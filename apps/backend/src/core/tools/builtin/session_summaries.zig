const std = @import("std");

const summaries = @import("../../sessions/summaries.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "session_summaries",
    .description = "Read the session summary timeline — the latest <=100-word summary of every session in the workspace (or the global ledger), each maintained by its session before the turn ended. This is the recall surface for what other sessions did, what they concluded, and what they left open. Use it before delegating (pick a session whose work is relevant), before continuing after a restart (recover your own last summary), or when a session references another session's work. Rows show status, title, source (agent or kernel_fallback), and last-updated age.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "scope": { "type": "string", "enum": ["project", "global"], "description": "project (default): sessions whose workspace matches the current workspace. global: every session row in the ledger — when VANTARI_HOME is set, the ledger spans workspaces." },
    \\    "session_id": { "type": "string", "description": "Return the full summary row for exactly this session (ignores scope)." },
    \\    "query": { "type": "string", "minLength": 1, "description": "Case-insensitive keyword filter on title, topic, and summary." },
    \\    "full": { "type": "boolean", "description": "Emit full summaries instead of 40-word timeline previews. Default false; single-session lookups always return the full summary." },
    \\    "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Max rows to return. Defaults to 20." }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"scope\":\"project\",\"query\":\"context\",\"limit\":10}",
    .usage_hint = "Use session_id to pull one session's full summary; use query to filter the timeline by topic; use scope:global when VANTARI_HOME spans multiple workspaces.",
};

pub const availability = module.AvailabilitySpec{};

const Args = struct {
    scope: []const u8 = "project",
    session_id: ?[]const u8 = null,
    query: ?[]const u8 = null,
    full: ?bool = null,
    limit: ?usize = null,
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const args = parsed.value;

    const rows = try summaries.listSummaries(allocator, execution_context.workspace_root);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }

    // Filter: exact session id first; then scope + query over the timeline.
    var matches = std.array_list.Managed(usize).init(allocator);
    defer matches.deinit();
    for (rows, 0..) |row, index| {
        if (args.session_id) |sid| {
            if (std.mem.eql(u8, row.session_id, sid)) {
                matches.append(index) catch {};
                break;
            }
            continue;
        }
        if (std.mem.eql(u8, args.scope, "project") and
            !std.mem.eql(u8, row.workspace_root, execution_context.workspace_root)) continue;
        if (args.query) |query| {
            if (std.ascii.indexOfIgnoreCase(row.title, query) == null and
                std.ascii.indexOfIgnoreCase(row.topic, query) == null and
                std.ascii.indexOfIgnoreCase(row.summary, query) == null) continue;
        }
        matches.append(index) catch {};
    }

    const limit = if (args.limit) |l| @min(@max(l, 1), 100) else 20;
    const count = @min(matches.items.len, limit);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();

    if (args.session_id) |sid| {
        if (count == 0) {
            try writer.print("SESSION {f} not found\nREASON no summary row exists for this session\n", .{std.json.fmt(sid, .{})});
            return module.okEnvelope(allocator, "session_summaries", output.items);
        }
        const row = &rows[matches.items[0]];
        try writer.print("SESSION {f} ({s})\nSTATUS {s}\nSOURCE {s}\nUPDATED {s}\nSUMMARY {s}\n", .{
            std.json.fmt(row.session_id, .{}),
            row.title,
            row.status,
            row.source,
            ageLabel(row.updated_at_ms),
            row.summary,
        });
        return module.okEnvelope(allocator, "session_summaries", output.items);
    }

    try writer.print("SESSIONS {d} of {d}\n", .{ count, rows.len });
    const full_mode = args.full orelse false;
    for (matches.items[0..count]) |index| {
        const row = &rows[index];
        if (full_mode) {
            try writer.print("- [{s}] {s} ({s}) — {s} · {s} · {s}\n", .{
                row.status,
                row.session_id,
                row.title,
                row.summary,
                ageLabel(row.updated_at_ms),
                row.source,
            });
        } else {
            const preview = try summaries.truncateToWords(allocator, row.summary, 40);
            defer allocator.free(preview);
            try writer.print("- [{s}] {s} ({s}) — {s} · {s} · {s}\n", .{
                row.status,
                row.session_id,
                row.title,
                preview,
                ageLabel(row.updated_at_ms),
                row.source,
            });
        }
    }
    if (count == 0) try writer.writeAll("REASON no matching sessions in the summary ledger\n");

    return module.okEnvelope(allocator, "session_summaries", output.items);
}

