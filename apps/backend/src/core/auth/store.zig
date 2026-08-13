const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidAuthState,
    MissingAuth,
    MissingProvider,
};

pub const AuthBootstrap = struct {
    provider_id: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    subscription_plan_id: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
    subscription_source: ?[]const u8 = null,
};

/// OAuth provider data crosses the CLI/helper boundary as an owned-free view.
/// The auth store is the only owner that persists these secrets.
pub const OAuthProviderRecord = struct {
    provider_id: []const u8,
    base_url: []const u8,
    model: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    id_token: ?[]const u8 = null,
    expires_at_ms: i64,
    account_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    email: ?[]const u8 = null,
    plan_type: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
    subscription_source: []const u8,
    last_verified_at_ms: i64,
};

pub const ResolvedAuth = struct {
    provider_id: []u8,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    auth_type: types.AuthType = .api_key,
    refresh_token: ?[]u8 = null,
    expires_at_ms: ?i64 = null,
    account_id: ?[]u8 = null,
    user_id: ?[]u8 = null,
    email: ?[]u8 = null,
    plan_type: ?[]u8 = null,
    last_verified_at_ms: ?i64 = null,
    subscription_plan_id: ?[]u8 = null,
    subscription_plan_label: ?[]u8 = null,
    subscription_status: ?[]u8 = null,

    pub fn deinit(self: ResolvedAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        if (self.refresh_token) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.user_id) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
        if (self.plan_type) |value| allocator.free(value);
        if (self.subscription_plan_id) |value| allocator.free(value);
        if (self.subscription_plan_label) |value| allocator.free(value);
        if (self.subscription_status) |value| allocator.free(value);
    }
};

/// Secret-free active-provider projection for CLI and health surfaces.
pub const AuthStatus = struct {
    provider_id: []u8,
    auth_type: types.AuthType,
    model: []u8,
    base_url: []u8,
    account_id: ?[]u8 = null,
    email: ?[]u8 = null,
    plan_type: ?[]u8 = null,
    subscription_plan_label: ?[]u8 = null,
    subscription_status: ?[]u8 = null,
    expires_at_ms: ?i64 = null,
    last_verified_at_ms: ?i64 = null,

    pub fn deinit(self: AuthStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model);
        allocator.free(self.base_url);
        if (self.account_id) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
        if (self.plan_type) |value| allocator.free(value);
        if (self.subscription_plan_label) |value| allocator.free(value);
        if (self.subscription_status) |value| allocator.free(value);
    }
};

/// Read the active provider as a secret-free operator projection.
pub fn readAuthStatus(allocator: std.mem.Allocator, workspace_root: []const u8) !AuthStatus {
    var resolved = try resolveOrSeed(allocator, workspace_root, null);
    defer resolved.deinit(allocator);

    return .{
        .provider_id = try allocator.dupe(u8, resolved.provider_id),
        .auth_type = resolved.auth_type,
        .model = try allocator.dupe(u8, resolved.model),
        .base_url = try allocator.dupe(u8, resolved.base_url),
        .account_id = if (resolved.account_id) |value| try allocator.dupe(u8, value) else null,
        .email = if (resolved.email) |value| try allocator.dupe(u8, value) else null,
        .plan_type = if (resolved.plan_type) |value| try allocator.dupe(u8, value) else null,
        .subscription_plan_label = if (resolved.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
        .subscription_status = if (resolved.subscription_status) |value| try allocator.dupe(u8, value) else null,
        .expires_at_ms = resolved.expires_at_ms,
        .last_verified_at_ms = resolved.last_verified_at_ms,
    };
}

pub fn resolveOrSeed(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    bootstrap: ?AuthBootstrap,
) !ResolvedAuth {
    const installed_path = if (bootstrap == null) try installedAuthFilePath(allocator) else null;
    defer if (installed_path) |value| allocator.free(value);

    return resolveOrSeedWithInstalledAuthPath(allocator, workspace_root, bootstrap, installed_path);
}

pub fn resolveOrSeedWithInstalledAuthPath(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    bootstrap: ?AuthBootstrap,
    installed_path: ?[]const u8,
) !ResolvedAuth {
    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);

    if (fsutil.fileExists(path)) {
        return readActiveProvider(allocator, path);
    }

    const legacy_nested_path = try legacyNestedAuthFilePath(allocator, workspace_root);
    defer allocator.free(legacy_nested_path);
    if (fsutil.fileExists(legacy_nested_path)) {
        try migrateAuthFile(allocator, legacy_nested_path, path);
        return readActiveProvider(allocator, path);
    }

    if (bootstrap == null) {
        if (installed_path) |fallback_path| {
            if (fsutil.fileExists(fallback_path)) {
                try migrateAuthFile(allocator, fallback_path, path);
                return readActiveProvider(allocator, path);
            }
        }
    }

    const seed = bootstrap orelse return Error.MissingAuth;
    try writeBootstrapAuthFile(allocator, path, seed);
    return cloneBootstrap(allocator, seed);
}

