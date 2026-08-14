const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    EmptyEvaluatorId,
    EmptyEvidence,
    CandidateNotFound,
    CandidateMismatch,
    CandidateBaselineConflict,
};

pub const repair_receipt_event_type = "repair_receipt";
pub const repair_receipt_schema = "var1.repair_receipt.v1";
pub const repair_candidate_event_type = "repair_candidate";
pub const repair_candidate_schema = "var1.repair_candidate.v1";
pub const repair_candidate_approval_event_type = "repair_candidate_approval";
pub const repair_candidate_approval_schema = "var1.repair_candidate_approval.v1";
pub const repair_candidate_applied_event_type = "repair_candidate_applied";
pub const repair_candidate_applied_schema = "var1.repair_candidate_applied.v1";

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

/// Persist a proposal-only repair candidate. The candidate carries hashes and
/// source-baseline identity, never the patch body. Applying a candidate is a
/// later, explicitly approved operation owned by the normal write tools.
pub fn appendRepairCandidateEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    candidate_id: []const u8,
    failure_id: []const u8,
    operation: []const u8,
    target_path: []const u8,
    before_sha256: []const u8,
    patch_sha256: []const u8,
    expected_source_baseline: []const u8,
    current_source_baseline: []const u8,
    baseline_match: bool,
) !u64 {
    const required = [_][]const u8{
        session_id,
        candidate_id,
        failure_id,
        operation,
        target_path,
        before_sha256,
        patch_sha256,
        expected_source_baseline,
        current_source_baseline,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const expected_baseline_hash = contentHash(expected_source_baseline);
    const current_baseline_hash = contentHash(current_source_baseline);
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"candidate_id\":{f},\"failure_id\":{f},\"operation\":{f},\"target_path\":{f},\"before_sha256\":\"sha256:{s}\",\"patch_sha256\":\"sha256:{s}\",\"expected_source_baseline\":{f},\"expected_source_baseline_sha256\":\"sha256:{s}\",\"current_source_baseline\":{f},\"current_source_baseline_sha256\":\"sha256:{s}\",\"baseline_match\":{},\"status\":\"{s}\",\"mutation_allowed\":false}}",
        .{
            repair_candidate_schema,
            std.json.fmt(candidate_id, .{}),
            std.json.fmt(failure_id, .{}),
            std.json.fmt(operation, .{}),
            std.json.fmt(target_path, .{}),
            before_sha256,
            patch_sha256,
            std.json.fmt(expected_source_baseline, .{}),
            expected_baseline_hash[0..],
            std.json.fmt(current_source_baseline, .{}),
            current_baseline_hash[0..],
            baseline_match,
            if (baseline_match) "ready" else "baseline_conflict",
        },
    );
    defer allocator.free(message);

    return store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = repair_candidate_event_type,
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

const RepairCandidatePayload = struct {
    schema: []const u8 = "",
    candidate_id: []const u8 = "",
    failure_id: []const u8 = "",
    operation: []const u8 = "",
    target_path: []const u8 = "",
    before_sha256: []const u8 = "",
    patch_sha256: []const u8 = "",
    expected_source_baseline: []const u8 = "",
    current_source_baseline: []const u8 = "",
    baseline_match: bool = false,
    status: []const u8 = "",
};

const RepairCandidateApprovalPayload = struct {
    schema: []const u8 = "",
    candidate_id: []const u8 = "",
    candidate_event_seq: u64 = 0,
    failure_id: []const u8 = "",
    approval_id: []const u8 = "",
    approved_by: []const u8 = "",
    patch_sha256: []const u8 = "",
    expected_source_baseline: []const u8 = "",
};

const RepairCandidateAppliedPayload = struct {
    schema: []const u8 = "",
    candidate_id: []const u8 = "",
    candidate_event_seq: u64 = 0,
    approval_id: []const u8 = "",
    approval_event_seq: u64 = 0,
    tool_call_id: []const u8 = "",
    operation: []const u8 = "",
    target_path: []const u8 = "",
    patch_sha256: []const u8 = "",
    effect_sha256: []const u8 = "",
};

/// Append one explicit operator approval for an exact candidate event. The
/// approval is itself immutable evidence; it does not carry patch text and does
/// not mutate source. Repeating the same approval identity returns the original
/// approval sequence after re-validating its binding.
pub fn appendRepairCandidateApprovalEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    candidate_event_seq: u64,
    candidate_id: []const u8,
    approval_id: []const u8,
    approved_by: []const u8,
    patch_sha256: []const u8,
    expected_source_baseline: []const u8,
) !u64 {
    const required = [_][]const u8{
        session_id,
        candidate_id,
        approval_id,
        approved_by,
        patch_sha256,
        expected_source_baseline,
    };
    if (candidate_event_seq == 0) return Error.EmptyEvidence;
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);

    var candidate_event: ?*const types.SessionEvent = null;
    var existing_approval: ?*const types.SessionEvent = null;
    for (events) |*event| {
        if (event.seq == candidate_event_seq and std.mem.eql(u8, event.event_type, repair_candidate_event_type)) {
            candidate_event = event;
            continue;
        }
        if (!std.mem.eql(u8, event.event_type, repair_candidate_approval_event_type)) continue;
        const parsed = std.json.parseFromSlice(RepairCandidateApprovalPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (parsed.value.candidate_event_seq == candidate_event_seq and
            std.mem.eql(u8, parsed.value.approval_id, approval_id))
        {
            existing_approval = event;
        }
    }

    const candidate = candidate_event orelse return Error.CandidateNotFound;
    var parsed_candidate = std.json.parseFromSlice(RepairCandidatePayload, allocator, candidate.message, .{
        .ignore_unknown_fields = true,
    }) catch return Error.CandidateMismatch;
    defer parsed_candidate.deinit();
    if (!std.mem.eql(u8, parsed_candidate.value.schema, repair_candidate_schema) or
        !std.mem.eql(u8, parsed_candidate.value.candidate_id, candidate_id) or
        !parsed_candidate.value.baseline_match or
        !std.mem.eql(u8, parsed_candidate.value.status, "ready") or
        !std.mem.eql(u8, parsed_candidate.value.patch_sha256, patch_sha256) or
        !std.mem.eql(u8, parsed_candidate.value.expected_source_baseline, expected_source_baseline))
    {
        return Error.CandidateMismatch;
    }

    if (existing_approval) |event| {
        const parsed = std.json.parseFromSlice(RepairCandidateApprovalPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch return Error.CandidateMismatch;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, repair_candidate_approval_schema) or
            !std.mem.eql(u8, parsed.value.candidate_id, candidate_id) or
            parsed.value.candidate_event_seq != candidate_event_seq or
            !std.mem.eql(u8, parsed.value.approval_id, approval_id) or
            !std.mem.eql(u8, parsed.value.approved_by, approved_by) or
            !std.mem.eql(u8, parsed.value.patch_sha256, patch_sha256) or
            !std.mem.eql(u8, parsed.value.expected_source_baseline, expected_source_baseline))
        {
            return Error.CandidateMismatch;
        }
        return event.seq;
    }

    const current_source_baseline = try sourceBaseline(allocator);
    defer allocator.free(current_source_baseline);
    if (!std.mem.eql(u8, parsed_candidate.value.current_source_baseline, current_source_baseline) or
        !std.mem.eql(u8, parsed_candidate.value.expected_source_baseline, current_source_baseline))
    {
        return Error.CandidateBaselineConflict;
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"candidate_id\":{f},\"candidate_event_seq\":{d},\"failure_id\":{f},\"approval_id\":{f},\"approved_by\":{f},\"operation\":{f},\"target_path\":{f},\"before_sha256\":\"{s}\",\"patch_sha256\":\"{s}\",\"expected_source_baseline\":{f},\"expected_source_baseline_sha256\":\"sha256:{s}\",\"current_source_baseline\":{f},\"current_source_baseline_sha256\":\"sha256:{s}\",\"status\":\"approved\",\"mutation_allowed\":true}}",
        .{
            repair_candidate_approval_schema,
            std.json.fmt(candidate_id, .{}),
            candidate_event_seq,
            std.json.fmt(parsed_candidate.value.failure_id, .{}),
            std.json.fmt(approval_id, .{}),
            std.json.fmt(approved_by, .{}),
            std.json.fmt(parsed_candidate.value.operation, .{}),
            std.json.fmt(parsed_candidate.value.target_path, .{}),
            parsed_candidate.value.before_sha256,
            parsed_candidate.value.patch_sha256,
            std.json.fmt(expected_source_baseline, .{}),
            contentHash(expected_source_baseline)[0..],
            std.json.fmt(current_source_baseline, .{}),
            contentHash(current_source_baseline)[0..],
        },
    );
    defer allocator.free(message);

    return store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = repair_candidate_approval_event_type,
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

