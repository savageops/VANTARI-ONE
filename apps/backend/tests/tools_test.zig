const builtin = @import("builtin");
const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeToolCall(
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments_json: []const u8,
) !VAR1.shared.types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, "call-1"),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    };
}

fn execCtx(workspace_root: []const u8) VAR1.core.tool_runtime.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
    };
}

fn guardedExecCtx(workspace_root: []const u8, ledger: *VAR1.core.tool_runtime.FileInspectionLedger) VAR1.core.tool_runtime.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
        .file_inspection_ledger = ledger,
    };
}

fn execCtxWithProbe(
    workspace_root: []const u8,
    probe_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!bool,
) VAR1.core.tool_runtime.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
        .command_probe = .{
            .context = null,
            .commandExistsFn = probe_fn,
        },
    };
}

fn execCtxWithShapeProbe(
    workspace_root: []const u8,
    shape_context: *IxShapeProbeContext,
) VAR1.core.tool_runtime.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
        .command_probe = .{
            .context = shape_context,
            .commandExistsFn = mockCommandAvailable,
            .commandMatchesFn = mockIxSearchShape,
        },
    };
}

fn mockCommandAvailable(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    command_name: []const u8,
) anyerror!bool {
    return std.mem.eql(u8, command_name, "iex");
}

fn mockCommandUnavailable(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) anyerror!bool {
    return false;
}

const IxShapeProbeContext = struct {
    available: bool,
    calls: usize = 0,
};

fn mockIxSearchShape(
    ctx_ptr: ?*anyopaque,
    _: std.mem.Allocator,
    command_name: []const u8,
    argv: []const []const u8,
    stdout_needles: []const []const u8,
) anyerror!bool {
    var ctx: *IxShapeProbeContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.calls += 1;

    try std.testing.expectEqualStrings("iex", command_name);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("iex", argv[0]);
    try std.testing.expectEqualStrings("search", argv[1]);
    try std.testing.expectEqualStrings("--help", argv[2]);
    var found_json_flag = false;
    for (stdout_needles) |needle| {
        if (std.mem.eql(u8, needle, "--json")) found_json_flag = true;
    }
    try std.testing.expect(found_json_flag);

    return ctx.available;
}

const MockCommandContext = struct {
    allocator: std.mem.Allocator,
    last_command: ?[]u8 = null,

    fn deinit(self: *MockCommandContext) void {
        if (self.last_command) |value| self.allocator.free(value);
    }
};

const CountingRunnerContext = struct {
    calls: usize = 0,
    timeout_ms: usize = 0,
    max_output_bytes: usize = 0,
};

const OutputDeltaRecord = struct {
    tool_call_id: []const u8 = "",
    tool_name: []const u8 = "",
    stream: VAR1.core.tool_runtime.CommandOutputStream = .stdout,
    chunk: []const u8 = "",
    cap_reached: bool = false,
};

const OutputDeltaCapture = struct {
    records: [8]OutputDeltaRecord = [_]OutputDeltaRecord{.{}} ** 8,
    count: usize = 0,
};

fn captureToolOutputDelta(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    stream: VAR1.core.tool_runtime.CommandOutputStream,
    chunk: []const u8,
    cap_reached: bool,
) anyerror!void {
    var capture: *OutputDeltaCapture = @ptrCast(@alignCast(ctx.?));
    if (capture.count >= capture.records.len) return error.TooManyOutputDeltas;
    capture.records[capture.count] = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .stream = stream,
        .chunk = chunk,
        .cap_reached = cap_reached,
    };
    capture.count += 1;
}

fn mockCommandRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    var ctx: *MockCommandContext = @ptrCast(@alignCast(ctx_ptr.?));

    var joined = std.array_list.Managed(u8).init(ctx.allocator);
    errdefer joined.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try joined.writer().writeAll(" ");
        try joined.writer().writeAll(arg);
    }

    if (ctx.last_command) |value| ctx.allocator.free(value);
    ctx.last_command = try joined.toOwnedSlice();

    const stdout = if (std.mem.eql(u8, argv[1], "--files"))
        try allocator.dupe(u8, "src/main.zig\nsrc/core/tools/runtime.zig\n")
    else if (std.mem.eql(u8, argv[1], "search")) blk: {
        const main_path = try std.fmt.allocPrint(allocator, "{s}{c}src{c}main.zig", .{ cwd, std.fs.path.sep, std.fs.path.sep });
        defer allocator.free(main_path);
        const tools_path = try std.fmt.allocPrint(allocator, "{s}{c}src{c}core{c}tools{c}runtime.zig", .{ cwd, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep, std.fs.path.sep });
        defer allocator.free(tools_path);
        break :blk try std.fmt.allocPrint(
            allocator,
            "{{\"hits\":[{{\"path\":{f},\"line\":12,\"column\":1,\"preview\":\"read_file\"}},{{\"path\":{f},\"line\":9,\"column\":1,\"preview\":\"search_files\"}}]}}",
            .{ std.json.fmt(main_path, .{}), std.json.fmt(tools_path, .{}) },
        );
    } else try allocator.dupe(u8, "");

    return .{
        .exit_code = 0,
        .stdout = stdout,
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn mockCountingRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    var ctx: *CountingRunnerContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.calls += 1;
    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, "ok"),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn mockCountingLimitedRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
    limits: VAR1.core.tool_runtime.CommandLimits,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    var ctx: *CountingRunnerContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.calls += 1;
    ctx.timeout_ms = limits.timeout_ms;
    ctx.max_output_bytes = limits.max_output_bytes;
    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, "ok"),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn mockStreamingShellRunner(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
    limits: VAR1.core.tool_runtime.CommandLimits,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    try limits.output_callback.onOutput(.stdout, "alpha", false);
    try limits.output_callback.onOutput(.stderr, "warn", false);
    try limits.output_callback.onOutput(.stdout, "", true);

    return .{
        .exit_code = 7,
        .stdout = try allocator.dupe(u8, "alpha"),
        .stderr = try allocator.dupe(u8, "warn"),
        .truncated = true,
    };
}

const RecorderCommandContext = struct {
    allocator: std.mem.Allocator,
    last_command: ?[]u8 = null,

    fn deinit(self: *RecorderCommandContext) void {
        if (self.last_command) |value| self.allocator.free(value);
    }
};

fn recordCommand(ctx: *RecorderCommandContext, argv: []const []const u8) !void {
    var joined = std.array_list.Managed(u8).init(ctx.allocator);
    errdefer joined.deinit();
    for (argv, 0..) |arg, index| {
        if (index > 0) try joined.writer().writeAll(" ");
        try joined.writer().writeAll(arg);
    }

    if (ctx.last_command) |value| ctx.allocator.free(value);
    ctx.last_command = try joined.toOwnedSlice();
}

fn mockBackupRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    const ctx: *RecorderCommandContext = @ptrCast(@alignCast(ctx_ptr.?));
    try recordCommand(ctx, argv);

    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, "backup created"),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn mockNonGitRunner(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    argv: []const []const u8,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    const ctx: *RecorderCommandContext = @ptrCast(@alignCast(ctx_ptr.?));
    try recordCommand(ctx, argv);

    return .{
        .exit_code = 128,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, "fatal: not a git repository"),
    };
}

