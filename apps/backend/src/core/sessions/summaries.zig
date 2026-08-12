/// Session summary ledger — the permanent handoff record for every VANTARI
/// session (root orchestrator, subagents, past sessions).
///
/// Each session maintains one durable row of at most 100 words, updated by the
/// orchestrator through `update_session_summary` before its turn ends. The
/// ledger is a single JSON object keyed by session id at
/// `<runtimeRoot>/sessions/summaries.json`, atomically rewritten on upsert.
/// Any session can read the full timeline through `session_summaries`, which
/// makes the ledger the global recall surface: what every session was doing,
/// what it concluded, and what it left open.
///
/// Row shape (schema `var1.session_summary.v1`):
///   session_id, parent_session_id, title, topic, summary, status,
///   workspace_root, source ("agent" | "kernel_fallback"),
///   updated_at_ms, turn_count
///
/// Enforcement: `ensureFreshSummary` is the turn-end gate. If the agent did
/// not update its row during the run (row.updated_at_ms <= run_start_ms), the
/// kernel writes a deterministic truncated fallback so the timeline never
/// goes stale — the same ledger, one writer discipline, typed event evidence.
const std = @import("std");

const fsutil = @import("../../shared/fsutil.zig");

pub const schema_version = "var1.session_summary.v1";
pub const max_summary_words: usize = 100;
pub const max_summary_bytes: usize = 4096;

pub const SummaryRow = struct {
    session_id: []u8,
    parent_session_id: []u8,
    title: []u8,
    topic: []u8,
    summary: []u8,
    status: []u8,
    workspace_root: []u8,
    source: []u8,
    updated_at_ms: i64,
    turn_count: usize,

    pub fn deinit(self: *SummaryRow, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.parent_session_id);
        allocator.free(self.title);
        allocator.free(self.topic);
        allocator.free(self.summary);
        allocator.free(self.status);
        allocator.free(self.workspace_root);
        allocator.free(self.source);
    }
};

/// Result of the turn-end freshness gate.
pub const Freshness = enum {
    /// The agent updated its summary during this run — mandate satisfied.
    updated_by_agent,
    /// No fresh update; the kernel wrote the deterministic fallback.
    kernel_fallback,
};

pub fn summariesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const path = try fsutil.join(allocator, &.{ root, "sessions", "summaries.json" });
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse "") catch {};
    return path;
}

pub fn countWords(text: []const u8) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |_| count += 1;
    return count;
}

/// Keep the first `max_words` whitespace-separated tokens, joined with single
/// spaces. Deterministic — used by the kernel fallback and by timeline
/// preview truncation.
pub fn truncateToWords(allocator: std.mem.Allocator, text: []const u8, max_words: usize) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var kept: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| : (kept += 1) {
        if (kept >= max_words) break;
        if (kept > 0) try output.append(' ');
        try output.appendSlice(token);
    }

    return output.toOwnedSlice();
}

/// Read one session's summary row. Returns null when absent, unreadable, or
/// structurally malformed (the ledger must never brick a turn).
pub fn readSummary(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?SummaryRow {
    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);

    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const entry = root.get(session_id) orelse return null;
    if (entry != .object) return null;

    return rowFromObject(allocator, session_id, entry.object) catch null;
}

