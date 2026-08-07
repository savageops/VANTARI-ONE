const std = @import("std");
const json = @import("../shared/json.zig");

const max_header_bytes = 8 * 1024;
const read_chunk_bytes = 16 * 1024;

/// Re-export of the canonical shared JSON helper.
pub fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return json.renderAlloc(allocator, value);
}

pub fn renderSuccessResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    result_payload: []const u8,
) ![]u8 {
    const id_payload = try renderJsonAlloc(allocator, id);
    defer allocator.free(id_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_payload, result_payload },
    );
}

pub fn renderErrorResponse(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) ![]u8 {
    const id_payload = if (id) |value|
        try renderJsonAlloc(allocator, value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_payload);

    const error_payload = try renderJsonAlloc(allocator, .{
        .code = code,
        .message = message,
    });
    defer allocator.free(error_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}",
        .{ id_payload, error_payload },
    );
}

pub fn errorResponseOrNull(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) !?[]u8 {
    if (id) |request_id| return try renderErrorResponse(allocator, request_id, code, message);
    return null;
}

pub fn writeFrame(file: std.fs.File, payload: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    try writer.interface.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

/// Stateful Content-Length frame decoder for byte-stream transports.
///
/// A pipe read may return several complete frames at once. The decoder keeps
/// every byte beyond the current payload for the next call; callers must keep
/// one reader alive for the lifetime of the stream.
pub const FrameReader = struct {
    allocator: std.mem.Allocator,
    buffered: std.array_list.Managed(u8),
    start: usize = 0,
    body_start: ?usize = null,
    expected_frame_end: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) FrameReader {
        return .{
            .allocator = allocator,
            .buffered = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *FrameReader) void {
        self.buffered.deinit();
    }

    pub fn readFrame(self: *FrameReader, file: std.fs.File) !?[]u8 {
        while (true) {
            const unread = self.buffered.items[self.start..];
            if (self.expected_frame_end == null) {
                const header_end = std.mem.indexOf(u8, unread, "\r\n\r\n") orelse {
                    if (unread.len > max_header_bytes) return error.InvalidFrame;
                    if (!try self.readMore(file, unread.len)) return null;
                    continue;
                };
                if (header_end > max_header_bytes) return error.InvalidFrame;
                const body_start = header_end + 4;
                const content_length = try parseContentLength(unread[0..header_end]);
                if (content_length > std.math.maxInt(usize) - body_start) return error.InvalidFrame;
                self.body_start = body_start;
                self.expected_frame_end = body_start + content_length;
            }

            const frame_end = self.expected_frame_end.?;
            if (unread.len >= frame_end) {
                const payload = try self.allocator.dupe(u8, unread[self.body_start.?..frame_end]);
                self.body_start = null;
                self.expected_frame_end = null;
                self.consume(frame_end);
                return payload;
            }

            _ = try self.readMore(file, unread.len);
        }
    }

    fn readMore(self: *FrameReader, file: std.fs.File, unread_len: usize) !bool {
        var chunk: [read_chunk_bytes]u8 = undefined;
        const read_len = try file.read(&chunk);
        if (read_len == 0) {
            if (unread_len == 0) return false;
            return error.InvalidFrame;
        }
        try self.buffered.appendSlice(chunk[0..read_len]);
        return true;
    }

    fn consume(self: *FrameReader, count: usize) void {
        self.start += count;
        if (self.start == self.buffered.items.len) {
            self.buffered.clearRetainingCapacity();
            self.start = 0;
            return;
        }

        // Compact only after meaningful progress so ordinary frame reads avoid
        // copying the unread suffix on every call.
        if (self.start >= read_chunk_bytes and self.start >= self.buffered.items.len / 2) {
            const remaining = self.buffered.items[self.start..];
            std.mem.copyForwards(u8, self.buffered.items[0..remaining.len], remaining);
            self.buffered.items.len = remaining.len;
            self.start = 0;
        }
    }
};

fn parseContentLength(header: []const u8) !usize {
    var content_length: ?usize = null;
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Content-Length:")) continue;
        if (content_length != null) return error.InvalidFrame;
        const value_text = std.mem.trim(u8, line["Content-Length:".len..], " \t");
        content_length = std.fmt.parseInt(usize, value_text, 10) catch return error.InvalidFrame;
    }
    return content_length orelse error.InvalidFrame;
}

fn frameAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{payload.len});
    defer allocator.free(header);
    return std.mem.concat(allocator, u8, &.{ header, payload });
}

test "frame reader preserves coalesced frames" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("coalesced.bin", .{ .read = true });
    defer file.close();
    const first_frame = try frameAlloc(allocator, "first");
    defer allocator.free(first_frame);
    const second_frame = try frameAlloc(allocator, "second");
    defer allocator.free(second_frame);
    const coalesced = try std.mem.concat(allocator, u8, &.{ first_frame, second_frame });
    defer allocator.free(coalesced);
    try file.writeAll(coalesced);
    try file.seekTo(0);

    var reader = FrameReader.init(allocator);
    defer reader.deinit();

    const first = (try reader.readFrame(file)).?;
    defer allocator.free(first);
    const second = (try reader.readFrame(file)).?;
    defer allocator.free(second);

    try std.testing.expectEqualStrings("first", first);
    try std.testing.expectEqualStrings("second", second);
    try std.testing.expect((try reader.readFrame(file)) == null);
}

test "frame reader spans chunk boundaries without losing the following frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const large_payload = try allocator.alloc(u8, read_chunk_bytes * 2 + 73);
    defer allocator.free(large_payload);
    @memset(large_payload, 'x');

    var file = try tmp.dir.createFile("partial.bin", .{ .read = true });
    defer file.close();
    const first_frame = try frameAlloc(allocator, large_payload);
    defer allocator.free(first_frame);
    const second_frame = try frameAlloc(allocator, "tail");
    defer allocator.free(second_frame);
    const coalesced = try std.mem.concat(allocator, u8, &.{ first_frame, second_frame });
    defer allocator.free(coalesced);
    try file.writeAll(coalesced);
    try file.seekTo(0);

    var reader = FrameReader.init(allocator);
    defer reader.deinit();

    const first = (try reader.readFrame(file)).?;
    defer allocator.free(first);
    const second = (try reader.readFrame(file)).?;
    defer allocator.free(second);

    try std.testing.expectEqualSlices(u8, large_payload, first);
    try std.testing.expectEqualStrings("tail", second);
}

test "frame reader drains a coalesced notification burst without loss" {
    const allocator = std.testing.allocator;
    const frame_count: usize = 4_096;
    const framed = try frameAlloc(allocator, "x");
    defer allocator.free(framed);

    var coalesced = std.array_list.Managed(u8).init(allocator);
    defer coalesced.deinit();
    try coalesced.ensureTotalCapacity(framed.len * frame_count);
    for (0..frame_count) |_| try coalesced.appendSlice(framed);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile("burst.bin", .{ .read = true });
    defer file.close();
    try file.writeAll(coalesced.items);
    try file.seekTo(0);

    var reader = FrameReader.init(allocator);
    defer reader.deinit();
    var decoded: usize = 0;
    while (try reader.readFrame(file)) |payload| {
        defer allocator.free(payload);
        try std.testing.expectEqualStrings("x", payload);
        decoded += 1;
    }

    try std.testing.expectEqual(frame_count, decoded);
}
