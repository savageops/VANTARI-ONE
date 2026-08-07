const builtin = @import("builtin");
const std = @import("std");

const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "shell_exec",
    .description = "Execute a bounded command in the workspace. Prefer argv mode for known binaries; use shell, bash, or powershell mode only when shell semantics are required.",
    .review_risk = .command_execution,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "mode": { "type": "string", "enum": ["shell", "bash", "powershell", "argv"], "description": "Execution mode. shell uses the platform default command shell; bash uses bash -lc; powershell uses powershell.exe -Command; argv executes argv directly." },
    \\    "command": { "type": "string", "description": "Command string for shell, bash, or powershell mode." },
    \\    "argv": { "type": "array", "items": { "type": "string" }, "description": "Argument vector for argv mode. argv[0] is the executable." },
    \\    "cwd": { "type": "string", "description": "Optional workspace-relative working directory. Defaults to ." },
    \\    "timeout_ms": { "type": "integer", "minimum": 1, "maximum": 60000, "description": "Execution timeout in milliseconds. Defaults to 10000." },
    \\    "max_output_bytes": { "type": "integer", "minimum": 1, "maximum": 65536, "description": "Maximum captured bytes per stdout/stderr stream. Defaults to 16384." }
    \\  },
    \\  "required": ["mode"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"mode\":\"argv\",\"argv\":[\"zig\",\"version\"],\"cwd\":\".\",\"timeout_ms\":10000,\"max_output_bytes\":4096}",
    .usage_hint = "Use mode=argv with argv only for precise execution. Use mode=powershell/shell/bash with command only for compound operators. On Windows, prefer PowerShell-native commands such as Select-String/Get-ChildItem instead of cmd find/findstr pipelines. cwd is always resolved inside the workspace. Inspect exit_code; nonzero exits are returned as data, not transport failure.",
};

pub const availability = module.AvailabilitySpec{};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    runner: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        mode: []const u8,
        command: ?[]const u8 = null,
        argv: ?[]const []const u8 = null,
        cwd: ?[]const u8 = null,
        timeout_ms: ?usize = null,
        max_output_bytes: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const cwd = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.cwd orelse ".");
    defer allocator.free(cwd);

    const timeout_ms = clamp(parsed.value.timeout_ms orelse 10_000, 1, 60_000);
    const max_output_bytes = clamp(parsed.value.max_output_bytes orelse 16 * 1024, 1, 64 * 1024);

    const argv = try buildArgv(allocator, parsed.value.mode, parsed.value.command, parsed.value.argv);
    defer freeArgv(allocator, argv);

    var output_context = ToolOutputContext{
        .sink = execution_context.tool_events,
        .tool_call_id = null,
    };
    const callback = module.CommandOutputCallback{
        .context = &output_context,
        .onOutputFn = forwardCommandOutput,
    };

    var result = try runner.runWithLimits(allocator, cwd, argv, .{
        .timeout_ms = timeout_ms,
        .max_output_bytes = max_output_bytes,
        .output_callback = callback,
    });
    defer result.deinit(allocator);

    return renderResult(allocator, parsed.value.mode, cwd, argv, result);
}

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    runner: module.CommandRunner,
    tool_call_id: []const u8,
) ![]u8 {
    const Args = struct {
        mode: []const u8,
        command: ?[]const u8 = null,
        argv: ?[]const []const u8 = null,
        cwd: ?[]const u8 = null,
        timeout_ms: ?usize = null,
        max_output_bytes: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const cwd = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.cwd orelse ".");
    defer allocator.free(cwd);

    const timeout_ms = clamp(parsed.value.timeout_ms orelse 10_000, 1, 60_000);
    const max_output_bytes = clamp(parsed.value.max_output_bytes orelse 16 * 1024, 1, 64 * 1024);

    const argv = try buildArgv(allocator, parsed.value.mode, parsed.value.command, parsed.value.argv);
    defer freeArgv(allocator, argv);

    var output_context = ToolOutputContext{
        .sink = execution_context.tool_events,
        .tool_call_id = tool_call_id,
    };
    const callback = module.CommandOutputCallback{
        .context = &output_context,
        .onOutputFn = forwardCommandOutput,
    };

    const started_at_ms = std.time.milliTimestamp();
    var result = try runner.runWithLimits(allocator, cwd, argv, .{
        .timeout_ms = timeout_ms,
        .max_output_bytes = max_output_bytes,
        .output_callback = callback,
    });
    defer result.deinit(allocator);

    appendProcessLedger(allocator, execution_context, parsed.value.mode, cwd, argv, tool_call_id, started_at_ms, result) catch {};

    return renderResult(allocator, parsed.value.mode, cwd, argv, result);
}

const ToolOutputContext = struct {
    sink: ?module.ToolEventSink,
    tool_call_id: ?[]const u8,
};

fn forwardCommandOutput(
    ctx: ?*anyopaque,
    stream: module.CommandOutputStream,
    chunk: []const u8,
    cap_reached: bool,
) anyerror!void {
    const context: *ToolOutputContext = @ptrCast(@alignCast(ctx orelse return));
    const sink = context.sink orelse return;
    const tool_call_id = context.tool_call_id orelse "";
    try sink.onOutputDelta(tool_call_id, definition.name, stream, chunk, cap_reached);
}

