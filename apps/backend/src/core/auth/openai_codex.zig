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

/// Small localhost callback owner for the browser PKCE path. Manual redirect
/// paste remains the fallback when port 1455 is unavailable or the browser
/// cannot reach the callback.
pub const CallbackServer = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    expected_state: []const u8,
    result: ?AuthorizationInput = null,
    thread: ?std.Thread = null,

    pub fn start(allocator: std.mem.Allocator, expected_state: []const u8) !*CallbackServer {
        const address = try std.net.Address.parseIp("127.0.0.1", 1455);
        const listener = try address.listen(.{ .reuse_address = true });
        const server = try allocator.create(CallbackServer);
        server.* = .{
            .allocator = allocator,
            .listener = listener,
            .expected_state = expected_state,
        };
        server.thread = std.Thread.spawn(.{}, callbackThread, .{server}) catch |err| {
            server.listener.deinit();
            allocator.destroy(server);
            return err;
        };
        return server;
    }

    pub fn takeResult(self: *CallbackServer) ?AuthorizationInput {
        self.stopAndJoin();
        const result = self.result;
        self.result = null;
        return result;
    }

    pub fn deinit(self: *CallbackServer) void {
        self.stopAndJoin();
        if (self.result) |result| result.deinit(self.allocator);
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    fn stopAndJoin(self: *CallbackServer) void {
        if (self.thread == null) return;
        const address = self.listener.listen_address;
        var wake = std.net.tcpConnectToAddress(address) catch null;
        if (wake) |*stream| {
            defer stream.close();
            stream.writeAll("GET /cancel HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") catch {};
        }
        self.thread.?.join();
        self.thread = null;
    }

    fn callbackThread(self: *CallbackServer) void {
        while (true) {
            var connection = self.listener.accept() catch return;
            defer connection.stream.close();

            var buffer: [8192]u8 = undefined;
            const count = connection.stream.read(&buffer) catch return;
            const request = buffer[0..count];
            const target = requestTarget(request) orelse continue;
            if (std.mem.eql(u8, target, "/cancel")) return;
            if (!std.mem.startsWith(u8, target, "/auth/callback")) {
                writeCallbackResponse(&connection, "404 Not Found", "VANTARI OAuth callback route not found.");
                continue;
            }

            const callback_url = std.fmt.allocPrint(self.allocator, "http://localhost{s}", .{target}) catch return;
            defer self.allocator.free(callback_url);
            var input = parseAuthorizationInput(self.allocator, callback_url) catch {
                writeCallbackResponse(&connection, "400 Bad Request", "VANTARI OAuth callback was invalid.");
                continue;
            };
            if (input.state == null or !std.mem.eql(u8, input.state.?, self.expected_state)) {
                input.deinit(self.allocator);
                writeCallbackResponse(&connection, "400 Bad Request", "VANTARI OAuth state mismatch.");
                continue;
            }

            self.result = input;
            writeCallbackResponse(&connection, "200 OK", "VANTARI OAuth login received. Return to the terminal.");
            return;
        }
    }
};

fn requestTarget(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const start = 4;
    const relative_end = std.mem.indexOfScalar(u8, request[start..], ' ') orelse return null;
    return request[start .. start + relative_end];
}

fn writeCallbackResponse(connection: *std.net.Server.Connection, status: []const u8, body: []const u8) void {
    var response: [1024]u8 = undefined;
    const rendered = std.fmt.bufPrint(&response, "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, body.len, body }) catch return;
    connection.stream.writeAll(rendered) catch {};
}

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

test "codex oauth helper preserves PKCE and redirect state boundaries" {
    var flow = try generatePkce(std.testing.allocator);
    defer flow.deinit(std.testing.allocator);

    const url = try authorizationUrl(std.testing.allocator, flow);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, descriptor.authorize_url));
    try std.testing.expect(std.mem.indexOf(u8, url, flow.challenge) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, flow.state) != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback") != null);

    var input = try parseAuthorizationInput(
        std.testing.allocator,
        "http://localhost:1455/auth/callback?code=auth%2Fcode&state=state%2Bvalue",
    );
    defer input.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth/code", input.code);
    try std.testing.expectEqualStrings("state+value", input.state.?);

    var fragment = try parseAuthorizationInput(std.testing.allocator, "auth-code#state-token");
    defer fragment.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth-code", fragment.code);
    try std.testing.expectEqualStrings("state-token", fragment.state.?);
}

const FakeTokenTransport = struct {
    response: []const u8,
    endpoint: ?[]u8 = null,
    form: ?[]u8 = null,

    fn post(
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        endpoint: []const u8,
        form: []const u8,
    ) ![]u8 {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.endpoint) |value| allocator.free(value);
        if (self.form) |value| allocator.free(value);
        self.endpoint = try allocator.dupe(u8, endpoint);
        self.form = try allocator.dupe(u8, form);
        return allocator.dupe(u8, self.response);
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.endpoint) |value| allocator.free(value);
        if (self.form) |value| allocator.free(value);
    }
};

test "codex oauth helper exchanges and refreshes only through injected transport" {
    const response =
        "{\"access_token\":\"fake-access-token\",\"refresh_token\":\"fake-refresh-token\",\"expires_in\":3600,\"id_token\":\"fake-id-token\"}";
    var fake = FakeTokenTransport{ .response = response };
    defer fake.deinit(std.testing.allocator);

    var exchanged = try exchangeAuthorizationCode(
        std.testing.allocator,
        .{ .context = &fake, .postFn = FakeTokenTransport.post },
        "code with spaces",
        "verifier-value",
        1000,
    );
    defer exchanged.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fake-access-token", exchanged.access_token);
    try std.testing.expectEqualStrings("fake-refresh-token", exchanged.refresh_token);
    try std.testing.expectEqual(@as(i64, 3_601_000), exchanged.expires_at_ms);
    try std.testing.expect(std.mem.indexOf(u8, fake.endpoint.?, descriptor.token_url) != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.form.?, "grant_type=authorization_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.form.?, "code=code%20with%20spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.form.?, "code_verifier=verifier-value") != null);

    fake.response =
        "{\"access_token\":\"fake-refreshed-access\",\"expires_in\":1800}";
    var refreshed = try refreshAccessToken(
        std.testing.allocator,
        .{ .context = &fake, .postFn = FakeTokenTransport.post },
        "fake-refresh-token",
        5000,
    );
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fake-refreshed-access", refreshed.access_token);
    try std.testing.expectEqualStrings("fake-refresh-token", refreshed.refresh_token);
    try std.testing.expectEqual(@as(i64, 1_805_000), refreshed.expires_at_ms);
    try std.testing.expect(std.mem.indexOf(u8, fake.form.?, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.form.?, "refresh_token=fake-refresh-token") != null);
}

test "codex oauth helper extracts account and subscription claims from fake jwt" {
    const payload =
        "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct-fake\",\"chatgpt_user_id\":\"user-fake\",\"chatgpt_plan_type\":\"pro\"},\"email\":\"fake@example.invalid\"}";
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try std.testing.allocator.alloc(u8, encoded_len);
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);

    const jwt = try std.fmt.allocPrint(std.testing.allocator, "e30.{s}.e30", .{encoded});
    defer std.testing.allocator.free(jwt);
    var claims = try extractClaims(std.testing.allocator, jwt);
    defer claims.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("acct-fake", claims.account_id.?);
    try std.testing.expectEqualStrings("user-fake", claims.user_id.?);
    try std.testing.expectEqualStrings("pro", claims.plan_type.?);
    try std.testing.expectEqualStrings("fake@example.invalid", claims.email.?);
}
