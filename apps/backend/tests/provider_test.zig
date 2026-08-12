const std = @import("std");
const VAR1 = @import("VAR1");

const provider = VAR1.core.provider_runtime;
const anthropic = VAR1.core.provider_anthropic;
const responses = VAR1.core.provider_responses;
const types = VAR1.shared.types;

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

    const payload = try provider.testing.requestJson(std.testing.allocator, "test-model", .{
        .messages = messages[0..],
        .tool_definitions = tool_definitions[0..],
    }, true, "", .zai);
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

    const response = try provider.testing.completionResponse(std.testing.allocator, "test-model", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("first-token", response.content.?);
}

test "parseCompletionResponse captures reasoning_content from GLM-5.x" {
    const body =
        \\{"model":"glm-5.1","choices":[{"message":{"content":"255","reasoning_content":"1. 15 * 17 = 255","role":"assistant"}}]}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "glm-5.1", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("255", response.content.?);
    try std.testing.expect(response.reasoning != null);
    try std.testing.expectEqualStrings("1. 15 * 17 = 255", response.reasoning.?);
}

test "streaming deltas capture reasoning_content alongside content" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Step 1:\"}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"255\"}}]}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "glm-5.1", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("255", response.content.?);
    try std.testing.expect(response.reasoning != null);
    try std.testing.expectEqualStrings("Step 1:", response.reasoning.?);
}

test "response without reasoning_content leaves reasoning null" {
    const body =
        \\{"model":"gpt-4","choices":[{"message":{"content":"hello","role":"assistant"}}]}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "gpt-4", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hello", response.content.?);
    try std.testing.expect(response.reasoning == null);
}

test "non-stream response captures usage with cached details" {
    const body =
        \\{"model":"glm-5.2","choices":[{"message":{"content":"ok","role":"assistant"}}],
        \\"usage":{"prompt_tokens":1234,"completion_tokens":567,"total_tokens":1801,
        \\"prompt_tokens_details":{"cached_tokens":890}}}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "glm-5.2", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1234), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 567), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 890), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 1801), response.usage.total_tokens);
}

test "non-stream response without usage yields zeros" {
    const body =
        \\{"model":"gpt-4","choices":[{"message":{"content":"hello","role":"assistant"}}]}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "gpt-4", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.total_tokens);
}

test "usage total recomputed from buckets when total_tokens omitted" {
    const body =
        \\{"model":"m","choices":[{"message":{"content":"x","role":"assistant"}}],
        \\"usage":{"prompt_tokens":300,"completion_tokens":200}}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 500), response.usage.total_tokens);
}

test "stream final chunk usage captured from choices-empty chunk" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":40,\"total_tokens\":140,\"prompt_tokens_details\":{\"cached_tokens\":60}}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("done", response.content.?);
    try std.testing.expectEqual(@as(u64, 100), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 40), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 60), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 140), response.usage.total_tokens);
}

test "stream usage attached to non-empty chunk wins over earlier chunks" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2}}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5,\"total_tokens\":15}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ab", response.content.?);
    // Last non-null usage wins.
    try std.testing.expectEqual(@as(u64, 10), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 5), response.usage.completion_tokens);
}

test "stream without any usage yields zeros" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hi", response.content.?);
    try std.testing.expectEqual(@as(u64, 0), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.total_tokens);
}

test "stream with reasoning and usage both captured" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think:\"}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"42\"}}]}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":50,\"completion_tokens\":30,\"total_tokens\":80}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "glm-5.2", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("42", response.content.?);
    try std.testing.expectEqualStrings("think:", response.reasoning.?);
    try std.testing.expectEqual(@as(u64, 50), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 30), response.usage.completion_tokens);
}

test "stream tool-call deltas and terminal usage chunk combined" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"a\"}}]}}]}\r\n\r\n" ++
        "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"b\"}}]}}]}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"total_tokens\":10}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqualStrings("ab", response.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(u64, 7), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 3), response.usage.completion_tokens);
}

test "usage cached_tokens defaults to zero when details omitted" {
    const body =
        \\{"model":"m","choices":[{"message":{"content":"x","role":"assistant"}}],
        \\"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}
    ;

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 7), response.usage.total_tokens);
}

test "Usage.reconcile keeps provider total when present" {
    var usage = types.Usage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 200,
    };
    usage.reconcile();
    try std.testing.expectEqual(@as(u64, 200), usage.total_tokens);
}

test "Usage.reconcile sums buckets when total absent" {
    var usage = types.Usage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .cached_tokens = 25,
    };
    usage.reconcile();
    try std.testing.expectEqual(@as(u64, 175), usage.total_tokens);
}