fn buildArgv(
    allocator: std.mem.Allocator,
    mode: []const u8,
    command: ?[]const u8,
    maybe_argv: ?[]const []const u8,
) ![][]const u8 {
    if (std.mem.eql(u8, mode, "argv")) {
        if (command != null) return module.Error.InvalidArguments;
        const provided = maybe_argv orelse return module.Error.InvalidArguments;
        if (provided.len == 0) return module.Error.InvalidArguments;
        return cloneArgv(allocator, provided);
    }

    if (maybe_argv != null) return module.Error.InvalidArguments;
    const command_text = command orelse return module.Error.InvalidArguments;
    if (std.mem.trim(u8, command_text, " \t\r\n").len == 0) return module.Error.InvalidArguments;

    if (std.mem.eql(u8, mode, "shell")) {
        if (builtin.os.tag == .windows) {
            return cloneArgv(allocator, &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command_text });
        }
        return cloneArgv(allocator, &.{ "/bin/sh", "-lc", command_text });
    }

    if (std.mem.eql(u8, mode, "bash")) {
        return cloneArgv(allocator, &.{ "bash", "-lc", command_text });
    }

    if (std.mem.eql(u8, mode, "powershell")) {
        return cloneArgv(allocator, &.{ "powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command_text });
    }

    return module.Error.InvalidArguments;
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![][]const u8 {
    var owned = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(owned);
    for (argv, 0..) |arg, index| {
        owned[index] = try allocator.dupe(u8, arg);
    }
    return owned;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn renderResult(
    allocator: std.mem.Allocator,
    mode: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    result: module.CommandOutput,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"ok\":true,\"tool\":\"shell_exec\",\"mode\":");
    try output.writer().print("{f}", .{std.json.fmt(mode, .{})});
    try output.writer().writeAll(",\"cwd\":");
    try output.writer().print("{f}", .{std.json.fmt(cwd, .{})});
    try output.writer().writeAll(",\"argv\":[");
    for (argv, 0..) |arg, index| {
        if (index > 0) try output.writer().writeAll(",");
        try output.writer().print("{f}", .{std.json.fmt(arg, .{})});
    }
    try output.writer().writeAll("],\"exit_code\":");
    try output.writer().print("{d}", .{result.exit_code});
    try output.writer().writeAll(",\"timed_out\":");
    try output.writer().writeAll(if (result.timed_out) "true" else "false");
    try output.writer().writeAll(",\"truncated\":");
    try output.writer().writeAll(if (result.truncated) "true" else "false");
    try output.writer().writeAll(",\"stdout\":");
    try output.writer().print("{f}", .{std.json.fmt(result.stdout, .{})});
    try output.writer().writeAll(",\"stderr\":");
    try output.writer().print("{f}", .{std.json.fmt(result.stderr, .{})});
    try output.writer().writeAll("}");

    return output.toOwnedSlice();
}

fn clamp(value: usize, min: usize, max: usize) usize {
    return @min(@max(value, min), max);
}

test "shell_exec builds direct argv and returns structured exit metadata" {
    const Runner = struct {
        fn run(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            cwd: []const u8,
            argv: []const []const u8,
            limits: module.CommandLimits,
        ) anyerror!module.CommandOutput {
            try std.testing.expect(std.mem.endsWith(u8, cwd, "apps\\backend") or std.mem.endsWith(u8, cwd, "apps/backend"));
            try std.testing.expectEqualStrings("zig", argv[0]);
            try std.testing.expectEqual(@as(usize, 1000), limits.timeout_ms);
            return .{
                .exit_code = 0,
                .stdout = try allocator.dupe(u8, "0.15.1\n"),
                .stderr = try allocator.dupe(u8, ""),
            };
        }
    };

    const output = try execute(std.testing.allocator, .{
        .workspace_root = ".",
    }, "{\"mode\":\"argv\",\"argv\":[\"zig\",\"version\"],\"cwd\":\"apps/backend\",\"timeout_ms\":1000}", .{
        .context = null,
        .runFn = undefinedRun,
        .runWithLimitsFn = Runner.run,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"tool\":\"shell_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"exit_code\":0") != null);
}

fn undefinedRun(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
) anyerror!module.CommandOutput {
    return module.Error.CommandFailed;
}

/// Append a process execution record to the workspace-local process ledger
/// at .var/processes/processes.jsonl. Failures are swallowed (catch {}) so
/// the command result is never blocked by a ledger write failure.
fn appendProcessLedger(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    mode: []const u8,
    cwd: []const u8,
    argv: []const []const u8,
    tool_call_id: []const u8,
    started_at_ms: i64,
    result: module.CommandOutput,
) !void {
    const now_ms = std.time.milliTimestamp();
    const duration_ms = now_ms - started_at_ms;

    var argv_buf = std.array_list.Managed(u8).init(allocator);
    defer argv_buf.deinit();
    const aw = argv_buf.writer();
    try aw.writeByte('[');
    for (argv, 0..) |arg, i| {
        if (i > 0) try aw.writeByte(',');
        try aw.print("{f}", .{std.json.fmt(arg, .{})});
    }
    try aw.writeByte(']');

    const record = try std.fmt.allocPrint(allocator,
        \\{{"schema":"var1.process.v1","mode":{f},"cwd":{f},"argv":{s},"exit_code":{d},"timed_out":{},"truncated":{},"duration_ms":{d},"started_at_ms":{d},"tool_call_id":{f},"workspace_root":{f},"session_id":{f}}}
    , .{
        std.json.fmt(mode, .{}),
        std.json.fmt(cwd, .{}),
        argv_buf.items,
        result.exit_code,
        result.timed_out,
        result.truncated,
        duration_ms,
        started_at_ms,
        std.json.fmt(tool_call_id, .{}),
        std.json.fmt(execution_context.workspace_root, .{}),
        std.json.fmt(execution_context.parent_session_id orelse "", .{}),
    });
    defer allocator.free(record);

    const ledger_path = try fsutil.join(allocator, &.{ execution_context.workspace_root, ".var", "processes", "processes.jsonl" });
    defer allocator.free(ledger_path);

    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();
    try line.appendSlice(record);
    try line.append('\n');
    try fsutil.appendText(ledger_path, line.items);
}
