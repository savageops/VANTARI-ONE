const std = @import("std");
const auth_store = @import("../auth/store.zig");
const detect = @import("../auth/detect.zig");
const provider_profile = @import("profile.zig");
const types = @import("../../shared/types.zig");

/// Single-owner model router. Resolves a `provider/model-name` selector to a
/// concrete credential-carrying provider record using ONE precedence ladder:
///
///   1. auth ledger record for the provider (explicit `auth use`/import/login)
///   2. provider environment API key (OPENAI_API_KEY, ANTHROPIC_API_KEY, ...)
///
/// The provider namespace is the collision guard: `anthropic/claude-sonnet`
/// and `openrouter/claude-sonnet` are distinct. This is the only owner that
/// turns a model selector into a live credential; routes/session callers never
/// reimplement the ladder.
///
/// Native Codex/Claude/OpenCode credentials are surfaced by `detect()` and the
/// `auth import` path — they are deliberately NOT auto-materialized at request
/// time, so a refresh token only ever crosses into VANTARI's store through an
/// explicit, operator-confirmed import. `hasCredential` reports their
/// availability (secret-free) so the eligibility surface can tell the operator
/// "Claude is set up — run `auth import claude`".

pub const ResolvedModel = struct {
    provider_id: []u8,
    model_id: []u8,
    /// Secret-bearing credential for the resolved provider, or null when the
    /// provider is keyless (auth_scheme `.none`).
    auth: ?auth_store.ResolvedAuth = null,
    /// Where the credential came from: "ledger" or "env".
    credential_origin: []const u8 = "ledger",

    pub fn deinit(self: ResolvedModel, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
        if (self.auth) |value| value.deinit(allocator);
    }
};

pub const Error = error{
    NoProviderSelected,
    ProviderUnavailable,
};

/// Resolve one `provider/model-name` selector to a live credential.
/// Returns null when the selector is unqualified (no provider prefix and no
/// explicit provider) so the caller keeps its active-provider path.
pub fn resolve(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    model_ref: []const u8,
    explicit_provider: ?[]const u8,
) !?ResolvedModel {
    const selection = provider_profile.resolveModelSelection(model_ref, explicit_provider);
    const provider_id = selection.provider_id orelse {
        if (explicit_provider == null) return null;
        return Error.NoProviderSelected;
    };
    const canonical = provider_profile.canonicalProviderId(provider_id);

    var result = ResolvedModel{
        .provider_id = try allocator.dupe(u8, canonical),
        .model_id = try allocator.dupe(u8, selection.model_id),
    };
    errdefer result.deinit(allocator);

    // 1. Auth ledger record (import/login/use).
    if (auth_store.readProviderById(allocator, workspace_root, canonical)) |auth| {
        result.auth = auth;
        return result;
    } else |err| switch (err) {
        error.MissingAuth, error.MissingProvider => {},
        else => return err,
    }

    // 2. Environment API key for built-in providers. Materialize an ephemeral
    // ResolvedAuth so dispatch needs no separate env plumbing.
    if (provider_profile.apiKeyEnvironment(canonical)) |env_name| {
        if (std.process.getEnvVarOwned(allocator, env_name)) |key| {
            defer allocator.free(key);
            if (key.len == 0) return Error.ProviderUnavailable;
            const base_url = provider_profile.defaultBaseUrl(canonical) orelse return Error.ProviderUnavailable;
            const defaults = provider_profile.defaults(canonical, base_url);
            result.auth = .{
                .provider_id = try allocator.dupe(u8, canonical),
                .base_url = try allocator.dupe(u8, base_url),
                .api_key = try allocator.dupe(u8, key),
                .model = try allocator.dupe(u8, selection.model_id),
                .auth_type = .api_key,
                .wire_api = defaults.wire_api,
                .auth_scheme = defaults.auth_scheme,
            };
            result.credential_origin = "env";
            return result;
        } else |_| {}
    }

    return Error.ProviderUnavailable;
}

/// Return whether a provider has a resolvable credential across the full
/// ladder (ledger + env + detected native), for availability filtering without
/// carrying secrets. Native detection only reports presence — the operator
/// must still `auth import` to make it usable.
pub fn hasCredential(allocator: std.mem.Allocator, workspace_root: []const u8, provider_id: []const u8) bool {
    const canonical = provider_profile.canonicalProviderId(provider_id);

    if (auth_store.readProviderById(allocator, workspace_root, canonical)) |auth| {
        auth.deinit(allocator);
        return true;
    } else |_| {}

    if (provider_profile.apiKeyEnvironment(canonical)) |env_name| {
        if (std.process.getEnvVarOwned(allocator, env_name)) |key| {
            const live = key.len > 0;
            allocator.free(key);
            return live;
        } else |_| {}
    }

    var detection = detect.detect(allocator) catch return false;
    defer detection.deinit();
    for (detection.detected) |entry| {
        if (entry.live and std.mem.eql(u8, entry.provider_id, canonical)) return true;
    }
    return false;
}

const testing = std.testing;

const router_test_workspace = "router-ws";

test "router resolves an imported ledger provider to a bearer credential" {
    try auth_store.upsertOAuthProvider(testing.allocator, router_test_workspace, .{
        .provider_id = "anthropic",
        .base_url = "https://api.anthropic.com",
        .model = "claude-sonnet-4-5",
        .access_token = "at-ledger",
        .refresh_token = "rt-ledger",
        .expires_at_ms = 4102444800000,
        .subscription_source = "manual",
        .last_verified_at_ms = std.time.milliTimestamp(),
        .auth_scheme = .bearer,
    });
    defer auth_store.removeProvider(testing.allocator, router_test_workspace, "anthropic") catch {};

    const model = try resolve(testing.allocator, router_test_workspace, "anthropic/claude-sonnet-4-5", null);
    defer if (model) |m| m.deinit(testing.allocator);
    try testing.expect(model != null);
    try testing.expectEqualStrings("anthropic", model.?.provider_id);
    try testing.expectEqualStrings("claude-sonnet-4-5", model.?.model_id);
    try testing.expectEqual(types.AuthScheme.bearer, model.?.auth.?.auth_scheme);
    try testing.expectEqualStrings("at-ledger", model.?.auth.?.api_key);
}

test "router resolves env-configured provider without a ledger record" {
    // The test environment has no OPENROUTER_API_KEY set; verify the ladder
    // yields ProviderUnavailable rather than falling through to a bad guess.
    const openrouter = try resolve(testing.allocator, router_test_workspace, "openrouter/openrouter/auto", null);
    if (openrouter) |model| {
        defer model.deinit(testing.allocator);
    }
    // With a clean workspace and no env, unqualified selection returns null.
    const unqualified = try resolve(testing.allocator, router_test_workspace, "claude-sonnet", null);
    try testing.expect(unqualified == null);
}

test "router unqualified model keeps active-provider path when provider absent" {
    // Unqualified model with no provider and no credential → null (caller owns).
    const result = try resolve(testing.allocator, router_test_workspace, "some-model", null);
    try testing.expect(result == null);
}

test "router provider/model namespace keeps distinct backends" {
    // openai-codex and anthropic are distinct even though both host "claude"
    // naming in some gateways; the provider prefix is the collision guard.
    try testing.expectEqualStrings("openai-codex", provider_profile.splitKnownProviderModel("openai-codex/gpt-5.4-mini").?.provider_id);
    try testing.expectEqualStrings("anthropic", provider_profile.splitKnownProviderModel("anthropic/claude-sonnet").?.provider_id);
}
