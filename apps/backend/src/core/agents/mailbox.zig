const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

pub const received_event_type = "agent_message_received";
pub const sent_event_type = "agent_message_sent";
pub const cursor_event_type = "agent_mailbox_cursor";

pub const max_body_bytes: usize = 4 * 1024;
pub const max_reference_count: usize = 8;
pub const max_reference_bytes: usize = 512;
pub const max_recipient_count: usize = 64;
pub const max_context_messages: usize = 16;
pub const max_context_bytes: usize = 16 * 1024;

pub const Error = error{
    CorruptMailboxEvent,
    CrossTreeDelivery,
    EmptyMessage,
    EmptyRecipientSet,
    InvalidCursor,
    InvalidTarget,
    MessageConflict,
    MessageTooLarge,
    MissingParent,
    MissingRecipient,
    RecipientLimitExceeded,
    ReferenceLimitExceeded,
    ReferenceTooLarge,
    SelfDelivery,
    SessionTreeCycle,
    UnknownSession,
};

pub const Target = enum {
    direct,
    parent,
    current_group,

    pub fn label(self: Target) []const u8 {
        return switch (self) {
            .direct => "direct",
            .parent => "parent",
            .current_group => "current_group",
        };
    }

    pub fn parse(value: []const u8) Error!Target {
        if (std.mem.eql(u8, value, "direct")) return .direct;
        if (std.mem.eql(u8, value, "parent")) return .parent;
        if (std.mem.eql(u8, value, "current_group")) return .current_group;
        return Error.InvalidTarget;
    }
};

pub const Delivery = enum {
    queue,
    wake,

    pub fn label(self: Delivery) []const u8 {
        return switch (self) {
            .queue => "queue",
            .wake => "wake",
        };
    }

    pub fn parse(value: []const u8) Error!Delivery {
        if (std.mem.eql(u8, value, "queue")) return .queue;
        if (std.mem.eql(u8, value, "wake")) return .wake;
        return Error.InvalidTarget;
    }
};

pub const SendRequest = struct {
    sender_session_id: []const u8,
    tool_call_id: []const u8,
    target: Target,
    recipient_session_id: ?[]const u8 = null,
    delivery: Delivery,
    body: []const u8,
    references: []const []const u8 = &.{},
    delivery_sink: DeliverySink = .{},
};

pub const DeliverySink = struct {
    context: ?*anyopaque = null,
    notifyFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,

    pub fn notify(
        self: DeliverySink,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.notifyFn) |callback| {
            try callback(self.context, session_id, seq, event_type, message, timestamp_ms);
        }
    }
};

pub const RecipientReceipt = struct {
    session_id: []u8,
    seq: u64,

    fn deinit(self: RecipientReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
    }
};

pub const DeliveryReceipt = struct {
    message_id: []u8,
    target: Target,
    delivery: Delivery,
    recipients: []RecipientReceipt,
    replayed: bool = false,

    pub fn deinit(self: *DeliveryReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.message_id);
        for (self.recipients) |recipient| recipient.deinit(allocator);
        allocator.free(self.recipients);
        self.* = undefined;
    }

    pub fn renderJson(self: DeliveryReceipt, allocator: std.mem.Allocator) ![]u8 {
        const View = struct {
            schema: []const u8 = "var1.agent_message_receipt.v1",
            ok: bool = true,
            message_id: []const u8,
            target: []const u8,
            delivery: []const u8,
            replayed: bool,
            recipients: []const RecipientReceipt,
        };
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(View{
            .message_id = self.message_id,
            .target = self.target.label(),
            .delivery = self.delivery.label(),
            .replayed = self.replayed,
            .recipients = self.recipients,
        }, .{})});
    }
};

pub const UnreadBatch = struct {
    rendered: []u8,
    through_seq: u64,
    message_count: usize,
    has_wake: bool,

    pub fn deinit(self: *UnreadBatch, allocator: std.mem.Allocator) void {
        allocator.free(self.rendered);
        self.* = undefined;
    }
};

const ReceivedPayload = struct {
    schema: []const u8 = "var1.agent_message.v1",
    message_id: []const u8,
    fingerprint: []const u8,
    sender_session_id: []const u8,
    target: []const u8,
    target_group_id: ?[]const u8 = null,
    recipient_session_id: []const u8,
    delivery: []const u8,
    body: []const u8,
    references: []const []const u8 = &.{},
    sent_at_ms: i64,
};

