const std = @import("std");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");
const prompts = @import("../../prompts/index.zig");

pub const definition = types.ToolDefinition{
    .name = "set_prompt_mode",
    .description = "Switch the session's prompt mode at runtime. The change is durable (persists across turns) and observable (emits a prompt_mode_changed event). Use this to shift between orchestrate, build, align, and plan postures mid-session when the task phase changes.",
    .review_risk = .interactive,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "mode": {
    \\      "type": "string",
    \\      "enum": ["orchestrate", "build", "align", "plan"],
    \\      "description": "The target prompt mode."
    \\    },
    \\    "reason": {
    \\      "type": "string",
    \\      "maxLength": 240,
    \\      "description": "Bounded explanation for the mode change."
    \\    }
    \\  },
    \\  "required": ["mode"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"mode\":\"build\",\"reason\":\"Implementation phase; direct action preferred.\"}",
    .usage_hint = "Switch modes when the task phase changes (e.g. alignment complete, moving to build). Same-mode calls are no-ops with no event.",
};

pub const definitions = [_]types.ToolDefinition{definition};
pub const availability = module.AvailabilitySpec{};

pub fn handles(tool_name: []const u8) bool {
    return std.mem.eql(u8, tool_name, definition.name);
}

const Args = struct {
    mode: []const u8,
    reason: []const u8 = "",
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    tool_call_id: []const u8,
) ![]u8 {
    _ = tool_call_id;
    const session_id = execution_context.session_id orelse return module.Error.MissingParentSession;
    const service = execution_context.prompt_mode_service orelse return module.Error.ToolUnavailable;

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const target_mode = prompts.PromptMode.fromString(parsed.value.mode) orelse
        return module.Error.InvalidArguments;

    const reason = if (parsed.value.reason.len > 240)
        parsed.value.reason[0..240]
    else
        parsed.value.reason;

    try service.set(allocator, session_id, target_mode.label(), reason);

    const content = try std.fmt.allocPrint(allocator, "{{\"mode\":{f}}}", .{std.json.fmt(target_mode.label(), .{})});
    defer allocator.free(content);
    return module.okEnvelope(allocator, definition.name, content);
}

// --- test harness ---

const FakePromptModeService = struct {
    label_buf: [64]u8 = undefined,
    reason_buf: [256]u8 = undefined,
    label_len: usize = 0,
    reason_len: usize = 0,
    call_count: u32 = 0,

    fn setFn(
        ctx: ?*anyopaque,
        _: std.mem.Allocator,
        _: []const u8,
        mode_label: []const u8,
        reason: []const u8,
    ) anyerror!void {
        const self: *FakePromptModeService = @ptrCast(@alignCast(ctx.?));
        self.call_count += 1;
        const label_copy_len = @min(mode_label.len, self.label_buf.len);
        @memcpy(self.label_buf[0..label_copy_len], mode_label[0..label_copy_len]);
        self.label_len = label_copy_len;
        const reason_copy_len = @min(reason.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..reason_copy_len], reason[0..reason_copy_len]);
        self.reason_len = reason_copy_len;
    }

    fn service(self: *FakePromptModeService) module.PromptModeService {
        return .{
            .context = self,
            .setFn = FakePromptModeService.setFn,
        };
    }
};

fn makeContextWithService(fake: *FakePromptModeService) module.ExecutionContext {
    return .{
        .workspace_root = "workspace",
        .session_id = "session-test",
        .prompt_mode_service = fake.service(),
    };
}

test "set_prompt_mode rejects unknown mode label with InvalidArguments and zero service calls" {
    var fake: FakePromptModeService = .{};
    const context = makeContextWithService(&fake);
    const args = "{\"mode\":\"nonexistent\",\"reason\":\"test\"}";
    try std.testing.expectError(module.Error.InvalidArguments, execute(
        std.testing.allocator,
        context,
        args,
        "call-set-prompt-mode-invalid",
    ));
    try std.testing.expectEqual(@as(u32, 0), fake.call_count);
}

test "set_prompt_mode invokes service with exact label and truncates reason to 240 bytes" {
    var fake: FakePromptModeService = .{};
    const context = makeContextWithService(&fake);

    // 300-char reason — should be truncated to 240
    var long_reason_buf: [300]u8 = undefined;
    @memset(&long_reason_buf, 'x');
    const long_reason = long_reason_buf[0..300];
    const args = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"mode\":\"build\",\"reason\":\"{s}\"}}",
        .{long_reason},
    );
    defer std.testing.allocator.free(args);

    const output = try execute(
        std.testing.allocator,
        context,
        args,
        "call-set-prompt-mode-build",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(u32, 1), fake.call_count);
    try std.testing.expectEqualStrings("build", fake.label_buf[0..fake.label_len]);
    try std.testing.expectEqual(@as(usize, 240), fake.reason_len);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\\"mode\\\":\\\"build\\\"") != null);
}

test "set_prompt_mode returns ToolUnavailable when prompt_mode_service is null" {
    const context = module.ExecutionContext{
        .workspace_root = "workspace",
        .session_id = "session-test",
    };
    // Valid args but no service wired → ToolUnavailable before any parsing.
    const args = "{\"mode\":\"build\",\"reason\":\"test\"}";
    try std.testing.expectError(module.Error.ToolUnavailable, execute(
        std.testing.allocator,
        context,
        args,
        "call-set-prompt-mode-null",
    ));
}