pub fn authFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "auth.json" });
}

/// Previous releases nested credentials under auth/auth.json. It remains a
/// one-time migration input, never a second live owner.
fn legacyNestedAuthFilePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "auth", "auth.json" });
}

pub fn installedAuthFilePath(allocator: std.mem.Allocator) !?[]u8 {
    if (try installedConfigRoot(allocator)) |root| {
        defer allocator.free(root);
        return try installedAuthFilePathFromRoot(allocator, root);
    }
    return null;
}

pub fn installedAuthFilePathFromRoot(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ root, "Vantari", "auth", "auth.json" });
}

fn migrateAuthFile(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !void {
    var validated = try readActiveProvider(allocator, source_path);
    defer validated.deinit(allocator);
    const content = try fsutil.readTextAlloc(allocator, source_path);
    defer allocator.free(content);
    try fsutil.writeText(destination_path, content);
    var canonical = try readActiveProvider(allocator, destination_path);
    defer canonical.deinit(allocator);
    try std.fs.cwd().deleteFile(source_path);
}

fn installedConfigRoot(allocator: std.mem.Allocator) !?[]u8 {
    const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (local_app_data) |value| return value;

    const xdg_config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (xdg_config_home) |value| return value;

    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (home) |value| {
        defer allocator.free(value);
        return try fsutil.join(allocator, &.{ value, ".config" });
    }

    return null;
}

fn readActiveProvider(allocator: std.mem.Allocator, path: []const u8) !ResolvedAuth {
    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidAuthState;
    const root = parsed.value.object;

    const active_provider_value = root.get("active_provider") orelse return Error.MissingProvider;
    if (active_provider_value != .string) return Error.InvalidAuthState;
    const active_provider = active_provider_value.string;

    return readProviderFromRoot(allocator, root, active_provider);
}

/// Read a specific provider by id from the auth ledger's providers map.
/// Used for multi-provider routing: the operator requests a non-active
/// provider (e.g. `--provider lmstudio`) and this resolves its credentials
/// without changing the active provider. Returns MissingProvider when the
/// requested id is not in the map.
pub fn readProviderById(allocator: std.mem.Allocator, workspace_root: []const u8, provider_id: []const u8) !ResolvedAuth {
    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);

    if (!fsutil.fileExists(path)) return Error.MissingAuth;

    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{});
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidAuthState;
    return readProviderFromRoot(allocator, parsed.value.object, provider_id);
}

