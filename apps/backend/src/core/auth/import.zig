const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const auth_store = @import("store.zig");
const detect = @import("detect.zig");
const codex = @import("openai_codex.zig");
const provider_profile = @import("../providers/profile.zig");
const types = @import("../../shared/types.zig");

/// Explicit, opt-in import of a detected native credential into the auth
/// ledger. Import is the only place a refresh token crosses from a native
/// file into VANTARI's store; detection alone never writes secrets. The wire
/// provider id and the credential source are kept distinct: an import refuses
/// to clobber a record owned by a different source unless forced.

pub const Error = error{
    HomeUnavailable,
    SourceFileUnavailable,
    InvalidSourceFormat,
    /// Import would replace a provider record owned by a different source.
    CredentialSourceCollision,
    NoSourceSelected,
};

/// Import every live detected credential for the requested source(s).
/// `sources` lists provenance tags to import ("codex", "claude", "opencode",
/// "env"); an empty slice imports all live detected credentials. Returns the
/// provider ids that were written, so the operator sees the outcome without
/// any secret leaking.
pub fn importSources(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    sources: []const []const u8,
    force: bool,
) !ImportResult {
    var detection = try detect.detect(allocator);
    defer detection.deinit();
    return importDetected(allocator, workspace_root, sources, force, detection.detected);
}

/// Import from an explicitly supplied detection inventory (test seam). Tests
/// pass a fixture-home detection so they never touch the host's real native
/// credential files; production uses `importSources` (real HOME).
pub fn importDetected(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    sources: []const []const u8,
    force: bool,
    detected: []const detect.DetectedCredential,
) !ImportResult {
    var imported = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (imported.items) |id| allocator.free(id);
        imported.deinit();
    }
    var skipped = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (skipped.items) |id| allocator.free(id);
        skipped.deinit();
    }

    for (detected) |entry| {
        if (!entry.live) continue;
        if (sources.len > 0 and !sourceIncluded(entry.source, sources)) continue;
        // Env vars are already resolvable at request time; importing them into
        // the ledger is redundant and would obscure the live env override.
        if (std.mem.eql(u8, entry.source, "env")) continue;

        importOne(allocator, workspace_root, entry, force, &imported) catch |err| switch (err) {
            error.CredentialSourceCollision => {
                try skipped.append(try allocator.dupe(u8, entry.provider_id));
                continue;
            },
            error.InvalidSourceFormat => {
                try skipped.append(try allocator.dupe(u8, entry.provider_id));
                continue;
            },
            else => return err,
        };
    }

    return .{
        .allocator = allocator,
        .imported = try imported.toOwnedSlice(),
        .skipped = try skipped.toOwnedSlice(),
    };
}

fn sourceIncluded(source: []const u8, sources: []const []const u8) bool {
    for (sources) |candidate| {
        if (std.mem.eql(u8, source, candidate)) return true;
    }
    return false;
}

pub const ImportResult = struct {
    allocator: std.mem.Allocator,
    imported: []const []u8,
    skipped: []const []u8,

    pub fn deinit(self: *ImportResult) void {
        for (self.imported) |id| self.allocator.free(id);
        self.allocator.free(self.imported);
        for (self.skipped) |id| self.allocator.free(id);
        self.allocator.free(self.skipped);
    }
};

fn importOne(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    entry: detect.DetectedCredential,
    force: bool,
    imported: *std.array_list.Managed([]u8),
) !void {
    // Preserve source/account identity: refuse to overwrite a provider record
    // that a different source owns. A record that EXISTS but carries no source
    // tag is a manual interactive login or legacy record — operator-owned and
    // equally protected, because a silent native-import overwrite would clobber
    // an explicit choice. An absent provider imports freely. Explicit --force
    // overrides after the operator has seen the collision in the status surface.
    if (!force) {
        const provider_exists = auth_store.readProviderExists(allocator, workspace_root, entry.provider_id);
        if (provider_exists) {
            const existing_source = auth_store.readProviderSourceById(allocator, workspace_root, entry.provider_id) catch null;
            if (existing_source) |source| {
                defer allocator.free(source);
                if (!std.mem.eql(u8, source, entry.source)) return Error.CredentialSourceCollision;
            } else {
                return Error.CredentialSourceCollision;
            }
        }
    }

    switch (entry.kind) {
        .codex => try importCodex(allocator, workspace_root, entry),
        .claude => try importClaude(allocator, workspace_root, entry),
        .opencode => try importOpenCode(allocator, workspace_root, entry),
        .openai_api_key, .anthropic_api_key, .opencode_api_key => return Error.NoSourceSelected,
    }
    try imported.append(try allocator.dupe(u8, entry.provider_id));
}