const MockAgentContext = struct {
    allocator: std.mem.Allocator,
    last_prompt: ?[]u8 = null,
    last_scope: VAR1.core.tool_runtime.DelegationScope = .{},

    fn deinit(self: *MockAgentContext) void {
        if (self.last_prompt) |value| self.allocator.free(value);
    }
};

fn mockLaunchAgent(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    prompt: []const u8,
    _: ?[]const u8,
    scope: VAR1.core.tool_runtime.DelegationScope,
) anyerror![]u8 {
    var ctx: *MockAgentContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.last_prompt) |value| ctx.allocator.free(value);
    ctx.last_prompt = try ctx.allocator.dupe(u8, prompt);
    ctx.last_scope = scope;
    return std.fmt.allocPrint(
        allocator,
        "AGENT_NAME berry-child\nSTATUS running\nCAPABILITY_PROFILE subagent\nSCOPE_DEPTH {}\nCONTACT_BUDGET {}\nVALIDATION_STATUS {s}\nESCALATION_REASON {s}\nPROMPT {s}",
        .{
            scope.scope_depth,
            scope.contact_budget,
            VAR1.core.agent_scope.validationStatusLabel(scope.validation_status),
            VAR1.core.agent_scope.escalationReasonLabel(scope),
            prompt,
        },
    );
}

fn mockAgentStatus(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child\nSTATUS running\nSESSION_ID session-child\nPARENT_SESSION_ID session-parent\nTERMINAL false\nLATEST_EVENT_TYPE tool_completed\nLATEST_EVENT_MESSAGE tool completed: write_file");
}

fn mockWaitAgent(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child\nSTATUS completed\nSESSION_ID session-child\nPARENT_SESSION_ID session-parent\nWAIT_STATE terminal\nOUTPUT There are 3 r's in strawberry.");
}

fn mockListAgents(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8, "AGENT_NAME berry-child STATUS completed SESSION_ID session-child\n");
}

fn mockConvergeBranches(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {}
fn mockReconcileShards(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!usize {
    return 0;
}

test "tool socket validates tool definitions through core namespace" {
    try VAR1.core.tools.validateDefinition(std.testing.allocator, .{
        .name = "lookup_ticket",
        .description = "Look up a ticket.",
        .review_risk = .read_only,
        .parameters_json = "{\"type\":\"object\",\"additionalProperties\":false}",
    });

    try std.testing.expectError(VAR1.core.tools.sockets.Error.InvalidToolName, VAR1.core.tools.sockets.validateName("lookup-ticket"));
    try std.testing.expectError(VAR1.core.tools.sockets.Error.InvalidParametersSchema, VAR1.core.tools.validateDefinition(std.testing.allocator, .{
        .name = "bad_schema",
        .description = "Bad schema.",
        .review_risk = .unknown_high_impact,
        .parameters_json = "[]",
    }));
}

test "plugin manifest validates declared sockets without loading plugins" {
    const sockets = [_]VAR1.core.plugins.PluginSocket{.{
        .kind = .tool,
        .name = "lookup_ticket",
        .entry = "tools/lookup_ticket",
        .review_risk = "read_only",
    }};

    try VAR1.core.plugins.validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = sockets[0..],
    });

    try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidPluginId, VAR1.core.plugins.validateManifest(.{
        .id = "Tickets",
        .version = "0.1.0",
    }));

    try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidSocketName, VAR1.core.plugins.validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .tool,
            .name = "lookup-ticket",
            .entry = "tools/lookup_ticket",
            .review_risk = "read_only",
        }},
    }));
}

test "file tools can create append replace and read within the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"notes/example.txt\",\"content\":\"alpha\\n\"}");
    defer write_call.deinit(std.testing.allocator);
    const write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), write_call);
    defer std.testing.allocator.free(write_output);

    var append_call = try makeToolCall(std.testing.allocator, "append_file", "{\"path\":\"notes/example.txt\",\"content\":\"beta\\n\"}");
    defer append_call.deinit(std.testing.allocator);
    const append_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), append_call);
    defer std.testing.allocator.free(append_output);

    var replace_call = try makeToolCall(std.testing.allocator, "replace_in_file", "{\"path\":\"notes/example.txt\",\"old_text\":\"beta\",\"new_text\":\"gamma\"}");
    defer replace_call.deinit(std.testing.allocator);
    const replace_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), replace_call);
    defer std.testing.allocator.free(replace_output);

    var read_call = try makeToolCall(std.testing.allocator, "read_file", "{\"path\":\"notes/example.txt\",\"start_line\":1,\"end_line\":2}");
    defer read_call.deinit(std.testing.allocator);
    const read_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), read_call);
    defer std.testing.allocator.free(read_output);

    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"effect\":{\"schema_version\":\"var1.tool_effect.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"action\":\"write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"before_exists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"bytes_written\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"after_sha256\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "APPENDED_BYTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"action\":\"append_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"before_exists\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"before_bytes\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"after_bytes\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"bytes_appended\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "REPLACEMENTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "\"action\":\"replace_in_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "\"replacements\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_output, "1: alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_output, "2: gamma") != null);
}

test "append primitive preserves existing file content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "journal.txt" });
    defer std.testing.allocator.free(file_path);

    try VAR1.shared.fsutil.writeText(file_path, "alpha\n");
    try VAR1.shared.fsutil.appendText(file_path, "beta\n");

    const contents = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(contents);

    try std.testing.expectEqualStrings("alpha\nbeta\n", contents);
}

test "file tools reject paths outside the workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"../escape.txt\",\"content\":\"blocked\"}");
    defer write_call.deinit(std.testing.allocator);

    try std.testing.expectError(VAR1.shared.fsutil.PathError.PathOutsideWorkspace, VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), write_call));
}

test "write-capable file tools require exact read ledger evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var ledger = VAR1.core.tool_runtime.FileInspectionLedger.init(std.testing.allocator);
    defer ledger.deinit();
    const ctx = guardedExecCtx(workspace_root, &ledger);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"notes/new.txt\",\"content\":\"alpha\\n\"}");
    defer write_call.deinit(std.testing.allocator);
    try std.testing.expectError(VAR1.core.tool_runtime.Error.FileNotInspected, VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, write_call));

    var missing_read_call = try makeToolCall(std.testing.allocator, "read_file", "{\"path\":\"notes/new.txt\"}");
    defer missing_read_call.deinit(std.testing.allocator);
    try std.testing.expectError(error.FileNotFound, VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, missing_read_call));

    const write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, write_call);
    defer std.testing.allocator.free(write_output);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"before_exists\":false") != null);

    var append_call = try makeToolCall(std.testing.allocator, "append_file", "{\"path\":\"notes/new.txt\",\"content\":\"beta\\n\"}");
    defer append_call.deinit(std.testing.allocator);
    const append_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, append_call);
    defer std.testing.allocator.free(append_output);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"before_exists\":true") != null);

    var replace_call = try makeToolCall(std.testing.allocator, "replace_in_file", "{\"path\":\"notes/new.txt\",\"old_text\":\"beta\",\"new_text\":\"gamma\"}");
    defer replace_call.deinit(std.testing.allocator);
    const replace_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, replace_call);
    defer std.testing.allocator.free(replace_output);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "\"replacements\":1") != null);
}