fn readProviderFromRoot(allocator: std.mem.Allocator, root: std.json.ObjectMap, provider_id: []const u8) !ResolvedAuth {
    const providers_value = root.get("providers") orelse return Error.MissingProvider;
    if (providers_value != .object) return Error.InvalidAuthState;

    const provider_value = providers_value.object.get(provider_id) orelse return Error.MissingProvider;
    if (provider_value != .object) return Error.InvalidAuthState;
    const provider_object = provider_value.object;

    const auth_type = try readAuthType(provider_object);
    const base_url = try cloneRequiredString(allocator, provider_object, "base_url");
    errdefer allocator.free(base_url);
    const model = try cloneRequiredString(allocator, provider_object, "model");
    errdefer allocator.free(model);

    const api_key = if (auth_type == .oauth)
        try cloneRequiredString(allocator, provider_object, "access_token")
    else
        try cloneRequiredString(allocator, provider_object, "api_key");
    errdefer allocator.free(api_key);

    const refresh_token = if (auth_type == .oauth)
        try cloneRequiredString(allocator, provider_object, "refresh_token")
    else
        null;
    errdefer if (refresh_token) |value| allocator.free(value);

    const expires_at_ms = if (auth_type == .oauth)
        try cloneRequiredInteger(allocator, provider_object, "expires_at_ms")
    else
        null;

    var account_id: ?[]u8 = null;
    errdefer if (account_id) |value| allocator.free(value);
    var user_id: ?[]u8 = null;
    errdefer if (user_id) |value| allocator.free(value);
    var email: ?[]u8 = null;
    errdefer if (email) |value| allocator.free(value);
    var plan_type: ?[]u8 = null;
    errdefer if (plan_type) |value| allocator.free(value);
    if (auth_type == .oauth) {
        account_id = try cloneOptionalString(allocator, provider_object, "account_id");
        user_id = try cloneOptionalString(allocator, provider_object, "user_id");
        email = try cloneOptionalString(allocator, provider_object, "email");
        plan_type = try cloneOptionalString(allocator, provider_object, "plan_type");
    }

    var subscription_plan_id: ?[]u8 = null;
    errdefer if (subscription_plan_id) |value| allocator.free(value);
    var subscription_plan_label: ?[]u8 = null;
    errdefer if (subscription_plan_label) |value| allocator.free(value);
    var subscription_status: ?[]u8 = null;
    errdefer if (subscription_status) |value| allocator.free(value);
    var last_verified_at_ms: ?i64 = null;

    if (provider_object.get("subscription")) |subscription_value| {
        if (subscription_value == .object) {
            subscription_plan_id = try cloneOptionalString(allocator, subscription_value.object, "plan_id");
            subscription_plan_label = try cloneOptionalString(allocator, subscription_value.object, "plan_label");
            subscription_status = try cloneOptionalString(allocator, subscription_value.object, "status");
            last_verified_at_ms = try cloneOptionalInteger(allocator, subscription_value.object, "last_verified_at_ms");
        }
    }

    return .{
        .provider_id = try allocator.dupe(u8, provider_id),
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .auth_type = auth_type,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
        .user_id = user_id,
        .email = email,
        .plan_type = plan_type,
        .subscription_plan_id = subscription_plan_id,
        .subscription_plan_label = subscription_plan_label,
        .subscription_status = subscription_status,
        .last_verified_at_ms = last_verified_at_ms,
    };
}

fn readAuthType(object: std.json.ObjectMap) !types.AuthType {
    const value = object.get("auth_type") orelse return .api_key;
    if (value != .string) return Error.InvalidAuthState;
    if (std.mem.eql(u8, value.string, "api_key")) return .api_key;
    if (std.mem.eql(u8, value.string, "oauth")) return .oauth;
    return Error.InvalidAuthState;
}

fn stripUtf8Bom(content: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, bom)) return content[bom.len..];
    return content;
}

fn cloneBootstrap(allocator: std.mem.Allocator, bootstrap: AuthBootstrap) !ResolvedAuth {
    return .{
        .provider_id = try allocator.dupe(u8, bootstrap.provider_id),
        .base_url = try allocator.dupe(u8, bootstrap.base_url),
        .api_key = try allocator.dupe(u8, bootstrap.api_key),
        .model = try allocator.dupe(u8, bootstrap.model),
        .subscription_plan_id = if (bootstrap.subscription_plan_id) |value| try allocator.dupe(u8, value) else null,
        .subscription_plan_label = if (bootstrap.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
        .subscription_status = if (bootstrap.subscription_status) |value| try allocator.dupe(u8, value) else null,
    };
}

fn cloneRequiredString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return Error.InvalidAuthState;
    if (value != .string) return Error.InvalidAuthState;
    return allocator.dupe(u8, value.string);
}