fn ageLabel(updated_at_ms: i64) []const u8 {
    const now_ms = std.time.milliTimestamp();
    const elapsed_s: i64 = @max(0, @divTrunc(now_ms - updated_at_ms, 1000));    if (elapsed_s < 60) return "just now";
    if (elapsed_s < 3600) return "minutes ago";
    if (elapsed_s < 86400) return "hours ago";
    return "days ago";
}

test "session_summaries lists the timeline newest first with previews" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    _ = try summaries.upsertSummary(allocator, workspace, "sess-view-1", "", "Context compiler", "context", "Rebuilt the context compiler with deterministic checkpoints and typed diagnostics. Next steps are provider probing and tool diffing.", "completed", "agent", std.time.milliTimestamp() - 60_000);
    _ = try summaries.upsertSummary(allocator, workspace, "sess-view-2", "", "Ticket audit", "tickets", "Audited all open tickets and closed the resolved ones with evidence paths.", "completed", "agent", std.time.milliTimestamp() - 5_000);

    const ctx = module.ExecutionContext{ .workspace_root = workspace };
    const output = try execute(allocator, ctx, "{}");
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SESSIONS 2 of 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sess-view-2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sess-view-1") != null);
}

test "session_summaries filters by query and returns the full single-session row" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    _ = try summaries.upsertSummary(allocator, workspace, "sess-q1", "", "Context compiler", "context", "Rebuilt the context compiler with deterministic checkpoints.", "completed", "agent", std.time.milliTimestamp());
    _ = try summaries.upsertSummary(allocator, workspace, "sess-q2", "", "Ticket audit", "tickets", "Audited all open tickets.", "completed", "agent", std.time.milliTimestamp());

    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    const filtered = try execute(allocator, ctx, "{\"query\":\"compiler\"}");
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "SESSIONS 1 of 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "sess-q1") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "sess-q2") == null);

    const single = try execute(allocator, ctx, "{\"session_id\":\"sess-q2\"}");
    defer allocator.free(single);
    try std.testing.expect(std.mem.indexOf(u8, single, "SESSION \"sess-q2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, single, "Audited all open tickets.") != null);
    try std.testing.expect(std.mem.indexOf(u8, single, "SUMMARY ") != null);
}

test "session_summaries project scope excludes foreign-workspace rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const ctx = module.ExecutionContext{ .workspace_root = workspace };
    const ledger_path = try summaries.summariesFilePath(allocator, workspace);
    defer allocator.free(ledger_path);

    // Hand-write a ledger with one foreign-workspace row and one local row.
    const local_root = std.fmt.allocPrint(allocator, ".zig-cache/tmp/local-{s}", .{tmp.sub_path}) catch unreachable;
    defer allocator.free(local_root);
    const ledger = try std.fmt.allocPrint(
        allocator,
        "{{\"sess-foreign\":{{\"schema\":\"var1.session_summary.v1\",\"session_id\":\"sess-foreign\",\"parent_session_id\":\"\",\"title\":\"Foreign\",\"topic\":\"\",\"summary\":\"Work in another workspace entirely.\",\"status\":\"completed\",\"workspace_root\":\"{s}\",\"source\":\"agent\",\"updated_at_ms\":100,\"turn_count\":1}},\"sess-local\":{{\"schema\":\"var1.session_summary.v1\",\"session_id\":\"sess-local\",\"parent_session_id\":\"\",\"title\":\"Local\",\"topic\":\"\",\"summary\":\"Work in this workspace.\",\"status\":\"completed\",\"workspace_root\":\"{s}\",\"source\":\"agent\",\"updated_at_ms\":200,\"turn_count\":1}}}}",
        .{ local_root, workspace },
    );
    defer allocator.free(ledger);
    try std.fs.cwd().writeFile(.{ .sub_path = ledger_path, .data = ledger });

    const project = try execute(allocator, ctx, "{\"scope\":\"project\"}");
    defer allocator.free(project);
    try std.testing.expect(std.mem.indexOf(u8, project, "SESSIONS 1 of 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "sess-local") != null);
    try std.testing.expect(std.mem.indexOf(u8, project, "sess-foreign") == null);

    const global = try execute(allocator, ctx, "{\"scope\":\"global\"}");
    defer allocator.free(global);
    try std.testing.expect(std.mem.indexOf(u8, global, "SESSIONS 2 of 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, global, "sess-foreign") != null);
}