/// Verify the exact operator approval before a repair can reach the existing
/// write tool. The returned flag is true when this approval already produced
/// an applied receipt, which keeps retries mutation-idempotent.
pub fn verifyRepairCandidateApply(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    candidate_event_seq: u64,
    approval_event_seq: u64,
    candidate_id: []const u8,
    approval_id: []const u8,
    operation: []const u8,
    target_path: []const u8,
    patch_sha256: []const u8,
    expected_source_baseline: []const u8,
) !bool {
    if (candidate_event_seq == 0 or approval_event_seq == 0) return Error.EmptyEvidence;
    const required = [_][]const u8{
        session_id,
        candidate_id,
        approval_id,
        operation,
        target_path,
        patch_sha256,
        expected_source_baseline,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);

    var candidate_event: ?*const types.SessionEvent = null;
    var approval_event: ?*const types.SessionEvent = null;
    var already_applied = false;
    for (events) |*event| {
        if (event.seq == candidate_event_seq and std.mem.eql(u8, event.event_type, repair_candidate_event_type)) {
            candidate_event = event;
        }
        if (event.seq == approval_event_seq and std.mem.eql(u8, event.event_type, repair_candidate_approval_event_type)) {
            approval_event = event;
        }
        if (!std.mem.eql(u8, event.event_type, repair_candidate_applied_event_type)) continue;
        const parsed = std.json.parseFromSlice(RepairCandidateAppliedPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.schema, repair_candidate_applied_schema) and
            std.mem.eql(u8, parsed.value.candidate_id, candidate_id) and
            parsed.value.candidate_event_seq == candidate_event_seq and
            std.mem.eql(u8, parsed.value.approval_id, approval_id) and
            parsed.value.approval_event_seq == approval_event_seq)
        {
            already_applied = true;
        }
    }

    const candidate = candidate_event orelse return Error.CandidateNotFound;
    var parsed_candidate = std.json.parseFromSlice(RepairCandidatePayload, allocator, candidate.message, .{
        .ignore_unknown_fields = true,
    }) catch return Error.CandidateMismatch;
    defer parsed_candidate.deinit();
    if (!std.mem.eql(u8, parsed_candidate.value.schema, repair_candidate_schema) or
        !std.mem.eql(u8, parsed_candidate.value.candidate_id, candidate_id) or
        !parsed_candidate.value.baseline_match or
        !std.mem.eql(u8, parsed_candidate.value.status, "ready") or
        !std.mem.eql(u8, parsed_candidate.value.operation, operation) or
        !std.mem.eql(u8, parsed_candidate.value.target_path, target_path) or
        !std.mem.eql(u8, parsed_candidate.value.patch_sha256, patch_sha256) or
        !std.mem.eql(u8, parsed_candidate.value.expected_source_baseline, expected_source_baseline))
    {
        return Error.CandidateMismatch;
    }

    const approval = approval_event orelse return Error.CandidateMismatch;
    var parsed_approval = std.json.parseFromSlice(RepairCandidateApprovalPayload, allocator, approval.message, .{
        .ignore_unknown_fields = true,
    }) catch return Error.CandidateMismatch;
    defer parsed_approval.deinit();
    if (!std.mem.eql(u8, parsed_approval.value.schema, repair_candidate_approval_schema) or
        !std.mem.eql(u8, parsed_approval.value.candidate_id, candidate_id) or
        parsed_approval.value.candidate_event_seq != candidate_event_seq or
        !std.mem.eql(u8, parsed_approval.value.approval_id, approval_id) or
        !std.mem.eql(u8, parsed_approval.value.patch_sha256, patch_sha256) or
        !std.mem.eql(u8, parsed_approval.value.expected_source_baseline, expected_source_baseline))
    {
        return Error.CandidateMismatch;
    }

    // A previously applied approval is already durable evidence. Do not make
    // a successful repair fail merely because a later source commit changed
    // the current Git baseline during a retry.
    if (already_applied) return true;

    const current_source_baseline = try sourceBaseline(allocator);
    defer allocator.free(current_source_baseline);
    if (!std.mem.eql(u8, parsed_candidate.value.current_source_baseline, current_source_baseline) or
        !std.mem.eql(u8, parsed_candidate.value.expected_source_baseline, current_source_baseline))
    {
        return Error.CandidateBaselineConflict;
    }

    return false;
}

