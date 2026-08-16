const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");

/// Read-only credential discovery for native Codex, Claude Code, and OpenCode
/// installations. This module NEVER prints or persists tokens; it only reports
/// which native credential files are present, whether their schema is valid,
/// whether they are (heuristically) live, and what provider/model they map to.
/// Import (persisting into the auth ledger) is a separate, explicit step.
///
/// Harvested from the credential file shapes observed on this workstation and
/// oh-my-pi's credential semantics: Codex/Claude are OAuth refresh flows,
/// OpenCode is a static API-key store.

pub const SourceKind = enum {
    codex,
    claude,
    opencode,
    openai_api_key,
    anthropic_api_key,
    opencode_api_key,
};

pub const DetectedCredential = struct {
    /// Provenance tag persisted on the imported provider record.
    source: []const u8,
    kind: SourceKind,
    /// Path of the native file that backs this credential (secret-free).
    source_path: []const u8,
    /// Canonical wire provider id this credential will import under.
    provider_id: []const u8,
    /// Model id this credential is already scoped to (empty = let router pick).
    model: []const u8 = "",
    /// Whether the credential looks live (tokens present and not expired).
    live: bool,
    /// Optional account/identity hint for operator disambiguation (never a token).
    account_hint: ?[]const u8 = null,
    /// Reason a present file is considered invalid/expired (secret-free).
    note: ?[]const u8 = null,
};

pub const DetectResult = struct {
    allocator: std.mem.Allocator,
    detected: []DetectedCredential,

    pub fn deinit(self: *DetectResult) void {
        for (self.detected) |entry| {
            self.allocator.free(entry.source);
            self.allocator.free(entry.source_path);
            self.allocator.free(entry.provider_id);
            self.allocator.free(entry.model);
            if (entry.account_hint) |value| self.allocator.free(value);
            if (entry.note) |value| self.allocator.free(value);
        }
        self.allocator.free(self.detected);
    }
};

pub const Error = error{
    HomeUnavailable,
};

/// Probe every native credential source in priority order. Detection is
/// read-only; no ledger is written. Returns an owned, secret-free inventory.
pub fn detect(allocator: std.mem.Allocator) !DetectResult {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return Error.HomeUnavailable,
        else => return err,
    };
    defer allocator.free(home);
    return detectWithHome(allocator, home);
}

/// Detection over a caller-provided home root (used by tests to probe a
/// fixture directory). Env-var probes still consult the live environment.
pub fn detectWithHome(allocator: std.mem.Allocator, home: []const u8) !DetectResult {
    var detected = std.array_list.Managed(DetectedCredential).init(allocator);
    errdefer {
        for (detected.items) |entry| {
            allocator.free(entry.source);
            allocator.free(entry.source_path);
            allocator.free(entry.provider_id);
            allocator.free(entry.model);
            if (entry.account_hint) |value| allocator.free(value);
            if (entry.note) |value| allocator.free(value);
        }
        detected.deinit();
    }

    // Environment API keys are the cheapest, most reliable source and always
    // outrank any file-backed credential at request time.
    if (std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY")) |key| {
        detected.append(.{
            .source = try allocator.dupe(u8, "env"),
            .kind = .openai_api_key,
            .source_path = try allocator.dupe(u8, "env:OPENAI_API_KEY"),
            .provider_id = try allocator.dupe(u8, "openai"),
            .live = key.len > 0,
        }) catch |err| {
            allocator.free(key);
            return err;
        };
        allocator.free(key);
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY")) |key| {
        detected.append(.{
            .source = try allocator.dupe(u8, "env"),
            .kind = .anthropic_api_key,
            .source_path = try allocator.dupe(u8, "env:ANTHROPIC_API_KEY"),
            .provider_id = try allocator.dupe(u8, "anthropic"),
            .live = key.len > 0,
        }) catch |err| {
            allocator.free(key);
            return err;
        };
        allocator.free(key);
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "OPENCODE_API_KEY")) |key| {
        detected.append(.{
            .source = try allocator.dupe(u8, "env"),
            .kind = .opencode_api_key,
            .source_path = try allocator.dupe(u8, "env:OPENCODE_API_KEY"),
            .provider_id = try allocator.dupe(u8, "opencode"),
            .live = key.len > 0,
        }) catch |err| {
            allocator.free(key);
            return err;
        };
        allocator.free(key);
    } else |_| {}

    try detectCodex(allocator, home, &detected);
    try detectClaude(allocator, home, &detected);
    try detectOpenCode(allocator, home, &detected);

    return .{
        .allocator = allocator,
        .detected = try detected.toOwnedSlice(),
    };
}

