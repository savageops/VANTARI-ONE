const std = @import("std");
const VAR1 = @import("VAR1");

const auth_store = VAR1.core.auth_store;

test "auth resolution falls back to installed auth when workspace auth is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("workspace");
    try writeAuthFile(tmp.dir, "installed/Vantari/auth/auth.json", "zai", "https://api.z.ai/api/coding/paas/v4", "global-key", "glm-5.1");

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    const installed_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/installed/Vantari/auth/auth.json", .{tmp.sub_path});
    defer std.testing.allocator.free(installed_path);

    const resolved = try auth_store.resolveOrSeedWithInstalledAuthPath(std.testing.allocator, workspace_root, null, installed_path);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("zai", resolved.provider_id);
    try std.testing.expectEqualStrings("global-key", resolved.api_key);
    try std.testing.expectEqualStrings("glm-5.1", resolved.model);
    const canonical_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace/.var/auth.json", .{tmp.sub_path});
    defer std.testing.allocator.free(canonical_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(canonical_path));
    try std.testing.expect(!VAR1.shared.fsutil.fileExists(installed_path));
}

test "auth resolution keeps explicit workspace auth ahead of installed auth" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeAuthFile(tmp.dir, "installed/Vantari/auth/auth.json", "zai", "https://api.z.ai/api/coding/paas/v4", "global-key", "glm-5.1");
    try writeAuthFile(tmp.dir, "workspace/.var/auth.json", "local", "https://local.example/v1", "local-key", "local-model");

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    const installed_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/installed/Vantari/auth/auth.json", .{tmp.sub_path});
    defer std.testing.allocator.free(installed_path);

    const resolved = try auth_store.resolveOrSeedWithInstalledAuthPath(std.testing.allocator, workspace_root, null, installed_path);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("local", resolved.provider_id);
    try std.testing.expectEqualStrings("local-key", resolved.api_key);
    try std.testing.expectEqualStrings("local-model", resolved.model);
}

test "oauth ledger persists refreshed credentials, redacts status, and preserves logout parity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var seeded = try auth_store.resolveOrSeed(std.testing.allocator, workspace_root, .{
        .provider_id = "local-api",
        .base_url = "https://local.example/v1",
        .api_key = "fake-api-key",
        .model = "local-model",
        .subscription_plan_label = "local",
        .subscription_status = "active",
        .subscription_source = "test",
    });
    defer seeded.deinit(std.testing.allocator);

    try auth_store.upsertOAuthProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .model = "gpt-5.4-mini",
        .access_token = "fake-access-token",
        .refresh_token = "fake-refresh-token",
        .id_token = "fake-id-token",
        .expires_at_ms = 1000,
        .account_id = "acct-fake",
        .user_id = "user-fake",
        .email = "fake@example.invalid",
        .plan_type = "pro",
        .subscription_plan_label = "ChatGPT Pro",
        .subscription_status = "active",
        .subscription_source = "openai-codex-oauth",
        .last_verified_at_ms = 900,
    });

    var resolved = try auth_store.readProviderById(std.testing.allocator, workspace_root, "openai-codex");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.AuthType.oauth, resolved.auth_type);
    try std.testing.expectEqualStrings("fake-access-token", resolved.api_key);
    try std.testing.expectEqualStrings("fake-refresh-token", resolved.refresh_token.?);
    try std.testing.expectEqualStrings("acct-fake", resolved.account_id.?);

    var status = try auth_store.readAuthStatus(std.testing.allocator, workspace_root);
    defer status.deinit(std.testing.allocator);
    const rendered = try VAR1.clients.cli_auth.renderAuthStatus(std.testing.allocator, status, true);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "openai-codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ChatGPT Pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fake@example.invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fake-access-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fake-refresh-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fake-id-token") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "fake-api-key") == null);

    try auth_store.upsertOAuthProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "openai-codex",
        .base_url = "https://chatgpt.com/backend-api",
        .model = "gpt-5.4-mini",
        .access_token = "fake-refreshed-access",
        .refresh_token = "fake-refreshed-token",
        .id_token = "fake-refreshed-id-token",
        .expires_at_ms = 20_000,
        .account_id = "acct-fake",
        .user_id = "user-fake",
        .email = "fake@example.invalid",
        .plan_type = "pro",
        .subscription_plan_label = "ChatGPT Pro",
        .subscription_status = "active",
        .subscription_source = "openai-codex-oauth",
        .last_verified_at_ms = 19_000,
    });

    var refreshed = try auth_store.readProviderById(std.testing.allocator, workspace_root, "openai-codex");
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fake-refreshed-access", refreshed.api_key);
    try std.testing.expectEqualStrings("fake-refreshed-token", refreshed.refresh_token.?);
    try std.testing.expectEqual(@as(i64, 20_000), refreshed.expires_at_ms.?);

    try auth_store.removeProvider(std.testing.allocator, workspace_root, "openai-codex");
    var remaining = try auth_store.resolveOrSeed(std.testing.allocator, workspace_root, null);
    defer remaining.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("local-api", remaining.provider_id);
    try std.testing.expectEqualStrings("fake-api-key", remaining.api_key);

    try auth_store.removeProvider(std.testing.allocator, workspace_root, "local-api");
    try std.testing.expectError(
        auth_store.Error.MissingAuth,
        auth_store.readProviderById(std.testing.allocator, workspace_root, "local-api"),
    );
}