test "stream with trailing usage-only chunks after content" {
    const body =
        "data: {\"choices\":[{\"delta\":{\"content\":\"final\"}}]}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":1,\"total_tokens\":10}}\r\n\r\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":1,\"total_tokens\":10}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try provider.testing.completionResponse(std.testing.allocator, "m", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("final", response.content.?);
    try std.testing.expectEqual(@as(u64, 9), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 1), response.usage.completion_tokens);
}

test "anthropic non-stream usage folds cache creation into prompt" {
    const body =
        \\{"content":[{"type":"text","text":"hi"}],"model":"claude-sonnet-4-20250514",
        \\"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":5}}
    ;

    const response = try anthropic.parseCompletionResponse(std.testing.allocator, "claude-sonnet-4-20250514", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hi", response.content.?);
    try std.testing.expectEqual(@as(u64, 105), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 20), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 30), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 155), response.usage.total_tokens);
}

test "anthropic stream accumulates message_start and message_delta usage" {
    const body =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100,\"cache_creation_input_tokens\":5,\"cache_read_input_tokens\":30}}}\r\n\r\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\r\n\r\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":20}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try anthropic.parseCompletionResponse(std.testing.allocator, "claude-sonnet-4", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hi", response.content.?);
    try std.testing.expectEqual(@as(u64, 105), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 30), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 20), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 155), response.usage.total_tokens);
}

test "anthropic response without usage yields zeros" {
    const body =
        \\{"content":[{"type":"text","text":"plain"}],"model":"claude-sonnet-4"}
    ;

    const response = try anthropic.parseCompletionResponse(std.testing.allocator, "claude-sonnet-4", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("plain", response.content.?);
    try std.testing.expectEqual(@as(u64, 0), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.total_tokens);
}

test "anthropic tool_use and usage both parsed" {
    const body =
        \\{"content":[{"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"a.txt"}}],
        \\"usage":{"input_tokens":10,"output_tokens":2},"model":"claude-sonnet-4"}
    ;

    const response = try anthropic.parseCompletionResponse(std.testing.allocator, "claude-sonnet-4", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), response.tool_calls.len);
    try std.testing.expectEqualStrings("read_file", response.tool_calls[0].name);
    try std.testing.expectEqual(@as(u64, 10), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 2), response.usage.completion_tokens);
}

test "responses non-stream usage with cached details" {
    const body =
        \\{"output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}],
        \\"usage":{"input_tokens":50,"output_tokens":10,"total_tokens":60,"input_tokens_details":{"cached_tokens":15}},
        \\"model":"gpt-5"}
    ;

    const response = try responses.parseCompletionResponse(std.testing.allocator, "gpt-5", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hi", response.content.?);
    try std.testing.expectEqual(@as(u64, 50), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 10), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 15), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 60), response.usage.total_tokens);
}

test "responses stream completed event usage" {
    const body =
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\r\n\r\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":50,\"output_tokens\":10,\"total_tokens\":60,\"input_tokens_details\":{\"cached_tokens\":15}}}}\r\n\r\n" ++
        "data: [DONE]\r\n\r\n";

    const response = try responses.parseCompletionResponse(std.testing.allocator, "gpt-5", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("hi", response.content.?);
    try std.testing.expectEqual(@as(u64, 50), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 15), response.usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 60), response.usage.total_tokens);
}

test "responses response without usage yields zeros" {
    const body =
        \\{"output":[{"type":"message","content":[{"type":"output_text","text":"plain"}]}],"model":"gpt-5"}
    ;

    const response = try responses.parseCompletionResponse(std.testing.allocator, "gpt-5", body);
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("plain", response.content.?);
    try std.testing.expectEqual(@as(u64, 0), response.usage.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.completion_tokens);
    try std.testing.expectEqual(@as(u64, 0), response.usage.cached_tokens);
}

test "WireApi.fromString accepts auto and label round-trips" {
    try std.testing.expectEqual(types.WireApi.auto, types.WireApi.fromString("auto").?);
    try std.testing.expectEqualStrings("auto", types.WireApi.auto.label());
    try std.testing.expectEqual(types.WireApi.auto, types.WireApi.fromString(types.WireApi.auto.label()).?);
}

test "zai format emits top-level enable_thinking true when enabled" {
    const payload = try provider.testing.requestJson(std.testing.allocator, "glm-5.2", .{ .messages = &.{} }, false, "", .zai);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"enable_thinking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thinking\"") == null);
}

test "zai format emits enable_thinking false when thinking off" {
    const payload = try requestJsonWithThinking(std.testing.allocator, "glm-5.2", "off", .zai);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"enable_thinking\":false") != null);
}