const ParsedReceivedPayload = struct {
    schema: []const u8,
    message_id: []const u8,
    fingerprint: []const u8,
    sender_session_id: []const u8,
    target: []const u8,
    target_group_id: ?[]const u8 = null,
    recipient_session_id: []const u8,
    delivery: []const u8,
    body: []const u8,
    references: []const []const u8 = &.{},
    sent_at_ms: i64,
};

const SentPayload = struct {
    schema: []const u8 = "var1.agent_message_receipt.v1",
    message_id: []const u8,
    fingerprint: []const u8,
    sender_session_id: []const u8,
    target: []const u8,
    target_group_id: ?[]const u8 = null,
    delivery: []const u8,
    recipients: []const RecipientReceipt,
    sent_at_ms: i64,
};

const ParsedRecipientReceipt = struct {
    session_id: []const u8,
    seq: u64,
};

const ParsedSentPayload = struct {
    schema: []const u8,
    message_id: []const u8,
    fingerprint: []const u8,
    sender_session_id: []const u8,
    target: []const u8,
    target_group_id: ?[]const u8 = null,
    delivery: []const u8,
    recipients: []const ParsedRecipientReceipt,
    sent_at_ms: i64,
};

const CursorPayload = struct {
    schema: []const u8 = "var1.agent_mailbox_cursor.v1",
    through_seq: u64,
    observed_run_seq: u64,
    observed_at_ms: i64,
};

const ParsedCursorPayload = struct {
    schema: []const u8,
    through_seq: u64,
    observed_run_seq: u64 = 0,
    observed_at_ms: i64 = 0,
};

var mutation_mutex: std.Thread.Mutex = .{};

pub fn send(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    request: SendRequest,
) !DeliveryReceipt {
    try validateRequest(request);

    mutation_mutex.lock();
    defer mutation_mutex.unlock();

    const sessions = try store.listSessionRecords(allocator, workspace_root);
    defer types.deinitSessionRecords(allocator, sessions);
    const sender = findSession(sessions, request.sender_session_id) orelse return Error.UnknownSession;

    var recipient_ids = std.array_list.Managed([]const u8).init(allocator);
    defer recipient_ids.deinit();
    const target_group_id = try resolveRecipients(sessions, sender, request, &recipient_ids);
    if (recipient_ids.items.len == 0) return Error.EmptyRecipientSet;
    if (recipient_ids.items.len > max_recipient_count) return Error.RecipientLimitExceeded;
    std.mem.sort([]const u8, recipient_ids.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    const message_id = try messageId(allocator, request.sender_session_id, request.tool_call_id);
    errdefer allocator.free(message_id);
    const fingerprint = requestFingerprint(request);

    if (try readSentReceipt(allocator, workspace_root, request, message_id, fingerprint[0..])) |existing| {
        allocator.free(message_id);
        return existing;
    }

    const now_ms = std.time.milliTimestamp();
    var recipients = std.array_list.Managed(RecipientReceipt).init(allocator);
    errdefer {
        for (recipients.items) |recipient| recipient.deinit(allocator);
        recipients.deinit();
    }

    for (recipient_ids.items) |recipient_session_id| {
        const existing_seq = try findReceivedSequence(
            allocator,
            workspace_root,
            recipient_session_id,
            message_id,
            fingerprint[0..],
        );
        var notification_payload: ?[]u8 = null;
        defer if (notification_payload) |payload_json| allocator.free(payload_json);
        const seq = existing_seq orelse blk: {
            const payload = ReceivedPayload{
                .message_id = message_id,
                .fingerprint = fingerprint[0..],
                .sender_session_id = request.sender_session_id,
                .target = request.target.label(),
                .target_group_id = target_group_id,
                .recipient_session_id = recipient_session_id,
                .delivery = request.delivery.label(),
                .body = request.body,
                .references = request.references,
                .sent_at_ms = now_ms,
            };
            const payload_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
            notification_payload = payload_json;
            break :blk try store.appendEventWithSeq(allocator, workspace_root, recipient_session_id, .{
                .event_type = received_event_type,
                .message = payload_json,
                .timestamp_ms = now_ms,
            });
        };
        try recipients.append(.{
            .session_id = try allocator.dupe(u8, recipient_session_id),
            .seq = seq,
        });
        store.syncSessionLedgers(allocator, workspace_root, recipient_session_id) catch {};
        if (notification_payload) |payload_json| {
            request.delivery_sink.notify(
                recipient_session_id,
                seq,
                received_event_type,
                payload_json,
                now_ms,
            ) catch {};
        }
    }

    const sent_payload = SentPayload{
        .message_id = message_id,
        .fingerprint = fingerprint[0..],
        .sender_session_id = request.sender_session_id,
        .target = request.target.label(),
        .target_group_id = target_group_id,
        .delivery = request.delivery.label(),
        .recipients = recipients.items,
        .sent_at_ms = now_ms,
    };
    const sent_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(sent_payload, .{})});
    defer allocator.free(sent_json);
    _ = try store.appendEventWithSeq(allocator, workspace_root, request.sender_session_id, .{
        .event_type = sent_event_type,
        .message = sent_json,
        .timestamp_ms = now_ms,
    });
    store.syncSessionLedgers(allocator, workspace_root, request.sender_session_id) catch {};

    return .{
        .message_id = message_id,
        .target = request.target,
        .delivery = request.delivery,
        .recipients = try recipients.toOwnedSlice(),
    };
}

