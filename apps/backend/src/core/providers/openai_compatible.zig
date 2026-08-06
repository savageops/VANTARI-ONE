const std = @import("std");
const context_overflow = @import("../context/overflow.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    BadStatus,
    ContextWindowExceeded,
    MalformedChunkedResponse,
    MalformedHttpResponse,
    MalformedStreamResponse,
    MissingChoice,
    MissingContent,
    ShortHttpResponseBody,
};

const max_head_bytes = 64 * 1024;
const max_response_bytes = 4 * 1024 * 1024;
const max_transport_bytes = max_head_bytes + max_response_bytes;
const plain_read_buffer_size = 8 * 1024;
const plain_write_buffer_size = 1024;
const tls_record_buffer_size = std.crypto.tls.Client.min_buffer_len;
const tls_plaintext_write_buffer_size = tls_record_buffer_size;
const tls_read_buffer_size = tls_record_buffer_size + max_head_bytes;
const bad_status_diagnostic_bytes = 2048;
const bad_status_body_prefix_bytes = 768;

threadlocal var latest_bad_status_diagnostic: [bad_status_diagnostic_bytes]u8 = undefined;
threadlocal var latest_bad_status_diagnostic_len: usize = 0;

const Scheme = enum {
    http,
    https,
};

const ParsedResponse = struct {
    model: ?[]const u8 = null,
    choices: []const Choice,

    const Choice = struct {
        message: Message,
    };

    const Message = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: ?[]const ParsedToolCall = null,
    };

    const ParsedToolCall = struct {
        id: ?[]const u8 = null,
        function: Function,

        const Function = struct {
            name: []const u8,
            arguments: std.json.Value,
        };
    };
};

const ParsedStreamChunk = struct {
    choices: []const Choice = &.{},

    const Choice = struct {
        delta: Delta = .{},
    };

    const Delta = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        tool_calls: ?[]const ToolCallDelta = null,
    };

    const ToolCallDelta = struct {
        index: usize = 0,
        id: ?[]const u8 = null,
        function: ?Function = null,

        const Function = struct {
            name: ?[]const u8 = null,
            arguments: ?[]const u8 = null,
        };
    };
};

pub const StreamHooks = struct {
    context: ?*anyopaque = null,
    onAssistantDeltaFn: ?*const fn (ctx: ?*anyopaque, delta: []const u8) anyerror!void = null,
    onReasoningDeltaFn: ?*const fn (ctx: ?*anyopaque, delta: []const u8) anyerror!void = null,

    pub fn hasHandlers(self: StreamHooks) bool {
        return self.onAssistantDeltaFn != null or self.onReasoningDeltaFn != null;
    }

    pub fn onAssistantDelta(self: StreamHooks, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (self.onAssistantDeltaFn) |callback| {
            try callback(self.context, delta);
        }
    }

    pub fn onReasoningDelta(self: StreamHooks, delta: []const u8) !void {
        if (delta.len == 0) return;
        if (self.onReasoningDeltaFn) |callback| {
            try callback(self.context, delta);
        }
    }
};

pub fn clearFailureDiagnostic() void {
    latest_bad_status_diagnostic_len = 0;
}

pub fn failureDiagnosticForError(err: anyerror) []const u8 {
    if (err == Error.BadStatus and latest_bad_status_diagnostic_len > 0) {
        return latest_bad_status_diagnostic[0..latest_bad_status_diagnostic_len];
    }
    return @errorName(err);
}

pub fn complete(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
) !types.CompletionResponse {
    return completeWithTransport(allocator, config, request, .{
        .context = null,
        .sendFn = httpSend,
    });
}

pub const Transport = struct {
    context: ?*anyopaque,
    sendFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        api_key: []const u8,
        payload: []const u8,
    ) anyerror![]u8,
    streamFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        url: []const u8,
        api_key: []const u8,
        payload: []const u8,
        hooks: StreamHooks,
    ) anyerror![]u8 = null,

    pub fn send(
        self: Transport,
        allocator: std.mem.Allocator,
        url: []const u8,
        api_key: []const u8,
        payload: []const u8,
        hooks: StreamHooks,
    ) anyerror![]u8 {
        if (hooks.hasHandlers()) {
            if (self.streamFn) |stream_fn| {
                return stream_fn(self.context, allocator, url, api_key, payload, hooks);
            }
        }
        return self.sendFn(self.context, allocator, url, api_key, payload);
    }
};

pub const testing = struct {
    pub fn requestJson(
        allocator: std.mem.Allocator,
        model: []const u8,
        request: types.CompletionRequest,
        stream: bool,
    ) ![]u8 {
        return buildRequestJson(allocator, model, request, stream, "disabled");
    }

    pub fn completionResponse(
        allocator: std.mem.Allocator,
        configured_model: []const u8,
        response_body: []const u8,
    ) !types.CompletionResponse {
        return parseCompletionResponse(allocator, configured_model, response_body);
    }
};

pub fn completeWithTransport(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: Transport,
) !types.CompletionResponse {
    return completeWithTransportAndHooks(allocator, config, request, transport, .{});
}

pub fn completeWithTransportAndHooks(
    allocator: std.mem.Allocator,
    config: types.Config,
    request: types.CompletionRequest,
    transport: Transport,
    stream_hooks: StreamHooks,
) !types.CompletionResponse {
    const url = try completionUrl(allocator, config.openai_base_url);
    defer allocator.free(url);

    const payload = try buildRequestJson(allocator, config.openai_model, request, stream_hooks.hasHandlers(), config.thinking_mode);
    defer allocator.free(payload);

    clearFailureDiagnostic();
    const response_body = try transport.send(allocator, url, config.openai_api_key, payload, stream_hooks);
    defer allocator.free(response_body);

    return parseCompletionResponse(allocator, config.openai_model, response_body);
}

