const std = @import("std");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");
const process = @import("../process.zig");

/// Persistent code execution sandbox for VANTARI.
///
/// Harvested from oh-my-pi's eval feature (README feature 01):
/// "runs persistent Python and a Bun worker, and either kernel can call
/// back into the agent's own tools — read, search, task — over a loopback
/// bridge."
///
/// Moves 56-57 implement persistent Python and Bun workers. The worker protocol
/// is intentionally smaller than Jupyter's: one request line, one response
/// line, one session-owned namespace. Move 58 owns the shared process
/// supervisor and tree teardown receipts.
const worker_output_cap: usize = 64 * 1024;

pub const Language = enum {
    auto,
    python,
    bun,
};

fn languageLabel(language: Language) []const u8 {
    return switch (language) {
        .auto => "auto",
        .python => "python",
        .bun => "bun",
    };
}

const bun_command_name: []const u8 = if (@import("builtin").os.tag == .windows) "bun.exe" else "bun";

fn bunCommand() []const u8 {
    return bun_command_name;
}

/// The worker keeps a single namespace while VANTARI owns the session
/// boundary. User code is not sandboxed; the tool is therefore gated by
/// `runtime.full_access_mode` until a verified native sandbox exists.
const python_worker_source =
    \\import base64
    \\import builtins
    \\import contextlib
    \\import json
    \\import sys
    \\import traceback
    \\class BoundedText:
    \\    def __init__(self, limit):
    \\        self.limit = limit
    \\        self.parts = []
    \\        self.size = 0
    \\        self.truncated = False
    \\    def write(self, value):
    \\        text = str(value)
    \\        remaining = self.limit - self.size
    \\        if remaining > 0:
    \\            self.parts.append(text[:remaining])
    \\            self.size += min(len(text), remaining)
    \\        if len(text) > max(remaining, 0):
    \\            self.truncated = True
    \\        return len(text)
    \\    def flush(self):
    \\        return None
    \\    def getvalue(self):
    \\        return "".join(self.parts)
    \\def disabled_input(*args, **kwargs):
    \\    raise RuntimeError("interactive input is disabled for VANTARI eval")
    \\safe_builtins = dict(vars(builtins))
    \\safe_builtins["input"] = disabled_input
    \\namespace = {
    \\    "__name__": "__vantari_eval__",
    \\    "__builtins__": safe_builtins,
    \\}
    \\for line in sys.stdin:
    \\    if not line.strip():
    \\        continue
    \\    stdout = BoundedText(65536)
    \\    stderr = BoundedText(65536)
    \\    ok = True
    \\    try:
    \\        request = json.loads(line)
    \\        code = base64.b64decode(request["code"]).decode("utf-8")
    \\        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
    \\            exec(compile(code, "<vantari-eval>", "exec"), namespace, namespace)
    \\    except BaseException:
    \\        ok = False
    \\        stderr.write(traceback.format_exc())
    \\    response = {
    \\        "ok": ok,
    \\        "stdout": stdout.getvalue(),
    \\        "stderr": stderr.getvalue(),
    \\        "truncated": stdout.truncated or stderr.truncated,
    \\    }
    \\    sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
    \\    sys.stdout.flush()
;

const bun_worker_source =
    \\const readline = require("node:readline");
    \\const vm = require("node:vm");
    \\const context = vm.createContext({});
    \\let stdout = "";
    \\let stderr = "";
    \\const limit = 65536;
    \\const append = (target, value) => {
    \\  const text = String(value);
    \\  return target.length >= limit ? target : target + text.slice(0, limit - target.length);
    \\};
    \\context.console = {
    \\  log: (...args) => { stdout = append(stdout, args.join(" ") + "\n"); },
    \\  info: (...args) => { stdout = append(stdout, args.join(" ") + "\n"); },
    \\  warn: (...args) => { stderr = append(stderr, args.join(" ") + "\n"); },
    \\  error: (...args) => { stderr = append(stderr, args.join(" ") + "\n"); },
    \\};
    \\context.globalThis = context;
    \\const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
    \\input.on("line", (line) => {
    \\  if (!line.trim()) return;
    \\  stdout = "";
    \\  stderr = "";
    \\  let ok = true;
    \\  try {
    \\    const request = JSON.parse(line);
    \\    const code = Buffer.from(request.code, "base64").toString("utf8");
    \\    vm.runInContext(code, context, { filename: "<vantari-eval>" });
    \\  } catch (error) {
    \\    ok = false;
    \\    stderr = append(stderr, error && error.stack ? error.stack : String(error));
    \\  }
    \\  process.stdout.write(JSON.stringify({ ok, stdout, stderr, truncated: stdout.length >= limit || stderr.length >= limit }) + "\n");
    \\});
