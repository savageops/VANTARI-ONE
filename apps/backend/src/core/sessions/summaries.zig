/// Session summary ledger — the permanent handoff record for every VANTARI
/// session (root orchestrator, subagents, past sessions).
///
/// Each session appends a durable row of at most 100 words through
/// `update_session_summary` before its turn ends. The ledger lives at
/// `<runtimeRoot>/sessions/summaries.jsonl`; readers project the greatest
/// sequence for each session. Any session can read that latest-row timeline
/// through `session_summaries`: what every session was doing, what it
/// concluded, and what it left open.
///
/// Row shape (schema `var1.session_summary.v2`):
///   session_id, parent_session_id, title, topic, summary, status,
///   workspace_root, source ("agent" | "kernel_fallback"),
///   seq, updated_at_ms, turn_count
///
/// Enforcement: `ensureFreshSummary` is the turn-end gate. If the agent did
/// not update its row during the run (row.updated_at_ms <= run_start_ms), the
/// kernel writes a deterministic truncated fallback so the timeline never
/// goes stale — the same ledger, one writer discipline, typed event evidence.
const std = @import("std");

const fsutil = @import("../../shared/fsutil.zig");

pub const schema_version = "var1.session_summary.v2";
pub const max_summary_words: usize = 100;
pub const max_summary_bytes: usize = 4096;

/// One host process owns summary mutation. This is intentionally one mutex,
/// not a workspace registry: summary writes occur once per turn, and the
/// eventual persistent host remains the only execution owner.
var summary_ledger_mutex: std.Thread.Mutex = .{};

pub const SummaryRow = struct {
    session_id: []u8,
    parent_session_id: []u8,
    title: []u8,
    topic: []u8,
    summary: []u8,
    status: []u8,
    workspace_root: []u8,
    source: []u8,
    seq: u64,
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

pub const UpsertResult = struct {
    seq: u64,
    turn_count: usize,
};

pub fn summariesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const path = try fsutil.join(allocator, &.{ root, "sessions", "summaries.jsonl" });
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse "") catch {};
    return path;
}

fn legacySummariesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", "summaries.json" });
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
    summary_ledger_mutex.lock();
    defer summary_ledger_mutex.unlock();

    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);
    try ensureLedgerReadyLocked(allocator, workspace_root, path);

    var projection = try loadProjectionLocked(allocator, path);
    defer projection.deinit(allocator);
    for (projection.rows) |row| {
        if (std.mem.eql(u8, row.session_id, session_id)) return @as(?SummaryRow, try cloneRow(allocator, row));
    }
    return null;
}

/// Append a session summary revision. One process mutex owns sequence and
/// turn-count allocation; no existing row is rewritten. Returns exact identity.
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
) !UpsertResult {
    summary_ledger_mutex.lock();
    defer summary_ledger_mutex.unlock();

    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);
    try ensureLedgerReadyLocked(allocator, workspace_root, path);
    return appendSummaryLocked(
        allocator,
        path,
        workspace_root,
        session_id,
        parent_session_id,
        title,
        topic,
        summary,
        status,
        source,
        updated_at_ms,
    );
}

/// Parse the append-only ledger into one latest row per session, sorted newest
/// first. Malformed lines are isolated; valid rows before or after them remain
/// readable. Caller frees every row and the returned slice.
pub fn listSummaries(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]SummaryRow {
    summary_ledger_mutex.lock();
    defer summary_ledger_mutex.unlock();

    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);
    try ensureLedgerReadyLocked(allocator, workspace_root, path);

    const projection = try loadProjectionLocked(allocator, path);
    const rows = projection.rows;

    std.mem.sort(SummaryRow, rows, {}, struct {
        fn lessThan(_: void, a: SummaryRow, b: SummaryRow) bool {
            if (a.updated_at_ms == b.updated_at_ms) return a.seq > b.seq;
            return a.updated_at_ms > b.updated_at_ms;
        }
    }.lessThan);

    return rows;
}

const LedgerProjection = struct {
    rows: []SummaryRow,

    fn deinit(self: *LedgerProjection, allocator: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(allocator);
        allocator.free(self.rows);
    }
};

