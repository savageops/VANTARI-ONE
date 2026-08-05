const std = @import("std");
const VAR1 = @import("VAR1");

const provider = VAR1.core.provider_runtime;
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
    }, true);
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
