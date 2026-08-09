const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const history = VAR1.core.session_history;
const commands = @import("commands.zig");
const settings_view = @import("settings_view.zig");

const protocol = VAR1.core.protocol_types;
const stdio_rpc = VAR1.host.stdio_rpc;

const TextInput = tui.widgets.TextInput;
const Window = tui.Window;
const Style = tui.Cell.Style;
const Color = tui.Cell.Color;

const Event = union(enum) {
    key_press: tui.Key,
    mouse: tui.Mouse,
    winsize: tui.Winsize,
    focus_in,
    focus_out,
};

pub const StartupMode = enum {
    blank,
    continue_latest,
};

const Role = enum {
    user,
    assistant,
    progress,
    system,
};

const ActivityKind = enum {
    none,
    group,
    item,
};

const ActivityState = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

const AgentCounts = struct {
    running: usize = 0,
    total: usize = 0,
};

const stream_min_frame_ns: u64 = 16 * std.time.ns_per_ms;
const stream_max_adaptive_frame_ns: u64 = 100 * std.time.ns_per_ms;
const stream_idle_wait_ms: usize = 100;
const max_notifications_per_frame: usize = 128;

fn nextStreamWaitMs(redraw_pending: bool, elapsed_ns: u64, frame_interval_ns: u64) usize {
    if (!redraw_pending) return stream_idle_wait_ms;
    if (elapsed_ns >= frame_interval_ns) return 0;

    const remaining_ns = frame_interval_ns - elapsed_ns;
    const rounded_ms = (remaining_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
    return @min(stream_idle_wait_ms, @max(@as(usize, 1), @as(usize, @intCast(rounded_ms))));
}

const Message = struct {
    role: Role,
    text: []u8,
    text_capacity: usize = 0,
    tool_call_id: ?[]u8 = null,
    activity_parent_id: ?[]u8 = null,
    activity_kind: ActivityKind = .none,
    activity_state: ActivityState = .pending,
    activity_last: bool = false,
    pending: bool = false,

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        self.freeText(allocator);
        if (self.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        if (self.activity_parent_id) |parent_id| allocator.free(parent_id);
    }

    fn freeText(self: Message, allocator: std.mem.Allocator) void {
        if (self.text_capacity == 0) {
            allocator.free(self.text);
        } else {
            allocator.free(self.text.ptr[0..self.text_capacity]);
        }
    }

    fn replaceTextOwned(self: *Message, allocator: std.mem.Allocator, replacement: []u8) void {
        self.freeText(allocator);
        self.text = replacement;
        self.text_capacity = 0;
    }

    fn appendText(self: *Message, allocator: std.mem.Allocator, suffix: []const u8) !void {
        if (suffix.len == 0) return;
        if (suffix.len > std.math.maxInt(usize) - self.text.len) return error.OutOfMemory;

        const previous_len = self.text.len;
        const required_len = previous_len + suffix.len;
        const current_capacity = if (self.text_capacity == 0) previous_len else self.text_capacity;

        if (required_len > current_capacity) {
            const next_capacity = @max(required_len, @max(@as(usize, 64), current_capacity *| 2));
            const storage = if (self.text_capacity == 0) blk: {
                const allocated = try allocator.alloc(u8, next_capacity);
                @memcpy(allocated[0..previous_len], self.text);
                allocator.free(self.text);
                break :blk allocated;
            } else try allocator.realloc(self.text.ptr[0..self.text_capacity], next_capacity);

            self.text = storage[0..required_len];
            self.text_capacity = next_capacity;
        } else {
            self.text = self.text.ptr[0..required_len];
        }

        @memcpy(self.text[previous_len..], suffix);
    }
};

const ChatState = struct {
    allocator: std.mem.Allocator,
    client: *stdio_rpc.LocalClient,
    workspace_root: []const u8,
    model: []const u8,
    base_url: []const u8,
    auth_provider: []const u8,
    plan: []const u8,
    subscription_status: []const u8,
    effort: []const u8 = "",
    thinking_mode: []const u8 = "",
    context_window_tokens: u64 = 0,
    reserve_output_tokens: u64 = 0,
    /// Latest context compiler estimate from the typed turn boundary event.
    /// Null is intentional before the first provider turn or after a cold
    /// start with no replayable turn telemetry.
    context_used_tokens: ?u64 = null,
    session_id: ?[]u8 = null,
    status: []const u8 = "READY",
    messages: std.ArrayList(Message) = .{},
    seen_progress_events: std.ArrayList([]u8) = .{},
    scroll_offset: usize = 0,
    waiting: bool = false,
    cancel_requested: bool = false,
    received_assistant_delta: bool = false,
    pending_assistant_placeholder: bool = false,
    /// Accumulated reasoning trace buffer — all reasoning_delta tokens
    /// are appended here and rendered as a single dimmed block, not
    /// one row per token.
    reasoning_buffer: std.ArrayList(u8) = .{},
    last_notification_sequence: u64 = 0,
    last_transcript_body_width: usize = 80,
    history_entries: std.ArrayList([]u8) = .{},
    history_cursor: usize = 0,
    history_draft: ?[]u8 = null,
    /// Buffer model preview text — shown in the reasoning dock when the
    /// heavyweight model is not actively reasoning. Populated by the buffer
    /// model (draft/buffer layer). When null or empty, the dock collapses.
    buffer_preview: ?[]u8 = null,
    /// In-TUI settings overlay state. Null when closed. Initialized by the
    /// /settings command. When non-null and .open, the draw function renders
    /// the settings overlay instead of the normal transcript+footer.
    settings_state: ?settings_view.SettingsState = null,

    fn deinit(self: *ChatState) void {
        if (self.session_id) |value| self.allocator.free(value);
        for (self.messages.items) |message| message.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        for (self.seen_progress_events.items) |event_key| self.allocator.free(event_key);
        self.seen_progress_events.deinit(self.allocator);
        self.reasoning_buffer.deinit(self.allocator);
        for (self.history_entries.items) |entry| self.allocator.free(entry);
        self.history_entries.deinit(self.allocator);
        if (self.history_draft) |draft| self.allocator.free(draft);
        if (self.buffer_preview) |preview| self.allocator.free(preview);
        if (self.settings_state) |*ss| ss.deinit();
    }

    fn appendHistory(self: *ChatState, prompt: []const u8) !void {
        if (prompt.len == 0) return;
        const max_history = 1000;
        if (self.history_entries.items.len >= max_history) {
            const oldest = self.history_entries.orderedRemove(0);
            self.allocator.free(oldest);
        }
        try self.history_entries.append(self.allocator, try self.allocator.dupe(u8, prompt));
        self.history_cursor = 0;
        if (self.history_draft) |draft| {
            self.allocator.free(draft);
            self.history_draft = null;
        }
        // Persist to the global history file — fire-and-forget. A write failure
        // does not block the TUI; the in-memory ring buffer still works.
        history.appendHistoryEntry(self.allocator, self.workspace_root, prompt) catch {};
    }

    fn historyNavigateUp(self: *ChatState, input: *TextInput) !void {
        if (self.history_entries.items.len == 0) return;
        if (self.history_cursor >= self.history_entries.items.len) return;
        if (self.history_cursor == 0) {
            const current = try input.toOwnedSlice();
            defer self.allocator.free(current);
            if (current.len > 0) {
                self.history_draft = try self.allocator.dupe(u8, current);
            }
        }
        self.history_cursor += 1;
        const idx = self.history_entries.items.len - self.history_cursor;
        input.clearAndFree();
        try input.insertSliceAtCursor(self.history_entries.items[idx]);
    }

    fn historyNavigateDown(self: *ChatState, input: *TextInput) !void {
        if (self.history_cursor == 0) return;
        self.history_cursor -= 1;
        input.clearAndFree();
        if (self.history_cursor == 0) {
            if (self.history_draft) |draft| {
                try input.insertSliceAtCursor(draft);
            }
        } else {
            const idx = self.history_entries.items.len - self.history_cursor;
            try input.insertSliceAtCursor(self.history_entries.items[idx]);
        }
    }

    /// Set the buffer model's navigation preview text. Shown in the reasoning
    /// dock when the heavyweight model is not actively reasoning. Pass null or
    /// empty to clear the preview and collapse the dock to idle.
    fn setBufferPreview(self: *ChatState, preview: ?[]const u8) !void {
        if (self.buffer_preview) |old| self.allocator.free(old);
        self.buffer_preview = if (preview) |text|
            if (text.len > 0) try self.allocator.dupe(u8, text) else null
        else
            null;
    }

    pub fn add(self: *ChatState, role: Role, text: []const u8) !void {
        if (self.scroll_offset > 0) {
            self.scroll_offset += messageRowCount(role, text, false, self.last_transcript_body_width);
        }
        try self.messages.append(self.allocator, .{
            .role = role,
            .text = try self.allocator.dupe(u8, text),
        });
    }

    fn loadLatestSession(self: *ChatState) !bool {
        const list_call = try self.client.call(protocol.methods.session_list, "{}");
        defer list_call.deinit(self.allocator);
        const list_result_json = try expectKernelResult(self.allocator, list_call);
        defer self.allocator.free(list_result_json);

        var parsed_list = try std.json.parseFromSlice(protocol.SessionListResult, self.allocator, list_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_list.deinit();

        if (parsed_list.value.sessions.len == 0) return false;
        try self.loadSession(parsed_list.value.sessions[0].session_id);
        return true;
    }

    fn loadSession(self: *ChatState, session_id: []const u8) !void {
        const params = try renderJsonAlloc(self.allocator, .{ .session_id = session_id });
        defer self.allocator.free(params);

        const get_call = try self.client.call(protocol.methods.session_get, params);
        defer get_call.deinit(self.allocator);
        const get_result_json = try expectKernelResult(self.allocator, get_call);
        defer self.allocator.free(get_result_json);

        var parsed_get = try std.json.parseFromSlice(protocol.SessionGetResult, self.allocator, get_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_get.deinit();

        if (self.session_id) |value| self.allocator.free(value);
        self.session_id = try self.allocator.dupe(u8, parsed_get.value.session.session_id);
        self.status = "READY";

        for (self.messages.items) |message| message.deinit(self.allocator);
        self.messages.clearRetainingCapacity();
        for (self.seen_progress_events.items) |event_key| self.allocator.free(event_key);
        self.seen_progress_events.clearRetainingCapacity();
        self.last_notification_sequence = 0;
        self.scroll_offset = 0;
        self.waiting = false;
        self.cancel_requested = false;
        self.received_assistant_delta = false;
        self.pending_assistant_placeholder = false;
        self.clearReasoningBuffer();

        try self.hydrateTranscript(parsed_get.value.messages);
        for (parsed_get.value.events) |event| {
            _ = try self.markProgressEventSeen(event.event_type, event.message, event.timestamp_ms);
            if (replayProgressEvent(event.event_type)) try self.addProgress(event.event_type, event.message);
        }
        self.jumpToBottom();
    }

    fn hydrateTranscript(self: *ChatState, messages: []const VAR1.shared.types.SessionMessage) !void {
        for (messages) |message| {
            switch (message.role) {
                .user => try self.add(.user, message.content),
                .assistant => if (message.content.len > 0) try self.add(.assistant, message.content),
                .tool => if (message.content.len > 0) {
                    const preview = try formatToolTranscriptMessage(self.allocator, message.content);
                    defer self.allocator.free(preview);
                    try self.add(.progress, preview);
                },
            }
        }
    }

    fn submit(
        self: *ChatState,
        prompt: []const u8,
        vx: *tui.Vaxis,
        tty: *tui.Tty,
        loop: *tui.Loop(Event),
        writer: anytype,
        input: *TextInput,
    ) !void {
        if (prompt.len == 0) return;
        self.jumpToBottom();
        self.clearReasoningBuffer();
        try self.add(.user, prompt);
        try self.appendHistory(prompt);
        self.status = "RUNNING";
        self.waiting = true;
        self.cancel_requested = false;
        self.received_assistant_delta = false;
        try self.startAssistantPlaceholder();
        input.clearAndFree();
        try draw(vx, writer, self, input);
        defer self.waiting = false;

        const turn = self.executePromptTurn(prompt, vx, tty, loop, writer, input) catch |err| {
            self.status = "RPC_ERROR";
            self.removeAssistantPlaceholder();
            const text = try std.fmt.allocPrint(self.allocator, "Transport failure: {s}", .{@errorName(err)});
            defer self.allocator.free(text);
            try self.add(.system, text);
            return;
        };
        defer if (turn.output) |output| self.allocator.free(output);
        defer if (turn.failure_reason) |reason| self.allocator.free(reason);

        if (turn.failure_reason) |reason| {
            self.status = "FAILED";
            self.removeAssistantPlaceholder();
            const text = try std.fmt.allocPrint(self.allocator, "Session {s} failed: {s}", .{ turn.session_id, reason });
            defer self.allocator.free(text);
            try self.add(.system, text);
            return;
        }

        self.status = "READY";
        if (turn.output) |output| {
            if (!self.received_assistant_delta) {
                if (!try self.replaceAssistantPlaceholder(output)) try self.add(.assistant, output);
            }
        } else {
            self.removeAssistantPlaceholder();
            try self.add(.system, "Session completed without model output.");
        }
    }

    const PromptTurn = struct {
        session_id: []const u8,
        output: ?[]u8 = null,
        failure_reason: ?[]u8 = null,
    };

    fn executePromptTurn(
        self: *ChatState,
        prompt: []const u8,
        vx: *tui.Vaxis,
        tty: *tui.Tty,
        loop: *tui.Loop(Event),
        writer: anytype,
        input: *TextInput,
    ) !PromptTurn {
        const existing_session_id = self.session_id;
        const session_id = if (existing_session_id) |value|
            value
        else blk: {
            const create_params = try renderJsonAlloc(self.allocator, .{
                .prompt = prompt,
                .enable_agent_tools = true,
            });
            defer self.allocator.free(create_params);

            const create_call = try self.client.call(protocol.methods.session_create, create_params);
            defer create_call.deinit(self.allocator);
            const create_result_json = try expectKernelResult(self.allocator, create_call);
            defer self.allocator.free(create_result_json);

            var parsed_create = try std.json.parseFromSlice(protocol.SessionCreateResult, self.allocator, create_result_json, .{
                .ignore_unknown_fields = true,
            });
            defer parsed_create.deinit();

            const owned = try self.allocator.dupe(u8, parsed_create.value.session.session_id);
            self.session_id = owned;
            break :blk owned;
        };

        const send_params = if (existing_session_id != null)
            try renderJsonAlloc(self.allocator, .{
                .session_id = session_id,
                .prompt = prompt,
                .enable_agent_tools = true,
            })
        else
            try renderJsonAlloc(self.allocator, .{
                .session_id = session_id,
                .enable_agent_tools = true,
            });
        var send_job = SendJob{
            .allocator = self.allocator,
            .client = self.client,
            .params_json = send_params,
        };
        defer send_job.deinit();

        const thread = try std.Thread.spawn(.{}, runSessionSend, .{&send_job});

        var render_clock = try std.time.Timer.start();
        var last_render_finished_ns = render_clock.read();
        var last_frame_cost_ns: u64 = 0;
        var redraw_pending = false;

        // Fold every notification burst into one frame. The cadence follows
        // the reference TUI invariant: never discard stream state, never paint
        // faster than the terminal can absorb, and keep input responsive.
        while (!send_job.isDone()) {
            const now_ns = render_clock.read();
            const adaptive_frame_ns = @max(
                stream_min_frame_ns,
                @min(stream_max_adaptive_frame_ns, last_frame_cost_ns *| 2),
            );
            const wait_ms = nextStreamWaitMs(
                redraw_pending,
                now_ns -| last_render_finished_ns,
                adaptive_frame_ns,
            );

            var changed = try self.drainProgress(session_id, wait_ms);
            if (try self.drainUiEventsDuringTurn(vx, tty, loop, session_id, input)) changed += 1;
            redraw_pending = redraw_pending or changed > 0;

            const ready_ns = render_clock.read();
            if (redraw_pending and ready_ns -| last_render_finished_ns >= adaptive_frame_ns) {
                const frame_start_ns = ready_ns;
                try draw(vx, writer, self, input);
                const frame_end_ns = render_clock.read();
                last_frame_cost_ns = frame_end_ns -| frame_start_ns;
                last_render_finished_ns = frame_end_ns;
                redraw_pending = false;
            }
        }
        thread.join();
        if (try self.drainProgress(session_id, 0) > 0) redraw_pending = true;
        if (redraw_pending) try draw(vx, writer, self, input);

        if (send_job.err) |err| return err;
        const send_call = send_job.result orelse return error.InvalidRpcResponse;
        const send_result_json = try expectKernelResult(self.allocator, send_call);
        defer self.allocator.free(send_result_json);

        var parsed_send = try std.json.parseFromSlice(protocol.SessionSendResult, self.allocator, send_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_send.deinit();

        return .{
            .session_id = session_id,
            .output = if (parsed_send.value.session.output) |value| try self.allocator.dupe(u8, value) else null,
            .failure_reason = if (parsed_send.value.session.failure_reason) |value| try self.allocator.dupe(u8, value) else null,
        };
    }

    fn drainProgress(self: *ChatState, session_id: []const u8, timeout_ms: usize) !usize {
        var changed: usize = 0;
        var processed: usize = 0;
        var wait_ms = timeout_ms;
        while (true) {
            const notification = try self.client.waitForNotificationAfter(self.last_notification_sequence, wait_ms) orelse return changed;
            self.last_notification_sequence = notification.sequence;
            const notification_changed = self.recordProgressNotification(session_id, notification) catch |err| {
                notification.deinit(self.allocator);
                return err;
            };
            notification.deinit(self.allocator);
            if (notification_changed) changed += 1;

            processed += 1;
            wait_ms = 0;
            if (timeout_ms > 0 and processed >= max_notifications_per_frame) return changed;
        }
    }

    fn recordProgressNotification(self: *ChatState, session_id: []const u8, notification: stdio_rpc.Notification) !bool {
        if (!std.mem.eql(u8, notification.method, protocol.notification_methods.session_event)) return false;
        var parsed = std.json.parseFromSlice(protocol.SessionEventNotification, self.allocator, notification.params_json, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.session_id, session_id)) return false;
        return try self.recordProgressEvent(parsed.value.event_type, parsed.value.message, parsed.value.timestamp_ms);
    }

    fn recordProgressEvent(self: *ChatState, event_type: []const u8, message: []const u8, timestamp_ms: i64) !bool {
        if (!try self.markProgressEventSeen(event_type, message, timestamp_ms)) return false;

        if (try self.recordTurnTelemetry(event_type, message)) return true;
        if (std.mem.eql(u8, event_type, "assistant_delta")) {
            try self.addAssistantDelta(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "reasoning_delta")) {
            try self.addReasoningDelta(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "buffer_preview")) {
            try self.setBufferPreview(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "user_message_queued")) return true;
        if (std.mem.eql(u8, event_type, "user_message_injected")) return true;
        if (skipProgressEvent(event_type)) return false;

        try self.addProgress(event_type, message);
        return true;
    }

    fn recordTurnTelemetry(self: *ChatState, event_type: []const u8, message: []const u8) !bool {
        if (!std.mem.eql(u8, event_type, "turn_started") and
            !std.mem.eql(u8, event_type, "turn_finished")) return false;

        const TurnTelemetry = struct {
            window_tokens: u64 = 0,
        };
        var parsed = std.json.parseFromSlice(TurnTelemetry, self.allocator, message, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        self.context_used_tokens = parsed.value.window_tokens;
        return true;
    }

    fn markProgressEventSeen(self: *ChatState, event_type: []const u8, message: []const u8, timestamp_ms: i64) !bool {
        const key = try std.fmt.allocPrint(self.allocator, "{d}\x1f{s}\x1f{s}", .{ timestamp_ms, event_type, message });
        errdefer self.allocator.free(key);

        for (self.seen_progress_events.items) |seen| {
            if (std.mem.eql(u8, seen, key)) {
                self.allocator.free(key);
                return false;
            }
        }

        try self.seen_progress_events.append(self.allocator, key);
        if (self.seen_progress_events.items.len > max_seen_progress_events) {
            const dropped = self.seen_progress_events.orderedRemove(0);
            self.allocator.free(dropped);
        }
        return true;
    }

    fn addProgress(self: *ChatState, event_type: []const u8, message: []const u8) !void {
        if (std.mem.eql(u8, event_type, "child_convergence_started") or
            std.mem.eql(u8, event_type, "session_waiting")) return;
        if (std.mem.startsWith(u8, event_type, "child_")) {
            try self.upsertChildProgress(event_type, message);
            return;
        }
        if (std.mem.eql(u8, event_type, "tool_requested") or std.mem.eql(u8, event_type, "tool_completed")) return;
        if (std.mem.eql(u8, event_type, "tool_started")) {
            try self.upsertToolStarted(message);
            return;
        }
        if (std.mem.eql(u8, event_type, "tool_finished")) {
            try self.upsertToolFinished(message);
            return;
        }
        if (std.mem.eql(u8, event_type, "tool_output_delta")) {
            try self.upsertToolOutputDelta(message);
            return;
        }

        const maybe_text = try formatProgress(self.allocator, event_type, message);
        const text = maybe_text orelse return;
        defer self.allocator.free(text);
        if (!std.mem.eql(u8, event_type, "tool_output_delta") and self.hasProgress(text)) return;
        self.removeAssistantPlaceholder();
        try self.add(.progress, text);
    }

    fn upsertChildProgress(self: *ChatState, event_type: []const u8, message: []const u8) !void {
        if (std.mem.eql(u8, event_type, "child_group_started") or
            std.mem.eql(u8, event_type, "child_group_finished") or
            std.mem.eql(u8, event_type, "child_group_recovered"))
        {
            const GroupEvent = struct {
                group_id: []const u8 = "",
                queued: usize = 0,
                running: usize = 0,
                completed: usize = 0,
                failed: usize = 0,
                cancelled: usize = 0,
                tasks: usize = 0,
                stale_owners_reconciled: usize = 0,
                terminal: bool = false,
            };
            var parsed = std.json.parseFromSlice(GroupEvent, self.allocator, message, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            if (parsed.value.group_id.len == 0) return;
            const pending = parsed.value.queued + parsed.value.running;
            const recovered = std.mem.eql(u8, event_type, "child_group_recovered");
            const finished = if (recovered) parsed.value.tasks else parsed.value.completed + parsed.value.failed + parsed.value.cancelled;
            const failed = if (recovered) parsed.value.stale_owners_reconciled else parsed.value.failed;
            const total = pending + finished;
            const state: ActivityState = if (!parsed.value.terminal)
                .running
            else if (failed > 0)
                .failed
            else if (parsed.value.cancelled > 0 and parsed.value.completed == 0)
                .cancelled
            else
                .completed;
            const text = if (parsed.value.terminal and failed == 0 and parsed.value.cancelled == 0)
                try std.fmt.allocPrint(self.allocator, "Agents {d}/{d}", .{ finished, finished })
            else if (parsed.value.terminal)
                try std.fmt.allocPrint(self.allocator, "Agents {d}/{d} - {d} failed, {d} cancelled", .{ finished, finished, failed, parsed.value.cancelled })
            else
                try std.fmt.allocPrint(self.allocator, "Agents {d}/{d} - waiting on {d}", .{ finished, total, pending });
            defer self.allocator.free(text);
            const key = try std.fmt.allocPrint(self.allocator, "group:{s}", .{parsed.value.group_id});
            defer self.allocator.free(key);
            try self.upsertActivityProgress(key, text, .group, state, null);
            return;
        }

        const ChildEvent = struct {
            group_id: []const u8 = "",
            task_id: []const u8 = "",
            name: []const u8 = "agent",
            status: []const u8 = "queued",
            phase: ?[]const u8 = null,
            detail: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(ChildEvent, self.allocator, message, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        if (parsed.value.group_id.len == 0 or parsed.value.task_id.len == 0) return;
        const phase = parsed.value.phase orelse parsed.value.status;
        const state: ActivityState = if (std.mem.eql(u8, event_type, "child_waiting"))
            .running
        else
            activityStateFromLabel(parsed.value.status);
        const text = if (state == .completed)
            try self.allocator.dupe(u8, parsed.value.name)
        else if (std.mem.eql(u8, event_type, "child_finished") and parsed.value.detail != null)
            try std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ parsed.value.name, parsed.value.detail.? })
        else
            try std.fmt.allocPrint(self.allocator, "{s} - {s}", .{ parsed.value.name, phase });
        defer self.allocator.free(text);
        const key = try std.fmt.allocPrint(self.allocator, "agent:{s}:{s}", .{ parsed.value.group_id, parsed.value.task_id });
        defer self.allocator.free(key);
        try self.upsertActivityProgress(key, text, .item, state, parsed.value.group_id);
    }

    fn upsertToolStarted(self: *ChatState, message: []const u8) !void {
        const ToolStarted = struct {
            tool_call_id: []const u8 = "",
            tool: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(ToolStarted, self.allocator, message, .{
            .ignore_unknown_fields = true,
        }) catch {
            const fallback = (try formatProgress(self.allocator, "tool_started", message)) orelse return;
            defer self.allocator.free(fallback);
            return self.addToolProgress("", fallback);
        };
        defer parsed.deinit();

        if (parsed.value.tool.len == 0) return;
        if (isAgentLifecycleTool(parsed.value.tool)) return;
        try self.upsertActivityProgress(
            parsed.value.tool_call_id,
            activityTitle(parsed.value.tool),
            .group,
            .running,
            null,
        );
    }

    fn upsertToolFinished(self: *ChatState, message: []const u8) !void {
        const ToolFinished = struct {
            tool_call_id: []const u8 = "",
            tool: []const u8 = "",
            ok: bool = false,
            error_name: ?[]const u8 = null,
            hint: ?[]const u8 = null,
            duration_ms: i64 = 0,
        };
        var parsed = std.json.parseFromSlice(ToolFinished, self.allocator, message, .{
            .ignore_unknown_fields = true,
        }) catch {
            const fallback = (try formatProgress(self.allocator, "tool_finished", message)) orelse return;
            defer self.allocator.free(fallback);
            return self.addToolProgress("", fallback);
        };
        defer parsed.deinit();

        if (isAgentLifecycleTool(parsed.value.tool)) return;

        const tool = activityTitle(if (parsed.value.tool.len == 0) "tool" else parsed.value.tool);
        var text = if (parsed.value.ok)
            try std.fmt.allocPrint(self.allocator, "{s} - {d}ms", .{ tool, parsed.value.duration_ms })
        else if (parsed.value.error_name) |error_name|
            if (parsed.value.hint) |hint|
                try std.fmt.allocPrint(self.allocator, "{s} - {s} - {d}ms - {s}", .{ tool, error_name, parsed.value.duration_ms, hint })
            else
                try std.fmt.allocPrint(self.allocator, "{s} - {s} - {d}ms", .{ tool, error_name, parsed.value.duration_ms })
        else
            try std.fmt.allocPrint(self.allocator, "{s} - failed - {d}ms", .{ tool, parsed.value.duration_ms });
        text = try trimOwnedProgress(self.allocator, text);
        defer self.allocator.free(text);
        const state: ActivityState = if (parsed.value.ok) .completed else .failed;
        try self.upsertActivityProgress(parsed.value.tool_call_id, text, .group, state, null);
        self.setActivityChildrenState(parsed.value.tool_call_id, state);
    }

    fn addToolProgress(self: *ChatState, tool_call_id: []const u8, text: []const u8) !void {
        return self.upsertActivityProgress(tool_call_id, text, .none, .pending, null);
    }

    fn upsertActivityProgress(
        self: *ChatState,
        activity_id: []const u8,
        text: []const u8,
        kind: ActivityKind,
        state: ActivityState,
        parent_id: ?[]const u8,
    ) !void {
        self.removeAssistantPlaceholder();
        if (activity_id.len > 0) {
            for (self.messages.items) |*message| {
                if (message.role != .progress) continue;
                const existing = message.tool_call_id orelse continue;
                if (!std.mem.eql(u8, existing, activity_id)) continue;

                const replacement = try self.allocator.dupe(u8, text);
                message.replaceTextOwned(self.allocator, replacement);
                message.activity_kind = kind;
                message.activity_state = state;
                return;
            }
        }

        if (self.scroll_offset > 0) {
            self.scroll_offset += messageRowCount(.progress, text, false, self.last_transcript_body_width);
        }
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const owned_activity_id = if (activity_id.len == 0) null else try self.allocator.dupe(u8, activity_id);
        errdefer if (owned_activity_id) |value| self.allocator.free(value);
        const owned_parent_id = if (parent_id) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (owned_parent_id) |value| self.allocator.free(value);

        if (parent_id) |value| self.markPriorActivitySiblings(value);
        try self.messages.append(self.allocator, .{
            .role = .progress,
            .text = owned_text,
            .tool_call_id = owned_activity_id,
            .activity_parent_id = owned_parent_id,
            .activity_kind = kind,
            .activity_state = state,
            .activity_last = kind == .item,
        });
    }

    fn markPriorActivitySiblings(self: *ChatState, parent_id: []const u8) void {
        for (self.messages.items) |*message| {
            const existing_parent = message.activity_parent_id orelse continue;
            if (std.mem.eql(u8, existing_parent, parent_id)) message.activity_last = false;
        }
    }

    fn setActivityChildrenState(self: *ChatState, parent_id: []const u8, state: ActivityState) void {
        for (self.messages.items) |*message| {
            const existing_parent = message.activity_parent_id orelse continue;
            if (std.mem.eql(u8, existing_parent, parent_id)) message.activity_state = state;
        }
    }

    fn upsertToolOutputDelta(self: *ChatState, message: []const u8) !void {
        const ToolOutputDelta = struct {
            tool_call_id: []const u8 = "",
            stream: []const u8 = "",
        };
        var parsed = std.json.parseFromSlice(ToolOutputDelta, self.allocator, message, .{
            .ignore_unknown_fields = true,
        }) catch {
            const fallback = (try formatProgress(self.allocator, "tool_output_delta", message)) orelse return;
            defer self.allocator.free(fallback);
            return self.add(.progress, fallback);
        };
        defer parsed.deinit();

        const formatted = (try formatProgress(self.allocator, "tool_output_delta", message)) orelse return;
        defer self.allocator.free(formatted);

        if (parsed.value.tool_call_id.len == 0 or parsed.value.stream.len == 0) {
            return self.add(.progress, formatted);
        }

        const key = try std.fmt.allocPrint(self.allocator, "{s}\x1eoutput\x1e{s}", .{ parsed.value.tool_call_id, parsed.value.stream });
        defer self.allocator.free(key);
        try self.appendToolProgress(key, parsed.value.tool_call_id, parsed.value.stream, formatted);
    }

    fn appendToolProgress(self: *ChatState, progress_key: []const u8, parent_id: []const u8, stream: []const u8, formatted: []const u8) !void {
        self.removeAssistantPlaceholder();
        for (self.messages.items) |*message| {
            if (message.role != .progress) continue;
            const existing = message.tool_call_id orelse continue;
            if (!std.mem.eql(u8, existing, progress_key)) continue;

            const next = try appendBoundedProgress(self.allocator, message.text, stream, formatted);
            message.replaceTextOwned(self.allocator, next);
            message.activity_state = .running;
            return;
        }

        try self.upsertActivityProgress(progress_key, formatted, .item, .running, parent_id);
    }

    fn addAssistantDelta(self: *ChatState, delta: []const u8) !void {
        if (delta.len == 0) return;
        self.received_assistant_delta = true;

        if (try self.replaceAssistantPlaceholder(delta)) return;

        if (self.messages.items.len > 0) {
            const last_index = self.messages.items.len - 1;
            if (self.messages.items[last_index].role == .assistant) {
                const previous = self.messages.items[last_index].text;
                const previous_rows = messageRowCount(.assistant, previous, false, self.last_transcript_body_width);
                try self.messages.items[last_index].appendText(self.allocator, delta);
                const expanded = self.messages.items[last_index].text;
                if (self.scroll_offset > 0) {
                    const next_rows = messageRowCount(.assistant, expanded, false, self.last_transcript_body_width);
                    if (next_rows > previous_rows) self.scroll_offset += next_rows - previous_rows;
                }
                return;
            }
        }

        try self.add(.assistant, delta);
    }

    /// Accumulate reasoning trace tokens into a single buffer, rendered as
    /// one dimmed block. This avoids one-row-per-token flooding the TUI.
    fn addReasoningDelta(self: *ChatState, delta: []const u8) !void {
        if (delta.len == 0) return;
        try self.reasoning_buffer.appendSlice(self.allocator, delta);
    }

    /// Clear the reasoning buffer (called when a new turn starts).
    fn clearReasoningBuffer(self: *ChatState) void {
        self.reasoning_buffer.clearRetainingCapacity();
    }

    fn startAssistantPlaceholder(self: *ChatState) !void {
        self.removeAssistantPlaceholder();
        if (self.scroll_offset > 0) {
            self.scroll_offset += messageRowCount(.assistant, "", true, self.last_transcript_body_width);
        }
        try self.messages.append(self.allocator, .{
            .role = .assistant,
            .text = try self.allocator.dupe(u8, ""),
            .pending = true,
        });
        self.pending_assistant_placeholder = true;
    }

    fn replaceAssistantPlaceholder(self: *ChatState, text: []const u8) !bool {
        if (!self.pending_assistant_placeholder) return false;
        if (self.messages.items.len == 0) {
            self.pending_assistant_placeholder = false;
            return false;
        }

        const last_index = self.messages.items.len - 1;
        const last = &self.messages.items[last_index];
        if (last.role != .assistant or !last.pending) {
            self.removeAssistantPlaceholder();
            return false;
        }

        const previous_rows = messageRowCount(.assistant, last.text, true, self.last_transcript_body_width);
        const replacement = try self.allocator.dupe(u8, text);
        last.replaceTextOwned(self.allocator, replacement);
        last.pending = false;
        self.pending_assistant_placeholder = false;
        if (self.scroll_offset > 0) {
            const next_rows = messageRowCount(.assistant, text, false, self.last_transcript_body_width);
            if (next_rows > previous_rows) {
                self.scroll_offset += next_rows - previous_rows;
            } else {
                self.scroll_offset -|= previous_rows - next_rows;
            }
        }
        return true;
    }

    fn removeAssistantPlaceholder(self: *ChatState) void {
        if (!self.pending_assistant_placeholder) return;
        var index = self.messages.items.len;
        while (index > 0) {
            index -= 1;
            const message = self.messages.items[index];
            if (message.role == .assistant and message.pending) {
                const removed = self.messages.orderedRemove(index);
                if (self.scroll_offset > 0) {
                    self.scroll_offset -|= messageRowCount(removed.role, removed.text, removed.pending, self.last_transcript_body_width);
                }
                removed.deinit(self.allocator);
                break;
            }
        }
        self.pending_assistant_placeholder = false;
    }

    fn hasProgress(self: *const ChatState, text: []const u8) bool {
        for (self.messages.items) |message| {
            if (message.role == .progress and std.mem.eql(u8, message.text, text)) return true;
        }
        return false;
    }

    fn agentCounts(self: *const ChatState) AgentCounts {
        var counts = AgentCounts{};
        for (self.messages.items) |message| {
            if (message.role != .progress or
                message.activity_kind != .item or
                message.activity_parent_id == null) continue;

            counts.total += 1;
            if (message.activity_state == .running) counts.running += 1;
        }
        return counts;
    }

    fn scrollUp(self: *ChatState, amount: usize) void {
        self.scroll_offset = @min(self.scroll_offset + amount, self.maxScrollOffsetRows());
    }

    fn scrollDown(self: *ChatState, amount: usize) void {
        self.scroll_offset -|= amount;
    }

    fn jumpToBottom(self: *ChatState) void {
        self.scroll_offset = 0;
    }

    fn maxScrollOffsetRows(self: *const ChatState) usize {
        const rows = transcriptRowCount(self, self.last_transcript_body_width);
        return if (rows == 0) 0 else rows - 1;
    }

    fn drainUiEventsDuringTurn(
        self: *ChatState,
        vx: *tui.Vaxis,
        tty: *tui.Tty,
        loop: *tui.Loop(Event),
        session_id: []const u8,
        input: *TextInput,
    ) !bool {
        var changed = false;
        while (loop.tryEvent()) |event| {
            changed = true;
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true }) or key.matches(tui.Key.escape, .{})) {
                        try self.requestCancel(session_id);
                        continue;
                    }
                    if (key.matches(tui.Key.page_up, .{})) {
                        self.scrollUp(6);
                        continue;
                    }
                    if (key.matches(tui.Key.page_down, .{})) {
                        self.scrollDown(6);
                        continue;
                    }
                    if (key.matches(tui.Key.home, .{ .ctrl = true })) {
                        self.scrollUp(self.maxScrollOffsetRows());
                        continue;
                    }
                    if (key.matches(tui.Key.end, .{ .ctrl = true })) {
                        self.jumpToBottom();
                        continue;
                    }
                    if (self.scroll_offset == 0 and key.matches(tui.Key.up, .{})) {
                        try self.historyNavigateUp(input);
                        continue;
                    }
                    if (self.scroll_offset == 0 and key.matches(tui.Key.down, .{})) {
                        try self.historyNavigateDown(input);
                        continue;
                    }
                    if (key.matches(tui.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                        // Interjection protocol: capture and queue the message
                        const owned = input.toOwnedSlice() catch continue;
                        defer self.allocator.free(owned);
                        const text = std.mem.trim(u8, owned, " \t\r\n");
                        if (text.len > 0) {
                            try self.queueMessage(session_id, text);
                            input.clearAndFree();
                        }
                        continue;
                    }
                    try input.update(.{ .key_press = key });
                },
                .mouse => |mouse| {
                    _ = applyMouseScroll(self, mouse);
                },
                .winsize => |ws| try vx.resize(self.allocator, tty.anyWriter(), ws),
                else => {},
            }
        }
        return changed;
    }

    fn requestCancel(self: *ChatState, session_id: []const u8) !void {
        if (self.cancel_requested) return;
        self.cancel_requested = true;
        self.status = "CANCELLING";
        const params = try renderJsonAlloc(self.allocator, .{ .session_id = session_id });
        defer self.allocator.free(params);
        const call = self.client.call(protocol.methods.session_cancel, params) catch return;
        call.deinit(self.allocator);
        try self.add(.progress, "cancelling");
    }

    /// Fire-and-forget session/send to queue a message during an active turn
    /// (interjection protocol). Mirrors requestCancel's non-blocking pattern.
    fn queueMessage(self: *ChatState, session_id: []const u8, text: []const u8) !void {
        const params = try renderJsonAlloc(self.allocator, .{ .session_id = session_id, .prompt = text });
        defer self.allocator.free(params);
        const call = self.client.call(protocol.methods.session_send, params) catch return;
        call.deinit(self.allocator);
    }
};

// ---------------------------------------------------------------------------
// Slash command execute functions + registry
// ---------------------------------------------------------------------------

fn cmdHelp(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    if (args.len > 0) {
        // Per-command detail — find the command in the info list.
        for (commands.builtin_command_info) |info| {
            if (std.mem.eql(u8, info.name, args)) {
                const detail = try std.fmt.allocPrint(allocator, "/{s}: {s}", .{ info.name, info.description });
                defer allocator.free(detail);
                try state.add(.system, detail);
                return .handled;
            }
        }
        const not_found = try std.fmt.allocPrint(allocator, "No help available for /{s}.", .{args});
        defer allocator.free(not_found);
        try state.add(.system, not_found);
        return .handled;
    }
    const help_text = try commands.renderHelp(allocator);
    defer allocator.free(help_text);
    try state.add(.system, help_text);
    return .handled;
}

fn cmdClear(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    for (state.messages.items) |message| message.deinit(state.allocator);
    state.messages.clearRetainingCapacity();
    state.reasoning_buffer.clearRetainingCapacity();
    state.scroll_offset = 0;
    try state.add(.system, "Conversation cleared.");
    return .handled;
}

fn cmdExit(_: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    return .exit;
}

fn cmdStatus(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    const status_text = try commands.renderStatus(state.allocator, state.workspace_root, state.model, state.session_id, state.effort);
    defer state.allocator.free(status_text);
    try state.add(.system, status_text);
    return .handled;
}

fn cmdHistory(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    const entries = history.loadHistory(allocator, state.workspace_root, 20) catch {
        try state.add(.system, "Unable to load history.");
        return .handled;
    };
    defer {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }
    if (entries.len == 0) {
        try state.add(.system, "No history yet.");
        return .handled;
    }
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.writer().writeAll("Recent History (newest last):\n");
    for (entries, 0..) |entry, i| {
        try output.writer().print("  {d: >2}. {s}\n", .{ i + 1, entry.text });
    }
    try state.add(.system, output.items);
    return .handled;
}

fn cmdCompact(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    // Send a compact request to the kernel via the session/compact RPC.
    const session_id = state.session_id orelse {
        try state.add(.system, "No active session to compact.");
        return .handled;
    };
    const params = try std.fmt.allocPrint(state.allocator, "{{\"session_id\":{f}}}", .{std.json.fmt(session_id, .{})});
    defer state.allocator.free(params);
    const call = state.client.call(protocol.methods.session_compact, params) catch {
        try state.add(.system, "Compact request failed.");
        return .handled;
    };
    defer call.deinit(state.allocator);
    try state.add(.system, "Context compacted.");
    return .handled;
}

fn cmdCancel(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    state.cancel_requested = true;
    try state.add(.system, "Cancellation requested.");
    return .handled;
}

fn cmdSettings(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    // Open the settings overlay. Initialize state and load the first section.
    if (state.settings_state == null) {
        state.settings_state = settings_view.SettingsState.init(state.allocator, state.workspace_root);
    }
    state.settings_state.?.open = true;
    state.settings_state.?.loadSection() catch {};
    return .handled;
}

fn cmdStub(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    // Remaining stubs — model/effort/persona/agents are implemented in chain 034e.
    _ = args;
    try state.add(.system, "This command is being implemented. Use /settings to configure via the TUI.");
    return .handled;
}

const command_registry = [_]commands.Command(ChatState){
    .{ .name = "help", .description = "List commands or show help.", .category = .help, .execute = cmdHelp },
    .{ .name = "clear", .description = "Clear the transcript.", .category = .session, .execute = cmdClear },
    .{ .name = "exit", .description = "Exit VANTARI.", .category = .session, .execute = cmdExit },
    .{ .name = "quit", .description = "Exit VANTARI.", .category = .session, .execute = cmdExit },
    .{ .name = "status", .description = "Show workspace, model, session.", .category = .help, .execute = cmdStatus },
    .{ .name = "history", .description = "Show recent global history.", .category = .help, .execute = cmdHistory },
    .{ .name = "compact", .description = "Summarize conversation to free context.", .category = .session, .execute = cmdCompact },
    .{ .name = "cancel", .description = "Cancel the current turn.", .category = .session, .execute = cmdCancel },
    // Phase 2 stubs:
    .{ .name = "settings", .description = "Open settings panel.", .category = .config, .execute = cmdSettings },
    .{ .name = "model", .description = "Switch model (coming soon).", .category = .model, .execute = cmdStub },
    .{ .name = "effort", .description = "Set effort (coming soon).", .category = .model, .execute = cmdStub },
    .{ .name = "persona", .description = "Edit persona (coming soon).", .category = .config, .execute = cmdStub },
    .{ .name = "agents", .description = "Manage agents (coming soon).", .category = .agent, .execute = cmdStub },
};

const SendJob = struct {
    allocator: std.mem.Allocator,
    client: *stdio_rpc.LocalClient,
    params_json: []u8,
    result: ?stdio_rpc.RpcCallResult = null,
    err: ?anyerror = null,
    done: bool = false,
    mutex: std.Thread.Mutex = .{},

    fn deinit(self: *SendJob) void {
        self.allocator.free(self.params_json);
        if (self.result) |result| result.deinit(self.allocator);
    }

    fn finish(self: *SendJob, result: ?stdio_rpc.RpcCallResult, err: ?anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.result = result;
        self.err = err;
        self.done = true;
    }

    fn isDone(self: *SendJob) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.done;
    }
};

fn runSessionSend(job: *SendJob) void {
    // Use the MAIN client (shared with the TUI's notification reader).
    // This means notifications from the provider streaming arrive directly
    // through the main client's reader thread — no second kernel process,
    // no disk polling, no RPC round-trips for every token.
    const result = job.client.call(protocol.methods.session_send, job.params_json) catch |err| {
        job.finish(null, err);
        return;
    };
    job.finish(result, null);
}

/// Extract a printable ASCII character from a key event, or null if the key
/// is not a simple printable character. Used by the settings edit buffer.
fn keyToPrintable(key: tui.Key) ?u8 {
    // tui.Key.text is ?[]const u8 — null for special keys, text for printable.
    const text = key.text orelse return null;
    if (text.len == 1) {
        const c = text[0];
        if (c >= 0x20 and c < 0x7f) return c;
    }
    return null;
}

pub fn main(allocator: std.mem.Allocator) !void {
    return mainWithMode(allocator, .blank);
}

pub fn mainContinueLatest(allocator: std.mem.Allocator) !void {
    return mainWithMode(allocator, .continue_latest);
}

fn mainWithMode(allocator: std.mem.Allocator, startup_mode: StartupMode) !void {
    var buffer: [1024]u8 = undefined;
    var tty = try tui.Tty.init(&buffer);
    defer tty.deinit();

    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, null);
    defer client.deinit();

    const initialize_call = try client.call(protocol.methods.initialize, "{}");
    defer initialize_call.deinit(allocator);
    const initialize_result_json = try expectKernelResult(allocator, initialize_call);
    defer allocator.free(initialize_result_json);

    const subscribe_call = try client.call(protocol.methods.events_subscribe, "{}");
    defer subscribe_call.deinit(allocator);
    const subscribe_result_json = try expectKernelResult(allocator, subscribe_call);
    defer allocator.free(subscribe_result_json);

    const health_call = try client.call(protocol.methods.health_get, "{}");
    defer health_call.deinit(allocator);
    const health_result_json = try expectKernelResult(allocator, health_call);
    defer allocator.free(health_result_json);

    var parsed_health = try std.json.parseFromSlice(protocol.HealthGetResult, allocator, health_result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_health.deinit();

    const writer = tty.anyWriter();
    var vx = try tui.init(allocator, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(allocator, tty.anyWriter());

    var loop: tui.Loop(Event) = .{
        .vaxis = &vx,
        .tty = &tty,
    };
    try loop.init();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try vx.setMouseMode(writer, true);
    try writer.flush();
    try vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s);

    var input = TextInput.init(allocator, &vx.unicode);
    defer input.deinit();

    var state = ChatState{
        .allocator = allocator,
        .client = &client,
        .workspace_root = parsed_health.value.workspace_root,
        .model = parsed_health.value.model,
        .base_url = parsed_health.value.base_url,
        .auth_provider = parsed_health.value.auth_provider orelse "unconfigured",
        .plan = parsed_health.value.subscription_plan_label orelse "unknown",
        .subscription_status = parsed_health.value.subscription_status orelse "unknown",
        .effort = parsed_health.value.effort,
        .thinking_mode = parsed_health.value.thinking_mode,
        .context_window_tokens = parsed_health.value.context_window_tokens,
        .reserve_output_tokens = parsed_health.value.reserve_output_tokens,
    };
    defer state.deinit();

    // Load global persistent message history into the in-memory ring buffer
    // so Up/Down navigation recalls prompts from previous sessions.
    {
        const entries: []history.HistoryEntry = history.loadHistory(allocator, state.workspace_root, history.max_history_entries) catch try allocator.alloc(history.HistoryEntry, 0);
        defer {
            for (entries) |*entry| entry.deinit(allocator);
            allocator.free(entries);
        }
        for (entries) |entry| {
            // Dedup against entries already in the buffer (shouldn't happen on
            // fresh load, but guards against double-load edge cases).
            const already = blk: {
                for (state.history_entries.items) |existing| {
                    if (std.mem.eql(u8, existing, entry.text)) break :blk true;
                }
                break :blk false;
            };
            if (already) continue;
            state.history_entries.append(allocator, allocator.dupe(u8, entry.text) catch continue) catch continue;
        }
        state.history_cursor = 0;
    }

    if (startup_mode == .continue_latest) {
        if (!try state.loadLatestSession()) {
            try state.add(.system, "No sessions in this workspace yet.");
        }
    }

    while (true) {
        try draw(&vx, writer, &state, &input);

        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                // Settings overlay key routing — when the panel is open, all keys
                // go to the settings handler except Ctrl-C (force exit).
                if (state.settings_state) |*ss| {
                    if (ss.open) {
                        if (key.matches('c', .{ .ctrl = true })) break;
                        const consumed = ss.handleKey(key, state.client) catch false;
                        if (!consumed and ss.editing) {
                            // Route printable chars to the edit buffer.
                            const ch = keyToPrintable(key);
                            if (ch) |c| {
                                ss.edit_buffer.append(allocator, c) catch {};
                            } else if (key.matches(tui.Key.backspace, .{})) {
                                if (ss.edit_buffer.items.len > 0) {
                                    _ = ss.edit_buffer.pop();
                                }
                            }
                        }
                        continue;
                    }
                }

                if (key.matches('c', .{ .ctrl = true })) break;
                if (key.matches(tui.Key.page_up, .{})) {
                    state.scrollUp(6);
                    continue;
                }
                if (key.matches(tui.Key.page_down, .{})) {
                    state.scrollDown(6);
                    continue;
                }
                if (key.matches(tui.Key.home, .{ .ctrl = true })) {
                    state.scrollUp(state.messages.items.len);
                    continue;
                }
                if (key.matches(tui.Key.end, .{ .ctrl = true })) {
                    state.jumpToBottom();
                    continue;
                }
                if (state.scroll_offset == 0 and key.matches(tui.Key.up, .{})) {
                    try state.historyNavigateUp(&input);
                    continue;
                }
                if (state.scroll_offset == 0 and key.matches(tui.Key.down, .{})) {
                    try state.historyNavigateDown(&input);
                    continue;
                }
                if (key.matches(tui.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                    const owned_prompt = try input.toOwnedSlice();
                    defer allocator.free(owned_prompt);
                    const prompt = std.mem.trim(u8, owned_prompt, " \t\r\n");
                    // Slash command dispatch — intercept /-prefixed input before
                    // submitting to the model.
                    const cmd_result = commands.dispatch(ChatState, &state, &command_registry, prompt) catch .not_a_command;
                    switch (cmd_result) {
                        .exit => break,
                        .handled => {
                            input.clearAndFree();
                            continue;
                        },
                        .not_a_command => {},
                    }
                    try state.submit(prompt, &vx, &tty, &loop, writer, &input);
                    continue;
                }
                try input.update(.{ .key_press = key });
            },
            .mouse => |mouse| {
                if (applyMouseScroll(&state, mouse)) continue;
            },
            .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
            else => {},
        }
    }
}

