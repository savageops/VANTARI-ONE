const std = @import("std");
const context_builder = @import("../context/index.zig");
const pricing = @import("../providers/pricing.zig");
const protocol_events = @import("../../shared/protocol/events.zig");
const types = @import("../../shared/types.zig");

/// Turn boundary evidence — the single owner of turn-start telemetry and
/// completed terminal measurements. Both the kernel executor loop and the
/// model-task supervisor consume this projection so measured usage cannot drift.
/// Why: measured token telemetry and derived cost must be emitted from one
/// contract, not duplicated per caller (AGENTS.md §IV typed event grammar).
/// Evidence: consumed by loop.zig:320/743 and supervisor.zig model tasks.
/// Typed turn ingress payload: step index + estimated window tokens. The
/// precision marker prevents clients from presenting the compiler estimate as
/// provider-reported usage.
pub fn turnStartedPayload(
    allocator: std.mem.Allocator,
    step: usize,
    messages: []const types.ChatMessage,
) ![]u8 {
    const window_tokens = context_builder.budget.estimateChatMessages(messages);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.turn_started.v1\",\"step\":{d},\"window_tokens\":{d},\"window_precision\":\"{s}\"}}",
        .{ step, window_tokens, types.TokenPrecision.estimated.label() },
    );
}

/// Build the measured portion of one completed `turn_terminal` row. The session
/// store binds this input to the exact durable run sequence and serializes it.
/// Unknown model price remains null; token buckets remain measured provider
/// data. Missing provider usage remains unknown and is never promoted to an
/// exact zero.
pub fn completedTerminalInput(
    step: usize,
    messages: []const types.ChatMessage,
    model: []const u8,
    usage: types.Usage,
    output_bytes: usize,
) protocol_events.TurnTerminalInput {
    const window_tokens = context_builder.budget.estimateChatMessages(messages);
    var measured = usage;
    measured.reconcile();
    const cost = if (measured.precision == .exact)
        pricing.calculateCost(model, measured)
    else
        null;
    return .{
        .outcome = .completed,
        .step = step,
        .window_tokens = window_tokens,
        .window_precision = types.TokenPrecision.estimated.label(),
        .output_bytes = output_bytes,
        .prompt_tokens = measured.prompt_tokens,
        .completion_tokens = measured.completion_tokens,
        .cached_tokens = measured.cached_tokens,
        .usage_precision = measured.precision.label(),
        .cost_total_usd = if (cost) |value| value.total_usd else null,
    };
}

test "completed terminal input carries all measured token fields" {
    const input = completedTerminalInput(3, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 100,
        .completion_tokens = 40,
        .cached_tokens = 20,
        .total_tokens = 160,
    }, 25);
    try std.testing.expectEqual(protocol_events.TurnTerminalOutcome.completed, input.outcome);
    try std.testing.expectEqual(@as(usize, 3), input.step);
    try std.testing.expectEqual(@as(u64, 100), input.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 40), input.completion_tokens);
    try std.testing.expectEqual(@as(u64, 20), input.cached_tokens);
    try std.testing.expectEqualStrings("estimated", input.window_precision);
    try std.testing.expectEqualStrings("exact", input.usage_precision);
    try std.testing.expectEqual(@as(usize, 25), input.output_bytes);
}

test "cost_total_usd present when model priced" {
    const input = completedTerminalInput(1, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 1_000_000,
        .completion_tokens = 500_000,
        .cached_tokens = 100_000,
    }, 0);
    try std.testing.expectApproxEqAbs(@as(f64, 0.28028), input.cost_total_usd.?, 1e-12);
}

test "cost_total_usd null when model unpriced" {
    const input = completedTerminalInput(1, &.{}, "custom-local-model", .{
        .prompt_tokens = 100,
    }, 0);
    try std.testing.expect(input.cost_total_usd == null);
    try std.testing.expectEqualStrings("exact", input.usage_precision);
}

test "missing provider usage remains unknown" {
    const input = completedTerminalInput(1, &.{}, "custom-local-model", .{}, 0);
    try std.testing.expectEqualStrings("unknown", input.usage_precision);
    try std.testing.expectEqual(@as(u64, 0), input.prompt_tokens);
}

test "turn_started payload labels estimated window" {
    const payload = try turnStartedPayload(std.testing.allocator, 2, &.{});
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":\"var1.turn_started.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"step\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"window_tokens\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"window_precision\":\"estimated\"") != null);
}

test "window_tokens and output_bytes enter terminal evidence" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = @constCast("hello") },
    };
    const input = completedTerminalInput(0, messages[0..], "glm-5.2", .{}, 7);
    try std.testing.expectEqual(@as(usize, 7), input.output_bytes);
    try std.testing.expect(input.window_tokens > 0);
    // No provider usage means no measured cost, even for a known free tier.
    try std.testing.expect(input.cost_total_usd == null);
}

test "exact zero-price usage remains a measured zero cost" {
    const input = completedTerminalInput(0, &.{}, "glm-5.2", .{
        .prompt_tokens = 50,
        .completion_tokens = 10,
    }, 7);
    try std.testing.expectEqualStrings("exact", input.usage_precision);
    try std.testing.expectEqual(@as(?f64, 0), input.cost_total_usd);
}

test "completed input serializes through the canonical terminal schema" {
    const input = completedTerminalInput(5, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 10,
        .completion_tokens = 4,
        .cached_tokens = 2,
        .total_tokens = 16,
    }, 3);
    const payload = try protocol_events.serializeTurnTerminal(std.testing.allocator, "session-terminal", 11, input);
    defer std.testing.allocator.free(payload);

    const Parsed = struct {
        schema: []const u8,
        run_seq: u64,
        outcome: []const u8,
        step: usize,
        prompt_tokens: u64,
        completion_tokens: u64,
        cached_tokens: u64,
        usage_precision: []const u8,
        cost_total_usd: ?f64,
    };
    var parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("var1.turn_terminal.v1", parsed.value.schema);
    try std.testing.expectEqual(@as(u64, 11), parsed.value.run_seq);
    try std.testing.expectEqualStrings("completed", parsed.value.outcome);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.step);
    try std.testing.expectEqual(@as(u64, 10), parsed.value.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 4), parsed.value.completion_tokens);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.cached_tokens);
    try std.testing.expectEqualStrings("exact", parsed.value.usage_precision);
    try std.testing.expect(parsed.value.cost_total_usd != null);
}
