const std = @import("std");
const VAR1 = @import("VAR1");

const mailbox = VAR1.core.agent_mailbox;
const store = VAR1.core.session_store;
const types = VAR1.shared.types;

fn workspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn childReceipt(
    parent_session_id: []const u8,
    group_id: []const u8,
    task_id: []const u8,
    branch_seq: u64,
) types.ExecutionReceiptView {
    return .{
        .execution_kind = "agent_session",
        .agent_spec_id = "recon",
        .route_role = "recon",
        .provider_id = "test",
        .model = "test-model",
        .wire_api = "chat_completions",
        .thinking_mode = "disabled",
        .capability_profile_id = "recon",
        .capability_hash = "test-capability",
        .parent_session_id = parent_session_id,
        .parent_checkpoint_id = "parent-root",
        .group_id = group_id,
        .task_id = task_id,
        .branch_seq = branch_seq,
        .budget = .{ .max_steps = 4, .max_tool_calls = 4, .max_children = 0 },
        .output_schema_hash = "test-schema",
        .created_at_ms = 1,
    };
}

fn initChild(
    allocator: std.mem.Allocator,
    workspace: []const u8,
    parent_session_id: []const u8,
    group_id: []const u8,
    task_id: []const u8,
    branch_seq: u64,
) !types.SessionRecord {
    const receipt = childReceipt(parent_session_id, group_id, task_id, branch_seq);
    return store.initSessionWithExecutionReceipt(
        allocator,
        workspace,
        task_id,
        .{
            .parent_session_id = parent_session_id,
            .display_name = task_id,
            .agent_profile = "recon",
        },
        &receipt,
    );
}

fn countEvent(events: []const types.SessionEvent, event_type: []const u8) usize {
    var count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, event_type)) count += 1;
    }
    return count;
}

fn findEventSeq(events: []const types.SessionEvent, event_type: []const u8) ?u64 {
    for (events) |event| if (std.mem.eql(u8, event.event_type, event_type)) return event.seq;
    return null;
}

const DeliveryCapture = struct {
    calls: usize = 0,
    session_id: ?[]u8 = null,
    message: ?[]u8 = null,

    fn deinit(self: *DeliveryCapture, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.message) |value| allocator.free(value);
    }
};

fn captureDelivery(
    ctx: ?*anyopaque,
    session_id: []const u8,
    _: u64,
    event_type: []const u8,
    message: []const u8,
    _: i64,
) anyerror!void {
    var capture: *DeliveryCapture = @ptrCast(@alignCast(ctx.?));
    capture.calls += 1;
    capture.session_id = try std.testing.allocator.dupe(u8, session_id);
    capture.message = try std.testing.allocator.dupe(u8, message);
    try std.testing.expectEqualStrings(mailbox.received_event_type, event_type);
}

test "mailbox resolves direct parent current-group and nested-parent targets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspacePath(allocator, &tmp);
    defer allocator.free(workspace);

    var root = try store.initSession(allocator, workspace, "root");
    defer root.deinit(allocator);
    var sibling_a = try initChild(allocator, workspace, root.id, "group-one", "task-a", 1);
    defer sibling_a.deinit(allocator);
    var sibling_b = try initChild(allocator, workspace, root.id, "group-one", "task-b", 2);
    defer sibling_b.deinit(allocator);
    var nested = try initChild(allocator, workspace, sibling_a.id, "group-nested", "task-nested", 1);
    defer nested.deinit(allocator);

    var direct = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sibling_a.id,
        .tool_call_id = "call-direct",
        .target = .direct,
        .recipient_session_id = sibling_b.id,
        .delivery = .queue,
        .body = "Direct finding.",
        .references = &.{"summary:task-a"},
    });
    defer direct.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), direct.recipients.len);
    try std.testing.expectEqualStrings(sibling_b.id, direct.recipients[0].session_id);

    var parent = try mailbox.send(allocator, workspace, .{
        .sender_session_id = nested.id,
        .tool_call_id = "call-parent",
        .target = .parent,
        .delivery = .wake,
        .body = "Nested report.",
    });
    defer parent.deinit(allocator);
    try std.testing.expectEqualStrings(sibling_a.id, parent.recipients[0].session_id);

    var group = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sibling_a.id,
        .tool_call_id = "call-group",
        .target = .current_group,
        .delivery = .queue,
        .body = "Sibling challenge.",
    });
    defer group.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), group.recipients.len);
    try std.testing.expectEqualStrings(sibling_b.id, group.recipients[0].session_id);

    const sibling_events = try store.readEvents(allocator, workspace, sibling_b.id);
    defer types.deinitSessionEvents(allocator, sibling_events);
    try std.testing.expectEqual(@as(usize, 2), countEvent(sibling_events, mailbox.received_event_type));
    try std.testing.expectEqual(direct.recipients[0].seq, findEventSeq(sibling_events, mailbox.received_event_type).?);

    const nested_parent_events = try store.readEvents(allocator, workspace, sibling_a.id);
    defer types.deinitSessionEvents(allocator, nested_parent_events);
    try std.testing.expectEqual(@as(usize, 1), countEvent(nested_parent_events, mailbox.received_event_type));
}

