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
