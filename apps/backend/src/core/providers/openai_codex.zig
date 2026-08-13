const std = @import("std");
const provider = @import("openai_compatible.zig");
const responses = @import("responses.zig");
const types = @import("../../shared/types.zig");

/// Explicit ChatGPT-subscription transport. This is not an OpenAI-compatible
/// `/v1/chat/completions` provider: Codex uses `/codex/responses`, account
/// metadata, and Responses/SSE events.
pub const Error = error{
    UnsupportedProviderAuth,
    MissingAccountId,
    InvalidAccountId,
    AuthExpired,
    AuthRejected,
    EntitlementRequired,
    RateLimited,
    ResponseFailed,
    BadStatus,
    MalformedResponse,
    MissingHeaderTransport,
    StreamingTransportUnsupported,
    InvalidRequest,
};

pub const default_base_url = "https://chatgpt.com/backend-api";
pub const originator = "codex_cli_rs";

pub fn complete(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
) !types.CompletionResponse {
    return completeWithTransportAndHooks(allocator, config, request, .{
        .context = null,
        .sendFn = provider.httpSend,
        .sendWithHeadersFn = provider.httpSendWithHeaders,
        .streamWithHeadersFn = provider.httpSendStreamingWithHeaders,
    }, .{});
}

pub fn completeWithTransportAndHooks(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: provider.Transport,
    downstream_hooks: provider.StreamHooks,
) !types.CompletionResponse {
    const provider_id = config.auth_provider orelse return Error.UnsupportedProviderAuth;
    if (config.auth_type != .oauth or !std.mem.eql(u8, provider_id, "openai-codex")) {
        return Error.UnsupportedProviderAuth;
    }

    const account_id = config.auth_account_id orelse return Error.MissingAccountId;
    if (!isSafeHeaderValue(account_id)) return Error.InvalidAccountId;
    if (config.auth_expires_at_ms) |expires_at_ms| {
        if (expires_at_ms <= std.time.milliTimestamp()) return Error.AuthExpired;
    }

    const url = try responsesUrl(allocator, config.openai_base_url);
    defer allocator.free(url);
    const payload = try buildRequestJson(allocator, config.openai_model, request, config.effort);
    defer allocator.free(payload);

    const headers = provider.RequestHeaders{
        .account_id = account_id,
        .originator = originator,
        .openai_beta = "responses=experimental",
        .accept = "text/event-stream",
    };

    var stream_context = CodexStreamContext{
        .allocator = allocator,
        .downstream = downstream_hooks,
    };
    const transport_hooks = if (downstream_hooks.hasHandlers()) provider.StreamHooks{
        .context = &stream_context,
        .onRawEventFn = onRawEvent,
    } else provider.StreamHooks{};

    provider.clearFailureDiagnostic();
    const response_body = transport.sendWithHeaders(
        allocator,
        url,
        config.openai_api_key,
        headers,
        payload,
        transport_hooks,
    ) catch |err| return mapTransportError(err);
    defer allocator.free(response_body);

    return parseCompletionResponse(allocator, config.openai_model, response_body);
}

/// Resolve the official Codex backend endpoint. A configured base URL may
/// already include `/codex` or `/codex/responses` for local test fixtures.
pub fn responsesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const raw = if (std.mem.trim(u8, base_url, " \t\r\n").len == 0) default_base_url else base_url;
    const trimmed = std.mem.trimRight(u8, raw, "/");
    if (std.mem.endsWith(u8, trimmed, "/codex/responses")) return allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, "/codex")) return std.fmt.allocPrint(allocator, "{s}/responses", .{trimmed});
    return std.fmt.allocPrint(allocator, "{s}/codex/responses", .{trimmed});
}

/// Build the Codex Responses request from the canonical VANTARI request.
/// Message/tool conversion stays in the Responses adapter; Codex owns only
/// the provider-specific fields and never routes through chat completions.
pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: []const u8,
    request: types.CompletionRequest,
    effort: []const u8,
) ![]u8 {
    const base = try responses.buildRequestJson(allocator, model, request, true);
    defer allocator.free(base);
    if (base.len < 2 or base[base.len - 1] != '}') return Error.InvalidRequest;

    var payload = std.array_list.Managed(u8).init(allocator);
    errdefer payload.deinit();
    try payload.appendSlice(base[0 .. base.len - 1]);
    try payload.appendSlice(",\"store\":false,\"include\":[\"reasoning.encrypted_content\"]");
    if (effort.len > 0) {
        try payload.appendSlice(",\"reasoning\":{\"effort\":");
        try writeJsonValue(payload.writer(), effort);
        try payload.append('}');
    }
    try payload.append('}');
    return payload.toOwnedSlice();
}