test "read ledger does not authorize adjacent file mutations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const first_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "notes", "first.txt" });
    defer std.testing.allocator.free(first_path);
    const second_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "notes", "second.txt" });
    defer std.testing.allocator.free(second_path);
    try VAR1.shared.fsutil.writeText(first_path, "alpha\n");
    try VAR1.shared.fsutil.writeText(second_path, "beta\n");

    var ledger = VAR1.core.tool_runtime.FileInspectionLedger.init(std.testing.allocator);
    defer ledger.deinit();
    const ctx = guardedExecCtx(workspace_root, &ledger);

    var read_first_call = try makeToolCall(std.testing.allocator, "read_file", "{\"path\":\"notes/first.txt\"}");
    defer read_first_call.deinit(std.testing.allocator);
    const read_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, read_first_call);
    defer std.testing.allocator.free(read_output);

    var replace_second_call = try makeToolCall(std.testing.allocator, "replace_in_file", "{\"path\":\"notes/second.txt\",\"old_text\":\"beta\",\"new_text\":\"delta\"}");
    defer replace_second_call.deinit(std.testing.allocator);
    try std.testing.expectError(VAR1.core.tool_runtime.Error.FileNotInspected, VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, replace_second_call));

    var append_missing_call = try makeToolCall(std.testing.allocator, "append_file", "{\"path\":\"notes/third.txt\",\"content\":\"new\\n\"}");
    defer append_missing_call.deinit(std.testing.allocator);
    try std.testing.expectError(VAR1.core.tool_runtime.Error.FileNotInspected, VAR1.core.tool_runtime.execute(std.testing.allocator, ctx, append_missing_call));
}

test "tool error envelope teaches read-before-write recovery" {
    const rendered = try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "write_file", "FileNotInspected", "{\"path\":\"notes/new.txt\",\"content\":\"x\"}");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"error\":\"FileNotInspected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Read the exact target with read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "FileNotFound result as absence proof") != null);
}

test "agent prompt carries file inspection and bounded wait guidance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const prompt = try VAR1.core.prompts.buildAgentSystemPrompt(std.testing.allocator, execCtx(workspace_root), .{});
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "inspect the exact target with read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "FileNotFound absence proof") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files and search_files discover paths but do not satisfy write inspection") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "wait_agent accepts timeout_ms") != null);
}

test "file tools reject undeclared arguments before side effects" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"notes/example.txt\",\"content\":\"alpha\",\"extra\":true}");
    defer write_call.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnknownField, VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), write_call));

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "notes", "example.txt" });
    defer std.testing.allocator.free(file_path);
    try std.testing.expect(!VAR1.shared.fsutil.fileExists(file_path));
}

test "file tools accept generated payloads above the former 8192 byte ceiling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const write_body = try std.testing.allocator.alloc(u8, 9 * 1024);
    defer std.testing.allocator.free(write_body);
    @memset(write_body, 'w');

    const write_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"notes/large.txt\",\"content\":{f}}}",
        .{std.json.fmt(write_body, .{})},
    );
    defer std.testing.allocator.free(write_args);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", write_args);
    defer write_call.deinit(std.testing.allocator);

    const write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), write_call);
    defer std.testing.allocator.free(write_output);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"bytes_written\":9216") != null);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "notes", "large.txt" });
    defer std.testing.allocator.free(file_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(file_path));

    const append_body = try std.testing.allocator.alloc(u8, 9 * 1024 + 17);
    defer std.testing.allocator.free(append_body);
    @memset(append_body, 'a');

    const append_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"notes/large.txt\",\"content\":{f}}}",
        .{std.json.fmt(append_body, .{})},
    );
    defer std.testing.allocator.free(append_args);

    var append_call = try makeToolCall(std.testing.allocator, "append_file", append_args);
    defer append_call.deinit(std.testing.allocator);
    const append_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), append_call);
    defer std.testing.allocator.free(append_output);
    try std.testing.expect(std.mem.indexOf(u8, append_output, "\"bytes_appended\":9233") != null);

    const replace_body = try std.testing.allocator.alloc(u8, 9 * 1024 + 33);
    defer std.testing.allocator.free(replace_body);
    @memset(replace_body, 'r');

    const replace_args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"notes/large.txt\",\"old_text\":{f},\"new_text\":{f}}}",
        .{ std.json.fmt(write_body, .{}), std.json.fmt(replace_body, .{}) },
    );
    defer std.testing.allocator.free(replace_args);

    var replace_call = try makeToolCall(std.testing.allocator, "replace_in_file", replace_args);
    defer replace_call.deinit(std.testing.allocator);
    const replace_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), replace_call);
    defer std.testing.allocator.free(replace_output);
    try std.testing.expect(std.mem.indexOf(u8, replace_output, "\"replacements\":1") != null);

    const contents = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, file_path);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, replace_body.len + append_body.len), contents.len);
    try std.testing.expect(std.mem.startsWith(u8, contents, replace_body));
    try std.testing.expect(std.mem.endsWith(u8, contents, append_body));
}

test "tool error envelope summarizes oversized failed arguments" {
    const oversized_content = try std.testing.allocator.alloc(u8, VAR1.core.tool_runtime.max_error_arguments_json_echo_bytes + 256);
    defer std.testing.allocator.free(oversized_content);
    @memset(oversized_content, 'z');

    const arguments_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"path\":\"notes/large.txt\",\"content\":{f}}}",
        .{std.json.fmt(oversized_content, .{})},
    );
    defer std.testing.allocator.free(arguments_json);

    const rendered = try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "write_file", "FileNotInspected", arguments_json);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"arguments_json_omitted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"arguments_json_bytes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"arguments_json_sha256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, oversized_content) == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Read the exact target with read_file") != null);
}

test "file tool catalog omits artificial content maxLength ceilings" {
    const catalog = try VAR1.core.tool_runtime.renderCatalog(std.testing.allocator, execCtx("."));
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"maxLength\": 8192") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "former 8192") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "resumable chunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Large replacements are allowed") != null);
}

test "list_files defaults to the workspace root and returns relative paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const std = @import(\"std\");\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/view.zig", .data = "pub fn render() void {}\n" });

    var list_call = try makeToolCall(std.testing.allocator, "list_files", "{\"max_results\":10}");
    defer list_call.deinit(std.testing.allocator);
    const list_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), list_call);
    defer std.testing.allocator.free(list_output);

    try std.testing.expect(std.mem.indexOf(u8, list_output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "src/nested/view.zig") != null);
}

test "search_files uses the command runner contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = MockCommandContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    var search_call = try makeToolCall(std.testing.allocator, "search_files", "{\"pattern\":\"read_file\",\"path\":\"src\",\"max_results\":5}");
    defer search_call.deinit(std.testing.allocator);
    const search_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtxWithProbe(workspace_root, mockCommandAvailable), search_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(search_output);

    try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "iex search --json --max-hits 5 read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, search_output, "src/main.zig:12:read_file") != null);
}

test "tool availability registry derives agent capabilities from the agent module" {
    const search_spec = VAR1.core.tools.registry.availabilitySpec("search_files").?;
    try std.testing.expect(search_spec.dependency != null);
    try std.testing.expectEqual(VAR1.core.tools.module.DependencyKind.external_command, search_spec.dependency.?.kind);
    try std.testing.expectEqualStrings("iex", search_spec.dependency.?.name);

    const agent_names = [_][]const u8{
        "launch_agent",
        "agent_status",
        "wait_agent",
        "list_agents",
    };
    for (agent_names) |name| {
        const agent_spec = VAR1.core.tools.registry.availabilitySpec(name);
        try std.testing.expect(agent_spec != null);
        try std.testing.expect(agent_spec.?.dependency == null);
    }

    try std.testing.expect(VAR1.core.tools.registry.availabilitySpec("missing_tool") == null);
}