pub fn writeStartupFailure(allocator: std.mem.Allocator, err: anyerror) !void {
    const rendered = try renderStartupFailure(allocator, err);
    defer allocator.free(rendered);
    var buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buffer);
    try stderr.interface.writeAll(rendered);
    try stderr.interface.flush();
}

pub fn renderStartupFailure(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "VAR1_ERROR category=tui code={s} message={f}\n",
        .{ startupFailureCode(err), std.json.fmt(startupFailureMessage(err), .{}) },
    );
}

fn startupFailureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidHandle => "TerminalUnavailable",
        error.InvalidRpcResponse => "KernelInvalidRpcResponse",
        error.RpcRemoteError => "KernelRemoteError",
        error.MissingChildPipes => "KernelPipeUnavailable",
        else => @errorName(err),
    };
}

fn startupFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidHandle => "TUI requires an interactive terminal handle. Run from a real console, or use commands such as `vantari health --json` and `vantari c --json` in non-interactive shells.",
        error.InvalidRpcResponse => "Kernel stdio returned an invalid JSON-RPC response during TUI startup.",
        error.RpcRemoteError => "Kernel stdio returned an error during TUI startup.",
        error.MissingChildPipes => "Kernel stdio child process did not expose the required pipes.",
        else => "TUI startup failed before the chat surface became interactive.",
    };
}