/// Probe `~/.codex/auth.json`. Shape (observed):
/// `{auth_mode, OPENAI_API_KEY, tokens:{id_token, access_token, refresh_token,
/// account_id}, last_refresh}`. Account identity is a token-free JWT claim.
fn detectCodex(
    allocator: std.mem.Allocator,
    home: []const u8,
    detected: *std.array_list.Managed(DetectedCredential),
) !void {
    const path = try std.fs.path.join(allocator, &.{ home, ".codex", "auth.json" });
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return;

    const source_path = try allocator.dupe(u8, path);
    errdefer allocator.free(source_path);
    const content = fsutil.readTextAlloc(allocator, path) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "codex"),
            .kind = .codex,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "openai-codex"),
            .live = false,
            .note = try allocator.dupe(u8, "codex auth file unreadable"),
        });
        return;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "codex"),
            .kind = .codex,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "openai-codex"),
            .live = false,
            .note = try allocator.dupe(u8, "codex auth file is not valid JSON"),
        });
        return;
    };
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else {
        try detected.append(.{
            .source = try allocator.dupe(u8, "codex"),
            .kind = .codex,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "openai-codex"),
            .live = false,
            .note = try allocator.dupe(u8, "codex auth file root is not an object"),
        });
        return;
    };

    const tokens = if (root.get("tokens")) |t| (if (t == .object) t.object else null) else null;
    if (tokens == null or tokens.?.get("access_token") == null or tokens.?.get("refresh_token") == null) {
        try detected.append(.{
            .source = try allocator.dupe(u8, "codex"),
            .kind = .codex,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "openai-codex"),
            .live = false,
            .note = try allocator.dupe(u8, "codex tokens object missing access/refresh token"),
        });
        return;
    }

    var account_hint: ?[]u8 = null;
    if (tokens.?.get("account_id")) |account| {
        if (account == .string and account.string.len > 0) {
            account_hint = try allocator.dupe(u8, account.string);
        }
    }

    const last_refresh = if (root.get("last_refresh")) |v| (if (v == .string) v.string else "") else "";
    // Codex auth.json carries no explicit expiry; the presence of both tokens
    // is the live heuristic we can safely assert without decoding JWTs here.
    try detected.append(.{
        .source = try allocator.dupe(u8, "codex"),
        .kind = .codex,
        .source_path = source_path,
        .provider_id = try allocator.dupe(u8, "openai-codex"),
        .model = try allocator.dupe(u8, "gpt-5.4-mini"),
        .live = true,
        .account_hint = account_hint,
        .note = if (last_refresh.len > 0) try std.fmt.allocPrint(allocator, "last_refresh={s}", .{last_refresh}) else null,
    });
}

