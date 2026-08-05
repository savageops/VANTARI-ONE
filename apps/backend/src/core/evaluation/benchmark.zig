const std = @import("std");
const budget = @import("../context/budget.zig");
const types = @import("../../shared/types.zig");

/// Comparison harness (roadmap P2-18). Measures VANTARI's core operations
/// with nanosecond precision and emits JSON that can be compared against
/// Eve's equivalent metrics. The harness generates synthetic workloads
/// (messages, events) of increasing size to measure scaling behavior.

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,

    pub fn renderJson(self: BenchmarkResult, writer: anytype) !void {
        try writer.print(
            "{{\"name\":\"{s}\",\"iterations\":{d},\"total_ns\":{d},\"avg_ns\":{d},\"min_ns\":{d},\"max_ns\":{d}}}",
            .{ self.name, self.iterations, self.total_ns, self.avg_ns, self.min_ns, self.max_ns },
        );
    }
};

/// Run a single benchmark: call `func` `iterations` times and measure.
fn bench(
    name: []const u8,
    iterations: usize,
    ctx: anytype,
    func: fn (@TypeOf(ctx)) void,
) BenchmarkResult {
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        func(ctx);
        const elapsed: u64 = @intCast(std.time.nanoTimestamp() - start);
        total_ns += elapsed;
        if (elapsed < min_ns) min_ns = elapsed;
        if (elapsed > max_ns) max_ns = elapsed;
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = if (iterations > 0) total_ns / iterations else 0,
        .min_ns = if (min_ns == std.math.maxInt(u64)) 0 else min_ns,
        .max_ns = max_ns,
    };
}

/// Generate synthetic ChatMessages for benchmarking.
fn makeMessages(allocator: std.mem.Allocator, count: usize) ![]types.ChatMessage {
    const messages = try allocator.alloc(types.ChatMessage, count);
    for (messages, 0..) |*msg, i| {
        msg.* = .{
            .role = if (i % 2 == 0) .user else .assistant,
            .content = try std.fmt.allocPrint(allocator, "message body number {d} with enough text to be meaningful for token estimation", .{i}),
        };
    }
    return messages;
}

fn freeMessages(allocator: std.mem.Allocator, messages: []types.ChatMessage) void {
    for (messages) |msg| {
        if (msg.content) |c| allocator.free(c);
    }
    allocator.free(messages);
}

fn tokenEstimateFn(messages: []const types.ChatMessage) void {
    _ = budget.estimateChatMessages(messages);
}

const TokenEstimateContext = struct {
    messages: []const types.ChatMessage,
};

fn tokenEstimateWrapper(ctx: TokenEstimateContext) void {
    tokenEstimateFn(ctx.messages);
}

/// Run the full benchmark suite and emit JSON.
pub fn runBenchmarks(allocator: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll("{\"benchmarks\":[");

    // Token estimation benchmarks at different scales.
    const scales = [_]struct { count: usize, label: []const u8 }{
        .{ .count = 10, .label = "token_estimate_10_msgs" },
        .{ .count = 50, .label = "token_estimate_50_msgs" },
        .{ .count = 100, .label = "token_estimate_100_msgs" },
    };

    var first = true;
    for (scales) |scale| {
        const messages = try makeMessages(allocator, scale.count);
        defer freeMessages(allocator, messages);

        const ctx = TokenEstimateContext{ .messages = messages };
        const result = bench(scale.label, 1000, ctx, tokenEstimateWrapper);

        if (!first) try writer.writeAll(",");
        first = false;
        try result.renderJson(writer);
    }

    // Single-message token estimation (per-turn hot path).
    const single_msg = try makeMessages(allocator, 1);
    defer freeMessages(allocator, single_msg);
    const single_ctx = TokenEstimateContext{ .messages = single_msg };
    const single_result = bench("token_estimate_single", 10000, single_ctx, tokenEstimateWrapper);
    if (!first) try writer.writeAll(",");
    try single_result.renderJson(writer);

    // Window budget computation (context compilation cost).
    const budget_messages = try makeMessages(allocator, 50);
    defer freeMessages(allocator, budget_messages);
    const full_tokens = budget.estimateChatMessages(budget_messages);
    const summary = "Summary of conversation: implemented event seq, BOM stripping, durability, Job Objects.";
    const wb_result = bench("window_budget_50_msgs", 1000, .{}, struct {
        fn run(_: void) void {
            _ = budget.windowBudget(summary, budget_messages[0..5], full_tokens);
        }
    }.run);
    if (!first) try writer.writeAll(",");
    try wb_result.renderJson(writer);

    try writer.writeAll("],\"unit\":\"nanoseconds\",\"note\":\"Compare against Eve equivalent: token_estimate uses char/4 heuristic in Eve; window_budget has no Eve equivalent (Eve has no shard model).\"}");
}

test "BenchmarkResult renders JSON" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();
    const result = BenchmarkResult{
        .name = "test",
        .iterations = 100,
        .total_ns = 1_000_000,
        .avg_ns = 10_000,
        .min_ns = 5_000,
        .max_ns = 20_000,
    };
    try result.renderJson(buffer.writer());
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"name\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"avg_ns\":10000") != null);
}

test "runBenchmarks produces valid JSON with all benchmarks" {
    var buffer = std.array_list.Managed(u8).init(std.testing.allocator);
    defer buffer.deinit();
    try runBenchmarks(std.testing.allocator, buffer.writer());

    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"benchmarks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "token_estimate_10_msgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "token_estimate_100_msgs") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "window_budget") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "\"unit\":\"nanoseconds\"") != null);
}
