const std = @import("std");
const provider = @import("openai_compatible.zig");
const types = @import("../../shared/types.zig");

/// OpenAI Responses API wire-protocol adapter (POST /v1/responses).
///
/// Harvested from pi-mono's `openai-responses` provider and the OpenAI
/// Responses API spec. LM Studio supports this surface since 0.3.29. The
/// Responses API uses `input` (an array of items) instead of `messages`, and
/// tool calls are `function_call` / `function_call_output` items rather than
/// the chat-completions tool_calls envelope.
///
/// This adapter converts the kernel's canonical ChatMessage[] to/from the
/// Responses API input-item shape. The HTTP transport is reused from
/// openai_compatible.zig — only the URL, payload shape, and response parser
/// differ.

pub const Error = provider.Error;

/// Complete via the Responses API. Builds the /v1/responses URL, constructs
/// the input-item payload, sends via the shared transport, and parses the
/// response. Reuses the streaming SSE infrastructure from the chat-completions
/// adapter when stream hooks are present.
pub fn completeWithTransportAndHooks(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: provider.Transport,
    downstream_hooks: provider.StreamHooks,
) !types.CompletionResponse {
    const url = try responsesUrl(allocator, config.openai_base_url);
    defer allocator.free(url);

    const streaming = downstream_hooks.hasHandlers();
    const payload = try buildRequestJson(allocator, config.openai_model, request, streaming);
    defer allocator.free(payload);

    var stream_context = ResponsesStreamContext{
        .allocator = allocator,
        .downstream = downstream_hooks,
    };
    const transport_hooks = if (streaming) provider.StreamHooks{
        .context = &stream_context,
        .onRawEventFn = onRawResponsesEvent,
        .shouldAbortFn = shouldAbortResponsesStream,
    } else provider.StreamHooks{};
    const headers = provider.RequestHeaders{
        .auth_scheme = config.auth_scheme,
        .accept = if (streaming) "text/event-stream" else "application/json",
    };

    provider.clearFailureDiagnostic();
    const response_body = transport.sendWithHeaders(
        allocator,
        url,
        config.openai_api_key,
        headers,
        payload,
        transport_hooks,
    ) catch |err| switch (err) {
        // Body-only fixture transports remain valid for parser/dispatch tests;
        // the native transport still enforces the selected header contract.
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

/// Provider-specific Responses SSE bridge. The shared transport owns framing;
/// this adapter translates `response.output_text.delta` into kernel deltas.
const ResponsesStreamContext = struct {
    allocator: std.mem.Allocator,
    downstream: provider.StreamHooks,
};

fn shouldAbortResponsesStream(ctx: ?*anyopaque) bool {
    const state: *ResponsesStreamContext = @ptrCast(@alignCast(ctx.?));
    return state.downstream.shouldAbort();
}

/// Forward raw Responses events and project text/reasoning deltas without
/// adding a second streaming transport or event owner.
fn onRawResponsesEvent(ctx: ?*anyopaque, event_json: []const u8) anyerror!void {
    const state: *ResponsesStreamContext = @ptrCast(@alignCast(ctx.?));
    try state.downstream.onRawEvent(event_json);

    var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, event_json, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;
    const event_type = root.get("type") orelse return;
    if (event_type != .string) return;
    const delta = root.get("delta") orelse return;
    if (delta != .string) return;
    if (std.mem.eql(u8, event_type.string, "response.output_text.delta") or
        std.mem.eql(u8, event_type.string, "response.output_text.added"))
    {
        try state.downstream.onAssistantDelta(delta.string);
    } else if (std.mem.indexOf(u8, event_type.string, "reasoning") != null) {
        try state.downstream.onReasoningDelta(delta.string);
    }
}

/// Resolve the /responses URL for a provider base_url.
pub fn responsesUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    var base = trimmed;
    // Strip /chat/completions if present so a base_url configured for the
    // chat adapter works for responses without reconfiguration.
    if (std.mem.endsWith(u8, base, "/chat/completions")) {
        base = base[0 .. base.len - "/chat/completions".len];
    }
    // Also strip a trailing /v1 if the base already includes it, since we
    // add /v1/responses ourselves when no version segment is present.
    if (std.mem.endsWith(u8, base, "/v1")) {
        base = base[0 .. base.len - "/v1".len];
    }
    const suffix = if (hasVersionSegment(base)) "/responses" else "/v1/responses";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

fn hasVersionSegment(base_url: []const u8) bool {
    const slash_index = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse return false;
    const segment = base_url[slash_index + 1 ..];
    if (segment.len < 2 or segment[0] != 'v') return false;
    for (segment[1..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

/// Build the Responses API request payload from canonical ChatMessage[].
/// The Responses API uses `input` (array of items) instead of `messages`.
/// Each item is a typed object: message, function_call, or function_call_output.
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
    try writer.writeAll(",\"input\":[");

    var first = true;
    for (request.messages) |message| {
        if (message.role == .system) {
            // Responses API puts system content as a developer/system role message in input.
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.writeAll("{\"role\":\"system\",\"content\":");
            if (message.content) |content| {
                try writeJsonValue(writer, content);
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeAll("}");
            continue;
        }

        switch (message.role) {
            .user => {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
                try writeJsonValue(writer, message.content orelse "");
                try writer.writeAll("}]}");
            },
            .assistant => {
                if (!first) try writer.writeAll(",");
                first = false;
                if (message.tool_calls.len > 0) {
                    // Assistant tool calls become function_call items.
                    for (message.tool_calls) |tool_call| {
                        if (!first) try writer.writeAll(",");
                        first = false;
                        try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                        try writeJsonValue(writer, tool_call.id);
                        try writer.writeAll(",\"name\":");
                        try writeJsonValue(writer, tool_call.name);
                        try writer.writeAll(",\"arguments\":");
                        try writeJsonValue(writer, tool_call.arguments_json);
                        try writer.writeAll("}");
                    }
                } else {
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try writeJsonValue(writer, message.content orelse "");
                    try writer.writeAll("}]}");
                }
            },
            .tool => {
                if (!first) try writer.writeAll(",");
                first = false;
                // Tool results become function_call_output items.
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try writeJsonValue(writer, message.tool_call_id orelse "");
                try writer.writeAll(",\"output\":");
                try writeJsonValue(writer, message.content orelse "");
                try writer.writeAll("}");
            },
            .system => unreachable, // handled above
        }
    }

    try writer.writeAll("]");
    try writer.writeAll(",\"temperature\":0");
    if (stream) try writer.writeAll(",\"stream\":true");

    if (request.tool_definitions.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tool_definitions, 0..) |tool_def, index| {
            if (index > 0) try writer.writeAll(",");
            // Responses API uses the same function tool shape as chat completions.
            try writer.writeAll("{\"type\":\"function\",\"name\":");
            try writeJsonValue(writer, tool_def.name);
            try writer.writeAll(",\"description\":");
            try writeJsonValue(writer, tool_def.description);
            try writer.writeAll(",\"parameters\":");
            try writer.writeAll(tool_def.parameters_json);
            try writer.writeAll("}");
        }
        try writer.writeAll("],\"tool_choice\":\"auto\"");
    }

    try writer.writeAll("}");
    return payload.toOwnedSlice();
}

/// Parse a Responses API response body into the canonical CompletionResponse.
/// The Responses API returns `output` (array of items) containing message
/// items and function_call items.
pub fn parseCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    // Check for SSE event stream (streaming responses).
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

    // The output array contains the response items.
    if (root.get("output")) |output_value| {
        if (output_value == .array) {
            for (output_value.array.items) |item| {
                if (item != .object) continue;
                const item_type = item.object.get("type") orelse continue;
                if (item_type != .string) continue;

                if (std.mem.eql(u8, item_type.string, "message")) {
                    // Extract text from content array.
                    if (item.object.get("content")) |content_value| {
                        if (content_value == .array) {
                            for (content_value.array.items) |content_item| {
                                if (content_item != .object) continue;
                                const ct = content_item.object.get("type") orelse continue;
                                if (ct != .string) continue;
                                if (std.mem.eql(u8, ct.string, "output_text") or
                                    std.mem.eql(u8, ct.string, "text"))
                                {
                                    if (content_item.object.get("text")) |text| {
                                        if (text == .string) try content_buf.appendSlice(text.string);
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, item_type.string, "function_call")) {
                    // Extract function call.
                    const call_id = getItemString(item.object, "call_id") orelse getItemString(item.object, "id") orelse "call-generated";
                    const name = getItemString(item.object, "name") orelse continue;
                    const arguments = getItemString(item.object, "arguments") orelse "{}";
                    tool_calls.append(.{
                        .id = try allocator.dupe(u8, call_id),
                        .name = try allocator.dupe(u8, name),
                        .arguments_json = try allocator.dupe(u8, arguments),
                    }) catch return Error.MalformedHttpResponse;
                }
            }
        }
    }

    // Some Responses implementations put output_text at top-level for convenience.
    if (content_buf.items.len == 0) {
        if (root.get("output_text")) |ot| {
            if (ot == .string) try content_buf.appendSlice(ot.string);
        }
    }

    const model_str = if (root.get("model")) |m| (if (m == .string) m.string else configured_model) else configured_model;

    var usage: types.Usage = .{};
    captureResponsesUsage(root, &usage);
    usage.reconcile();

    return .{
        .model = try allocator.dupe(u8, model_str),
        .content = if (content_buf.items.len > 0) try content_buf.toOwnedSlice() else null,
        .tool_calls = try tool_calls.toOwnedSlice(),
        .usage = usage,
    };
}

/// Extract an OpenAI Responses usage object into the canonical Usage contract.
/// `input_tokens_details.cached_tokens` becomes the cached bucket. Missing
/// usage → fields unchanged (zeros by caller default). Why: the cost model
/// must work for every wire protocol VANTARI speaks. Evidence: non-stream
/// parse + response.completed stream event.
fn captureResponsesUsage(root: std.json.ObjectMap, usage: *types.Usage) void {
    const usage_value = root.get("usage") orelse return;
    if (usage_value != .object) return;
    const u = usage_value.object;
    if (getU64(u, "input_tokens")) |value| usage.prompt_tokens = value;
    if (getU64(u, "output_tokens")) |value| usage.completion_tokens = value;
    if (getU64(u, "total_tokens")) |value| usage.total_tokens = value;
    if (u.get("input_tokens_details")) |details| {
        if (details == .object) {
            if (getU64(details.object, "cached_tokens")) |value| usage.cached_tokens = value;
        }
    }
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

    // Accumulator for streamed function calls (arguments arrive in deltas).
    var tc_accumulators = std.array_list.Managed(TcAccumulator).init(allocator);
    defer {
        for (tc_accumulators.items) |*acc| acc.deinit(allocator);
        tc_accumulators.deinit();
    }

    var cursor: usize = 0;
    var usage: types.Usage = .{};
    while (cursor < response_body.len) {
        const remaining = response_body[cursor..];
        if (findSseBoundary(remaining)) |boundary| {
            try parseSseEvent(allocator, remaining[0..boundary.event_end], &content, &tool_calls, &tc_accumulators, &usage);
            cursor += boundary.remove_len;
            continue;
        }
        try parseSseEvent(allocator, remaining, &content, &tool_calls, &tc_accumulators, &usage);
        break;
    }
    usage.reconcile();

    // Materialize accumulated tool calls.
    for (tc_accumulators.items) |acc| {
        if (acc.name.items.len == 0) continue;
        tool_calls.append(.{
            .id = if (acc.call_id.items.len > 0)
                try allocator.dupe(u8, acc.call_id.items)
            else
                try std.fmt.allocPrint(allocator, "resp_call_{d}", .{tool_calls.items.len}),
            .name = try allocator.dupe(u8, acc.name.items),
            .arguments_json = try allocator.dupe(u8, acc.arguments.items),
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
    call_id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    arguments: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) TcAccumulator {
        return .{
            .call_id = std.array_list.Managed(u8).init(allocator),
            .name = std.array_list.Managed(u8).init(allocator),
            .arguments = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *TcAccumulator, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.call_id.deinit();
        self.name.deinit();
        self.arguments.deinit();
    }
};

fn parseSseEvent(
    allocator: std.mem.Allocator,
    event: []const u8,
    content: *std.array_list.Managed(u8),
    tool_calls: *std.array_list.Managed(types.ToolCall),
    tc_accumulators: *std.array_list.Managed(TcAccumulator),
    usage: *types.Usage,
) !void {
    _ = tool_calls;
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

    // Response API streaming events: response.output_text.delta, response.function_call_arguments.delta, etc.
    const event_type = if (root.get("type")) |t| (if (t == .string) t.string else "") else "";

    // Usage evidence: the terminal response.completed event carries the usage
    // object at root, under response (standard), or under delta (some SDKs).
    if (std.mem.eql(u8, event_type, "response.completed")) {
        captureResponsesUsage(root, usage);
        if (root.get("response")) |response| {
            if (response == .object) captureResponsesUsage(response.object, usage);
        }
        if (root.get("delta")) |delta| {
            if (delta == .object) captureResponsesUsage(delta.object, usage);
        }
    }

    if (std.mem.eql(u8, event_type, "response.output_text.delta") or
        std.mem.eql(u8, event_type, "response.output_text.added"))
    {
        if (root.get("delta")) |delta| {
            if (delta == .string) try content.appendSlice(delta.string);
        }
    }

    // Function call deltas in streaming.
    if (root.get("item")) |item| {
        if (item == .object) {
            if (item.object.get("type")) |it| {
                if (it == .string and std.mem.eql(u8, it.string, "function_call")) {
                    const idx_val = item.object.get("index") orelse return;
                    const idx: usize = if (idx_val == .integer) @intCast(idx_val.integer) else 0;
                    while (tc_accumulators.items.len <= idx) {
                        try tc_accumulators.append(TcAccumulator.init(allocator));
                    }
                    var acc = &tc_accumulators.items[idx];
                    if (item.object.get("call_id")) |cid| {
                        if (cid == .string) try acc.call_id.appendSlice(cid.string);
                    }
                    if (item.object.get("name")) |name| {
                        if (name == .string) try acc.name.appendSlice(name.string);
                    }
                    if (item.object.get("arguments")) |args| {
                        if (args == .string) try acc.arguments.appendSlice(args.string);
                    }
                }
            }
        }
    }
}

fn getItemString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
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

test "responses buildRequestJson converts chat messages to input items" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = @constCast("You are helpful.") },
        .{ .role = .user, .content = @constCast("Hello") },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"input\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model\":\"test-model\"") != null);
}

test "responses buildRequestJson converts tool result to function_call_output" {
    const messages = [_]types.ChatMessage{
        .{
            .role = .tool,
            .content = @constCast("{\"result\":42}"),
            .tool_call_id = @constCast("call_1"),
        },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
    }, false);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"call_id\":\"call_1\"") != null);
}

test "responses parseCompletionResponse extracts message text from output array" {
    const body =
        \\{"model":"test","output":[
        \\  {"type":"message","role":"assistant","content":[
        \\    {"type":"output_text","text":"Hello world"}
        \\  ]}
        \\]}
    ;
    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Hello world", response.content.?);
    try std.testing.expectEqual(@as(usize, 0), response.tool_calls.len);
}

test "responses parseCompletionResponse extracts function_call items as tool calls" {
    const body =
        \\{"model":"test","output":[
        \\  {"type":"function_call","call_id":"call_1","name":"read_file","arguments":"{\"path\":\"README.md\"}"}
        \\]}
    ;
    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", response.tool_calls[0].arguments_json);
}

test "responsesUrl resolves correctly for various base_urls" {
    const url1 = try responsesUrl(std.testing.allocator, "http://localhost:1234/v1");
    defer std.testing.allocator.free(url1);
    try std.testing.expectEqualStrings("http://localhost:1234/v1/responses", url1);

    const url2 = try responsesUrl(std.testing.allocator, "https://api.openai.com");
    defer std.testing.allocator.free(url2);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", url2);

    const url3 = try responsesUrl(std.testing.allocator, "http://localhost:1234/v1/chat/completions");
    defer std.testing.allocator.free(url3);
    try std.testing.expectEqualStrings("http://localhost:1234/v1/responses", url3);
}