fn loadProjectionLocked(allocator: std.mem.Allocator, path: []const u8) !LedgerProjection {
    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .rows = try allocator.alloc(SummaryRow, 0) },
        else => return err,
    };
    defer allocator.free(content);

    var latest = std.StringHashMapUnmanaged(SummaryRow){};
    var map_owns_rows = true;
    defer {
        if (map_owns_rows) {
            var values = latest.valueIterator();
            while (values.next()) |row| row.deinit(allocator);
        }
        latest.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = std.mem.trim(u8, line[3..], " \t\r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const session_value = parsed.value.object.get("session_id") orelse continue;
        if (session_value != .string or session_value.string.len == 0) continue;

        var row = rowFromObject(allocator, session_value.string, parsed.value.object) catch continue;
        if (latest.get(row.session_id)) |existing| {
            if (row.seq <= existing.seq) {
                row.deinit(allocator);
                continue;
            }
            if (latest.fetchRemove(row.session_id)) |removed| {
                var old = removed.value;
                old.deinit(allocator);
            }
        }
        latest.put(allocator, row.session_id, row) catch |err| {
            row.deinit(allocator);
            return err;
        };
    }

    const rows = try allocator.alloc(SummaryRow, latest.count());
    var index: usize = 0;
    var values = latest.valueIterator();
    while (values.next()) |row| : (index += 1) rows[index] = row.*;
    map_owns_rows = false;
    return .{ .rows = rows };
}

fn appendSummaryLocked(
    allocator: std.mem.Allocator,
    path: []const u8,
    workspace_root: []const u8,
    session_id: []const u8,
    parent_session_id: []const u8,
    title: []const u8,
    topic: []const u8,
    summary: []const u8,
    status: []const u8,
    source: []const u8,
    updated_at_ms: i64,
) !UpsertResult {
    const state = try readAppendStateLocked(allocator, path, session_id);
    if (state.turn_count == std.math.maxInt(usize)) return error.SummaryTurnCountOverflow;
    if (state.max_seq == std.math.maxInt(u64)) return error.SummarySequenceOverflow;
    const turn_count = state.turn_count + 1;
    const seq = state.max_seq + 1;

    var encoded = std.array_list.Managed(u8).init(allocator);
    defer encoded.deinit();
    const writer = encoded.writer();
    try writer.writeByte('{');
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
        seq,
        updated_at_ms,
        turn_count,
    );
    try writer.writeAll("}\n");
    try fsutil.appendJsonlRecord(path, encoded.items, true);
    return .{ .seq = seq, .turn_count = turn_count };
}

const AppendState = struct {
    max_seq: u64 = 0,
    turn_count: usize = 0,
};

/// Read only as far backward as needed to find the last sequence and this
/// session's latest revision. Torn trailing rows are skipped. This keeps the
/// append path independent of latest-row projection allocation.
fn readAppendStateLocked(
    allocator: std.mem.Allocator,
    path: []const u8,
    session_id: []const u8,
) !AppendState {
    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(content);

    var state = AppendState{};
    var found_session = false;
    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;
        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content[start..end], .{}) catch {
            end = if (start == 0) 0 else start - 1;
            continue;
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (state.max_seq == 0) state.max_seq = uintField(parsed.value.object, "seq", 0);
            if (!found_session) {
                if (parsed.value.object.get("session_id")) |value| {
                    if (value == .string and std.mem.eql(u8, value.string, session_id)) {
                        state.turn_count = @intCast(uintField(parsed.value.object, "turn_count", 0));
                        found_session = true;
                    }
                }
            }
        }
        if (state.max_seq > 0 and found_session) break;
        end = if (start == 0) 0 else start - 1;
    }
    return state;
}

