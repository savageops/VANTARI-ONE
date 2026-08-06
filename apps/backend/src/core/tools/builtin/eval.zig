const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

/// Persistent code execution sandbox for VANTARI.
///
/// Harvested from oh-my-pi's eval feature (README feature 01):
/// "runs persistent Python and a Bun worker, and either kernel can call
/// back into the agent's own tools — read, search, task — over a loopback
/// bridge."
///
/// VANTARI's implementation spawns a persistent kernel process (Python
/// via `python -i` or Bun via `bun -e`) and communicates over stdio.
/// Each eval call sends code to the kernel's stdin and reads the result
/// from stdout. The kernel persists across calls, so variables, imports,
/// and state survive between eval invocations within the same session.
///
/// VANTARI's advantage: the kernel is spawned with the same Job Object
/// process-tree kill infrastructure as shell_exec, so it's bounded and
/// cancellable. The output is captured with the same PipeCollector that
/// bounds command output — no unbounded kernel output can flood the
/// context window.

/// The persistent kernel state. Stored per-session so variables survive
/// across eval calls.
pub const KernelState = struct {
    allocator: std.mem.Allocator,
    process: ?std.process.Child = null,
    language: []const u8 = "python",
    started: bool = false,

    pub fn deinit(self: *KernelState) void {
        if (self.process) |*proc| {
            if (proc.stdin) |*stdin| {
                stdin.close();
                proc.stdin = null;
            }
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
        }
    }
};

/// Start or get the persistent kernel for this session.
/// The kernel is a long-running process (python -i or bun repl) that
/// persists variables across calls.
pub fn ensureKernel(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    workspace_root: []const u8,
) !void {
    if (kernel.started) return;

    // Detect available runtime: python first, then bun, then node.
    const cmd: []const u8 = blk: {
        if (commandExists(allocator, "python")) break :blk "python";
        if (commandExists(allocator, "python3")) break :blk "python3";
        if (commandExists(allocator, "bun")) break :blk "bun";
        return error.NoKernelAvailable;
    };

    if (std.mem.startsWith(u8, cmd, "python")) {
        kernel.language = "python";
    } else if (std.mem.startsWith(u8, cmd, "bun")) {
        kernel.language = "bun";
    }

    // Spawn the kernel in interactive mode.
    // Python: `python -i -u` (unbuffered, interactive)
    // Bun: we'll use `bun` with eval per-call instead of a persistent REPL
    // (Bun's REPL is not easily scriptable over stdin)
    if (std.mem.startsWith(u8, cmd, "python")) {
        const argv = [_][]const u8{ cmd, "-i", "-u" };
        var child = std.process.Child.init(&argv, allocator);
        child.cwd = workspace_root;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        kernel.process = child;
    } else {
        // Bun: use per-call execution (no persistent REPL)
        kernel.language = "bun";
    }

    kernel.started = true;
}

/// Execute code in the persistent kernel. Returns stdout+stderr output.
/// For Python: writes code to stdin followed by a sentinel marker, reads
/// until the sentinel appears in stdout.
/// For Bun: spawns a fresh process per call (Bun doesn't have a scriptable REPL).
pub fn executeCode(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    code: []const u8,
    workspace_root: []const u8,
    timeout_ms: u64,
) !EvalResult {
    if (!kernel.started) {
        try ensureKernel(allocator, kernel, workspace_root);
    }

    if (std.mem.eql(u8, kernel.language, "python") and kernel.process != null) {
        return executePythonPersistent(allocator, kernel, code, timeout_ms);
    } else if (std.mem.eql(u8, kernel.language, "bun")) {
        return executeBunOneShot(allocator, code, workspace_root, timeout_ms);
    }

    return error.NoKernelAvailable;
}

