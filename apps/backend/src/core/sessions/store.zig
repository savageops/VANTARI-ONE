const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

/// Batched durability gate. Per-append `file.sync()` on Windows is
/// FlushFileBuffers — tens of milliseconds per call. During streaming, a
/// provider turn emits 100+ reasoning/assistant deltas; syncing each one
/// throttles the stream to ~1 token/second. Instead, sync at most once per
/// batch window, and force a final flush at turn boundaries via
/// `syncSessionLedgers`. A crash mid-turn loses at most the last window of
/// deltas — the valid-prefix reader recovers the intact prefix and the turn
/// is retried, so the durability tradeoff is bounded and recoverable.
const ledger_sync_batch_window_ms: i64 = 100;
var last_ledger_sync_ms: i64 = 0;
var last_session_touch_ms: i64 = 0;

/// Force a durable flush for a session's ledgers. Called by the executor at
/// turn boundaries (after the final assistant response / failure / cancel)
/// so committed terminal state cannot be lost. This is the true durability
/// point — the batched gate only delays, never drops, the final sync.
pub fn syncSessionLedgers(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !void {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    syncLedgerPath(events_path);
    syncLedgerPath(messages_path);
    syncLedgerPath(context_path);
}

/// Open and sync a ledger path if it exists.
fn syncLedgerPath(path: []const u8) void {
    if (!fsutil.fileExists(path)) return;
    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch return;
    defer file.close();
    file.sync() catch {};
    last_ledger_sync_ms = std.time.milliTimestamp();
}

/// Strip a leading UTF-8 BOM (\xEF\xBB\xBF) from a byte slice.  Some editors
/// and Windows tools prepend a BOM to JSONL files; without stripping, the first
/// line's JSON parse silently fails and the first record is lost.
fn stripUtf8Bom(content: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, bom)) return content[bom.len..];
    return content;
}

/// Compute a CRC32 checksum for a JSONL line, to be embedded as a `"crc32"`
/// field for tamper detection (roadmap P0-12c). The CRC is computed over the
/// line content excluding the crc32 field itself. The caller appends the
/// result as `,"crc32":"{hex}"` before the closing `}`.
pub fn computeLineCrc32(line: []const u8) u32 {
    return std.hash.Crc32.hash(line);
}

/// Verify a JSONL line's CRC32 field against its content. Returns true if the
/// CRC matches, false if it doesn't (tamper/corruption), or null if no CRC32
/// field is present (legacy entry — skip verification).
pub fn verifyLineCrc32(line: []const u8) ?bool {
    // Find the crc32 field in the line.
    const marker = "\"crc32\":\"";
    const crc_start = std.mem.indexOf(u8, line, marker) orelse return null;
    const value_start = crc_start + marker.len;
    const value_end = std.mem.indexOf(u8, line[value_start..], "\"") orelse return null;

    // The content to verify is everything before the `,"crc32":"..."` field.
    // We strip back to the comma before crc32.
    const content_end = if (crc_start > 0 and line[crc_start - 1] == ',')
        crc_start - 1
    else
        crc_start;

    const expected_crc = std.fmt.parseInt(u32, line[value_start .. value_start + value_end], 16) catch return false;
    const actual_crc = computeLineCrc32(line[0..content_end]);
    return actual_crc == expected_crc;
}

pub const InitSessionOptions = struct {
    status: types.SessionStatus = .initialized,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
};

const ParsedSessionRecord = struct {
    id: []const u8,
    prompt: []const u8,
    status: []const u8,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const ParsedSessionEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
    seq: u64 = 0,
    bytes_b64: ?[]const u8 = null,
};

const ParsedSessionMessage = struct {
    id: []const u8,
    seq: u64,
    role: []const u8,
    content: []const u8 = "",
    tool_call_id: ?[]const u8 = null,
    tool_calls: []types.ToolCall = &.{},
    timestamp_ms: i64,
    reasoning: ?[]const u8 = null,
};

const ParsedContextCheckpoint = struct {
    id: []const u8,
    type: []const u8 = "summary_checkpoint",
    created_at_ms: i64,
    source_seq_start: u64,
    source_seq_end: u64,
    first_kept_seq: u64,
    tokens_before_estimate: u64 = 0,
    tokens_after_estimate: u64 = 0,
    aggressiveness_milli: u16 = 350,
    compacted_entry_count: u32 = 0,
    trigger: []const u8,
    summary: []const u8,
    parent_checkpoint_id: ?[]const u8 = null,
    branch_seq: u64 = 0,
    branch_status: ?[]const u8 = null,
};

