const std = @import("std");
const provider = @import("openai_compatible.zig");
const responses = @import("responses.zig");
const anthropic = @import("anthropic.zig");
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
    return switch (config.wire_api) {
        .chat_completions => provider.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
        .responses => responses.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
        .anthropic_messages => anthropic.completeWithTransportAndHooks(allocator, config, request, transport, stream_hooks),
    };
}
