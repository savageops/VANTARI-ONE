const std = @import("std");

pub const Error = error{
    InvalidAuthorizationInput,
    InvalidJwt,
    InvalidTokenResponse,
    MissingAccountId,
    TokenTransportFailed,
    TokenEndpointRejected,
    /// Refresh token expired or revoked — operator must re-login.
    RefreshTokenExpired,
    /// Refresh quota exhausted (rate-limited) — retry later.
    RefreshTokenExhausted,
};

/// Typed refresh-failure classification. Harvested from codex's
/// `RefreshTokenFailedReason`. Maps the failure to operator action:
/// Expired → re-login, Exhausted → retry later, Other → transient.
pub const RefreshTokenFailedReason = enum {
    expired,
    exhausted,
    other,

    pub fn label(self: RefreshTokenFailedReason) []const u8 {
        return switch (self) {
            .expired => "expired_or_revoked",
            .exhausted => "rate_limited",
            .other => "transient",
        };
    }
};

pub const descriptor = .{
    .provider_id = "openai-codex",
    .client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
    .authorize_url = "https://auth.openai.com/oauth/authorize",
    .token_url = "https://auth.openai.com/oauth/token",
    .redirect_uri = "http://localhost:1455/auth/callback",
    .scope = "openid profile email offline_access api.connectors.read api.connectors.invoke",
    .jwt_auth_claim_path = "https://api.openai.com/auth",
    .originator = "codex_cli_rs",
    .base_url = "https://chatgpt.com/backend-api",
    .model = "gpt-5.4-mini",
    .issuer = "https://auth.openai.com",
    .subscription_source = "openai-codex-oauth",
};

pub const PkceFlow = struct {
    verifier: []u8,
    challenge: []u8,
    state: []u8,

    pub fn deinit(self: PkceFlow, allocator: std.mem.Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
        allocator.free(self.state);
    }
};

pub const OAuthTokens = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    id_token: ?[]u8 = null,

    pub fn deinit(self: OAuthTokens, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        if (self.id_token) |value| allocator.free(value);
    }
};

pub const TokenClaims = struct {
    account_id: ?[]u8 = null,
    user_id: ?[]u8 = null,
    plan_type: ?[]u8 = null,
    email: ?[]u8 = null,

    pub fn deinit(self: TokenClaims, allocator: std.mem.Allocator) void {
        if (self.account_id) |value| allocator.free(value);
        if (self.user_id) |value| allocator.free(value);
        if (self.plan_type) |value| allocator.free(value);
        if (self.email) |value| allocator.free(value);
    }
};

pub const TokenPostFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    form_body: []const u8,
) anyerror![]u8;

pub const TokenTransport = struct {
    context: ?*anyopaque,
    postFn: TokenPostFn,
};

pub fn postTokenForm(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    form_body: []const u8,
) ![]u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response = std.Io.Writer.Allocating.init(allocator);
    defer response.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = form_body,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .response_writer = &response.writer,
    }) catch return error.TokenTransportFailed;

    if (result.status != .ok) {
        // Classify the failure so the operator knows whether to re-login or retry.
        // Harvested from codex's RefreshTokenFailedReason classification.
        const code = @intFromEnum(result.status);
        return switch (code) {
            400, 401, 403 => error.RefreshTokenExpired, // invalid_grant: token expired or revoked
            429 => error.RefreshTokenExhausted, // rate-limited: retry later
            else => error.TokenEndpointRejected, // server error or unexpected: transient
        };
    }
    return response.toOwnedSlice();
}

pub fn generatePkce(allocator: std.mem.Allocator) !PkceFlow {
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    var verifier_encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&verifier_encoded, &random_bytes);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(verifier_encoded[0..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var challenge_encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(digest.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&challenge_encoded, &digest);

    var state_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&state_bytes);
    var state_encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(state_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&state_encoded, &state_bytes);

    return .{
        .verifier = try allocator.dupe(u8, verifier_encoded[0..]),
        .challenge = try allocator.dupe(u8, challenge_encoded[0..]),
        .state = try allocator.dupe(u8, state_encoded[0..]),
    };
}

