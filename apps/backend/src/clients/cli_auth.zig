const std = @import("std");
const json = @import("../shared/json.zig");
const auth_store = @import("../core/auth/store.zig");
const shared_types = @import("../shared/types.zig");

pub const AuthAction = union(enum) {
    status,
    login: []const u8,
    logout: []const u8,
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
    \\  VAR1 auth login <provider-id> [--json]
    \\  VAR1 auth logout <provider-id>
    \\
    \\Flags:
    \\  --json                    Emit secret-free machine-readable auth status.
    \\  -h, --help                Print help for the auth command.
    \\
    \\Providers:
    \\  openai-codex              ChatGPT Plus/Pro OAuth provider.
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

    if (std.mem.eql(u8, action, "login") or std.mem.eql(u8, action, "logout")) {
        const provider_id = iter.next() orelse return error.InvalidArgs;
        if (iter.next()) |arg| {
            if (!std.mem.eql(u8, arg, "--json")) return error.InvalidArgs;
            parsed.options.json_output = true;
            if (iter.next() != null) return error.InvalidArgs;
        }
        parsed.options.action = if (std.mem.eql(u8, action, "login"))
            .{ .login = provider_id }
        else
            .{ .logout = provider_id };
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
        "provider_id: {s}\nauth_type: {s}\nmodel: {s}\nbase_url: {s}\naccount_id: {s}\nemail: {s}\nplan_type: {s}\nsubscription_plan: {s}\nsubscription_status: {s}\nexpires_at_ms: {s}\nlast_verified_at_ms: {s}",
        .{
            status.provider_id,
            authTypeLabel(status.auth_type),
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
