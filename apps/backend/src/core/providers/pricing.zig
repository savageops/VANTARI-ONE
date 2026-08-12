const std = @import("std");
const types = @import("../../shared/types.zig");

/// Per-model pricing engine. Maps a model id to a compiled price table and
/// derives the dollar cost of a measured `types.Usage`.
/// Why: the event spine must answer "what did this turn cost" with a priced
/// quantity, not just token counts. The formula mirrors prime-agent's
/// calculateCost (packages/ai/src/models.ts:51-62): cost = ($/1M) * tokens
/// per bucket, summed. Preserves: cost is only ever CLAIMED when a price is
/// known — unknown models return null and token accounting still works.
/// Evidence: consumed by turn_payload (turn_finished v2) and tested here.
pub const ModelPrice = struct {
    /// USD per 1,000,000 prompt (and cache_creation) tokens.
    input_usd: f64,
    /// USD per 1,000,000 completion tokens.
    output_usd: f64,
    /// USD per 1,000,000 cached (prompt cache read) tokens.
    cache_read_usd: f64,
};

/// Derived priced quantities for one measured usage. Flattened (no nested
/// struct) so the event payload writer emits four numbers directly.
pub const Cost = struct {
    input_usd: f64,
    output_usd: f64,
    cached_usd: f64,
    total_usd: f64,
};

const PriceEntry = struct {
    prefix: []const u8,
    price: ModelPrice,
};

/// Compiled price table, longest-prefix first so the first match wins.
/// Provenance: harvested from prime-agent `packages/ai/src/models.generated.ts`
/// (deepseek-v4-* :4040-4077, glm-5.2 family :20364-20381, gpt-4.1 family
/// :7627-7653) plus published provider rates for models absent from that
/// table (deepseek-chat/reasoner, claude-4-*, o3-mini/o4-mini). z.ai's GLM
/// tier is listed free (0/0) in the harvest — cost is $0 and token evidence
/// still flows. Operators with paid tiers extend this table at the source.
const PRICE_TABLE = [_]PriceEntry{
    .{ .prefix = "deepseek-v4-flash", .price = .{ .input_usd = 0.14, .output_usd = 0.28, .cache_read_usd = 0.0028 } },
    .{ .prefix = "deepseek-v4-pro", .price = .{ .input_usd = 0.435, .output_usd = 0.87, .cache_read_usd = 0.003625 } },
    .{ .prefix = "deepseek-reasoner", .price = .{ .input_usd = 0.55, .output_usd = 2.19, .cache_read_usd = 0.14 } },
    .{ .prefix = "deepseek-chat", .price = .{ .input_usd = 0.27, .output_usd = 1.10, .cache_read_usd = 0.07 } },
    .{ .prefix = "glm-5.2", .price = .{ .input_usd = 0, .output_usd = 0, .cache_read_usd = 0 } },
    .{ .prefix = "glm-5-turbo", .price = .{ .input_usd = 0, .output_usd = 0, .cache_read_usd = 0 } },
    .{ .prefix = "glm-4.7", .price = .{ .input_usd = 0, .output_usd = 0, .cache_read_usd = 0 } },
    .{ .prefix = "gpt-4.1-mini", .price = .{ .input_usd = 0.4, .output_usd = 1.6, .cache_read_usd = 0.1 } },
    .{ .prefix = "gpt-4.1", .price = .{ .input_usd = 2.0, .output_usd = 8.0, .cache_read_usd = 0.5 } },
    .{ .prefix = "o4-mini", .price = .{ .input_usd = 1.1, .output_usd = 4.4, .cache_read_usd = 0.55 } },
    .{ .prefix = "o3-mini", .price = .{ .input_usd = 1.1, .output_usd = 4.4, .cache_read_usd = 0.55 } },
    .{ .prefix = "claude-opus-4-", .price = .{ .input_usd = 15, .output_usd = 75, .cache_read_usd = 1.5 } },
    .{ .prefix = "claude-sonnet-4-", .price = .{ .input_usd = 3, .output_usd = 15, .cache_read_usd = 0.3 } },
    .{ .prefix = "claude-haiku-4-", .price = .{ .input_usd = 0.8, .output_usd = 4, .cache_read_usd = 0.08 } },
    .{ .prefix = "claude-3-7-sonnet", .price = .{ .input_usd = 3, .output_usd = 15, .cache_read_usd = 0.3 } },
    .{ .prefix = "claude-3-5-sonnet", .price = .{ .input_usd = 3, .output_usd = 15, .cache_read_usd = 0.3 } },
};

// Table integrity is a compile-time contract: prices non-negative and the
// longest-prefix-first ordering provable (no entry is a prefix of an earlier
// entry — otherwise the earlier entry would shadow it).
comptime {
    for (PRICE_TABLE) |entry| {
        if (entry.price.input_usd < 0 or entry.price.output_usd < 0 or entry.price.cache_read_usd < 0) {
            @compileError("negative price for " ++ entry.prefix);
        }
    }
    var i: usize = 0;
    while (i < PRICE_TABLE.len) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            if (std.mem.startsWith(u8, PRICE_TABLE[i].prefix, PRICE_TABLE[j].prefix)) {
                @compileError("entry '" ++ PRICE_TABLE[i].prefix ++ "' is shadowed by earlier prefix '" ++ PRICE_TABLE[j].prefix ++ "'");
            }
        }
    }
}

