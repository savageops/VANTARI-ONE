const std = @import("std");
const fsutil = @import("fsutil.zig");
const types = @import("types.zig");

// TODO: Keep .var process tracking as a hard gate for progress visibility.

pub fn ensureRunStart(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
    const log_path = try runLogPath(allocator, workspace_root);
    defer allocator.free(log_path);
    if (!fsutil.fileExists(log_path)) {
        try fsutil.writeText(log_path, "# VAR1 Harness Changelog Log\n\n");
    }

    const log_contents = try fsutil.readTextAlloc(allocator, log_path);
    allocator.free(log_contents);

    const memories_path = try memoriesFilePath(allocator, workspace_root);
    defer allocator.free(memories_path);
    if (!fsutil.fileExists(memories_path)) {
        try fsutil.writeText(memories_path, "# VAR1 Project Memories\n\n");
    }

    const memory_contents = try fsutil.readTextAlloc(allocator, memories_path);
    allocator.free(memory_contents);
}

pub fn writePending(allocator: std.mem.Allocator, workspace_root: []const u8, snapshot: types.ProgressSnapshot) !void {
    try ensureRunStart(allocator, workspace_root);

    const pending_path = try todoSlicePath(allocator, workspace_root, snapshot.task_id);
    defer allocator.free(pending_path);

    const content = try renderTaskDoc(allocator, snapshot);
    defer allocator.free(content);
    try fsutil.writeText(pending_path, content);
}

pub fn completeTask(allocator: std.mem.Allocator, workspace_root: []const u8, snapshot: types.ProgressSnapshot) !void {
    try ensureRunStart(allocator, workspace_root);

    const pending_path = try todoSlicePath(allocator, workspace_root, snapshot.task_id);
    defer allocator.free(pending_path);

    const changelog_path = try changelogSlicePath(allocator, workspace_root, snapshot.task_id);
    defer allocator.free(changelog_path);

    const content = try renderTaskDoc(allocator, snapshot);
    defer allocator.free(content);

    try fsutil.writeText(pending_path, content);
    try fsutil.moveFile(pending_path, changelog_path);
}

pub fn appendLog(allocator: std.mem.Allocator, workspace_root: []const u8, message: []const u8) !void {
    try ensureRunStart(allocator, workspace_root);

    const log_path = try runLogPath(allocator, workspace_root);
    defer allocator.free(log_path);

    const line = try std.fmt.allocPrint(allocator, "- {d}: {s}\n", .{
        std.time.milliTimestamp(),
        message,
    });
    defer allocator.free(line);
    try fsutil.appendText(log_path, line);
}

pub fn runLogPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", "_log.md" });
}

pub fn memoriesFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "memories", "memories.md" });
}

pub fn todoSlicePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "todos", "task", task_id, "todo-slice1.md" });
}

pub fn changelogSlicePath(allocator: std.mem.Allocator, workspace_root: []const u8, task_id: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "changelog", task_id, "todo-slice1.md" });
}

fn renderTaskDoc(allocator: std.mem.Allocator, snapshot: types.ProgressSnapshot) ![]u8 {
    const result = if (snapshot.answer.len == 0) "Pending" else snapshot.answer;
    const blockers = if (std.mem.eql(u8, snapshot.status, "failed")) snapshot.answer else "None";
    return std.fmt.allocPrint(
        allocator,
        \\# Todo Slice 1
        \\
        \\- Task ID: {s}
        \\- Status: {s}
        \\- Updated At (ms): {d}
        \\- Canonical Session Root: `.var/sessions/{s}/`
        \\
        \\## Objective
        \\
        \\{s}
        \\
        \\## Current Result
        \\
        \\{s}
        \\
        \\## Steps Taken
        \\
        \\- Canonical session state is stored under `.var/sessions/{s}/`.
        \\- Journal events append to `journal.jsonl`.
        \\- This file is the human-readable execution slice for the current run.
        \\
        \\## Blockers
        \\
        \\{s}
        \\
    ,
        .{
            snapshot.task_id,
            snapshot.status,
            snapshot.updated_at_ms,
            snapshot.task_id,
            snapshot.prompt,
            result,
            snapshot.task_id,
            blockers,
        },
    );
}