fn buildRequestJson(
    allocator: std.mem.Allocator,
    model: []const u8,
    request: types.CompletionRequest,
    stream: bool,
    thinking_mode: []const u8,
) ![]u8 {
    _ = thinking_mode;
    var payload = std.array_list.Managed(u8).init(allocator);
    errdefer payload.deinit();

    const writer = payload.writer();
    try writer.writeAll("{\"model\":");
    try writeJsonValue(writer, model);
    try writer.writeAll(",\"messages\":[");

    for (request.messages, 0..) |message, index| {
        if (index > 0) try writer.writeAll(",");
        try writeMessageJson(writer, message);
    }

    try writer.writeAll("],\"temperature\":0");
    if (stream) try writer.writeAll(",\"stream\":true");

    if (request.tool_definitions.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (request.tool_definitions, 0..) |tool_definition, index| {
            if (index > 0) try writer.writeAll(",");
            try writeToolDefinitionJson(writer, tool_definition);
        }
        try writer.writeAll("],\"tool_choice\":\"auto\",\"parallel_tool_calls\":true");
    }

    try writer.writeAll("}");
    return payload.toOwnedSlice();
}

fn parseCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    if (looksLikeEventStream(response_body)) {
        return parseStreamCompletionResponse(allocator, configured_model, response_body);
    }

    var parsed = try std.json.parseFromSlice(ParsedResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return Error.MissingChoice;

    const parsed_message = parsed.value.choices[0].message;
    const tool_calls = try duplicateToolCalls(allocator, parsed_message.tool_calls orelse &.{});
    errdefer {
        for (tool_calls) |tool_call| tool_call.deinit(allocator);
        if (tool_calls.len > 0) allocator.free(tool_calls);
    }

    return .{
        .model = try allocator.dupe(u8, parsed.value.model orelse configured_model),
        .content = if (parsed_message.content) |value| try allocator.dupe(u8, value) else null,
        .reasoning = if (parsed_message.reasoning_content) |value| try allocator.dupe(u8, value) else null,
        .tool_calls = tool_calls,
    };
}

const ToolCallAccumulator = struct {
    id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    arguments: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) ToolCallAccumulator {
        return .{
            .id = std.array_list.Managed(u8).init(allocator),
            .name = std.array_list.Managed(u8).init(allocator),
            .arguments = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *ToolCallAccumulator) void {
        self.id.deinit();
        self.name.deinit();
        self.arguments.deinit();
    }
};

fn parseStreamCompletionResponse(
    allocator: std.mem.Allocator,
    configured_model: []const u8,
    response_body: []const u8,
) !types.CompletionResponse {
    var content = std.array_list.Managed(u8).init(allocator);
    errdefer content.deinit();

    var reasoning = std.array_list.Managed(u8).init(allocator);
    errdefer reasoning.deinit();

    var tool_accumulators = std.array_list.Managed(ToolCallAccumulator).init(allocator);
    defer {
        for (tool_accumulators.items) |*accumulator| accumulator.deinit();
        tool_accumulators.deinit();
    }

    var cursor: usize = 0;
    while (cursor < response_body.len) {
        const remaining = response_body[cursor..];
        if (findSseEventBoundary(remaining)) |boundary| {
            try parseStreamEventInto(allocator, remaining[0..boundary.event_end], &content, &reasoning, &tool_accumulators);
            cursor += boundary.remove_len;
            continue;
        }
        try parseStreamEventInto(allocator, remaining, &content, &reasoning, &tool_accumulators);
        break;
    }

    const tool_calls = try materializeStreamToolCalls(allocator, tool_accumulators.items);
    errdefer {
        for (tool_calls) |tool_call| tool_call.deinit(allocator);
        if (tool_calls.len > 0) allocator.free(tool_calls);
    }

    return .{
        .model = try allocator.dupe(u8, configured_model),
        .content = if (content.items.len > 0) try content.toOwnedSlice() else null,
        .reasoning = if (reasoning.items.len > 0) try reasoning.toOwnedSlice() else null,
        .tool_calls = tool_calls,
    };
}

fn parseStreamEventInto(
    allocator: std.mem.Allocator,
    event: []const u8,
    content: *std.array_list.Managed(u8),
    reasoning: *std.array_list.Managed(u8),
    tool_accumulators: *std.array_list.Managed(ToolCallAccumulator),
) !void {
    var event_data = std.array_list.Managed(u8).init(allocator);
    defer event_data.deinit();

    var lines = std.mem.splitScalar(u8, event, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const data = stripSseDataPrefix(line) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) return;

        if (event_data.items.len > 0) try event_data.append('\n');
        try event_data.appendSlice(data);
    }

    if (event_data.items.len == 0) return;

    var parsed = std.json.parseFromSlice(ParsedStreamChunk, allocator, event_data.items, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return;
    const delta = parsed.value.choices[0].delta;
    if (delta.content) |value| try content.appendSlice(value);
    if (delta.reasoning_content) |value| try reasoning.appendSlice(value);
    if (delta.tool_calls) |tool_deltas| {
        for (tool_deltas) |tool_delta| {
            try applyToolCallDelta(allocator, tool_accumulators, tool_delta);
        }
    }
}

