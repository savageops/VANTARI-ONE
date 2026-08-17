const std = @import("std");

/// Typed payloads for migrated VAR1 event-spine paths. Each struct carries its
/// schema version for forward-compatible evolution (AGENTS.md §IV).
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

pub const context_compile_diagnostic_event_type = "context_compile_diagnostic";

/// One compact diagnostic for a provider-context compile. Counts describe
/// durable rows that were repaired or skipped while preserving the valid
/// prefix; the event carries no transcript content.
pub const ContextCompileDiagnostic = struct {
    schema: []const u8 = "var1.context_compile_diagnostic.v1",
    phase: []const u8,
    synthesized_tool_results: u32,
    skipped_tool_results: u32,
};

pub const failure_receipt_schema = "var1.failure_receipt.v1";
pub const max_failure_detail_bytes: usize = 2048;

/// One bounded, deterministic description of a terminal harness failure.
/// The receipt is embedded in the existing turn-terminal event so the event
/// ledger remains the only durable failure spine. Move 72 extends this shape
/// with immutable replay inputs and environment evidence.
pub const FailureReceipt = struct {
    schema: []const u8 = failure_receipt_schema,
    failure_id: []const u8,
    failure_class: []const u8,
    phase: []const u8,
    detail: []const u8,
};

/// One run-final carrier. `run_seq` is the exact durable `session_started.seq`
/// for an admitted run, or zero when admission failed before a start row could
/// exist. Timeout remains distinct evidence even though SessionStatus projects
/// it to failed.
pub const TurnTerminalOutcome = enum {
    completed,
    failed,
    timed_out,
    cancelled,
};

pub const turn_terminal_event_type = "turn_terminal";

pub const TurnTerminalInput = struct {
    outcome: TurnTerminalOutcome,
    detail: []const u8 = "",
    failure_class: []const u8 = "",
    failure_phase: []const u8 = "turn",
    step: usize = 0,
    window_tokens: u64 = 0,
    window_precision: []const u8 = "unknown",
    output_bytes: usize = 0,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    usage_precision: []const u8 = "unknown",
    cost_total_usd: ?f64 = null,
};

pub const prompt_mode_changed_event_type = "prompt_mode_changed";

pub const PromptModeChanged = struct {
    schema: []const u8 = "var1.prompt_mode_changed.v1",
    from: []const u8,
    to: []const u8,
    reason: []const u8,
};

pub const max_prompt_mode_reason_bytes: usize = 240;

pub fn serializePromptModeChanged(
    allocator: std.mem.Allocator,
    from_label: []const u8,
    to_label: []const u8,
    reason: []const u8,
) ![]u8 {
    const bounded_reason = if (reason.len > max_prompt_mode_reason_bytes)
        reason[0..max_prompt_mode_reason_bytes]
    else
        reason;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.prompt_mode_changed.v1\",\"from\":{f},\"to\":{f},\"reason\":{f}}}",
        .{
            std.json.fmt(from_label, .{}),
            std.json.fmt(to_label, .{}),
            std.json.fmt(bounded_reason, .{}),
        },
    );
}

pub const TurnTerminal = struct {
    schema: []const u8 = "var1.turn_terminal.v1",
    run_seq: u64,
    outcome: []const u8,
    detail: []const u8,
    step: usize,
    window_tokens: u64,
    window_precision: []const u8,
    output_bytes: usize,
    prompt_tokens: u64,
    completion_tokens: u64,
    cached_tokens: u64,
    usage_precision: []const u8,
    cost_total_usd: ?f64,
    failure: ?FailureReceipt = null,
};

pub fn turnTerminalOutcomeLabel(outcome: TurnTerminalOutcome) []const u8 {
    return switch (outcome) {
        .completed => "completed",
        .failed => "failed",
        .timed_out => "timed_out",
        .cancelled => "cancelled",
    };
}

pub fn parseTurnTerminalOutcome(value: []const u8) !TurnTerminalOutcome {
    inline for (std.meta.fields(TurnTerminalOutcome)) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidTurnTerminalOutcome;
}

pub fn isFailureOutcome(outcome: TurnTerminalOutcome) bool {
    return outcome == .failed or outcome == .timed_out;
}