test "tool review classifies capability risk before dispatch" {
    const file_definitions = VAR1.core.tool_runtime.builtinDefinitions(false);
    const agent_definitions = VAR1.core.tool_runtime.builtinDefinitions(true);
    const workspace_definitions = VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .workspace_state_enabled = true,
    });

    var read_call = try makeToolCall(std.testing.allocator, "read_file", "{\"path\":\"src/main.zig\"}");
    defer read_call.deinit(std.testing.allocator);
    const read_decision = VAR1.core.tool_runtime.review.reviewToolCall(read_call, file_definitions);
    try std.testing.expect(read_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.read_only, read_decision.risk);
    try std.testing.expectEqualStrings("tool_reviewed", read_decision.event_type);

    var write_call = try makeToolCall(std.testing.allocator, "write_file", "{\"path\":\"out.txt\",\"content\":\"ok\"}");
    defer write_call.deinit(std.testing.allocator);
    const write_decision = VAR1.core.tool_runtime.review.reviewToolCall(write_call, file_definitions);
    try std.testing.expect(write_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.write_capable, write_decision.risk);

    var launch_call = try makeToolCall(std.testing.allocator, "launch_agent", "{\"prompt\":\"inspect one file\"}");
    defer launch_call.deinit(std.testing.allocator);
    const launch_decision = VAR1.core.tool_runtime.review.reviewToolCall(launch_call, agent_definitions);
    try std.testing.expect(launch_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.delegating, launch_decision.risk);

    var unknown_call = try makeToolCall(std.testing.allocator, "unknown_tool", "{}");
    defer unknown_call.deinit(std.testing.allocator);
    const unknown_decision = VAR1.core.tool_runtime.review.reviewToolCall(unknown_call, agent_definitions);
    try std.testing.expect(!unknown_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.unknown_high_impact, unknown_decision.risk);
    try std.testing.expectEqualStrings("tool_blocked", unknown_decision.event_type);
    try std.testing.expect(unknown_decision.tool_error_hint != null);

    var context_unavailable_call = try makeToolCall(std.testing.allocator, "init_workspace", "{}");
    defer context_unavailable_call.deinit(std.testing.allocator);
    const context_unavailable_decision = VAR1.core.tool_runtime.review.reviewToolCall(context_unavailable_call, file_definitions);
    try std.testing.expect(!context_unavailable_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.unknown_high_impact, context_unavailable_decision.risk);

    const workspace_decision = VAR1.core.tool_runtime.review.reviewToolCall(context_unavailable_call, workspace_definitions);
    try std.testing.expect(workspace_decision.approved);
    try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.write_capable, workspace_decision.risk);

    const event = try VAR1.core.tool_runtime.review.renderReviewEvent(std.testing.allocator, unknown_call, unknown_decision);
    defer std.testing.allocator.free(event);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"schema\":\"var1.tool_review.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"approved\":false") != null);

    const blocked = try VAR1.core.tool_runtime.review.renderBlockedToolResult(std.testing.allocator, unknown_call, unknown_decision);
    defer std.testing.allocator.free(blocked);
    try std.testing.expect(std.mem.indexOf(u8, blocked, "\"error\":\"ToolReviewBlocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked, "Unknown tool names are blocked before execution") != null);
}

test "agent capability profiles and delegation scopes bound child launch" {
    const subagent = try VAR1.core.agent_profile.resolveProfile("subagent");
    try std.testing.expect(VAR1.core.agent_profile.allowsToolClass(subagent, .delegation));
    try std.testing.expect(!VAR1.core.agent_profile.allowsToolClass(subagent, .workspace_state));

    try VAR1.core.agent_scope.validateDelegationScope(.{}, subagent);
    try VAR1.core.agent_scope.validateDelegationScope(.{
        .scope_depth = 2,
        .contact_budget = 3,
        .validation_status = .self_checked,
        .escalation_reason = "parallel file-level contract audit",
        .parent_capability_profile = "root",
    }, subagent);
    try std.testing.expectError(VAR1.core.agent_scope.Error.UnsupportedDelegationScope, VAR1.core.agent_scope.validateDelegationScope(.{
        .scope_depth = 2,
    }, subagent));
    try std.testing.expectError(VAR1.core.agent_profile.Error.UnsupportedCapabilityProfile, VAR1.core.agent_profile.resolveProfile("recursive_mas"));
}

test "agent tools use the agent service contract and surface agent tool catalog" {
    var context = MockAgentContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const execution_context = VAR1.core.tool_runtime.ExecutionContext{
        .workspace_root = ".",
        .parent_session_id = "session-parent",
        .agent_service = .{
            .context = &context,
            .launchFn = mockLaunchAgent,
            .statusFn = mockAgentStatus,
            .waitFn = mockWaitAgent,
            .listFn = mockListAgents,
            .convergeFn = mockConvergeBranches,
            .reconcileFn = mockReconcileShards,
        },
    };

    const catalog = try VAR1.core.tool_runtime.renderCatalog(std.testing.allocator, execution_context);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "launch_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "wait_agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "branchable work") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "SITREP") != null);

    var launch_call = try makeToolCall(std.testing.allocator, "launch_agent", "{\"prompt\":\"how many r in strawberry\",\"name\":\"berry-child\"}");
    defer launch_call.deinit(std.testing.allocator);
    const launch_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, launch_call);
    defer std.testing.allocator.free(launch_output);
    try std.testing.expect(std.mem.indexOf(u8, launch_output, "berry-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.last_prompt.?, "strawberry") != null);
    try std.testing.expect(std.mem.indexOf(u8, launch_output, "CAPABILITY_PROFILE subagent") != null);
    try std.testing.expectEqual(@as(usize, 1), context.last_scope.scope_depth);
    try std.testing.expectEqual(@as(usize, 1), context.last_scope.contact_budget);

    var scoped_launch_call = try makeToolCall(std.testing.allocator, "launch_agent", "{\"prompt\":\"audit scoped files\",\"name\":\"scoped-child\",\"scope_depth\":2,\"contact_budget\":3,\"validation_status\":\"self_checked\",\"escalation_reason\":\"parallel file-level contract audit\",\"parent_capability_profile\":\"root\"}");
    defer scoped_launch_call.deinit(std.testing.allocator);
    const scoped_launch_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, scoped_launch_call);
    defer std.testing.allocator.free(scoped_launch_output);
    try std.testing.expect(std.mem.indexOf(u8, scoped_launch_output, "SCOPE_DEPTH 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped_launch_output, "CONTACT_BUDGET 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, scoped_launch_output, "VALIDATION_STATUS self_checked") != null);
    try std.testing.expectEqual(@as(usize, 2), context.last_scope.scope_depth);
    try std.testing.expectEqual(@as(usize, 3), context.last_scope.contact_budget);

    var blocked_launch_call = try makeToolCall(std.testing.allocator, "launch_agent", "{\"prompt\":\"expand without reason\",\"scope_depth\":2}");
    defer blocked_launch_call.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedDelegationScope, VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, blocked_launch_call));

    var status_call = try makeToolCall(std.testing.allocator, "agent_status", "{\"name\":\"berry-child\"}");
    defer status_call.deinit(std.testing.allocator);
    const status_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, status_call);
    defer std.testing.allocator.free(status_output);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LATEST_EVENT_TYPE tool_completed") != null);

    var wait_call = try makeToolCall(std.testing.allocator, "wait_agent", "{\"name\":\"berry-child\",\"timeout_ms\":500}");
    defer wait_call.deinit(std.testing.allocator);
    const wait_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, wait_call);
    defer std.testing.allocator.free(wait_output);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "There are 3 r's") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "WAIT_STATE terminal") != null);

    var list_call = try makeToolCall(std.testing.allocator, "list_agents", "{}");
    defer list_call.deinit(std.testing.allocator);
    const list_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execution_context, list_call);
    defer std.testing.allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "AGENT_NAME berry-child") != null);
}

