const std = @import("std");
const types = @import("../../shared/types.zig");

/// Provider capability probe snapshot (roadmap Move 61). Dispatch materializes
/// this fixed contract from the selected adapter instead of guessing from a
/// model name or issuing a network preflight on every turn. Unknown protocol
/// selection fails before provider I/O.
pub const Error = error{
    UnknownWireApi,
    UnsupportedCapability,
};

pub const Capability = enum {
    /// Provider supports SSE streaming deltas.
    streaming,
    /// Provider supports tool/function calling.
    tool_calling,
    /// Provider supports the responses API shape (vs chat completions).
    responses_api,
    /// Provider returns context overflow error signatures.
    context_overflow_detection,
};

pub const ProbeStatus = enum {
    /// Capability verified as supported.
    supported,
    /// Capability verified as NOT supported.
    unsupported,
    /// Capability not yet probed — fail closed.
    unknown,

    pub fn isSupported(self: ProbeStatus) bool {
        return self == .supported;
    }
};

/// A cached provider capability profile. One per provider endpoint, keyed
/// by base_url + model. Fixed-size — no per-turn allocation.
pub const CapabilityCache = struct {
    streaming: ProbeStatus = .unknown,
    tool_calling: ProbeStatus = .unknown,
    responses_api: ProbeStatus = .unknown,
    context_overflow_detection: ProbeStatus = .unknown,
    /// Maximum context window in tokens, if probed.
    max_context_tokens: ?u64 = null,
    /// Maximum output tokens per response, if probed.
    max_output_tokens: ?u64 = null,

    /// Check a capability. Returns the cached status or .unknown.
    /// Unknown fails closed — the caller must not assume support.
    pub fn check(self: CapabilityCache, cap: Capability) ProbeStatus {
        return switch (cap) {
            .streaming => self.streaming,
            .tool_calling => self.tool_calling,
            .responses_api => self.responses_api,
            .context_overflow_detection => self.context_overflow_detection,
        };
    }

    /// Record a probed capability result.
    pub fn record(self: *CapabilityCache, cap: Capability, status: ProbeStatus) void {
        switch (cap) {
            .streaming => self.streaming = status,
            .tool_calling => self.tool_calling = status,
            .responses_api => self.responses_api = status,
            .context_overflow_detection => self.context_overflow_detection = status,
        }
    }

    /// Returns true if the capability is explicitly supported (not unknown).
    pub fn isCapable(self: CapabilityCache, cap: Capability) bool {
        return self.check(cap).isSupported();
    }

    /// Fail-closed check: returns true ONLY if the capability is verified
    /// as supported. Unknown and unsupported both return false.
    pub fn requireCapability(self: CapabilityCache, cap: Capability) bool {
        return self.check(cap) == .supported;
    }
};

/// Probe the capabilities owned by one concrete wire adapter. This is the
/// smallest durable boundary: the adapters all implement streaming, native
/// tool serialization, and bounded overflow classification; Responses is only
/// supported by the Responses-shaped adapters. Dynamic remote model metadata
/// remains a separate provider-catalog concern.
pub fn probe(wire_api: types.WireApi) !CapabilityCache {
    if (wire_api == .auto) return Error.UnknownWireApi;

    var cache = CapabilityCache{};
    cache.record(.streaming, .supported);
    cache.record(.tool_calling, .supported);
    cache.record(.context_overflow_detection, .supported);
    cache.record(.responses_api, if (wire_api == .responses) .supported else .unsupported);
    return cache;
}

test "CapabilityCache defaults to unknown (fail-closed)" {
    const cache = CapabilityCache{};
    try std.testing.expectEqual(ProbeStatus.unknown, cache.check(.streaming));
    try std.testing.expect(!cache.isCapable(.streaming));
    try std.testing.expect(!cache.requireCapability(.streaming));
}

test "CapabilityCache records and checks probed capabilities" {
    var cache = CapabilityCache{};
    cache.record(.streaming, .supported);
    cache.record(.tool_calling, .unsupported);

    try std.testing.expectEqual(ProbeStatus.supported, cache.check(.streaming));
    try std.testing.expectEqual(ProbeStatus.unsupported, cache.check(.tool_calling));
    try std.testing.expectEqual(ProbeStatus.unknown, cache.check(.responses_api));

    try std.testing.expect(cache.isCapable(.streaming));
    try std.testing.expect(!cache.isCapable(.tool_calling));
    try std.testing.expect(!cache.isCapable(.responses_api));
}

test "CapabilityCache requireCapability fails closed for unknown" {
    const cache = CapabilityCache{};
    // Unknown must fail closed — no assuming support.
    try std.testing.expect(!cache.requireCapability(.streaming));
    try std.testing.expect(!cache.requireCapability(.tool_calling));
}

test "CapabilityCache records max token limits" {
    var cache = CapabilityCache{};
    cache.max_context_tokens = 128_000;
    cache.max_output_tokens = 4_096;

    try std.testing.expectEqual(@as(?u64, 128_000), cache.max_context_tokens);
    try std.testing.expectEqual(@as(?u64, 4_096), cache.max_output_tokens);
}

test "provider probe materializes known adapter capabilities" {
    const chat = try probe(.chat_completions);
    try std.testing.expect(chat.requireCapability(.streaming));
    try std.testing.expect(chat.requireCapability(.tool_calling));
    try std.testing.expect(chat.requireCapability(.context_overflow_detection));
    try std.testing.expectEqual(ProbeStatus.unsupported, chat.check(.responses_api));

    const responses = try probe(.responses);
    try std.testing.expect(responses.requireCapability(.responses_api));
}

test "provider probe rejects unresolved wire protocol" {
    try std.testing.expectError(Error.UnknownWireApi, probe(.auto));
}