test "deepseek format emits nested thinking enabled" {
    const payload = try requestJsonWithThinking(std.testing.allocator, "deepseek-v4-flash", "", .deepseek);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "enable_thinking") == null);
}

test "deepseek format emits nested thinking disabled when off" {
    const payload = try requestJsonWithThinking(std.testing.allocator, "deepseek-v4-flash", "off", .deepseek);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thinking\":{\"type\":\"disabled\"}") != null);
}

test "standard format omits thinking fields entirely" {
    const payload = try requestJsonWithThinking(std.testing.allocator, "gpt-4.1", "", .standard);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "enable_thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"thinking\"") == null);
}

test "deepseek forwards reasoning_content on assistant messages" {
    const messages = [_]types.ChatMessage{
        .{
            .role = .assistant,
            .content = @constCast("result"),
            .reasoning = @constCast("prior trace"),
        },
    };
    const payload = try requestJsonWithThinkingAndMessages(std.testing.allocator, "deepseek-v4-flash", "", .deepseek, messages[0..]);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"reasoning_content\":\"prior trace\"") != null);
}

test "standard format does not forward reasoning_content" {
    const messages = [_]types.ChatMessage{
        .{
            .role = .assistant,
            .content = @constCast("result"),
            .reasoning = @constCast("prior trace"),
        },
    };
    const payload = try requestJsonWithThinkingAndMessages(std.testing.allocator, "gpt-4.1", "", .standard, messages[0..]);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "reasoning_content") == null);
}

test "dispatch resolves auto wire api to chat adapter for zai base url" {
    var capture = CaptureTransport{};
    const config = try makeMinimalConfig(std.testing.allocator, "https://api.z.ai/api/coding/paas/v4", types.WireApi.auto);
    defer config.deinit(std.testing.allocator);

    const completion = try VAR1.core.provider_dispatch.completeWithTransportAndHooks(std.testing.allocator, config, .{
        .messages = &.{},
    }, .{
        .context = &capture,
        .sendFn = captureSend,
    }, .{});
    defer completion.deinit(std.testing.allocator);
    defer std.testing.allocator.free(capture.url);
    defer std.testing.allocator.free(capture.payload);

    try std.testing.expect(std.mem.indexOf(u8, capture.url, "/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.payload, "\"enable_thinking\":true") != null);
}

test "dispatch resolves auto wire api to anthropic adapter for anthropic base url" {
    var capture = CaptureTransport{};
    const config = try makeMinimalConfig(std.testing.allocator, "https://api.anthropic.com/v1", types.WireApi.auto);
    defer config.deinit(std.testing.allocator);

    const completion = try VAR1.core.provider_dispatch.completeWithTransportAndHooks(std.testing.allocator, config, .{
        .messages = &.{},
    }, .{
        .context = &capture,
        .sendFn = captureSend,
    }, .{});
    defer completion.deinit(std.testing.allocator);
    defer std.testing.allocator.free(capture.url);
    defer std.testing.allocator.free(capture.payload);

    // Anthropic Messages adapter requires max_tokens — a distinct wire shape.
    try std.testing.expect(std.mem.indexOf(u8, capture.payload, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.payload, "enable_thinking") == null);
}

const CaptureTransport = struct {
    url: []u8 = "",
    payload: []u8 = "",
};

fn captureSend(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var capture: *CaptureTransport = @ptrCast(@alignCast(ctx_ptr.?));
    capture.url = try allocator.dupe(u8, url);
    capture.payload = try allocator.dupe(u8, payload);
    return allocator.dupe(u8,
        \\{"model":"m","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
    );
}

fn makeMinimalConfig(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    wire_api: types.WireApi,
) !types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, base_url),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "test-model"),
        .max_steps = 10,
        .max_tool_calls_per_session = 96,
        .workspace_root = try allocator.dupe(u8, "."),
        .wire_api = wire_api,
    };
}

fn requestJsonWithThinking(
    allocator: std.mem.Allocator,
    model: []const u8,
    thinking_mode: []const u8,
    thinking_format: VAR1.core.provider_compat.ThinkingFormat,
) ![]u8 {
    return requestJsonWithThinkingAndMessages(allocator, model, thinking_mode, thinking_format, &.{});
}

fn requestJsonWithThinkingAndMessages(
    allocator: std.mem.Allocator,
    model: []const u8,
    thinking_mode: []const u8,
    thinking_format: VAR1.core.provider_compat.ThinkingFormat,
    messages: []const types.ChatMessage,
) ![]u8 {
    return provider.testing.requestJson(allocator, model, .{ .messages = messages }, false, thinking_mode, thinking_format);
}