test "workspace-state tools scaffold and manage canonical root artifacts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var init_call = try makeToolCall(std.testing.allocator, "init_workspace", "{}");
    defer init_call.deinit(std.testing.allocator);
    const init_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), init_call);
    defer std.testing.allocator.free(init_output);
    try std.testing.expect(std.mem.indexOf(u8, init_output, "FILES_WRITTEN") != null);

    const workspace_state_readme = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "README.md" });
    defer std.testing.allocator.free(workspace_state_readme);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(workspace_state_readme));

    var session_call = try makeToolCall(
        std.testing.allocator,
        "session_record",
        "{\"action\":\"upsert\",\"session_name\":\"demo-session\",\"status\":\"in_progress\",\"objective\":\"Finalize the workspace-state runtime.\",\"scope\":[\"add missing tools\"],\"evidence_roots\":[\"src\",\"tests\"]}",
    );
    defer session_call.deinit(std.testing.allocator);
    const session_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), session_call);
    defer std.testing.allocator.free(session_output);
    try std.testing.expect(std.mem.indexOf(u8, session_output, "demo-session") != null);

    var todo_call = try makeToolCall(
        std.testing.allocator,
        "todo_slice",
        "{\"action\":\"upsert\",\"category\":\"feature\",\"todo_name\":\"demo-todo\",\"status\":\"done\",\"objective\":\"Ship the workspace-state tools.\",\"dependencies\":[\"none\"],\"steps_taken\":[\"wired the runtime\"],\"blockers\":[],\"evidence\":[\"tests green\"]}",
    );
    defer todo_call.deinit(std.testing.allocator);
    const todo_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), todo_call);
    defer std.testing.allocator.free(todo_output);
    try std.testing.expect(std.mem.indexOf(u8, todo_output, "todo-slice1.md") != null);

    var changelog_call = try makeToolCall(
        std.testing.allocator,
        "changelog_ledger",
        "{\"action\":\"archive_todo\",\"category\":\"feature\",\"todo_name\":\"demo-todo\",\"slice_name\":\"todo-slice1.md\",\"log_entry\":\"- Completed demo-todo tool finalization.\"}",
    );
    defer changelog_call.deinit(std.testing.allocator);
    const changelog_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), changelog_call);
    defer std.testing.allocator.free(changelog_output);
    try std.testing.expect(std.mem.indexOf(u8, changelog_output, "ARCHIVED_TO") != null);

    const archived_todo = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "changelog", "demo-todo", "todo-slice1.md" });
    defer std.testing.allocator.free(archived_todo);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(archived_todo));

    var memories_append = try makeToolCall(
        std.testing.allocator,
        "memory_write",
        "{\"operation\":\"remember\",\"scope\":\"global\",\"kind\":\"lesson\",\"topic\":\"workspace-state-boundary\",\"content\":\"Root workspace-state tools stay inside .var/.\",\"trigger\":\"agent_decided\",\"activation\":\"relevant\"}",
    );
    defer memories_append.deinit(std.testing.allocator);
    const memories_append_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), memories_append);
    defer std.testing.allocator.free(memories_append_output);
    try std.testing.expect(std.mem.indexOf(u8, memories_append_output, "\"ok\":true") != null);

    var memories_read = try makeToolCall(std.testing.allocator, "memory_read", "{\"scope\":\"global\",\"query\":\"workspace state boundary\"}");
    defer memories_read.deinit(std.testing.allocator);
    const memories_read_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), memories_read);
    defer std.testing.allocator.free(memories_read_output);
    try std.testing.expect(std.mem.indexOf(u8, memories_read_output, "Root workspace-state tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, memories_read_output, ".var/") != null);

    var research_write = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"write\",\"surface\":\"research\",\"path\":\"snapshot.md\",\"title\":\"Snapshot\",\"content\":\"U1 runtime snapshot\"}",
    );
    defer research_write.deinit(std.testing.allocator);
    const research_write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), research_write);
    defer std.testing.allocator.free(research_write_output);
    try std.testing.expect(std.mem.indexOf(u8, research_write_output, "snapshot.md") != null);

    var docs_write = try makeToolCall(
        std.testing.allocator,
        "docs_artifact",
        "{\"action\":\"write\",\"path\":\"extra.md\",\"content\":\"# Extra\\n\\nContract note.\"}",
    );
    defer docs_write.deinit(std.testing.allocator);
    const docs_write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), docs_write);
    defer std.testing.allocator.free(docs_write_output);
    try std.testing.expect(std.mem.indexOf(u8, docs_write_output, "extra.md") != null);
}

test "workspace scaffold creates knowledge surfaces and knowledge_artifact reads writes and lists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var init_call = try makeToolCall(std.testing.allocator, "init_workspace", "{}");
    defer init_call.deinit(std.testing.allocator);
    const init_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), init_call);
    defer std.testing.allocator.free(init_output);
    try std.testing.expect(std.mem.indexOf(u8, init_output, "FILES_WRITTEN") != null);

    // The three new knowledge surfaces must exist after scaffolding.
    const plans_readme = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "plans", "README.md" });
    defer std.testing.allocator.free(plans_readme);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(plans_readme));

    const advice_readme = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "advice", "README.md" });
    defer std.testing.allocator.free(advice_readme);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(advice_readme));

    const roadmap_readme = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "roadmap", "README.md" });
    defer std.testing.allocator.free(roadmap_readme);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(roadmap_readme));

    // Write a research artifact through knowledge_artifact.
    var write_call = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"write\",\"surface\":\"research\",\"path\":\"never-wait.md\",\"title\":\"Never-Wait Mechanics\",\"content\":\"The yield-queue injects results as a new turn.\"}",
    );
    defer write_call.deinit(std.testing.allocator);
    const write_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), write_call);
    defer std.testing.allocator.free(write_output);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "SURFACE research") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_output, "never-wait.md") != null);

    // Read it back.
    var read_call = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"read\",\"surface\":\"research\",\"path\":\"never-wait.md\"}",
    );
    defer read_call.deinit(std.testing.allocator);
    const read_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), read_call);
    defer std.testing.allocator.free(read_output);
    try std.testing.expect(std.mem.indexOf(u8, read_output, "yield-queue injects results") != null);

    // Write a plan artifact to a different surface.
    var plan_call = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"write\",\"surface\":\"plans\",\"path\":\"inbox-drain.md\",\"content\":\"# Inbox Drain Plan\\n\\nStep 1: add per-parent inbox.\"}",
    );
    defer plan_call.deinit(std.testing.allocator);
    const plan_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), plan_call);
    defer std.testing.allocator.free(plan_output);
    try std.testing.expect(std.mem.indexOf(u8, plan_output, "SURFACE plans") != null);

    // List the research surface — must show never-wait.md.
    var list_call = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"list\",\"surface\":\"research\"}",
    );
    defer list_call.deinit(std.testing.allocator);
    const list_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), list_call);
    defer std.testing.allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "SURFACE research") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "never-wait.md") != null);

    // Reject an unknown surface.
    var bad_surface_call = try makeToolCall(
        std.testing.allocator,
        "knowledge_artifact",
        "{\"action\":\"list\",\"surface\":\"unknown\"}",
    );
    defer bad_surface_call.deinit(std.testing.allocator);
    const bad_surface_output = VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), bad_surface_call);
    try std.testing.expectError(error.InvalidArguments, bad_surface_output);
}