/// Import the former keyed-object ledger once. The legacy file remains an
/// immutable rollback input; after JSONL exists, no runtime reader consults it.
fn ensureLedgerReadyLocked(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    path: []const u8,
) !void {
    if (fsutil.fileExists(path)) return;

    const legacy_path = try legacySummariesFilePath(allocator, workspace_root);
    defer allocator.free(legacy_path);
    const content = fsutil.readTextAlloc(allocator, legacy_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;

    var encoded = std.array_list.Managed(u8).init(allocator);
    defer encoded.deinit();
    const writer = encoded.writer();
    var seq: u64 = 0;
    const root = parsed.value.object;
    for (root.keys(), root.values()) |session_id, value| {
        if (value != .object) continue;
        var row = rowFromObject(allocator, session_id, value.object) catch continue;
        defer row.deinit(allocator);
        if (seq == std.math.maxInt(u64)) return error.SummarySequenceOverflow;
        seq += 1;
        try writer.writeByte('{');
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
            seq,
            row.updated_at_ms,
            row.turn_count,
        );
        try writer.writeAll("}\n");
    }
    if (encoded.items.len > 0) try fsutil.writeText(path, encoded.items);
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
    summary_ledger_mutex.lock();
    defer summary_ledger_mutex.unlock();

    const path = try summariesFilePath(allocator, workspace_root);
    defer allocator.free(path);
    try ensureLedgerReadyLocked(allocator, workspace_root, path);

    var projection = try loadProjectionLocked(allocator, path);
    defer projection.deinit(allocator);
    for (projection.rows) |existing| {
        if (std.mem.eql(u8, existing.session_id, session_id) and existing.updated_at_ms > run_start_ms) {
            return .updated_by_agent;
        }
    }

    const fallback = try buildFallbackSummary(allocator, status, prompt, final_output);
    defer allocator.free(fallback);
    _ = try appendSummaryLocked(
        allocator,
        path,
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
        .seq = uintField(obj, "seq", 0),
        .updated_at_ms = intField(obj, "updated_at_ms", 0),
        .turn_count = @intCast(uintField(obj, "turn_count", 0)),
    };
}

