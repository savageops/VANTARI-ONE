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
