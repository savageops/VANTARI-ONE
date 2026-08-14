const std = @import("std");
const store = @import("../sessions/store.zig");

pub const Error = error{
    EmptyEvaluatorId,
    EmptyEvidence,
};

pub const repair_receipt_event_type = "repair_receipt";
pub const repair_receipt_schema = "var1.repair_receipt.v1";

const repair_environment_keys = [_][]const u8{
    "VANTARI_HOME",
    "VANTARI_WORKSPACE",
    "PATH",
    "PATHEXT",
    "SystemRoot",
    "TEMP",
    "MAX_STEPS",
    "MAX_TOOL_CALLS_PER_TURN",
    "MAX_TOOL_CALLS_PER_SESSION",
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

/// Persist the exact replay boundary for one admitted turn. The raw config,
/// tool catalog, and environment never enter the event ledger; only their
/// stable hashes do. The accepted input is retained because it is the one
/// value a later repair rerun must not silently substitute.
pub fn appendRepairReceiptEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    run_seq: u64,
    original_input: []const u8,
    model: []const u8,
    config_snapshot: []const u8,
    tool_catalog_snapshot: []const u8,
    source_baseline: []const u8,
    environment_snapshot: []const u8,
) !void {
    if (run_seq == 0 or std.mem.trim(u8, original_input, " \t\r\n").len == 0) return Error.EmptyEvidence;

    const input_hash = contentHash(original_input);
    const config_hash = contentHash(config_snapshot);
    const tool_catalog_hash = contentHash(tool_catalog_snapshot);
    const source_baseline_hash = contentHash(source_baseline);
    const environment_hash = contentHash(environment_snapshot);
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"run_seq\":{d},\"replay_input_immutable\":true,\"original_input\":{f},\"original_input_sha256\":\"sha256:{s}\",\"model\":{f},\"config_sha256\":\"sha256:{s}\",\"tool_catalog_sha256\":\"sha256:{s}\",\"source_baseline\":{f},\"source_baseline_sha256\":\"sha256:{s}\",\"environment_sha256\":\"sha256:{s}\"}}",
        .{
            repair_receipt_schema,
            run_seq,
            std.json.fmt(original_input, .{}),
            input_hash[0..],
            std.json.fmt(model, .{}),
            config_hash[0..],
            tool_catalog_hash[0..],
            std.json.fmt(source_baseline, .{}),
            source_baseline_hash[0..],
            environment_hash[0..],
        },
    );
    defer allocator.free(message);

    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = repair_receipt_event_type,
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

/// Resolve the current source baseline without making source control a runtime
/// dependency. A non-checkout or unavailable Git executable remains truthful
/// as `unavailable`; the receipt still carries a deterministic hash so repair
/// admission can reject an unverifiable baseline later.
pub fn sourceBaseline(allocator: std.mem.Allocator) ![]u8 {
    const argv = [_][]const u8{ "git", "rev-parse", "HEAD" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return allocator.dupe(u8, "unavailable");
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const baseline = switch (result.term) {
        .Exited => |code| if (code == 0) std.mem.trim(u8, result.stdout, " \t\r\n") else "",
        else => "",
    };
    if (baseline.len == 0) return allocator.dupe(u8, "unavailable");
    return std.fmt.allocPrint(allocator, "git:{s}", .{baseline});
}

/// Capture only environment keys that can alter workspace resolution, tool
/// availability, process behavior, or the runtime budget. Values stay in
/// memory long enough to hash and are never persisted in the receipt.
pub fn environmentSnapshot(allocator: std.mem.Allocator) ![]u8 {
    var snapshot = std.array_list.Managed(u8).init(allocator);
    errdefer snapshot.deinit();

    for (repair_environment_keys) |key| {
        try snapshot.writer().print("{s}=", .{key});
        const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (value) |owned| {
            defer allocator.free(owned);
            try snapshot.writer().writeAll(owned);
        } else {
            try snapshot.writer().writeAll("<unset>");
        }
        try snapshot.writer().writeAll("\x00");
    }

    return snapshot.toOwnedSlice();
}

pub fn contentHash(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});

    var output: [64]u8 = undefined;
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = hex[byte >> 4];
        output[index * 2 + 1] = hex[byte & 0x0f];
    }
    return output;
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

test "repair receipt persists exact input and hashes transient replay state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var session = try store.initSession(std.testing.allocator, workspace_root, "repair input");
    defer session.deinit(std.testing.allocator);

    const input = "ask the agent to inspect the question modal";
    const config_snapshot = "{\"api_key\":\"secret\",\"max_steps\":4}";
    const tool_catalog_snapshot = "{\"tools\":[\"ask_user\"]}";
    const source_baseline = "git:abc123";
    const environment_snapshot = "PATH=/test\\x00";

    try appendRepairReceiptEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        7,
        input,
        "glm-5.2",
        config_snapshot,
        tool_catalog_snapshot,
        source_baseline,
        environment_snapshot,
    );

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer @import("../../shared/types.zig").deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings(repair_receipt_event_type, events[0].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"schema\":\"var1.repair_receipt.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"replay_input_immutable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, input) != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"model\":\"glm-5.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "secret") == null);

    const input_hash = contentHash(input);
    const input_hash_field = try std.fmt.allocPrint(std.testing.allocator, "original_input_sha256\":\"sha256:{s}", .{input_hash[0..]});
    defer std.testing.allocator.free(input_hash_field);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, input_hash_field) != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "config_sha256\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "tool_catalog_sha256\":\"sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "source_baseline\":\"git:abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "environment_sha256\":\"sha256:") != null);
}
