const std = @import("std");
const context_builder = @import("../context/index.zig");
const pricing = @import("../providers/pricing.zig");
const types = @import("../../shared/types.zig");

/// Turn boundary payload builders — the single owner of turn_started /
/// turn_finished JSON on the typed event spine. Both the kernel executor loop
/// and the model-task supervisor consume these builders so the two
/// turn_finished emissions cannot drift apart.
/// Why: measured token telemetry and derived cost must be emitted from one
/// contract, not duplicated per caller (AGENTS.md §IV typed event grammar).
/// Evidence: consumed by loop.zig:320/743 and supervisor.zig model tasks.

/// Typed turn ingress payload: step index + estimated window tokens
/// (schema var1.turn_started.v1, unchanged from the pre-chain shape).
pub fn turnStartedPayload(
    allocator: std.mem.Allocator,
    step: usize,
    messages: []const types.ChatMessage,
) ![]u8 {
    const window_tokens = context_builder.budget.estimateChatMessages(messages);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.turn_started.v1\",\"step\":{d},\"window_tokens\":{d}}}",
        .{ step, window_tokens },
    );
}

/// Typed turn terminal payload (schema var1.turn_finished.v2): step index,
/// estimated window tokens, output byte count, and the MEASURED provider
/// token buckets (prompt/completion/cached) plus the priced dollar total.
/// `cost_total_usd` is a number when the model has a compiled price, literal
/// null otherwise — cost is never fabricated for unknown models.
/// Why: the event spine must answer "what did this turn cost" with measured
/// evidence, not an estimate. Evidence: usage from provider adapters (035a/c),
/// priced via pricing.calculateCost (035b).
pub fn turnFinishedPayload(
    allocator: std.mem.Allocator,
    step: usize,
    messages: []const types.ChatMessage,
    model: []const u8,
    usage: types.Usage,
    output_bytes: usize,
) ![]u8 {
    const window_tokens = context_builder.budget.estimateChatMessages(messages);
    const cost = pricing.calculateCost(model, usage);
    if (cost) |c| {
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"var1.turn_finished.v2\",\"step\":{d},\"window_tokens\":{d},\"output_bytes\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"cached_tokens\":{d},\"cost_total_usd\":{d}}}",
            .{ step, window_tokens, output_bytes, usage.prompt_tokens, usage.completion_tokens, usage.cached_tokens, c.total_usd },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.turn_finished.v2\",\"step\":{d},\"window_tokens\":{d},\"output_bytes\":{d},\"prompt_tokens\":{d},\"completion_tokens\":{d},\"cached_tokens\":{d},\"cost_total_usd\":null}}",
        .{ step, window_tokens, output_bytes, usage.prompt_tokens, usage.completion_tokens, usage.cached_tokens },
    );
}

test "turn_finished v2 payload has schema and all token fields" {
    const payload = try turnFinishedPayload(std.testing.allocator, 3, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 100,
        .completion_tokens = 40,
        .cached_tokens = 20,
        .total_tokens = 160,
    }, 25);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":\"var1.turn_finished.v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"step\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"prompt_tokens\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"completion_tokens\":40") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cached_tokens\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"output_bytes\":25") != null);
}

test "cost_total_usd present when model priced" {
    const payload = try turnFinishedPayload(std.testing.allocator, 1, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 1_000_000,
        .completion_tokens = 500_000,
        .cached_tokens = 100_000,
    }, 0);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cost_total_usd\":0.28028") != null);
}

test "cost_total_usd null when model unpriced" {
    const payload = try turnFinishedPayload(std.testing.allocator, 1, &.{}, "custom-local-model", .{
        .prompt_tokens = 100,
    }, 0);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cost_total_usd\":null") != null);
}

test "turn_started payload unchanged v1 shape" {
    const payload = try turnStartedPayload(std.testing.allocator, 2, &.{});
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"schema\":\"var1.turn_started.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"step\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"window_tokens\"") != null);
}

test "window_tokens and output_bytes preserved in v2" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = @constCast("hello") },
    };
    const payload = try turnFinishedPayload(std.testing.allocator, 0, messages[0..], "glm-5.2", .{}, 7);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"output_bytes\":7") != null);
    // glm-5.2 is a free-tier entry: cost present as 0 (not null).
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"cost_total_usd\":0") != null);
}

test "payload parses back as JSON with expected values" {
    const payload = try turnFinishedPayload(std.testing.allocator, 5, &.{}, "deepseek-v4-flash", .{
        .prompt_tokens = 10,
        .completion_tokens = 4,
        .cached_tokens = 2,
        .total_tokens = 16,
    }, 3);
    defer std.testing.allocator.free(payload);

    const Parsed = struct {
        schema: []const u8,
        step: usize,
        prompt_tokens: u64,
        completion_tokens: u64,
        cached_tokens: u64,
        cost_total_usd: ?f64,
    };
    var parsed = try std.json.parseFromSlice(Parsed, std.testing.allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("var1.turn_finished.v2", parsed.value.schema);
    try std.testing.expectEqual(@as(usize, 5), parsed.value.step);
    try std.testing.expectEqual(@as(u64, 10), parsed.value.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 4), parsed.value.completion_tokens);
    try std.testing.expectEqual(@as(u64, 2), parsed.value.cached_tokens);
    try std.testing.expect(parsed.value.cost_total_usd != null);
}