test "mailbox replay is idempotent and never mutates recipient transcript" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspacePath(allocator, &tmp);
    defer allocator.free(workspace);

    var root = try store.initSession(allocator, workspace, "root");
    defer root.deinit(allocator);
    var sender = try initChild(allocator, workspace, root.id, "group-one", "task-a", 1);
    defer sender.deinit(allocator);
    var recipient = try initChild(allocator, workspace, root.id, "group-one", "task-b", 2);
    defer recipient.deinit(allocator);

    const before_messages = try store.readSessionMessages(allocator, workspace, recipient.id);
    defer types.deinitSessionMessages(allocator, before_messages);

    var first = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "stable-call",
        .target = .direct,
        .recipient_session_id = recipient.id,
        .delivery = .wake,
        .body = "One durable delivery.",
    });
    defer first.deinit(allocator);
    var replay = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "stable-call",
        .target = .direct,
        .recipient_session_id = recipient.id,
        .delivery = .wake,
        .body = "One durable delivery.",
    });
    defer replay.deinit(allocator);

    try std.testing.expectEqualStrings(first.message_id, replay.message_id);
    try std.testing.expectEqual(first.recipients[0].seq, replay.recipients[0].seq);
    try std.testing.expect(replay.replayed);

    const events = try store.readEvents(allocator, workspace, recipient.id);
    defer types.deinitSessionEvents(allocator, events);
    try std.testing.expectEqual(@as(usize, 1), countEvent(events, mailbox.received_event_type));

    const after_messages = try store.readSessionMessages(allocator, workspace, recipient.id);
    defer types.deinitSessionMessages(allocator, after_messages);
    try std.testing.expectEqual(before_messages.len, after_messages.len);
    for (before_messages, after_messages) |before, after| {
        try std.testing.expectEqual(before.seq, after.seq);
        try std.testing.expectEqualStrings(before.content, after.content);
    }
}

test "mailbox publishes the exact persisted delivery once after durable append" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspacePath(allocator, &tmp);
    defer allocator.free(workspace);

    var root = try store.initSession(allocator, workspace, "root");
    defer root.deinit(allocator);
    var sender = try initChild(allocator, workspace, root.id, "group-one", "task-a", 1);
    defer sender.deinit(allocator);
    var capture = DeliveryCapture{};
    defer capture.deinit(allocator);

    var receipt = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "sink-exact",
        .target = .parent,
        .delivery = .wake,
        .body = "Exact persisted sink payload.",
        .delivery_sink = .{ .context = &capture, .notifyFn = captureDelivery },
    });
    defer receipt.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualStrings(root.id, capture.session_id.?);

    const events = try store.readEvents(allocator, workspace, root.id);
    defer types.deinitSessionEvents(allocator, events);
    var persisted_message: ?[]const u8 = null;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, mailbox.received_event_type)) persisted_message = event.message;
    }
    try std.testing.expect(persisted_message != null);
    try std.testing.expectEqualStrings(persisted_message.?, capture.message.?);

    var replay = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "sink-exact",
        .target = .parent,
        .delivery = .wake,
        .body = "Exact persisted sink payload.",
        .delivery_sink = .{ .context = &capture, .notifyFn = captureDelivery },
    });
    defer replay.deinit(allocator);
    try std.testing.expect(replay.replayed);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "mailbox rejects invalid scope and budgets before append" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspacePath(allocator, &tmp);
    defer allocator.free(workspace);

    var root_a = try store.initSession(allocator, workspace, "root-a");
    defer root_a.deinit(allocator);
    var root_b = try store.initSession(allocator, workspace, "root-b");
    defer root_b.deinit(allocator);
    var only_child = try initChild(allocator, workspace, root_a.id, "solo-group", "only-child", 1);
    defer only_child.deinit(allocator);

    try std.testing.expectError(mailbox.Error.CrossTreeDelivery, mailbox.send(allocator, workspace, .{
        .sender_session_id = only_child.id,
        .tool_call_id = "cross-tree",
        .target = .direct,
        .recipient_session_id = root_b.id,
        .delivery = .queue,
        .body = "No.",
    }));
    try std.testing.expectError(mailbox.Error.SelfDelivery, mailbox.send(allocator, workspace, .{
        .sender_session_id = only_child.id,
        .tool_call_id = "self",
        .target = .direct,
        .recipient_session_id = only_child.id,
        .delivery = .queue,
        .body = "No.",
    }));
    try std.testing.expectError(mailbox.Error.EmptyRecipientSet, mailbox.send(allocator, workspace, .{
        .sender_session_id = only_child.id,
        .tool_call_id = "empty-group",
        .target = .current_group,
        .delivery = .queue,
        .body = "No peers.",
    }));

    const oversized = try allocator.alloc(u8, mailbox.max_body_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(mailbox.Error.MessageTooLarge, mailbox.send(allocator, workspace, .{
        .sender_session_id = only_child.id,
        .tool_call_id = "oversized",
        .target = .parent,
        .delivery = .queue,
        .body = oversized,
    }));

    const sender_events = try store.readEvents(allocator, workspace, only_child.id);
    defer types.deinitSessionEvents(allocator, sender_events);
    try std.testing.expectEqual(@as(usize, 0), countEvent(sender_events, mailbox.sent_event_type));
}