/// Upsert a session's summary row. Rewrites the ledger atomically
/// (fsutil.writeText -> atomicFile -> rename) preserving every other row.
/// `turn_count` increments on every write so the timeline shows how many
/// times a session refreshed its record. Returns the new turn_count.
pub fn upsertSummary(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    title: []const u8,
    topic: []const u8,
    summary: []const u8,
    status: []const u8,
    source: []const u8,
    updated_at_ms: i64,
) !usize {
    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);

    const rows = try listSummaries(allocator, workspace_root);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }

    // Preserve the existing row's turn_count; its position is dropped and the
    // updated row is appended (file order is cosmetic — list sorts by time).
    var turn_count: usize = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, row.session_id, session_id)) {
            turn_count = row.turn_count;
            break;
        }
    }
    turn_count += 1;

    var ledger = std.array_list.Managed(u8).init(allocator);
    defer ledger.deinit();
    const writer = ledger.writer();
    try writer.writeByte('{');

    var written: usize = 0;
    for (rows) |row| {
        if (std.mem.eql(u8, row.session_id, session_id)) continue;
        if (written > 0) try writer.writeByte(',');
        try writer.print("{f}:{{", .{std.json.fmt(row.session_id, .{})});
        try renderRow(
            writer,
            row.session_id,
            row.parent_session_id,
            row.title,
            row.topic,
            row.summary,
            row.status,
            row.workspace_root,
            row.source,
            row.updated_at_ms,
            row.turn_count,
        );
        try writer.writeByte('}');
        written += 1;
    }
    if (written > 0) try writer.writeByte(',');
    try writer.print("{f}:{{", .{std.json.fmt(session_id, .{})});
    try renderRow(
        writer,
        session_id,
        parent_session_id,
        title,
        topic,
        summary,
        status,
        workspace_root,
        source,
        updated_at_ms,
        turn_count,
    );
    try writer.writeByte('}');
    try writer.writeByte('}');

    try fsutil.writeText(path, ledger.items);
    return turn_count;
}

/// Parse the ledger into rows sorted by updated_at_ms descending (newest
/// first). Caller frees every row and the returned slice. Absent, empty, or
/// unparseable ledgers yield an empty list — never an error.
pub fn listSummaries(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]SummaryRow {
    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);

    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SummaryRow, 0),
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return allocator.alloc(SummaryRow, 0);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(SummaryRow, 0);

    var rows = std.array_list.Managed(SummaryRow).init(allocator);
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit();
    }

    const root = parsed.value.object;
    for (root.keys(), root.values()) |key, value| {
        if (value != .object) continue;
        if (rowFromObject(allocator, key, value.object)) |row| {
            rows.append(row) catch {};
        } else |_| {}
    }

    std.mem.sort(SummaryRow, rows.items, {}, struct {
        fn lessThan(_: void, a: SummaryRow, b: SummaryRow) bool {
            return a.updated_at_ms > b.updated_at_ms;
        }
    }.lessThan);

    return rows.toOwnedSlice();
}

/// Turn-end freshness gate (AGENTS.md mandatory-summary discipline). If the
/// agent updated its row during this run, the mandate is satisfied. Otherwise
/// the kernel writes a deterministic fallback derived from the session prompt
/// and final output so the timeline never goes stale. `status` is the
/// session's terminal state label (completed/failed/...).
pub fn ensureFreshSummary(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    final_output: []const u8,
    run_start_ms: i64,
) !Freshness {
    var maybe_existing = try readSummary(allocator, workspace_root, session_id);
    if (maybe_existing) |*existing| {
        defer existing.deinit(allocator);
        if (existing.updated_at_ms > run_start_ms) return .updated_by_agent;
    }

    const fallback = try buildFallbackSummary(allocator, status, prompt, final_output);
    defer allocator.free(fallback);
    _ = try upsertSummary(
        allocator,
        workspace_root,
        session_id,
        parent_session_id,
        "",
        "",
        fallback,
        status,
        "kernel_fallback",
        std.time.milliTimestamp(),
    );
    return .kernel_fallback;
}

fn buildFallbackSummary(
    allocator: std.mem.Allocator,
    status: []const u8,
    prompt: []const u8,
    final_output: []const u8,
) ![]u8 {
    const objective = try truncateToWords(allocator, prompt, 40);
    defer allocator.free(objective);
    const outcome = try truncateToWords(allocator, final_output, 40);
    defer allocator.free(outcome);

    return std.fmt.allocPrint(
        allocator,
        "Session status: {s}. Objective: {s}. Outcome: {s}.",
        .{ status, objective, outcome },
    );
}