/// Parse the Codex Responses body at the provider boundary. The canonical
/// Responses parser handles message/tool/usage projection; Codex adds only
/// provider-specific failure classification.
pub fn parseCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    if (containsIgnoreCase(response_body, "usage_limit_reached") or
        containsIgnoreCase(response_body, "usage_not_included") or
        containsIgnoreCase(response_body, "entitlement"))
    {
        return Error.EntitlementRequired;
    }
    if (containsIgnoreCase(response_body, "invalid_token") or
        containsIgnoreCase(response_body, "token expired") or
        containsIgnoreCase(response_body, "unauthorized"))
    {
        return Error.AuthRejected;
    }
    if (containsIgnoreCase(response_body, "response.failed") or
        containsIgnoreCase(response_body, "\"type\":\"error\""))
    {
        return Error.ResponseFailed;
    }

    return responses.parseCompletionResponse(allocator, configured_model, response_body) catch |err| {
        if (err == provider.Error.MalformedHttpResponse or err == provider.Error.MalformedStreamResponse) {
            return Error.MalformedResponse;
        }
        return err;
    };
}

fn mapTransportError(err: anyerror) anyerror {
    if (err == provider.Error.ContextWindowExceeded) return err;
    if (err == provider.Error.BadStatus) {
        const diagnostic = provider.failureDiagnosticForError(err);
        if (containsIgnoreCase(diagnostic, "status=401") or containsIgnoreCase(diagnostic, "status=403")) {
            return Error.AuthRejected;
        }
        if (containsIgnoreCase(diagnostic, "status=429")) return Error.RateLimited;
        if (containsIgnoreCase(diagnostic, "usage_limit") or containsIgnoreCase(diagnostic, "entitlement")) {
            return Error.EntitlementRequired;
        }
        return Error.BadStatus;
    }
    if (err == error.HeadersUnsupported) return Error.MissingHeaderTransport;
    if (err == error.StreamingHeadersUnsupported) return Error.StreamingTransportUnsupported;
    return err;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn isSafeHeaderValue(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |char| {
        if (char == '\r' or char == '\n' or char == 0) return false;
    }
    return true;
}

fn writeJsonValue(writer: anytype, value: []const u8) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

const CodexStreamContext = struct {
    allocator: std.mem.Allocator,
    downstream: provider.StreamHooks,
};

fn onRawEvent(ctx: ?*anyopaque, event_json: []const u8) anyerror!void {
    const stream: *CodexStreamContext = @ptrCast(@alignCast(ctx.?));
    var parsed = std.json.parseFromSlice(std.json.Value, stream.allocator, event_json, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    const event_type = root.get("type") orelse return;
    if (event_type != .string) return;
    const delta = root.get("delta") orelse return;
    if (delta != .string) return;

    if (std.mem.eql(u8, event_type.string, "response.output_text.delta") or
        std.mem.eql(u8, event_type.string, "response.refusal.delta"))
    {
        try stream.downstream.onAssistantDelta(delta.string);
    } else if (std.mem.eql(u8, event_type.string, "response.reasoning_summary_text.delta")) {
        try stream.downstream.onReasoningDelta(delta.string);
    }
}

const Capture = struct {
    url: ?[]u8 = null,
    token: ?[]u8 = null,
    account_id: ?[]u8 = null,
    originator_header: ?[]u8 = null,
    payload: ?[]u8 = null,
    streamed: bool = false,

    fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        if (self.url) |value| allocator.free(value);
        if (self.token) |value| allocator.free(value);
        if (self.account_id) |value| allocator.free(value);
        if (self.originator_header) |value| allocator.free(value);
        if (self.payload) |value| allocator.free(value);
    }
};

const DeltaSink = struct {
    delta: ?[]u8 = null,

    fn deinit(self: *DeltaSink, allocator: std.mem.Allocator) void {
        if (self.delta) |value| allocator.free(value);
    }
};

fn captureRequest(
    capture: *Capture,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    headers: provider.RequestHeaders,
    payload: []const u8,
) !void {
    capture.url = try allocator.dupe(u8, url);
    capture.token = try allocator.dupe(u8, api_key);
    capture.account_id = if (headers.account_id) |value| try allocator.dupe(u8, value) else null;
    capture.originator_header = if (headers.originator) |value| try allocator.dupe(u8, value) else null;
    capture.payload = try allocator.dupe(u8, payload);
}

fn captureSend(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    headers: provider.RequestHeaders,
    payload: []const u8,
) anyerror![]u8 {
    const capture: *Capture = @ptrCast(@alignCast(ctx.?));
    try captureRequest(capture, allocator, url, api_key, headers, payload);
    return allocator.dupe(u8,
        "{\"model\":\"gpt-5.4-mini\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}",
    );
}

fn captureStream(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    headers: provider.RequestHeaders,
    payload: []const u8,
    hooks: provider.StreamHooks,
) anyerror![]u8 {
    const capture: *Capture = @ptrCast(@alignCast(ctx.?));
    capture.streamed = true;
    try captureRequest(capture, allocator, url, api_key, headers, payload);
    try hooks.onRawEvent("{\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}");
    return allocator.dupe(u8,
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"ok\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"model\":\"gpt-5.4-mini\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n",
    );
}

fn captureDelta(ctx: ?*anyopaque, delta: []const u8) anyerror!void {
    const sink: *DeltaSink = @ptrCast(@alignCast(ctx.?));
    const allocator = std.testing.allocator;
    if (sink.delta) |value| allocator.free(value);
    sink.delta = try allocator.dupe(u8, delta);
}

fn makeOAuthConfig(allocator: std.mem.Allocator, expires_at_ms: ?i64, account_id: ?[]const u8) !types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "https://chatgpt.com/backend-api"),
        .openai_api_key = try allocator.dupe(u8, "oauth-access-token"),
        .openai_model = try allocator.dupe(u8, "gpt-5.4-mini"),
        .auth_provider = try allocator.dupe(u8, "openai-codex"),
        .auth_type = .oauth,
        .auth_account_id = if (account_id) |value| try allocator.dupe(u8, value) else null,
        .auth_expires_at_ms = expires_at_ms,
        .max_steps = 8,
        .workspace_root = try allocator.dupe(u8, "."),
        .effort = "high",
    };
}