pub fn ensureStoreReady(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
    const sessions_root = try sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return;

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const session_path = try sessionFilePath(allocator, workspace_root, entry.name);
        defer allocator.free(session_path);
        if (!fsutil.fileExists(session_path)) continue;

        const session = try readSessionRecordRaw(allocator, session_path);
        defer session.deinit(allocator);
        try writeSessionRecord(allocator, workspace_root, session);
        const memories_path = try memoriesFilePath(allocator, workspace_root, entry.name);
        defer allocator.free(memories_path);
        if (!fsutil.fileExists(memories_path)) try fsutil.writeText(memories_path, "");
    }
}

pub fn initSession(allocator: std.mem.Allocator, workspace_root: []const u8, prompt: []const u8) !types.SessionRecord {
    return initSessionWithOptions(allocator, workspace_root, prompt, .{});
}

pub fn initSessionWithOptions(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt: []const u8,
    options: InitSessionOptions,
) !types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const id = try std.fmt.allocPrint(allocator, "session-{d}-{x}", .{ now, nonce });
    errdefer allocator.free(id);

    const prompt_copy = try allocator.dupe(u8, prompt);
    errdefer allocator.free(prompt_copy);

    const parent_session_id = if (options.parent_session_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (parent_session_id) |value| allocator.free(value);
    const continued_from_session_id = if (options.continued_from_session_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (continued_from_session_id) |value| allocator.free(value);
    const display_name = if (options.display_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_name) |value| allocator.free(value);
    const agent_profile = if (options.agent_profile) |value| try allocator.dupe(u8, value) else null;
    errdefer if (agent_profile) |value| allocator.free(value);

    const session = types.SessionRecord{
        .id = id,
        .prompt = prompt_copy,
        .status = options.status,
        .parent_session_id = parent_session_id,
        .continued_from_session_id = continued_from_session_id,
        .display_name = display_name,
        .agent_profile = agent_profile,
        .created_at_ms = now,
        .updated_at_ms = now,
    };

    try writeSessionRecord(allocator, workspace_root, session);
    try ensureInitialSessionMessage(allocator, workspace_root, session);
    const memories_path = try memoriesFilePath(allocator, workspace_root, session.id);
    defer allocator.free(memories_path);
    if (!fsutil.fileExists(memories_path)) try fsutil.writeText(memories_path, "");
    return session;
}

pub fn readSessionRecord(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const session_path = try sessionFilePath(allocator, workspace_root, session_id);
    defer allocator.free(session_path);

    const raw_content = try fsutil.readTextAlloc(allocator, session_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var parsed = try std.json.parseFromSlice(ParsedSessionRecord, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .prompt = try allocator.dupe(u8, parsed.value.prompt),
        .status = try types.parseStatusLabel(parsed.value.status),
        .parent_session_id = if (parsed.value.parent_session_id) |value| try allocator.dupe(u8, value) else null,
        .continued_from_session_id = if (parsed.value.continued_from_session_id) |value| try allocator.dupe(u8, value) else null,
        .display_name = if (parsed.value.display_name) |value| try allocator.dupe(u8, value) else null,
        .agent_profile = if (parsed.value.agent_profile) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed.value.failure_reason) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
    };
}

pub fn sessionExists(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) !bool {
    try ensureStoreReady(allocator, workspace_root);
    const path = try sessionFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    return fsutil.fileExists(path);
}

pub fn writeSessionRecord(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
) !void {
    const session_path = try sessionFilePath(allocator, workspace_root, session.id);
    defer allocator.free(session_path);

    const payload = .{
        .id = session.id,
        .prompt = session.prompt,
        .status = types.statusLabel(session.status),
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(payload, .{ .whitespace = .indent_2 }),
    });
    defer allocator.free(json);

    try fsutil.writeText(session_path, json);
}

pub fn touchSessionUpdatedAt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    timestamp_ms: i64,
) !void {
    // Batched heartbeat: session.json is rewritten at most once per batch
    // window. Per-event rewrites (read + parse + atomic temp-rename) on
    // Windows throttle streaming to ~1 token/sec — the same cost center as
    // the ledger sync gate. The stale-owner check reads the latest EVENT
    // timestamp, so the heartbeat rewrite is a display nicety, not a
    // correctness requirement; batching it is safe.
    const now_ms = std.time.milliTimestamp();
    if (now_ms - last_session_touch_ms < ledger_sync_batch_window_ms) return;
    last_session_touch_ms = now_ms;

    var session = try readSessionRecord(allocator, workspace_root, session_id);
    defer session.deinit(allocator);

    if (timestamp_ms <= session.updated_at_ms) return;
    session.updated_at_ms = timestamp_ms;
    try writeSessionRecord(allocator, workspace_root, session);
}

