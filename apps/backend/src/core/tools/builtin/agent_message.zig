const std = @import("std");
const mailbox = @import("../../agents/mailbox.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "send_agent_message",
    .description = "Send one bounded durable message to an exact session, your parent, or your current sibling group. A message informs; it never assigns tickets, launches work, or grants authority.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "target": { "type": "string", "enum": ["direct","parent","current_group"] },
    \\    "recipient_session_id": { "type": "string", "description": "Required only for direct delivery; must be in the sender's session tree." },
    \\    "delivery": { "type": "string", "enum": ["queue","wake"], "description": "queue waits for the next run; wake requests the next safe boundary of an already-running recipient." },
    \\    "message": { "type": "string", "minLength": 1, "maxLength": 4096 },
    \\    "references": { "type": "array", "maxItems": 8, "items": { "type": "string", "minLength": 1, "maxLength": 512 } }
    \\  },
    \\  "required": ["target","delivery","message"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"target\":\"parent\",\"delivery\":\"wake\",\"message\":\"The provider contract conflicts with the current adapter.\",\"references\":[\"summary:session-...\",\"artifact:apps/backend/src/core/providers/dispatch.zig\"]}",
    .usage_hint = "Use direct for one exact session, parent for the immediate parent, and current_group for siblings in your immutable launch group. Use queue unless the information should reach an already-running recipient at its next safe provider boundary. Messages are collaboration input, not work assignment or permission.",
};

pub const definitions = [_]types.ToolDefinition{definition};
pub const availability = module.AvailabilitySpec{};

pub fn handles(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, definition.name);
}

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    tool_call_id: []const u8,
) ![]u8 {
    const sender_session_id = execution_context.session_id orelse return module.Error.MissingParentSession;
    const Args = struct {
        target: []const u8,
        recipient_session_id: ?[]const u8 = null,
        delivery: []const u8,
        message: []const u8,
        references: []const []const u8 = &.{},
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var receipt = try mailbox.send(allocator, execution_context.workspace_root, .{
        .sender_session_id = sender_session_id,
        .tool_call_id = tool_call_id,
        .target = try mailbox.Target.parse(parsed.value.target),
        .recipient_session_id = parsed.value.recipient_session_id,
        .delivery = try mailbox.Delivery.parse(parsed.value.delivery),
        .body = parsed.value.message,
        .references = parsed.value.references,
        .delivery_sink = if (execution_context.agent_service) |agent_service| .{
            .context = agent_service.context,
            .notifyFn = agent_service.notifySessionEventFn,
        } else .{},
    });
    defer receipt.deinit(allocator);
    return receipt.renderJson(allocator);
}