test "provider-scoped API-key login preserves records and cycles through secret-free inventory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var seeded = try auth_store.resolveOrSeed(std.testing.allocator, workspace_root, .{
        .provider_id = "openai",
        .base_url = "https://api.openai.com/v1",
        .api_key = "openai-key",
        .model = "gpt-5",
    });
    defer seeded.deinit(std.testing.allocator);

    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "anthropic",
        .base_url = "https://api.anthropic.com",
        .api_key = "anthropic-secret",
        .model = "claude-sonnet-4-5",
    });
    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "openrouter",
        .base_url = "https://openrouter.ai/api/v1",
        .api_key = "router-secret",
        .model = "anthropic/claude-sonnet-4.5",
    });

    var inventory = try auth_store.listProviderSummaries(std.testing.allocator, workspace_root);
    defer inventory.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("openrouter", inventory.active_provider);
    try std.testing.expectEqual(@as(usize, 3), inventory.providers.len);

    var found_anthropic = false;
    var found_openrouter = false;
    for (inventory.providers) |summary| {
        if (std.mem.eql(u8, summary.provider_id, "anthropic")) {
            found_anthropic = true;
            try std.testing.expectEqual(types.AuthType.api_key, summary.auth_type);
            try std.testing.expectEqual(types.WireApi.anthropic_messages, summary.wire_api);
            try std.testing.expectEqual(types.AuthScheme.api_key, summary.auth_scheme);
        }
        if (std.mem.eql(u8, summary.provider_id, "openrouter")) {
            found_openrouter = true;
            try std.testing.expect(summary.active);
            try std.testing.expectEqual(types.WireApi.chat_completions, summary.wire_api);
            try std.testing.expectEqual(types.AuthScheme.bearer, summary.auth_scheme);
        }
    }
    try std.testing.expect(found_anthropic);
    try std.testing.expect(found_openrouter);

    try auth_store.selectProvider(std.testing.allocator, workspace_root, "anthropic");
    var active = try auth_store.readAuthStatus(std.testing.allocator, workspace_root);
    defer active.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("anthropic", active.provider_id);
    try std.testing.expectEqual(types.WireApi.anthropic_messages, active.wire_api);
    try std.testing.expectEqual(types.AuthScheme.api_key, active.auth_scheme);
}

test "keyless custom provider accepts no-auth selection without a credential" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "local-gateway",
        .base_url = "http://127.0.0.1:43199/v1",
        .api_key = "",
        .model = "local-model",
        .wire_api = .chat_completions,
        .auth_scheme = .none,
    });

    var resolved = try auth_store.readProviderById(std.testing.allocator, workspace_root, "local-gateway");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.AuthScheme.none, resolved.auth_scheme);
    try std.testing.expectEqual(@as(usize, 0), resolved.api_key.len);
}

const types = VAR1.shared.types;

fn writeAuthFile(
    dir: std.fs.Dir,
    sub_path: []const u8,
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
) !void {
    if (std.fs.path.dirname(sub_path)) |parent| {
        try dir.makePath(parent);
    }

    const payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "version": 1,
        \\  "active_provider": "{s}",
        \\  "providers": {{
        \\    "{s}": {{
        \\      "auth_type": "api_key",
        \\      "api_key": "{s}",
        \\      "base_url": "{s}",
        \\      "model": "{s}",
        \\      "subscription": {{
        \\        "plan_id": null,
        \\        "plan_label": "test",
        \\        "status": "active",
        \\        "source": "test",
        \\        "last_verified_at_ms": 1
        \\      }},
        \\      "updated_at_ms": 1
        \\    }}
        \\  }}
        \\}}
        \\
    , .{ provider_id, provider_id, api_key, base_url, model });
    defer std.testing.allocator.free(payload);

    try dir.writeFile(.{ .sub_path = sub_path, .data = payload });
}
