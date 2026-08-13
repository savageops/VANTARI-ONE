const std = @import("std");
const json = @import("../shared/json.zig");
const auth_store = @import("../core/auth/store.zig");
const shared_types = @import("../shared/types.zig");

pub const AuthAction = union(enum) {
    status,
    login: LoginOptions,
    logout: []const u8,
    use: []const u8,
};

/// Provider-scoped login options. API keys enter through stdin or an explicitly
/// named environment variable; they are never accepted as a command argument.
pub const LoginOptions = struct {
    provider_id: []const u8,
    api_key_stdin: bool = false,
    api_key_env: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    wire_api: ?shared_types.WireApi = null,
    auth_scheme: ?shared_types.AuthScheme = null,
};

pub const AuthCliOptions = struct {
    action: AuthAction,
    json_output: bool = false,
};

pub const ParsedAuthArguments = struct {
    options: AuthCliOptions = .{ .action = .status },
    help_requested: bool = false,
};

pub const help_text =
    \\Usage:
    \\  VAR1 auth status [--json]
    \\  VAR1 auth login <provider-id> --api-key-stdin [--base-url <url>] --model <id> [--wire-api <api>] [--json]
    \\  VAR1 auth login <provider-id> --api-key-env <name> [--base-url <url>] --model <id> [--wire-api <api>] [--json]
    \\  VAR1 auth logout <provider-id>
    \\  VAR1 auth use <provider-id>
    \\
    \\Flags:
    \\  --json                    Emit secret-free machine-readable auth status.
    \\  -h, --help                Print help for the auth command.
    \\
    \\Providers:
    \\  openai-codex              ChatGPT Plus/Pro OAuth provider.
    \\  openai, anthropic,        API-key providers; OpenRouter and custom
    \\  openrouter                 OpenAI-compatible endpoints use the same path.
    \\
    \\Status never prints API keys, access tokens, or refresh tokens. Login prints
    \\the provider authorization URL and accepts a pasted redirect/code fallback;
    \\logout removes only the named provider record.
    \\
;

pub fn parseArguments(iter: *std.process.ArgIterator) !ParsedAuthArguments {
    var parsed = ParsedAuthArguments{};
    const action = iter.next() orelse return error.InvalidArgs;
    if (isHelpFlag(action)) {
        parsed.help_requested = true;
        return parsed;
    }

    if (std.mem.eql(u8, action, "status")) {
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                parsed.options.json_output = true;
                continue;
            }
            if (isHelpFlag(arg)) {
                parsed.help_requested = true;
                continue;
            }
            return error.InvalidArgs;
        }
        parsed.options.action = .status;
        return parsed;
    }

    if (std.mem.eql(u8, action, "use")) {
        const provider_id = iter.next() orelse return error.InvalidArgs;
        if (iter.next()) |arg| {
            if (!std.mem.eql(u8, arg, "--json")) return error.InvalidArgs;
            parsed.options.json_output = true;
            if (iter.next() != null) return error.InvalidArgs;
        }
        parsed.options.action = .{ .use = provider_id };
        return parsed;
    }

    if (std.mem.eql(u8, action, "logout")) {
        const provider_id = iter.next() orelse return error.InvalidArgs;
        if (iter.next()) |arg| {
            if (!std.mem.eql(u8, arg, "--json")) return error.InvalidArgs;
            parsed.options.json_output = true;
            if (iter.next() != null) return error.InvalidArgs;
        }
        parsed.options.action = .{ .logout = provider_id };
        return parsed;
    }

    if (std.mem.eql(u8, action, "login")) {
        const provider_id = iter.next() orelse return error.InvalidArgs;
        var login = LoginOptions{ .provider_id = provider_id };
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                parsed.options.json_output = true;
            } else if (std.mem.eql(u8, arg, "--api-key-stdin")) {
                login.api_key_stdin = true;
            } else if (std.mem.eql(u8, arg, "--api-key-env")) {
                login.api_key_env = iter.next() orelse return error.InvalidArgs;
            } else if (std.mem.eql(u8, arg, "--base-url")) {
                login.base_url = iter.next() orelse return error.InvalidArgs;
            } else if (std.mem.eql(u8, arg, "--model")) {
                login.model = iter.next() orelse return error.InvalidArgs;
            } else if (std.mem.eql(u8, arg, "--wire-api")) {
                const value = iter.next() orelse return error.InvalidArgs;
                login.wire_api = shared_types.WireApi.fromString(value) orelse return error.InvalidArgs;
            } else if (std.mem.eql(u8, arg, "--auth-scheme")) {
                const value = iter.next() orelse return error.InvalidArgs;
                login.auth_scheme = shared_types.AuthScheme.fromString(value) orelse return error.InvalidArgs;
            } else if (isHelpFlag(arg)) {
                parsed.help_requested = true;
            } else {
                return error.InvalidArgs;
            }
        }
        if (!login.api_key_stdin and login.api_key_env == null and std.mem.eql(u8, provider_id, "openai-codex")) {
            parsed.options.action = .{ .login = login };
            return parsed;
        }
        if (!login.api_key_stdin and login.api_key_env == null) return error.InvalidArgs;
        parsed.options.action = .{ .login = login };
        return parsed;
    }

    return error.InvalidArgs;
}

pub fn renderAuthStatus(allocator: std.mem.Allocator, status: auth_store.AuthStatus, json_output: bool) ![]u8 {
    if (json_output) return json.renderAlloc(allocator, status);

    const expires_at = try optionalTimestampLabel(allocator, status.expires_at_ms);
    defer allocator.free(expires_at);
    const last_verified_at = try optionalTimestampLabel(allocator, status.last_verified_at_ms);
    defer allocator.free(last_verified_at);

    return std.fmt.allocPrint(
        allocator,
        "provider_id: {s}\nauth_type: {s}\nwire_api: {s}\nauth_scheme: {s}\nmodel: {s}\nbase_url: {s}\naccount_id: {s}\nemail: {s}\nplan_type: {s}\nsubscription_plan: {s}\nsubscription_status: {s}\nexpires_at_ms: {s}\nlast_verified_at_ms: {s}",
        .{
            status.provider_id,
            authTypeLabel(status.auth_type),
            status.wire_api.label(),
            status.auth_scheme.label(),
            status.model,
            status.base_url,
            status.account_id orelse "unknown",
            status.email orelse "unknown",
            status.plan_type orelse "unknown",
            status.subscription_plan_label orelse "unknown",
            status.subscription_status orelse "unknown",
            expires_at,
            last_verified_at,
        },
    );
}

fn optionalTimestampLabel(allocator: std.mem.Allocator, value: ?i64) ![]u8 {
    if (value) |timestamp| return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    return allocator.dupe(u8, "unknown");
}

fn authTypeLabel(auth_type: shared_types.AuthType) []const u8 {
    return switch (auth_type) {
        .api_key => "api_key",
        .oauth => "oauth",
    };
}


fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}