fn cloneOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}

fn cloneRequiredInteger(_: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return Error.InvalidAuthState;
    if (value != .integer) return Error.InvalidAuthState;
    return value.integer;
}

fn cloneOptionalInteger(_: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .integer) return Error.InvalidAuthState;
    return value.integer;
}

/// Persist one OAuth provider while preserving every unrelated provider record.
/// The write uses the same atomic text owner as bootstrap auth creation.
pub fn upsertOAuthProvider(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    record: OAuthProviderRecord,
) !void {
    if (record.provider_id.len == 0 or record.access_token.len == 0 or record.refresh_token.len == 0) {
        return Error.InvalidAuthState;
    }

    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);

    if (!fsutil.fileExists(path)) {
        const migrated = resolveOrSeed(allocator, workspace_root, null) catch |err| switch (err) {
            error.MissingAuth => null,
            else => return err,
        };
        if (migrated) |value| value.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var root = if (fsutil.fileExists(path)) blk: {
        const content = try fsutil.readTextAlloc(allocator, path);
        defer allocator.free(content);
        const parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidAuthState;
        if (parsed.value != .object) return Error.InvalidAuthState;
        break :blk parsed.value.object;
    } else blk: {
        break :blk std.json.ObjectMap.init(arena_allocator);
    };

    try putInteger(arena_allocator, &root, "version", 2);
    try putString(arena_allocator, &root, "active_provider", record.provider_id);

    const providers = if (root.getPtr("providers")) |value| blk: {
        if (value.* != .object) return Error.InvalidAuthState;
        break :blk &value.object;
    } else blk: {
        const object = std.json.ObjectMap.init(arena_allocator);
        try putValue(arena_allocator, &root, "providers", .{ .object = object });
        break :blk &root.getPtr("providers").?.object;
    };

    const provider = if (providers.getPtr(record.provider_id)) |value| blk: {
        if (value.* != .object) return Error.InvalidAuthState;
        break :blk &value.object;
    } else blk: {
        const object = std.json.ObjectMap.init(arena_allocator);
        try providers.put(try arena_allocator.dupe(u8, record.provider_id), .{ .object = object });
        break :blk &providers.getPtr(record.provider_id).?.object;
    };

    try putString(arena_allocator, provider, "auth_type", "oauth");
    try putString(arena_allocator, provider, "access_token", record.access_token);
    try putString(arena_allocator, provider, "refresh_token", record.refresh_token);
    try putOptionalString(arena_allocator, provider, "id_token", record.id_token);
    try putString(arena_allocator, provider, "base_url", record.base_url);
    try putString(arena_allocator, provider, "model", record.model);
    try putInteger(arena_allocator, provider, "expires_at_ms", record.expires_at_ms);
    try putOptionalString(arena_allocator, provider, "account_id", record.account_id);
    try putOptionalString(arena_allocator, provider, "user_id", record.user_id);
    try putOptionalString(arena_allocator, provider, "email", record.email);
    try putOptionalString(arena_allocator, provider, "plan_type", record.plan_type);
    try putInteger(arena_allocator, provider, "updated_at_ms", std.time.milliTimestamp());

    const subscription = if (provider.getPtr("subscription")) |value| blk: {
        if (value.* != .object) return Error.InvalidAuthState;
        break :blk &value.object;
    } else blk: {
        const object = std.json.ObjectMap.init(arena_allocator);
        try putValue(arena_allocator, provider, "subscription", .{ .object = object });
        break :blk &provider.getPtr("subscription").?.object;
    };
    try putOptionalString(arena_allocator, subscription, "plan_id", record.plan_type);
    try putOptionalString(arena_allocator, subscription, "plan_label", record.subscription_plan_label orelse record.plan_type);
    try putOptionalString(arena_allocator, subscription, "status", record.subscription_status orelse "active");
    try putString(arena_allocator, subscription, "source", record.subscription_source);
    try putInteger(arena_allocator, subscription, "last_verified_at_ms", record.last_verified_at_ms);

    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 })});
    defer allocator.free(formatted);
    try fsutil.writeText(path, formatted);
}