/// Keep failure classes small and stable even when callers pass Zig error
/// names or provider diagnostics. Callers may provide one of the canonical
/// labels directly; otherwise the shared evidence text is classified once at
/// the terminal owner.
pub fn normalizeFailureClass(
    outcome: TurnTerminalOutcome,
    hint: []const u8,
    detail: []const u8,
) []const u8 {
    if (outcome == .timed_out) return "timeout";

    const canonical = [_][]const u8{
        "auth",
        "capability",
        "context",
        "execution_limit",
        "provider_transport",
        "runtime",
        "stale_lease",
        "stale_owner",
        "tool",
        "timeout",
    };
    for (canonical) |label| {
        if (std.ascii.eqlIgnoreCase(hint, label)) return label;
    }

    const has = struct {
        fn match(needle: []const u8, left: []const u8, right: []const u8) bool {
            return std.ascii.indexOfIgnoreCase(left, needle) != null or
                std.ascii.indexOfIgnoreCase(right, needle) != null;
        }
    }.match;

    if (has("stale_lease", hint, detail) or has("lease expired", hint, detail)) return "stale_lease";
    if (has("stale", hint, detail) or has("owner", hint, detail)) return "stale_owner";
    if (has("auth", hint, detail) or has("unauthorized", hint, detail) or
        has("forbidden", hint, detail) or has("entitlement", hint, detail)) return "auth";
    if (has("budget", hint, detail) or has("steplimit", hint, detail) or has("step_limit", hint, detail)) return "execution_limit";
    if (has("context", hint, detail) or has("compaction", hint, detail)) return "context";
    if (has("tool", hint, detail) or has("invalidargument", hint, detail)) return "tool";
    if (has("connection", hint, detail) or has("network", hint, detail) or
        has("badstatus", hint, detail) or has("malformed", hint, detail) or
        has("stream", hint, detail)) return "provider_transport";
    if (has("unsupported", hint, detail) or has("unavailable", hint, detail)) return "capability";
    return "runtime";
}

pub fn normalizeFailurePhase(hint: []const u8, detail: []const u8) []const u8 {
    const canonical = [_][]const u8{ "auth", "context", "provider", "runtime", "scheduler", "tool", "turn" };
    for (canonical) |label| {
        if (std.ascii.eqlIgnoreCase(hint, label)) return label;
    }
    if (std.ascii.indexOfIgnoreCase(hint, "tool") != null) return "tool";
    if (std.ascii.indexOfIgnoreCase(hint, "context") != null or
        std.ascii.indexOfIgnoreCase(hint, "compaction") != null) return "context";
    if (std.ascii.indexOfIgnoreCase(hint, "provider") != null or
        std.ascii.indexOfIgnoreCase(hint, "connection") != null) return "provider";
    if (std.ascii.indexOfIgnoreCase(hint, "lease") != null or
        std.ascii.indexOfIgnoreCase(hint, "scheduler") != null) return "scheduler";
    if (std.ascii.indexOfIgnoreCase(hint, "auth") != null) return "auth";
    if (std.ascii.indexOfIgnoreCase(detail, "tool") != null) return "tool";
    if (std.ascii.indexOfIgnoreCase(detail, "context") != null or
        std.ascii.indexOfIgnoreCase(detail, "compaction") != null) return "context";
    if (std.ascii.indexOfIgnoreCase(detail, "provider") != null or
        std.ascii.indexOfIgnoreCase(detail, "connection") != null) return "provider";
    if (std.ascii.indexOfIgnoreCase(detail, "lease") != null or
        std.ascii.indexOfIgnoreCase(detail, "scheduler") != null) return "scheduler";
    return "runtime";
}

/// Return a UTF-8-safe bounded view for operator-facing failure evidence.
pub fn boundedFailureDetail(detail: []const u8) []const u8 {
    if (detail.len <= max_failure_detail_bytes) return detail;
    var end = max_failure_detail_bytes;
    while (end > 0 and (detail[end] & 0xc0) == 0x80) : (end -= 1) {}
    return detail[0..end];
}

/// Derive a stable receipt identity from the durable subject/run boundary and
/// normalized failure evidence. No wall-clock or random value participates.
pub fn failureReceiptId(
    allocator: std.mem.Allocator,
    subject_id: []const u8,
    sequence: u64,
    failure_class: []const u8,
    phase: []const u8,
    detail: []const u8,
) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(failure_receipt_schema);
    hasher.update("\x00");
    hasher.update(subject_id);
    hasher.update("\x00");
    var sequence_buffer: [32]u8 = undefined;
    const sequence_text = try std.fmt.bufPrint(&sequence_buffer, "{d}", .{sequence});
    hasher.update(sequence_text);
    hasher.update("\x00");
    hasher.update(failure_class);
    hasher.update("\x00");
    hasher.update(phase);
    hasher.update("\x00");
    hasher.update(boundedFailureDetail(detail));

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[index * 2 + 1] = hex_chars[@as(usize, byte & 0x0f)];
    }
    return std.fmt.allocPrint(allocator, "failure-{s}", .{hex[0..]});
}

