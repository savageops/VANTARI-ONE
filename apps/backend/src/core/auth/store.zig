const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");
const provider_profile = @import("../providers/profile.zig");

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
    wire_api: types.WireApi = .auto,
    auth_scheme: ?types.AuthScheme = null,
};

/// API-key provider data crosses the CLI/helper boundary without exposing a
/// second credential owner. `auth.json` remains the only persistence owner.
pub const ApiKeyProviderRecord = struct {
    provider_id: []const u8,
    base_url: []const u8,
    model: []const u8,
    api_key: []const u8,
    wire_api: types.WireApi = .auto,
    auth_scheme: ?types.AuthScheme = null,
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
    wire_api: types.WireApi = .auto,
    auth_scheme: types.AuthScheme = .bearer,
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
    wire_api: types.WireApi = .auto,
    auth_scheme: types.AuthScheme = .bearer,
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

/// Secret-free inventory row for provider/model selection. Credentials never
/// cross this projection; only the auth ledger reads the underlying record.
pub const ProviderSummary = struct {
    provider_id: []u8,
    auth_type: types.AuthType,
    wire_api: types.WireApi,
    auth_scheme: types.AuthScheme,
    model: []u8,
    base_url: []u8,
    active: bool,
    expires_at_ms: ?i64 = null,
    subscription_status: ?[]u8 = null,

    pub fn deinit(self: ProviderSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model);
        allocator.free(self.base_url);
        if (self.subscription_status) |value| allocator.free(value);
    }
};

pub const ProviderSummaryList = struct {
    active_provider: []u8,
    providers: []ProviderSummary,

    pub fn deinit(self: ProviderSummaryList, allocator: std.mem.Allocator) void {
        allocator.free(self.active_provider);
        for (self.providers) |provider| provider.deinit(allocator);
        allocator.free(self.providers);
    }
};

/// Read the active provider as a secret-free operator projection.
pub fn readAuthStatus(allocator: std.mem.Allocator, workspace_root: []const u8) !AuthStatus {
    var resolved = try resolveOrSeed(allocator, workspace_root, null);
    defer resolved.deinit(allocator);

    return .{
        .provider_id = try allocator.dupe(u8, resolved.provider_id),
        .auth_type = resolved.auth_type,
        .wire_api = resolved.wire_api,
        .auth_scheme = resolved.auth_scheme,
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

/// Read every configured provider as a secret-free selection projection.
/// Ordering follows the persisted JSON object order so CLI/TUI cycling is
/// deterministic without creating a second provider registry.
pub fn listProviderSummaries(allocator: std.mem.Allocator, workspace_root: []const u8) !ProviderSummaryList {
    const path = try authFilePath(allocator, workspace_root);
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return Error.MissingAuth;

    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidAuthState;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidAuthState;
    const root = parsed.value.object;
    const active_value = root.get("active_provider") orelse return Error.MissingProvider;
    if (active_value != .string) return Error.InvalidAuthState;
    const providers_value = root.get("providers") orelse return Error.MissingProvider;
    if (providers_value != .object) return Error.InvalidAuthState;

    var summaries = std.array_list.Managed(ProviderSummary).init(allocator);
    errdefer {
        for (summaries.items) |summary| summary.deinit(allocator);
        summaries.deinit();
    }

    var iterator = providers_value.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) return Error.InvalidAuthState;
        var summary = try readProviderSummary(allocator, entry.key_ptr.*, entry.value_ptr.*.object, std.mem.eql(u8, entry.key_ptr.*, active_value.string));
        summaries.append(summary) catch |err| {
            summary.deinit(allocator);
            return err;
        };
    }

    const active_provider = try allocator.dupe(u8, active_value.string);
    errdefer allocator.free(active_provider);
    return .{
        .active_provider = active_provider,
        .providers = try summaries.toOwnedSlice(),
    };
}

