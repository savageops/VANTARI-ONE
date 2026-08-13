const std = @import("std");
const provider = @import("openai_compatible.zig");
const types = @import("../../shared/types.zig");

/// Anthropic Messages API wire-protocol adapter (POST /v1/messages).
///
/// Harvested from pi-mono's `anthropic-messages` provider and the Anthropic
/// API spec. LM Studio supports this surface since 0.4.1. The Messages API
/// differs from chat completions in several key ways:
///
/// - `system` is a top-level field, not a message in the messages array
/// - `max_tokens` is required (not optional)
/// - Tool schema uses `input_schema` (not `parameters`)
/// - Tool calls are `tool_use` content blocks; results are `tool_result` blocks
/// - Streaming uses Anthropic event types (message_start, content_block_delta, etc.)
///
/// This adapter converts the kernel's canonical ChatMessage[] to/from the
/// Anthropic Messages shape. The HTTP transport is reused from
/// openai_compatible.zig.

pub const Error = provider.Error;

/// Complete via the Anthropic Messages API. Builds the /v1/messages URL,
/// constructs the Anthropic-format payload (system as top-level field,
/// max_tokens required, input_schema for tools), sends via the shared
/// transport, and parses the response.
pub fn completeWithTransportAndHooks(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: provider.Transport,
    downstream_hooks: provider.StreamHooks,
) !types.CompletionResponse {
    const url = try messagesUrl(allocator, config.openai_base_url);
    defer allocator.free(url);

    const streaming = downstream_hooks.hasHandlers();
    const payload = try buildRequestJson(allocator, config.openai_model, request, streaming);
    defer allocator.free(payload);

    var stream_context = AnthropicStreamContext{
        .allocator = allocator,
        .downstream = downstream_hooks,
    };
    const transport_hooks = if (streaming) provider.StreamHooks{
        .context = &stream_context,
        .onRawEventFn = onRawAnthropicEvent,
    } else provider.StreamHooks{};
    const headers = provider.RequestHeaders{
        .auth_scheme = config.auth_scheme,
        .anthropic_version = "2023-06-01",
        .accept = if (streaming) "text/event-stream" else "application/json",
    };

    provider.clearFailureDiagnostic();
    // The shared transport owns HTTP/SSE framing. Prism translates the
    // provider's named event payloads into the kernel's downstream hooks.
    const response_body = transport.sendWithHeaders(
        allocator,
        url,
        config.openai_api_key,
        headers,
        payload,
        transport_hooks,
    ) catch |err| switch (err) {
        // Body-only fixture transports remain valid for parser/dispatch tests.
        // The native HTTP transport takes the header-aware branch above, which
        // preserves Anthropic's x-api-key and version headers in production.
        error.HeadersUnsupported, error.StreamingHeadersUnsupported => try transport.send(
            allocator,
            url,
            config.openai_api_key,
            payload,
            transport_hooks,
        ),
        else => return err,
    };
    defer allocator.free(response_body);

    return parseCompletionResponse(allocator, config.openai_model, response_body);
}

/// Provider-specific SSE event bridge. Anthropic emits named content-block
/// events rather than the OpenAI `choices[].delta` shape.
const AnthropicStreamContext = struct {
    allocator: std.mem.Allocator,
    downstream: provider.StreamHooks,
};

/// Forward raw Anthropic events and project text/reasoning deltas into the
/// canonical event spine without teaching the shared HTTP transport Anthropic
/// payload semantics.
fn onRawAnthropicEvent(ctx: ?*anyopaque, event_json: []const u8) anyerror!void {
    const state: *AnthropicStreamContext = @ptrCast(@alignCast(ctx.?));
    try state.downstream.onRawEvent(event_json);

    var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, event_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    const event_type = root.get("type") orelse return;
    if (event_type != .string or !std.mem.eql(u8, event_type.string, "content_block_delta")) return;
    const delta = root.get("delta") orelse return;
    if (delta != .object) return;
    const delta_type = delta.object.get("type") orelse return;
    if (delta_type != .string) return;
    if (std.mem.eql(u8, delta_type.string, "text_delta")) {
        if (delta.object.get("text")) |text| if (text == .string) try state.downstream.onAssistantDelta(text.string);
    } else if (std.mem.eql(u8, delta_type.string, "thinking_delta")) {
        if (delta.object.get("thinking")) |thinking| if (thinking == .string) try state.downstream.onReasoningDelta(thinking.string);
    }
}

