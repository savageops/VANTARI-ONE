/// Global persistent user message history — the cross-session record of every
/// prompt submitted through the TUI. Stored as append-only JSONL at
/// `<runtimeRoot>/tui/history.jsonl`, one row per submitted prompt.
///
/// Unlike per-session `messages.jsonl`, this file aggregates prompts across ALL
/// sessions and survives TUI restarts. The TUI loads it on startup to seed the
/// Up/Down navigation ring buffer, and appends on every submit.
///
/// The file is workspace-scoped via `runtimeRootForWorkspace` — production
/// (`$VANTARI_HOME`) gives a global view across workspaces; workspace-local
/// (`.var`) isolates history per project.
///
/// Entry shape: `{"timestamp_ms":N,"text":"..."}` — deliberately minimal. No
/// session_id (the file IS the cross-session aggregate), no role (only user
/// prompts are history), no metadata (keep it lean for fast loading).
const std = @import("std");

const fsutil = @import("../../shared/fsutil.zig");

pub const max_history_entries: usize = 1000;

/// One row in the global prompt history.
pub const HistoryEntry = struct {
    timestamp_ms: i64,
    text: []u8,

    pub fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Resolve `<runtimeRoot>/tui/history.jsonl`. Creates the `tui/` directory if
/// it does not exist.
pub fn historyFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const path = try fsutil.join(allocator, &.{ root, "tui", "history.jsonl" });
    std.fs.cwd().makePath(std.fs.path.dirname(path) orelse "") catch {};
    return path;
}

/// Append one prompt to the global history file. Deduplicates consecutive
/// identical text — if the last row matches, the write is skipped. This
/// prevents rapid re-submits from polluting the recall surface.
pub fn appendHistoryEntry(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    text: []const u8,
) !void {
    if (text.len == 0) return;

    const path = try historyFilePath(allocator, workspace_root);
    defer allocator.free(path);

    // Consecutive dedup: read the last line and skip if identical.
    if (lastEntryTextMatches(path, text)) return;

    const timestamp_ms = std.time.milliTimestamp();
    const escaped = try escapeJsonString(allocator, text);
    defer allocator.free(escaped);
    const row = try std.fmt.allocPrint(allocator, "{{\"timestamp_ms\":{d},\"text\":\"{s}\"}}\n", .{
        timestamp_ms,
        escaped,
    });
    defer allocator.free(row);
    appendJsonlRow(path, row) catch {};
}

/// Load the most recent `max_entries` prompts in chronological order (oldest
/// first, matching the TUI's Up/Down navigation expectation). Reads the valid
/// prefix of the file — corrupted trailing rows are skipped per AGENTS.md II.
pub fn loadHistory(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_entries: usize,
) ![]HistoryEntry {
    const path = try historyFilePath(allocator, workspace_root);
    defer allocator.free(path);

    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(HistoryEntry, 0),
        else => return err,
    };
    defer allocator.free(content);

    // Strip BOM if present.
    const trimmed = if (std.mem.startsWith(u8, content, "\xEF\xBB\xBF"))
        content[3..]
    else
        content;

    var entries = std.array_list.Managed(HistoryEntry).init(allocator);
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (line_iter.next()) |line| {
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (stripped.len == 0) continue;

        var entry = parseHistoryRow(allocator, stripped) catch continue;
        entries.append(entry) catch {
            entry.deinit(allocator);
            continue;
        };
    }

    // Keep only the last max_entries (trim from the front).
    if (entries.items.len > max_entries) {
        const trim_count = entries.items.len - max_entries;
        for (entries.items[0..trim_count]) |*entry| entry.deinit(allocator);
        // Shift remaining entries to the front.
        std.mem.copyForwards(HistoryEntry, entries.items[0..max_entries], entries.items[trim_count..]);
        entries.shrinkRetainingCapacity(max_entries);
    }

    return entries.toOwnedSlice();
}