fn readNativeJson(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
    if (!fsutil.fileExists(path)) return Error.SourceFileUnavailable;
    const content = fsutil.readTextAlloc(allocator, path) catch return Error.SourceFileUnavailable;
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .ignore_unknown_fields = true }) catch return Error.InvalidSourceFormat;
    if (parsed.value != .object) {
        parsed.deinit();
        return Error.InvalidSourceFormat;
    }
    return parsed;
}

fn getString(root: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = root.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

/// Import Codex: `~/.codex/auth.json` tokens → `openai-codex` OAuth record.
/// Account id comes from the id_token JWT claim (same extraction the
/// interactive flow uses), falling back to the file's own account_id field.
fn importCodex(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    entry: detect.DetectedCredential,
) !void {
    var parsed = try readNativeJson(allocator, entry.source_path);
    defer parsed.deinit();
    const root = parsed.value.object;

    const tokens = if (root.get("tokens")) |t| (if (t == .object) t.object else null) else null;
    const access_token = if (tokens) |t| getString(t, "access_token") else null;
    const refresh_token = if (tokens) |t| getString(t, "refresh_token") else null;
    const id_token = if (tokens) |t| getString(t, "id_token") else null;
    if (access_token == null or refresh_token == null) return Error.InvalidSourceFormat;

    var account_id: ?[]u8 = null;
    defer if (account_id) |v| allocator.free(v);
    var email: ?[]u8 = null;
    defer if (email) |v| allocator.free(v);
    var plan_type: ?[]u8 = null;
    defer if (plan_type) |v| allocator.free(v);
    if (id_token) |id_token_value| {
        if (codex.extractClaims(allocator, id_token_value)) |claims| {
            defer claims.deinit(allocator);
            if (claims.account_id) |value| account_id = try allocator.dupe(u8, value);
            if (claims.email) |value| email = try allocator.dupe(u8, value);
            if (claims.plan_type) |value| plan_type = try allocator.dupe(u8, value);
        } else |_| {}
    }
    if (account_id == null) {
        if (tokens) |t| {
            if (getString(t, "account_id")) |value| account_id = try allocator.dupe(u8, value);
        }
    }

    // Codex auth.json carries no explicit expiry; use the interactive default
    // model and a far-future expiry so the record is usable until a refresh.
    // The refresh flow re-derives account/email on the next successful turn.
    try auth_store.upsertOAuthProvider(allocator, workspace_root, .{
        .provider_id = "openai-codex",
        .base_url = codex.descriptor.base_url,
        .model = codex.descriptor.model,
        .access_token = access_token.?,
        .refresh_token = refresh_token.?,
        .id_token = id_token,
        .expires_at_ms = std.time.milliTimestamp() + 60 * std.time.ms_per_min,
        .account_id = account_id,
        .email = email,
        .plan_type = plan_type,
        .subscription_plan_label = plan_type,
        .subscription_status = "active",
        .subscription_source = codex.descriptor.subscription_source,
        .last_verified_at_ms = std.time.milliTimestamp(),
        .credential_source = "codex",
    });
}

/// Import Claude Code: `~/.claude/.credentials.json` → `anthropic` OAuth record
/// with an explicit bearer scheme (the profile default is api-key).
fn importClaude(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    entry: detect.DetectedCredential,
) !void {
    var parsed = try readNativeJson(allocator, entry.source_path);
    defer parsed.deinit();
    const root = parsed.value.object;
    const oauth = if (root.get("claudeAiOauth")) |v| (if (v == .object) v.object else null) else null;
    if (oauth == null) return Error.InvalidSourceFormat;
    const access_token = getString(oauth.?, "accessToken") orelse return Error.InvalidSourceFormat;
    const refresh_token = getString(oauth.?, "refreshToken") orelse return Error.InvalidSourceFormat;

    var expires_at_ms: i64 = std.time.milliTimestamp() + 60 * std.time.ms_per_min;
    if (oauth.?.get("expiresAt")) |expires| {
        if (expires == .integer and expires.integer > 0) expires_at_ms = expires.integer;
    }

    var subscription_status: ?[]u8 = null;
    defer if (subscription_status) |v| allocator.free(v);
    if (oauth.?.get("subscriptionType")) |subscription| {
        if (subscription == .string) subscription_status = try allocator.dupe(u8, subscription.string);
    }

    const base_url = provider_profile.defaultBaseUrl("anthropic") orelse "https://api.anthropic.com";
    try auth_store.upsertOAuthProvider(allocator, workspace_root, .{
        .provider_id = "anthropic",
        .base_url = base_url,
        .model = "claude-sonnet-4-5",
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .subscription_plan_label = subscription_status,
        .subscription_status = subscription_status,
        .subscription_source = "claude-code-oauth",
        .last_verified_at_ms = std.time.milliTimestamp(),
        .auth_scheme = .bearer,
        .credential_source = "claude",
    });
}

/// Import OpenCode: each `provider_id:{type,key}` becomes an api-key record
/// under that provider id with the shared OpenCode base URL.
fn importOpenCode(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    entry: detect.DetectedCredential,
) !void {
    var parsed = try readNativeJson(allocator, entry.source_path);
    defer parsed.deinit();
    const root = parsed.value.object;
    const provider_object = root.get(entry.provider_id) orelse return Error.InvalidSourceFormat;
    if (provider_object != .object) return Error.InvalidSourceFormat;
    const key = getString(provider_object.object, "key") orelse return Error.InvalidSourceFormat;

    try auth_store.upsertApiKeyProvider(allocator, workspace_root, .{
        .provider_id = entry.provider_id,
        .base_url = "https://api.opencode.ai/v1",
        .model = "opencode-go",
        .api_key = key,
        .credential_source = "opencode",
    });
}

const testing = std.testing;

fn writeFixture(root: []const u8, subpath: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ root, subpath });
    defer testing.allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

