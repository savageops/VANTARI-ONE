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

pub fn serializeTurnTerminal(
    allocator: std.mem.Allocator,
    run_seq: u64,
    input: TurnTerminalInput,
) ![]u8 {
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
    const json = try serializeTurnTerminal(std.testing.allocator, 17, .{
        .outcome = .timed_out,
        .detail = "provider \"deadline\"",
    });
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\":\"var1.turn_terminal.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"run_seq\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outcome\":\"timed_out\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "provider \\\"deadline\\\"") != null);
}