/// Resolve the /messages URL for a provider base_url (Anthropic surface).
pub fn messagesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var trimmed = std.mem.trimRight(u8, base_url, "/");
    // Strip known suffixes so any configured base_url works.
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        trimmed = trimmed[0 .. trimmed.len - "/chat/completions".len];
    }
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        trimmed = trimmed[0 .. trimmed.len - "/v1".len];
    }
    // Anthropic uses /v1/messages
    return std.fmt.allocPrint(allocator, "{s}/v1/messages", .{trimmed});
}

/// Build the Anthropic Messages API request payload from canonical ChatMessage[].
pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: []const u8,
    request: types.CompletionRequest,
    stream: bool,
) ![]u8 {
    var payload = std.array_list.Managed(u8).init(allocator);
    errdefer payload.deinit();
    const writer = payload.writer();

    try writer.writeAll("{\"model\":");
    try writeJsonValue(writer, model);

    // Extract system messages — Anthropic puts system as a top-level field.
    var system_text = std.array_list.Managed(u8).init(allocator);
    defer system_text.deinit();
    for (request.messages) |message| {
        if (message.role == .system) {
            if (message.content) |content| {
                if (system_text.items.len > 0) try system_text.append('\n');
                try system_text.appendSlice(content);
            }
        }
    }
    if (system_text.items.len > 0) {
        try writer.writeAll(",\"system\":");
        try writeJsonValue(writer, system_text.items);
    }

    // Build messages array (non-system messages only).
    try writer.writeAll(",\"messages\":[");
    var first = true;
    for (request.messages) |message| {
        if (message.role == .system) continue;

        if (!first) try writer.writeAll(",");
        first = false;

        switch (message.role) {
            .user => {
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                try writeJsonValue(writer, message.content orelse "");
                try writer.writeAll("}");
            },
            .assistant => {
                if (message.tool_calls.len > 0) {
                    // Assistant with tool calls: content array with text + tool_use blocks.
                    try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
                    var block_first = true;
                    if (message.content) |content| {
                        if (content.len > 0) {
                            try writer.writeAll("{\"type\":\"text\",\"text\":");
                            try writeJsonValue(writer, content);
                            try writer.writeAll("}");
                            block_first = false;
                        }
                    }
                    for (message.tool_calls) |tool_call| {
                        if (!block_first) try writer.writeAll(",");
                        block_first = false;
                        try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                        try writeJsonValue(writer, tool_call.id);
                        try writer.writeAll(",\"name\":");
                        try writeJsonValue(writer, tool_call.name);
                        try writer.writeAll(",\"input\":");
                        // Anthropic expects the parsed object, not a string.
                        try writer.writeAll(tool_call.arguments_json);
                        try writer.writeAll("}");
                    }
                    try writer.writeAll("]}");
                } else {
                    try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                    try writeJsonValue(writer, message.content orelse "");
                    try writer.writeAll("}");
                }
            },
            .tool => {
                // Tool results: user role with tool_result content block.
                try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
                try writeJsonValue(writer, message.tool_call_id orelse "");
                try writer.writeAll(",\"content\":");
                try writeJsonValue(writer, message.content orelse "");
                try writer.writeAll("}]}");
            },
            .system => unreachable,
        }
    }
    try writer.writeAll("]");

    // max_tokens is required in the Anthropic API.
    try writer.writeAll(",\"max_tokens\":8192");
    try writer.writeAll(",\"temperature\":0");
    if (stream) try writer.writeAll(",\"stream\":true");

    // Tools — Anthropic uses input_schema (not parameters) and a flat shape.
    if (request.tool_definitions.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tool_definitions, 0..) |tool_def, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try writeJsonValue(writer, tool_def.name);
            try writer.writeAll(",\"description\":");
            try writeJsonValue(writer, tool_def.description);
            try writer.writeAll(",\"input_schema\":");
            try writer.writeAll(tool_def.parameters_json);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
    return payload.toOwnedSlice();
}