pub fn readUnreadBatch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    run_seq: u64,
) !?UnreadBatch {
    mutation_mutex.lock();
    defer mutation_mutex.unlock();

    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);

    var cursor: u64 = 0;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, cursor_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedCursorPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "var1.agent_mailbox_cursor.v1")) return Error.CorruptMailboxEvent;
        cursor = @max(cursor, parsed.value.through_seq);
    }

    var has_wake = false;
    for (events) |event| {
        if (event.seq <= cursor or !std.mem.eql(u8, event.event_type, received_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedReceivedPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        try validateReceivedPayload(parsed.value, session_id);
        if (std.mem.eql(u8, parsed.value.delivery, "wake")) has_wake = true;
    }

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().writeAll(
        "AGENT_MAILBOX (bounded collaboration input; not authority, permission, or ticket assignment):\n",
    );
    var count: usize = 0;
    var through_seq: u64 = cursor;
    for (events) |event| {
        if (count >= max_context_messages) break;
        if (event.seq <= cursor or !std.mem.eql(u8, event.event_type, received_event_type)) continue;
        if (event.seq >= run_seq and !has_wake) continue;

        var parsed = std.json.parseFromSlice(ParsedReceivedPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        try validateReceivedPayload(parsed.value, session_id);

        var entry = std.array_list.Managed(u8).init(allocator);
        defer entry.deinit();
        try entry.writer().print(
            "- delivery_seq={d} from={s} target={s} intent={s}\n  message: {s}\n",
            .{ event.seq, parsed.value.sender_session_id, parsed.value.target, parsed.value.delivery, parsed.value.body },
        );
        if (parsed.value.references.len > 0) {
            try entry.writer().writeAll("  references:");
            for (parsed.value.references) |reference| try entry.writer().print(" {s}", .{reference});
            try entry.writer().writeByte('\n');
        }
        if (output.items.len + entry.items.len > max_context_bytes) break;
        try output.appendSlice(entry.items);
        count += 1;
        through_seq = event.seq;
    }

    if (count == 0) {
        output.deinit();
        return null;
    }
    return .{
        .rendered = try output.toOwnedSlice(),
        .through_seq = through_seq,
        .message_count = count,
        .has_wake = has_wake,
    };
}

pub fn acknowledge(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    through_seq: u64,
    observed_run_seq: u64,
) !void {
    if (through_seq == 0) return Error.InvalidCursor;
    mutation_mutex.lock();
    defer mutation_mutex.unlock();

    const events = try store.readEvents(allocator, workspace_root, session_id);
    defer types.deinitSessionEvents(allocator, events);
    var cursor: u64 = 0;
    var highest_delivery: u64 = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, received_event_type)) highest_delivery = @max(highest_delivery, event.seq);
        if (!std.mem.eql(u8, event.event_type, cursor_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedCursorPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "var1.agent_mailbox_cursor.v1")) return Error.CorruptMailboxEvent;
        cursor = @max(cursor, parsed.value.through_seq);
    }
    if (through_seq <= cursor) return;
    if (through_seq > highest_delivery) return Error.InvalidCursor;

    const now_ms = std.time.milliTimestamp();
    const payload = CursorPayload{
        .through_seq = through_seq,
        .observed_run_seq = observed_run_seq,
        .observed_at_ms = now_ms,
    };
    const payload_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload, .{})});
    defer allocator.free(payload_json);
    _ = try store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = cursor_event_type,
        .message = payload_json,
        .timestamp_ms = now_ms,
    });
    store.syncSessionLedgers(allocator, workspace_root, session_id) catch {};
}

