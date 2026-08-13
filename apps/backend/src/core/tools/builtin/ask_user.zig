const std = @import("std");
const input_protocol = @import("../../../shared/protocol/input.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "ask_user",
    .description = "Ask the operator a bounded set of structured multiple-choice questions. Use this only when a user decision materially changes the work; continue autonomously when judgment is sufficient.",
    .review_risk = .interactive,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "questions": {
    \\      "type": "array",
    \\      "minItems": 1,
    \\      "maxItems": 60,
    \\      "items": {
    \\        "type": "object",
    \\        "properties": {
    \\          "id": { "type": "string", "maxLength": 64 },
    \\          "prompt": { "type": "string", "minLength": 1, "maxLength": 1024 },
    \\          "multiple": { "type": "boolean" },
    \\          "options": {
    \\            "type": "array",
    \\            "minItems": 2,
    \\            "maxItems": 5,
    \\            "items": {
    \\              "type": "object",
    \\              "properties": {
    \\                "label": { "type": "string", "minLength": 1, "maxLength": 256 },
    \\                "description": { "type": "string", "maxLength": 512 }
    \\              },
    \\              "required": ["label"],
    \\              "additionalProperties": false
    \\            }
    \\          }
    \\        },
    \\        "required": ["prompt", "options"],
    \\        "additionalProperties": false
    \\      }
    \\    }
    \\  },
    \\  "required": ["questions"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"questions\":[{\"prompt\":\"Which direction should I take?\",\"options\":[{\"label\":\"Fastest\"},{\"label\":\"Most maintainable\"}],\"multiple\":false}]}",
    .usage_hint = "Ask only when the operator's preference changes the result. Provide 2-5 concrete options; VANTARI adds f / Other for inline text. Batch related questions into one call, and keep autonomous work moving while no decision is needed.",
};

pub const definitions = [_]types.ToolDefinition{definition};
pub const availability = module.AvailabilitySpec{};

pub fn handles(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, definition.name);
}

const RawOption = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

const RawQuestion = struct {
    id: ?[]const u8 = null,
    prompt: []const u8,
    options: []RawOption,
    multiple: bool = false,
};

const Args = struct {
    questions: []RawQuestion,
};

const option_ids = [_][]const u8{ "a", "b", "c", "d", "e" };

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    tool_call_id: []const u8,
) ![]u8 {
    const session_id = execution_context.session_id orelse return module.Error.MissingParentSession;
    if (tool_call_id.len == 0) return module.Error.InvalidArguments;

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    if (parsed.value.questions.len == 0 or parsed.value.questions.len > input_protocol.max_questions) {
        return module.Error.InvalidArguments;
    }

    var question_ids = try allocator.alloc([]u8, parsed.value.questions.len);
    defer {
        for (question_ids) |id| allocator.free(id);
        allocator.free(question_ids);
    }
    var normalized_questions = try allocator.alloc(input_protocol.Question, parsed.value.questions.len);
    defer allocator.free(normalized_questions);
    var normalized_options = try allocator.alloc([]input_protocol.Option, parsed.value.questions.len);
    defer {
        for (normalized_options) |options| allocator.free(options);
        allocator.free(normalized_options);
    }

    for (parsed.value.questions, 0..) |question, question_index| {
        if (question.prompt.len == 0 or question.prompt.len > input_protocol.max_prompt_bytes or
            question.options.len < 2 or question.options.len > option_ids.len)
        {
            return module.Error.InvalidArguments;
        }

        question_ids[question_index] = if (question.id) |id| blk: {
            if (id.len == 0 or id.len > 64) return module.Error.InvalidArguments;
            break :blk try allocator.dupe(u8, id);
        } else try std.fmt.allocPrint(allocator, "q{d}", .{question_index + 1});

        const options = try allocator.alloc(input_protocol.Option, question.options.len + 1);
        normalized_options[question_index] = options;
        for (question.options, 0..) |option, option_index| {
            if (option.label.len == 0 or option.label.len > input_protocol.max_label_bytes) {
                return module.Error.InvalidArguments;
            }
            if (option.description) |description| {
                if (description.len > input_protocol.max_description_bytes) return module.Error.InvalidArguments;
            }
            options[option_index] = .{
                .id = option_ids[option_index],
                .label = option.label,
                .description = option.description,
            };
        }
        options[question.options.len] = .{
            .id = "f",
            .label = "Other",
            .description = "Type a custom answer inline.",
        };
        normalized_questions[question_index] = .{
            .id = question_ids[question_index],
            .prompt = question.prompt,
            .multiple = question.multiple,
            .options = options,
        };
    }

    const request_json = try input_protocol.serializeRequest(allocator, tool_call_id, normalized_questions);
    defer allocator.free(request_json);
    if (request_json.len > input_protocol.max_serialized_bytes) return module.Error.InvalidArguments;
    const response_json = try execution_context.input_service.request(
        allocator,
        session_id,
        tool_call_id,
        request_json,
    );
    defer allocator.free(response_json);
    return module.okEnvelope(allocator, definition.name, response_json);
}

test "ask_user normalizes choices to a-f with Other and rejects oversized batches" {
    const context = module.ExecutionContext{
        .workspace_root = "workspace",
        .session_id = "session-ask-user",
        .input_service = .{
            .context = null,
            .requestFn = captureRequest,
        },
    };
    const args = "{\"questions\":[{\"prompt\":\"Pick\",\"options\":[{\"label\":\"One\"},{\"label\":\"Two\"}]}]}";
    const result = try execute(std.testing.allocator, context, args, "call-ask-user");
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "var1.input_response.v1") != null);
}

fn captureRequest(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    request_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(input_protocol.Request, allocator, request_json, .{});
    defer parsed.deinit();
    if (parsed.value.questions.len != 1 or parsed.value.questions[0].options.len != 3) return error.InvalidRequest;
    if (!std.mem.eql(u8, parsed.value.questions[0].options[2].id, "f") or
        !std.mem.eql(u8, parsed.value.questions[0].options[2].label, "Other")) return error.InvalidRequest;
    return allocator.dupe(u8, "{\"schema\":\"var1.input_response.v1\",\"request_id\":\"call-ask-user\",\"answers\":[]}");
}