pub fn serializeTurnTerminal(
    allocator: std.mem.Allocator,
    subject_id: []const u8,
    run_seq: u64,
    input: TurnTerminalInput,
) ![]u8 {
    var failure_id: ?[]u8 = null;
    defer if (failure_id) |value| allocator.free(value);

    var failure: ?FailureReceipt = null;
    if (isFailureOutcome(input.outcome)) {
        const failure_class = normalizeFailureClass(input.outcome, input.failure_class, input.detail);
        const phase = normalizeFailurePhase(input.failure_phase, input.detail);
        const detail = boundedFailureDetail(input.detail);
        failure_id = try failureReceiptId(allocator, subject_id, run_seq, failure_class, phase, detail);
        failure = .{
            .failure_id = failure_id.?,
            .failure_class = failure_class,
            .phase = phase,
            .detail = detail,
        };
    }

    return serialize(allocator, TurnTerminal{
        .run_seq = run_seq,
        .outcome = turnTerminalOutcomeLabel(input.outcome),
        .detail = input.detail,
        .step = input.step,
        .window_tokens = input.window_tokens,
        .window_precision = input.window_precision,
        .output_bytes = input.output_bytes,
        .prompt_tokens = input.prompt_tokens,
        .completion_tokens = input.completion_tokens,
        .cached_tokens = input.cached_tokens,
        .usage_precision = input.usage_precision,
        .cost_total_usd = input.cost_total_usd,
        .failure = failure,
    });
}

pub fn serializeContextCompileDiagnostic(
    allocator: std.mem.Allocator,
    phase: []const u8,
    synthesized_tool_results: u32,
    skipped_tool_results: u32,
) ![]u8 {
    return serialize(allocator, ContextCompileDiagnostic{
        .phase = phase,
        .synthesized_tool_results = synthesized_tool_results,
        .skipped_tool_results = skipped_tool_results,
    });
}

/// Serialize a typed event payload to owned canonical JSON.
pub fn serialize(allocator: std.mem.Allocator, event: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(event, .{})});
}

/// Preserve arbitrary command bytes in the one typed output envelope. The
/// enclosing event ledger stays canonical UTF-8 JSON; clients decode only this
/// runtime-owned field and treat the bytes as untrusted display data.
pub fn serializeToolOutputDelta(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool: []const u8,
    stream: []const u8,
    chunk: []const u8,
    cap_reached: bool,
) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(chunk.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, chunk);

    return serialize(allocator, ToolOutputDelta{
        .tool_call_id = tool_call_id,
        .tool = tool,
        .stream = stream,
        .chunk_b64 = encoded,
        .cap_reached = cap_reached,
    });
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

test "ToolFinished serializes its terminal state" {
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

test "TurnTerminal serializes one escaped typed outcome" {
    const json = try serializeTurnTerminal(std.testing.allocator, "session-17", 17, .{
        .outcome = .timed_out,
        .detail = "provider \"deadline\"",
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"var1.turn_terminal.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"run_seq\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outcome\":\"timed_out\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "provider \\\"deadline\\\"") != null);
}

test "failed terminal serializes one normalized deterministic failure receipt" {
    const input: TurnTerminalInput = .{
        .outcome = .failed,
        .detail = "BadStatus status=503 provider unavailable",
    };
    const first = try serializeTurnTerminal(std.testing.allocator, "session-failure", 4, input);
    defer std.testing.allocator.free(first);
    const second = try serializeTurnTerminal(std.testing.allocator, "session-failure", 4, input);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "var1.failure_receipt.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"failure_class\":\"provider_transport\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"phase\":\"turn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"failure_id\":\"failure-") != null);
}

test "successful and cancelled terminals do not manufacture failure receipts" {
    const completed = try serializeTurnTerminal(std.testing.allocator, "session-ok", 1, .{ .outcome = .completed });
    defer std.testing.allocator.free(completed);
    const cancelled = try serializeTurnTerminal(std.testing.allocator, "session-cancelled", 1, .{ .outcome = .cancelled });
    defer std.testing.allocator.free(cancelled);
    try std.testing.expect(std.mem.indexOf(u8, completed, "var1.failure_receipt.v1") == null);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "var1.failure_receipt.v1") == null);
}

test "failure detail is bounded without cutting a UTF-8 continuation" {
    var detail: [max_failure_detail_bytes + 4]u8 = undefined;
    @memset(&detail, 'x');
    detail[max_failure_detail_bytes - 1] = 0xe2;
    detail[max_failure_detail_bytes] = 0x82;
    detail[max_failure_detail_bytes + 1] = 0xac;
    detail[max_failure_detail_bytes + 2] = 'y';
    const bounded = boundedFailureDetail(&detail);
    try std.testing.expectEqual(@as(usize, max_failure_detail_bytes - 1), bounded.len);
}

test "failure phase stays in the bounded phase vocabulary" {
    try std.testing.expectEqualStrings("provider", normalizeFailurePhase("provider_stream_reader", ""));
    try std.testing.expectEqualStrings("runtime", normalizeFailurePhase("untrusted phase text", ""));
}

test "ContextCompileDiagnostic serializes repair counts" {
    const json = try serializeContextCompileDiagnostic(std.testing.allocator, "provider_rebuild", 2, 1);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "var1.context_compile_diagnostic.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"phase\":\"provider_rebuild\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"synthesized_tool_results\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"skipped_tool_results\":1") != null);
}