pub fn hasEligibleUnread(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    run_seq: u64,
) !bool {
    if (try readUnreadBatch(allocator, workspace_root, session_id, run_seq)) |batch_value| {
        var batch = batch_value;
        batch.deinit(allocator);
        return true;
    }
    return false;
}

fn validateRequest(request: SendRequest) !void {
    if (request.sender_session_id.len == 0 or request.tool_call_id.len == 0) return Error.UnknownSession;
    if (request.body.len == 0) return Error.EmptyMessage;
    if (request.body.len > max_body_bytes) return Error.MessageTooLarge;
    if (request.references.len > max_reference_count) return Error.ReferenceLimitExceeded;
    for (request.references) |reference| {
        if (reference.len == 0 or reference.len > max_reference_bytes) return Error.ReferenceTooLarge;
    }
    switch (request.target) {
        .direct => if (request.recipient_session_id == null or request.recipient_session_id.?.len == 0) return Error.MissingRecipient,
        .parent, .current_group => if (request.recipient_session_id != null) return Error.InvalidTarget,
    }
}

fn resolveRecipients(
    sessions: []const types.SessionRecord,
    sender: *const types.SessionRecord,
    request: SendRequest,
    recipients: *std.array_list.Managed([]const u8),
) !?[]const u8 {
    switch (request.target) {
        .direct => {
            const recipient_id = request.recipient_session_id.?;
            if (std.mem.eql(u8, sender.id, recipient_id)) return Error.SelfDelivery;
            _ = findSession(sessions, recipient_id) orelse return Error.UnknownSession;
            const sender_root = try rootSessionId(sessions, sender.id);
            const recipient_root = try rootSessionId(sessions, recipient_id);
            if (!std.mem.eql(u8, sender_root, recipient_root)) return Error.CrossTreeDelivery;
            try recipients.append(recipient_id);
            return null;
        },
        .parent => {
            const parent_id = sender.parent_session_id orelse return Error.MissingParent;
            _ = findSession(sessions, parent_id) orelse return Error.UnknownSession;
            try recipients.append(parent_id);
            return null;
        },
        .current_group => {
            const sender_receipt = sender.execution_receipt orelse return Error.EmptyRecipientSet;
            for (sessions) |*candidate| {
                if (std.mem.eql(u8, candidate.id, sender.id)) continue;
                const candidate_receipt = candidate.execution_receipt orelse continue;
                if (!std.mem.eql(u8, candidate_receipt.group_id, sender_receipt.group_id)) continue;
                if (!std.mem.eql(u8, candidate_receipt.parent_session_id, sender_receipt.parent_session_id)) continue;
                try recipients.append(candidate.id);
            }
            return sender_receipt.group_id;
        },
    }
}

fn findSession(sessions: []const types.SessionRecord, session_id: []const u8) ?*const types.SessionRecord {
    for (sessions) |*session| {
        if (std.mem.eql(u8, session.id, session_id)) return session;
    }
    return null;
}

fn rootSessionId(sessions: []const types.SessionRecord, session_id: []const u8) ![]const u8 {
    var current = findSession(sessions, session_id) orelse return Error.UnknownSession;
    var remaining = sessions.len + 1;
    while (current.parent_session_id) |parent_id| {
        if (remaining == 0 or std.mem.eql(u8, current.id, parent_id)) return Error.SessionTreeCycle;
        remaining -= 1;
        current = findSession(sessions, parent_id) orelse return Error.UnknownSession;
    }
    return current.id;
}

fn messageId(allocator: std.mem.Allocator, sender_session_id: []const u8, tool_call_id: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(sender_session_id);
    hasher.update("\x00");
    hasher.update(tool_call_id);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = digestHex(digest);
    return std.fmt.allocPrint(allocator, "message-{s}", .{hex[0..]});
}