;

const WorkerResponse = struct {
    ok: bool,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    truncated: bool = false,
};

const KernelRegistry = struct {
    mutex: std.Thread.Mutex = .{},
    kernels: std.StringHashMapUnmanaged(*KernelState) = .{},

    fn deinit(self: *KernelRegistry) void {
        const allocator = std.heap.page_allocator;
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.kernels.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            allocator.destroy(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.kernels.deinit(allocator);
        self.kernels = .{};
    }
};

var kernel_registry: KernelRegistry = .{};

/// Stop every session-owned worker during host teardown. The registry is
/// process-local execution state, never transcript or session truth.
pub fn deinitAll() void {
    kernel_registry.deinit();
}

/// The persistent kernel state. Stored per-session so variables survive
/// across eval calls.
pub const KernelState = struct {
    allocator: std.mem.Allocator,
    process: ?process.PersistentProcess = null,
    language: Language = .auto,
    started: bool = false,
    mutex: std.Thread.Mutex = .{},

    pub fn deinit(self: *KernelState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopLocked();
    }

    fn stopLocked(self: *KernelState) void {
        if (self.process) |*proc| {
            proc.deinit();
        }
        self.process = null;
        self.started = false;
    }
};

fn registryKey(workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}", .{ workspace_root, session_id });
}

fn acquireKernel(
    workspace_root: []const u8,
    session_id: []const u8,
    requested_language: Language,
) !*KernelState {
    if (session_id.len == 0) return error.SessionRequired;

    const allocator = std.heap.page_allocator;
    const key = try registryKey(workspace_root, session_id);
    errdefer allocator.free(key);

    kernel_registry.mutex.lock();
    defer kernel_registry.mutex.unlock();

    if (kernel_registry.kernels.get(key)) |kernel| {
        if (requested_language != .auto and kernel.language != .auto and kernel.language != requested_language) {
            return error.KernelLanguageMismatch;
        }
        if (!kernel.started and requested_language != .auto) kernel.language = requested_language;
        allocator.free(key);
        return kernel;
    }

    const kernel = try allocator.create(KernelState);
    errdefer allocator.destroy(kernel);
    kernel.* = .{
        .allocator = allocator,
        .language = requested_language,
    };
    try kernel_registry.kernels.put(allocator, key, kernel);
    return kernel;
}

/// Start or get the persistent kernel for this session.
/// The kernel is a long-running Python worker that persists variables across
/// calls.
pub fn ensureKernel(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    workspace_root: []const u8,
) !void {
    kernel.mutex.lock();
    defer kernel.mutex.unlock();
    try ensureKernelLocked(allocator, kernel, workspace_root);
}

fn ensureKernelLocked(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    workspace_root: []const u8,
) !void {
    if (kernel.started) return;
    if (kernel.language == .auto) {
        if (commandExists(allocator, "python"))
            kernel.language = .python
        else if (commandExists(allocator, bunCommand()))
            kernel.language = .bun
        else
            return error.NoKernelAvailable;
    }

    switch (kernel.language) {
        .python => {
            const argv = [_][]const u8{ "python", "-u", "-c", python_worker_source };
            kernel.process = try process.PersistentProcess.spawn(kernel.allocator, workspace_root, &argv);
        },
        .bun => {
            const argv = [_][]const u8{ bunCommand(), "-e", bun_worker_source };
            kernel.process = try process.PersistentProcess.spawn(kernel.allocator, workspace_root, &argv);
        },
        .auto => return error.NoKernelAvailable,
    }
    kernel.started = true;
}

/// Execute code in the persistent Python kernel. Returns bounded output.
pub fn executeCode(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    code: []const u8,
    workspace_root: []const u8,
    timeout_ms: u64,
) !EvalResult {
    kernel.mutex.lock();
    defer kernel.mutex.unlock();
    try ensureKernelLocked(allocator, kernel, workspace_root);
    if (kernel.process == null) return error.NoKernelAvailable;
    return executePersistent(allocator, kernel, code, timeout_ms);
}