fn readProviderSummary(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    provider_object: std.json.ObjectMap,
    active: bool,
) !ProviderSummary {
    const auth_type = try readAuthType(provider_object);
    const base_url = try cloneRequiredString(allocator, provider_object, "base_url");
    errdefer allocator.free(base_url);
    const model = try cloneRequiredString(allocator, provider_object, "model");
    errdefer allocator.free(model);
    const profile_defaults = provider_profile.defaults(provider_id, base_url);
    const stored_wire_api = try readOptionalWireApi(provider_object);
    const wire_api = if (stored_wire_api == null or stored_wire_api.? == .auto) profile_defaults.wire_api else stored_wire_api.?;
    const auth_scheme = (try readOptionalAuthScheme(provider_object)) orelse profile_defaults.auth_scheme;
    var subscription_status: ?[]u8 = null;
    errdefer if (subscription_status) |value| allocator.free(value);
    var expires_at_ms: ?i64 = null;
    if (auth_type == .oauth) {
        expires_at_ms = try cloneRequiredInteger(allocator, provider_object, "expires_at_ms");
        if (provider_object.get("subscription")) |subscription| {
            if (subscription == .object) {
                subscription_status = try cloneOptionalString(allocator, subscription.object, "status");
            }
        }
    }

    return .{
        .provider_id = try allocator.dupe(u8, provider_id),
        .auth_type = auth_type,
        .wire_api = wire_api,
        .auth_scheme = auth_scheme,
        .model = model,
        .base_url = base_url,
        .active = active,
        .expires_at_ms = expires_at_ms,
        .subscription_status = subscription_status,
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
    const profile_defaults = provider_profile.defaults(provider_id, base_url);
    const stored_wire_api = try readOptionalWireApi(provider_object);
    const wire_api = if (stored_wire_api == null or stored_wire_api.? == .auto) profile_defaults.wire_api else stored_wire_api.?;
    const auth_scheme = (try readOptionalAuthScheme(provider_object)) orelse profile_defaults.auth_scheme;
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
        .wire_api = wire_api,
        .auth_scheme = auth_scheme,
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

/// Read a provider-specific wire override while keeping legacy records
/// resolvable through the codename profile defaults.
fn readOptionalWireApi(object: std.json.ObjectMap) !?types.WireApi {
    const value = object.get("wire_api") orelse return null;
    if (value != .string) return Error.InvalidAuthState;
    return types.WireApi.fromString(value.string) orelse Error.InvalidAuthState;
}

/// Read the header scheme stored by provider-scoped login. Missing values are
/// legacy records and are filled from provider id/base-url evidence.
fn readOptionalAuthScheme(object: std.json.ObjectMap) !?types.AuthScheme {
    const value = object.get("auth_scheme") orelse return null;
    if (value != .string) return Error.InvalidAuthState;
    return types.AuthScheme.fromString(value.string) orelse Error.InvalidAuthState;
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
        .wire_api = provider_profile.effectiveWireApi(bootstrap.provider_id, bootstrap.base_url, bootstrap.wire_api),
        .auth_scheme = bootstrap.auth_scheme orelse provider_profile.defaults(bootstrap.provider_id, bootstrap.base_url).auth_scheme,
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
    try putString(arena_allocator, provider, "wire_api", provider_profile.defaults(record.provider_id, record.base_url).wire_api.label());
    try putString(arena_allocator, provider, "auth_scheme", provider_profile.defaults(record.provider_id, record.base_url).auth_scheme.label());
    _ = provider.orderedRemove("api_key");
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

/// Persist one API-key provider while preserving unrelated provider records.
/// Provider-scoped login is idempotent: repeating the same provider id updates
/// only that record and makes it the active provider, while OAuth-only fields
/// are removed so stale subscription secrets cannot survive an auth-type swap.
pub fn upsertApiKeyProvider(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    record: ApiKeyProviderRecord,
) !void {
    if (record.provider_id.len == 0 or record.base_url.len == 0 or record.model.len == 0 or record.api_key.len == 0) {
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

    try putString(arena_allocator, provider, "auth_type", "api_key");
    try putString(arena_allocator, provider, "api_key", record.api_key);
    try putString(arena_allocator, provider, "base_url", record.base_url);
    try putString(arena_allocator, provider, "model", record.model);
    try putString(arena_allocator, provider, "wire_api", provider_profile.effectiveWireApi(record.provider_id, record.base_url, record.wire_api).label());
    try putString(arena_allocator, provider, "auth_scheme", (record.auth_scheme orelse provider_profile.defaults(record.provider_id, record.base_url).auth_scheme).label());
    _ = provider.orderedRemove("access_token");
    _ = provider.orderedRemove("refresh_token");
    _ = provider.orderedRemove("id_token");
    _ = provider.orderedRemove("expires_at_ms");
    _ = provider.orderedRemove("account_id");
    _ = provider.orderedRemove("user_id");
    _ = provider.orderedRemove("email");
    _ = provider.orderedRemove("plan_type");
    try putInteger(arena_allocator, provider, "updated_at_ms", std.time.milliTimestamp());

    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 })});
    defer allocator.free(formatted);
    try fsutil.writeText(path, formatted);
}

/// Select an existing provider without changing its credentials. The auth
/// ledger remains the only active-provider selector used by config loading.
pub fn selectProvider(allocator: std.mem.Allocator, workspace_root: []const u8, provider_id: []const u8) !void {
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
    const providers_value = root.get("providers") orelse return Error.MissingProvider;
    if (providers_value != .object or providers_value.object.get(provider_id) == null) return Error.MissingProvider;
    try putString(arena_allocator, root, "active_provider", provider_id);
    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
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
    try writer.writeAll(",\n      \"wire_api\": ");
    try writeJsonString(writer, provider_profile.effectiveWireApi(bootstrap.provider_id, bootstrap.base_url, bootstrap.wire_api).label());
    try writer.writeAll(",\n      \"auth_scheme\": ");
    try writeJsonString(writer, (bootstrap.auth_scheme orelse provider_profile.defaults(bootstrap.provider_id, bootstrap.base_url).auth_scheme).label());
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