test "mailbox queue waits, wake drains in order, cursor survives reconstruction" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try workspacePath(allocator, &tmp);
    defer allocator.free(workspace);

    var root = try store.initSession(allocator, workspace, "root");
    defer root.deinit(allocator);
    var sender = try initChild(allocator, workspace, root.id, "group-one", "task-a", 1);
    defer sender.deinit(allocator);
    var recipient = try initChild(allocator, workspace, root.id, "group-one", "task-b", 2);
    defer recipient.deinit(allocator);

    const run_seq = try store.appendEventWithSeq(allocator, workspace, recipient.id, .{
        .event_type = "session_started",
        .message = "test run",
        .timestamp_ms = 10,
    });
    var queued = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "queued",
        .target = .direct,
        .recipient_session_id = recipient.id,
        .delivery = .queue,
        .body = "Wait for a turn.",
    });
    defer queued.deinit(allocator);
    try std.testing.expect((try mailbox.readUnreadBatch(allocator, workspace, recipient.id, run_seq)) == null);

    var waking = try mailbox.send(allocator, workspace, .{
        .sender_session_id = sender.id,
        .tool_call_id = "waking",
        .target = .direct,
        .recipient_session_id = recipient.id,
        .delivery = .wake,
        .body = "Process the mailbox.",
    });
    defer waking.deinit(allocator);

    var first_read = (try mailbox.readUnreadBatch(allocator, workspace, recipient.id, run_seq)).?;
    defer first_read.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), first_read.message_count);
    try std.testing.expect(first_read.has_wake);
    try std.testing.expect(std.mem.indexOf(u8, first_read.rendered, "Wait for a turn.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_read.rendered, "Process the mailbox.") != null);
    try std.testing.expect(queued.recipients[0].seq < waking.recipients[0].seq);
    try std.testing.expectEqual(waking.recipients[0].seq, first_read.through_seq);

    var replay = (try mailbox.readUnreadBatch(allocator, workspace, recipient.id, run_seq)).?;
    defer replay.deinit(allocator);
    try std.testing.expectEqualStrings(first_read.rendered, replay.rendered);
    try std.testing.expectEqual(first_read.through_seq, replay.through_seq);

    try mailbox.acknowledge(allocator, workspace, recipient.id, first_read.through_seq, run_seq);
    try std.testing.expect((try mailbox.readUnreadBatch(allocator, workspace, recipient.id, run_seq)) == null);

    const events = try store.readEvents(allocator, workspace, recipient.id);
    defer types.deinitSessionEvents(allocator, events);
    try std.testing.expectEqual(@as(usize, 1), countEvent(events, mailbox.cursor_event_type));
}

test "collaboration tool remains available to depth-zero recon and write agents" {
    const recon_definitions = VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .session_id = "session-recon",
        .capability_profile_id = "recon",
        .delegation_depth_remaining = 0,
    });
    const write_definitions = VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .session_id = "session-write",
        .capability_profile_id = "write",
        .delegation_depth_remaining = 0,
    });
    const model_task_definitions = VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .session_id = "session-model-task",
        .capability_profile_id = "model_task",
        .delegation_depth_remaining = 0,
    });

    var recon_has_mail = false;
    for (recon_definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "send_agent_message")) recon_has_mail = true;
    }
    var write_has_mail = false;
    for (write_definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "send_agent_message")) write_has_mail = true;
    }
    var model_task_has_mail = false;
    for (model_task_definitions) |definition| {
        if (std.mem.eql(u8, definition.name, "send_agent_message")) model_task_has_mail = true;
    }

    try std.testing.expect(recon_has_mail);
    try std.testing.expect(write_has_mail);
    try std.testing.expect(!model_task_has_mail);
    try std.testing.expectEqual(
        VAR1.core.agent_profile.ToolClass.collaboration,
        VAR1.core.tool_runtime.toolClassForName("send_agent_message").?,
    );
}