fn rowFromObject(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    obj: std.json.ObjectMap,
) !SummaryRow {
    return .{
        .session_id = try allocator.dupe(u8, session_id),
        .parent_session_id = try dupField(allocator, obj, "parent_session_id"),
        .title = try dupField(allocator, obj, "title"),
        .topic = try dupField(allocator, obj, "topic"),
        .summary = try dupField(allocator, obj, "summary"),
        .status = try dupField(allocator, obj, "status"),
        .workspace_root = try dupField(allocator, obj, "workspace_root"),
        .source = try dupField(allocator, obj, "source"),
        .updated_at_ms = intField(obj, "updated_at_ms", 0),
        .turn_count = @intCast(intField(obj, "turn_count", 0)),
    };
}

fn dupField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![]u8 {
    if (obj.get(name)) |value| {
        if (value == .string) return allocator.dupe(u8, value.string);
    }
    return allocator.dupe(u8, "");
}

fn intField(obj: std.json.ObjectMap, name: []const u8, default: i64) i64 {
    if (obj.get(name)) |value| {
        if (value == .integer) return value.integer;
    }
    return default;
}

/// Render a single row's JSON fields (no braces, no key).
fn renderRow(
    writer: anytype,
    session_id: []const u8,
    parent_session_id: []const u8,
    title: []const u8,
    topic: []const u8,
    summary: []const u8,
    status: []const u8,
    workspace_root: []const u8,
    source: []const u8,
    updated_at_ms: i64,
    turn_count: usize,
) !void {
    try writer.print(
        "\"schema\":{f},\"session_id\":{f},\"parent_session_id\":{f},\"title\":{f},\"topic\":{f},\"summary\":{f},\"status\":{f},\"workspace_root\":{f},\"source\":{f},\"updated_at_ms\":{d},\"turn_count\":{d}",
        .{
            std.json.fmt(schema_version, .{}),
            std.json.fmt(session_id, .{}),
            std.json.fmt(parent_session_id, .{}),
            std.json.fmt(title, .{}),
            std.json.fmt(topic, .{}),
            std.json.fmt(summary, .{}),
            std.json.fmt(status, .{}),
            std.json.fmt(workspace_root, .{}),
            std.json.fmt(source, .{}),
            updated_at_ms,
            turn_count,
        },
    );
}

test "countWords and truncateToWords enforce the 100-word contract" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(@as(usize, 0), countWords(""));
    try std.testing.expectEqual(@as(usize, 3), countWords("a b   c"));
    try std.testing.expectEqual(@as(usize, 6), countWords("one\ntwo\nthree four five six"));

    const truncated = try truncateToWords(allocator, "alpha beta gamma delta", 2);
    defer allocator.free(truncated);
    try std.testing.expectEqualStrings("alpha beta", truncated);

    const capped = try truncateToWords(allocator, "one two three", 100);
    defer allocator.free(capped);
    try std.testing.expectEqualStrings("one two three", capped);
}

test "upsertSummary writes a durable schema-bound row and increments turn_count" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const first = try upsertSummary(allocator, workspace, "sess-1", "", "Title one", "agents", "Summary text one", "completed", "agent", 1000);
    try std.testing.expectEqual(@as(usize, 1), first);

    const second = try upsertSummary(allocator, workspace, "sess-1", "", "Title two", "agents", "Summary text two", "completed", "agent", 2000);
    try std.testing.expectEqual(@as(usize, 2), second);

    var row = (try readSummary(allocator, workspace, "sess-1")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("sess-1", row.session_id);
    try std.testing.expectEqualStrings("Title two", row.title);
    try std.testing.expectEqualStrings("Summary text two", row.summary);
    try std.testing.expectEqualStrings("agent", row.source);
    try std.testing.expectEqual(@as(i64, 2000), row.updated_at_ms);

    // Raw ledger carries the schema marker and the replacement (not both rows).
    const path = try summariesFilePath(allocator, workspace);
    defer allocator.free(path);
    const raw = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"schema\":\"var1.session_summary.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Summary text one") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Summary text two") != null);
}