/// Per-test workspaces are derived from each tmp dir's unique sub_path so the
/// auth ledger always lands under the isolated test runtime root.
fn testWorkspace(allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{sub_path});
}

/// Detect native credentials under a fixture home root (never the real HOME)
/// and import from that inventory via the seam, so the test cannot accidentally
/// copy the host's actual Codex/Claude/OpenCode credentials into the ledger.
fn importFromFixtureHome(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    home: []const u8,
    sources: []const []const u8,
    force: bool,
) !ImportResult {
    var detection = try detect.detectWithHome(allocator, home);
    defer detection.deinit();
    return importDetected(allocator, workspace_root, sources, force, detection.detected);
}

test "import claude oauth persists a bearer-scheme anthropic record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    const workspace = try testWorkspace(testing.allocator, tmp.sub_path[0..]);
    defer testing.allocator.free(workspace);

    try writeFixture(root, "/.claude/.credentials.json",
        \\{"claudeAiOauth":{"accessToken":"at-1","refreshToken":"rt-1","expiresAt":4102444800000,"scopes":[],"subscriptionType":"pro"}}
    );

    const sources = [_][]const u8{"claude"};
    var result = try importFromFixtureHome(testing.allocator, workspace, root, sources[0..], false);
    defer result.deinit();

    try testing.expect(result.imported.len == 1);
    try testing.expectEqualStrings("anthropic", result.imported[0]);

    var auth = try auth_store.readProviderById(testing.allocator, workspace, "anthropic");
    defer auth.deinit(testing.allocator);
    try testing.expectEqual(types.AuthType.oauth, auth.auth_type);
    try testing.expectEqual(types.AuthScheme.bearer, auth.auth_scheme);
    try testing.expectEqualStrings("at-1", auth.api_key);
}