pub fn setSessionStatus(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    status: types.SessionStatus,
) !void {
    session.status = status;
    session.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and session.failure_reason != null) {
        allocator.free(session.failure_reason.?);
        session.failure_reason = null;
    }
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn setSessionPrompt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    prompt: []const u8,
    status: types.SessionStatus,
) !void {
    allocator.free(session.prompt);
    session.prompt = try allocator.dupe(u8, prompt);
    session.status = status;
    session.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and session.failure_reason != null) {
        allocator.free(session.failure_reason.?);
        session.failure_reason = null;
    }
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn setSessionFailure(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: *types.SessionRecord,
    failure_reason: []const u8,
) !void {
    if (session.failure_reason) |value| allocator.free(value);
    session.failure_reason = try allocator.dupe(u8, failure_reason);
    session.status = .failed;
    session.updated_at_ms = std.time.milliTimestamp();
    try writeSessionRecord(allocator, workspace_root, session.*);
}

pub fn appendEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    event: types.SessionEvent,
) !void {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    const next_seq = try nextEventSeq(allocator, events_path);

    var event_with_seq = event;
    event_with_seq.seq = next_seq;

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(event_with_seq, .{}),
    });
    defer allocator.free(jsonl);

    try appendJsonlRecord(events_path, jsonl);
}

pub fn readLatestEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?types.SessionEvent {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    if (!fsutil.fileExists(events_path)) return null;

    const raw_content = try fsutil.readTextAlloc(allocator, events_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        const slice = content[start..end];
        if (!std.unicode.utf8ValidateSlice(slice)) {
            end = if (start == 0) 0 else start - 1;
            continue;
        }

        var parsed = std.json.parseFromSlice(ParsedSessionEvent, allocator, slice, .{
            .ignore_unknown_fields = true,
        }) catch {
            end = if (start == 0) 0 else start - 1;
            continue;
        };
        defer parsed.deinit();

        return .{
            .event_type = try allocator.dupe(u8, parsed.value.event_type),
            .message = try allocator.dupe(u8, parsed.value.message),
            .timestamp_ms = parsed.value.timestamp_ms,
            .seq = parsed.value.seq,
            .bytes_b64 = if (parsed.value.bytes_b64) |b| try allocator.dupe(u8, b) else null,
        };
    }

    return null;
}

pub fn readEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]types.SessionEvent {
    const events_path = try eventsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(events_path);

    if (!fsutil.fileExists(events_path)) return allocator.alloc(types.SessionEvent, 0);

    const raw_content = try fsutil.readTextAlloc(allocator, events_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var events = std.array_list.Managed(types.SessionEvent).init(allocator);
    errdefer {
        for (events.items) |event| event.deinit(allocator);
        events.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(line)) break; // Invalid UTF-8 — poisoned line.

        var parsed = std.json.parseFromSlice(ParsedSessionEvent, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch break; // Stop at first poisoned line; return valid prefix.
        defer parsed.deinit();

        try events.append(.{
            .event_type = try allocator.dupe(u8, parsed.value.event_type),
            .message = try allocator.dupe(u8, parsed.value.message),
            .timestamp_ms = parsed.value.timestamp_ms,
            .seq = parsed.value.seq,
            .bytes_b64 = if (parsed.value.bytes_b64) |b| try allocator.dupe(u8, b) else null,
        });
    }

    return events.toOwnedSlice();
}

pub fn readSessionMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]types.SessionMessage {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) return allocator.alloc(types.SessionMessage, 0);

    return readSessionMessagesFromPath(allocator, messages_path);
}

pub fn appendSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    role: types.SessionMessageRole,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    return appendSessionMessageWithReasoning(allocator, workspace_root, session_id, role, content, null, timestamp_ms);
}

pub fn appendSessionMessageWithReasoning(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    role: types.SessionMessageRole,
    content: []const u8,
    reasoning: ?[]const u8,
    timestamp_ms: i64,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) {
        try writeSessionMessages(allocator, messages_path, &.{});
    }

    const next_seq = try nextSessionMessageSeq(allocator, messages_path);
    const message_id = try sessionMessageId(allocator, next_seq);
    defer allocator.free(message_id);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .id = message_id,
            .seq = next_seq,
            .role = types.sessionMessageRoleLabel(role),
            .content = content,
            .reasoning = reasoning,
            .timestamp_ms = timestamp_ms,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try appendJsonlRecord(messages_path, jsonl);
}

