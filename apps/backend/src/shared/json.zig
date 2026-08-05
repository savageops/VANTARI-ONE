const std = @import("std");

/// Serialize any value with std.json.fmt into an owned string.
/// This is the ONE canonical JSON serialization helper for the kernel.
/// Replaces the 6 private renderJsonAlloc clones that were scattered
/// across host/, clients/, and tests/.
pub fn renderAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

/// Serialize a value and append a trailing newline (for JSONL records).
pub fn renderJsonlAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(value, .{})});
}

test "renderAlloc produces valid JSON for a struct" {
    const Point = struct { x: i32, y: i32 };
    const json = try renderAlloc(std.testing.allocator, Point{ .x = 1, .y = 2 });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"x\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"y\":2") != null);
}

test "renderJsonlAlloc appends newline" {
    const Pair = struct { a: u8 };
    const jsonl = try renderJsonlAlloc(std.testing.allocator, Pair{ .a = 42 });
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(jsonl[jsonl.len - 1] == '\n');
}