fn applyToolCallDelta(
    allocator: std.mem.Allocator,
    tool_accumulators: *std.array_list.Managed(ToolCallAccumulator),
    tool_delta: ParsedStreamChunk.ToolCallDelta,
) !void {
    while (tool_accumulators.items.len <= tool_delta.index) {
        try tool_accumulators.append(ToolCallAccumulator.init(allocator));
    }

    var accumulator = &tool_accumulators.items[tool_delta.index];
    if (tool_delta.id) |id| try accumulator.id.appendSlice(id);
    if (tool_delta.function) |function| {
        if (function.name) |name| try accumulator.name.appendSlice(name);
        if (function.arguments) |arguments| try accumulator.arguments.appendSlice(arguments);
    }
}

fn materializeStreamToolCalls(
    allocator: std.mem.Allocator,
    accumulators: []const ToolCallAccumulator,
) ![]types.ToolCall {
    var count: usize = 0;
    for (accumulators) |accumulator| {
        if (accumulator.name.items.len > 0) count += 1;
    }
    if (count == 0) return allocator.alloc(types.ToolCall, 0);

    const tool_calls = try allocator.alloc(types.ToolCall, count);
    errdefer allocator.free(tool_calls);

    var output_index: usize = 0;
    for (accumulators, 0..) |accumulator, index| {
        if (accumulator.name.items.len == 0) continue;
        errdefer {
            var cleanup_index: usize = 0;
            while (cleanup_index < output_index) : (cleanup_index += 1) tool_calls[cleanup_index].deinit(allocator);
        }

        tool_calls[output_index] = .{
            .id = if (accumulator.id.items.len > 0)
                try allocator.dupe(u8, accumulator.id.items)
            else
                try std.fmt.allocPrint(allocator, "stream_call_{d}", .{index}),
            .name = try allocator.dupe(u8, accumulator.name.items),
            .arguments_json = try allocator.dupe(u8, accumulator.arguments.items),
        };
        output_index += 1;
    }

    return tool_calls;
}

pub fn completionUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    const suffix = if (hasExplicitVersionSegment(trimmed))
        "/chat/completions"
    else
        "/v1/chat/completions";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
}

pub fn modelsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    var trimmed = std.mem.trimRight(u8, base_url, "/");
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        trimmed = trimmed[0 .. trimmed.len - "/chat/completions".len];
    }
    const suffix = if (hasExplicitVersionSegment(trimmed)) "/models" else "/v1/models";
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed, suffix });
}

pub fn lmStudioLoadedModelsUrl(allocator: std.mem.Allocator, base_url: []const u8) !?[]u8 {
    const trimmed = std.mem.trimRight(u8, base_url, "/");
    if (!isLocalHostUrl(trimmed)) return null;
    const origin = stripPathAndVersion(trimmed);
    return try std.fmt.allocPrint(allocator, "{s}/api/v1/models/loaded", .{origin});
}

fn stripPathAndVersion(base_url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, base_url, "://") orelse return base_url;
    const path_start = std.mem.indexOfPos(u8, base_url, scheme_end + 3, "/") orelse return base_url;
    return base_url[0..path_start];
}

pub fn isLocalHostUrl(url: []const u8) bool {
    if (std.mem.indexOf(u8, url, "://") == null) return false;
    return std.mem.indexOf(u8, url, "localhost") != null or
        std.mem.indexOf(u8, url, "127.0.0.1") != null or
        std.mem.indexOf(u8, url, "[::1]") != null;
}

pub fn httpGet(
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    account_id: ?[]const u8,
) anyerror![]u8 {
    const uri = try std.Uri.parse(url);
    const scheme = try schemeFromUri(uri.scheme);
    var host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const port = uri.port orelse defaultPort(scheme);
    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();
    return switch (scheme) {
        .http => plainHttpGet(allocator, stream, &uri, api_key, account_id),
        .https => tlsHttpGet(allocator, stream, host, &uri, api_key, account_id),
    };
}

fn hasExplicitVersionSegment(base_url: []const u8) bool {
    const slash_index = std.mem.lastIndexOfScalar(u8, base_url, '/') orelse return false;
    const segment = base_url[slash_index + 1 ..];
    if (segment.len < 2 or segment[0] != 'v') return false;

    for (segment[1..]) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }

    return true;
}

pub fn httpSend(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    const uri = try std.Uri.parse(url);
    const scheme = try schemeFromUri(uri.scheme);

    var host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const port = uri.port orelse defaultPort(scheme);

    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();

    return switch (scheme) {
        .http => plainHttpSend(allocator, stream, &uri, api_key, payload),
        .https => tlsHttpSend(allocator, stream, host, &uri, api_key, payload),
    };
}

pub fn httpSendStreaming(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    api_key: []const u8,
    payload: []const u8,
    hooks: StreamHooks,
) anyerror![]u8 {
    const uri = try std.Uri.parse(url);
    const scheme = try schemeFromUri(uri.scheme);

    var host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const host = try uri.getHost(&host_buffer);
    const port = uri.port orelse defaultPort(scheme);

    const stream = try std.net.tcpConnectToHost(allocator, host, port);
    defer stream.close();

    return switch (scheme) {
        .http => plainHttpSendStreaming(allocator, stream, &uri, api_key, payload, hooks),
        .https => tlsHttpSendStreaming(allocator, stream, host, &uri, api_key, payload, hooks),
    };
}

