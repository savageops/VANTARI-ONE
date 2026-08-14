const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");
const protocol_events = @import("../../shared/protocol/events.zig");

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
pub const repair_rerun_started_event_type = "repair_rerun_started";
pub const repair_rerun_completed_event_type = "repair_rerun_completed";
pub const repair_rerun_schema = "var1.repair_rerun.v1";
pub const repair_evaluation_event_type = "repair_evaluation";
pub const repair_evaluation_schema = "var1.repair_evaluation.v1";
pub const repair_rollback_started_event_type = "repair_rollback_started";
pub const repair_rollback_completed_event_type = "repair_rollback_completed";
pub const repair_rollback_schema = "var1.repair_rollback.v1";

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
    provider_id: []const u8,
    prompt_mode: []const u8,
    config_snapshot: []const u8,
    tool_catalog_snapshot: []const u8,
    source_baseline: []const u8,
    environment_snapshot: []const u8,
) !void {
    if (run_seq == 0 or std.mem.trim(u8, original_input, " \t\r\n").len == 0 or
        std.mem.trim(u8, model, " \t\r\n").len == 0 or
        std.mem.trim(u8, prompt_mode, " \t\r\n").len == 0)
        return Error.EmptyEvidence;

    const input_hash = contentHash(original_input);
    const config_hash = contentHash(config_snapshot);
    const tool_catalog_hash = contentHash(tool_catalog_snapshot);
    const source_baseline_hash = contentHash(source_baseline);
    const environment_hash = contentHash(environment_snapshot);
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"run_seq\":{d},\"replay_input_immutable\":true,\"original_input\":{f},\"original_input_sha256\":\"sha256:{s}\",\"model\":{f},\"provider_id\":{f},\"prompt_mode\":{f},\"config_sha256\":\"sha256:{s}\",\"tool_catalog_sha256\":\"sha256:{s}\",\"source_baseline\":{f},\"source_baseline_sha256\":\"sha256:{s}\",\"environment_sha256\":\"sha256:{s}\"}}",
        .{
            repair_receipt_schema,
            run_seq,
            std.json.fmt(original_input, .{}),
            input_hash[0..],
            std.json.fmt(model, .{}),
            std.json.fmt(provider_id, .{}),
            std.json.fmt(prompt_mode, .{}),
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

/// The only comparison primitive used by an exact replay gate. Receipt fields
/// carry the stable `sha256:<hex>` label; snapshots remain transient.
pub fn contentHashMatches(label: []const u8, content: []const u8) bool {
    const hex = if (std.mem.startsWith(u8, label, "sha256:")) label[7..] else label;
    const digest = contentHash(content);
    return std.mem.eql(u8, hex, digest[0..]);
}

pub const RepairReceiptPayload = struct {
    schema: []const u8 = "",
    run_seq: u64 = 0,
    replay_input_immutable: bool = false,
    original_input: []const u8 = "",
    original_input_sha256: []const u8 = "",
    model: []const u8 = "",
    provider_id: []const u8 = "",
    prompt_mode: []const u8 = "",
    config_sha256: []const u8 = "",
    tool_catalog_sha256: []const u8 = "",
    source_baseline: []const u8 = "",
    source_baseline_sha256: []const u8 = "",
    environment_sha256: []const u8 = "",
};

pub const RepairRerunState = enum {
    started,
    completed,

    pub fn label(self: RepairRerunState) []const u8 {
        return switch (self) {
            .started => "started",
            .completed => "completed",
        };
    }
};

/// Append the durable control-plane edge between a failed source run and its
/// isolated exact-input treatment session. The child session owns provider and
/// tool events; the source session owns this compact relationship receipt.
pub fn appendRepairRerunEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    state: RepairRerunState,
    rerun_id: []const u8,
    source_receipt_seq: u64,
    applied_event_seq: u64,
    child_session_id: []const u8,
    original_input_sha256: []const u8,
    config_sha256: []const u8,
    source_baseline: []const u8,
    outcome: []const u8,
    input_match: bool,
    config_match: bool,
    provider_dispatched: bool,
) !u64 {
    if (source_receipt_seq == 0 or applied_event_seq == 0) return Error.EmptyEvidence;
    const required = [_][]const u8{
        session_id,
        rerun_id,
        child_session_id,
        original_input_sha256,
        config_sha256,
        source_baseline,
        outcome,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"rerun_id\":{f},\"source_receipt_seq\":{d},\"applied_event_seq\":{d},\"child_session_id\":{f},\"original_input_sha256\":{f},\"config_sha256\":{f},\"source_baseline\":{f},\"state\":\"{s}\",\"outcome\":{f},\"input_match\":{},\"config_match\":{},\"provider_dispatched\":{}}}",
        .{
            repair_rerun_schema,
            std.json.fmt(rerun_id, .{}),
            source_receipt_seq,
            applied_event_seq,
            std.json.fmt(child_session_id, .{}),
            std.json.fmt(original_input_sha256, .{}),
            std.json.fmt(config_sha256, .{}),
            std.json.fmt(source_baseline, .{}),
            state.label(),
            std.json.fmt(outcome, .{}),
            input_match,
            config_match,
            provider_dispatched,
        },
    );
    defer allocator.free(message);

    return store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = if (state == .started) repair_rerun_started_event_type else repair_rerun_completed_event_type,
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

/// Bounds are operator evidence, not hidden policy. A null bound means that
/// metric is recorded but not used as a pass/fail gate. Tool spans are the
/// conservative observable side-effect proxy here; file-effect certainty stays
/// with the existing `var1.tool_effect.v1` receipts.
pub const RepairEvaluationBounds = struct {
    max_latency_ms: ?u64 = null,
    max_side_effects_delta: ?u64 = null,
    max_prompt_tokens: ?u64 = null,
    max_completion_tokens: ?u64 = null,
    max_cost_usd: ?f64 = null,
};

pub const RepairEvaluationInput = struct {
    evaluation_id: []const u8,
    baseline_session_id: []const u8,
    treatment_session_id: []const u8,
    baseline_events: []const types.SessionEvent,
    treatment_events: []const types.SessionEvent,
    input_match: bool,
    config_match: bool,
    provider_dispatched: bool,
    bounds: RepairEvaluationBounds = .{},
};

pub const RepairEvaluationResult = struct {
    event_seq: u64,
    passed: bool,
};

const RepairEvaluationRunMetrics = struct {
    outcome: []const u8 = "missing",
    latency_ms: u64 = 0,
    tool_spans: u64 = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    usage_precision: []const u8 = "unknown",
    cost_total_usd: ?f64 = null,
    start_timestamp_ms: ?i64 = null,
    terminal_timestamp_ms: ?i64 = null,
};

const ParsedRepairTerminal = struct {
    outcome: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    usage_precision: []const u8 = "unknown",
    cost_total_usd: ?f64 = null,
};

pub const RepairEvaluationPayload = struct {
    schema: []const u8 = "",
    evaluation_id: []const u8 = "",
    baseline_session_id: []const u8 = "",
    treatment_session_id: []const u8 = "",
    passed: bool = false,
};

pub const RepairCandidatePayload = struct {
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

pub const RepairCandidateApprovalPayload = struct {
    schema: []const u8 = "",
    candidate_id: []const u8 = "",
    candidate_event_seq: u64 = 0,
    failure_id: []const u8 = "",
    approval_id: []const u8 = "",
    approved_by: []const u8 = "",
    patch_sha256: []const u8 = "",
    expected_source_baseline: []const u8 = "",
};

pub const RepairCandidateAppliedPayload = struct {
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
    status: []const u8 = "",
    mutation_allowed: bool = false,
};

pub const RepairRollbackState = enum {
    started,
    completed,

    pub fn label(self: RepairRollbackState) []const u8 {
        return switch (self) {
            .started => "started",
            .completed => "completed",
        };
    }
};

/// A rollback is a control-plane receipt, not a second patch language. The
/// source event spine retains the failed treatment and inverse effect while
/// `baseline_restored` proves whether the reviewed writer returned the target
/// bytes to the candidate's pre-apply hash.
pub fn appendRepairRollbackEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    state: RepairRollbackState,
    rollback_id: []const u8,
    evaluation_id: []const u8,
    candidate_event_seq: u64,
    approval_event_seq: u64,
    applied_event_seq: u64,
    target_path: []const u8,
    expected_current_sha256: []const u8,
    restored_sha256: []const u8,
    inverse_patch_sha256: []const u8,
    source_baseline: []const u8,
    status: []const u8,
    baseline_restored: bool,
) !u64 {
    if (candidate_event_seq == 0 or approval_event_seq == 0 or applied_event_seq == 0) return Error.EmptyEvidence;
    const required = [_][]const u8{
        session_id,
        rollback_id,
        evaluation_id,
        target_path,
        expected_current_sha256,
        restored_sha256,
        inverse_patch_sha256,
        source_baseline,
        status,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    const event_type = if (state == .started) repair_rollback_started_event_type else repair_rollback_completed_event_type;
    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);
    for (events) |*event| {
        if (!std.mem.eql(u8, event.event_type, event_type)) continue;
        var stored = std.json.parseFromSlice(RepairRollbackPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer stored.deinit();
        if (std.mem.eql(u8, stored.value.schema, repair_rollback_schema) and
            std.mem.eql(u8, stored.value.rollback_id, rollback_id))
        {
            return event.seq;
        }
    }

    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"rollback_id\":{f},\"evaluation_id\":{f},\"candidate_event_seq\":{d},\"approval_event_seq\":{d},\"applied_event_seq\":{d},\"target_path\":{f},\"expected_current_sha256\":{f},\"restored_sha256\":{f},\"inverse_patch_sha256\":{f},\"source_baseline\":{f},\"state\":\"{s}\",\"status\":{f},\"baseline_restored\":{},\"mutation_allowed\":true}}",
        .{
            repair_rollback_schema,
            std.json.fmt(rollback_id, .{}),
            std.json.fmt(evaluation_id, .{}),
            candidate_event_seq,
            approval_event_seq,
            applied_event_seq,
            std.json.fmt(target_path, .{}),
            std.json.fmt(expected_current_sha256, .{}),
            std.json.fmt(restored_sha256, .{}),
            std.json.fmt(inverse_patch_sha256, .{}),
            std.json.fmt(source_baseline, .{}),
            state.label(),
            std.json.fmt(status, .{}),
            baseline_restored,
        },
    );
    defer allocator.free(message);

    return store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = event_type,
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

pub const RepairRollbackPayload = struct {
    schema: []const u8 = "",
    rollback_id: []const u8 = "",
    evaluation_id: []const u8 = "",
    candidate_event_seq: u64 = 0,
    approval_event_seq: u64 = 0,
    applied_event_seq: u64 = 0,
    target_path: []const u8 = "",
    expected_current_sha256: []const u8 = "",
    restored_sha256: []const u8 = "",
    inverse_patch_sha256: []const u8 = "",
    source_baseline: []const u8 = "",
    state: []const u8 = "",
    status: []const u8 = "",
    baseline_restored: bool = false,
    mutation_allowed: bool = false,
};

const RepairTokenCostCheck = struct {
    evaluable: bool,
    within_bound: bool,
};

fn stableRepairOutcome(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "completed")) return "completed";
    if (std.mem.eql(u8, value, "failed")) return "failed";
    if (std.mem.eql(u8, value, "timed_out")) return "timed_out";
    if (std.mem.eql(u8, value, "cancelled")) return "cancelled";
    return "unknown";
}

fn collectRepairEvaluationMetrics(
    allocator: std.mem.Allocator,
    events: []const types.SessionEvent,
) !RepairEvaluationRunMetrics {
    var metrics = RepairEvaluationRunMetrics{};

    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "turn_started")) {
            metrics.start_timestamp_ms = event.timestamp_ms;
        } else if (std.mem.eql(u8, event.event_type, "session_started") and metrics.start_timestamp_ms == null) {
            metrics.start_timestamp_ms = event.timestamp_ms;
        }
        if (std.mem.eql(u8, event.event_type, "tool_finished")) {
            metrics.tool_spans +|= 1;
        }
        if (!std.mem.eql(u8, event.event_type, protocol_events.turn_terminal_event_type)) continue;

        var parsed = std.json.parseFromSlice(ParsedRepairTerminal, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        metrics.outcome = stableRepairOutcome(parsed.value.outcome);
        metrics.prompt_tokens = parsed.value.prompt_tokens;
        metrics.completion_tokens = parsed.value.completion_tokens;
        metrics.cached_tokens = parsed.value.cached_tokens;
        metrics.usage_precision = if (std.mem.eql(u8, parsed.value.usage_precision, "exact")) "exact" else "unknown";
        metrics.cost_total_usd = parsed.value.cost_total_usd;
        metrics.terminal_timestamp_ms = event.timestamp_ms;
    }

    if (metrics.start_timestamp_ms) |start| {
        if (metrics.terminal_timestamp_ms) |end| {
            metrics.latency_ms = if (end > start) @intCast(end - start) else 0;
        }
    }

    return metrics;
}

