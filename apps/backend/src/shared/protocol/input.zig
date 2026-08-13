const std = @import("std");

pub const request_schema = "var1.input_requested.v1";
pub const response_schema = "var1.input_response.v1";

pub const max_questions: usize = 60;
pub const max_options: usize = 6;
pub const max_prompt_bytes: usize = 1024;
pub const max_label_bytes: usize = 256;
pub const max_description_bytes: usize = 512;
pub const max_other_bytes: usize = 2048;
pub const max_serialized_bytes: usize = 64 * 1024;

pub const Option = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const Question = struct {
    id: []const u8,
    prompt: []const u8,
    multiple: bool = false,
    options: []const Option,
};

pub const Request = struct {
    schema: []const u8 = request_schema,
    request_id: []const u8,
    kind: []const u8 = "question",
    questions: []const Question,
};

pub const Answer = struct {
    question_id: []const u8,
    selected: []const []const u8 = &.{},
    other: ?[]const u8 = null,
};

pub const Response = struct {
    schema: []const u8 = response_schema,
    request_id: []const u8,
    cancelled: bool = false,
    answers: []const Answer = &.{},
};

pub fn serializeRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    questions: []const Question,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(Request{
        .request_id = request_id,
        .questions = questions,
    }, .{})});
}

pub fn serializeResponse(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    cancelled: bool,
    answers: []const Answer,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(Response{
        .request_id = request_id,
        .cancelled = cancelled,
        .answers = answers,
    }, .{})});
}

test "input protocol serializes a typed questionnaire and response" {
    const questions = [_]Question{.{
        .id = "q1",
        .prompt = "Choose a direction",
        .options = &[_]Option{
            .{ .id = "a", .label = "Fast" },
            .{ .id = "f", .label = "Other", .description = "Type a custom answer." },
        },
    }};
    const request = try serializeRequest(std.testing.allocator, "call-1", &questions);
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "var1.input_requested.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Choose a direction") != null);

    const selected = [_][]const u8{"a"};
    const answers = [_]Answer{.{ .question_id = "q1", .selected = &selected }};
    const response = try serializeResponse(std.testing.allocator, "call-1", false, &answers);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "var1.input_response.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"selected\":[\"a\"]") != null);
}
