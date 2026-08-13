const std = @import("std");
const types = @import("../../shared/types.zig");

/// Promoted provider profile owner, harvested under codename Prism from Codex,
/// pi-mono, and oh-my-pi.
///
/// Purpose: keep provider identity, wire selection, and secret-header choice
/// in one small pure owner. Why: provider-prefixed selection is only safe when
/// a concrete provider/model pair resolves to one transport contract.
/// Preserves: one existing dispatch owner, explicit unsupported boundaries, and
/// secret-free route receipts. Evidence: `.refs/openai__codex/codex-rs/app-server/README.md`,
/// `.refs/badlogic__pi-mono/packages/coding-agent/docs/providers.md`, and
/// `.refs/can1357__oh-my-pi/docs/models.md`.

/// The provider defaults needed before an auth record supplies an explicit
/// wire or header scheme. The Anthropic version is a protocol constant, not a
/// user secret, and is emitted by the Anthropic adapter.
pub const Defaults = struct {
    wire_api: types.WireApi,
    auth_scheme: types.AuthScheme,
    anthropic_version: ?[]const u8 = null,
};

/// Resolve the finite provider profile from stable id and endpoint evidence.
/// Explicit persisted wire/auth values are applied by the caller; this helper
/// only supplies safe defaults for legacy records and new provider login.
pub fn defaults(provider_id: []const u8, base_url: []const u8) Defaults {
    if (std.mem.eql(u8, provider_id, "openai-codex")) {
        return .{ .wire_api = .responses, .auth_scheme = .bearer };
    }
    if (isAnthropic(provider_id, base_url)) {
        return .{
            .wire_api = .anthropic_messages,
            .auth_scheme = .api_key,
            .anthropic_version = "2023-06-01",
        };
    }
    return .{ .wire_api = .chat_completions, .auth_scheme = .bearer };
}

/// Resolve the configured wire API, preserving an explicit operator choice
/// and otherwise applying the provider profile to the legacy `auto` value.
pub fn effectiveWireApi(provider_id: []const u8, base_url: []const u8, configured: types.WireApi) types.WireApi {
    if (configured != .auto) return configured;
    return defaults(provider_id, base_url).wire_api;
}

/// Resolve the configured authentication scheme, preserving an explicit
/// provider-record value and using the profile only for legacy records.
pub fn effectiveAuthScheme(provider_id: []const u8, base_url: []const u8, configured: ?types.AuthScheme) types.AuthScheme {
    return configured orelse defaults(provider_id, base_url).auth_scheme;
}

/// Return true for the official Anthropic host or an explicitly named
/// Anthropic provider; OpenAI-compatible proxies remain opt-in by wire value.
pub fn isAnthropic(provider_id: []const u8, base_url: []const u8) bool {
    return std.ascii.eqlIgnoreCase(provider_id, "anthropic") or
        std.mem.indexOf(u8, base_url, "api.anthropic.com") != null;
}

/// Return the official API-key environment variable for built-in providers.
/// Custom providers intentionally return null; their key must enter the
/// credential ledger through `auth login` input rather than a guessed secret.
pub fn apiKeyEnvironment(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai") or std.mem.eql(u8, provider_id, "openai-compatible")) return "OPENAI_API_KEY";
    if (std.mem.eql(u8, provider_id, "anthropic")) return "ANTHROPIC_API_KEY";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "OPENROUTER_API_KEY";
    return null;
}

/// Return a built-in provider base URL. Custom providers must provide one
/// explicitly so endpoint ownership is never inferred from a secret name.
pub fn defaultBaseUrl(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider_id, "anthropic")) return "https://api.anthropic.com";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1";
    return null;
}

test "provider profile recognizes official Anthropic header and wire defaults" {
    const profile = defaults("anthropic", "https://api.anthropic.com");
    try std.testing.expectEqual(types.WireApi.anthropic_messages, profile.wire_api);
    try std.testing.expectEqual(types.AuthScheme.api_key, profile.auth_scheme);
    try std.testing.expectEqualStrings("2023-06-01", profile.anthropic_version.?);
}

test "provider profile preserves Codex Responses transport identity" {
    const profile = defaults("openai-codex", "https://chatgpt.com/backend-api");
    try std.testing.expectEqual(types.WireApi.responses, profile.wire_api);
    try std.testing.expectEqual(types.AuthScheme.bearer, profile.auth_scheme);
}

test "provider profile keeps explicit custom wire selection" {
    try std.testing.expectEqual(
        types.WireApi.responses,
        effectiveWireApi("custom", "http://127.0.0.1:9000/v1", .responses),
    );
    try std.testing.expectEqual(
        types.WireApi.chat_completions,
        effectiveWireApi("custom", "http://127.0.0.1:9000/v1", .auto),
    );
}

test "provider profile exposes only named built-in key environment variables" {
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", apiKeyEnvironment("anthropic").?);
    try std.testing.expectEqualStrings("OPENROUTER_API_KEY", apiKeyEnvironment("openrouter").?);
    try std.testing.expect(apiKeyEnvironment("my-private-gateway") == null);
}

test "provider profile supplies built-in endpoint defaults without inventing custom endpoints" {
    try std.testing.expectEqualStrings("https://api.openai.com/v1", defaultBaseUrl("openai").?);
    try std.testing.expectEqualStrings("https://api.anthropic.com", defaultBaseUrl("anthropic").?);
    try std.testing.expect(defaultBaseUrl("private-gateway") == null);
}