fn applyMouseScroll(state: *ChatState, mouse: tui.Mouse) bool {
    switch (mouse.button) {
        .wheel_up => {
            state.scrollUp(3);
            return true;
        },
        .wheel_down => {
            state.scrollDown(3);
            return true;
        },
        else => return false,
    }
}

fn draw(vx: *tui.Vaxis, writer: anytype, state: *ChatState, input: *TextInput) !void {
    const root = vx.window();

    // Settings overlay — when open, render full-screen instead of normal layout.
    if (state.settings_state) |*ss| {
        if (ss.open) {
            settings_view.drawSettings(root, ss);
            try writer.flush();
            return;
        }
    }

    root.fill(.{ .style = styles.surface });

    const reasoning_body_width = @max(@as(usize, 1), @as(usize, root.width -| 8));
    // Dual-mode dock: when the heavyweight model is actively reasoning,
    // show the live reasoning trace. When idle, show the buffer model's
    // navigation preview if available. The dock collapses when both are empty.
    const dock_is_reasoning = state.waiting and state.reasoning_buffer.items.len > 0;
    const dock_source: []const u8 = if (dock_is_reasoning)
        state.reasoning_buffer.items
    else if (state.buffer_preview) |preview|
        preview
    else
        "";
    var reasoning_rows = try buildReasoningDockRows(state.allocator, dock_source, reasoning_body_width);
    defer reasoning_rows.deinit(state.allocator);
    const layout = computeLayoutWithReasoningDock(root.height, @intCast(reasoning_rows.items.len));

    const transcript = root.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = root.width,
        .height = layout.transcript_height,
    });
    drawTranscript(transcript, state);

    if (layout.reasoning_height > 0) {
        const reasoning = root.child(.{
            .x_off = 1,
            .y_off = @intCast(layout.reasoning_y),
            .width = root.width -| 2,
            .height = layout.reasoning_height,
        });
        drawReasoningDock(reasoning, reasoning_rows.items, dock_is_reasoning);
    }

    const input_win = root.child(.{
        .x_off = 0,
        .y_off = @intCast(layout.footer_y),
        .width = root.width,
        .height = layout.footer_height,
    });
    input_win.fill(.{ .style = styles.meta_surface });
    const composer_row = input_win.child(.{
        .x_off = 0,
        .y_off = @intCast(layout.editor_y),
        .width = input_win.width,
        .height = 1,
    });
    composer_row.fill(.{ .style = styles.composer });
    const editor = composer_row.child(.{
        .x_off = 1,
        .y_off = 0,
        .width = composer_row.width -| 2,
        .height = 1,
    });
    input.drawWithStyle(editor, styles.composer);
    const agent_counts = state.agentCounts();
    const meta_width = @as(usize, input_win.width) -| 4;
    const footer_meta = try formatFooterMeta(
        state.allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        state.context_used_tokens,
        state.context_window_tokens,
        agent_counts.running,
        agent_counts.total,
        state.waiting,
        state.cancel_requested,
        state.scroll_offset,
        meta_width,
    );
    defer state.allocator.free(footer_meta);

    if (input_win.width > 1) {
        _ = input_win.print(&.{.{ .text = "●", .style = footerStatusStyle(state) }}, .{
            .row_offset = layout.meta_y,
            .col_offset = 1,
            .wrap = .none,
        });
    }
    if (footer_meta.len > 0 and input_win.width > 3) {
        _ = input_win.print(&.{.{ .text = footer_meta, .style = styles.meta_value }}, .{
            .row_offset = layout.meta_y,
            .col_offset = 3,
            .wrap = .none,
        });
    }
    try vx.render(writer);
    try writer.flush();
}

