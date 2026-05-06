const std = @import("std");
const store = @import("../sessions/store.zig");

pub const Error = error{
    EmptyEvaluatorId,
    EmptyEvidence,
};

pub const HeartbeatStatus = enum {
    running,
    stalled,
    completed,
};

pub fn appendHeartbeatEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    status: HeartbeatStatus,
    detail: []const u8,
) !void {
    const redacted_detail = try redactSensitiveText(allocator, detail);
    defer allocator.free(redacted_detail);

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.runtime_heartbeat.v1\",\"status\":\"{s}\",\"detail\":{f}}}",
        .{
            heartbeatStatusLabel(status),
            std.json.fmt(redacted_detail, .{}),
        },
    );
    defer allocator.free(message);

    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = "runtime_heartbeat",
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

pub fn appendEvaluatorEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    evaluator_id: []const u8,
    passed: bool,
    evidence: []const u8,
) !void {
    if (std.mem.trim(u8, evaluator_id, " \t\r\n").len == 0) return Error.EmptyEvaluatorId;
    if (std.mem.trim(u8, evidence, " \t\r\n").len == 0) return Error.EmptyEvidence;

    const redacted_evidence = try redactSensitiveText(allocator, evidence);
    defer allocator.free(redacted_evidence);

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.evaluator_result.v1\",\"evaluator_id\":{f},\"passed\":{},\"evidence\":{f},\"executor_mutation\":\"forbidden\"}}",
        .{
            std.json.fmt(evaluator_id, .{}),
            passed,
            std.json.fmt(redacted_evidence, .{}),
        },
    );
    defer allocator.free(message);

    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = "evaluator_result",
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

pub fn appendUnsupportedBehaviorEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    behavior: []const u8,
    diagnostic: []const u8,
) !void {
    const redacted_diagnostic = try redactSensitiveText(allocator, diagnostic);
    defer allocator.free(redacted_diagnostic);

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.unsupported_behavior.v1\",\"behavior\":{f},\"diagnostic\":{f}}}",
        .{
            std.json.fmt(behavior, .{}),
            std.json.fmt(redacted_diagnostic, .{}),
        },
    );
    defer allocator.free(message);

    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = "runtime_unsupported_behavior",
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

pub fn heartbeatStatusLabel(status: HeartbeatStatus) []const u8 {
    return switch (status) {
        .running => "running",
        .stalled => "stalled",
        .completed => "completed",
    };
}

pub fn redactSensitiveText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (looksSensitive(text)) return allocator.dupe(u8, "[redacted]");
    return allocator.dupe(u8, text);
}

fn looksSensitive(text: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, "api_key") != null or
        std.ascii.indexOfIgnoreCase(text, "authorization") != null or
        std.ascii.indexOfIgnoreCase(text, "secret") != null or
        std.ascii.indexOfIgnoreCase(text, "token") != null or
        std.ascii.indexOfIgnoreCase(text, "sk-") != null;
}

test "heartbeat and evaluator events persist as redacted session evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var session = try store.initSession(std.testing.allocator, workspace_root, "evaluate current run");
    defer session.deinit(std.testing.allocator);

    try appendHeartbeatEvent(std.testing.allocator, workspace_root, session.id, .running, "api_key=sk-test");
    try appendEvaluatorEvent(std.testing.allocator, workspace_root, session.id, "contract-check", true, "No state mutation.");

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer @import("../../shared/types.zig").deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("runtime_heartbeat", events[0].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "[redacted]") != null);
    try std.testing.expectEqualStrings("evaluator_result", events[1].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[1].message, "\"executor_mutation\":\"forbidden\"") != null);
}