test "instruction_ingestion resolves the applicable AGENTS chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try tmp.dir.makePath("apps/feature");
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "root agents\n" });
    try tmp.dir.writeFile(.{ .sub_path = "apps/feature/AGENTS.md", .data = "feature agents\n" });

    var ingest_call = try makeToolCall(
        std.testing.allocator,
        "instruction_ingestion",
        "{\"mode\":\"session-start\",\"target_path\":\"apps/feature\"}",
    );
    defer ingest_call.deinit(std.testing.allocator);
    const ingest_output = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), ingest_call);
    defer std.testing.allocator.free(ingest_output);

    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "MODE session-start") != null);
    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "root agents") != null);
    try std.testing.expect(std.mem.indexOf(u8, ingest_output, "feature agents") != null);
}

test "backup and worktree workspace-state tools use the command runner contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var backup_context = RecorderCommandContext{ .allocator = std.testing.allocator };
    defer backup_context.deinit();

    var backup_call = try makeToolCall(std.testing.allocator, "workspace_backup", "{\"label\":\"checkpoint\"}");
    defer backup_call.deinit(std.testing.allocator);
    const backup_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), backup_call, .{
        .context = &backup_context,
        .runFn = mockBackupRunner,
    });
    defer std.testing.allocator.free(backup_output);

    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, backup_context.last_command.?, "Compress-Archive") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, backup_context.last_command.?, "zip -r") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, backup_output, "checkpoint") != null);

    var worktree_context = RecorderCommandContext{ .allocator = std.testing.allocator };
    defer worktree_context.deinit();

    var worktree_call = try makeToolCall(std.testing.allocator, "git_worktree", "{\"action\":\"status\"}");
    defer worktree_call.deinit(std.testing.allocator);
    const worktree_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), worktree_call, .{
        .context = &worktree_context,
        .runFn = mockNonGitRunner,
    });
    defer std.testing.allocator.free(worktree_output);

    try std.testing.expect(std.mem.indexOf(u8, worktree_context.last_command.?, "rev-parse") != null);
    try std.testing.expect(std.mem.indexOf(u8, worktree_output, "WORKTREE_STATUS disabled") != null);
}

test "tool execution errors include schema guidance for todo slice calls" {
    const error_payload = try VAR1.core.tool_runtime.renderExecutionError(
        std.testing.allocator,
        "todo_slice",
        "InvalidArguments",
        "{\"action\":\"upsert\"}",
    );
    defer std.testing.allocator.free(error_payload);

    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"arguments_json\":\"{\\\"action\\\":\\\"upsert\\\"}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "runtime-managed todo slice") != null);
}

test "tool execution errors include search_files contract details for file-not-found loops" {
    const error_payload = try VAR1.core.tool_runtime.renderExecutionError(
        std.testing.allocator,
        "search_files",
        "FileNotFound",
        "{\"pattern\":\"read_file\",\"path\":\"missing\"}",
    );
    defer std.testing.allocator.free(error_payload);

    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "\"contract_example\":\"{\\\"pattern\\\":\\\"read_file\\\",\\\"path\\\":\\\"src\\\",\\\"glob\\\":\\\"*.zig\\\",\\\"max_results\\\":20}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "Use list_files first when unsure") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_payload, "iex executable") != null);
}

test "shell_exec forwards stdout stderr and cap deltas through the tool event sink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var capture = OutputDeltaCapture{};
    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"argv\",\"argv\":[\"fake\",\"arg\"],\"max_output_bytes\":5}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, .{
        .workspace_root = workspace_root,
        .tool_events = .{
            .context = &capture,
            .onOutputDeltaFn = captureToolOutputDelta,
        },
    }, shell_call, .{
        .context = null,
        .runFn = mockCommandRunner,
        .runWithLimitsFn = mockStreamingShellRunner,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stdout\":\"alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stderr\":\"warn\"") != null);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
    try std.testing.expectEqualStrings("call-1", capture.records[0].tool_call_id);
    try std.testing.expectEqualStrings("shell_exec", capture.records[0].tool_name);
    try std.testing.expectEqual(VAR1.core.tool_runtime.CommandOutputStream.stdout, capture.records[0].stream);
    try std.testing.expectEqualStrings("alpha", capture.records[0].chunk);
    try std.testing.expect(!capture.records[0].cap_reached);
    try std.testing.expectEqual(VAR1.core.tool_runtime.CommandOutputStream.stderr, capture.records[1].stream);
    try std.testing.expectEqualStrings("warn", capture.records[1].chunk);
    try std.testing.expectEqual(VAR1.core.tool_runtime.CommandOutputStream.stdout, capture.records[2].stream);
    try std.testing.expectEqualStrings("", capture.records[2].chunk);
    try std.testing.expect(capture.records[2].cap_reached);

    // The typed truncation marker must appear in the tool output JSON.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"truncated\":true") != null);
}

test "shell_exec rejects contradictory command shapes before process launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const cases = [_][]const u8{
        "{\"mode\":\"argv\",\"argv\":[]}",
        "{\"mode\":\"argv\",\"command\":\"echo no\",\"argv\":[\"echo\",\"no\"]}",
        "{\"mode\":\"shell\",\"argv\":[\"echo\",\"no\"]}",
        "{\"mode\":\"shell\",\"command\":\"   \\t\\n\"}",
    };

    for (cases) |arguments_json| {
        var context = CountingRunnerContext{};
        var shell_call = try makeToolCall(std.testing.allocator, "shell_exec", arguments_json);
        defer shell_call.deinit(std.testing.allocator);

        const result = VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), shell_call, .{
            .context = &context,
            .runFn = mockCountingRunner,
            .runWithLimitsFn = mockCountingLimitedRunner,
        });
        try std.testing.expectError(error.InvalidArguments, result);
        try std.testing.expectEqual(@as(usize, 0), context.calls);
    }
}

test "shell_exec rejects cwd escape before process launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = CountingRunnerContext{};
    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"argv\",\"argv\":[\"echo\",\"no\"],\"cwd\":\"..\"}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const result = VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), shell_call, .{
        .context = &context,
        .runFn = mockCountingRunner,
        .runWithLimitsFn = mockCountingLimitedRunner,
    });
    try std.testing.expectError(error.PathOutsideWorkspace, result);
    try std.testing.expectEqual(@as(usize, 0), context.calls);
}

test "shell_exec clamps command limits before runner dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = CountingRunnerContext{};
    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"argv\",\"argv\":[\"fake\"],\"timeout_ms\":999999,\"max_output_bytes\":999999}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), shell_call, .{
        .context = &context,
        .runFn = mockCountingRunner,
        .runWithLimitsFn = mockCountingLimitedRunner,
    });
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(usize, 60_000), context.timeout_ms);
    try std.testing.expectEqual(@as(usize, 64 * 1024), context.max_output_bytes);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stdout\":\"ok\"") != null);
}