/// Parse an Anthropic Messages API response into the canonical CompletionResponse.
pub fn parseCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    if (looksLikeEventStream(response_body)) {
        return parseStreamResponse(allocator, configured_model, response_body);
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.MalformedHttpResponse;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return Error.MalformedHttpResponse,
    };

    var content_buf = std.array_list.Managed(u8).init(allocator);
    errdefer content_buf.deinit();
    var tool_calls = std.array_list.Managed(types.ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |tc| tc.deinit(allocator);
        tool_calls.deinit();
    }

    // Anthropic response: { content: [{type:"text",text:...}, {type:"tool_use",id:...,name:...,input:{...}}] }
    if (root.get("content")) |content_value| {
        if (content_value == .array) {
            for (content_value.array.items) |block| {
                if (block != .object) continue;
                const block_type = block.object.get("type") orelse continue;
                if (block_type != .string) continue;

                if (std.mem.eql(u8, block_type.string, "text")) {
                    if (block.object.get("text")) |text| {
                        if (text == .string) try content_buf.appendSlice(text.string);
                    }
                } else if (std.mem.eql(u8, block_type.string, "tool_use")) {
                    const id = getString(block.object, "id") orelse "call-generated";
                    const name = getString(block.object, "name") orelse continue;
                    // input is a JSON object — serialize it back to a string for arguments_json.
                    const input = if (block.object.get("input")) |i| i else std.json.Value{ .null = {} };
                    const args_str = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(input, .{})});
                    defer allocator.free(args_str);
                    tool_calls.append(.{
                        .id = try allocator.dupe(u8, id),
                        .name = try allocator.dupe(u8, name),
                        .arguments_json = try allocator.dupe(u8, args_str),
                    }) catch return Error.MalformedHttpResponse;
                }
            }
        }
    }

    const model_str = if (root.get("model")) |m| (if (m == .string) m.string else configured_model) else configured_model;

    var usage: types.Usage = .{};
    captureAnthropicUsage(root, &usage);
    usage.reconcile();

    return .{
        .model = try allocator.dupe(u8, model_str),
        .content = if (content_buf.items.len > 0) try content_buf.toOwnedSlice() else null,
        .tool_calls = try tool_calls.toOwnedSlice(),
        .usage = usage,
    };
}

/// Extract an Anthropic Messages usage object into the canonical Usage
/// contract. `cache_creation_input_tokens` folds into prompt (Anthropic bills
/// cache creation at the input rate); `cache_read_input_tokens` becomes the
/// cached bucket. Missing usage → fields unchanged (zeros by caller default).
/// Why: the cost model must work for every wire protocol VANTARI speaks.
/// Evidence: non-stream parse + message_start/message_delta stream events.
fn captureAnthropicUsage(root: std.json.ObjectMap, usage: *types.Usage) void {
    const usage_value = root.get("usage") orelse return;
    if (usage_value != .object) return;
    const u = usage_value.object;
    if (getU64(u, "input_tokens")) |value| usage.prompt_tokens = value;
    if (getU64(u, "output_tokens")) |value| usage.completion_tokens = value;
    if (getU64(u, "cache_read_input_tokens")) |value| usage.cached_tokens = value;
    if (getU64(u, "cache_creation_input_tokens")) |value| usage.prompt_tokens += value;
}

fn getU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = obj.get(key) orelse return null;
    return if (value == .integer) @intCast(value.integer) else null;
}

