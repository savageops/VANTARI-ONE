const std = @import("std");
const fsutil = @import("fsutil.zig");
const types = @import("types.zig");

// TODO: Keep session persistence canonical and append-only as new durable surfaces land.

pub const InitTaskOptions = struct {
    status: types.TaskStatus = .running,
    parent_task_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
};

const ParsedTaskRecord = struct {
    id: []const u8,
    prompt: []const u8,
    status: []const u8,
    parent_task_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
};

const ParsedJournalEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
};

const ParsedConversationTurn = struct {
    role: []const u8,
    content: []const u8,
    timestamp_ms: i64,
};

pub fn initTask(allocator: std.mem.Allocator, workspace_root: []const u8, prompt: []const u8) !types.TaskRecord {
    return initTaskWithOptions(allocator, workspace_root, prompt, .{});
}

pub fn initTaskWithOptions(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    prompt: []const u8,
    options: InitTaskOptions,
) !types.TaskRecord {
    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const id = try std.fmt.allocPrint(allocator, "task-{d}-{x}", .{ now, nonce });
    errdefer allocator.free(id);

    const prompt_copy = try allocator.dupe(u8, prompt);
    errdefer allocator.free(prompt_copy);

    const parent_task_id = if (options.parent_task_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (parent_task_id) |value| allocator.free(value);
    const display_name = if (options.display_name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (display_name) |value| allocator.free(value);
    const agent_profile = if (options.agent_profile) |value| try allocator.dupe(u8, value) else null;
    errdefer if (agent_profile) |value| allocator.free(value);

    const task = types.TaskRecord{
        .id = id,
        .prompt = prompt_copy,
        .status = options.status,
        .parent_task_id = parent_task_id,
        .display_name = display_name,
        .agent_profile = agent_profile,
        .created_at_ms = now,
        .updated_at_ms = now,
    };

    try writeTaskRecord(allocator, workspace_root, task);
    try ensureInitialConversationTurn(allocator, workspace_root, task);
    return task;
}

pub fn readTaskRecord(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !types.TaskRecord {
    const task_path = try taskFilePath(allocator, workspace_root, task_id);
    defer allocator.free(task_path);

    const content = try fsutil.readTextAlloc(allocator, task_path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ParsedTaskRecord, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .prompt = try allocator.dupe(u8, parsed.value.prompt),
        .status = try types.parseStatusLabel(parsed.value.status),
        .parent_task_id = if (parsed.value.parent_task_id) |value| try allocator.dupe(u8, value) else null,
        .display_name = if (parsed.value.display_name) |value| try allocator.dupe(u8, value) else null,
        .agent_profile = if (parsed.value.agent_profile) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed.value.failure_reason) |value| try allocator.dupe(u8, value) else null,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
    };
}

pub fn taskExists(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) !bool {
    const path = try taskFilePath(allocator, workspace_root, task_id);
    defer allocator.free(path);
    return fsutil.fileExists(path);
}

pub fn writeTaskRecord(allocator: std.mem.Allocator, workspace_root: []const u8, task: types.TaskRecord) !void {
    const task_path = try taskFilePath(allocator, workspace_root, task.id);
    defer allocator.free(task_path);

    const payload = .{
        .id = task.id,
        .prompt = task.prompt,
        .status = types.statusLabel(task.status),
        .parent_task_id = task.parent_task_id,
        .display_name = task.display_name,
        .agent_profile = task.agent_profile,
        .failure_reason = task.failure_reason,
        .created_at_ms = task.created_at_ms,
        .updated_at_ms = task.updated_at_ms,
    };
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(payload, .{ .whitespace = .indent_2 }),
    });
    defer allocator.free(json);

    try fsutil.writeText(task_path, json);
}

pub fn setTaskStatus(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task: *types.TaskRecord,
    status: types.TaskStatus,
) !void {
    task.status = status;
    task.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and task.failure_reason != null) {
        allocator.free(task.failure_reason.?);
        task.failure_reason = null;
    }
    try writeTaskRecord(allocator, workspace_root, task.*);
}