fn repairTotalTokens(metrics: RepairEvaluationRunMetrics) u64 {
    return metrics.prompt_tokens +| metrics.completion_tokens +| metrics.cached_tokens;
}

fn repairSignedDelta(treatment: u64, baseline: u64) i64 {
    if (treatment >= baseline) return @intCast(treatment - baseline);
    return -@as(i64, @intCast(baseline - treatment));
}

fn repairTokenCostCheck(
    metrics: RepairEvaluationRunMetrics,
    bounds: RepairEvaluationBounds,
) RepairTokenCostCheck {
    var evaluable = true;
    var within_bound = true;
    const has_token_bound = bounds.max_prompt_tokens != null or bounds.max_completion_tokens != null;

    if (has_token_bound and !std.mem.eql(u8, metrics.usage_precision, "exact")) {
        evaluable = false;
        within_bound = false;
    }
    if (bounds.max_prompt_tokens) |bound| {
        if (metrics.prompt_tokens > bound) within_bound = false;
    }
    if (bounds.max_completion_tokens) |bound| {
        if (metrics.completion_tokens > bound) within_bound = false;
    }
    if (bounds.max_cost_usd) |bound| {
        if (metrics.cost_total_usd) |cost| {
            if (cost > bound) within_bound = false;
        } else {
            evaluable = false;
            within_bound = false;
        }
    }

    return .{ .evaluable = evaluable, .within_bound = within_bound };
}