/// Rewrite the history file with only the provided entries. Used when the file
/// exceeds `max_history_entries` — trim on load, not on every append.
pub fn trimHistoryFile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    entries: []const HistoryEntry,
) !void {
    const path = try historyFilePath(allocator, workspace_root);
    defer allocator.free(path);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    for (entries) |entry| {
        const escaped = try escapeJsonString(allocator, entry.text);
        defer allocator.free(escaped);
        const row = try std.fmt.allocPrint(allocator, "{{\"timestamp_ms\":{d},\"text\":\"{s}\"}}\n", .{
            entry.timestamp_ms,
            escaped,
        });
        defer allocator.free(row);
        try output.appendSlice(row);
    }
    fsutil.writeText(path, output.items) catch {};
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn appendJsonlRow(path: []const u8, jsonl: []const u8) !void {
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
}

/// Check if the last line of the history file matches `text`. Used for
/// consecutive dedup. Returns false if the file doesn't exist or can't be read.
fn lastEntryTextMatches(path: []const u8, text: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const content = fsutil.readTextAlloc(allocator, path) catch return false;
    defer allocator.free(content);

    // Find the last non-empty line.
    var last_line: []const u8 = "";
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const stripped = std.mem.trim(u8, line, " \t\r");
        if (stripped.len > 0) last_line = stripped;
    }
    if (last_line.len == 0) return false;

    // Parse the text field from the last row.
    var row = parseHistoryRow(allocator, last_line) catch return false;
    defer row.deinit(allocator);
    return std.mem.eql(u8, row.text, text);
}

fn parseHistoryRow(allocator: std.mem.Allocator, json_line: []const u8) !HistoryEntry {
    var parsed = std.json.parseFromSlice(struct {
        timestamp_ms: i64 = 0,
        text: []const u8 = "",
    }, allocator, json_line, .{ .ignore_unknown_fields = true }) catch return error.InvalidJson;
    defer parsed.deinit();

    const text = try allocator.dupe(u8, parsed.value.text);
    return .{
        .timestamp_ms = parsed.value.timestamp_ms,
        .text = text,
    };
}

/// Escape a string for embedding in a JSON string literal. Handles the
/// standard escape sequences. Allocates and returns a new slice.
fn escapeJsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    for (text) |char| {
        switch (char) {
            '"' => try output.appendSlice("\\\""),
            '\\' => try output.appendSlice("\\\\"),
            '\n' => try output.appendSlice("\\n"),
            '\r' => try output.appendSlice("\\r"),
            '\t' => try output.appendSlice("\\t"),
            0...8, 11...12, 14...31 => {
                try output.writer().print("\\u{x:0>4}", .{char});
            },
            else => try output.append(char),
        }
    }
    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "appendHistoryEntry writes a JSONL row" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try appendHistoryEntry(allocator, workspace, "hello world");

    const path = try historyFilePath(allocator, workspace);
    defer allocator.free(path);
    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"timestamp_ms\":") != null);
}

test "loadHistory returns entries in chronological order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try appendHistoryEntry(allocator, workspace, "first");
    try appendHistoryEntry(allocator, workspace, "second");
    try appendHistoryEntry(allocator, workspace, "third");

    const entries = try loadHistory(allocator, workspace, 100);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("first", entries[0].text);
    try std.testing.expectEqualStrings("second", entries[1].text);
    try std.testing.expectEqualStrings("third", entries[2].text);
}

test "loadHistory handles missing file gracefully" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    const entries = try loadHistory(allocator, workspace, 100);
    defer allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "loadHistory handles corrupted suffix (valid prefix preserved)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    // Write valid rows then a corrupted row.
    const path = try historyFilePath(allocator, workspace);
    defer allocator.free(path);
    try fsutil.appendText(path, "{\"timestamp_ms\":1,\"text\":\"valid\"}\n");
    try fsutil.appendText(path, "THIS IS NOT JSON\n");

    const entries = try loadHistory(allocator, workspace, 100);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("valid", entries[0].text);
}

test "loadHistory trims to max_entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try appendHistoryEntry(allocator, workspace, "one");
    try appendHistoryEntry(allocator, workspace, "two");
    try appendHistoryEntry(allocator, workspace, "three");
    try appendHistoryEntry(allocator, workspace, "four");
    try appendHistoryEntry(allocator, workspace, "five");

    const entries = try loadHistory(allocator, workspace, 3);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("three", entries[0].text);
    try std.testing.expectEqualStrings("five", entries[2].text);
}

test "consecutive duplicate text is deduplicated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try appendHistoryEntry(allocator, workspace, "same prompt");
    try appendHistoryEntry(allocator, workspace, "same prompt");
    try appendHistoryEntry(allocator, workspace, "different prompt");

    const entries = try loadHistory(allocator, workspace, 100);
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("same prompt", entries[0].text);
    try std.testing.expectEqualStrings("different prompt", entries[1].text);
}

test "escapeJsonString handles special characters" {
    const allocator = std.testing.allocator;
    const escaped = try escapeJsonString(allocator, "hello \"world\"\n\t");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\n\\t", escaped);
}