/// Record the successful application after the existing write tool commits
/// its write intent. Repeating the same identity returns the original event
/// sequence and never appends a duplicate application receipt.
pub fn appendRepairCandidateAppliedEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    candidate_event_seq: u64,
    approval_event_seq: u64,
    candidate_id: []const u8,
    approval_id: []const u8,
    tool_call_id: []const u8,
    operation: []const u8,
    target_path: []const u8,
    patch_sha256: []const u8,
    effect_sha256: []const u8,
) !u64 {
    if (candidate_event_seq == 0 or approval_event_seq == 0) return Error.EmptyEvidence;
    const required = [_][]const u8{
        session_id,
        candidate_id,
        approval_id,
        tool_call_id,
        operation,
        target_path,
        patch_sha256,
        effect_sha256,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);
    for (events) |*event| {
        if (!std.mem.eql(u8, event.event_type, repair_candidate_applied_event_type)) continue;
        const parsed = std.json.parseFromSlice(RepairCandidateAppliedPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();
        if (std.mem.eql(u8, parsed.value.schema, repair_candidate_applied_schema) and
            std.mem.eql(u8, parsed.value.candidate_id, candidate_id) and
            parsed.value.candidate_event_seq == candidate_event_seq and
            std.mem.eql(u8, parsed.value.approval_id, approval_id) and
            parsed.value.approval_event_seq == approval_event_seq)
        {
            return event.seq;
        }
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"candidate_id\":{f},\"candidate_event_seq\":{d},\"approval_id\":{f},\"approval_event_seq\":{d},\"tool_call_id\":{f},\"operation\":{f},\"target_path\":{f},\"patch_sha256\":{f},\"effect_sha256\":{f},\"status\":\"applied\",\"mutation_allowed\":true}}",
        .{
            repair_candidate_applied_schema,
            std.json.fmt(candidate_id, .{}),
            candidate_event_seq,
            std.json.fmt(approval_id, .{}),
            approval_event_seq,
            std.json.fmt(tool_call_id, .{}),
            std.json.fmt(operation, .{}),
            std.json.fmt(target_path, .{}),
            std.json.fmt(patch_sha256, .{}),
            std.json.fmt(effect_sha256, .{}),
        },
    );
    defer allocator.free(message);

    return store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = repair_candidate_applied_event_type,
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

test "repair candidate receipt blocks source drift without persisting patch text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var session = try store.initSession(std.testing.allocator, workspace_root, "repair candidate");
    defer session.deinit(std.testing.allocator);

    _ = try appendRepairCandidateEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        "candidate-1",
        "failure-1",
        "replace_in_file",
        "apps/backend/src/core/example.zig",
        "before-hash",
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "git:expected",
        "git:current",
        false,
    );

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer @import("../../shared/types.zig").deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings(repair_candidate_event_type, events[0].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"schema\":\"var1.repair_candidate.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"status\":\"baseline_conflict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"baseline_match\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"mutation_allowed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "patch body") == null);
}

test "repair candidate approval binds the exact proposal and is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var session = try store.initSession(std.testing.allocator, workspace_root, "repair approval");
    defer session.deinit(std.testing.allocator);

    const current_baseline = try sourceBaseline(std.testing.allocator);
    defer std.testing.allocator.free(current_baseline);
    const patch_hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const patch_sha256 = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const candidate_seq = try appendRepairCandidateEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        "candidate-approval",
        "failure-approval",
        "replace_in_file",
        "README.md",
        "before-hash",
        patch_hash,
        current_baseline,
        current_baseline,
        true,
    );

    const approval_seq = try appendRepairCandidateApprovalEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        candidate_seq,
        "candidate-approval",
        "approval-1",
        "operator",
        patch_sha256,
        current_baseline,
    );
    try std.testing.expect(approval_seq > candidate_seq);

    const repeated_seq = try appendRepairCandidateApprovalEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        candidate_seq,
        "candidate-approval",
        "approval-1",
        "operator",
        patch_sha256,
        current_baseline,
    );
    try std.testing.expectEqual(approval_seq, repeated_seq);
    try std.testing.expectError(
        Error.CandidateMismatch,
        appendRepairCandidateApprovalEvent(
            std.testing.allocator,
            workspace_root,
            session.id,
            candidate_seq,
            "candidate-approval",
            "approval-1",
            "operator",
            "sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210",
            current_baseline,
        ),
    );

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings(repair_candidate_approval_event_type, events[1].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[1].message, "\"status\":\"approved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[1].message, "\"mutation_allowed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[1].message, "\"approved_by\":\"operator\"") != null);
}