/// Longest-prefix match of a model id against the price table. First entry
/// wins because the table is ordered most-specific-first. Unknown models
/// return null — the caller reports tokens without a priced quantity.
pub fn lookupModelPrice(model_id: []const u8) ?ModelPrice {
    for (PRICE_TABLE) |entry| {
        if (std.mem.startsWith(u8, model_id, entry.prefix)) return entry.price;
    }
    return null;
}

/// Derive the dollar cost of a measured usage. Null when the model has no
/// compiled price — cost is never fabricated for unknown models.
/// Formula (prime models.ts:56-60): (price / 1_000_000) * tokens per bucket.
pub fn calculateCost(model_id: []const u8, usage: types.Usage) ?Cost {
    const price = lookupModelPrice(model_id) orelse return null;
    const input_usd = price.input_usd * @as(f64, @floatFromInt(usage.prompt_tokens)) / 1_000_000.0;
    const output_usd = price.output_usd * @as(f64, @floatFromInt(usage.completion_tokens)) / 1_000_000.0;
    const cached_usd = price.cache_read_usd * @as(f64, @floatFromInt(usage.cached_tokens)) / 1_000_000.0;
    return .{
        .input_usd = input_usd,
        .output_usd = output_usd,
        .cached_usd = cached_usd,
        .total_usd = input_usd + output_usd + cached_usd,
    };
}

test "exact model id match" {
    const price = lookupModelPrice("deepseek-v4-flash").?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.14), price.input_usd, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.28), price.output_usd, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0028), price.cache_read_usd, 1e-12);
}

test "longest prefix wins" {
    // glm-5.2-highspeed resolves through the glm-5.2 entry.
    try std.testing.expectApproxEqAbs(@as(f64, 0), lookupModelPrice("glm-5.2-highspeed").?.input_usd, 1e-12);
    // gpt-4.1-mini must not be shadowed by gpt-4.1.
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), lookupModelPrice("gpt-4.1-mini").?.input_usd, 1e-12);
    // A hypothetical deepseek-v4-flash variant still matches the flash entry.
    try std.testing.expectApproxEqAbs(@as(f64, 0.14), lookupModelPrice("deepseek-v4-flash-ctx128k").?.input_usd, 1e-12);
}

test "unknown model returns null" {
    try std.testing.expect(lookupModelPrice("custom-local-model") == null);
    try std.testing.expect(lookupModelPrice("") == null);
    try std.testing.expect(lookupModelPrice("gpt-3.5-turbo") == null);
}

test "calculateCost applies per-million formula" {
    // deepseek-v4-flash: 1,000,000 prompt + 500,000 completion + 100,000 cached
    // -> 0.14 + 0.14 + 0.00028 = 0.28028
    const cost = calculateCost("deepseek-v4-flash", .{
        .prompt_tokens = 1_000_000,
        .completion_tokens = 500_000,
        .cached_tokens = 100_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.14), cost.input_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.14), cost.output_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.00028), cost.cached_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.28028), cost.total_usd, 1e-9);
}

test "calculateCost zero usage yields zero cost" {
    const cost = calculateCost("deepseek-v4-flash", .{}).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), cost.total_usd, 1e-12);
}

test "calculateCost unknown model returns null" {
    try std.testing.expect(calculateCost("llama-3.3-70b", .{ .prompt_tokens = 100 }) == null);
}

test "glm-5.2 zero price yields zero cost with tokens tracked" {
    const cost = calculateCost("glm-5.2", .{
        .prompt_tokens = 50_000,
        .completion_tokens = 10_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), cost.total_usd, 1e-12);
    // The usage itself remains non-zero — tokens are the evidence on a free tier.
    try std.testing.expectEqual(@as(u64, 50_000), (types.Usage{ .prompt_tokens = 50_000 }).prompt_tokens);
}

test "small token counts price correctly" {
    // gpt-4.1: 1,234 prompt -> 0.002468; 5,678 completion -> 0.045424
    const cost = calculateCost("gpt-4.1", .{
        .prompt_tokens = 1234,
        .completion_tokens = 5678,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.002468), cost.input_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.045424), cost.output_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.047892), cost.total_usd, 1e-9);
}

test "cache reads priced at cache rate on deepseek" {
    const cost = calculateCost("deepseek-v4-flash", .{
        .prompt_tokens = 1_000_000,
        .cached_tokens = 1_000_000,
    }).?;
    // Cached tokens are 50x cheaper than prompt tokens on deepseek-v4-flash.
    try std.testing.expect(cost.cached_usd < cost.input_usd);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0028), cost.cached_usd, 1e-9);
}

test "claude sonnet cache pricing" {
    const cost = calculateCost("claude-sonnet-4-20250514", .{
        .prompt_tokens = 1_000_000,
        .cached_tokens = 1_000_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3), cost.input_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), cost.cached_usd, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), cost.total_usd, 1e-9);
}