fn plainHttpSend(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
) ![]u8 {
    var read_buffer: [plain_read_buffer_size]u8 = undefined;
    var write_buffer: [plain_write_buffer_size]u8 = undefined;

    var stream_reader = stream.reader(&read_buffer);
    var stream_writer = stream.writer(&write_buffer);

    try writeRequestHead(&stream_writer.interface, uri, api_key, payload.len);
    try stream_writer.interface.writeAll(payload);
    try stream_writer.interface.flush();

    return readResponse(allocator, stream_reader.interface());
}

fn plainHttpGet(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    uri: *const std.Uri,
    api_key: []const u8,
    account_id: ?[]const u8,
) ![]u8 {
    var read_buffer: [plain_read_buffer_size]u8 = undefined;
    var write_buffer: [plain_write_buffer_size]u8 = undefined;
    var stream_reader = stream.reader(&read_buffer);
    var stream_writer = stream.writer(&write_buffer);
    try writeGetHead(&stream_writer.interface, uri, api_key, account_id);
    try stream_writer.interface.flush();
    return readResponse(allocator, stream_reader.interface());
}

fn plainHttpSendStreaming(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
    hooks: StreamHooks,
) ![]u8 {
    var read_buffer: [plain_read_buffer_size]u8 = undefined;
    var write_buffer: [plain_write_buffer_size]u8 = undefined;

    var stream_reader = stream.reader(&read_buffer);
    var stream_writer = stream.writer(&write_buffer);

    try writeRequestHead(&stream_writer.interface, uri, api_key, payload.len);
    try stream_writer.interface.writeAll(payload);
    try stream_writer.interface.flush();

    return readStreamingResponse(allocator, stream_reader.interface(), hooks);
}

fn tlsHttpSend(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    host: []const u8,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
) ![]u8 {
    var encrypted_write_buffer: [tls_record_buffer_size]u8 = undefined;
    var encrypted_read_buffer: [tls_record_buffer_size]u8 = undefined;
    var tls_read_buffer: [tls_read_buffer_size]u8 = undefined;
    var plaintext_write_buffer: [tls_plaintext_write_buffer_size]u8 = undefined;

    var stream_writer = stream.writer(&encrypted_write_buffer);
    var stream_reader = stream.reader(&encrypted_read_buffer);

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);

    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buffer[0..],
            .write_buffer = plaintext_write_buffer[0..],
            .allow_truncation_attacks = true,
        },
    );

    try writeRequestHead(&tls_client.writer, uri, api_key, payload.len);
    try tls_client.writer.writeAll(payload);
    try tls_client.writer.flush();
    try stream_writer.interface.flush();

    return readResponse(allocator, &tls_client.reader);
}

fn tlsHttpGet(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    host: []const u8,
    uri: *const std.Uri,
    api_key: []const u8,
    account_id: ?[]const u8,
) ![]u8 {
    var encrypted_write_buffer: [tls_record_buffer_size]u8 = undefined;
    var encrypted_read_buffer: [tls_record_buffer_size]u8 = undefined;
    var tls_read_buffer: [tls_read_buffer_size]u8 = undefined;
    var plaintext_write_buffer: [tls_plaintext_write_buffer_size]u8 = undefined;
    var stream_writer = stream.writer(&encrypted_write_buffer);
    var stream_reader = stream.reader(&encrypted_read_buffer);
    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);
    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buffer[0..],
            .write_buffer = plaintext_write_buffer[0..],
            .allow_truncation_attacks = true,
        },
    );
    try writeGetHead(&tls_client.writer, uri, api_key, account_id);
    try tls_client.writer.flush();
    try stream_writer.interface.flush();
    return readResponse(allocator, &tls_client.reader);
}

fn tlsHttpSendStreaming(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    host: []const u8,
    uri: *const std.Uri,
    api_key: []const u8,
    payload: []const u8,
    hooks: StreamHooks,
) ![]u8 {
    var encrypted_write_buffer: [tls_record_buffer_size]u8 = undefined;
    var encrypted_read_buffer: [tls_record_buffer_size]u8 = undefined;
    var tls_read_buffer: [tls_read_buffer_size]u8 = undefined;
    var plaintext_write_buffer: [tls_plaintext_write_buffer_size]u8 = undefined;

    var stream_writer = stream.writer(&encrypted_write_buffer);
    var stream_reader = stream.reader(&encrypted_read_buffer);

    var ca_bundle: std.crypto.Certificate.Bundle = .{};
    defer ca_bundle.deinit(allocator);
    try ca_bundle.rescan(allocator);

    var tls_client = try std.crypto.tls.Client.init(
        stream_reader.interface(),
        &stream_writer.interface,
        .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = ca_bundle },
            .read_buffer = tls_read_buffer[0..],
            .write_buffer = plaintext_write_buffer[0..],
            .allow_truncation_attacks = true,
        },
    );

    try writeRequestHead(&tls_client.writer, uri, api_key, payload.len);
    try tls_client.writer.writeAll(payload);
    try tls_client.writer.flush();
    try stream_writer.interface.flush();

    return readStreamingResponse(allocator, &tls_client.reader, hooks);
}

fn writeRequestHead(
    writer: *std.Io.Writer,
    uri: *const std.Uri,
    api_key: []const u8,
    payload_len: usize,
) !void {
    try writer.writeAll("POST ");
    try uri.writeToStream(writer, .{ .path = true, .query = true });
    try writer.writeAll(" HTTP/1.1\r\n");

    try writer.writeAll("host: ");
    try uri.writeToStream(writer, .{ .authority = true });
    try writer.writeAll("\r\n");

    try writer.writeAll("authorization: Bearer ");
    try writer.writeAll(api_key);
    try writer.writeAll("\r\n");

    try writer.writeAll("content-type: application/json\r\n");
    try writer.writeAll("accept: text/event-stream, application/json\r\n");
    try writer.writeAll("accept-encoding: identity\r\n");
    try writer.writeAll("connection: close\r\n");
    try writer.print("content-length: {d}\r\n\r\n", .{payload_len});
}