fn footerStatusStyle(state: *const ChatState) Style {
    if (std.ascii.eqlIgnoreCase(state.status, "FAILED") or
        std.ascii.eqlIgnoreCase(state.status, "RPC_ERROR")) return styles.status_failed;
    if (state.waiting or std.ascii.eqlIgnoreCase(state.status, "CANCELLING")) return styles.status_working;
    return styles.status_ready;
}

const ChatLayout = struct {
    transcript_height: u16,
    reasoning_y: u16 = 0,
    reasoning_height: u16 = 0,
    reasoning_gap_height: u16 = 0,
    footer_y: u16,
    footer_height: u16,
    editor_y: u16,
    meta_y: u16,
};

const startup_intro_lines = [_][]const u8{
    "╷ ╷╭─╮╭╮╷╶┬╴╭─╮╭─╮╷   ╭─╮╭╮╷╭─╴",
    "│╭╯├─┤│╰┤ │ ├─┤├┬╯│╶─╴│ ││╰┤├╴ ",
    "╰╯ ╵ ╵╵ ╵ ╵ ╵ ╵╵╰╴╵   ╰─╯╵ ╵╰─╴",
};

const startup_intro_version = "v0.1.8";
const startup_intro_gap_rows: usize = 1;
const startup_intro_projected_rows: usize = startup_intro_lines.len + 1 + startup_intro_gap_rows;

fn computeLayout(root_height: u16) ChatLayout {
    const footer_height: u16 = @min(@as(u16, 3), root_height);
    return .{
        .transcript_height = root_height -| footer_height,
        .footer_y = root_height -| footer_height,
        .footer_height = footer_height,
        .editor_y = 0,
        .meta_y = if (footer_height > 1) footer_height - 1 else 0,
    };
}

fn computeLayoutWithReasoningDock(root_height: u16, requested_reasoning_height: u16) ChatLayout {
    var layout = computeLayout(root_height);
    layout.reasoning_height = @min(requested_reasoning_height, layout.transcript_height);
    const remaining_height = layout.transcript_height - layout.reasoning_height;
    layout.reasoning_gap_height = @intFromBool(layout.reasoning_height > 0 and remaining_height > 0);
    layout.transcript_height = remaining_height - layout.reasoning_gap_height;
    layout.reasoning_y = layout.transcript_height + layout.reasoning_gap_height;
    return layout;
}

fn activityStateFromLabel(label: []const u8) ActivityState {
    if (std.ascii.eqlIgnoreCase(label, "completed") or
        std.ascii.eqlIgnoreCase(label, "done") or
        std.ascii.eqlIgnoreCase(label, "succeeded")) return .completed;
    if (std.ascii.eqlIgnoreCase(label, "failed") or
        std.ascii.eqlIgnoreCase(label, "error") or
        std.ascii.eqlIgnoreCase(label, "blocked")) return .failed;
    if (std.ascii.eqlIgnoreCase(label, "cancelled") or
        std.ascii.eqlIgnoreCase(label, "canceled")) return .cancelled;
    if (std.ascii.eqlIgnoreCase(label, "running") or
        std.ascii.eqlIgnoreCase(label, "active") or
        std.ascii.eqlIgnoreCase(label, "waiting")) return .running;
    return .pending;
}

fn activityTitle(tool_name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tool_name, "search_files") or
        std.ascii.eqlIgnoreCase(tool_name, "web_search") or
        std.ascii.eqlIgnoreCase(tool_name, "websearch") or
        std.ascii.eqlIgnoreCase(tool_name, "web_fetch")) return "Search";
    if (std.ascii.eqlIgnoreCase(tool_name, "list_files") or
        std.ascii.eqlIgnoreCase(tool_name, "read_file") or
        std.ascii.eqlIgnoreCase(tool_name, "explore")) return "Explore";
    if (std.ascii.eqlIgnoreCase(tool_name, "agents") or
        std.ascii.eqlIgnoreCase(tool_name, "configure_agent")) return "Agents";
    if (std.ascii.eqlIgnoreCase(tool_name, "todo_slice") or
        std.ascii.eqlIgnoreCase(tool_name, "todo_write") or
        std.ascii.eqlIgnoreCase(tool_name, "update_plan")) return "To-dos";
    return tool_name;
}

fn isAgentLifecycleTool(tool_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(tool_name, "launch_agent") or
        std.ascii.eqlIgnoreCase(tool_name, "wait_agent") or
        std.ascii.eqlIgnoreCase(tool_name, "agent_status") or
        std.ascii.eqlIgnoreCase(tool_name, "list_agents") or
        std.ascii.eqlIgnoreCase(tool_name, "cancel_agents");
}

fn activityMarker(state: ActivityState) []const u8 {
    return switch (state) {
        .pending => "○ ",
        .running => "◉ ",
        .completed => "✓ ",
        .failed => "✗ ",
        .cancelled => "⊘ ",
    };
}

fn activityConnector(kind: ActivityKind, is_last: bool) []const u8 {
    if (kind != .item) return "";
    return if (is_last) "└── " else "├── ";
}

/// Braille spinner frames for the reasoning/activity indicator.
/// Variable-speed: the render loop advances the frame based on
/// wall-clock time and activity level (reasoning deltas arriving).
const braille_spinner_frames = [_][]const u8{
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
};

/// Compute the spinner frame index from wall-clock time.
/// Active (recent deltas): ~80ms per frame. Idle: ~400ms per frame.
fn spinnerFrameIndex(active: bool) usize {
    const now_ms = std.time.milliTimestamp();
    const interval_ms: i64 = if (active) 80 else 400;
    const frame_count = braille_spinner_frames.len;
    const idx = @as(usize, @intCast(@mod(@divFloor(now_ms, interval_ms), @as(i64, @intCast(frame_count)))));
    return idx;
}

fn spinnerGlyph(active: bool) []const u8 {
    return braille_spinner_frames[spinnerFrameIndex(active)];
}

fn activityMarkerStyle(state: ActivityState) Style {
    return switch (state) {
        .running, .completed => styles.assistant,
        .pending, .failed, .cancelled => styles.progress,
    };
}

fn activityTextStyle(state: ActivityState) Style {
    return switch (state) {
        .completed, .cancelled => styles.system,
        .pending, .running, .failed => styles.progress,
    };
}

const styles = struct {
    const surface: Style = .{ .fg = Color.rgbFromUint(0xd9f7ef), .bg = Color.rgbFromUint(0x08110f) };
    /// Footer metadata is a quiet intermediate tint. The hierarchy is
    /// surface < meta_surface < composer; no border or extra chrome is
    /// needed to separate the focused input from runtime telemetry.
    const meta_surface: Style = .{ .fg = Color.rgbFromUint(0x78958d), .bg = Color.rgbFromUint(0x0a1614) };
    const composer: Style = .{ .fg = Color.rgbFromUint(0xe8fff8), .bg = Color.rgbFromUint(0x10221f) };
    const user: Style = .{ .fg = Color.rgbFromUint(0xcff8ec), .bg = Color.rgbFromUint(0x08110f), .bold = true };
    const assistant: Style = .{ .fg = Color.rgbFromUint(0x8ff5d2), .bg = Color.rgbFromUint(0x08110f), .bold = true };
    const user_text: Style = .{ .fg = Color.rgbFromUint(0xe8fff8), .bg = Color.rgbFromUint(0x08110f) };
    const assistant_text: Style = .{ .fg = Color.rgbFromUint(0xb7f7df), .bg = Color.rgbFromUint(0x08110f) };
    const thinking: Style = .{ .fg = Color.rgbFromUint(0x8ff5d2), .bg = Color.rgbFromUint(0x08110f), .dim = true, .blink = true };
    const progress: Style = .{ .fg = Color.rgbFromUint(0x9fbeb5), .bg = Color.rgbFromUint(0x08110f), .dim = true };
    const system: Style = .{ .fg = Color.rgbFromUint(0x78958d), .bg = Color.rgbFromUint(0x08110f), .dim = true };
    const intro: Style = .{ .fg = Color.rgbFromUint(0x8ff5d2), .bg = Color.rgbFromUint(0x08110f), .bold = true };
    const intro_version: Style = .{ .fg = Color.rgbFromUint(0x78958d), .bg = Color.rgbFromUint(0x08110f), .dim = true };
    const text: Style = .{ .fg = Color.rgbFromUint(0xd9f7ef), .bg = Color.rgbFromUint(0x08110f) };
    const meta_label: Style = .{ .fg = Color.rgbFromUint(0x5d746e), .bg = Color.rgbFromUint(0x0a1614), .dim = true };
    const meta_value: Style = .{ .fg = Color.rgbFromUint(0x9bbab1), .bg = Color.rgbFromUint(0x0a1614), .dim = true };
    const status_ready: Style = .{ .fg = Color.rgbFromUint(0x43c58b), .bg = Color.rgbFromUint(0x0a1614) };
    const status_working: Style = .{ .fg = Color.rgbFromUint(0xd7ad5a), .bg = Color.rgbFromUint(0x0a1614) };
    const status_failed: Style = .{ .fg = Color.rgbFromUint(0xe06c75), .bg = Color.rgbFromUint(0x0a1614) };
};

fn drawTranscript(win: Window, state: *ChatState) void {
    win.fill(.{ .style = styles.surface });
    const content = win.child(.{
        .x_off = 1,
        .y_off = 0,
        .width = win.width -| 2,
        .height = win.height,
    });
    if (content.height <= 1) return;

    state.last_transcript_body_width = @max(@as(usize, 1), @as(usize, content.width -| 4));
    var rows = buildTranscriptRows(state.allocator, content, state) catch return;
    defer rows.deinit(state.allocator);

    const visible_rows = visibleTranscriptRowCount(rows.items);
    const range = visibleRowRange(content, state, visible_rows);
    var row: u16 = 1;
    for (rows.items[range.start..range.end]) |transcript_row| {
        if (row >= content.height) break;
        drawTranscriptRow(content, row, transcript_row);
        row +|= 1;
    }
}

fn drawReasoningDock(win: Window, rows: []const TranscriptRow, is_reasoning: bool) void {
    // Glyph distinguishes modes: ∞ for live reasoning, ◊ for buffer preview.
    const header_glyph: []const u8 = if (is_reasoning) "∞ " else "◊ ";
    for (rows, 0..) |reasoning_row, index| {
        if (index >= win.height or index >= max_reasoning_dock_rows) break;
        const block = win.child(.{
            .x_off = 0,
            .y_off = @intCast(index),
            .width = win.width,
            .height = 1,
            .border = .{ .where = .left, .style = styles.assistant },
        });
        _ = block.print(&.{.{
            .text = if (index == 0) header_glyph else "  ",
            .style = styles.assistant,
        }}, .{
            .row_offset = 0,
            .col_offset = 1,
            .wrap = .none,
        });
        const body = block.child(.{
            .x_off = 3,
            .y_off = 0,
            .width = block.width -| 4,
            .height = 1,
        });
        _ = body.print(&.{.{ .text = reasoning_row.text, .style = styles.progress }}, .{
            .row_offset = 0,
            .col_offset = 0,
            .wrap = .none,
        });
    }
}

const VisibleRange = struct {
    start: usize,
    end: usize,
};

fn visibleRowRange(win: Window, state: *const ChatState, row_count: usize) VisibleRange {
    const end = visibleEndRow(state, row_count);
    return .{
        .start = visibleStartRow(win, end),
        .end = end,
    };
}

fn visibleEndRow(state: *const ChatState, row_count: usize) usize {
    return visibleEndRowForOffset(state.scroll_offset, row_count);
}

fn visibleEndRowForOffset(scroll_offset: usize, row_count: usize) usize {
    if (row_count == 0) return 0;
    const offset = @min(scroll_offset, row_count - 1);
    return row_count - offset;
}

fn visibleStartRow(win: Window, end: usize) usize {
    return visibleStartRowForAvailable(win.height -| 1, end);
}

fn visibleStartRowForAvailable(available: u16, end: usize) usize {
    if (end <= available) return 0;
    return end - available;
}

const TranscriptRow = struct {
    role: Role,
    text: []const u8,
    activity_kind: ActivityKind = .none,
    activity_state: ActivityState = .pending,
    activity_last: bool = false,
    pending: bool = false,
    gap: bool = false,
    intro: bool = false,
    intro_version: bool = false,
};

fn buildTranscriptRows(allocator: std.mem.Allocator, win: Window, state: *const ChatState) !std.ArrayList(TranscriptRow) {
    var rows: std.ArrayList(TranscriptRow) = .{};
    errdefer rows.deinit(allocator);

    const body_width = @max(@as(usize, 1), @as(usize, win.width -| 4));
    try appendStartupIntroRows(allocator, &rows);

    for (state.messages.items) |message| {
        if (message.pending and state.reasoning_buffer.items.len > 0) continue;
        try appendMessageRows(allocator, &rows, message, body_width);
    }
    return rows;
}

const max_reasoning_dock_rows: usize = 4;
const max_reasoning_dock_scan_bytes: usize = 1024;