pub fn upsertAssistantSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    return appendSessionMessageWithReasoning(allocator, workspace_root, session_id, .assistant, content, null, timestamp_ms);
}

pub fn upsertAssistantSessionMessageWithReasoning(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    content: []const u8,
    reasoning: ?[]const u8,
    timestamp_ms: i64,
) !void {
    return appendSessionMessageWithReasoning(allocator, workspace_root, session_id, .assistant, content, reasoning, timestamp_ms);
}

pub fn appendAssistantToolCallSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    content: ?[]const u8,
    tool_calls: []const types.ToolCall,
    reasoning: ?[]const u8,
    timestamp_ms: i64,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) {
        try writeSessionMessages(allocator, messages_path, &.{});
    }

    const next_seq = try nextSessionMessageSeq(allocator, messages_path);
    const message_id = try sessionMessageId(allocator, next_seq);
    defer allocator.free(message_id);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .id = message_id,
            .seq = next_seq,
            .role = types.sessionMessageRoleLabel(.assistant),
            .content = content orelse "",
            .tool_calls = tool_calls,
            .reasoning = reasoning,
            .timestamp_ms = timestamp_ms,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try appendJsonlRecord(messages_path, jsonl);
}

pub fn appendToolSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    tool_call_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(messages_path);

    if (!fsutil.fileExists(messages_path)) {
        try writeSessionMessages(allocator, messages_path, &.{});
    }

    const next_seq = try nextSessionMessageSeq(allocator, messages_path);
    const message_id = try sessionMessageId(allocator, next_seq);
    defer allocator.free(message_id);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .id = message_id,
            .seq = next_seq,
            .role = types.sessionMessageRoleLabel(.tool),
            .content = content,
            .tool_call_id = tool_call_id,
            .timestamp_ms = timestamp_ms,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try appendJsonlRecord(messages_path, jsonl);
}

pub fn appendContextCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    checkpoint: types.ContextCheckpoint,
) !void {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    // Build the JSON manually so we can conditionally include shard fields
    // (parent_checkpoint_id, branch_seq) only when they are meaningful.
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.print(
        "{{\"id\":{f},\"type\":{f},\"created_at_ms\":{d},\"source_seq_start\":{d},\"source_seq_end\":{d},\"first_kept_seq\":{d},\"tokens_before_estimate\":{d},\"tokens_after_estimate\":{d},\"aggressiveness_milli\":{d},\"compacted_entry_count\":{d},\"trigger\":{f},\"summary\":{f}",
        .{
            std.json.fmt(checkpoint.id, .{}),
            std.json.fmt(checkpoint.entry_type, .{}),
            checkpoint.created_at_ms,
            checkpoint.source_seq_start,
            checkpoint.source_seq_end,
            checkpoint.first_kept_seq,
            checkpoint.tokens_before_estimate,
            checkpoint.tokens_after_estimate,
            checkpoint.aggressiveness_milli,
            checkpoint.compacted_entry_count,
            std.json.fmt(checkpoint.trigger, .{}),
            std.json.fmt(checkpoint.summary, .{}),
        },
    );

    // Shard checkpoint fields: include only when this is a shard entry.
    if (checkpoint.parent_checkpoint_id) |parent_id| {
        try writer.print(",\"parent_checkpoint_id\":{f},\"branch_seq\":{d}", .{
            std.json.fmt(parent_id, .{}),
            checkpoint.branch_seq,
        });
    }

    try writer.writeAll("}\n");

    try appendJsonlRecord(context_path, output.items);
    output.deinit();
}

/// Append a shard checkpoint entry to context.jsonl. A shard checkpoint
/// references a parent checkpoint and marks a branch's lifecycle state
/// (open, converged, abandoned). This is the shard ledger primitive (P0-1).
pub fn appendShardCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    parent_checkpoint_id: []const u8,
    branch_seq: u64,
    branch_status: types.ShardStatus,
    branch_summary: []const u8,
) !void {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    const checkpoint_id = try checkpointIdAlloc(allocator);
    defer allocator.free(checkpoint_id);
    const entry_type = try allocator.dupe(u8, "shard_checkpoint");
    defer allocator.free(entry_type);
    const trigger = try allocator.dupe(u8, "branch");
    defer allocator.free(trigger);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.print(
        "{{\"id\":{f},\"type\":\"shard_checkpoint\",\"created_at_ms\":{d},\"source_seq_start\":0,\"source_seq_end\":0,\"first_kept_seq\":0,\"tokens_before_estimate\":0,\"tokens_after_estimate\":0,\"aggressiveness_milli\":0,\"compacted_entry_count\":0,\"trigger\":{f},\"summary\":{f},\"parent_checkpoint_id\":{f},\"branch_seq\":{d},\"branch_status\":{f}}}\n",
        .{
            std.json.fmt(checkpoint_id, .{}),
            std.time.milliTimestamp(),
            std.json.fmt(trigger, .{}),
            std.json.fmt(branch_summary, .{}),
            std.json.fmt(parent_checkpoint_id, .{}),
            branch_seq,
            std.json.fmt(branch_status.label(), .{}),
        },
    );

    try appendJsonlRecord(context_path, output.items);
    output.deinit();
}