test "shell_exec dispatches argv and Windows shell modes through distinct command shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = MockCommandContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    var argv_call = try makeToolCall(std.testing.allocator, "shell_exec", "{\"mode\":\"argv\",\"argv\":[\"node\",\"--version\"],\"cwd\":\".\"}");
    defer argv_call.deinit(std.testing.allocator);
    const argv_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), argv_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(argv_output);
    try std.testing.expectEqualStrings("node --version", context.last_command.?);

    var powershell_call = try makeToolCall(std.testing.allocator, "shell_exec", "{\"mode\":\"powershell\",\"command\":\"(Select-String -Path 'tests/*.zig' -Pattern 'test').Count\",\"cwd\":\".\"}");
    defer powershell_call.deinit(std.testing.allocator);
    const powershell_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), powershell_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(powershell_output);
    try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "Select-String") != null);

    var shell_call = try makeToolCall(std.testing.allocator, "shell_exec", "{\"mode\":\"shell\",\"command\":\"Get-ChildItem -Name\",\"cwd\":\".\"}");
    defer shell_call.deinit(std.testing.allocator);
    const shell_output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtx(workspace_root), shell_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    });
    defer std.testing.allocator.free(shell_output);
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command") != null);
        try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "Get-ChildItem") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, context.last_command.?, "/bin/sh -lc") != null);
    }
}

test "tool execution errors expose specialized repair hints across failure classes" {
    const cases = [_]struct {
        tool: []const u8,
        error_name: []const u8,
        args: []const u8,
        expected: []const u8,
    }{
        .{ .tool = "shell_exec", .error_name = "CommandTimedOut", .args = "{\"mode\":\"argv\",\"argv\":[\"slow\"]}", .expected = "timeout_ms" },
        .{ .tool = "shell_exec", .error_name = "ToolPayloadExceeded", .args = "{\"mode\":\"argv\",\"argv\":[\"loud\"]}", .expected = "stdout/stderr capture budget" },
        .{ .tool = "shell_exec", .error_name = "FileNotFound", .args = "{\"mode\":\"argv\",\"argv\":[\"missing\"]}", .expected = "argv[0]" },
        .{ .tool = "write_file", .error_name = "ToolPayloadExceeded", .args = "{\"path\":\"big.txt\",\"content\":\"...\"}", .expected = "append_file chunks" },
        .{ .tool = "replace_in_file", .error_name = "PathOutsideWorkspace", .args = "{\"path\":\"..\\\\x\",\"old_text\":\"a\",\"new_text\":\"b\"}", .expected = "workspace-relative path" },
    };

    for (cases) |case| {
        const output = try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, case.tool, case.error_name, case.args);
        defer std.testing.allocator.free(output);

        try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":false") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\"hint\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, output, case.expected) != null);
    }
}

test "catalog keeps workspace-state tools out of normal coding contexts" {
    const catalog = try VAR1.core.tool_runtime.renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "skill_info") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") == null);
}

test "skill_info exposes native skill capsules without workspace path escape" {
    var exact_call = try makeToolCall(std.testing.allocator, "skill_info", "{\"name\":\"planning-spec\"}");
    defer exact_call.deinit(std.testing.allocator);

    const exact = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx("."), exact_call);
    defer std.testing.allocator.free(exact);

    try std.testing.expect(std.mem.indexOf(u8, exact, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact, "SKILL planning-spec") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact, "TIER native") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact, "cold-start handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, exact, "todo_chain_templates.md") != null);

    var insect_call = try makeToolCall(std.testing.allocator, "skill_info", "{\"name\":\"insect\"}");
    defer insect_call.deinit(std.testing.allocator);

    const insect = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx("."), insect_call);
    defer std.testing.allocator.free(insect);

    try std.testing.expect(std.mem.indexOf(u8, insect, "SKILL insect") != null);
    try std.testing.expect(std.mem.indexOf(u8, insect, "insect-rs-runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, insect, "run-insect-rs.ps1") != null);
    try std.testing.expect(std.mem.indexOf(u8, insect, "engine --query") != null);

    var query_call = try makeToolCall(std.testing.allocator, "skill_info", "{\"query\":\"scrape\",\"include_addons\":false}");
    defer query_call.deinit(std.testing.allocator);

    const query = try VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx("."), query_call);
    defer std.testing.allocator.free(query);

    try std.testing.expect(std.mem.indexOf(u8, query, "NATIVE SKILLS") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "insect") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "ADDON SKILLS") == null);
}

test "catalog enables workspace-state tools only for workspace-state contexts" {
    const catalog = try VAR1.core.tool_runtime.renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
        .workspace_state_enabled = true,
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "init_workspace") != null);
}

test "catalog json exposes schema and example objects for default coding tools" {
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"workspace_root\":\".\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"skill_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"parameters_schema\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"type\": \"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"contract_example\":{\"path\":\"src/core/tools/runtime.zig\",\"start_line\":1,\"end_line\":80}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"usage_hint\":\"Pass a file path, not a directory.") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"availability\":{\"status\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"todo_slice\"") == null);
}

test "catalog json exposes shell_exec command-shape and Windows query guidance" {
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"shell_exec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"enum\": [\"shell\", \"bash\", \"powershell\", \"argv\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"contract_example\":{\"mode\":\"argv\",\"argv\":[\"zig\",\"version\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Use mode=argv with argv only") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "mode=powershell/shell/bash with command only") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Select-String/Get-ChildItem") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "find/findstr") != null);
}

test "shell_exec schema error output is self-repairing before process launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var shell_call = try makeToolCall(std.testing.allocator, "shell_exec", "{\"mode\":\"shell\",\"argv\":[\"cmd\",\"/c\",\"find\"]}");
    defer shell_call.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidArguments, VAR1.core.tool_runtime.execute(std.testing.allocator, execCtx(workspace_root), shell_call));

    const error_output = try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, shell_call.name, "InvalidArguments", shell_call.arguments_json);
    defer std.testing.allocator.free(error_output);

    try std.testing.expect(std.mem.indexOf(u8, error_output, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "\"parameters_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "\"usage_hint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "\"hint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "Use mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, error_output, "Select-String") != null);
}

test "catalog json reports unavailable command-backed tools explicitly" {
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, execCtxWithProbe(".", mockCommandUnavailable));
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"availability\":{\"status\":\"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"kind\":\"external_command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"iex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"available\":false") != null);
}

test "availability registry uses builtin module-owned names" {
    const search_spec = VAR1.core.tools.registry.availabilitySpec("search_files").?;
    try std.testing.expect(search_spec.dependency != null);
    try std.testing.expectEqual(VAR1.core.tools.module.DependencyKind.external_command, search_spec.dependency.?.kind);
    try std.testing.expectEqualStrings("iex", search_spec.dependency.?.name);

    const agent_spec = VAR1.core.tools.registry.availabilitySpec("launch_agent").?;
    try std.testing.expect(agent_spec.dependency == null);

    const skill_spec = VAR1.core.tools.registry.availabilitySpec("skill_info").?;
    try std.testing.expect(skill_spec.dependency == null);
}

test "catalog json reports available command-backed tools when dependency resolves" {
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, execCtxWithProbe(".", mockCommandAvailable));
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"availability\":{\"status\":\"available\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"iex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"available\":true") != null);
}