pub fn authorizationUrl(allocator: std.mem.Allocator, flow: PkceFlow) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}?response_type=code&client_id={s}&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid%20profile%20email%20offline_access%20api.connectors.read%20api.connectors.invoke&code_challenge={s}&code_challenge_method=S256&state={s}&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator={s}",
        .{ descriptor.authorize_url, descriptor.client_id, flow.challenge, flow.state, descriptor.originator },
    );
}

pub const AuthorizationInput = struct {
    code: []u8,
    state: ?[]u8 = null,

    pub fn deinit(self: AuthorizationInput, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        if (self.state) |value| allocator.free(value);
    }
};

pub fn parseAuthorizationInput(allocator: std.mem.Allocator, input: []const u8) !AuthorizationInput {
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (value.len == 0) return Error.InvalidAuthorizationInput;

    if (std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://")) {
        const query_start = std.mem.indexOfScalar(u8, value, '?') orelse return Error.InvalidAuthorizationInput;
        const path = value[0..query_start];
        if (!std.mem.endsWith(u8, path, "/auth/callback")) return Error.InvalidAuthorizationInput;
        return parseAuthorizationQuery(allocator, value[query_start + 1 ..]);
    }

    if (std.mem.indexOfScalar(u8, value, '#')) |separator| {
        if (separator == 0 or separator + 1 >= value.len) return Error.InvalidAuthorizationInput;
        return .{
            .code = try allocator.dupe(u8, value[0..separator]),
            .state = try allocator.dupe(u8, value[separator + 1 ..]),
        };
    }

    if (std.mem.indexOfScalar(u8, value, '=') != null) return parseAuthorizationQuery(allocator, value);
    return .{ .code = try allocator.dupe(u8, value) };
}

fn parseAuthorizationQuery(allocator: std.mem.Allocator, query: []const u8) !AuthorizationInput {
    var code: ?[]u8 = null;
    var state: ?[]u8 = null;
    errdefer {
        if (code) |value| allocator.free(value);
        if (state) |value| allocator.free(value);
    }

    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const separator = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..separator];
        const item = field[separator + 1 ..];
        if (std.mem.eql(u8, key, "code") and code == null) {
            code = try decodeQueryComponent(allocator, item);
        } else if (std.mem.eql(u8, key, "state") and state == null) {
            state = try decodeQueryComponent(allocator, item);
        }
    }
    return .{ .code = code orelse return Error.InvalidAuthorizationInput, .state = state };
}

fn decodeQueryComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var decoded = std.array_list.Managed(u8).init(allocator);
    defer decoded.deinit();

    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        switch (value[index]) {
            '+' => try decoded.append(' '),
            '%' => {
                if (index + 2 >= value.len) return Error.InvalidAuthorizationInput;
                const high = hexValue(value[index + 1]) orelse return Error.InvalidAuthorizationInput;
                const low = hexValue(value[index + 2]) orelse return Error.InvalidAuthorizationInput;
                try decoded.append((high << 4) | low);
                index += 2;
            },
            else => |char| try decoded.append(char),
        }
    }

    return decoded.toOwnedSlice();
}

fn hexValue(char: u8) ?u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

pub fn parseTokenResponse(allocator: std.mem.Allocator, response_body: []const u8, now_ms: i64) !OAuthTokens {
    return parseTokenResponseWithIdToken(allocator, response_body, now_ms, true, null);
}

pub fn parseRefreshTokenResponse(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    fallback_refresh_token: []const u8,
    now_ms: i64,
) !OAuthTokens {
    return parseTokenResponseWithIdToken(allocator, response_body, now_ms, false, fallback_refresh_token);
}