fn requestFingerprint(request: SendRequest) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const fields = [_][]const u8{
        request.sender_session_id,
        request.target.label(),
        request.recipient_session_id orelse "",
        request.delivery.label(),
        request.body,
    };
    for (fields) |field| {
        hasher.update(field);
        hasher.update("\x00");
    }
    for (request.references) |reference| {
        hasher.update(reference);
        hasher.update("\x00");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digestHex(digest);
}

fn digestHex(digest: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[index * 2 + 1] = hex_chars[@as(usize, byte & 0x0f)];
    }
    return hex;
}

pub fn hasSentReceipt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    sender_session_id: []const u8,
    tool_call_id: []const u8,
) !bool {
    mutation_mutex.lock();
    defer mutation_mutex.unlock();

    const expected_message_id = try messageId(allocator, sender_session_id, tool_call_id);
    defer allocator.free(expected_message_id);
    const events = try store.readEvents(allocator, workspace_root, sender_session_id);
    defer types.deinitSessionEvents(allocator, events);
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, sent_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedSentPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "var1.agent_message_receipt.v1")) return Error.CorruptMailboxEvent;
        if (!std.mem.eql(u8, parsed.value.sender_session_id, sender_session_id)) return Error.CorruptMailboxEvent;
        if (std.mem.eql(u8, parsed.value.message_id, expected_message_id)) return true;
    }
    return false;
}

fn readSentReceipt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    request: SendRequest,
    message_id: []const u8,
    fingerprint: []const u8,
) !?DeliveryReceipt {
    const events = try store.readEvents(allocator, workspace_root, request.sender_session_id);
    defer types.deinitSessionEvents(allocator, events);
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, sent_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedSentPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "var1.agent_message_receipt.v1")) return Error.CorruptMailboxEvent;
        if (!std.mem.eql(u8, parsed.value.message_id, message_id)) continue;
        if (!std.mem.eql(u8, parsed.value.fingerprint, fingerprint)) return Error.MessageConflict;

        var recipients = try allocator.alloc(RecipientReceipt, parsed.value.recipients.len);
        errdefer allocator.free(recipients);
        var initialized: usize = 0;
        errdefer for (recipients[0..initialized]) |recipient| recipient.deinit(allocator);
        for (parsed.value.recipients, 0..) |recipient, index| {
            recipients[index] = .{
                .session_id = try allocator.dupe(u8, recipient.session_id),
                .seq = recipient.seq,
            };
            initialized += 1;
        }
        return .{
            .message_id = try allocator.dupe(u8, parsed.value.message_id),
            .target = request.target,
            .delivery = request.delivery,
            .recipients = recipients,
            .replayed = true,
        };
    }
    return null;
}

fn findReceivedSequence(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    recipient_session_id: []const u8,
    message_id: []const u8,
    fingerprint: []const u8,
) !?u64 {
    const events = try store.readEvents(allocator, workspace_root, recipient_session_id);
    defer types.deinitSessionEvents(allocator, events);
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, received_event_type)) continue;
        var parsed = std.json.parseFromSlice(ParsedReceivedPayload, allocator, event.message, .{
            .ignore_unknown_fields = false,
        }) catch return Error.CorruptMailboxEvent;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "var1.agent_message.v1")) return Error.CorruptMailboxEvent;
        if (!std.mem.eql(u8, parsed.value.message_id, message_id)) continue;
        if (!std.mem.eql(u8, parsed.value.fingerprint, fingerprint)) return Error.MessageConflict;
        return event.seq;
    }
    return null;
}

fn validateReceivedPayload(payload: ParsedReceivedPayload, session_id: []const u8) !void {
    if (!std.mem.eql(u8, payload.schema, "var1.agent_message.v1")) return Error.CorruptMailboxEvent;
    if (!std.mem.eql(u8, payload.recipient_session_id, session_id)) return Error.CorruptMailboxEvent;
    if (payload.body.len == 0 or payload.body.len > max_body_bytes) return Error.CorruptMailboxEvent;
    if (payload.references.len > max_reference_count) return Error.CorruptMailboxEvent;
    for (payload.references) |reference| if (reference.len == 0 or reference.len > max_reference_bytes) return Error.CorruptMailboxEvent;
    _ = try Target.parse(payload.target);
    _ = try Delivery.parse(payload.delivery);
}