/// Probe `~/.claude/.credentials.json`. Shape (observed):
/// `{claudeAiOauth:{accessToken, refreshToken, expiresAt, refreshTokenExpiresAt,
/// scopes, subscriptionType}}`. `expiresAt` is an epoch-ms number.
fn detectClaude(
    allocator: std.mem.Allocator,
    home: []const u8,
    detected: *std.array_list.Managed(DetectedCredential),
) !void {
    const path = try std.fs.path.join(allocator, &.{ home, ".claude", ".credentials.json" });
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return;

    const source_path = try allocator.dupe(u8, path);
    errdefer allocator.free(source_path);
    const content = fsutil.readTextAlloc(allocator, path) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "claude"),
            .kind = .claude,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "anthropic"),
            .live = false,
            .note = try allocator.dupe(u8, "claude credentials file unreadable"),
        });
        return;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "claude"),
            .kind = .claude,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "anthropic"),
            .live = false,
            .note = try allocator.dupe(u8, "claude credentials file is not valid JSON"),
        });
        return;
    };
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else {
        try detected.append(.{
            .source = try allocator.dupe(u8, "claude"),
            .kind = .claude,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "anthropic"),
            .live = false,
            .note = try allocator.dupe(u8, "claude credentials root is not an object"),
        });
        return;
    };
    const oauth = if (root.get("claudeAiOauth")) |v| (if (v == .object) v.object else null) else null;
    if (oauth == null or oauth.?.get("accessToken") == null or oauth.?.get("refreshToken") == null) {
        try detected.append(.{
            .source = try allocator.dupe(u8, "claude"),
            .kind = .claude,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "anthropic"),
            .live = false,
            .note = try allocator.dupe(u8, "claudeAiOauth object missing access/refresh token"),
        });
        return;
    }

    var live = true;
    var note: ?[]u8 = null;
    if (oauth.?.get("expiresAt")) |expires| {
        if (expires == .integer) {
            if (expires.integer <= std.time.milliTimestamp()) {
                live = false;
                note = try allocator.dupe(u8, "access token expired");
            }
        }
    }

    var subscription_hint: ?[]u8 = null;
    if (oauth.?.get("subscriptionType")) |subscription| {
        if (subscription == .string and subscription.string.len > 0) {
            subscription_hint = try allocator.dupe(u8, subscription.string);
        }
    }

    try detected.append(.{
        .source = try allocator.dupe(u8, "claude"),
        .kind = .claude,
        .source_path = source_path,
        .provider_id = try allocator.dupe(u8, "anthropic"),
        .model = try allocator.dupe(u8, "claude-sonnet-4-5"),
        .live = live,
        .account_hint = subscription_hint,
        .note = note,
    });
}

/// Probe `~/.local/share/opencode/auth.json`. Shape (observed):
/// `{provider_id:{type,key}}`. Each provider is a static API key.
fn detectOpenCode(
    allocator: std.mem.Allocator,
    home: []const u8,
    detected: *std.array_list.Managed(DetectedCredential),
) !void {
    const path = try std.fs.path.join(allocator, &.{ home, ".local", "share", "opencode", "auth.json" });
    defer allocator.free(path);
    if (!fsutil.fileExists(path)) return;

    const source_path = try allocator.dupe(u8, path);
    errdefer allocator.free(source_path);
    const content = fsutil.readTextAlloc(allocator, path) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "opencode"),
            .kind = .opencode,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "opencode"),
            .live = false,
            .note = try allocator.dupe(u8, "opencode auth file unreadable"),
        });
        return;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .ignore_unknown_fields = true }) catch {
        try detected.append(.{
            .source = try allocator.dupe(u8, "opencode"),
            .kind = .opencode,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "opencode"),
            .live = false,
            .note = try allocator.dupe(u8, "opencode auth file is not valid JSON"),
        });
        return;
    };
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else {
        try detected.append(.{
            .source = try allocator.dupe(u8, "opencode"),
            .kind = .opencode,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "opencode"),
            .live = false,
            .note = try allocator.dupe(u8, "opencode auth root is not an object"),
        });
        return;
    };

    var found = false;
    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const provider_object = entry.value_ptr.*.object;
        const key = provider_object.get("key") orelse continue;
        if (key != .string or key.string.len == 0) continue;
        found = true;
        var account_hint: ?[]u8 = null;
        if (provider_object.get("type")) |provider_type| {
            if (provider_type == .string and provider_type.string.len > 0) {
                account_hint = try allocator.dupe(u8, provider_type.string);
            }
        }
        try detected.append(.{
            .source = try allocator.dupe(u8, "opencode"),
            .kind = .opencode,
            .source_path = try allocator.dupe(u8, path),
            .provider_id = try allocator.dupe(u8, entry.key_ptr.*),
            .live = true,
            .account_hint = account_hint,
        });
    }

    if (found) {
        // Each provider entry owns its own path copy (allocated above); the
        // shared local is no longer referenced once the loop wrote its copies.
        allocator.free(source_path);
        return;
    }

    if (!found) {
        try detected.append(.{
            .source = try allocator.dupe(u8, "opencode"),
            .kind = .opencode,
            .source_path = source_path,
            .provider_id = try allocator.dupe(u8, "opencode"),
            .live = false,
            .note = try allocator.dupe(u8, "opencode auth file has no api keys"),
        });
    }
}