test "upsertSummary preserves unrelated rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    _ = try upsertSummary(allocator, workspace, "sess-a", "", "A", "", "Row A", "completed", "agent", 100);
    _ = try upsertSummary(allocator, workspace, "sess-b", "", "B", "", "Row B", "failed", "kernel_fallback", 200);
    _ = try upsertSummary(allocator, workspace, "sess-a", "", "A2", "", "Row A updated", "completed", "agent", 300);

    const rows = try listSummaries(allocator, workspace);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("sess-a", rows[0].session_id);
    try std.testing.expectEqualStrings("Row A updated", rows[0].summary);
    try std.testing.expectEqualStrings("sess-b", rows[1].session_id);
    try std.testing.expectEqualStrings("Row B", rows[1].summary);
}

test "readSummary returns null when absent or malformed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try std.testing.expect((try readSummary(allocator, workspace, "missing")) == null);

    const path = try summariesFilePath(allocator, workspace);
    defer allocator.free(path);
    try fsutil.writeText(path, "{broken json");
    try std.testing.expect((try readSummary(allocator, workspace, "missing")) == null);
}

test "listSummaries returns rows newest first" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    _ = try upsertSummary(allocator, workspace, "sess-old", "", "Old", "", "Older work", "completed", "agent", 100);
    _ = try upsertSummary(allocator, workspace, "sess-new", "", "New", "", "Newer work", "completed", "agent", 300);
    _ = try upsertSummary(allocator, workspace, "sess-mid", "", "Mid", "", "Middle work", "failed", "kernel_fallback", 200);

    const rows = try listSummaries(allocator, workspace);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("sess-new", rows[0].session_id);
    try std.testing.expectEqualStrings("sess-mid", rows[1].session_id);
    try std.testing.expectEqualStrings("sess-old", rows[2].session_id);
    try std.testing.expectEqualStrings("kernel_fallback", rows[1].source);
    try std.testing.expectEqualStrings("failed", rows[1].status);
}

test "ensureFreshSummary writes kernel fallback when the agent missed the mandate" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const run_start_ms: i64 = 5000;
    const freshness = try ensureFreshSummary(
        allocator,
        workspace,
        "sess-a",
        "",
        "completed",
        "Implement the summary ledger for all sessions",
        "Implemented the ledger with atomic rewrites.",
        run_start_ms,
    );
    try std.testing.expectEqual(Freshness.kernel_fallback, freshness);

    var row = (try readSummary(allocator, workspace, "sess-a")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("kernel_fallback", row.source);
    try std.testing.expectEqualStrings("completed", row.status);
    try std.testing.expect(std.mem.indexOf(u8, row.summary, "Implement the summary ledger") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.summary, "Implemented the ledger") != null);
    try std.testing.expect(std.mem.startsWith(u8, row.summary, "Session status: completed."));
}

test "ensureFreshSummary accepts a fresh agent update and leaves it untouched" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    // Agent updated the summary during the run (updated_at_ms > run_start_ms).
    _ = try upsertSummary(allocator, workspace, "sess-b", "", "Agent title", "", "Agent's own 100-word summary of the turn", "running", "agent", 9000);
    const run_start_ms: i64 = 5000;

    const freshness = try ensureFreshSummary(
        allocator,
        workspace,
        "sess-b",
        "",
        "completed",
        "Some prompt",
        "Some output",
        run_start_ms,
    );
    try std.testing.expectEqual(Freshness.updated_by_agent, freshness);

    var row = (try readSummary(allocator, workspace, "sess-b")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("agent", row.source);
    try std.testing.expectEqualStrings("Agent's own 100-word summary of the turn", row.summary);
    try std.testing.expectEqual(@as(usize, 1), row.turn_count);
}
