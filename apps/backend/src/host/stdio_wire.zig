const std = @import("std");
const json = @import("../shared/json.zig");

const max_header_line_bytes = 8 * 1024;

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

pub fn readFrame(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try readHeaderLine(allocator, file);
        if (line == null) {
            if (content_length == null) return null;
            return error.InvalidFrame;
        }
        defer allocator.free(line.?);

        const trimmed = std.mem.trimRight(u8, line.?, "\r\n");
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value_text = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value_text, 10) catch return error.InvalidFrame;
        }
    }

    const expected_len = content_length orelse return error.InvalidFrame;
    const payload = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(payload);
    try readExactly(file, payload);
    return payload;
}

fn readHeaderLine(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var line = std.array_list.Managed(u8).init(allocator);
    errdefer line.deinit();

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try file.read(&byte);
        if (read_len == 0) {
            if (line.items.len == 0) {
                line.deinit();
                return null;
            }
            return error.InvalidFrame;
        }

        try line.append(byte[0]);
        if (byte[0] == '\n') return try line.toOwnedSlice();
        if (line.items.len > max_header_line_bytes) return error.InvalidFrame;
    }
}

fn readExactly(file: std.fs.File, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_len = try file.read(buffer[offset..]);
        if (read_len == 0) return error.InvalidFrame;
        offset += read_len;
    }
}