fn checkpointIdAlloc(allocator: std.mem.Allocator) ![]u8 {
    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    return std.fmt.allocPrint(allocator, "checkpoint-{d}-{x}", .{ now, nonce });
}

pub fn readLatestContextCheckpoint(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?types.ContextCheckpoint {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    if (!fsutil.fileExists(context_path)) return null;

    const raw_content = try fsutil.readTextAlloc(allocator, context_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        const line = std.mem.trim(u8, content[start..end], " \r");
        if (line.len > 0 and std.unicode.utf8ValidateSlice(line)) {
            var parsed = std.json.parseFromSlice(ParsedContextCheckpoint, allocator, line, .{
                .ignore_unknown_fields = true,
            }) catch {
                end = if (start == 0) 0 else start - 1;
                continue;
            };
            defer parsed.deinit();

            return .{
                .id = try allocator.dupe(u8, parsed.value.id),
                .entry_type = try allocator.dupe(u8, parsed.value.type),
                .created_at_ms = parsed.value.created_at_ms,
                .source_seq_start = parsed.value.source_seq_start,
                .source_seq_end = parsed.value.source_seq_end,
                .first_kept_seq = parsed.value.first_kept_seq,
                .tokens_before_estimate = parsed.value.tokens_before_estimate,
                .tokens_after_estimate = parsed.value.tokens_after_estimate,
                .aggressiveness_milli = parsed.value.aggressiveness_milli,
                .compacted_entry_count = parsed.value.compacted_entry_count,
                .trigger = try allocator.dupe(u8, parsed.value.trigger),
                .summary = try allocator.dupe(u8, parsed.value.summary),
                .parent_checkpoint_id = if (parsed.value.parent_checkpoint_id) |pid| try allocator.dupe(u8, pid) else null,
                .branch_seq = parsed.value.branch_seq,
            };
        }

        end = if (start == 0) 0 else start - 1;
    }

    return null;
}

/// Read all context checkpoints from context.jsonl in forward order.
/// Used by shard-graph cold-start recovery to find open shard entries
/// that may need reconciliation (roadmap P0-4b).
pub fn readAllContextCheckpoints(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]types.ContextCheckpoint {
    const context_path = try contextFilePath(allocator, workspace_root, session_id);
    defer allocator.free(context_path);

    if (!fsutil.fileExists(context_path)) return allocator.alloc(types.ContextCheckpoint, 0);

    const raw_content = try fsutil.readTextAlloc(allocator, context_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var checkpoints = std.array_list.Managed(types.ContextCheckpoint).init(allocator);
    errdefer {
        for (checkpoints.items) |cp| cp.deinit(allocator);
        checkpoints.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(line)) break;

        var parsed = std.json.parseFromSlice(ParsedContextCheckpoint, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch break;
        defer parsed.deinit();

        try checkpoints.append(.{
            .id = try allocator.dupe(u8, parsed.value.id),
            .entry_type = try allocator.dupe(u8, parsed.value.type),
            .created_at_ms = parsed.value.created_at_ms,
            .source_seq_start = parsed.value.source_seq_start,
            .source_seq_end = parsed.value.source_seq_end,
            .first_kept_seq = parsed.value.first_kept_seq,
            .tokens_before_estimate = parsed.value.tokens_before_estimate,
            .tokens_after_estimate = parsed.value.tokens_after_estimate,
            .aggressiveness_milli = parsed.value.aggressiveness_milli,
            .compacted_entry_count = parsed.value.compacted_entry_count,
            .trigger = try allocator.dupe(u8, parsed.value.trigger),
            .summary = try allocator.dupe(u8, parsed.value.summary),
            .parent_checkpoint_id = if (parsed.value.parent_checkpoint_id) |pid| try allocator.dupe(u8, pid) else null,
            .branch_seq = parsed.value.branch_seq,
            .branch_status = if (parsed.value.branch_status) |bs| types.ShardStatus.parse(bs) else null,
        });
    }

    return checkpoints.toOwnedSlice();
}

pub fn listSessionRecords(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]types.SessionRecord {
    try ensureStoreReady(allocator, workspace_root);

    const sessions_root = try sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return allocator.alloc(types.SessionRecord, 0);

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var sessions = std.array_list.Managed(types.SessionRecord).init(allocator);
    errdefer {
        for (sessions.items) |session| session.deinit(allocator);
        sessions.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const session = readSessionRecord(allocator, workspace_root, entry.name) catch continue;
        try sessions.append(session);
    }

    std.mem.sortUnstable(types.SessionRecord, sessions.items, {}, struct {
        fn lessThan(_: void, left: types.SessionRecord, right: types.SessionRecord) bool {
            if (left.updated_at_ms == right.updated_at_ms) {
                return left.created_at_ms > right.created_at_ms;
            }
            return left.updated_at_ms > right.updated_at_ms;
        }
    }.lessThan);

    return sessions.toOwnedSlice();
}

pub fn writeOutput(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    output: []const u8,
) !void {
    const output_path = try outputFilePath(allocator, workspace_root, session_id);
    defer allocator.free(output_path);
    try fsutil.writeText(output_path, output);
}

pub fn readOutput(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !?[]u8 {
    const output_path = try outputFilePath(allocator, workspace_root, session_id);
    defer allocator.free(output_path);

    if (!fsutil.fileExists(output_path)) return null;
    const output = try fsutil.readTextAlloc(allocator, output_path);
    return output;
}

fn ensureInitialSessionMessage(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
) !void {
    const messages_path = try messagesFilePath(allocator, workspace_root, session.id);
    defer allocator.free(messages_path);

    if (fsutil.fileExists(messages_path)) return;

    try appendSessionMessage(allocator, workspace_root, session.id, .user, session.prompt, session.created_at_ms);
}

fn readSessionMessagesFromPath(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
) ![]types.SessionMessage {
    const raw_content = try fsutil.readTextAlloc(allocator, messages_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var messages = std.array_list.Managed(types.SessionMessage).init(allocator);
    errdefer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(line)) break; // Invalid UTF-8 — poisoned line.

        var parsed = std.json.parseFromSlice(ParsedSessionMessage, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch break; // Stop at first poisoned line; return valid prefix.
        defer parsed.deinit();

        try messages.append(try cloneParsedSessionMessage(allocator, parsed.value));
    }

    return messages.toOwnedSlice();
}

fn cloneParsedSessionMessage(
    allocator: std.mem.Allocator,
    parsed: ParsedSessionMessage,
) !types.SessionMessage {
    const role = try types.parseSessionMessageRole(parsed.role);
    const id = try allocator.dupe(u8, parsed.id);
    errdefer allocator.free(id);
    const content_copy = try allocator.dupe(u8, parsed.content);
    errdefer allocator.free(content_copy);
    const tool_call_id = if (parsed.tool_call_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (tool_call_id) |value| allocator.free(value);
    const tool_calls = try types.cloneToolCalls(allocator, parsed.tool_calls);
    errdefer {
        for (tool_calls) |tool_call| tool_call.deinit(allocator);
        if (tool_calls.len > 0) allocator.free(tool_calls);
    }

    const reasoning = if (parsed.reasoning) |value| try allocator.dupe(u8, value) else null;
    errdefer if (reasoning) |value| allocator.free(value);

    return .{
        .id = id,
        .seq = parsed.seq,
        .role = role,
        .content = content_copy,
        .tool_call_id = tool_call_id,
        .tool_calls = tool_calls,
        .timestamp_ms = parsed.timestamp_ms,
        .reasoning = reasoning,
    };
}

fn writeSessionMessages(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
    messages: []const types.SessionMessage,
) !void {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    const writer = body.writer();

    for (messages) |message| {
        try writer.print("{f}\n", .{
            std.json.fmt(.{
                .id = message.id,
                .seq = message.seq,
                .role = types.sessionMessageRoleLabel(message.role),
                .content = message.content,
                .tool_call_id = message.tool_call_id,
                .tool_calls = message.tool_calls,
                .timestamp_ms = message.timestamp_ms,
            }, .{}),
        });
    }

    try fsutil.writeText(messages_path, body.items);
}

fn appendJsonlRecord(
    path: []const u8,
    jsonl: []const u8,
) !void {
    try fsutil.ensureParent(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        }),
        else => return err,
    };
    defer file.close();

    var end_position = try file.getEndPos();
    if (end_position > 0) {
        var tail: [1]u8 = undefined;
        const read_count = try file.preadAll(tail[0..], end_position - 1);
        if (read_count == 1 and tail[0] != '\n') {
            try file.pwriteAll("\n", end_position);
            end_position += 1;
        }
    }

    try file.pwriteAll(jsonl, end_position);

    // Batched durability gate: flush the OS page cache at most once per
    // batch window. Per-append FlushFileBuffers on Windows throttles
    // provider streaming to ~1 token/sec; batching keeps the stream fast
    // while bounding crash loss to the last window of deltas. Terminal
    // turn boundaries force a full flush via `syncSessionLedgers`.
    const now_ms = std.time.milliTimestamp();
    if (now_ms - last_ledger_sync_ms >= ledger_sync_batch_window_ms) {
        file.sync() catch {};
        last_ledger_sync_ms = now_ms;
    }
}

pub fn sessionsRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const path = try fsutil.join(allocator, &.{ root, "sessions" });
    std.fs.cwd().makePath(path) catch {};
    return path;
}

pub fn sessionDirPath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const path = try fsutil.join(allocator, &.{ root, "sessions", session_id });
    std.fs.cwd().makePath(path) catch {};
    return path;
}