fn parseStreamResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    var content = std.array_list.Managed(u8).init(allocator);
    errdefer content.deinit();
    var tool_calls = std.array_list.Managed(types.ToolCall).init(allocator);
    errdefer {
        for (tool_calls.items) |tc| tc.deinit(allocator);
        tool_calls.deinit();
    }

    // Accumulate tool_use blocks from content_block_start/delta events.
    var tc_accum = std.array_list.Managed(TcAccumulator).init(allocator);
    defer {
        for (tc_accum.items) |*a| a.deinit(allocator);
        tc_accum.deinit();
    }

    var cursor: usize = 0;
    var usage: types.Usage = .{};
    while (cursor < response_body.len) {
        const remaining = response_body[cursor..];
        if (findSseBoundary(remaining)) |boundary| {
            try parseAnthropicSseEvent(allocator, remaining[0..boundary.event_end], &content, &tc_accum, &usage);
            cursor += boundary.remove_len;
            continue;
        }
        try parseAnthropicSseEvent(allocator, remaining, &content, &tc_accum, &usage);
        break;
    }
    usage.reconcile();

    for (tc_accum.items) |acc| {
        if (acc.name.items.len == 0) continue;
        tool_calls.append(.{
            .id = if (acc.id.items.len > 0)
                try allocator.dupe(u8, acc.id.items)
            else
                try std.fmt.allocPrint(allocator, "anthropic_call_{d}", .{tool_calls.items.len}),
            .name = try allocator.dupe(u8, acc.name.items),
            .arguments_json = try allocator.dupe(u8, acc.input.items),
        }) catch return Error.MalformedHttpResponse;
    }

    return .{
        .model = try allocator.dupe(u8, configured_model),
        .content = if (content.items.len > 0) try content.toOwnedSlice() else null,
        .tool_calls = try tool_calls.toOwnedSlice(),
        .usage = usage,
    };
}

const TcAccumulator = struct {
    id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    input: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) TcAccumulator {
        return .{
            .id = std.array_list.Managed(u8).init(allocator),
            .name = std.array_list.Managed(u8).init(allocator),
            .input = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *TcAccumulator, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.id.deinit();
        self.name.deinit();
        self.input.deinit();
    }
};