fn buildReasoningDockRows(
    allocator: std.mem.Allocator,
    reasoning_text: []const u8,
    body_width: usize,
) !std.ArrayList(TranscriptRow) {
    var wrapped: std.ArrayList(TranscriptRow) = .{};
    errdefer wrapped.deinit(allocator);
    if (reasoning_text.len == 0) return wrapped;

    const display = reasoningTail(reasoning_text, max_reasoning_dock_scan_bytes);
    try appendWrappedTranscriptRows(allocator, &wrapped, .progress, display, body_width);
    if (wrapped.items.len <= max_reasoning_dock_rows) return wrapped;

    const newest = wrapped.items[wrapped.items.len - max_reasoning_dock_rows ..];
    std.mem.copyForwards(TranscriptRow, wrapped.items[0..max_reasoning_dock_rows], newest);
    wrapped.shrinkRetainingCapacity(max_reasoning_dock_rows);
    return wrapped;
}

fn reasoningTail(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var start = text.len - max_bytes;
    while (start < text.len and text[start] & 0b1100_0000 == 0b1000_0000) : (start += 1) {}
    return text[start..];
}

fn appendStartupIntroRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TranscriptRow),
) !void {
    for (startup_intro_lines) |line| {
        try rows.append(allocator, .{
            .role = .system,
            .text = line,
            .intro = true,
        });
    }
    try rows.append(allocator, .{
        .role = .system,
        .text = startup_intro_version,
        .intro = true,
        .intro_version = true,
    });
    var gap: usize = 0;
    while (gap < startup_intro_gap_rows) : (gap += 1) {
        try rows.append(allocator, .{
            .role = .system,
            .text = "",
            .gap = true,
            .intro = true,
        });
    }
}

fn visibleTranscriptRowCount(rows: []const TranscriptRow) usize {
    var count = rows.len;
    while (count > 0 and rows[count - 1].gap) count -= 1;
    return count;
}

fn appendMessageRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TranscriptRow),
    message: Message,
    body_width: usize,
) !void {
    if (message.pending) {
        try appendTranscriptRow(allocator, rows, .assistant, "thinking", true, false);
        try appendTranscriptRow(allocator, rows, .assistant, "", false, true);
        return;
    }

    if (isCompactRole(message.role)) {
        try rows.append(allocator, .{
            .role = message.role,
            .text = message.text,
            .activity_kind = message.activity_kind,
            .activity_state = message.activity_state,
            .activity_last = message.activity_last,
        });
        return;
    }

    try appendWrappedTranscriptRows(allocator, rows, message.role, message.text, body_width);
    try appendTranscriptRow(allocator, rows, message.role, "", false, true);
}

fn appendTranscriptRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TranscriptRow),
    role: Role,
    text: []const u8,
    pending: bool,
    gap: bool,
) !void {
    try rows.append(allocator, .{
        .role = role,
        .text = text,
        .pending = pending,
        .gap = gap,
    });
}

fn appendWrappedTranscriptRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TranscriptRow),
    role: Role,
    text: []const u8,
    body_width: usize,
) !void {
    if (text.len == 0) {
        try appendTranscriptRow(allocator, rows, role, "", false, false);
        return;
    }

    var remaining = text;
    while (true) {
        if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline| {
            try appendWrappedSegmentRows(allocator, rows, role, remaining[0..newline], body_width);
            remaining = remaining[newline + 1 ..];
            if (remaining.len == 0) {
                try appendTranscriptRow(allocator, rows, role, "", false, false);
                return;
            }
            continue;
        }
        try appendWrappedSegmentRows(allocator, rows, role, remaining, body_width);
        return;
    }
}

fn appendWrappedSegmentRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TranscriptRow),
    role: Role,
    segment: []const u8,
    body_width: usize,
) !void {
    const width = @max(@as(usize, 1), body_width);
    var offset: usize = 0;
    if (segment.len == 0) {
        try appendTranscriptRow(allocator, rows, role, "", false, false);
        return;
    }

    while (offset < segment.len) {
        const take = wrappedSegmentTake(segment, offset, width);
        const raw = segment[offset .. offset + take];
        const line = std.mem.trimRight(u8, raw, " \t\r");
        try appendTranscriptRow(allocator, rows, role, line, false, false);
        offset += take;
    }
}

fn drawTranscriptRow(win: Window, row: u16, transcript_row: TranscriptRow) void {
    if (transcript_row.gap) return;
    if (transcript_row.intro) {
        drawIntroRow(win, row, transcript_row.text, transcript_row.intro_version);
        return;
    }
    const role_style = if (transcript_row.pending) styles.thinking else roleStyle(transcript_row.role);
    const body_width = win.width -| 4;
    const block = win.child(.{
        .x_off = 0,
        .y_off = @intCast(row),
        .width = win.width,
        .height = 1,
        .border = .{ .where = .left, .style = role_style },
    });
    const body = block.child(.{ .x_off = 1, .y_off = 0, .width = body_width, .height = 1 });
    if (transcript_row.activity_kind != .none) {
        const connector = activityConnector(transcript_row.activity_kind, transcript_row.activity_last);
        // Group headers get the ◍ (complete) or ◉ (running) glyph;
        // items get the standard state marker (○/◉/✓/✗/⊘)
        if (transcript_row.activity_kind == .group) {
            const group_glyph: []const u8 = switch (transcript_row.activity_state) {
                .completed => "◍ ",
                .running => "◉ ",
                else => "○ ",
            };
            _ = body.print(&.{
                .{ .text = group_glyph, .style = styles.assistant },
                .{ .text = transcript_row.text, .style = activityTextStyle(transcript_row.activity_state) },
            }, .{
                .row_offset = 0,
                .col_offset = 0,
                .wrap = .none,
            });
        } else {
            _ = body.print(&.{
                .{ .text = connector, .style = styles.progress },
                .{ .text = activityMarker(transcript_row.activity_state), .style = activityMarkerStyle(transcript_row.activity_state) },
                .{ .text = transcript_row.text, .style = activityTextStyle(transcript_row.activity_state) },
            }, .{
                .row_offset = 0,
                .col_offset = 0,
                .wrap = .none,
            });
        }
        return;
    }
    _ = body.print(&.{.{ .text = transcript_row.text, .style = if (transcript_row.pending) styles.thinking else bodyStyle(transcript_row.role) }}, .{
        .row_offset = 0,
        .col_offset = 0,
        .wrap = .none,
    });
}

fn drawIntroRow(win: Window, row: u16, text: []const u8, version: bool) void {
    const visual_width = introVisualWidth(text);
    const col: u16 = if (win.width > visual_width)
        @intCast((@as(usize, win.width) - visual_width) / 2)
    else
        0;
    _ = win.print(&.{.{ .text = text, .style = if (version) styles.intro_version else styles.intro }}, .{
        .row_offset = row,
        .col_offset = col,
        .wrap = .none,
    });
}

fn introVisualWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn messageRowCount(role: Role, text: []const u8, pending: bool, body_width: usize) usize {
    if (pending) return 2;
    if (isCompactRole(role)) return 1;
    return wrappedRowCount(text, body_width) + 1;
}

fn transcriptRowCount(state: *const ChatState, body_width: usize) usize {
    var rows: usize = startup_intro_projected_rows;
    for (state.messages.items) |message| {
        rows += messageRowCount(message.role, message.text, message.pending, body_width);
    }
    return rows;
}

fn wrappedRowCount(text: []const u8, body_width: usize) usize {
    const width = @max(@as(usize, 1), body_width);
    if (text.len == 0) return 1;
    var rows: usize = 0;
    var remaining = text;
    while (true) {
        if (std.mem.indexOfScalar(u8, remaining, '\n')) |newline| {
            rows += wrappedSegmentRowCount(remaining[0..newline], width);
            remaining = remaining[newline + 1 ..];
            if (remaining.len == 0) return rows + 1;
            continue;
        }
        return rows + wrappedSegmentRowCount(remaining, width);
    }
}

fn wrappedSegmentRowCount(segment: []const u8, width: usize) usize {
    if (segment.len == 0) return 1;
    var rows: usize = 0;
    var offset: usize = 0;
    const safe_width = @max(@as(usize, 1), width);
    while (offset < segment.len) {
        rows += 1;
        offset += wrappedSegmentTake(segment, offset, safe_width);
    }
    return rows;
}

fn wrappedSegmentTake(segment: []const u8, offset: usize, width: usize) usize {
    const rest = segment[offset..];
    var take = @min(width, rest.len);
    if (take < rest.len) {
        var split = take;
        while (split > 0 and rest[split - 1] != ' ' and rest[split - 1] != '\t') split -= 1;
        if (split > 0) take = split;
    }
    return @max(@as(usize, 1), take);
}

fn expectRowsBorrowMessageStorage(rows: []const TranscriptRow, messages: []const Message) !void {
    for (rows) |row| {
        if (row.gap or row.pending or row.intro or row.text.len == 0) continue;
        try std.testing.expect(sliceBorrowedFromMessages(row.text, messages));
    }
}

fn expectScreenTextBorrowMessageStorage(screen: tui.Screen, messages: []const Message) !void {
    for (screen.buf) |cell| {
        const text = cell.char.grapheme;
        if (text.len == 0) continue;
        if (std.mem.eql(u8, text, " ")) continue;
        if (std.mem.eql(u8, text, "│")) continue;
        if (sliceBorrowedFromStartupIntro(text)) continue;
        try std.testing.expect(sliceBorrowedFromMessages(text, messages));
    }
}

fn sliceBorrowedFromStartupIntro(slice: []const u8) bool {
    if (slice.len == 0) return true;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    for (startup_intro_lines) |line| {
        const line_start = @intFromPtr(line.ptr);
        const line_end = line_start + line.len;
        if (slice_start >= line_start and slice_end <= line_end) return true;
    }
    const version_start = @intFromPtr(startup_intro_version.ptr);
    const version_end = version_start + startup_intro_version.len;
    if (slice_start >= version_start and slice_end <= version_end) return true;
    return false;
}

fn sliceBorrowedFromMessages(slice: []const u8, messages: []const Message) bool {
    if (slice.len == 0) return true;
    const slice_start = @intFromPtr(slice.ptr);
    const slice_end = slice_start + slice.len;
    for (messages) |message| {
        if (message.text.len == 0) continue;
        const message_start = @intFromPtr(message.text.ptr);
        const message_end = message_start + message.text.len;
        if (slice_start >= message_start and slice_end <= message_end) return true;
    }
    return false;
}

fn isCompactRole(role: Role) bool {
    return role == .progress or role == .system;
}

fn bodyStyle(role: Role) Style {
    return switch (role) {
        .user => styles.user_text,
        .assistant => styles.assistant_text,
        .progress => styles.progress,
        .system => styles.system,
    };
}

fn roleStyle(role: Role) Style {
    return switch (role) {
        .user => styles.user,
        .assistant => styles.assistant,
        .progress => styles.progress,
        .system => styles.system,
    };
}

fn formatFooterMeta(
    allocator: std.mem.Allocator,
    model: []const u8,
    effort: []const u8,
    thinking_mode: []const u8,
    context_used_tokens: ?u64,
    context_window_tokens: u64,
    running_agents: usize,
    total_agents: usize,
    waiting: bool,
    cancel_requested: bool,
    scroll_offset: usize,
    width: usize,
) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");

    const effort_label = footerEffortLabel(effort, thinking_mode);
    const context_full = try formatContextMeta(allocator, context_used_tokens, context_window_tokens, true);
    defer allocator.free(context_full);
    const context_compact = try formatContextMeta(allocator, context_used_tokens, context_window_tokens, false);
    defer allocator.free(context_compact);

    const agents = if (waiting and total_agents > 0)
        try std.fmt.allocPrint(allocator, "agents {d}/{d}", .{ running_agents, total_agents })
    else
        try allocator.dupe(u8, "");
    defer allocator.free(agents);

    const status = try formatFooterStatus(allocator, waiting, cancel_requested, scroll_offset);
    defer allocator.free(status);

    var candidate = try buildFooterMetaLine(allocator, model, effort_label, context_full, agents, status, true, true, true);
    if (candidate.len <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, model, effort_label, context_compact, agents, "", true, true, false);
    if (candidate.len <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, model, "", context_compact, agents, "", false, true, false);
    if (candidate.len <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, model, "", context_compact, "", "", false, false, false);
    if (candidate.len <= width) return candidate;
    allocator.free(candidate);

    const context_budget = @min(context_compact.len, width);
    if (context_budget == width) return truncateEnd(allocator, context_compact, width);
    const model_budget = width - context_budget -| 3;
    const compact_model = try truncateEnd(allocator, model, model_budget);
    defer allocator.free(compact_model);
    return std.fmt.allocPrint(allocator, "{s} · {s}", .{ compact_model, context_compact });
}

fn footerEffortLabel(effort: []const u8, thinking_mode: []const u8) []const u8 {
    if (effort.len > 0) return effort;
    if (std.ascii.eqlIgnoreCase(thinking_mode, "enabled")) return "thinking";
    return "default";
}

fn formatContextMeta(
    allocator: std.mem.Allocator,
    context_used_tokens: ?u64,
    context_window_tokens: u64,
    include_remaining: bool,
) ![]u8 {
    if (context_window_tokens == 0) return allocator.dupe(u8, "ctx —");

    const capacity = try compactTokenCount(allocator, context_window_tokens);
    defer allocator.free(capacity);
    if (context_used_tokens == null) {
        return std.fmt.allocPrint(allocator, "ctx — / {s}", .{capacity});
    }

    const used_value = @min(context_used_tokens.?, context_window_tokens);
    const used = try compactTokenCount(allocator, used_value);
    defer allocator.free(used);
    const percent: u64 = @intCast(((@as(u128, used_value) * 100) + (@as(u128, context_window_tokens) / 2)) / @as(u128, context_window_tokens));
    if (!include_remaining) {
        return std.fmt.allocPrint(allocator, "ctx {s} / {s} ({d}%)", .{ used, capacity, percent });
    }

    const remaining = try compactTokenCount(allocator, context_window_tokens - used_value);
    defer allocator.free(remaining);
    return std.fmt.allocPrint(allocator, "ctx {s} / {s} ({d}%) · {s} left", .{ used, capacity, percent, remaining });
}

fn compactTokenCount(allocator: std.mem.Allocator, value: u64) ![]u8 {
    if (value >= 1_000_000) {
        const whole = value / 1_000_000;
        const tenths = (value % 1_000_000) / 100_000;
        return if (tenths == 0)
            std.fmt.allocPrint(allocator, "{d}m", .{whole})
        else
            std.fmt.allocPrint(allocator, "{d}.{d}m", .{ whole, tenths });
    }
    if (value >= 1_000) {
        const whole = value / 1_000;
        const tenths = (value % 1_000) / 100;
        return if (tenths == 0)
            std.fmt.allocPrint(allocator, "{d}k", .{whole})
        else
            std.fmt.allocPrint(allocator, "{d}.{d}k", .{ whole, tenths });
    }
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn buildFooterMetaLine(
    allocator: std.mem.Allocator,
    model: []const u8,
    effort: []const u8,
    context: []const u8,
    agents: []const u8,
    status: []const u8,
    include_effort: bool,
    include_agents: bool,
    include_status: bool,
) ![]u8 {
    var line = std.array_list.Managed(u8).init(allocator);
    errdefer line.deinit();
    var first = true;
    try appendFooterPart(&line, &first, model);
    if (include_effort) try appendFooterPart(&line, &first, effort);
    try appendFooterPart(&line, &first, context);
    if (include_agents) try appendFooterPart(&line, &first, agents);
    if (include_status) try appendFooterPart(&line, &first, status);
    return line.toOwnedSlice();
}

fn appendFooterPart(line: *std.array_list.Managed(u8), first: *bool, part: []const u8) !void {
    if (part.len == 0) return;
    if (!first.*) try line.appendSlice(" · ");
    try line.appendSlice(part);
    first.* = false;
}

fn formatFooterStatus(
    allocator: std.mem.Allocator,
    waiting: bool,
    cancel_requested: bool,
    scroll_offset: usize,
) ![]u8 {
    // Waiting is rendered by the agent-count segment in formatFooterMeta;
    // status itself only carries cancellation and scrollback state.
    _ = waiting;
    var status = std.array_list.Managed(u8).init(allocator);
    errdefer status.deinit();

    if (cancel_requested) {
        try status.appendSlice("cancelling");
    }

    if (scroll_offset > 0) {
        if (status.items.len > 0) try status.appendSlice(" · ");
        try status.writer().print("older +{d}", .{scroll_offset});
    }

    return status.toOwnedSlice();
}

fn compactPathTail(allocator: std.mem.Allocator, path: []const u8, width: usize) ![]u8 {
    if (path.len <= width) return allocator.dupe(u8, path);
    if (width <= 3) return dotted(allocator, width);

    const out = try allocator.alloc(u8, width);
    @memcpy(out[0..3], "...");
    const suffix_len = width - 3;
    @memcpy(out[3..], path[path.len - suffix_len ..]);
    return out;
}

fn truncateEnd(allocator: std.mem.Allocator, value: []const u8, width: usize) ![]u8 {
    if (value.len <= width) return allocator.dupe(u8, value);
    if (width <= 3) return dotted(allocator, width);

    const out = try allocator.alloc(u8, width);
    const prefix_len = width - 3;
    @memcpy(out[0..prefix_len], value[0..prefix_len]);
    @memcpy(out[prefix_len..], "...");
    return out;
}

fn dotted(allocator: std.mem.Allocator, width: usize) ![]u8 {
    const out = try allocator.alloc(u8, width);
    @memset(out, '.');
    return out;
}

fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '\\' or path[end - 1] == '/')) end -= 1;
    var start = end;
    while (start > 0) {
        const char = path[start - 1];
        if (char == '\\' or char == '/') break;
        start -= 1;
    }
    return path[start..end];
}