fn cloneRow(allocator: std.mem.Allocator, row: SummaryRow) !SummaryRow {
    const session_id = try allocator.dupe(u8, row.session_id);
    errdefer allocator.free(session_id);
    const parent_session_id = try allocator.dupe(u8, row.parent_session_id);
    errdefer allocator.free(parent_session_id);
    const title = try allocator.dupe(u8, row.title);
    errdefer allocator.free(title);
    const topic = try allocator.dupe(u8, row.topic);
    errdefer allocator.free(topic);
    const summary = try allocator.dupe(u8, row.summary);
    errdefer allocator.free(summary);
    const status = try allocator.dupe(u8, row.status);
    errdefer allocator.free(status);
    const workspace_root = try allocator.dupe(u8, row.workspace_root);
    errdefer allocator.free(workspace_root);
    const source = try allocator.dupe(u8, row.source);
    errdefer allocator.free(source);
    return .{
        .session_id = session_id,
        .parent_session_id = parent_session_id,
        .title = title,
        .topic = topic,
        .summary = summary,
        .status = status,
        .workspace_root = workspace_root,
        .source = source,
        .seq = row.seq,
        .updated_at_ms = row.updated_at_ms,
        .turn_count = row.turn_count,
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

fn uintField(obj: std.json.ObjectMap, name: []const u8, default: u64) u64 {
    if (obj.get(name)) |value| {
        if (value == .integer and value.integer >= 0) return @intCast(value.integer);
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
    seq: u64,
    updated_at_ms: i64,
    turn_count: usize,
) !void {
    try writer.print(
        "\"schema\":{f},\"seq\":{d},\"session_id\":{f},\"parent_session_id\":{f},\"title\":{f},\"topic\":{f},\"summary\":{f},\"status\":{f},\"workspace_root\":{f},\"source\":{f},\"updated_at_ms\":{d},\"turn_count\":{d}",
        .{
            std.json.fmt(schema_version, .{}),
            seq,
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
    try std.testing.expectEqual(@as(u64, 1), first.seq);
    try std.testing.expectEqual(@as(usize, 1), first.turn_count);

    const second = try upsertSummary(allocator, workspace, "sess-1", "", "Title two", "agents", "Summary text two", "completed", "agent", 2000);
    try std.testing.expectEqual(@as(u64, 2), second.seq);
    try std.testing.expectEqual(@as(usize, 2), second.turn_count);

    var row = (try readSummary(allocator, workspace, "sess-1")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("sess-1", row.session_id);
    try std.testing.expectEqualStrings("Title two", row.title);
    try std.testing.expectEqualStrings("Summary text two", row.summary);
    try std.testing.expectEqualStrings("agent", row.source);
    try std.testing.expectEqual(@as(u64, 2), row.seq);
    try std.testing.expectEqual(@as(i64, 2000), row.updated_at_ms);

    // Raw ledger retains both revisions; the read projection selects seq 2.
    const path = try summariesFilePath(allocator, workspace);
    defer allocator.free(path);
    const raw = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"schema\":\"var1.session_summary.v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Summary text one") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Summary text two") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "\n"));
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

test "legacy keyed summary object imports once into sequenced JSONL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const legacy_path = try legacySummariesFilePath(allocator, workspace);
    defer allocator.free(legacy_path);
    const legacy = try std.fmt.allocPrint(
        allocator,
        "{{\"legacy-session\":{{\"schema\":\"var1.session_summary.v1\",\"session_id\":\"legacy-session\",\"parent_session_id\":\"\",\"title\":\"Imported\",\"topic\":\"migration\",\"summary\":\"Retain this handoff.\",\"status\":\"completed\",\"workspace_root\":{f},\"source\":\"agent\",\"updated_at_ms\":50,\"turn_count\":7}}}}",
        .{std.json.fmt(workspace, .{})},
    );
    defer allocator.free(legacy);
    try fsutil.writeText(legacy_path, legacy);

    var row = (try readSummary(allocator, workspace, "legacy-session")).?;
    defer row.deinit(allocator);
    try std.testing.expectEqualStrings("Retain this handoff.", row.summary);
    try std.testing.expectEqual(@as(u64, 1), row.seq);
    try std.testing.expectEqual(@as(usize, 7), row.turn_count);

    const path = try summariesFilePath(allocator, workspace);
    defer allocator.free(path);
    const raw = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"schema\":\"var1.session_summary.v2\"") != null);
    try std.testing.expect(fsutil.fileExists(legacy_path));
}

test "summary append isolates a poisoned suffix and preserves later rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    _ = try upsertSummary(allocator, workspace, "before-poison", "", "Before", "", "Valid prefix", "completed", "agent", 10);
    const path = try summariesFilePath(allocator, workspace);
    defer allocator.free(path);
    try fsutil.appendText(path, "{\"schema\":\"var1.session_summary.v2\"");
    _ = try upsertSummary(allocator, workspace, "after-poison", "", "After", "", "Valid suffix", "completed", "agent", 20);

    const rows = try listSummaries(allocator, workspace);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("after-poison", rows[0].session_id);
    try std.testing.expectEqualStrings("before-poison", rows[1].session_id);
}

test "100 concurrent summary upserts retain every latest row and sequence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const Gate = struct {
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        ready: usize = 0,
        open: bool = false,

        fn wait(self: *@This()) void {
            self.mutex.lock();
            self.ready += 1;
            self.condition.broadcast();
            while (!self.open) self.condition.wait(&self.mutex);
            self.mutex.unlock();
        }

        fn release(self: *@This(), expected: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.ready < expected) self.condition.wait(&self.mutex);
            self.open = true;
            self.condition.broadcast();
        }
    };
    const Worker = struct {
        gate: *Gate,
        workspace: []const u8,
        index: usize,
        ok: *bool,

        fn run(self: @This()) void {
            self.gate.wait();
            var id_buffer: [32]u8 = undefined;
            const session_id = std.fmt.bufPrint(&id_buffer, "session-{d}", .{self.index}) catch return;
            const result = upsertSummary(
                std.testing.allocator,
                self.workspace,
                session_id,
                "",
                "Concurrent",
                "ledger",
                "Retained row",
                "completed",
                "agent",
                @intCast(self.index + 1),
            ) catch return;
            self.ok.* = result.turn_count == 1 and result.seq >= 1 and result.seq <= 100;
        }
    };

    var gate = Gate{};
    var results = [_]bool{false} ** 100;
    var threads: [100]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .gate = &gate,
            .workspace = workspace,
            .index = index,
            .ok = &results[index],
        }});
    }
    gate.release(threads.len);
    for (threads) |thread| thread.join();
    for (results) |ok| try std.testing.expect(ok);

    const rows = try listSummaries(allocator, workspace);
    defer {
        for (rows) |*row| row.deinit(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 100), rows.len);
    var seen_sequences = [_]bool{false} ** 101;
    for (rows) |row| {
        try std.testing.expect(row.seq >= 1 and row.seq <= 100);
        try std.testing.expect(!seen_sequences[row.seq]);
        seen_sequences[row.seq] = true;
    }
    for (seen_sequences[1..]) |seen| try std.testing.expect(seen);
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