pub fn sessionFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "session.json" });
}

fn eventsFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "events.jsonl" });
}

fn messagesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "messages.jsonl" });
}

pub fn contextFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "context.jsonl" });
}

pub fn memoriesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "memories.jsonl" });
}

/// Path to the write-intent ledger (roadmap P0-5b). Records write-tool
/// mutations in two phases: "reserved" (before mutation) and "committed"
/// (after mutation). At cold start, reserved-without-committed = abandoned.
pub fn intentsFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "intents.jsonl" });
}

/// Reserve a write intent before mutation. The intent records the tool,
/// resolved path, and before-hash so that a crash after this point but
/// before the commit leaves durable evidence of an incomplete write.
pub fn reserveWriteIntent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    intent_id: []const u8,
    tool_name: []const u8,
    resolved_path: []const u8,
    before_sha256: ?[]const u8,
) !void {
    const path = try intentsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    try writer.print(
        "{{\"id\":{f},\"status\":\"reserved\",\"tool\":{f},\"path\":{f},\"before_sha256\":",
        .{
            std.json.fmt(intent_id, .{}),
            std.json.fmt(tool_name, .{}),
            std.json.fmt(resolved_path, .{}),
        },
    );
    if (before_sha256) |hash| {
        try writer.print("{f}", .{std.json.fmt(hash, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"reserved_at_ms\":{d}}}\n", .{std.time.milliTimestamp()});

    try appendJsonlRecord(path, output.items);
    output.deinit();
}

/// Commit a write intent after successful mutation. The after-hash proves
/// the mutation completed and records the final state for reconciliation.
pub fn commitWriteIntent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    intent_id: []const u8,
    after_sha256: ?[]const u8,
    bytes_written: usize,
) !void {
    const path = try intentsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    try writer.print(
        "{{\"id\":{f},\"status\":\"committed\",\"after_sha256\":",
        .{std.json.fmt(intent_id, .{})},
    );
    if (after_sha256) |hash| {
        try writer.print("{f}", .{std.json.fmt(hash, .{})});
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"bytes_written\":{d},\"committed_at_ms\":{d}}}\n", .{ bytes_written, std.time.milliTimestamp() });

    try appendJsonlRecord(path, output.items);
    output.deinit();
}

/// A parsed write-intent entry from the ledger.
pub const IntentEntry = struct {
    id: []u8,
    status: []u8,
    tool: ?[]u8 = null,
    path: ?[]u8 = null,
    before_sha256: ?[]u8 = null,
    after_sha256: ?[]u8 = null,
    bytes_written: usize = 0,

    pub fn deinit(self: IntentEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.status);
        if (self.tool) |v| allocator.free(v);
        if (self.path) |v| allocator.free(v);
        if (self.before_sha256) |v| allocator.free(v);
        if (self.after_sha256) |v| allocator.free(v);
    }
};

const ParsedIntentEntry = struct {
    id: []const u8,
    status: []const u8,
    tool: ?[]const u8 = null,
    path: ?[]const u8 = null,
    before_sha256: ?[]const u8 = null,
    after_sha256: ?[]const u8 = null,
    bytes_written: usize = 0,
};

/// Read all intent entries from the ledger. Used by cold-start reconciliation
/// to find reserved-without-committed (abandoned) intents.
pub fn readWriteIntents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]IntentEntry {
    const path = try intentsFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return allocator.alloc(IntentEntry, 0);

    const raw_content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var entries = std.array_list.Managed(IntentEntry).init(allocator);
    errdefer {
        for (entries.items) |e| e.deinit(allocator);
        entries.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (!std.unicode.utf8ValidateSlice(line)) break;

        var parsed = std.json.parseFromSlice(ParsedIntentEntry, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch break;
        defer parsed.deinit();

        try entries.append(.{
            .id = try allocator.dupe(u8, parsed.value.id),
            .status = try allocator.dupe(u8, parsed.value.status),
            .tool = if (parsed.value.tool) |v| try allocator.dupe(u8, v) else null,
            .path = if (parsed.value.path) |v| try allocator.dupe(u8, v) else null,
            .before_sha256 = if (parsed.value.before_sha256) |v| try allocator.dupe(u8, v) else null,
            .after_sha256 = if (parsed.value.after_sha256) |v| try allocator.dupe(u8, v) else null,
            .bytes_written = parsed.value.bytes_written,
        });
    }

    return entries.toOwnedSlice();
}

/// Reconcile abandoned write intents at cold start. Returns the count of
/// reserved intents that have no matching committed entry (crash mid-write).
pub fn reconcileAbandonedIntents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) !usize {
    const intents = try readWriteIntents(allocator, workspace_root, session_id);
    defer {
        for (intents) |e| e.deinit(allocator);
        allocator.free(intents);
    }

    var abandoned: usize = 0;
    for (intents) |entry| {
        if (!std.mem.eql(u8, entry.status, "reserved")) continue;

        // Check if a later "committed" entry with the same id exists.
        var committed = false;
        for (intents) |other| {
            if (std.mem.eql(u8, other.id, entry.id) and
                std.mem.eql(u8, other.status, "committed"))
            {
                committed = true;
                break;
            }
        }

        if (!committed) abandoned += 1;
    }

    return abandoned;
}