fn writeGetHead(
    writer: *std.Io.Writer,
    uri: *const std.Uri,
    api_key: []const u8,
    account_id: ?[]const u8,
) !void {
    try writer.writeAll("GET ");
    try uri.writeToStream(writer, .{ .path = true, .query = true });
    try writer.writeAll(" HTTP/1.1\r\n");
    try writer.writeAll("host: ");
    try uri.writeToStream(writer, .{ .authority = true });
    try writer.writeAll("\r\n");
    try writer.writeAll("authorization: Bearer ");
    try writer.writeAll(api_key);
    try writer.writeAll("\r\n");
    if (account_id) |value| {
        try writer.writeAll("chatgpt-account-id: ");
        try writer.writeAll(value);
        try writer.writeAll("\r\n");
    }
    try writer.writeAll("accept: application/json\r\n");
    try writer.writeAll("accept-encoding: identity\r\n");
    try writer.writeAll("connection: close\r\n");
    try writer.writeAll("content-length: 0\r\n\r\n");
}

const StreamingHttpState = struct {
    headers_parsed: bool = false,
    chunked: bool = false,
    content_length: ?usize = null,
    status_code: u16 = 0,
    body_cursor: usize = 0,
    body_start: usize = 0,
    stream_complete: bool = false,
    decoded_body: std.array_list.Managed(u8),
    sse: SseDeltaEmitter,

    fn init(allocator: std.mem.Allocator, hooks: StreamHooks) StreamingHttpState {
        return .{
            .decoded_body = std.array_list.Managed(u8).init(allocator),
            .sse = SseDeltaEmitter.init(allocator, hooks),
        };
    }

    fn deinit(self: *StreamingHttpState) void {
        self.decoded_body.deinit();
        self.sse.deinit();
    }
};

fn readStreamingResponse(allocator: std.mem.Allocator, source_reader: *std.Io.Reader, hooks: StreamHooks) ![]u8 {
    var raw_response = std.array_list.Managed(u8).init(allocator);
    errdefer raw_response.deinit();

    var state = StreamingHttpState.init(allocator, hooks);
    defer state.deinit();

    // 64KB read buffer — the previous 4KB buffer caused excessive read
    // syscalls during streaming, each triggering a full reprocess. A larger
    // buffer lets the TLS layer return more decrypted data per read, reducing
    // per-token overhead. oh-my-pi uses Bun's native fetch which handles
    // buffering internally; we need to be explicit about it.
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_len = try source_reader.readSliceShort(&buffer);
        if (read_len == 0) break;
        try raw_response.appendSlice(buffer[0..read_len]);
        if (raw_response.items.len > max_transport_bytes) return error.StreamTooLong;
        try processStreamingHttpBytes(allocator, raw_response.items, &state);
        if (state.stream_complete) break;
    }
    try state.sse.flushRemainder();

    if (!state.headers_parsed) return Error.MalformedHttpResponse;
    if (state.status_code != 200) {
        const raw = try raw_response.toOwnedSlice();
        defer allocator.free(raw);
        return parseRawHttpResponse(allocator, raw);
    }

    if (state.chunked) {
        return state.decoded_body.toOwnedSlice();
    }

    const body = raw_response.items[state.body_start..];
    if (state.content_length) |expected_len| {
        if (body.len < expected_len) return Error.ShortHttpResponseBody;
        return allocator.dupe(u8, body[0..expected_len]);
    }
    return allocator.dupe(u8, body);
}

fn processStreamingHttpBytes(
    allocator: std.mem.Allocator,
    raw_response: []const u8,
    state: *StreamingHttpState,
) !void {
    // Cache the header boundary so we don't re-scan the full buffer every
    // call. After the first parse, headers_parsed is true and body_start is
    // stored — subsequent calls skip straight to body processing.
    if (!state.headers_parsed) {
        const header_end = std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return;
        state.body_start = header_end + 4;
        try parseStreamingHeaders(raw_response[0..header_end], state);
        state.headers_parsed = true;
    }

    if (state.status_code != 200) return;

    const body = raw_response[state.body_start..];
    if (state.chunked) {
        try processStreamingChunkedBody(allocator, body, state);
        return;
    }

    if (body.len <= state.body_cursor) return;
    const next = body[state.body_cursor..];
    state.body_cursor = body.len;
    try state.sse.feed(next);
}

fn parseStreamingHeaders(headers: []const u8, state: *StreamingHttpState) !void {
    const status_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return Error.MalformedHttpResponse;
    const status_line = headers[0..status_line_end];

    var status_iter = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = status_iter.next() orelse return Error.MalformedHttpResponse;
    const status_code_text = status_iter.next() orelse return Error.MalformedHttpResponse;
    state.status_code = std.fmt.parseUnsigned(u16, status_code_text, 10) catch return Error.MalformedHttpResponse;

    var line_iter = std.mem.splitSequence(u8, headers[status_line_end + 2 ..], "\r\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        const separator_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator_index], " ");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            state.chunked = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            state.content_length = std.fmt.parseUnsigned(usize, value, 10) catch return Error.MalformedHttpResponse;
        }
    }
}

