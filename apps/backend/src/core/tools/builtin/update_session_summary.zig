const std = @import("std");

const fsutil = @import("../../../shared/fsutil.zig");
const store = @import("../../sessions/store.zig");
const summaries = @import("../../sessions/summaries.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "update_session_summary",
    .description = "Write or replace this session's permanent <=100-word summary in the session summary ledger (.var/sessions/summaries.json). MANDATORY before your turn ends — every session, including subagents, must leave a fresh summary so the timeline of all sessions stays truthful. The ledger is globally readable by every VANTARI session via session_summaries, so your summary is your session's handoff record for other agents and future cold starts. Capture: objective, key decisions, work completed, open threads, and next steps — under 100 words. If a turn ends without this call, the kernel writes a truncated fallback, visible in the ledger as source:kernel_fallback.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "summary": { "type": "string", "minLength": 1, "maxLength": 4096, "description": "Session summary. Required. At most 100 words — exceeding the cap is rejected." },
    \\    "title": { "type": "string", "minLength": 1, "maxLength": 128, "description": "Short one-line title for the session timeline. Optional; derives from the summary when absent." },
    \\    "topic": { "type": "string", "minLength": 1, "maxLength": 128, "description": "Optional topic tag, e.g. agents, context, tui." }
    \\  },
    \\  "required": ["summary"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"summary\":\"Implemented the session summary ledger: durable 100-word rows per session, mandatory pre-turn-end update, kernel fallback on violation. Next: wire docs and changelog.\",\"title\":\"Session summary ledger\",\"topic\":\"sessions\"}",
    .usage_hint = "Call this as the final step before your turn ends. The summary must be under 100 words and capture objective, key decisions, completed work, open threads, and next steps. It replaces the previous summary for this session.",
};

pub const availability = module.AvailabilitySpec{};

const Args = struct {
    summary: ?[]const u8 = null,
    title: ?[]const u8 = null,
    topic: ?[]const u8 = null,
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const session_id = execution_context.session_id orelse return module.Error.InvalidArguments;

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();

    const summary = std.mem.trim(u8, parsed.value.summary orelse return module.Error.InvalidArguments, " \t\r\n");
    if (summary.len == 0) return module.Error.InvalidArguments;
    if (summary.len > summaries.max_summary_bytes) return module.Error.ToolPayloadExceeded;
    if (summaries.countWords(summary) > summaries.max_summary_words) return module.Error.InvalidArguments;

    const title = std.mem.trim(u8, parsed.value.title orelse "", " \t\r\n");
    const topic = std.mem.trim(u8, parsed.value.topic orelse "", " \t\r\n");

    // The row's status field mirrors the session record so the timeline shows
    // truthful lifecycle state, not a stale snapshot.
    var status: []const u8 = "";
    var session_record = store.readSessionRecord(allocator, execution_context.workspace_root, session_id) catch null;
    defer if (session_record) |*record| record.deinit(allocator);
    if (session_record) |record| status = types.statusLabel(record.status);

    const turn_count = try summaries.upsertSummary(
        allocator,
        execution_context.workspace_root,
        session_id,
        execution_context.parent_session_id orelse "",
        title,
        topic,
        summary,
        status,
        "agent",
        std.time.milliTimestamp(),
    );

    const ledger_path = try summaries.summariesFilePath(allocator, execution_context.workspace_root);
    defer allocator.free(ledger_path);

    const receipt = try std.fmt.allocPrint(
        allocator,
        "{{\"session_id\":{f},\"words\":{d},\"turn_count\":{d},\"ledger_path\":{f},\"schema\":{f}}}",
        .{
            std.json.fmt(session_id, .{}),
            summaries.countWords(summary),
            turn_count,
            std.json.fmt(ledger_path, .{}),
            std.json.fmt(summaries.schema_version, .{}),
        },
    );
    defer allocator.free(receipt);
    return module.okEnvelope(allocator, "update_session_summary", receipt);
}

test "update_session_summary writes a schema-bound ledger row with effect receipt" {
    const allocator = std.testing.allocator;
    const summary = "Implemented the session summary ledger with mandatory pre-turn-end updates and kernel fallback evidence.";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{
        .workspace_root = workspace,
        .session_id = "sess-tool-1",
    };

    const arguments = try std.fmt.allocPrint(allocator, "{{\"summary\":{f},\"title\":\"Summary ledger\",\"topic\":\"sessions\"}}", .{std.json.fmt(summary, .{})});
    defer allocator.free(arguments);
    const output = try execute(allocator, ctx, arguments);
    defer allocator.free(output);

    var parsed_output = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed_output.deinit();
    try std.testing.expect(parsed_output.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("update_session_summary", parsed_output.value.object.get("tool").?.string);
    var receipt = try std.json.parseFromSlice(std.json.Value, allocator, parsed_output.value.object.get("content").?.string, .{});
    defer receipt.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(summaries.countWords(summary))), receipt.value.object.get("words").?.integer);
    try std.testing.expectEqualStrings("var1.session_summary.v1", receipt.value.object.get("schema").?.string);

    var row = (try summaries.readSummary(allocator, workspace, "sess-tool-1")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("Summary ledger", row.title);
    try std.testing.expectEqualStrings("sessions", row.topic);
    try std.testing.expectEqualStrings("agent", row.source);
}

test "update_session_summary rejects summaries over 100 words" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{
        .workspace_root = workspace,
        .session_id = "sess-tool-2",
    };

    var long_summary = std.array_list.Managed(u8).init(allocator);
    defer long_summary.deinit();
    var index: usize = 0;
    while (index < 101) : (index += 1) {
        if (index > 0) try long_summary.append(' ');
        try long_summary.appendSlice("word");
    }
    const arguments = try std.fmt.allocPrint(allocator, "{{\"summary\":{f}}}", .{std.json.fmt(long_summary.items, .{})});
    defer allocator.free(arguments);

    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, arguments));
}

test "update_session_summary rejects missing summary and missing session id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, .{ .workspace_root = workspace, .session_id = "sess-tool-3" }, "{}"),
    );
    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, .{ .workspace_root = workspace }, "{\"summary\":\"valid summary text here\"}"),
    );
}