/// Return the latest durable transcript sequence for memory provenance.
pub fn latestMessageSeq(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) !?u64 {
    const path = try messagesFilePath(allocator, workspace_root, session_id);
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return null;
    const messages = try readSessionMessagesFromPath(allocator, path);
    defer {
        for (messages) |message| message.deinit(allocator);
        allocator.free(messages);
    }
    if (messages.len == 0) return null;
    return messages[messages.len - 1].seq;
}

fn outputFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, session_id: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "sessions", session_id, "output.txt" });
}

fn nextSessionMessageSeq(
    allocator: std.mem.Allocator,
    messages_path: []const u8,
) !u64 {
    if (!fsutil.fileExists(messages_path)) return 1;

    const messages = try readSessionMessagesFromPath(allocator, messages_path);
    defer types.deinitSessionMessages(allocator, messages);

    var max_seq: u64 = 0;
    for (messages) |message| {
        if (message.seq > max_seq) max_seq = message.seq;
    }
    return max_seq + 1;
}

/// Compute the next monotonic seq for `events.jsonl` via a backward tail scan.
/// Because events are strictly append-ordered, the max seq is the seq of the
/// last parseable line. This is O(1)-ish per append — it does not read or parse
/// the entire file. Unparseable trailing lines (torn writes) are skipped.
fn nextEventSeq(
    allocator: std.mem.Allocator,
    events_path: []const u8,
) !u64 {
    if (!fsutil.fileExists(events_path)) return 1;

    const content = try fsutil.readTextAlloc(allocator, events_path);
    defer allocator.free(content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        var parsed = std.json.parseFromSlice(ParsedSessionEvent, allocator, content[start..end], .{
            .ignore_unknown_fields = true,
        }) catch {
            end = if (start == 0) 0 else start - 1;
            continue;
        };
        defer parsed.deinit();

        return parsed.value.seq + 1;
    }

    return 1;
}

fn sessionMessageId(allocator: std.mem.Allocator, seq: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "msg-{d}", .{seq});
}

fn readSessionRecordRaw(
    allocator: std.mem.Allocator,
    session_path: []const u8,
) !types.SessionRecord {
    const raw_content = try fsutil.readTextAlloc(allocator, session_path);
    defer allocator.free(raw_content);
    const content = stripUtf8Bom(raw_content);

    var parsed = try std.json.parseFromSlice(ParsedSessionRecord, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .prompt = try allocator.dupe(u8, parsed.value.prompt),
        .status = try types.parseStatusLabel(parsed.value.status),
        .parent_session_id = if (parsed.value.parent_session_id) |value| try allocator.dupe(u8, value) else null,
        .continued_from_session_id = if (parsed.value.continued_from_session_id) |value| try allocator.dupe(u8, value) else null,
        .display_name = if (parsed.value.display_name) |value| try allocator.dupe(u8, value) else null,
        .agent_profile = if (parsed.value.agent_profile) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed.value.failure_reason) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
    };
}