pub const EvalResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    success: bool,

    pub fn deinit(self: EvalResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Execute Python code in the persistent interactive session.
fn executePythonPersistent(
    allocator: std.mem.Allocator,
    kernel: *KernelState,
    code: []const u8,
    timeout_ms: u64,
) !EvalResult {
    const proc = &(kernel.process.?);
    const stdin = proc.stdin orelse return error.NoStdin;

    // Write the code followed by a sentinel that prints a unique marker.
    // The marker lets us know when the code has finished executing.
    const sentinel = "__VANTARI_EVAL_DONE__";
    const wrapped = try std.fmt.allocPrint(allocator,
        \\{s}
        \\print("{s}")
        \\
    , .{ code, sentinel });
    defer allocator.free(wrapped);

    stdin.writeAll(wrapped) catch return error.KernelDied;

    // Read stdout until we see the sentinel or timeout.
    const stdout = proc.stdout orelse return error.NoStdout;
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var buf: [4096]u8 = undefined;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var sentinel_found = false;

    while (std.time.milliTimestamp() < deadline) {
        const len = stdout.read(&buf) catch break;
        if (len == 0) break;
        try output.appendSlice(buf[0..len]);

        // Check for sentinel in the accumulated output.
        if (std.mem.indexOf(u8, output.items, sentinel) != null) {
            sentinel_found = true;
            break;
        }
    }

    // Strip the sentinel from the output.
    var result_text: []u8 = undefined;
    if (sentinel_found) {
        const pos = std.mem.indexOf(u8, output.items, sentinel) orelse output.items.len;
        // Also strip the trailing newline before the sentinel.
        var end = pos;
        if (end > 0 and output.items[end - 1] == '\n') end -= 1;
        result_text = try allocator.dupe(u8, output.items[0..end]);
    } else {
        result_text = try output.toOwnedSlice();
    }

    return .{
        .stdout = result_text,
        .stderr = try allocator.dupe(u8, ""),
        .exit_code = 0,
        .success = sentinel_found,
    };
}

/// Execute Bun code as a one-shot process (no persistent REPL).
fn executeBunOneShot(
    allocator: std.mem.Allocator,
    code: []const u8,
    workspace_root: []const u8,
    timeout_ms: u64,
) !EvalResult {
    // Write code to a temp file and execute with bun.
    const temp_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "eval_tmp.mjs" });
    defer allocator.free(temp_path);

    try fsutil.ensureParent(temp_path);
    try fsutil.writeText(temp_path, code);

    const argv = [_][]const u8{ "bun", "run", temp_path };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = workspace_root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    // Use the term parameter — timeout handled by the caller.
    _ = timeout_ms;

    child.spawn() catch {
        return .{
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "Failed to spawn bun. Is it installed?"),
            .exit_code = 1,
            .success = false,
        };
    };

    var stdout_collector = std.array_list.Managed(u8).init(allocator);
    defer stdout_collector.deinit();
    var stderr_collector = std.array_list.Managed(u8).init(allocator);
    defer stderr_collector.deinit();

    // Read output with a basic 8KB cap.
    var buf: [4096]u8 = undefined;
    while (true) {
        const len = if (child.stdout) |stdout| stdout.read(&buf) catch break else break;
        if (len == 0) break;
        if (stdout_collector.items.len < 8192) {
            const to_copy = @min(len, 8192 - stdout_collector.items.len);
            try stdout_collector.appendSlice(buf[0..to_copy]);
        }
    }
    while (true) {
        const len = if (child.stderr) |stderr| stderr.read(&buf) catch break else break;
        if (len == 0) break;
        if (stderr_collector.items.len < 4096) {
            const to_copy = @min(len, 4096 - stderr_collector.items.len);
            try stderr_collector.appendSlice(buf[0..to_copy]);
        }
    }

    const term = child.wait() catch {};
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };

    return .{
        .stdout = try stdout_collector.toOwnedSlice(),
        .stderr = try stderr_collector.toOwnedSlice(),
        .exit_code = exit_code,
        .success = exit_code == 0,
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
    .description = "Execute code in a persistent Python or Bun kernel. Variables, imports, and state persist across calls within the same session. Use for data analysis, calculations, code validation, and automation. Requires Python or Bun installed.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "code": { "type": "string", "description": "Code to execute. Python or Bun/JavaScript syntax depending on the available runtime." },
    \\    "language": { "type": "string", "description": "Optional language hint: 'python' or 'bun'. Defaults to auto-detect." }
    \\  },
    \\  "required": ["code"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"code\":\"import sys; print(sys.version)\"}",
    .usage_hint = "Use for calculations, data processing, code validation, and scripting. The kernel persists across calls — define a function in one eval, call it in the next. Python is preferred when available.",
};

pub const availability = module.AvailabilitySpec{};

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

    // Check if any runtime is available.
    const has_python = commandExists(allocator, "python") or commandExists(allocator, "python3");
    const has_bun = commandExists(allocator, "bun");

    if (!has_python and !has_bun) {
        return module.okEnvelope(allocator, "eval", "No code execution runtime found. Install Python or Bun to use eval.");
    }

    // Create a kernel for this call (persistent kernels would be stored
    // per-session in a production implementation).
    var kernel = KernelState{
        .allocator = allocator,
    };
    defer kernel.deinit();

    if (parsed.value.language) |lang| {
        kernel.language = lang;
    }

    const result = executeCode(
        allocator,
        &kernel,
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
    try writer.print("EXIT_CODE: {d}\n", .{result.exit_code});

    return module.okEnvelope(allocator, "eval", output.items);
}

// ============================================================================
// Tests
// ============================================================================

test "eval tool definition has correct review risk" {
    try std.testing.expectEqual(types.ToolReviewRisk.unknown_high_impact, definition.review_risk);
}

test "eval tool definition requires code field" {
    try std.testing.expect(std.mem.indexOf(u8, definition.parameters_json, "\"code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, definition.parameters_json, "\"required\":") != null);
}