test "import refuses to clobber a provider owned by a different source" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    const workspace = try testWorkspace(testing.allocator, tmp.sub_path[0..]);
    defer testing.allocator.free(workspace);

    // First, seed an anthropic record via interactive login (no source tag).
    try auth_store.upsertOAuthProvider(testing.allocator, workspace, .{
        .provider_id = "anthropic",
        .base_url = "https://api.anthropic.com",
        .model = "claude-sonnet-4-5",
        .access_token = "manual-at",
        .refresh_token = "manual-rt",
        .expires_at_ms = 4102444800000,
        .subscription_source = "manual",
        .last_verified_at_ms = std.time.milliTimestamp(),
    });

    try writeFixture(root, "/.claude/.credentials.json",
        \\{"claudeAiOauth":{"accessToken":"claude-at","refreshToken":"claude-rt","expiresAt":4102444800000}}
    );

    const sources = [_][]const u8{"claude"};
    var result = try importFromFixtureHome(testing.allocator, workspace, root, sources[0..], false);
    defer result.deinit();
    try testing.expect(result.imported.len == 0);
    try testing.expect(result.skipped.len == 1);
    try testing.expectEqualStrings("anthropic", result.skipped[0]);

    // The manual record is untouched.
    var auth = try auth_store.readProviderById(testing.allocator, workspace, "anthropic");
    defer auth.deinit(testing.allocator);
    try testing.expectEqualStrings("manual-at", auth.api_key);

    // --force replaces it.
    var forced = try importFromFixtureHome(testing.allocator, workspace, root, sources[0..], true);
    defer forced.deinit();
    try testing.expect(forced.imported.len == 1);
    var replaced = try auth_store.readProviderById(testing.allocator, workspace, "anthropic");
    defer replaced.deinit(testing.allocator);
    try testing.expectEqualStrings("claude-at", replaced.api_key);
}

test "import codex oauth persists an openai-codex record with account id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    const workspace = try testWorkspace(testing.allocator, tmp.sub_path[0..]);
    defer testing.allocator.free(workspace);

    try writeFixture(root, "/.codex/auth.json",
        \\{"auth_mode":"access_token","tokens":{"id_token":"e30.e30.e30","access_token":"codex-at","refresh_token":"codex-rt","account_id":"acct-99"},"last_refresh":"2026-08-01T00:00:00Z"}
    );

    const sources = [_][]const u8{"codex"};
    var result = try importFromFixtureHome(testing.allocator, workspace, root, sources[0..], false);
    defer result.deinit();
    try testing.expect(result.imported.len == 1);
    try testing.expectEqualStrings("openai-codex", result.imported[0]);

    var auth = try auth_store.readProviderById(testing.allocator, workspace, "openai-codex");
    defer auth.deinit(testing.allocator);
    try testing.expectEqualStrings("codex-at", auth.api_key);
    try testing.expectEqualStrings("acct-99", auth.account_id.?);
}

test "import opencode persists an api-key record under its provider id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    const workspace = try testWorkspace(testing.allocator, tmp.sub_path[0..]);
    defer testing.allocator.free(workspace);

    try writeFixture(root, "/.local/share/opencode/auth.json",
        \\{"opencode-go":{"type":"go","key":"opk-77"}}
    );

    const sources = [_][]const u8{"opencode"};
    var result = try importFromFixtureHome(testing.allocator, workspace, root, sources[0..], false);
    defer result.deinit();
    try testing.expect(result.imported.len == 1);
    try testing.expectEqualStrings("opencode-go", result.imported[0]);

    var auth = try auth_store.readProviderById(testing.allocator, workspace, "opencode-go");
    defer auth.deinit(testing.allocator);
    try testing.expectEqualStrings("opk-77", auth.api_key);
    const source = try auth_store.readProviderSourceById(testing.allocator, workspace, "opencode-go");
    try testing.expectEqualStrings("opencode", source.?);
    testing.allocator.free(source.?);
}