test "codex responsesUrl owns the explicit backend suffix" {
    const url1 = try responsesUrl(std.testing.allocator, "https://chatgpt.com/backend-api");
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", url1);

    const url2 = try responsesUrl(std.testing.allocator, "https://fixture.test/codex");
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://fixture.test/codex/responses", url2);

    const url3 = try responsesUrl(std.testing.allocator, "https://fixture.test/codex/responses");
    defer std.testing.allocator.free(url3);
    try std.testing.expectEqualStrings("https://fixture.test/codex/responses", url3);
}

test "codex request uses Responses stream and provider-owned fields" {
    const request = types.CompletionRequest{ .messages = &.{} };
    const payload = try buildRequestJson(std.testing.allocator, "gpt-5.4-mini", request, "high");
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "chat/completions") == null);
}

test "codex transport adds account headers and forwards Responses deltas" {
    var config = try makeOAuthConfig(std.testing.allocator, std.time.milliTimestamp() + 60_000, "acct-fixture");
    defer config.deinit(std.testing.allocator);
    var capture = Capture{};
    defer capture.deinit(std.testing.allocator);
    var sink = DeltaSink{};
    defer sink.deinit(std.testing.allocator);

    const completion = try completeWithTransportAndHooks(std.testing.allocator, config, .{
        .messages = &.{},
    }, .{
        .context = &capture,
        .sendFn = provider.httpSend,
        .sendWithHeadersFn = captureSend,
        .streamWithHeadersFn = captureStream,
    }, .{
        .context = &sink,
        .onAssistantDeltaFn = captureDelta,
    });
    defer completion.deinit(std.testing.allocator);

    try std.testing.expect(capture.streamed);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", capture.url.?);
    try std.testing.expectEqualStrings("oauth-access-token", capture.token.?);
    try std.testing.expectEqualStrings("acct-fixture", capture.account_id.?);
    try std.testing.expectEqualStrings(originator, capture.originator_header.?);
    try std.testing.expectEqualStrings("ok", sink.delta.?);
    try std.testing.expectEqualStrings("ok", completion.content.?);
    try std.testing.expectEqual(@as(u64, 2), completion.usage.total_tokens);
}

test "codex rejects missing or expired subscription auth before transport" {
    var missing_account = try makeOAuthConfig(std.testing.allocator, std.time.milliTimestamp() + 60_000, null);
    defer missing_account.deinit(std.testing.allocator);
    try std.testing.expectError(Error.MissingAccountId, completeWithTransportAndHooks(
        std.testing.allocator,
        missing_account,
        .{ .messages = &.{} },
        .{ .context = null, .sendFn = provider.httpSend },
        .{},
    ));

    var expired = try makeOAuthConfig(std.testing.allocator, std.time.milliTimestamp() - 1, "acct-fixture");
    defer expired.deinit(std.testing.allocator);
    try std.testing.expectError(Error.AuthExpired, completeWithTransportAndHooks(
        std.testing.allocator,
        expired,
        .{ .messages = &.{} },
        .{ .context = null, .sendFn = provider.httpSend },
        .{},
    ));
}

test "codex parser maps Responses function calls into the canonical response" {
    const body =
        \\{"model":"gpt-5.4-mini","output":[
        \\  {"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"README.md\"}"}
        \\]}
    ;
    const completion = try parseCompletionResponse(std.testing.allocator, "gpt-5.4-mini", body);
    defer completion.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
}