pub fn setTaskPrompt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task: *types.TaskRecord,
    prompt: []const u8,
    status: types.TaskStatus,
) !void {
    allocator.free(task.prompt);
    task.prompt = try allocator.dupe(u8, prompt);
    task.status = status;
    task.updated_at_ms = std.time.milliTimestamp();
    if (status != .failed and task.failure_reason != null) {
        allocator.free(task.failure_reason.?);
        task.failure_reason = null;
    }
    try writeTaskRecord(allocator, workspace_root, task.*);
}

pub fn setTaskFailure(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task: *types.TaskRecord,
    failure_reason: []const u8,
) !void {
    if (task.failure_reason) |value| allocator.free(value);
    task.failure_reason = try allocator.dupe(u8, failure_reason);
    task.status = .failed;
    task.updated_at_ms = std.time.milliTimestamp();
    try writeTaskRecord(allocator, workspace_root, task.*);
}

pub fn appendJournal(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
    event: types.JournalEvent,
) !void {
    const journal_path = try journalFilePath(allocator, workspace_root, task_id);
    defer allocator.free(journal_path);

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(event, .{}),
    });
    defer allocator.free(jsonl);

    try fsutil.appendText(journal_path, jsonl);
}

pub fn readLatestJournalEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !?types.JournalEvent {
    const journal_path = try journalFilePath(allocator, workspace_root, task_id);
    defer allocator.free(journal_path);

    if (!fsutil.fileExists(journal_path)) return null;

    const content = try fsutil.readTextAlloc(allocator, journal_path);
    defer allocator.free(content);

    var end = content.len;
    while (end > 0) {
        while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r')) : (end -= 1) {}
        if (end == 0) break;

        var start = end;
        while (start > 0 and content[start - 1] != '\n') : (start -= 1) {}

        var parsed = std.json.parseFromSlice(ParsedJournalEvent, allocator, content[start..end], .{
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
        };
    }

    return null;
}

pub fn readJournalEvents(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) ![]types.JournalEvent {
    const journal_path = try journalFilePath(allocator, workspace_root, task_id);
    defer allocator.free(journal_path);

    if (!fsutil.fileExists(journal_path)) return allocator.alloc(types.JournalEvent, 0);

    const content = try fsutil.readTextAlloc(allocator, journal_path);
    defer allocator.free(content);

    var events = std.array_list.Managed(types.JournalEvent).init(allocator);
    errdefer {
        for (events.items) |event| event.deinit(allocator);
        events.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(ParsedJournalEvent, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        try events.append(.{
            .event_type = try allocator.dupe(u8, parsed.value.event_type),
            .message = try allocator.dupe(u8, parsed.value.message),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return events.toOwnedSlice();
}

pub fn readConversationTurns(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) ![]types.ConversationTurn {
    const turns_path = try turnsFilePath(allocator, workspace_root, task_id);
    defer allocator.free(turns_path);

    if (!fsutil.fileExists(turns_path)) return allocator.alloc(types.ConversationTurn, 0);

    return readConversationTurnsFromPath(allocator, turns_path);
}

pub fn appendConversationTurn(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
    role: types.ConversationTurnRole,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    const turns_path = try turnsFilePath(allocator, workspace_root, task_id);
    defer allocator.free(turns_path);

    if (!fsutil.fileExists(turns_path)) {
        try writeConversationTurns(allocator, turns_path, &.{});
    }

    const jsonl = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .role = types.conversationTurnRoleLabel(role),
            .content = content,
            .timestamp_ms = timestamp_ms,
        }, .{}),
    });
    defer allocator.free(jsonl);

    try fsutil.appendText(turns_path, jsonl);
}

pub fn upsertAssistantConversationTurn(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    const turns_path = try turnsFilePath(allocator, workspace_root, task_id);
    defer allocator.free(turns_path);

    var turns = try readConversationTurns(allocator, workspace_root, task_id);
    defer types.deinitConversationTurns(allocator, turns);

    if (turns.len > 0 and turns[turns.len - 1].role == .assistant) {
        allocator.free(turns[turns.len - 1].content);
        turns[turns.len - 1].content = try allocator.dupe(u8, content);
        turns[turns.len - 1].timestamp_ms = timestamp_ms;
    } else {
        const expanded = try allocator.realloc(turns, turns.len + 1);
        turns = expanded;
        turns[turns.len - 1] = .{
            .role = .assistant,
            .content = try allocator.dupe(u8, content),
            .timestamp_ms = timestamp_ms,
        };
    }

    try writeConversationTurns(allocator, turns_path, turns);
}

pub fn listTaskRecords(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) ![]types.TaskRecord {
    const tasks_root = try tasksRootPath(allocator, workspace_root);
    defer allocator.free(tasks_root);

    if (!fsutil.fileExists(tasks_root)) return allocator.alloc(types.TaskRecord, 0);

    const tasks_root_abs = try fsutil.resolveAbsolute(allocator, tasks_root);
    defer allocator.free(tasks_root_abs);

    var dir = try std.fs.openDirAbsolute(tasks_root_abs, .{ .iterate = true });
    defer dir.close();

    var tasks = std.array_list.Managed(types.TaskRecord).init(allocator);
    errdefer {
        for (tasks.items) |task| task.deinit(allocator);
        tasks.deinit();
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const task = readTaskRecord(allocator, workspace_root, entry.name) catch continue;
        try tasks.append(task);
    }

    std.mem.sortUnstable(types.TaskRecord, tasks.items, {}, struct {
        fn lessThan(_: void, left: types.TaskRecord, right: types.TaskRecord) bool {
            if (left.updated_at_ms == right.updated_at_ms) {
                return left.created_at_ms > right.created_at_ms;
            }
            return left.updated_at_ms > right.updated_at_ms;
        }
    }.lessThan);

    return tasks.toOwnedSlice();
}

pub fn writeFinalAnswer(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
    answer: []const u8,
) !void {
    const result_path = try resultFilePath(allocator, workspace_root, task_id);
    defer allocator.free(result_path);
    try fsutil.writeText(result_path, answer);
}

pub fn readFinalAnswer(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !?[]u8 {
    const result_path = try resultFilePath(allocator, workspace_root, task_id);
    defer allocator.free(result_path);

    if (!fsutil.fileExists(result_path)) return null;
    const answer = try fsutil.readTextAlloc(allocator, result_path);
    return answer;
}

fn ensureInitialConversationTurn(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task: types.TaskRecord,
) !void {
    const turns_path = try turnsFilePath(allocator, workspace_root, task.id);
    defer allocator.free(turns_path);

    if (fsutil.fileExists(turns_path)) return;

    try writeConversationTurns(allocator, turns_path, &.{
        .{
            .role = .user,
            .content = task.prompt,
            .timestamp_ms = task.created_at_ms,
        },
    });
}

fn readConversationTurnsFromPath(
    allocator: std.mem.Allocator,
    turns_path: []const u8,
) ![]types.ConversationTurn {
    const content = try fsutil.readTextAlloc(allocator, turns_path);
    defer allocator.free(content);

    var turns = std.array_list.Managed(types.ConversationTurn).init(allocator);
    errdefer {
        for (turns.items) |turn| turn.deinit(allocator);
        turns.deinit();
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(ParsedConversationTurn, allocator, line, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        try turns.append(.{
            .role = try types.parseConversationTurnRole(parsed.value.role),
            .content = try allocator.dupe(u8, parsed.value.content),
            .timestamp_ms = parsed.value.timestamp_ms,
        });
    }

    return turns.toOwnedSlice();
}

fn writeConversationTurns(
    allocator: std.mem.Allocator,
    turns_path: []const u8,
    turns: []const types.ConversationTurn,
) !void {
    var body = std.array_list.Managed(u8).init(allocator);
    defer body.deinit();
    const writer = body.writer();

    for (turns) |turn| {
        try writer.print("{f}\n", .{
            std.json.fmt(.{
                .role = types.conversationTurnRoleLabel(turn.role),
                .content = turn.content,
                .timestamp_ms = turn.timestamp_ms,
            }, .{}),
        });
    }

    try fsutil.writeText(turns_path, body.items);
}

pub fn tasksRootPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions" });
}

pub fn taskDirPath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_id });
}

pub fn taskFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_id, "session.json" });
}

fn journalFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_id, "journal.jsonl" });
}

fn turnsFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_id, "turns.jsonl" });
}

fn resultFilePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "sessions", task_id, "answer.txt" });
}