fn writeOptionalU64(writer: anytype, value: ?u64) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalF64(writer: anytype, value: ?f64) !void {
    if (value) |number| {
        try writer.print("{f}", .{std.json.fmt(number, .{})});
    } else {
        try writer.writeAll("null");
    }
}

/// Compare one source baseline and one fresh treatment from their existing
/// event ledgers. The receipt is compact, deterministic for the supplied
/// evidence, and idempotent by evaluation ID. It never mutates executor state.
pub fn appendRepairEvaluationEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    source_session_id: []const u8,
    existing_source_events: []const types.SessionEvent,
    input: RepairEvaluationInput,
) !RepairEvaluationResult {
    const required = [_][]const u8{
        source_session_id,
        input.evaluation_id,
        input.baseline_session_id,
        input.treatment_session_id,
    };
    for (required) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.EmptyEvidence;
    }

    for (existing_source_events) |event| {
        if (!std.mem.eql(u8, event.event_type, repair_evaluation_event_type)) continue;
        var stored = std.json.parseFromSlice(RepairEvaluationPayload, allocator, event.message, .{
            .ignore_unknown_fields = true,
        }) catch continue;
        defer stored.deinit();
        if (std.mem.eql(u8, stored.value.schema, repair_evaluation_schema) and
            std.mem.eql(u8, stored.value.evaluation_id, input.evaluation_id))
        {
            return .{ .event_seq = event.seq, .passed = stored.value.passed };
        }
    }

    const baseline = try collectRepairEvaluationMetrics(allocator, input.baseline_events);
    const treatment = try collectRepairEvaluationMetrics(allocator, input.treatment_events);
    const token_cost = repairTokenCostCheck(treatment, input.bounds);
    const treatment_completed = std.mem.eql(u8, treatment.outcome, "completed");
    const side_effects_within_bound = if (input.bounds.max_side_effects_delta) |bound|
        treatment.tool_spans <= baseline.tool_spans +| bound
    else
        true;
    const latency_within_bound = if (input.bounds.max_latency_ms) |bound|
        treatment.latency_ms <= bound
    else
        true;
    const passed = input.input_match and input.config_match and input.provider_dispatched and
        treatment_completed and side_effects_within_bound and latency_within_bound and token_cost.within_bound;

    var message = std.array_list.Managed(u8).init(allocator);
    errdefer message.deinit();
    const writer = message.writer();
    try writer.print(
        "{{\"schema\":\"{s}\",\"evaluation_id\":{f},\"baseline_session_id\":{f},\"treatment_session_id\":{f},\"baseline_outcome\":\"{s}\",\"treatment_outcome\":\"{s}\",\"baseline_latency_ms\":{d},\"treatment_latency_ms\":{d},\"latency_delta_ms\":{d},\"baseline_tool_spans\":{d},\"treatment_tool_spans\":{d},\"tool_span_delta\":{d},\"baseline_prompt_tokens\":{d},\"treatment_prompt_tokens\":{d},\"baseline_completion_tokens\":{d},\"treatment_completion_tokens\":{d},\"baseline_cached_tokens\":{d},\"treatment_cached_tokens\":{d},\"baseline_total_tokens\":{d},\"treatment_total_tokens\":{d},\"baseline_cost_usd\":",
        .{
            repair_evaluation_schema,
            std.json.fmt(input.evaluation_id, .{}),
            std.json.fmt(input.baseline_session_id, .{}),
            std.json.fmt(input.treatment_session_id, .{}),
            baseline.outcome,
            treatment.outcome,
            baseline.latency_ms,
            treatment.latency_ms,
            repairSignedDelta(treatment.latency_ms, baseline.latency_ms),
            baseline.tool_spans,
            treatment.tool_spans,
            repairSignedDelta(treatment.tool_spans, baseline.tool_spans),
            baseline.prompt_tokens,
            treatment.prompt_tokens,
            baseline.completion_tokens,
            treatment.completion_tokens,
            baseline.cached_tokens,
            treatment.cached_tokens,
            repairTotalTokens(baseline),
            repairTotalTokens(treatment),
        },
    );
    try writeOptionalF64(writer, baseline.cost_total_usd);
    try writer.writeAll(",\"treatment_cost_usd\":");
    try writeOptionalF64(writer, treatment.cost_total_usd);
    try writer.print(
        ",\"input_identity\":{},\"config_identity\":{},\"provider_dispatched\":{},\"treatment_completed\":{},\"side_effects_within_bound\":{},\"latency_within_bound\":{},\"token_cost_evaluable\":{},\"token_cost_within_bound\":{},\"passed\":{},\"max_latency_ms\":",
        .{
            input.input_match,
            input.config_match,
            input.provider_dispatched,
            treatment_completed,
            side_effects_within_bound,
            latency_within_bound,
            token_cost.evaluable,
            token_cost.within_bound,
            passed,
        },
    );
    try writeOptionalU64(writer, input.bounds.max_latency_ms);
    try writer.writeAll(",\"max_side_effects_delta\":");
    try writeOptionalU64(writer, input.bounds.max_side_effects_delta);
    try writer.writeAll(",\"max_prompt_tokens\":");
    try writeOptionalU64(writer, input.bounds.max_prompt_tokens);
    try writer.writeAll(",\"max_completion_tokens\":");
    try writeOptionalU64(writer, input.bounds.max_completion_tokens);
    try writer.writeAll(",\"max_cost_usd\":");
    try writeOptionalF64(writer, input.bounds.max_cost_usd);
    try writer.writeAll(",\"executor_mutation\":\"forbidden\"}");

    const event_seq = try store.appendEventWithSeq(allocator, workspace_root, source_session_id, .{
        .event_type = repair_evaluation_event_type,
        .message = message.items,
        .timestamp_ms = std.time.milliTimestamp(),
    });
    message.deinit();
    return .{ .event_seq = event_seq, .passed = passed };
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
        "openai-compatible",
        "orchestrate",
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
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"provider_id\":\"openai-compatible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "\"prompt_mode\":\"orchestrate\"") != null);
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