fn parseTokenResponseWithIdToken(
    allocator: std.mem.Allocator,
    response_body: []const u8,
    now_ms: i64,
    require_id_token: bool,
    fallback_refresh_token: ?[]const u8,
) !OAuthTokens {
    const Parsed = struct {
        access_token: ?[]const u8 = null,
        refresh_token: ?[]const u8 = null,
        expires_in: ?i64 = null,
    id_token: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Parsed, allocator, response_body, .{ .ignore_unknown_fields = true }) catch {
        return Error.InvalidTokenResponse;
    };
    defer parsed.deinit();

    const access_token = parsed.value.access_token orelse return Error.InvalidTokenResponse;
    const refresh_token = parsed.value.refresh_token orelse fallback_refresh_token orelse return Error.InvalidTokenResponse;
    const id_token = parsed.value.id_token;
    const expires_in = parsed.value.expires_in orelse return Error.InvalidTokenResponse;
    if (access_token.len == 0 or refresh_token.len == 0 or expires_in <= 0) return Error.InvalidTokenResponse;
    if (require_id_token and (id_token == null or id_token.?.len == 0)) return Error.InvalidTokenResponse;

    return .{
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = try allocator.dupe(u8, refresh_token),
        .expires_at_ms = now_ms + expires_in * std.time.ms_per_s,
        .id_token = if (id_token) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn refreshAccessToken(
    allocator: std.mem.Allocator,
    transport: TokenTransport,
    refresh_token: []const u8,
    now_ms: i64,
) !OAuthTokens {
    var form_list = std.array_list.Managed(u8).init(allocator);
    defer form_list.deinit();
    try appendFormField(&form_list, "grant_type", "refresh_token");
    try appendFormField(&form_list, "client_id", descriptor.client_id);
    try appendFormField(&form_list, "refresh_token", refresh_token);
    const form = try allocator.dupe(u8, form_list.items);
    defer allocator.free(form);

    const response_body = try transport.postFn(transport.context, allocator, descriptor.token_url, form);
    defer allocator.free(response_body);
    return parseRefreshTokenResponse(allocator, response_body, refresh_token, now_ms);
}

pub fn exchangeAuthorizationCode(
    allocator: std.mem.Allocator,
    transport: TokenTransport,
    code: []const u8,
    verifier: []const u8,
    now_ms: i64,
) !OAuthTokens {
    var form_list = std.array_list.Managed(u8).init(allocator);
    defer form_list.deinit();
    try appendFormField(&form_list, "grant_type", "authorization_code");
    try appendFormField(&form_list, "client_id", descriptor.client_id);
    try appendFormField(&form_list, "code", code);
    try appendFormField(&form_list, "code_verifier", verifier);
    try appendFormField(&form_list, "redirect_uri", descriptor.redirect_uri);
    const form = try allocator.dupe(u8, form_list.items);
    defer allocator.free(form);

    const response_body = try transport.postFn(transport.context, allocator, descriptor.token_url, form);
    defer allocator.free(response_body);
    return parseTokenResponse(allocator, response_body, now_ms);
}

fn appendFormField(list: *std.array_list.Managed(u8), key: []const u8, value: []const u8) !void {
    const writer = list.writer();
    if (list.items.len > 0) try writer.writeByte('&');
    try writer.writeAll(key);
    try writer.writeByte('=');
    for (value) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try writer.writeByte(char);
        } else {
            try writer.print("%{X:0>2}", .{char});
        }
    }
}

pub fn extractClaims(allocator: std.mem.Allocator, jwt: []const u8) !TokenClaims {
    var segments = std.mem.splitScalar(u8, jwt, '.');
    _ = segments.next() orelse return Error.InvalidJwt;
    const payload_segment = segments.next() orelse return Error.InvalidJwt;
    _ = segments.next() orelse return Error.InvalidJwt;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment) catch return Error.InvalidJwt;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment) catch return Error.InvalidJwt;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return Error.InvalidJwt;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidJwt;

    var claims = TokenClaims{};
    errdefer claims.deinit(allocator);
    if (parsed.value.object.get(descriptor.jwt_auth_claim_path)) |auth| {
        if (auth == .object) {
            claims.account_id = try cloneOptionalString(allocator, auth.object, "chatgpt_account_id");
            claims.user_id = try cloneOptionalString(allocator, auth.object, "chatgpt_user_id");
            claims.plan_type = try cloneOptionalString(allocator, auth.object, "chatgpt_plan_type");
        }
    }
    claims.email = try cloneOptionalString(allocator, parsed.value.object, "email");
    if (claims.email == null) {
        if (parsed.value.object.get("https://api.openai.com/profile")) |profile| {
            if (profile == .object) {
                claims.email = try cloneOptionalString(allocator, profile.object, "email");
            }
        }
    }
    if (claims.account_id == null) return Error.MissingAccountId;
    return claims;
}

fn cloneOptionalString(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return try allocator.dupe(u8, value.string);
}
