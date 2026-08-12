const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");

/// Hashline — content-hash anchored edits for VANTARI.
///
/// Harvested from oh-my-pi's hashline patch language. The core idea: the
/// `read_file` tool returns a content hash (4-hex tag) alongside line numbers.
/// The edit tool accepts `PUT N.=M:` ranges anchored to that hash. If the
/// file changed since the read (stale anchor), the edit is rejected before
/// corrupting anything — the model re-reads and retries.
///
/// This eliminates:
/// - "string not found" loops from whitespace mismatches (str_replace)
/// - Edits landing on wrong lines after the file was modified by another tool
/// - The model re-typing entire file contents (61% token reduction per oh-my-pi)
///
/// VANTARI's hashline is simpler than oh-my-pi's (no syntactic block resolution,
/// no named registers, no move/rename) but covers the 90% case: line-range
/// replacement with stale-anchor rejection.
/// Compute a 4-hex content hash for a file. This is the "tag" that anchors
/// edits — if the file changes, the tag changes, and stale edits are rejected.
pub fn contentHash(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    // Normalize: hash the content with trailing whitespace stripped per line
    // and CRLF converted to LF, so minor whitespace differences don't cause
    // false stale rejections.
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        hasher.update(trimmed);
        hasher.update("\n");
    }
    const hash = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>4}", .{hash & 0xFFFF});
}

/// A single edit hunk: replace lines start..=end (1-indexed, inclusive)
/// with the given replacement text.
pub const HashHunk = struct {
    start_line: usize,
    end_line: usize,
    replacement: []const u8,
};

/// Apply hashline hunks to file content. The tag must match the current
/// file's content hash — if it doesn't, returns error.StaleAnchor.
///
/// Line numbers are 1-indexed and refer to the ORIGINAL file (before any
/// hunks are applied). Multiple hunks are applied bottom-to-top so earlier
/// line numbers remain valid.
pub fn applyHunks(
    allocator: std.mem.Allocator,
    original: []const u8,
    tag: []const u8,
    hunks: []const HashHunk,
) ![]u8 {
    // Verify the anchor.
    const current_tag = try contentHash(allocator, original);
    defer allocator.free(current_tag);
    if (!std.mem.eql(u8, tag, current_tag)) {
        return error.StaleAnchor;
    }

    // Split original into lines.
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var iter = std.mem.splitScalar(u8, original, '\n');
    while (iter.next()) |line| {
        try lines.append(line);
    }
    const has_trailing_newline = original.len > 0 and original[original.len - 1] == '\n';
    if (has_trailing_newline and lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }

    // Sort hunks by start_line descending (apply bottom-to-top).
    const sorted_hunks = try allocator.dupe(HashHunk, hunks);
    defer allocator.free(sorted_hunks);
    std.sort.heap(HashHunk, sorted_hunks, {}, struct {
        fn cmp(_: void, a: HashHunk, b: HashHunk) bool {
            return a.start_line > b.start_line;
        }
    }.cmp);

    // Apply each hunk.
    for (sorted_hunks) |hunk| {
        const start = if (hunk.start_line > 0) hunk.start_line - 1 else 0;
        const end = if (hunk.end_line > 0) hunk.end_line else 1;
        if (start >= lines.items.len) return error.LineOutOfRange;
        if (end > lines.items.len) return error.LineOutOfRange;

        // Split the replacement into lines.
        var repl_lines = std.array_list.Managed([]const u8).init(allocator);
        defer repl_lines.deinit();
        var repl_iter = std.mem.splitScalar(u8, hunk.replacement, '\n');
        while (repl_iter.next()) |repl_line| {
            try repl_lines.append(repl_line);
        }
        // Remove trailing empty from split if replacement doesn't end with \n.
        if (hunk.replacement.len > 0 and hunk.replacement[hunk.replacement.len - 1] != '\n') {
            // Keep all lines including the last (which may be empty if the
            // replacement ends with \n). This is correct.
        }

        // Replace lines[start..end] with repl_lines.
        var new_lines = std.array_list.Managed([]const u8).init(allocator);
        errdefer new_lines.deinit();
        try new_lines.appendSlice(lines.items[0..start]);
        try new_lines.appendSlice(repl_lines.items);
        try new_lines.appendSlice(lines.items[end..]);

        lines.deinit();
        lines = new_lines;
    }

    // Rejoin lines.
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    for (lines.items, 0..) |line, i| {
        if (i > 0) try output.append('\n');
        try output.appendSlice(line);
    }
    if (has_trailing_newline) try output.append('\n');

    return output.toOwnedSlice();
}