const testing = std.testing;

fn writeFixture(root: []const u8, subpath: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(testing.allocator, &.{ root, subpath });
    defer testing.allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir);
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
}

test "detect reports live codex and claude and opencode credentials" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);

    try writeFixture(root, "/.codex/auth.json",
        \\{"auth_mode":"access_token","tokens":{"id_token":"e30.e30.e30","access_token":"sk-codex","refresh_token":"r1","account_id":"acct-1"},"last_refresh":"2026-08-01T00:00:00Z"}
    );
    try writeFixture(root, "/.claude/.credentials.json",
        \\{"claudeAiOauth":{"accessToken":"claude-at","refreshToken":"claude-rt","expiresAt":4102444800000,"scopes":[],"subscriptionType":"pro"}}
    );
    try writeFixture(root, "/.local/share/opencode/auth.json",
        \\{"opencode":{"type":"zen","key":"opk-1"},"opencode-go":{"type":"go","key":"opk-2"}}
    );

    var result = try detectWithHome(testing.allocator, root);
    defer result.deinit();

    var codex = false;
    var claude = false;
    var opencode = false;
    for (result.detected) |entry| {
        if (std.mem.eql(u8, entry.provider_id, "openai-codex") and entry.live) codex = true;
        if (std.mem.eql(u8, entry.provider_id, "anthropic") and entry.live and entry.kind == .claude) claude = true;
        if (std.mem.eql(u8, entry.provider_id, "opencode") and entry.live) opencode = true;
    }
    try testing.expect(codex);
    try testing.expect(claude);
    try testing.expect(opencode);
}

test "detect marks malformed codex credentials invalid without leaking" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);

    try writeFixture(root, "/.codex/auth.json",
        \\{"auth_mode":"access_token","tokens":{"id_token":"e30.e30.e30"},"last_refresh":"2026-08-01T00:00:00Z"}
    );

    var result = try detectWithHome(testing.allocator, root);
    defer result.deinit();

    try testing.expect(result.detected.len == 1);
    try testing.expect(!result.detected[0].live);
    try testing.expect(result.detected[0].note != null);
}

test "detect with an empty home finds nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);

    var result = try detectWithHome(testing.allocator, root);
    defer result.deinit();
    try testing.expect(result.detected.len == 0);
}

test "detect reports every opencode provider with its own owned path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir.realpathAlloc(testing.allocator, ".") catch return error.SkipZigTest;
    defer testing.allocator.free(root);

    try writeFixture(root, "/.local/share/opencode/auth.json",
        \\{"opencode":{"type":"zen","key":"opk-1"},"opencode-go":{"type":"go","key":"opk-2"},"zai-coding-plan":{"type":"plan","key":"opk-3"}}
    );

    var result = try detectWithHome(testing.allocator, root);
    defer result.deinit();

    var opencode = false;
    var opencode_go = false;
    var zai = false;
    var opencode_count: usize = 0;
    for (result.detected) |entry| {
        if (!entry.live or entry.kind != .opencode) continue;
        opencode_count += 1;
        if (std.mem.eql(u8, entry.provider_id, "opencode")) opencode = true;
        if (std.mem.eql(u8, entry.provider_id, "opencode-go")) opencode_go = true;
        if (std.mem.eql(u8, entry.provider_id, "zai-coding-plan")) zai = true;
        // Every provider entry owns its own source_path copy (no shared
        // pointer), so deinit frees each exactly once.
        try testing.expect(entry.source_path.len > 0);
    }
    try testing.expect(opencode);
    try testing.expect(opencode_go);
    try testing.expect(zai);
    try testing.expect(opencode_count == 3);
}