pub const EvalResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    success: bool,
    truncated: bool = false,
    termination: process.PersistentTerminationReceipt = .{},

    pub fn deinit(self: EvalResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Execute one request in the persistent worker.
fn executePersistent(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    code: []const u8,
    timeout_ms: u64,
) !EvalResult {
    const proc = &(kernel.process.?);

    var encoded: [std.base64.standard.Encoder.calcSize(worker_output_cap)]u8 = undefined;
    if (code.len > worker_output_cap) return error.CodeTooLarge;
    const encoded_text = std.base64.standard.Encoder.encode(&encoded, code);
    const request = try std.fmt.allocPrint(allocator, "{{\"code\":\"{s}\"}}\n", .{encoded_text});
    defer allocator.free(request);
    proc.writeLine(request) catch {
        kernel.stopLocked();
        return error.KernelDied;
    };

    const response = try proc.readLine(allocator, @as(usize, @intCast(timeout_ms)), worker_output_cap);
    defer response.deinit(allocator);

    if (response.timed_out) {
        const termination = response.termination;
        kernel.stopLocked();
        return .{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try std.fmt.allocPrint(allocator, "eval timed out; {s} kernel was terminated", .{languageLabel(kernel.language)}),
            .exit_code = 124,
            .success = false,
            .termination = termination,
        };
    }
    if (response.truncated) {
        return .{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "eval response exceeded the bounded worker output"),
            .exit_code = 1,
            .success = false,
            .truncated = true,
            .termination = response.termination,
        };
    }

    var parsed = std.json.parseFromSlice(WorkerResponse, allocator, response.line, .{}) catch return error.InvalidKernelResponse;
    defer parsed.deinit();

    return .{
        .stdout = try allocator.dupe(u8, parsed.value.stdout),
        .stderr = try allocator.dupe(u8, parsed.value.stderr),
        .exit_code = if (parsed.value.ok) 0 else 1,
        .success = parsed.value.ok,
        .truncated = parsed.value.truncated,
        .termination = response.termination,
    };
}