test "catalog json rejects an iex binary that does not expose the IX search contract" {
    var shape_context = IxShapeProbeContext{ .available = false };
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, execCtxWithShapeProbe(".", &shape_context));
    defer std.testing.allocator.free(catalog);

    try std.testing.expectEqual(@as(usize, 1), shape_context.calls);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"availability\":{\"status\":\"unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"iex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"available\":false") != null);
}

test "catalog json advertises search only after the iex search shape probe passes" {
    var shape_context = IxShapeProbeContext{ .available = true };
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, execCtxWithShapeProbe(".", &shape_context));
    defer std.testing.allocator.free(catalog);

    try std.testing.expectEqual(@as(usize, 1), shape_context.calls);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"search_files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"availability\":{\"status\":\"available\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"available\":true") != null);
}

test "search_files stops before execution when iex is unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var context = MockCommandContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    var search_call = try makeToolCall(std.testing.allocator, "search_files", "{\"pattern\":\"read_file\",\"path\":\".\",\"max_results\":5}");
    defer search_call.deinit(std.testing.allocator);

    try std.testing.expectError(error.ToolUnavailable, VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, execCtxWithProbe(workspace_root, mockCommandUnavailable), search_call, .{
        .context = &context,
        .runFn = mockCommandRunner,
    }));
    try std.testing.expect(context.last_command == null);
}

test "agent system prompt teaches schema repair and file-tool roles" {
    const prompt = try VAR1.core.prompts.buildAgentSystemPrompt(std.testing.allocator, .{
        .workspace_root = ".",
    }, .{});
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Internal Runtime Guardrails") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files discovers paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "search_files locates symbols or text") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "IX/IEX expression engine") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Do not invent rg flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "branchable tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "required SITREP") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "one canonical parent-owned conclusion") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "messages.jsonl remains transcript truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Keep hidden runtime mechanics private") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "wait_agent accepts timeout_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use mode=argv with argv only") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "mode=powershell/shell/bash with command only") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Select-String/Get-ChildItem") != null);
}

test "orchestrator prompt requires compact discovery and signal-driven continuation" {
    const prompt = try VAR1.core.prompts.buildAgentSystemPrompt(std.testing.allocator, .{
        .workspace_root = ".",
        .orchestrator_only = true,
    }, .{});
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Your first tool call must be agents with {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "private child instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "I'll pick up as soon as an agent reports back.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "wakes on the first ready child result") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "checkpoint what converged and immediately route the next bounded slice") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "a checkpoint is continuation evidence, not a final answer") != null);
}

test "tool call summary masks child supervision tool names in logs" {
    var calls = [_]VAR1.shared.types.ToolCall{
        try makeToolCall(std.testing.allocator, "launch_agent", "{}"),
        try makeToolCall(std.testing.allocator, "wait_agent", "{}"),
        try makeToolCall(std.testing.allocator, "read_file", "{}"),
    };
    defer for (calls) |call| call.deinit(std.testing.allocator);

    const summary = try VAR1.core.tool_runtime.renderToolCallSummary(std.testing.allocator, calls[0..]);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(std.mem.indexOf(u8, summary, "child_run_dispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "child_run_wait") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "launch_agent") == null);
}

fn mockTimeoutRunner(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
    limits: VAR1.core.tool_runtime.CommandLimits,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    _ = limits;
    // Simulate a command that produced partial output before timing out.
    return .{
        .exit_code = 1,
        .stdout = try allocator.dupe(u8, "partial"),
        .stderr = try allocator.dupe(u8, ""),
        .timed_out = true,
        .truncated = false,
    };
}

test "shell_exec surfaces typed timeout evidence in the tool result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"argv\",\"argv\":[\"slow-command\"],\"timeout_ms\":100}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, .{
        .workspace_root = workspace_root,
    }, shell_call, .{
        .context = null,
        .runFn = mockCommandRunner,
        .runWithLimitsFn = mockTimeoutRunner,
    });
    defer std.testing.allocator.free(output);

    // The timeout evidence must be typed in the JSON output.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"exit_code\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"stdout\":\"partial\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"truncated\":false") != null);
}

fn mockTruncatedAndTimedOutRunner(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const []const u8,
    limits: VAR1.core.tool_runtime.CommandLimits,
) anyerror!VAR1.core.tool_runtime.CommandOutput {
    _ = limits;
    // Simulate a command that exceeded both the output budget and the timeout.
    return .{
        .exit_code = 1,
        .stdout = try allocator.dupe(u8, "big"),
        .stderr = try allocator.dupe(u8, "err"),
        .timed_out = true,
        .truncated = true,
    };
}

test "shell_exec surfaces both truncation and timeout evidence simultaneously" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"argv\",\"argv\":[\"huge-slow\"],\"timeout_ms\":50,\"max_output_bytes\":3}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = try VAR1.core.tool_runtime.executeWithRunner(std.testing.allocator, .{
        .workspace_root = workspace_root,
    }, shell_call, .{
        .context = null,
        .runFn = mockCommandRunner,
        .runWithLimitsFn = mockTruncatedAndTimedOutRunner,
    });
    defer std.testing.allocator.free(output);

    // Both evidence markers must be present and typed.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"truncated\":true") != null);
}

test "shell_exec kills child process tree on timeout (Windows Job Object)" {
    // This is a real process test, not a mock. It verifies that a command
    // that exceeds the timeout is killed cleanly. On Windows, the Job Object
    // with KILL_ON_JOB_CLOSE ensures the entire process tree dies.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Use Start-Sleep to create a long-running process that exceeds the
    // timeout. The Job Object with KILL_ON_JOB_CLOSE must kill it.
    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"shell\",\"command\":\"Start-Sleep -Seconds 10\",\"timeout_ms\":500}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = VAR1.core.tool_runtime.execute(std.testing.allocator, .{
        .workspace_root = workspace_root,
    }, shell_call) catch |err| {
        // A CommandTimedOut error is also valid — the process was killed.
        if (err == error.CommandTimedOut) return;
        return err;
    };
    defer std.testing.allocator.free(output);

    // The command must have been killed — either timed_out or an error.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timed_out\":true") != null);
}

test "shell_exec drains pipe after cap to prevent deadlock (bounded draining)" {
    // This is a real process test: a command that writes more than
    // max_output_bytes to stdout. Without continued draining after the cap,
    // the process would block on a full pipe buffer and never exit.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Generate 64KB of output (larger than typical pipe buffer of 4KB-8KB)
    // with a very small max_output_bytes to force the cap. The timeout is a
    // generous bound (this fixture's 10000-iteration Write-Host loop measures
    // ~15s on loaded Windows hardware) — the assertions under test are the
    // truncation cap and the deadlock-free completion, not the timeout.
    var shell_call = try makeToolCall(
        std.testing.allocator,
        "shell_exec",
        "{\"mode\":\"shell\",\"command\":\"1..10000 | ForEach-Object { Write-Host ('x' * 100) }\",\"timeout_ms\":30000,\"max_output_bytes\":100}",
    );
    defer shell_call.deinit(std.testing.allocator);

    const output = try VAR1.core.tool_runtime.execute(std.testing.allocator, .{
        .workspace_root = workspace_root,
    }, shell_call);
    defer std.testing.allocator.free(output);

    // The command must complete (not hang/deadlock) and show truncation.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"timed_out\":false") != null);
}