fn processStreamingChunkedBody(
    allocator: std.mem.Allocator,
    body: []const u8,
    state: *StreamingHttpState,
) !void {
    _ = allocator;
    while (true) {
        const size_line_end = std.mem.indexOfPos(u8, body, state.body_cursor, "\r\n") orelse return;
        const raw_size = body[state.body_cursor..size_line_end];
        const extension_index = std.mem.indexOfScalar(u8, raw_size, ';') orelse raw_size.len;
        const size_text = std.mem.trim(u8, raw_size[0..extension_index], " ");
        const chunk_size = std.fmt.parseUnsigned(usize, size_text, 16) catch return Error.MalformedChunkedResponse;
        const chunk_start = size_line_end + 2;
        const chunk_end = chunk_start + chunk_size;
        if (body.len < chunk_end + 2) return;
        if (!std.mem.eql(u8, body[chunk_end .. chunk_end + 2], "\r\n")) return Error.MalformedChunkedResponse;

        state.body_cursor = chunk_end + 2;
        if (chunk_size == 0) {
            state.stream_complete = true;
            return;
        }

        const chunk = body[chunk_start..chunk_end];
        // Check for [DONE] sentinel in the chunk — marks stream end for
        // providers that keep the connection open after sending data.
        if (std.mem.indexOf(u8, chunk, "[DONE]") != null) {
            try state.decoded_body.appendSlice(chunk);
            try state.sse.feed(chunk);
            state.stream_complete = true;
            return;
        }
        try state.decoded_body.appendSlice(chunk);
        try state.sse.feed(chunk);
    }
}

const SseDeltaEmitter = struct {
    allocator: std.mem.Allocator,
    hooks: StreamHooks,
    buffer: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator, hooks: StreamHooks) SseDeltaEmitter {
        return .{
            .allocator = allocator,
            .hooks = hooks,
            .buffer = std.array_list.Managed(u8).init(allocator),
        };
    }

    fn deinit(self: *SseDeltaEmitter) void {
        self.buffer.deinit();
    }

    fn feed(self: *SseDeltaEmitter, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.buffer.appendSlice(bytes);
        while (findSseEventBoundary(self.buffer.items)) |boundary| {
            const event = self.buffer.items[0..boundary.event_end];
            try self.emitEvent(event);
            self.buffer.replaceRangeAssumeCapacity(0, boundary.remove_len, &.{});
        }
    }

    fn flushRemainder(self: *SseDeltaEmitter) !void {
        if (self.buffer.items.len == 0) return;
        try self.emitEvent(self.buffer.items);
        self.buffer.clearRetainingCapacity();
    }

    fn emitEvent(self: *SseDeltaEmitter, event: []const u8) !void {
        var lines = std.mem.splitScalar(u8, event, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            const data = stripSseDataPrefix(line) orelse continue;
            if (std.mem.eql(u8, data, "[DONE]")) continue;

            var parsed = std.json.parseFromSlice(ParsedStreamChunk, self.allocator, data, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            if (parsed.value.choices.len == 0) continue;
            const delta = parsed.value.choices[0].delta;
            if (delta.content) |content| {
                try self.hooks.onAssistantDelta(content);
            }
            if (delta.reasoning_content) |reasoning| {
                try self.hooks.onReasoningDelta(reasoning);
            }
        }
    }
};

const SseBoundary = struct {
    event_end: usize,
    remove_len: usize,
};

fn findSseEventBoundary(buffer: []const u8) ?SseBoundary {
    const lf = std.mem.indexOf(u8, buffer, "\n\n");
    const crlf = std.mem.indexOf(u8, buffer, "\r\n\r\n");
    if (lf == null and crlf == null) return null;
    if (lf) |lf_index| {
        if (crlf == null or lf_index < crlf.?) return .{ .event_end = lf_index, .remove_len = lf_index + 2 };
    }
    const crlf_index = crlf.?;
    return .{ .event_end = crlf_index, .remove_len = crlf_index + 4 };
}

fn stripSseDataPrefix(line: []const u8) ?[]const u8 {
    const prefix = "data:";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    return std.mem.trim(u8, line[prefix.len..], " ");
}

fn looksLikeEventStream(body: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, body, " \t\r\n"), "data:");
}

fn readResponse(allocator: std.mem.Allocator, source_reader: *std.Io.Reader) ![]u8 {
    var raw_response = std.array_list.Managed(u8).init(allocator);
    errdefer raw_response.deinit();

    var response_writer = raw_response.writer();
    var response_writer_buffer: [2048]u8 = undefined;
    var response_writer_adapter = response_writer.adaptToNewApi(&response_writer_buffer);

    _ = source_reader.streamRemaining(&response_writer_adapter.new_interface) catch |err| switch (err) {
        error.WriteFailed => return response_writer_adapter.err orelse err,
        else => return err,
    };
    try response_writer_adapter.new_interface.flush();

    if (raw_response.items.len > max_transport_bytes) {
        return error.StreamTooLong;
    }

    const raw_response_owned = try raw_response.toOwnedSlice();
    defer allocator.free(raw_response_owned);

    return parseRawHttpResponse(allocator, raw_response_owned);
}

