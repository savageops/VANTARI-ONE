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

/// A provider-prefixed model selector. The slices borrow the caller's input;
/// the provider id points at the canonical built-in id when the prefix is
/// recognized. Model ids may still contain `/`, which is why selection only
/// splits a known provider prefix.
pub const ModelReference = struct {
    provider_id: []const u8,
    model_id: []const u8,
};

/// The result of resolving one user-facing model selector. The provider id is
/// optional when the input is an unqualified model and no provider was
/// explicit; the caller can then retain its existing active-provider path.
pub const ModelSelection = struct {
    provider_id: ?[]const u8 = null,
    model_id: []const u8,
};

const known_provider_ids = [_][]const u8{
    "openai-codex",
    "openai-compatible",
    "openai",
    "anthropic",
    "openrouter",
    "zai",
    "deepseek",
    "groq",
    "mistral",
    "xai",
    "google",
    "gemini",
    "ollama",
    "lm-studio",
    "vllm",
};

/// Normalize only the finite built-in provider namespace. Custom provider ids
/// remain caller-owned and case-sensitive so a custom endpoint is never
/// silently aliased to another credential record.
pub fn canonicalProviderId(provider_id: []const u8) []const u8 {
    for (known_provider_ids) |known| {
        if (std.ascii.eqlIgnoreCase(provider_id, known)) return known;
    }
    return provider_id;
}

/// Split `provider/model-id` using the longest known provider prefix. A model
/// such as `openrouter/anthropic/claude-sonnet` therefore resolves to provider
/// `openrouter` and model `anthropic/claude-sonnet`, preserving gateway model
/// namespaces. Unknown prefixes stay unqualified and are handled by the
/// explicit `--provider`/route provider path.
pub fn splitKnownProviderModel(model_ref: []const u8) ?ModelReference {
    var best: ?ModelReference = null;
    var best_provider_len: usize = 0;

    for (known_provider_ids) |provider_id| {
        if (model_ref.len <= provider_id.len + 1) continue;
        if (model_ref[provider_id.len] != '/') continue;
        if (!std.ascii.eqlIgnoreCase(model_ref[0..provider_id.len], provider_id)) continue;
        if (provider_id.len <= best_provider_len) continue;
        const model_id = model_ref[provider_id.len + 1 ..];
        if (model_id.len == 0) continue;
        best_provider_len = provider_id.len;
        best = .{ .provider_id = provider_id, .model_id = model_id };
    }

    return best;
}

/// Strip a provider prefix only when it matches an explicitly selected
/// provider. This preserves slash-bearing model ids such as
/// `anthropic/claude-sonnet` when they are being sent through OpenRouter.
pub fn modelForProvider(model_ref: []const u8, provider_id: []const u8) []const u8 {
    if (model_ref.len <= provider_id.len + 1) return model_ref;
    if (model_ref[provider_id.len] != '/') return model_ref;
    if (!std.ascii.eqlIgnoreCase(model_ref[0..provider_id.len], provider_id)) return model_ref;
    const model_id = model_ref[provider_id.len + 1 ..];
    return if (model_id.len > 0) model_id else model_ref;
}

/// Resolve the canonical provider/model identity once for every caller. An
/// explicit provider always wins; without one, only a known provider prefix
/// selects credentials. Unknown prefixes remain part of the model id so a
/// custom provider can define its own slash-bearing namespace.
pub fn resolveModelSelection(model_ref: []const u8, explicit_provider_id: ?[]const u8) ModelSelection {
    if (explicit_provider_id) |provider_id| {
        const canonical_provider_id = canonicalProviderId(provider_id);
        return .{
            .provider_id = canonical_provider_id,
            .model_id = modelForProvider(model_ref, canonical_provider_id),
        };
    }
    if (splitKnownProviderModel(model_ref)) |reference| {
        return .{
            .provider_id = reference.provider_id,
            .model_id = reference.model_id,
        };
    }
    return .{ .model_id = model_ref };
}

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

test "provider model reference preserves nested gateway model namespaces" {
    const reference = splitKnownProviderModel("openrouter/anthropic/claude-sonnet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("openrouter", reference.provider_id);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", reference.model_id);
}

test "provider model reference canonicalizes built-in provider casing" {
    const reference = splitKnownProviderModel("AnThRoPiC/claude-sonnet") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("anthropic", reference.provider_id);
    try std.testing.expectEqualStrings("claude-sonnet", reference.model_id);
    try std.testing.expectEqualStrings("openai", canonicalProviderId("OPENAI"));
}

test "explicit provider keeps slash-bearing model ids unless its own prefix matches" {
    try std.testing.expectEqualStrings(
        "anthropic/claude-sonnet",
        modelForProvider("anthropic/claude-sonnet", "openrouter"),
    );
    try std.testing.expectEqualStrings(
        "claude-sonnet",
        modelForProvider("anthropic/claude-sonnet", "anthropic"),
    );
    try std.testing.expectEqualStrings("custom-model", modelForProvider("custom-model", "anthropic"));
}

test "model selection resolves explicit and inferred providers through one owner" {
    const explicit = resolveModelSelection("anthropic/claude-sonnet", "ANTHROPIC");
    try std.testing.expectEqualStrings("anthropic", explicit.provider_id.?);
    try std.testing.expectEqualStrings("claude-sonnet", explicit.model_id);

    const inferred = resolveModelSelection("openrouter/anthropic/claude-sonnet", null);
    try std.testing.expectEqualStrings("openrouter", inferred.provider_id.?);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", inferred.model_id);

    const custom = resolveModelSelection("tenant/model/v2", null);
    try std.testing.expect(custom.provider_id == null);
    try std.testing.expectEqualStrings("tenant/model/v2", custom.model_id);
}
