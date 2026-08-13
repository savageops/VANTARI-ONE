const std = @import("std");
const provider = @import("openai_compatible.zig");
const openai_codex = @import("openai_codex.zig");
const responses = @import("responses.zig");
const anthropic = @import("anthropic.zig");
const compat = @import("compat.zig");
const types = @import("../../shared/types.zig");

/// Wire-protocol dispatch layer. Switches on config.wire_api to route the
/// provider turn to the correct adapter. Each adapter builds its own URL,
/// request payload, and response parser for its wire format; the HTTP
/// transport is shared from openai_compatible.zig.
///
/// Harvested from Codex's `wire_api` config switch and pi-mono's `Api` enum
/// dispatch table. One transport, three wire-protocol shapes, one canonical
/// CompletionResponse at the call site.

pub const Error = provider.Error;
pub const Transport = provider.Transport;
pub const StreamHooks = provider.StreamHooks;
pub const clearFailureDiagnostic = provider.clearFailureDiagnostic;
pub const failureDiagnosticForError = provider.failureDiagnosticForError;

/// Dispatch a completion request to the wire-protocol adapter selected by
/// config.wire_api. This is the single entry point the loop calls — it
/// replaces direct calls to provider.completeWithTransportAndHooks.
pub fn completeWithTransportAndHooks(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: Transport,
    stream_hooks: StreamHooks,
) !types.CompletionResponse {
    if (config.auth_type == .oauth) {
        const provider_id = config.auth_provider orelse return openai_codex.Error.UnsupportedProviderAuth;
        if (!std.mem.eql(u8, provider_id, "openai-codex")) return openai_codex.Error.UnsupportedProviderAuth;
        return openai_codex.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks);
    }

    // Config default `wire_api: "auto"` resolves here against the base URL.
    // Explicit config values (chat_completions/responses/anthropic_messages)
    // always beat detection — prime's provider-over-URL precedence rule,
    // adapted to VANTARI's config-first doctrine (compat.zig).
    const wire_api: types.WireApi =
        if (config.wire_api == .auto) compat.detectWireApi(config.openai_base_url) else config.wire_api;
    return switch (wire_api) {
        .chat_completions => provider.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
        .responses => responses.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
        .anthropic_messages => anthropic.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
        .auto => unreachable, // resolved above
    };
}

const CodexDispatchCapture = struct {
    url: ?[]u8 = null,
    payload: ?[]u8 = null,

    fn deinit(self: *CodexDispatchCapture, allocator: std.mem.Allocator) void {
        if (self.url) |value| allocator.free(value);
        if (self.payload) |value| allocator.free(value);
    }
};

fn captureCodexDispatch(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    _: []const u8,
    _: provider.RequestHeaders,
    payload: []const u8,
) anyerror![]u8 {
    const capture: *CodexDispatchCapture = @ptrCast(@alignCast(ctx.?));
    capture.url = try allocator.dupe(u8, url);
    capture.payload = try allocator.dupe(u8, payload);
    return allocator.dupe(u8, "{\"model\":\"gpt-5.4-mini\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}]}");
}

test "dispatch routes OAuth Codex records away from OpenAI-compatible wire" {
    var config = types.Config{
        .openai_base_url = try std.testing.allocator.dupe(u8, "https://chatgpt.com/backend-api"),
        .openai_api_key = try std.testing.allocator.dupe(u8, "oauth-access-token"),
        .openai_model = try std.testing.allocator.dupe(u8, "gpt-5.4-mini"),
        .auth_provider = try std.testing.allocator.dupe(u8, "openai-codex"),
        .auth_type = .oauth,
        .auth_account_id = try std.testing.allocator.dupe(u8, "acct-fixture"),
        .auth_expires_at_ms = std.time.milliTimestamp() + 60_000,
        .max_steps = 8,
        .workspace_root = try std.testing.allocator.dupe(u8, "."),
    };
    defer config.deinit(std.testing.allocator);
    var capture = CodexDispatchCapture{};
    defer capture.deinit(std.testing.allocator);

    const completion = try completeWithTransportAndHooks(std.testing.allocator, config, .{
        .messages = &.{},
    }, .{
        .context = &capture,
        .sendFn = provider.httpSend,
        .sendWithHeadersFn = captureCodexDispatch,
    }, .{});
    defer completion.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", capture.url.?);
    try std.testing.expect(std.mem.indexOf(u8, capture.payload.?, "chat/completions") == null);
    try std.testing.expectEqualStrings("ok", completion.content.?);
}
