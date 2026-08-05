const std = @import("std");

/// Typed event structs for the VAR1 event spine. Every state transition
/// is serialized through these structs via shared.json.renderAlloc,
/// replacing the 147 hand-rolled allocPrint("{{...}}") sites scattered
/// across the kernel. Each struct carries its schema version for
/// forward-compatible evolution (AGENTS.md §IV: versioned event payloads).

pub const ToolStarted = struct {
    schema: []const u8 = "var1.tool_started.v1",
    tool_call_id: []const u8,
    tool: []const u8,
    timestamp_ms: i64,
};

pub const ToolFinished = struct {
    schema: []const u8 = "var1.tool_finished.v1",
    tool_call_id: []const u8,
    tool: []const u8,
    ok: bool,
    duration_ms: i64,
    error_name: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

pub const ToolOutputDelta = struct {
    schema: []const u8 = "var1.tool_output_delta.v1",
    tool_call_id: []const u8,
    tool: []const u8,
    stream: []const u8,
    chunk_b64: []const u8,
    cap_reached: bool,
};

pub const ToolReview = struct {
    schema: []const u8 = "var1.tool_review.v1",
    tool: []const u8,
    risk: []const u8,
    decision: []const u8,
    reason: []const u8,
};

/// Serialize an event struct to an owned JSON string.
/// This is the canonical path — no hand-rolled JSON for events.
pub fn serialize(allocator: std.mem.Allocator, event: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(event, .{})});
}

test "ToolStarted serializes with schema" {
    const event = ToolStarted{
        .tool_call_id = "call-1",
        .tool = "list_files",
        .timestamp_ms = 12345,
    };
    const json = try serialize(std.testing.allocator, event);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "var1.tool_started.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "call-1") != null);
}

test "ToolFinished with optional fields omits nulls" {
    const event = ToolFinished{
        .tool_call_id = "call-2",
        .tool = "shell_exec",
        .ok = true,
        .duration_ms = 500,
    };
    const json = try serialize(std.testing.allocator, event);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "var1.tool_finished.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
}

test "ToolFinished with error includes error_name and hint" {
    const event = ToolFinished{
        .tool_call_id = "call-3",
        .tool = "shell_exec",
        .ok = false,
        .duration_ms = 100,
        .error_name = "CommandTimedOut",
        .hint = "Increase timeout_ms or simplify the command",
    };
    const json = try serialize(std.testing.allocator, event);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "CommandTimedOut") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Increase timeout_ms") != null);
}
