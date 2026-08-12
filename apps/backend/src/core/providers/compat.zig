const std = @import("std");
const types = @import("../../shared/types.zig");

/// Provider compat detection — the single owner of baseUrl-derived wire
/// protocol and thinking-format rules.
/// Why: VANTARI's config default (`wire_api: "auto"`) must resolve to a
/// concrete adapter, and the request body must match the endpoint's thinking
/// convention instead of applying z.ai's `enable_thinking` shape everywhere.
/// Harvested from prime-agent `detectCompat`/`getCompat`
/// (packages/ai/src/providers/openai-completions.ts:1075-1165) — provider
/// precedence over URL becomes explicit-config precedence over detection:
/// explicit `wire_api`/`thinking_mode` config always beats these rules.
/// Evidence: consumed by dispatch.resolveWireApi and the chat adapter's
/// buildRequestJson; tested here against the detection table.
pub const ThinkingFormat = enum {
    /// z.ai coding paas: top-level `enable_thinking` boolean
    /// (prime openai-completions.ts:564-565; empirically verified P0 fix f9e0dcc).
    zai,
    /// DeepSeek: nested `thinking: {type:"enabled"}` + reasoning_content echo
    /// (prime openai-completions.ts:573-577 `requiresReasoningContentOnAssistantMessages`).
    deepseek,
    /// OpenAI-compat default: no thinking field (LM Studio, Ollama, OpenAI).
    standard,
};

/// Resolve the wire protocol from a provider base URL. Only
/// api.anthropic.com requires a different adapter; every other known endpoint
/// (z.ai, deepseek, openai, LM Studio, Ollama) speaks chat_completions, and
/// the Responses API remains opt-in via explicit config for LM Studio 0.3.29+.
pub fn detectWireApi(base_url: []const u8) types.WireApi {
    if (std.mem.indexOf(u8, base_url, "api.anthropic.com") != null) return .anthropic_messages;
    return .chat_completions;
}

/// Resolve the thinking payload convention from a provider base URL.
/// z.ai's coding paas expects `enable_thinking` top-level; DeepSeek expects
/// the nested `thinking:{type}` shape; everything else gets neither.
pub fn detectThinkingFormat(base_url: []const u8) ThinkingFormat {
    if (std.mem.indexOf(u8, base_url, "api.z.ai") != null) return .zai;
    if (std.mem.indexOf(u8, base_url, "deepseek.com") != null) return .deepseek;
    return .standard;
}

test "detectWireApi anthropic base_url" {
    try std.testing.expectEqual(types.WireApi.anthropic_messages, detectWireApi("https://api.anthropic.com/v1"));
}

test "detectWireApi zai base_url stays chat_completions" {
    try std.testing.expectEqual(types.WireApi.chat_completions, detectWireApi("https://api.z.ai/api/coding/paas/v4"));
}

test "detectWireApi deepseek base_url stays chat_completions" {
    try std.testing.expectEqual(types.WireApi.chat_completions, detectWireApi("https://api.deepseek.com"));
}

test "detectWireApi lmstudio and localhost stay chat_completions" {
    try std.testing.expectEqual(types.WireApi.chat_completions, detectWireApi("http://localhost:1234/v1"));
    try std.testing.expectEqual(types.WireApi.chat_completions, detectWireApi("http://127.0.0.1:11434/v1"));
}

test "detectWireApi unknown base_url falls back to chat_completions" {
    try std.testing.expectEqual(types.WireApi.chat_completions, detectWireApi("https://custom.example.com/v1"));
}

test "detectThinkingFormat zai" {
    try std.testing.expectEqual(ThinkingFormat.zai, detectThinkingFormat("https://api.z.ai/api/coding/paas/v4"));
}

test "detectThinkingFormat deepseek" {
    try std.testing.expectEqual(ThinkingFormat.deepseek, detectThinkingFormat("https://api.deepseek.com"));
}

test "detectThinkingFormat standard for lmstudio and openai" {
    try std.testing.expectEqual(ThinkingFormat.standard, detectThinkingFormat("http://localhost:1234/v1"));
    try std.testing.expectEqual(ThinkingFormat.standard, detectThinkingFormat("https://api.openai.com/v1"));
}