fn parseRawHttpResponse(allocator: std.mem.Allocator, raw_response: []const u8) ![]u8 {
    const header_end = std.mem.indexOf(u8, raw_response, "\r\n\r\n") orelse return Error.MalformedHttpResponse;
    const headers = raw_response[0..header_end];
    const body = raw_response[header_end + 4 ..];

    const status_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return Error.MalformedHttpResponse;
    const status_line = headers[0..status_line_end];

    var status_iter = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = status_iter.next() orelse return Error.MalformedHttpResponse;
    const status_code_text = status_iter.next() orelse return Error.MalformedHttpResponse;
    const status_code = std.fmt.parseUnsigned(u16, status_code_text, 10) catch return Error.MalformedHttpResponse;
    if (status_code != 200) {
        if (status_code == 413 or context_overflow.isContextOverflowText(headers) or context_overflow.isContextOverflowText(body)) {
            return Error.ContextWindowExceeded;
        }
        recordBadStatusDiagnostic(status_code, status_line, body);
        return Error.BadStatus;
    }

    var is_chunked = false;
    var content_length: ?usize = null;

    var line_iter = std.mem.splitSequence(u8, headers[status_line_end + 2 ..], "\r\n");
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..separator_index], " ");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " ");

        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding") and std.ascii.indexOfIgnoreCase(value, "chunked") != null) {
            is_chunked = true;
            continue;
        }

        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseUnsigned(usize, value, 10) catch return Error.MalformedHttpResponse;
        }
    }

    if (is_chunked) {
        return decodeChunkedBody(allocator, body);
    }

    if (content_length) |expected_len| {
        if (body.len < expected_len) return Error.ShortHttpResponseBody;
        return allocator.dupe(u8, body[0..expected_len]);
    }

    return allocator.dupe(u8, body);
}

fn recordBadStatusDiagnostic(status_code: u16, status_line: []const u8, body: []const u8) void {
    var status_line_buffer: [256]u8 = undefined;
    const status_line_clean = sanitizedPrefix(&status_line_buffer, status_line);
    var body_buffer: [bad_status_body_prefix_bytes]u8 = undefined;
    const body_clean = sanitizedPrefix(&body_buffer, body);

    const diagnostic = std.fmt.bufPrint(
        &latest_bad_status_diagnostic,
        "BadStatus status={d} status_line=\"{s}\" body_prefix=\"{s}\"",
        .{ status_code, status_line_clean, body_clean },
    ) catch |err| switch (err) {
        error.NoSpaceLeft => "BadStatus status=unknown diagnostic_truncated",
    };
    latest_bad_status_diagnostic_len = diagnostic.len;
}

fn sanitizedPrefix(buffer: []u8, value: []const u8) []const u8 {
    if (buffer.len == 0) return buffer[0..0];
    const max_len = @min(buffer.len, value.len);
    var index: usize = 0;
    while (index < max_len) : (index += 1) {
        buffer[index] = switch (value[index]) {
            '\r', '\n', '\t' => ' ',
            '"' => '\'',
            else => |char| if (std.ascii.isPrint(char)) char else ' ',
        };
    }
    return buffer[0..index];
}

fn decodeChunkedBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    var decoded = std.array_list.Managed(u8).init(allocator);
    errdefer decoded.deinit();

    var cursor: usize = 0;
    while (true) {
        const size_line_end = std.mem.indexOfPos(u8, body, cursor, "\r\n") orelse return Error.MalformedChunkedResponse;
        const raw_size = body[cursor..size_line_end];
        const extension_index = std.mem.indexOfScalar(u8, raw_size, ';') orelse raw_size.len;
        const size_text = std.mem.trim(u8, raw_size[0..extension_index], " ");
        const chunk_size = std.fmt.parseUnsigned(usize, size_text, 16) catch return Error.MalformedChunkedResponse;

        cursor = size_line_end + 2;
        if (chunk_size == 0) {
            return decoded.toOwnedSlice();
        }

        if (cursor + chunk_size + 2 > body.len) return Error.ShortHttpResponseBody;
        try decoded.appendSlice(body[cursor .. cursor + chunk_size]);
        cursor += chunk_size;

        if (!std.mem.eql(u8, body[cursor .. cursor + 2], "\r\n")) return Error.MalformedChunkedResponse;
        cursor += 2;
    }
}

fn schemeFromUri(scheme: []const u8) !Scheme {
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return .http;
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return .https;
    return error.UnsupportedUriScheme;
}

fn defaultPort(scheme: Scheme) u16 {
    return switch (scheme) {
        .http => 80,
        .https => 443,
    };
}