test "repair evaluator compares bounded baseline and treatment evidence idempotently" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var baseline_session = try store.initSession(std.testing.allocator, workspace_root, "baseline run");
    defer baseline_session.deinit(std.testing.allocator);
    var treatment_session = try store.initSession(std.testing.allocator, workspace_root, "treatment run");
    defer treatment_session.deinit(std.testing.allocator);

    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, baseline_session.id, .{
        .event_type = "session_started",
        .message = "{}",
        .timestamp_ms = 100,
    });
    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, baseline_session.id, .{
        .event_type = "turn_started",
        .message = "{}",
        .timestamp_ms = 110,
    });
    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, baseline_session.id, .{
        .event_type = "tool_finished",
        .message = "{\"tool\":\"read_file\",\"ok\":true}",
        .timestamp_ms = 120,
    });
    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, baseline_session.id, .{
        .event_type = protocol_events.turn_terminal_event_type,
        .message = "{\"outcome\":\"failed\",\"prompt_tokens\":10,\"completion_tokens\":3,\"cached_tokens\":1,\"usage_precision\":\"exact\",\"cost_total_usd\":0.01}",
        .timestamp_ms = 150,
    });

    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, treatment_session.id, .{
        .event_type = "session_started",
        .message = "{}",
        .timestamp_ms = 200,
    });
    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, treatment_session.id, .{
        .event_type = "turn_started",
        .message = "{}",
        .timestamp_ms = 210,
    });
    _ = try store.appendEventWithSeq(std.testing.allocator, workspace_root, treatment_session.id, .{
        .event_type = protocol_events.turn_terminal_event_type,
        .message = "{\"outcome\":\"completed\",\"prompt_tokens\":11,\"completion_tokens\":4,\"cached_tokens\":1,\"usage_precision\":\"exact\",\"cost_total_usd\":0.02}",
        .timestamp_ms = 260,
    });

    const baseline_events = try store.readEvents(std.testing.allocator, workspace_root, baseline_session.id);
    defer types.deinitSessionEvents(std.testing.allocator, baseline_events);
    const treatment_events = try store.readEvents(std.testing.allocator, workspace_root, treatment_session.id);
    defer types.deinitSessionEvents(std.testing.allocator, treatment_events);

    const first = try appendRepairEvaluationEvent(
        std.testing.allocator,
        workspace_root,
        baseline_session.id,
        baseline_events,
        .{
            .evaluation_id = "evaluation-1",
            .baseline_session_id = baseline_session.id,
            .treatment_session_id = treatment_session.id,
            .baseline_events = baseline_events,
            .treatment_events = treatment_events,
            .input_match = true,
            .config_match = true,
            .provider_dispatched = true,
            .bounds = .{
                .max_latency_ms = 100,
                .max_side_effects_delta = 0,
                .max_prompt_tokens = 20,
                .max_completion_tokens = 20,
                .max_cost_usd = 0.1,
            },
        },
    );
    try std.testing.expect(first.passed);

    const persisted = try store.readEvents(std.testing.allocator, workspace_root, baseline_session.id);
    defer types.deinitSessionEvents(std.testing.allocator, persisted);
    try std.testing.expectEqual(@as(usize, 5), persisted.len);
    try std.testing.expectEqualStrings(repair_evaluation_event_type, persisted[4].event_type);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"schema\":\"var1.repair_evaluation.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"baseline_outcome\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"treatment_outcome\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"treatment_latency_ms\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"side_effects_within_bound\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"token_cost_evaluable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted[4].message, "\"passed\":true") != null);

    const repeated = try appendRepairEvaluationEvent(
        std.testing.allocator,
        workspace_root,
        baseline_session.id,
        persisted,
        .{
            .evaluation_id = "evaluation-1",
            .baseline_session_id = baseline_session.id,
            .treatment_session_id = treatment_session.id,
            .baseline_events = baseline_events,
            .treatment_events = treatment_events,
            .input_match = true,
            .config_match = true,
            .provider_dispatched = true,
        },
    );
    try std.testing.expectEqual(first.event_seq, repeated.event_seq);
    try std.testing.expect(repeated.passed);
}