const max_progress_message_bytes: usize = 220;
const max_tool_output_preview_bytes: usize = 180;
const max_tool_output_payload_bytes: usize = 180;
const max_seen_progress_events: usize = 512;

fn formatProgress(allocator: std.mem.Allocator, event_type: []const u8, message: []const u8) !?[]u8 {
    if (std.mem.eql(u8, event_type, "tool_requested")) return formatToolRequested(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_reviewed")) return formatToolReview(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_started")) return formatToolStarted(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_output_delta")) return formatToolOutputDelta(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_finished")) return formatToolFinished(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_completed")) return formatToolCompleted(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_blocked")) return formatToolBlocked(allocator, message);
    if (std.mem.eql(u8, event_type, "tool_budget_exceeded")) return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "budget: {s}", .{message}));
    if (std.mem.eql(u8, event_type, "session_waiting")) return try allocator.dupe(u8, "waiting on child group");
    if (std.mem.eql(u8, event_type, "child_convergence_started")) return try allocator.dupe(u8, "agents converging");
    if (std.mem.eql(u8, event_type, "session_failed")) return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "failed: {s}", .{message}));
    if (std.mem.startsWith(u8, event_type, "context_compaction_")) return formatContextCompaction(allocator, event_type, message);

    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ progressLabel(event_type), message }));
}

fn formatToolRequested(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const prefix = "tool requested: ";
    const tools = stripPrefix(message, prefix) orelse message;
    const summary = try compactToolList(allocator, tools);
    defer allocator.free(summary);
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "tool: {s}", .{summary}));
}

fn formatToolReview(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const ToolReview = struct {
        tool: []const u8 = "",
        risk: []const u8 = "",
        approved: bool = false,
    };
    var parsed = std.json.parseFromSlice(ToolReview, allocator, message, .{
        .ignore_unknown_fields = true,
    }) catch {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "review: {s}", .{message}));
    };
    defer parsed.deinit();

    if (parsed.value.approved) return null;
    if (parsed.value.risk.len == 0) {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "review: denied {s}", .{parsed.value.tool}));
    }
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "review: denied {s} ({s})", .{ parsed.value.tool, parsed.value.risk }));
}

fn formatToolStarted(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const ToolStarted = struct {
        tool: []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(ToolStarted, allocator, message, .{
        .ignore_unknown_fields = true,
    }) catch {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "start: {s}", .{message}));
    };
    defer parsed.deinit();

    if (parsed.value.tool.len == 0) return null;
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "start: {s}", .{parsed.value.tool}));
}

fn formatToolOutputDelta(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const ToolOutputDelta = struct {
        tool: []const u8 = "",
        stream: []const u8 = "",
        chunk_b64: []const u8 = "",
        cap_reached: bool = false,
    };
    var parsed = std.json.parseFromSlice(ToolOutputDelta, allocator, message, .{
        .ignore_unknown_fields = true,
    }) catch {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "output: {s}", .{message}));
    };
    defer parsed.deinit();

    if (parsed.value.chunk_b64.len == 0 and !parsed.value.cap_reached) return null;

    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(parsed.value.chunk_b64) catch {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: <invalid output chunk>", .{parsed.value.stream}));
    };
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    if (decoded_size > 0) {
        std.base64.standard.Decoder.decode(decoded, parsed.value.chunk_b64) catch {
            return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: <invalid output chunk>", .{parsed.value.stream}));
        };
    }

    const normalized = try normalizeTerminalChunk(allocator, decoded);
    defer allocator.free(normalized);
    const preview = try compactOutputPreview(allocator, normalized);
    defer allocator.free(preview);

    const suffix = if (parsed.value.cap_reached) " [cap]" else "";
    const stream = if (parsed.value.stream.len == 0) "output" else parsed.value.stream;
    if (preview.len == 0) {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}:{s}", .{ stream, suffix }));
    }
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}{s}", .{ stream, preview, suffix }));
}

fn formatToolFinished(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const ToolFinished = struct {
        tool: []const u8 = "",
        ok: bool = false,
        error_name: ?[]const u8 = null,
        hint: ?[]const u8 = null,
        duration_ms: i64 = 0,
    };
    var parsed = std.json.parseFromSlice(ToolFinished, allocator, message, .{
        .ignore_unknown_fields = true,
    }) catch {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "finish: {s}", .{message}));
    };
    defer parsed.deinit();

    const tool = if (parsed.value.tool.len == 0) "tool" else parsed.value.tool;
    if (parsed.value.ok) {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "done: {s} {d}ms", .{ tool, parsed.value.duration_ms }));
    }
    if (parsed.value.error_name) |error_name| {
        if (parsed.value.hint) |hint| {
            return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "error: {s} ({s}) {d}ms - {s}", .{ tool, error_name, parsed.value.duration_ms, hint }));
        }
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "error: {s} ({s}) {d}ms", .{ tool, error_name, parsed.value.duration_ms }));
    }
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "error: {s} {d}ms", .{ tool, parsed.value.duration_ms }));
}

fn formatToolCompleted(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    _ = allocator;
    _ = message;
    return null;
}

fn formatLegacyToolCompleted(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    if (stripPrefix(message, "tool completed: ")) |tool| {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "done: {s}", .{tool}));
    }
    if (stripPrefix(message, "tool errored: ")) |detail| {
        const short = firstBefore(detail, " - ");
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "error: {s}", .{short}));
    }
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "done: {s}", .{message}));
}

fn formatToolBlocked(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    if (stripPrefix(message, "tool blocked: ")) |detail| {
        return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "blocked: {s}", .{detail}));
    }
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "blocked: {s}", .{message}));
}

fn formatContextCompaction(allocator: std.mem.Allocator, event_type: []const u8, message: []const u8) !?[]u8 {
    if (std.mem.eql(u8, event_type, "context_compaction_started")) return try allocator.dupe(u8, "context: compacting");
    if (std.mem.eql(u8, event_type, "context_compaction_completed")) return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "context: {s}", .{message}));
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "context: {s}", .{message}));
}

fn compactToolList(allocator: std.mem.Allocator, tools: []const u8) ![]u8 {
    const Group = struct {
        name: []const u8,
        count: usize = 1,
    };

    var groups = std.array_list.Managed(Group).init(allocator);
    defer groups.deinit();

    var split = std.mem.splitSequence(u8, tools, ", ");
    while (split.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        if (value.len == 0) continue;
        var found = false;
        for (groups.items) |*group| {
            if (std.mem.eql(u8, group.name, value)) {
                group.count += 1;
                found = true;
                break;
            }
        }
        if (!found) try groups.append(.{ .name = value });
    }

    if (groups.items.len == 0) return allocator.dupe(u8, std.mem.trim(u8, tools, " \t\r\n"));

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    for (groups.items, 0..) |group, index| {
        if (index > 0) try writer.writeAll(", ");
        if (group.count > 1) {
            try writer.print("{s} x{d}", .{ group.name, group.count });
        } else {
            try writer.writeAll(group.name);
        }
    }
    return output.toOwnedSlice();
}

fn trimOwnedProgress(allocator: std.mem.Allocator, text: []u8) ![]u8 {
    if (text.len <= max_progress_message_bytes) return text;
    const trimmed = try std.fmt.allocPrint(allocator, "{s}...", .{text[0 .. max_progress_message_bytes - 3]});
    allocator.free(text);
    return trimmed;
}

fn appendBoundedProgress(allocator: std.mem.Allocator, previous: []const u8, stream: []const u8, formatted: []const u8) ![]u8 {
    const prefix = try std.fmt.allocPrint(allocator, "{s}: ", .{stream});
    defer allocator.free(prefix);

    const previous_payload = if (std.mem.startsWith(u8, previous, prefix)) previous[prefix.len..] else previous;
    const payload = if (std.mem.startsWith(u8, formatted, prefix)) formatted[prefix.len..] else formatted;
    var combined = if (previous_payload.len == 0)
        try allocator.dupe(u8, payload)
    else if (payload.len == 0)
        try allocator.dupe(u8, previous_payload)
    else
        try std.fmt.allocPrint(allocator, "{s} | {s}", .{ previous_payload, payload });
    errdefer allocator.free(combined);

    if (combined.len > max_tool_output_payload_bytes) {
        const keep = max_tool_output_payload_bytes - "...".len;
        const trimmed = try std.fmt.allocPrint(allocator, "...{s}", .{combined[combined.len - keep ..]});
        allocator.free(combined);
        combined = trimmed;
    }
    defer allocator.free(combined);

    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, combined });
}

fn compactOutputPreview(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return allocator.dupe(u8, "");

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var lines: usize = 1;
    var last_was_space = false;
    for (value) |byte| {
        switch (byte) {
            '\n' => {
                lines += 1;
                if (!last_was_space and output.items.len > 0) {
                    try output.append(' ');
                    last_was_space = true;
                }
            },
            '\r', '\t', ' ' => {
                if (!last_was_space and output.items.len > 0) {
                    try output.append(' ');
                    last_was_space = true;
                }
            },
            else => {
                try output.append(byte);
                last_was_space = false;
            },
        }
    }

    while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') {
        _ = output.pop();
    }

    if (lines > 1) {
        try output.writer().print(" ({d} lines)", .{lines});
    }

    if (output.items.len <= max_tool_output_preview_bytes) return output.toOwnedSlice();
    const keep = max_tool_output_preview_bytes - "...".len;
    return std.fmt.allocPrint(allocator, "{s}...", .{output.items[0..keep]});
}