fn writeMessageJson(writer: anytype, message: types.ChatMessage) !void {
    try writer.writeAll("{\"role\":");
    try writeJsonValue(writer, types.roleLabel(message.role));

    if (message.content) |content| {
        try writer.writeAll(",\"content\":");
        try writeJsonValue(writer, content);
    }

    if (message.tool_call_id) |tool_call_id| {
        try writer.writeAll(",\"tool_call_id\":");
        try writeJsonValue(writer, tool_call_id);
    }

    if (message.tool_calls.len > 0) {
        try writer.writeAll(",\"tool_calls\":[");
        for (message.tool_calls, 0..) |tool_call, index| {
            if (index > 0) try writer.writeAll(",");
            try writeToolCallJson(writer, tool_call);
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("}");
}

fn writeToolDefinitionJson(writer: anytype, tool_definition: types.ToolDefinition) !void {
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonValue(writer, tool_definition.name);
    try writer.writeAll(",\"description\":");
    try writeJsonValue(writer, tool_definition.description);
    try writer.writeAll(",\"parameters\":");
    try writer.writeAll(tool_definition.parameters_json);
    try writer.writeAll("}}");
}

fn writeToolCallJson(writer: anytype, tool_call: types.ToolCall) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonValue(writer, tool_call.id);
    try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
    try writeJsonValue(writer, tool_call.name);
    try writer.writeAll(",\"arguments\":");
    try writeJsonValue(writer, tool_call.arguments_json);
    try writer.writeAll("}}");
}

fn duplicateToolCalls(
    allocator: std.mem.Allocator,
    parsed_tool_calls: []const ParsedResponse.ParsedToolCall,
) ![]types.ToolCall {
    if (parsed_tool_calls.len == 0) return &.{};

    var tool_calls = try allocator.alloc(types.ToolCall, parsed_tool_calls.len);
    errdefer allocator.free(tool_calls);

    for (parsed_tool_calls, 0..) |parsed_tool_call, index| {
        const arguments_json = switch (parsed_tool_call.function.arguments) {
            .string => |value| try allocator.dupe(u8, value),
            else => try std.fmt.allocPrint(allocator, "{f}", .{
                std.json.fmt(parsed_tool_call.function.arguments, .{}),
            }),
        };
        errdefer allocator.free(arguments_json);

        tool_calls[index] = .{
            .id = try allocator.dupe(u8, parsed_tool_call.id orelse "call-generated"),
            .name = try allocator.dupe(u8, parsed_tool_call.function.name),
            .arguments_json = arguments_json,
        };
    }

    return tool_calls;
}

fn writeJsonValue(writer: anytype, value: anytype) !void {
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

const TestDeltaCapture = struct {
    output: std.array_list.Managed(u8),

    fn init(allocator: std.mem.Allocator) TestDeltaCapture {
        return .{ .output = std.array_list.Managed(u8).init(allocator) };
    }

    fn deinit(self: *TestDeltaCapture) void {
        self.output.deinit();
    }
};

fn captureTestAssistantDelta(ctx: ?*anyopaque, delta: []const u8) !void {
    const capture: *TestDeltaCapture = @ptrCast(@alignCast(ctx.?));
    try capture.output.appendSlice(delta);
}

test "provider parses SSE assistant deltas and reconstructs final content" {
    const body =
        \\data: {"choices":[{"delta":{"content":"hel"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"lo"}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;

    var capture = TestDeltaCapture.init(std.testing.allocator);
    defer capture.deinit();
    var emitter = SseDeltaEmitter.init(std.testing.allocator, .{
        .context = &capture,
        .onAssistantDeltaFn = captureTestAssistantDelta,
    });
    defer emitter.deinit();
    try emitter.feed(body[0..40]);
    try emitter.feed(body[40..]);
    try emitter.flushRemainder();
    try std.testing.expectEqualStrings("hello", capture.output.items);

    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", response.content.?);
}

test "provider parses streamed tool-call deltas into normal tool calls" {
    const body =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"README.md\"}"}}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;

    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", response.tool_calls[0].arguments_json);
}

test "provider preserves non-200 HTTP status diagnostic for session failure" {
    clearFailureDiagnostic();
    const raw_response =
        "HTTP/1.1 503 Service Unavailable\r\n" ++
        "content-type: application/json\r\n" ++
        "\r\n" ++
        "{\"error\":{\"message\":\"runtime warming\\nretry later\"}}";

    try std.testing.expectError(Error.BadStatus, parseRawHttpResponse(std.testing.allocator, raw_response));
    const diagnostic = failureDiagnosticForError(Error.BadStatus);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "BadStatus status=503") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "HTTP/1.1 503 Service Unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "runtime warming retry later") != null);
}

test "provider reconstructs CRLF SSE streams with sparse multi-tool indexes" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"phase-1 \"}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"function\":{\"name\":\"search_files\",\"arguments\":\"{\\\"pattern\\\":\\\"alpha\\\"}\"}}]}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"AGENTS.md\\\"}\"}}]}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"phase-2\"}}]}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("phase-1 phase-2", response.content.?);
    try std.testing.expectEqual(@as(usize, 2), response.tool_calls.len);
    try std.testing.expectEqualStrings("call_a", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"AGENTS.md\"}", response.tool_calls[0].arguments_json);
    try std.testing.expectEqualStrings("call_b", response.tool_calls[1].id);
    try std.testing.expectEqualStrings("search_files", response.tool_calls[1].name);
    try std.testing.expectEqualStrings("{\"pattern\":\"alpha\"}", response.tool_calls[1].arguments_json);
}

test "provider request payload opts into streaming and parallel tool calls when tools exist" {
    const messages = [_]types.ChatMessage{
        .{
            .role = .user,
            .content = @constCast("Use multiple tools if useful."),
        },
    };
    const tool_definitions = [_]types.ToolDefinition{
        .{
            .name = "read_file",
            .description = "Read a file.",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}",
            .review_risk = .read_only,
        },
        .{
            .name = "search_files",
            .description = "Search files.",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"}},\"required\":[\"pattern\"],\"additionalProperties\":false}",
            .review_risk = .read_only,
        },
    };
    const payload = try buildRequestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
        .tool_definitions = tool_definitions[0..],
    }, true, "disabled");
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"parallel_tool_calls\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"name\":\"search_files\"") != null);
}

test "provider reconstructs split SSE data fields instead of dropping first visible token" {
    const body =
        "data: {\"choices\":[{\"delta\":\r\n" ++
        "data: {\"content\":\"first-token\"}}]}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first-token", response.content.?);
}

test "provider stream matrix tolerates empty events and tool calls without ids" {
    const body =
        \\data: {"choices":[{"delta":{}}]}
        \\
        \\data: {}
        \\
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":2,"function":{"name":"read_file","arguments":"{}"}}]}}]}
        \\
        \\data: [DONE]
        \\
        \\
    ;

    const response = try parseCompletionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);
    try std.testing.expect(response.content == null);
    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("stream_call_2", response.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("{}", response.tool_calls[0].arguments_json);
}