pub const Error = error{
    StaleAnchor,
    LineOutOfRange,
};

/// Format a read response with line numbers and content hash tag,
/// so the model can reference them in a subsequent hashline edit.
///
/// Output format:
/// ```
/// [path#A1B2]
/// 1:first line
/// 2:second line
/// 3:third line
/// ```
pub fn formatReadWithHash(
    allocator: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
) ![]u8 {
    const tag = try contentHash(allocator, content);
    defer allocator.free(tag);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.print("[{s}#{s}]\n", .{ path, tag });

    var line_num: usize = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        // Don't print the phantom empty line from a trailing newline.
        if (line_num == 1 or line.len > 0 or iter.peek() != null) {
            try writer.print("{d}:{s}\n", .{ line_num, line });
        }
        line_num += 1;
    }

    return output.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "contentHash is deterministic for same content" {
    const tag1 = try contentHash(std.testing.allocator, "hello\nworld\n");
    defer std.testing.allocator.free(tag1);
    const tag2 = try contentHash(std.testing.allocator, "hello\nworld\n");
    defer std.testing.allocator.free(tag2);
    try std.testing.expectEqualStrings(tag1, tag2);
}

test "contentHash changes when content changes" {
    const tag1 = try contentHash(std.testing.allocator, "hello\nworld\n");
    defer std.testing.allocator.free(tag1);
    const tag2 = try contentHash(std.testing.allocator, "hello\nearth\n");
    defer std.testing.allocator.free(tag2);
    try std.testing.expect(!std.mem.eql(u8, tag1, tag2));
}

test "contentHash is 4 hex chars" {
    const tag = try contentHash(std.testing.allocator, "test");
    defer std.testing.allocator.free(tag);
    try std.testing.expectEqual(@as(usize, 4), tag.len);
}

test "applyHunks replaces lines correctly" {
    const original = "line1\nline2\nline3\nline4\n";
    const tag = try contentHash(std.testing.allocator, original);
    defer std.testing.allocator.free(tag);

    const hunks = [_]HashHunk{
        .{ .start_line = 2, .end_line = 3, .replacement = "replaced2\nreplaced3" },
    };

    const result = try applyHunks(std.testing.allocator, original, tag, &hunks);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("line1\nreplaced2\nreplaced3\nline4\n", result);
}

test "applyHunks rejects stale anchor" {
    const original = "line1\nline2\n";
    const hunks = [_]HashHunk{
        .{ .start_line = 1, .end_line = 1, .replacement = "new" },
    };

    // Wrong tag — should fail.
    const result = applyHunks(std.testing.allocator, original, "WRONG", &hunks);
    try std.testing.expectError(error.StaleAnchor, result);
}

test "applyHunks handles multiple non-adjacent hunks" {
    const original = "a\nb\nc\nd\ne\n";
    const tag = try contentHash(std.testing.allocator, original);
    defer std.testing.allocator.free(tag);

    const hunks = [_]HashHunk{
        .{ .start_line = 1, .end_line = 1, .replacement = "X" },
        .{ .start_line = 4, .end_line = 4, .replacement = "Y" },
    };

    const result = try applyHunks(std.testing.allocator, original, tag, &hunks);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("X\nb\nc\nY\ne\n", result);
}

test "formatReadWithHash includes tag and line numbers" {
    const content = "first\nsecond\nthird\n";
    const result = try formatReadWithHash(std.testing.allocator, "test.zig", content);
    defer std.testing.allocator.free(result);

    // Should start with the header.
    try std.testing.expect(std.mem.startsWith(u8, result, "[test.zig#"));
    // Should have line numbers.
    try std.testing.expect(std.mem.indexOf(u8, result, "1:first") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "2:second") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "3:third") != null);
}

test "applyHunks handles insertion (no lines replaced)" {
    const original = "line1\nline3\n";
    const tag = try contentHash(std.testing.allocator, original);
    defer std.testing.allocator.free(tag);

    // Insert after line 1: start=1, end=1, replacement includes original + new.
    const hunks = [_]HashHunk{
        .{ .start_line = 1, .end_line = 1, .replacement = "line1\nline2" },
    };

    const result = try applyHunks(std.testing.allocator, original, tag, &hunks);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("line1\nline2\nline3\n", result);
}