fn formatToolTranscriptMessage(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const preview = try compactOutputPreview(allocator, value);
    defer allocator.free(preview);
    if (preview.len == 0) return allocator.dupe(u8, "tool: <empty result>");
    return std.fmt.allocPrint(allocator, "tool: {s}", .{preview});
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn firstBefore(value: []const u8, needle: []const u8) []const u8 {
    if (std.mem.indexOf(u8, value, needle)) |index| return value[0..index];
    return value;
}

fn normalizeTerminalChunk(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var index: usize = 0;
    var line_start: usize = 0;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (byte == 0x1b and index + 1 < value.len and value[index + 1] == '[') {
            index += 2;
            while (index < value.len) : (index += 1) {
                if (value[index] >= 0x40 and value[index] <= 0x7e) break;
            }
            continue;
        }
        switch (byte) {
            '\r' => {
                if (index + 1 < value.len and value[index + 1] == '\n') continue;
                output.shrinkRetainingCapacity(line_start);
            },
            '\n' => {
                try output.append(byte);
                line_start = output.items.len;
            },
            '\t' => try output.append(byte),
            0x08 => {
                if (output.items.len > line_start) output.shrinkRetainingCapacity(output.items.len - 1);
            },
            0x20...0x7e => try output.append(byte),
            else => try output.append('.'),
        }
    }

    const trimmed = std.mem.trim(u8, output.items, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}

fn skipProgressEvent(event_type: []const u8) bool {
    // Internal lifecycle events that carry typed schema payloads must never
    // render in the operator chat — only agent responses, compact tool rows,
    // and the batched reasoning block belong in the transcript. Everything
    // else is kernel mechanics (AGENTS.md §X: diagnostics thinner than the
    // capability they serve; §XVI: no prompt scaffolding leaking into UI).
    return std.mem.eql(u8, event_type, "session_started") or
        std.mem.eql(u8, event_type, "assistant_response") or
        std.mem.eql(u8, event_type, "reasoning_delta") or
        std.mem.eql(u8, event_type, "turn_started") or
        std.mem.eql(u8, event_type, "turn_finished") or
        std.mem.eql(u8, event_type, "provider_turn_recovered") or
        std.mem.eql(u8, event_type, "branch_converged") or
        std.mem.eql(u8, event_type, "session_delegated") or
        std.mem.startsWith(u8, event_type, "context_compaction_");
}

fn replayProgressEvent(event_type: []const u8) bool {
    return std.mem.startsWith(u8, event_type, "child_") or std.mem.eql(u8, event_type, "session_waiting");
}

fn progressLabel(event_type: []const u8) []const u8 {
    if (std.mem.eql(u8, event_type, "session_started")) return "started";
    if (std.mem.eql(u8, event_type, "tool_requested")) return "tool";
    if (std.mem.eql(u8, event_type, "tool_reviewed")) return "review";
    if (std.mem.eql(u8, event_type, "tool_started")) return "start";
    if (std.mem.eql(u8, event_type, "tool_finished")) return "finish";
    if (std.mem.eql(u8, event_type, "tool_completed")) return "done";
    if (std.mem.eql(u8, event_type, "tool_blocked")) return "blocked";
    if (std.mem.eql(u8, event_type, "tool_budget_exceeded")) return "budget";
    if (std.mem.eql(u8, event_type, "session_waiting")) return "waiting";
    if (std.mem.startsWith(u8, event_type, "context_compaction_")) return "context";
    if (std.mem.eql(u8, event_type, "session_failed")) return "failed";
    return event_type;
}

fn expectKernelResult(allocator: std.mem.Allocator, call: stdio_rpc.RpcCallResult) ![]u8 {
    if (call.result_json) |result_json| return allocator.dupe(u8, result_json);
    if (call.error_json != null) return error.KernelRpcError;
    return error.InvalidRpcResponse;
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
}

test "tui stream cadence coalesces bursts without delaying an idle first frame" {
    try std.testing.expectEqual(stream_idle_wait_ms, nextStreamWaitMs(false, 0, stream_min_frame_ns));
    try std.testing.expectEqual(@as(usize, 15), nextStreamWaitMs(true, std.time.ns_per_ms, stream_min_frame_ns));
    try std.testing.expectEqual(@as(usize, 1), nextStreamWaitMs(true, stream_min_frame_ns - 1, stream_min_frame_ns));
    try std.testing.expectEqual(@as(usize, 0), nextStreamWaitMs(true, stream_min_frame_ns, stream_min_frame_ns));
}

test "tui assistant stream grows geometrically instead of reallocating every delta" {
    const allocator = std.testing.allocator;
    var message = Message{
        .role = .assistant,
        .text = try allocator.dupe(u8, "a"),
    };
    defer message.deinit(allocator);

    try message.appendText(allocator, "bc");
    const capacity_after_growth = message.text_capacity;
    const pointer_after_growth = message.text.ptr;
    try message.appendText(allocator, "def");

    try std.testing.expectEqualStrings("abcdef", message.text);
    try std.testing.expect(capacity_after_growth >= 6);
    try std.testing.expectEqual(pointer_after_growth, message.text.ptr);
}

test "tui progress hides successful approval review noise" {
    const allocator = std.testing.allocator;
    const formatted = try formatProgress(allocator, "tool_reviewed", "{\"schema\":\"var1.tool_review.v1\",\"tool\":\"shell_exec\",\"risk\":\"command_execution\",\"approved\":true}");
    try std.testing.expect(formatted == null);
}

test "tui progress renders tool lifecycle as compact user-facing rows" {
    const allocator = std.testing.allocator;

    const requested = (try formatProgress(allocator, "tool_requested", "tool requested: append_file, append_file, append_file")) orelse return error.TestUnexpectedNull;
    defer allocator.free(requested);
    try std.testing.expectEqualStrings("tool: append_file x3", requested);

    const started = (try formatProgress(allocator, "tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"timestamp_ms\":1}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(started);
    try std.testing.expectEqualStrings("start: shell_exec", started);

    const completed = (try formatProgress(allocator, "tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"ok\":true,\"duration_ms\":42}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(completed);
    try std.testing.expectEqualStrings("done: shell_exec 42ms", completed);

    const errored = (try formatProgress(allocator, "tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"write_file\",\"tool_call_id\":\"call_2\",\"ok\":false,\"error_name\":\"ToolPayloadExceeded\",\"duration_ms\":3}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(errored);
    try std.testing.expectEqualStrings("error: write_file (ToolPayloadExceeded) 3ms", errored);

    const hinted = (try formatProgress(allocator, "tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_3\",\"ok\":false,\"error_name\":\"InvalidArguments\",\"duration_ms\":4,\"hint\":\"Use mode=argv with argv only, or mode=powershell/shell/bash with command only. On Windows, use PowerShell-native commands such as Select-String.\"}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(hinted);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "error: shell_exec (InvalidArguments) 4ms - Use mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, hinted, "Select-String") != null);

    const legacy_completed = try formatLegacyToolCompleted(allocator, "tool completed: shell_exec");
    defer if (legacy_completed) |value| allocator.free(value);
    try std.testing.expect(legacy_completed != null);
}

test "tui progress renders hostile output chunks without corrupting the transcript surface" {
    const allocator = std.testing.allocator;

    const stdout_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"YWxwaGEKYmV0YQ==\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(stdout_chunk);
    try std.testing.expectEqualStrings("stdout: alpha beta (2 lines)", stdout_chunk);

    const stderr_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stderr\",\"chunk_b64\":\"d2Fybg0K\",\"cap_reached\":true}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(stderr_chunk);
    try std.testing.expectEqualStrings("stderr: warn [cap]", stderr_chunk);

    const invalid_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"%%%\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(invalid_chunk);
    try std.testing.expectEqualStrings("stdout: <invalid output chunk>", invalid_chunk);

    const binary_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"QQBCfw==\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(binary_chunk);
    try std.testing.expectEqualStrings("stdout: A.B.", binary_chunk);
}

test "tui startup errors render typed operator-facing envelopes" {
    const invalid_handle = try renderStartupFailure(std.testing.allocator, error.InvalidHandle);
    defer std.testing.allocator.free(invalid_handle);
    try std.testing.expect(std.mem.indexOf(u8, invalid_handle, "code=TerminalUnavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_handle, "interactive terminal handle") != null);

    const invalid_rpc = try renderStartupFailure(std.testing.allocator, error.InvalidRpcResponse);
    defer std.testing.allocator.free(invalid_rpc);
    try std.testing.expect(std.mem.indexOf(u8, invalid_rpc, "code=KernelInvalidRpcResponse") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_rpc, "invalid JSON-RPC response") != null);
}

test "tui latest-session hydration restores transcript rows before the next turn" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\MEMBRANE-FRAMEWORK",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    var messages = [_]VAR1.shared.types.SessionMessage{
        .{
            .id = try allocator.dupe(u8, "msg-1"),
            .seq = 1,
            .role = .user,
            .content = try allocator.dupe(u8, "hi"),
            .timestamp_ms = 1,
        },
        .{
            .id = try allocator.dupe(u8, "msg-2"),
            .seq = 2,
            .role = .assistant,
            .content = try allocator.dupe(u8, "hello back"),
            .timestamp_ms = 2,
        },
        .{
            .id = try allocator.dupe(u8, "msg-3"),
            .seq = 3,
            .role = .tool,
            .content = try allocator.dupe(u8, "alpha\nbeta\n"),
            .timestamp_ms = 3,
        },
    };
    defer for (&messages) |message| message.deinit(allocator);

    try state.hydrateTranscript(&messages);

    try std.testing.expectEqual(@as(usize, 3), state.messages.items.len);
    try std.testing.expectEqual(.user, state.messages.items[0].role);
    try std.testing.expectEqualStrings("hi", state.messages.items[0].text);
    try std.testing.expectEqual(.assistant, state.messages.items[1].role);
    try std.testing.expectEqualStrings("hello back", state.messages.items[1].text);
    try std.testing.expectEqual(.progress, state.messages.items[2].role);
    try std.testing.expectEqualStrings("tool: alpha beta (3 lines)", state.messages.items[2].text);
}

test "tui transcript prepends startup intro without creating a message" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var screen = try tui.Screen.init(allocator, .{ .rows = 10, .cols = 52, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.add(.user, "first operator message");
    const win = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
        .unicode = &unicode,
    };

    var rows = try buildTranscriptRows(allocator, win, &state);
    defer rows.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(rows.items[0].intro);
    try std.testing.expectEqualStrings(startup_intro_lines[0], rows.items[0].text);
    try std.testing.expect(rows.items[startup_intro_lines.len].intro_version);
    try std.testing.expectEqualStrings(startup_intro_version, rows.items[startup_intro_lines.len].text);
    try std.testing.expect(rows.items[startup_intro_lines.len + 1].gap);
    try std.testing.expectEqualStrings("first operator message", rows.items[startup_intro_projected_rows].text);
    try std.testing.expectEqual(@as(usize, 6), visibleTranscriptRowCount(rows.items));
}

test "tui progress keeps stdout and stderr streams separated for one tool call" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const stdout_one = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_stream\",\"stream\":\"stdout\",\"chunk_b64\":\"b25l\",\"cap_reached\":false}";
    const stderr_one = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_stream\",\"stream\":\"stderr\",\"chunk_b64\":\"d2Fybg==\",\"cap_reached\":false}";
    const stdout_two = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_stream\",\"stream\":\"stdout\",\"chunk_b64\":\"dHdv\",\"cap_reached\":true}";

    try state.addProgress("tool_output_delta", stdout_one);
    try state.addProgress("tool_output_delta", stderr_one);
    try state.addProgress("tool_output_delta", stdout_two);

    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("stdout: one | two [cap]", state.messages.items[0].text);
    try std.testing.expectEqualStrings("call_stream\x1eoutput\x1estdout", state.messages.items[0].tool_call_id.?);
    try std.testing.expectEqualStrings("stderr: warn", state.messages.items[1].text);
    try std.testing.expectEqualStrings("call_stream\x1eoutput\x1estderr", state.messages.items[1].tool_call_id.?);
}

test "tui hinted tool errors remain bounded and replace running rows under hostile payloads" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addProgress("tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_long\",\"timestamp_ms\":1}");
    try state.addProgress("tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_long\",\"ok\":false,\"error_name\":\"InvalidArguments\",\"duration_ms\":4,\"hint\":\"Use mode=argv with argv only. This hint is intentionally long so the transcript row must stay bounded and cannot push the composer or corrupt scrollback xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}");
    try state.addProgress("tool_completed", "tool errored: shell_exec (InvalidArguments) - duplicate legacy row should stay hidden");

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(Role.progress, state.messages.items[0].role);
    try std.testing.expect(std.mem.startsWith(u8, state.messages.items[0].text, "shell_exec - InvalidArguments - 4ms - Use mode=argv"));
    try std.testing.expect(state.messages.items[0].text.len <= max_progress_message_bytes);
    try std.testing.expect(std.mem.endsWith(u8, state.messages.items[0].text, "..."));
}

test "tui progress preserves mixed tool pressure and bounds long rows" {
    const allocator = std.testing.allocator;

    const mixed_tools = (try formatProgress(allocator, "tool_requested", "tool requested: read_file, shell_exec, append_file")) orelse return error.TestUnexpectedNull;
    defer allocator.free(mixed_tools);
    try std.testing.expectEqualStrings("tool: read_file, shell_exec, append_file", mixed_tools);

    const long_payload =
        "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    const long_row = (try formatProgress(allocator, "session_failed", long_payload)) orelse return error.TestUnexpectedNull;
    defer allocator.free(long_row);
    try std.testing.expect(long_row.len <= max_progress_message_bytes);
    try std.testing.expect(std.mem.endsWith(u8, long_row, "..."));
}

test "tui progress strips terminal color controls from streamed command output" {
    const allocator = std.testing.allocator;

    const ansi_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"G1szMW1yZWQbWzBt\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(ansi_chunk);
    try std.testing.expectEqualStrings("stdout: red", ansi_chunk);
}

test "tui progress renders terminal overwrite controls as the latest readable state" {
    const allocator = std.testing.allocator;

    const carriage_return_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"UHJvZ3Jlc3MgMTAlDVByb2dyZXNzIDkwJQ==\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(carriage_return_chunk);
    try std.testing.expectEqualStrings("stdout: Progress 90%", carriage_return_chunk);

    const backspace_chunk = (try formatProgress(allocator, "tool_output_delta", "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"Zm9vCHgKYmFy\",\"cap_reached\":false}")) orelse return error.TestUnexpectedNull;
    defer allocator.free(backspace_chunk);
    try std.testing.expectEqualStrings("stdout: fox bar (2 lines)", backspace_chunk);
}

test "tui streamed command output stays in one bounded row and preserves latest evidence" {
    const allocator = std.testing.allocator;
    var row = try allocator.dupe(u8, "stdout: first");
    defer allocator.free(row);

    var index: usize = 0;
    while (index < 80) : (index += 1) {
        const next = try appendBoundedProgress(allocator, row, "stdout", "stdout: latest-output-fragment");
        allocator.free(row);
        row = next;
    }

    try std.testing.expect(row.len <= max_progress_message_bytes);
    try std.testing.expect(std.mem.startsWith(u8, row, "stdout: ..."));
    try std.testing.expect(std.mem.endsWith(u8, row, "latest-output-fragment"));
    try std.testing.expect(std.mem.indexOfScalar(u8, row, '\n') == null);
}

test "tui output preview flattens code-shaped multiline payloads" {
    const allocator = std.testing.allocator;

    const code = "pub fn main() void {\n    std.debug.print(\"ok\", .{});\n}";
    const preview = try compactOutputPreview(allocator, code);
    defer allocator.free(preview);

    try std.testing.expectEqualStrings("pub fn main() void { std.debug.print(\"ok\", .{}); } (3 lines)", preview);
}

test "tui chat state coalesces assistant tokens and streams repeated command output into one row" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addAssistantDelta("Hel");
    try state.addAssistantDelta("lo");
    try std.testing.expect(state.received_assistant_delta);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(Role.assistant, state.messages.items[0].role);
    try std.testing.expectEqualStrings("Hello", state.messages.items[0].text);

    try state.addProgress("tool_requested", "tool requested: read_file, read_file");
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);

    const repeated_output = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"bGluZQ==\",\"cap_reached\":false}";
    try state.addProgress("tool_output_delta", repeated_output);
    try state.addProgress("tool_output_delta", repeated_output);
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("stdout: line | line", state.messages.items[1].text);
    try std.testing.expectEqualStrings("call_1\x1eoutput\x1estdout", state.messages.items[1].tool_call_id.?);

    try state.addAssistantDelta("After tool.");
    try std.testing.expectEqual(@as(usize, 3), state.messages.items.len);
    try std.testing.expectEqual(Role.assistant, state.messages.items[2].role);
    try std.testing.expectEqualStrings("After tool.", state.messages.items[2].text);
}

test "tui tool lifecycle updates one progress row instead of appending request start done rows" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addProgress("tool_requested", "tool requested: write_file");
    try std.testing.expectEqual(@as(usize, 0), state.messages.items.len);

    try state.addProgress("tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"write_file\",\"tool_call_id\":\"call_1\",\"timestamp_ms\":1}");
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(Role.progress, state.messages.items[0].role);
    try std.testing.expectEqualStrings("write_file", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityKind.group, state.messages.items[0].activity_kind);
    try std.testing.expectEqual(ActivityState.running, state.messages.items[0].activity_state);

    try state.addProgress("tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"write_file\",\"tool_call_id\":\"call_1\",\"ok\":true,\"duration_ms\":42}");
    try state.addProgress("tool_completed", "tool completed: write_file");
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("write_file - 42ms", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityState.completed, state.messages.items[0].activity_state);
}

test "tui tool lifecycle keeps actionable schema errors in the keyed tool row" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addProgress("tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_bad\",\"timestamp_ms\":1}");
    try state.addProgress("tool_finished", "{\"schema\":\"var1.tool_finished.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_bad\",\"ok\":false,\"error_name\":\"InvalidArguments\",\"duration_ms\":4,\"hint\":\"Use mode=argv with argv only, or mode=powershell/shell/bash with command only. On Windows, use PowerShell-native commands such as Select-String and Get-ChildItem.\"}");
    try state.addProgress("tool_completed", "tool errored: shell_exec (InvalidArguments) - legacy hint should stay suppressed");

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "shell_exec - InvalidArguments - 4ms - Use mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "Select-String") != null);
}

test "tui chat starts visible assistant feedback immediately and replaces it with real deltas" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.startAssistantPlaceholder();
    try std.testing.expect(state.pending_assistant_placeholder);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(Role.assistant, state.messages.items[0].role);
    try std.testing.expect(state.messages.items[0].pending);
    try std.testing.expectEqualStrings("", state.messages.items[0].text);

    try state.addAssistantDelta("Hel");
    try state.addAssistantDelta("lo");
    try std.testing.expect(!state.pending_assistant_placeholder);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(!state.messages.items[0].pending);
    try std.testing.expectEqualStrings("Hello", state.messages.items[0].text);
}

test "tui chat removes pending assistant placeholder when tool progress arrives first" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.startAssistantPlaceholder();
    try state.addProgress("tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"timestamp_ms\":1}");
    try state.addAssistantDelta("Done.");

    try std.testing.expect(!state.pending_assistant_placeholder);
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqual(Role.progress, state.messages.items[0].role);
    try std.testing.expectEqualStrings("shell_exec", state.messages.items[0].text);
    try std.testing.expectEqual(Role.assistant, state.messages.items[1].role);
    try std.testing.expectEqualStrings("Done.", state.messages.items[1].text);
}

test "tui progress event cursor preserves same timestamp bursts and rejects replays" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const first_output = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"b25l\",\"cap_reached\":false}";
    const second_output = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"dHdv\",\"cap_reached\":false}";
    try std.testing.expect(try state.recordProgressEvent("tool_output_delta", first_output, 42));
    try std.testing.expect(try state.recordProgressEvent("tool_output_delta", second_output, 42));
    try std.testing.expect(!try state.recordProgressEvent("tool_output_delta", second_output, 42));

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("stdout: one | two", state.messages.items[0].text);
}

test "tui scrollback keeps transcript navigable without mutating input state" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.add(.user, "oldest");
    try state.add(.assistant, "middle");
    try state.add(.progress, "newest");

    const row_count = transcriptRowCount(&state, 80);
    try std.testing.expectEqual(@as(usize, 10), row_count);
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, row_count));
    state.scrollUp(1);
    try std.testing.expectEqual(@as(usize, 9), visibleEndRow(&state, row_count));
    try std.testing.expect(applyMouseScroll(&state, .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(@as(usize, 6), visibleEndRow(&state, row_count));
    try std.testing.expect(applyMouseScroll(&state, .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(@as(usize, 9), visibleEndRow(&state, row_count));
    state.scrollUp(100);
    try std.testing.expectEqual(@as(usize, 1), visibleEndRow(&state, row_count));
    state.scrollDown(1);
    try std.testing.expectEqual(@as(usize, 2), visibleEndRow(&state, row_count));
    state.jumpToBottom();
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, row_count));
}

test "tui keeps the operator's scroll anchor while live output continues below" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.add(.user, "first");
    try state.add(.assistant, "second");
    try state.add(.progress, "third");
    try state.add(.assistant, "fourth");

    state.scrollUp(2);
    try std.testing.expectEqual(@as(usize, 2), state.scroll_offset);
    const before_rows = transcriptRowCount(&state, 80);
    try std.testing.expectEqual(@as(usize, 12), before_rows);
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, before_rows));

    const output_event = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"bGl2ZS1saW5l\",\"cap_reached\":false}";
    try state.addProgress("tool_output_delta", output_event);
    try state.addProgress("tool_output_delta", output_event);

    try std.testing.expectEqual(@as(usize, 3), state.scroll_offset);
    const after_rows = transcriptRowCount(&state, 80);
    try std.testing.expectEqual(@as(usize, 13), after_rows);
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, after_rows));
    try std.testing.expectEqual(@as(usize, 5), state.messages.items.len);
    try std.testing.expectEqualStrings("stdout: live-line | live-line", state.messages.items[4].text);
}

test "tui transcript rows expose every wrapped line of a long assistant response" {
    const allocator = std.testing.allocator;
    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(allocator);

    var message = Message{
        .role = .assistant,
        .text = try allocator.dupe(u8, "alpha beta gamma delta"),
    };
    defer message.deinit(allocator);

    try appendMessageRows(allocator, &rows, message, 6);

    try std.testing.expectEqual(@as(usize, 5), rows.items.len);
    try std.testing.expectEqualStrings("alpha", rows.items[0].text);
    try std.testing.expectEqualStrings("beta", rows.items[1].text);
    try std.testing.expectEqualStrings("gamma", rows.items[2].text);
    try std.testing.expectEqualStrings("delta", rows.items[3].text);
    try std.testing.expect(rows.items[4].gap);

    const visible_rows = visibleTranscriptRowCount(rows.items);
    try std.testing.expectEqual(@as(usize, 4), visible_rows);

    const bottom_end = visibleEndRowForOffset(0, visible_rows);
    try std.testing.expectEqual(@as(usize, 4), bottom_end);
    try std.testing.expectEqual(@as(usize, 1), visibleStartRowForAvailable(3, bottom_end));

    const scrolled_end = visibleEndRowForOffset(2, visible_rows);
    try std.testing.expectEqual(@as(usize, 2), scrolled_end);
    try std.testing.expectEqual(@as(usize, 0), visibleStartRowForAvailable(3, scrolled_end));
}

test "tui viewport sweep reaches every wrapped assistant row without gaps" {
    const allocator = std.testing.allocator;
    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(allocator);

    var message = Message{
        .role = .assistant,
        .text = try allocator.dupe(u8, "alpha beta gamma delta epsilon zeta eta theta"),
    };
    defer message.deinit(allocator);

    try appendMessageRows(allocator, &rows, message, 8);
    const visible_rows = visibleTranscriptRowCount(rows.items);
    try std.testing.expectEqual(@as(usize, 8), visible_rows);

    var covered = try allocator.alloc(bool, visible_rows);
    defer allocator.free(covered);
    @memset(covered, false);

    var offset: usize = 0;
    while (offset < visible_rows) : (offset += 1) {
        const end = visibleEndRowForOffset(offset, visible_rows);
        const start = visibleStartRowForAvailable(3, end);
        var index = start;
        while (index < end) : (index += 1) covered[index] = true;
    }

    for (covered) |row_was_reachable| {
        try std.testing.expect(row_was_reachable);
    }
}

test "tui final response replacement preserves every wrapped row after thinking placeholder" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
        .last_transcript_body_width = 6,
    };
    defer state.deinit();

    try state.startAssistantPlaceholder();
    try std.testing.expect(try state.replaceAssistantPlaceholder("alpha beta gamma delta"));

    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(std.testing.allocator);
    try appendMessageRows(std.testing.allocator, &rows, state.messages.items[0], 6);

    try std.testing.expectEqual(@as(usize, 4), visibleTranscriptRowCount(rows.items));
    try std.testing.expectEqualStrings("alpha", rows.items[0].text);
    try std.testing.expectEqualStrings("beta", rows.items[1].text);
    try std.testing.expectEqualStrings("gamma", rows.items[2].text);
    try std.testing.expectEqualStrings("delta", rows.items[3].text);
}