fn parseAnthropicSseEvent(
    allocator: std.mem.Allocator,
    event: []const u8,
    content: *std.array_list.Managed(u8),
    tc_accum: *std.array_list.Managed(TcAccumulator),
    usage: *types.Usage,
) !void {
    var event_data = std.array_list.Managed(u8).init(allocator);
    defer event_data.deinit();

    var lines = std.mem.splitScalar(u8, event, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) return;
        if (event_data.items.len > 0) try event_data.append('\n');
        try event_data.appendSlice(data);
    }

    if (event_data.items.len == 0) return;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_data.items, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return,
    };

    const event_type = if (root.get("type")) |t| (if (t == .string) t.string else "") else "";

    // Usage evidence: message_start carries input + cache tokens on the
    // message object; message_delta carries the terminal output_tokens count.
    if (std.mem.eql(u8, event_type, "message_start")) {
        if (root.get("message")) |message| {
            if (message == .object) captureAnthropicUsage(message.object, usage);
        }
    }
    if (std.mem.eql(u8, event_type, "message_delta")) {
        captureAnthropicUsage(root, usage);
    }

    // Text delta.
    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        if (root.get("delta")) |delta| {
            if (delta == .object) {
                const delta_type = if (delta.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    if (delta.object.get("text")) |text| {
                        if (text == .string) try content.appendSlice(text.string);
                    }
                }
            }
        }
    }

    // Tool use block start — captures id and name.
    if (std.mem.eql(u8, event_type, "content_block_start")) {
        if (root.get("index")) |index_val| {
            const idx: usize = if (index_val == .integer) @intCast(index_val.integer) else 0;
            if (root.get("content_block")) |block| {
                if (block == .object) {
                    const bt = if (block.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (std.mem.eql(u8, bt, "tool_use")) {
                        while (tc_accum.items.len <= idx) {
                            try tc_accum.append(TcAccumulator.init(allocator));
                        }
                        var acc = &tc_accum.items[idx];
                        if (block.object.get("id")) |id| {
                            if (id == .string) try acc.id.appendSlice(id.string);
                        }
                        if (block.object.get("name")) |name| {
                            if (name == .string) try acc.name.appendSlice(name.string);
                        }
                    }
                }
            }
        }
    }

    // Tool use input delta — accumulates the JSON input.
    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        if (root.get("index")) |index_val| {
            const idx: usize = if (index_val == .integer) @intCast(index_val.integer) else 0;
            if (root.get("delta")) |delta| {
                if (delta == .object) {
                    const dt = if (delta.object.get("type")) |t| (if (t == .string) t.string else "") else "";
                    if (std.mem.eql(u8, dt, "input_json_delta")) {
                        if (idx < tc_accum.items.len) {
                            if (delta.object.get("partial_json")) |pj| {
                                if (pj == .string) {
                                    try tc_accum.items[idx].input.appendSlice(pj.string);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn looksLikeEventStream(body: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, body, " \t\r\n"), "data:");
}

const SseBoundary = struct {
    event_end: usize,
    remove_len: usize,
};

fn findSseBoundary(buffer: []const u8) ?SseBoundary {
    const lf = std.mem.indexOf(u8, buffer, "\n\n");
    const crlf = std.mem.indexOf(u8, buffer, "\r\n\r\n");
    if (lf == null and crlf == null) return null;
    if (lf) |lf_index| {
        if (crlf == null or lf_index < crlf.?) return .{ .event_end = lf_index, .remove_len = lf_index + 2 };
    }
    const crlf_index = crlf.?;
    return .{ .event_end = crlf_index, .remove_len = crlf_index + 4 };
}

fn writeJsonValue(writer: anytype, value: anytype) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

test "anthropic buildRequestJson extracts system to top-level field" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = @constCast("You are helpful.") },
        .{ .role = .user, .content = @constCast("Hello") },
    };
    const payload = try buildRequestJson(std.testing.allocator, "claude-test", .{
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"system\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "You are helpful.") != null);
    // System should NOT appear in messages array.
    // The messages array should only contain the user message.
    const messages_start = std.mem.indexOf(u8, payload, "\"messages\":[").?;
    const messages_section = payload[messages_start..];
    try std.testing.expect(std.mem.indexOf(u8, messages_section, "\"role\":\"user\"") != null);
}

test "anthropic buildRequestJson includes required max_tokens" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = @constCast("Hi") },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"max_tokens\":") != null);
}

test "anthropic buildRequestJson converts tool result to tool_result block" {
    const messages = [_]types.ChatMessage{
        .{
            .role = .tool,
            .content = @constCast("42"),
            .tool_call_id = @constCast("toolu_1"),
        },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_use_id\":\"toolu_1\"") != null);
}

test "anthropic buildRequestJson uses input_schema for tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = @constCast("Read README.md") },
    };
    const tool_defs = [_]types.ToolDefinition{
        .{
            .name = "read_file",
            .description = "Read a file.",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
            .review_risk = .read_only,
        },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
        .tool_definitions = tool_defs[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input_schema\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"read_file\"") != null);
}

test "anthropic parseCompletionResponse extracts text content blocks" {
    const body =
        \\{"model":"claude-test","content":[
        \\  {"type":"text","text":"Hello from Anthropic"}
        \\]}
    ;
    const response = try parseCompletionResponse(std.testing.allocator, "claude-test", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello from Anthropic", response.content.?);
}

test "anthropic parseCompletionResponse extracts tool_use blocks as tool calls" {
    const body =
        \\{"model":"claude-test","content":[
        \\  {"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"README.md"}}
        \\]}
    ;
    const response = try parseCompletionResponse(std.testing.allocator, "claude-test", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("toolu_1", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expect(std.mem.indexOf(u8, response.tool_calls[0].arguments_json, "README.md") != null);
}

test "messagesUrl resolves correctly" {
    const url1 = try messagesUrl(std.testing.allocator, "http://localhost:1234/v1");
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("http://localhost:1234/v1/messages", url1);

    const url2 = try messagesUrl(std.testing.allocator, "https://api.anthropic.com");
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", url2);
}