/// Check if a command exists in PATH.
fn commandExists(allocator: std.mem.Allocator, command: []const u8) bool {
    // On Windows, check common locations. On Unix, use `which`.
    var child = std.process.Child.init(&[_][]const u8{
        switch (@import("builtin").os.tag) {
            .windows => "where",
            else => "which",
        },
        command,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// ============================================================================
// Agent tool definition
// ============================================================================

pub const definition = types.ToolDefinition{
    .name = "eval",
    .description = "Execute Python or Bun JavaScript in a persistent session kernel. Variables, imports, and state persist across calls within the same session. This is trusted code execution and requires runtime.full_access_mode=true until a native sandbox is available.",
    .review_risk = .command_execution,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "code": { "type": "string", "description": "Python or Bun JavaScript code to execute. Multiline code is supported." },
    \\    "language": { "type": "string", "enum": ["python", "bun"], "description": "Optional language hint. Defaults to Python when available, otherwise Bun." }
    \\  },
    \\  "required": ["code"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"language\":\"python\",\"code\":\"import sys; print(sys.version)\"}",
    .usage_hint = "Use only for trusted calculations, data processing, code validation, and scripting after full_access_mode is explicitly enabled. The selected Python or Bun kernel persists across calls in one session; define a function or variable in one eval and use it in the next.",
    .availability = .{ .dependency = .{ .kind = .external_command, .name = "python", .alternatives = &.{bun_command_name} } },
};

pub const availability = definition.availability;

/// Execute the eval tool.
pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        code: []const u8,
        language: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    if (!execution_context.full_access_mode) return module.Error.CapabilityDenied;
    const session_id = execution_context.session_id orelse return error.SessionRequired;
    const requested_language: Language = if (parsed.value.language) |lang| blk: {
        if (std.mem.eql(u8, lang, "python")) break :blk .python;
        if (std.mem.eql(u8, lang, "bun")) break :blk .bun;
        return module.Error.InvalidArguments;
    } else .auto;
    const kernel = try acquireKernel(execution_context.workspace_root, session_id, requested_language);

    const result = executeCode(
        allocator,
        kernel,
        parsed.value.code,
        execution_context.workspace_root,
        10_000, // 10 second timeout
    ) catch |err| {
        const err_msg = try std.fmt.allocPrint(allocator, "eval failed: {s}", .{@errorName(err)});
        defer allocator.free(err_msg);
        return module.okEnvelope(allocator, "eval", err_msg);
    };
    defer result.deinit(allocator);

    // Format the output for the agent.
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    if (result.stdout.len > 0) {
        try writer.print("STDOUT:\n{s}\n", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        try writer.print("STDERR:\n{s}\n", .{result.stderr});
    }
    if (result.stdout.len == 0 and result.stderr.len == 0) {
        try writer.writeAll("(no output)\n");
    }
    if (result.truncated) try writer.writeAll("OUTPUT_TRUNCATED: true\n");
    if (result.termination.termination_requested) {
        try writer.print(
            "PROCESS_RECEIPT: tree_teardown_attempted={} child_reaped={} pipes_drained={}\n",
            .{
                result.termination.tree_teardown_attempted,
                result.termination.child_reaped,
                result.termination.pipes_drained,
            },
        );
    }
    try writer.print("EXIT_CODE: {d}\n", .{result.exit_code});

    return module.okEnvelope(allocator, "eval", output.items);
}

// ============================================================================
// Tests
// ============================================================================

test "eval tool definition is explicit about trusted Python execution" {
    try std.testing.expectEqual(types.ToolRiskClass.command_execution, definition.review_risk);
    try std.testing.expect(std.mem.indexOf(u8, definition.description, "full_access_mode=true") != null);
    try std.testing.expectEqualStrings("python", definition.availability.dependency.?.name);
    try std.testing.expectEqualStrings(bun_command_name, definition.availability.dependency.?.alternatives[0]);
}

test "eval tool definition requires code field" {
    try std.testing.expect(std.mem.indexOf(u8, definition.parameters_json, "\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, definition.parameters_json, "\"required\":") != null);
}

test "persistent Python state is isolated by session" {
    if (!commandExists(std.testing.allocator, "python")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    defer deinitAll();

    const first = try acquireKernel(workspace_root, "session-one", .python);
    const first_result = try executeCode(std.testing.allocator, first, "value = 41\nprint(value)", workspace_root, 5_000);
    defer first_result.deinit(std.testing.allocator);
    try std.testing.expect(first_result.success);
    try std.testing.expectEqualStrings("41", std.mem.trim(u8, first_result.stdout, " \t\r\n"));

    const second_result = try executeCode(std.testing.allocator, first, "print(value + 1)", workspace_root, 5_000);
    defer second_result.deinit(std.testing.allocator);
    try std.testing.expect(second_result.success);
    try std.testing.expectEqualStrings("42", std.mem.trim(u8, second_result.stdout, " \t\r\n"));

    const other = try acquireKernel(workspace_root, "session-two", .python);
    const other_result = try executeCode(std.testing.allocator, other, "print('value' in globals())", workspace_root, 5_000);
    defer other_result.deinit(std.testing.allocator);
    try std.testing.expect(other_result.success);
    try std.testing.expectEqualStrings("False", std.mem.trim(u8, other_result.stdout, " \t\r\n"));
}

test "persistent Python timeout terminates the session kernel" {
    if (!commandExists(std.testing.allocator, "python")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    defer deinitAll();

    const kernel = try acquireKernel(workspace_root, "timeout-session", .python);
    const result = try executeCode(std.testing.allocator, kernel, "import time\ntime.sleep(30)", workspace_root, 50);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u8, 124), result.exit_code);
    try std.testing.expect(result.termination.termination_requested);
    try std.testing.expect(result.termination.child_reaped);
    try std.testing.expect(result.termination.pipes_drained);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(result.termination.tree_teardown_attempted);
    }
    try std.testing.expect(!kernel.started);
}

test "persistent Python output cap drains the response and preserves the kernel" {
    if (!commandExists(std.testing.allocator, "python")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    defer deinitAll();

    const kernel = try acquireKernel(workspace_root, "output-cap-session", .python);
    const oversized = try executeCode(std.testing.allocator, kernel, "print('x' * 70000)", workspace_root, 5_000);
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expect(!oversized.success);
    try std.testing.expect(oversized.truncated);
    try std.testing.expect(oversized.termination.pipes_drained);

    const after = try executeCode(std.testing.allocator, kernel, "print('still alive')", workspace_root, 5_000);
    defer after.deinit(std.testing.allocator);
    try std.testing.expect(after.success);
    try std.testing.expectEqualStrings("still alive", std.mem.trim(u8, after.stdout, " \t\r\n"));
}

test "persistent Bun state is isolated by session" {
    if (!commandExists(std.testing.allocator, bunCommand())) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    defer deinitAll();

    const first = try acquireKernel(workspace_root, "bun-session-one", .bun);
    const first_result = try executeCode(std.testing.allocator, first, "value = 41; console.log(value)", workspace_root, 20_000);
    defer first_result.deinit(std.testing.allocator);
    try std.testing.expect(first_result.success);
    try std.testing.expectEqualStrings("41", std.mem.trim(u8, first_result.stdout, " \t\r\n"));

    const second_result = try executeCode(std.testing.allocator, first, "console.log(value + 1)", workspace_root, 20_000);
    defer second_result.deinit(std.testing.allocator);
    try std.testing.expect(second_result.success);
    try std.testing.expectEqualStrings("42", std.mem.trim(u8, second_result.stdout, " \t\r\n"));

    const other = try acquireKernel(workspace_root, "bun-session-two", .bun);
    const other_result = try executeCode(std.testing.allocator, other, "console.log(typeof value)", workspace_root, 20_000);
    defer other_result.deinit(std.testing.allocator);
    try std.testing.expect(other_result.success);
    try std.testing.expectEqualStrings("undefined", std.mem.trim(u8, other_result.stdout, " \t\r\n"));
}