/// Remove exactly one provider record. If it was active, choose a remaining
/// provider deterministically; an empty ledger is removed atomically by the
/// filesystem owner and is read as MissingAuth on the next command.
pub fn removeProvider(allocator: std.mem.Allocator, workspace_root: []const u8, provider_id: []const u8) !void {
    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return Error.MissingAuth;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, arena_allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidAuthState;
    if (parsed.value != .object) return Error.InvalidAuthState;
    const root = &parsed.value.object;
    const providers_value = root.getPtr("providers") orelse return Error.InvalidAuthState;
    if (providers_value.* != .object) return Error.InvalidAuthState;
    const providers = &providers_value.object;
    if (!providers.orderedRemove(provider_id)) return Error.MissingProvider;

    if (providers.count() == 0) {
        try std.fs.cwd().deleteFile(path);
        return;
    }

    const active = root.get("active_provider");
    if (active == null or active.? != .string or std.mem.eql(u8, active.?.string, provider_id)) {
        var iterator = providers.iterator();
        const first = iterator.next() orelse return Error.InvalidAuthState;
        try putString(arena_allocator, root, "active_provider", first.key_ptr.*);
    }

    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(formatted);
    try fsutil.writeText(path, formatted);
}

fn putValue(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try owner.put(try allocator.dupe(u8, key), value);
}

fn putString(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putValue(allocator, owner, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putOptionalString(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: ?[]const u8) !void {
    if (value) |text| {
        try putString(allocator, owner, key, text);
    } else {
        try putValue(allocator, owner, key, .null);
    }
}

fn putInteger(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: i64) !void {
    try putValue(allocator, owner, key, .{ .integer = value });
}

fn writeBootstrapAuthFile(allocator: std.mem.Allocator, path: []const u8, bootstrap: AuthBootstrap) !void {
    const now = std.time.milliTimestamp();

    var payload = std.array_list.Managed(u8).init(allocator);
    defer payload.deinit();

    var writer = payload.writer();
    try writer.writeAll("{\n  \"version\": 1,\n  \"active_provider\": ");
    try writeJsonString(writer, bootstrap.provider_id);
    try writer.writeAll(",\n  \"providers\": {\n    ");
    try writeJsonString(writer, bootstrap.provider_id);
    try writer.writeAll(": {\n      \"auth_type\": \"api_key\",\n      \"api_key\": ");
    try writeJsonString(writer, bootstrap.api_key);
    try writer.writeAll(",\n      \"base_url\": ");
    try writeJsonString(writer, bootstrap.base_url);
    try writer.writeAll(",\n      \"model\": ");
    try writeJsonString(writer, bootstrap.model);
    try writer.writeAll(",\n      \"subscription\": {\n        \"plan_id\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_plan_id);
    try writer.writeAll(",\n        \"plan_label\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_plan_label);
    try writer.writeAll(",\n        \"status\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_status);
    try writer.writeAll(",\n        \"source\": ");
    try writeOptionalJsonString(writer, bootstrap.subscription_source);
    try writer.print(",\n        \"last_verified_at_ms\": {d}\n      }}", .{now});
    try writer.print(",\n      \"updated_at_ms\": {d}\n    }}\n  }}\n}}\n", .{now});

    try fsutil.writeText(path, payload.items);
}

fn writeOptionalJsonString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
        return;
    }
    try writer.writeAll("null");
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}