test "tui transcript rows borrow durable message storage for render safety" {
    const allocator = std.testing.allocator;
    var message = Message{
        .role = .assistant,
        .text = try allocator.dupe(u8, "alpha beta gamma"),
    };
    defer message.deinit(allocator);

    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(allocator);
    try appendMessageRows(allocator, &rows, message, 6);

    const start = @intFromPtr(message.text.ptr);
    const end = start + message.text.len;
    for (rows.items[0..3]) |row| {
        const row_start = @intFromPtr(row.text.ptr);
        const row_end = row_start + row.text.len;
        try std.testing.expect(row_start >= start);
        try std.testing.expect(row_end <= end);
    }
}

test "tui streamed realloc rows borrow the final assistant buffer" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
        .last_transcript_body_width = 6,
    };
    defer state.deinit();

    try state.addAssistantDelta("alpha");
    try state.addAssistantDelta(" beta");
    try state.addAssistantDelta(" gamma");
    try state.addAssistantDelta(" delta");
    try state.addAssistantDelta(" epsilon");

    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(std.testing.allocator);
    try appendMessageRows(std.testing.allocator, &rows, state.messages.items[0], 6);

    try expectRowsBorrowMessageStorage(rows.items, state.messages.items);
    try std.testing.expectEqual(@as(usize, 6), visibleTranscriptRowCount(rows.items));
}

test "tui progress rows borrow durable progress storage after output coalescing" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const first_output = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"b25l\",\"cap_reached\":false}";
    const second_output = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"dHdv\",\"cap_reached\":false}";
    try state.addProgress("tool_output_delta", first_output);
    try state.addProgress("tool_output_delta", second_output);

    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(std.testing.allocator);
    try appendMessageRows(std.testing.allocator, &rows, state.messages.items[0], 80);

    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expectEqualStrings("stdout: one | two", rows.items[0].text);
    try expectRowsBorrowMessageStorage(rows.items, state.messages.items);
}

test "tui draw transcript leaves screen cells backed by durable message storage" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var screen = try tui.Screen.init(allocator, .{ .rows = 8, .cols = 32, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
        .last_transcript_body_width = 8,
    };
    defer state.deinit();

    try state.add(.assistant, "alpha beta gamma");
    const win = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
        .unicode = &unicode,
    };
    drawTranscript(win, &state);

    try expectScreenTextBorrowMessageStorage(screen, state.messages.items);
}

test "tui assistant wrapping preserves blank and indented lines" {
    const allocator = std.testing.allocator;
    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(allocator);

    var message = Message{
        .role = .assistant,
        .text = try allocator.dupe(u8, "alpha\n\n  beta"),
    };
    defer message.deinit(allocator);

    try appendMessageRows(allocator, &rows, message, 12);

    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    try std.testing.expectEqualStrings("alpha", rows.items[0].text);
    try std.testing.expectEqualStrings("", rows.items[1].text);
    try std.testing.expectEqualStrings("  beta", rows.items[2].text);
    try std.testing.expect(rows.items[3].gap);
}

test "tui streamed assistant deltas preserve row scroll anchor as wrapping grows" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
        .last_transcript_body_width = 6,
    };
    defer state.deinit();

    try state.addAssistantDelta("alpha beta");
    const before_rows = transcriptRowCount(&state, 6);
    try std.testing.expectEqual(@as(usize, 8), before_rows);

    state.scrollUp(1);
    try state.addAssistantDelta(" gamma delta");

    const after_rows = transcriptRowCount(&state, 6);
    try std.testing.expectEqual(@as(usize, 10), after_rows);
    try std.testing.expectEqual(@as(usize, 3), state.scroll_offset);
    try std.testing.expectEqual(@as(usize, 7), visibleEndRow(&state, after_rows));
}

test "tui assistant deltas after progress open a new readable response block" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.1",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addAssistantDelta("I will inspect first.");
    try state.addProgress("tool_started", "{\"schema\":\"var1.tool_started.v1\",\"tool\":\"read_file\",\"tool_call_id\":\"call_1\",\"timestamp_ms\":1}");
    try state.addAssistantDelta("Now I have the file.");

    try std.testing.expectEqual(@as(usize, 3), state.messages.items.len);
    try std.testing.expectEqual(Role.assistant, state.messages.items[0].role);
    try std.testing.expectEqual(Role.progress, state.messages.items[1].role);
    try std.testing.expectEqual(Role.assistant, state.messages.items[2].role);
    try std.testing.expectEqualStrings("I will inspect first.", state.messages.items[0].text);
    try std.testing.expectEqualStrings("Explore", state.messages.items[1].text);
    try std.testing.expectEqualStrings("Now I have the file.", state.messages.items[2].text);
}

test "tui tool request summaries group repeated tools without hiding mixed work" {
    const allocator = std.testing.allocator;

    const grouped = (try formatProgress(allocator, "tool_requested", "tool requested: read_file, shell_exec, read_file, append_file, append_file, shell_exec")) orelse return error.TestUnexpectedNull;
    defer allocator.free(grouped);
    try std.testing.expectEqualStrings("tool: read_file x2, shell_exec x2, append_file x2", grouped);

    const spaced = (try formatProgress(allocator, "tool_requested", "tool requested:  read_file , shell_exec, read_file ")) orelse return error.TestUnexpectedNull;
    defer allocator.free(spaced);
    try std.testing.expectEqualStrings("tool: read_file x2, shell_exec", spaced);
}

test "tui transcript authorship uses styling instead of label rows" {
    try std.testing.expect(Style.eql(styles.user_text, bodyStyle(.user)));
    try std.testing.expect(Style.eql(styles.assistant_text, bodyStyle(.assistant)));
    try std.testing.expect(Style.eql(styles.progress, bodyStyle(.progress)));
    try std.testing.expect(Style.eql(styles.system, bodyStyle(.system)));
    try std.testing.expect(Color.eql(styles.user_text.bg, styles.surface.bg));
    try std.testing.expect(Color.eql(styles.assistant_text.bg, styles.surface.bg));
    try std.testing.expect(!Color.eql(styles.composer.bg, styles.surface.bg));
    try std.testing.expect(!Color.eql(styles.meta_surface.bg, styles.surface.bg));
    try std.testing.expect(!Color.eql(styles.composer.bg, styles.meta_surface.bg));
    try std.testing.expect(Color.eql(styles.meta_label.bg, styles.meta_surface.bg));
    try std.testing.expect(Color.eql(styles.meta_value.bg, styles.meta_surface.bg));
    try std.testing.expectEqualStrings("VANTARI-ONE", basename("E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\"));
    try std.testing.expectEqualStrings("project", basename("/tmp/project/"));
}

test "tui layout removes top chrome and keeps metadata below the lifted composer" {
    const tall = computeLayout(30);
    try std.testing.expectEqual(@as(u16, 27), tall.transcript_height);
    try std.testing.expectEqual(@as(u16, 27), tall.footer_y);
    try std.testing.expectEqual(@as(u16, 3), tall.footer_height);
    try std.testing.expectEqual(@as(u16, 0), tall.editor_y);
    try std.testing.expectEqual(@as(u16, 2), tall.meta_y);

    const tiny = computeLayout(2);
    try std.testing.expectEqual(@as(u16, 0), tiny.transcript_height);
    try std.testing.expectEqual(@as(u16, 0), tiny.footer_y);
    try std.testing.expectEqual(@as(u16, 2), tiny.footer_height);
    try std.testing.expectEqual(@as(u16, 0), tiny.editor_y);
    try std.testing.expectEqual(@as(u16, 1), tiny.meta_y);
}

test "tui footer metadata preserves high-value fields inside narrow terminals" {
    const allocator = std.testing.allocator;

    const wide = try formatFooterMeta(
        allocator,
        "glm-5.1",
        "high",
        "",
        5_000,
        200_000,
        2,
        4,
        false,
        false,
        0,
        96,
    );
    defer allocator.free(wide);
    try std.testing.expectEqualStrings(
        "glm-5.1 · high · ctx 5k / 200k (3%) · 195k left",
        wide,
    );

    const narrow = try formatFooterMeta(
        allocator,
        "glm-5.1",
        "high",
        "",
        5_000,
        200_000,
        2,
        4,
        false,
        false,
        0,
        40,
    );
    defer allocator.free(narrow);
    try std.testing.expect(narrow.len <= 40);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "ctx 5k / 200k (3%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "glm-5.1") != null);
}

test "tui footer metadata exposes only actionable transient state" {
    const allocator = std.testing.allocator;

    const waiting = try formatFooterMeta(
        allocator,
        "glm-5.1",
        "high",
        "",
        5_000,
        200_000,
        0,
        0,
        true,
        false,
        7,
        96,
    );
    defer allocator.free(waiting);
    try std.testing.expect(std.mem.indexOf(u8, waiting, "Esc cancel") == null);
    try std.testing.expect(std.mem.indexOf(u8, waiting, "older +7") != null);

    const cancelling = try formatFooterMeta(
        allocator,
        "glm-5.1",
        "high",
        "",
        5_000,
        200_000,
        0,
        0,
        true,
        true,
        0,
        96,
    );
    defer allocator.free(cancelling);
    try std.testing.expect(std.mem.indexOf(u8, cancelling, "cancelling") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancelling, "Esc cancel") == null);
}

test "tui footer projects context telemetry and live agent cardinality" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "Qwen3.6 35B-A3B",
        .base_url = "http://localhost:1234",
        .auth_provider = "lmstudio",
        .plan = "local",
        .subscription_status = "active",
        .effort = "high",
        .context_window_tokens = 200_000,
        .waiting = true,
    };
    defer state.deinit();

    try std.testing.expect(try state.recordProgressEvent(
        "turn_started",
        "{\"schema\":\"var1.turn_started.v1\",\"window_tokens\":5000}",
        1,
    ));
    try state.upsertActivityProgress("agent-1", "recon - running", .item, .running, "group-1");
    try state.upsertActivityProgress("agent-2", "review - queued", .item, .pending, "group-1");

    const counts = state.agentCounts();
    try std.testing.expectEqual(@as(usize, 1), counts.running);
    try std.testing.expectEqual(@as(usize, 2), counts.total);
    try std.testing.expectEqual(@as(u64, 5_000), state.context_used_tokens.?);

    const footer = try formatFooterMeta(
        allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        state.context_used_tokens,
        state.context_window_tokens,
        counts.running,
        counts.total,
        state.waiting,
        state.cancel_requested,
        state.scroll_offset,
        96,
    );
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Qwen3.6 35B-A3B") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "high") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 5k / 200k (3%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "195k left") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "agents 1/2") != null);
}

test "tui transcript gives dense single-line treatment to runtime rows" {
    try std.testing.expect(isCompactRole(.progress));
    try std.testing.expect(isCompactRole(.system));
    try std.testing.expect(!isCompactRole(.assistant));
    try std.testing.expect(!isCompactRole(.user));

    var progress_message = Message{ .role = .progress, .text = try std.testing.allocator.dupe(u8, "stdout: one | two") };
    defer progress_message.deinit(std.testing.allocator);
    var assistant_message = Message{ .role = .assistant, .text = try std.testing.allocator.dupe(u8, "Readable answer.") };
    defer assistant_message.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), messageRowCount(progress_message.role, progress_message.text, false, 80));
    try std.testing.expectEqual(@as(usize, 2), messageRowCount(assistant_message.role, assistant_message.text, false, 80));
}

test "tui reasoning dock keeps the newest four rows" {
    const allocator = std.testing.allocator;
    var rows = try buildReasoningDockRows(
        allocator,
        "the oldest reasoning words should fall away while the newest reasoning words always stay visible here",
        12,
    );
    defer rows.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), rows.items.len);
    // The newest row should end with "here" — the last word in the input.
    try std.testing.expect(std.mem.indexOf(u8, rows.items[3].text, "here") != null);
}

test "tui reasoning dock leaves one surface row above it without moving the composer" {
    const layout = computeLayoutWithReasoningDock(20, 2);
    try std.testing.expectEqual(@as(u16, 1), layout.reasoning_gap_height);
    try std.testing.expectEqual(layout.transcript_height + layout.reasoning_gap_height, layout.reasoning_y);
    try std.testing.expectEqual(layout.footer_y, layout.reasoning_y + layout.reasoning_height);

    const cramped = computeLayoutWithReasoningDock(4, 2);
    try std.testing.expectEqual(@as(u16, 0), cramped.reasoning_gap_height);
    try std.testing.expectEqual(cramped.footer_y, cramped.reasoning_y + cramped.reasoning_height);
}

test "tui reasoning events project only into the dock while progress stays in transcript" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var screen = try tui.Screen.init(allocator, .{ .rows = 12, .cols = 60, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(allocator);

    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.2",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.startAssistantPlaceholder();
    try std.testing.expect(try state.recordProgressEvent("reasoning_delta", "checking the first seam", 1));
    try std.testing.expect(try state.recordProgressEvent("session_waiting", "child group", 2));
    try std.testing.expect(try state.recordProgressEvent("reasoning_delta", " and now the newest words", 3));

    const win = Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
        .unicode = &unicode,
    };

    var transcript_rows = try buildTranscriptRows(allocator, win, &state);
    defer transcript_rows.deinit(allocator);
    for (transcript_rows.items) |row| {
        try std.testing.expect(std.mem.indexOf(u8, row.text, "checking the first seam") == null);
        try std.testing.expect(std.mem.indexOf(u8, row.text, "newest words") == null);
    }

    var dock_rows = try buildReasoningDockRows(allocator, state.reasoning_buffer.items, 80);
    defer dock_rows.deinit(allocator);
    try std.testing.expect(dock_rows.items.len <= max_reasoning_dock_rows);
    try std.testing.expect(std.mem.indexOf(u8, dock_rows.items[dock_rows.items.len - 1].text, "newest words") != null);

    const layout = computeLayoutWithReasoningDock(20, @intCast(dock_rows.items.len));
    try std.testing.expectEqual(layout.footer_y, layout.reasoning_y + layout.reasoning_height);
    try std.testing.expectEqual(layout.transcript_height + layout.reasoning_gap_height, layout.reasoning_y);
}

test "tui child replay keeps one keyed row per group and task" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.2",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    try state.addProgress("child_group_started", "{\"group_id\":\"group-one\",\"queued\":1,\"terminal\":false}");
    try std.testing.expectEqualStrings("Agents 0/1 - waiting on 1", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityKind.group, state.messages.items[0].activity_kind);
    try std.testing.expectEqual(ActivityState.running, state.messages.items[0].activity_state);
    try state.addProgress("child_admitted", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"queued\"}");
    try std.testing.expectEqualStrings("Recon - queued", state.messages.items[1].text);
    try std.testing.expectEqual(ActivityKind.item, state.messages.items[1].activity_kind);
    try std.testing.expectEqual(ActivityState.pending, state.messages.items[1].activity_state);
    try std.testing.expectEqualStrings("group-one", state.messages.items[1].activity_parent_id.?);
    try state.addProgress("child_started", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\"}");
    try std.testing.expectEqualStrings("Recon - running", state.messages.items[1].text);
    try std.testing.expectEqual(ActivityState.running, state.messages.items[1].activity_state);
    try state.addProgress("child_waiting", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"waiting\"}");
    try std.testing.expectEqualStrings("Recon - waiting", state.messages.items[1].text);
    try state.addProgress("child_finished", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"completed\"}");
    try state.addProgress("child_group_finished", "{\"group_id\":\"group-one\",\"completed\":1,\"terminal\":true}");
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("Agents 1/1", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityState.completed, state.messages.items[0].activity_state);
    try std.testing.expectEqualStrings("Recon", state.messages.items[1].text);
    try std.testing.expectEqual(ActivityState.completed, state.messages.items[1].activity_state);

    try state.addProgress("child_group_recovered", "{\"group_id\":\"group-one\",\"tasks\":1,\"stale_owners_reconciled\":1,\"terminal\":true}");
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("Agents 1/1 - 1 failed, 0 cancelled", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityState.failed, state.messages.items[0].activity_state);
    try std.testing.expect(replayProgressEvent("child_progress"));
    try std.testing.expect(replayProgressEvent("session_waiting"));
    try std.testing.expect(!replayProgressEvent("assistant_delta"));
}

test "tui activity families share nested checkbox grammar" {
    try std.testing.expectEqualStrings("Search", activityTitle("web_search"));
    try std.testing.expectEqualStrings("Explore", activityTitle("read_file"));
    try std.testing.expectEqualStrings("Agents", activityTitle("agents"));
    try std.testing.expectEqualStrings("To-dos", activityTitle("todo_slice"));

    try std.testing.expectEqualStrings("○ ", activityMarker(.pending));
    try std.testing.expectEqualStrings("◉ ", activityMarker(.running));
    try std.testing.expectEqualStrings("✓ ", activityMarker(.completed));
    try std.testing.expectEqualStrings("✗ ", activityMarker(.failed));
    try std.testing.expectEqualStrings("⊘ ", activityMarker(.cancelled));
    try std.testing.expectEqualStrings("├── ", activityConnector(.item, false));
    try std.testing.expectEqualStrings("└── ", activityConnector(.item, true));
    try std.testing.expectEqualStrings("", activityConnector(.group, false));
}
