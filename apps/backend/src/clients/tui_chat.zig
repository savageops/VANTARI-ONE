const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const history = VAR1.core.session_history;
const commands = @import("commands.zig");
const settings_view = @import("settings_view.zig");
const question_view = @import("question_view.zig");
const footer_effects = @import("footer_effects.zig");

const protocol = VAR1.core.protocol_types;
const protocol_events = VAR1.shared.protocol.events;
const shared_types = VAR1.shared.types;
const config_file = VAR1.core.config_file;
const stdio_rpc = VAR1.host.stdio_rpc;
const prompt_modes = VAR1.core.prompts;

const TextInput = tui.widgets.TextInput;
const Window = tui.Window;
const Style = tui.Cell.Style;
const Color = tui.Cell.Color;

const Event = union(enum) {
    key_press: tui.Key,
    mouse: tui.Mouse,
    winsize: tui.Winsize,
    input_error: []const u8,
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

const FooterPool = struct {
    known: bool = false,
    healthy: bool = true,
    max: usize = 0,
    running: usize = 0,
    tickets_assigned: usize = 0,
    tickets_in_progress: usize = 0,
    ticket_ledger_healthy: bool = true,
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
    activity_name: ?[]u8 = null,
    activity_summary: ?[]u8 = null,
    activity_phase: ?[]u8 = null,
    activity_elapsed_ms: i64 = 0,
    activity_kind: ActivityKind = .none,
    activity_state: ActivityState = .pending,
    activity_last: bool = false,
    pending: bool = false,

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        self.freeText(allocator);
        if (self.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
        if (self.activity_parent_id) |parent_id| allocator.free(parent_id);
        if (self.activity_name) |name| allocator.free(name);
        if (self.activity_summary) |summary| allocator.free(summary);
        if (self.activity_phase) |phase| allocator.free(phase);
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
    // Production hydrates this from health_get before the first frame. Keep
    // the constructor fallback at normal so existing read-model fixtures
    // retain their historical projection unless they opt into silent.
    log_level: shared_types.LogLevel = .normal,
    theme: config_file.TuiTheme = .vantari,
    status_bar_position: config_file.StatusBarPosition = .bottom,
    prompt_mode: prompt_modes.PromptMode = .orchestrate,
    footer_effect: footer_effects.Controller = .{},
    context_window_tokens: u64 = 0,
    reserve_output_tokens: u64 = 0,
    full_access_mode: bool = false,
    agent_pool_max: usize = 0,
    agent_pool_queued: usize = 0,
    agent_pool_running: usize = 0,
    agent_pool_idle: usize = 0,
    agent_pool_available: usize = 0,
    agent_pool_healthy: bool = false,
    agent_pool_known: bool = false,
    // Session cost read model accumulated from completed turn_terminal events
    // (measured provider tokens + priced cost; cost stays zero-flag unless a
    // turn reported a priced quantity).
    session_prompt_tokens: u64 = 0,
    session_completion_tokens: u64 = 0,
    session_cached_tokens: u64 = 0,
    session_cost_usd: f64 = 0,
    has_session_cost: bool = false,
    tickets_assigned: usize = 0,
    tickets_in_progress: usize = 0,
    ticket_ledger_healthy: bool = true,
    last_health_refresh_ms: i64 = 0,
    /// Latest context compiler estimate from the typed turn boundary event.
    /// Null is intentional before the first provider turn or after a cold
    /// start with no replayable turn telemetry.
    context_used_tokens: ?u64 = null,
    session_id: ?[]u8 = null,
    status: []const u8 = "READY",
    messages: std.ArrayList(Message) = .{},
    scroll_offset: usize = 0,
    waiting: bool = false,
    cancel_requested: bool = false,
    received_assistant_delta: bool = false,
    pending_assistant_placeholder: bool = false,
    /// Accumulated reasoning trace buffer — all reasoning_delta tokens
    /// are appended here and rendered as a single dimmed block, not
    /// one row per token.
    reasoning_buffer: std.ArrayList(u8) = .{},
    /// Process-local queue position used only to drain stdio notifications.
    /// Durable render identity is `last_event_seq` below.
    last_transport_sequence: u64 = 0,
    /// Exact per-session events.jsonl replay cursor.
    last_event_seq: u64 = 0,
    /// Exact session_started event sequence for the run this TUI observed.
    active_run_seq: u64 = 0,
    last_transcript_body_width: usize = 80,
    history_entries: std.ArrayList([]u8) = .{},
    history_cursor: usize = 0,
    history_draft: ?[]u8 = null,
    /// Buffer model preview text — shown in the reasoning dock when the
    /// heavyweight model is not actively reasoning. Populated by the buffer
    /// model (draft/buffer layer). When null or empty, the dock collapses.
    buffer_preview: ?[]u8 = null,
    /// In-TUI settings overlay state. Null when closed. Initialized by the
    /// registry-backed settings command. When non-null and .open, the draw function renders
    /// the settings overlay instead of the normal transcript+footer.
    settings_state: ?settings_view.SettingsState = null,
    /// One event-backed interactive input controller. The kernel owns the
    /// request lifecycle; this state owns only the active TUI projection.
    input_state: ?question_view.State = null,
    /// Reserved command autocomplete. A leading slash remains accepted for
    /// compatibility, while a single bare command token (for example
    /// `sett`) uses the same registry-backed popup.
    autocomplete_visible: bool = false,
    autocomplete_cursor: usize = 0,
    autocomplete_scroll: usize = 0,
    autocomplete_matches: std.ArrayList(usize) = .{},
    /// Reverse history search mode — activated by Ctrl+R. Filters the global
    /// history by the typed substring and shows the most recent match.
    search_mode: bool = false,
    search_buffer: std.ArrayList(u8) = .{},
    search_result_index: usize = 0,

    fn deinit(self: *ChatState) void {
        if (self.session_id) |value| self.allocator.free(value);
        for (self.messages.items) |message| message.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.reasoning_buffer.deinit(self.allocator);
        for (self.history_entries.items) |entry| self.allocator.free(entry);
        self.history_entries.deinit(self.allocator);
        if (self.history_draft) |draft| self.allocator.free(draft);
        if (self.buffer_preview) |preview| self.allocator.free(preview);
        if (self.settings_state) |*ss| ss.deinit();
        if (self.input_state) |*input_state| input_state.deinit();
        self.autocomplete_matches.deinit(self.allocator);
        self.search_buffer.deinit(self.allocator);
    }

    fn cyclePromptMode(self: *ChatState) void {
        self.prompt_mode = self.prompt_mode.next();
    }

    fn clearAutocomplete(self: *ChatState) void {
        self.autocomplete_visible = false;
        self.autocomplete_cursor = 0;
        self.autocomplete_scroll = 0;
        self.autocomplete_matches.clearRetainingCapacity();
    }

    /// Rebuild the transient command palette from the existing command
    /// metadata. Only the first, single token is reserved; prose and command
    /// arguments remain ordinary model input. A slash is optional for new
    /// input but stays supported for muscle memory and compatibility.
    fn refreshAutocomplete(self: *ChatState, input: *const TextInput) !void {
        self.clearAutocomplete();

        const owned = try input.toOwnedCopy(self.allocator);
        defer self.allocator.free(owned);
        const token = std.mem.trimLeft(u8, owned, " \t");
        if (token.len == 0) return;
        if (std.mem.indexOfAny(u8, token, " \t\r\n") != null) return;

        const slash = token[0] == '/';
        const query = if (slash) token[1..] else token;
        if (!slash and query.len == 0) return;

        // The executable command registry is the source of truth for the
        // palette. Help metadata remains a presentation projection; it must
        // not make a command look selectable when dispatch cannot handle it.
        for (command_registry, 0..) |command, index| {
            if (query.len > command.name.len) continue;
            if (!std.ascii.eqlIgnoreCase(command.name[0..query.len], query)) continue;
            try self.autocomplete_matches.append(self.allocator, index);
        }
        self.autocomplete_visible = self.autocomplete_matches.items.len > 0;
    }

    fn autocompleteHeight(self: *const ChatState) usize {
        if (!self.autocomplete_visible) return 0;
        return @min(@as(usize, 5), self.autocomplete_matches.items.len);
    }

    fn moveAutocompleteCursor(self: *ChatState, direction: i8) void {
        const count = self.autocomplete_matches.items.len;
        if (count == 0) return;

        if (direction < 0) {
            if (self.autocomplete_cursor == 0) {
                self.autocomplete_cursor = count - 1;
            } else {
                self.autocomplete_cursor -= 1;
            }
        } else {
            self.autocomplete_cursor = (self.autocomplete_cursor + 1) % count;
        }

        const visible = self.autocompleteHeight();
        if (visible == 0) return;
        if (self.autocomplete_cursor < self.autocomplete_scroll) {
            self.autocomplete_scroll = self.autocomplete_cursor;
        } else if (self.autocomplete_cursor >= self.autocomplete_scroll + visible) {
            self.autocomplete_scroll = self.autocomplete_cursor - visible + 1;
        }
    }

    fn selectedAutocompleteName(self: *const ChatState) ?[]const u8 {
        if (!self.autocomplete_visible or self.autocomplete_matches.items.len == 0) return null;
        const cursor = @min(self.autocomplete_cursor, self.autocomplete_matches.items.len - 1);
        return command_registry[self.autocomplete_matches.items[cursor]].name;
    }

    fn beginInputRequest(self: *ChatState, message: []const u8) !void {
        var next = try question_view.State.initFromJson(self.allocator, message);
        errdefer next.deinit();
        if (self.input_state) |*active| active.deinit();
        self.input_state = next;
    }

    fn clearInputRequest(self: *ChatState) void {
        if (self.input_state) |*active| active.deinit();
        self.input_state = null;
    }

    fn respondInput(self: *ChatState, cancelled: bool) !void {
        const active = self.input_state orelse return;
        const session_id = self.session_id orelse {
            // A replayed or failed turn can leave a request projection without
            // a live session owner. It is not answerable; keeping the panel
            // would trap the TUI in a dead input state.
            self.clearInputRequest();
            return;
        };
        const request_id = active.request_id;
        const response_json = try active.responseJson(self.allocator, cancelled);
        defer self.allocator.free(response_json);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{}) catch {
            try self.add(.system, "Input response was malformed.");
            return;
        };
        defer parsed.deinit();
        const answers = parsed.value.object.get("answers") orelse return;
        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"session_id\":{f},\"request_id\":{f},\"cancelled\":{s},\"answers\":{f}}}",
            .{
                std.json.fmt(session_id, .{}),
                std.json.fmt(request_id, .{}),
                if (cancelled) "true" else "false",
                std.json.fmt(answers, .{}),
            },
        );
        defer self.allocator.free(params);
        const call = self.client.call(protocol.methods.input_respond, params) catch {
            try self.add(.system, "Input response failed; the question remains active.");
            return;
        };
        defer call.deinit(self.allocator);
        if (call.error_json != null) {
            try self.add(.system, "Input response was rejected; the question remains active.");
            return;
        }
        self.clearInputRequest();
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

    /// Find the current reverse-search match: the Nth entry (from newest)
    /// in history that contains the search buffer as a substring. Returns
    /// null if no match.
    pub fn currentSearchMatch(self: *ChatState) ?[]const u8 {
        if (self.search_buffer.items.len == 0) return null;
        const needle = self.search_buffer.items;
        var match_count: usize = 0;
        // Iterate from newest to oldest (reverse order).
        var i: usize = self.history_entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.history_entries.items[i];
            if (std.mem.indexOf(u8, entry, needle) != null) {
                if (match_count == self.search_result_index) return entry;
                match_count += 1;
            }
        }
        return null;
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
        const list_params = try renderJsonAlloc(self.allocator, .{ .limit = 1 });
        defer self.allocator.free(list_params);
        const list_call = try self.client.call(protocol.methods.session_list, list_params);
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
        self.full_access_mode = parsed_get.value.session.full_access_mode;
        self.status = "READY";

        for (self.messages.items) |message| message.deinit(self.allocator);
        self.messages.clearRetainingCapacity();
        self.last_transport_sequence = 0;
        self.last_event_seq = 0;
        self.active_run_seq = 0;
        self.scroll_offset = 0;
        self.waiting = false;
        self.cancel_requested = false;
        self.received_assistant_delta = false;
        self.pending_assistant_placeholder = false;
        if (self.input_state) |*input_state| input_state.deinit();
        self.input_state = null;
        self.clearReasoningBuffer();

        try self.hydrateTranscript(parsed_get.value.messages);
        for (parsed_get.value.events) |event| {
            // Legacy rows have no replay identity. The current TUI must not
            // render them: sequence-bearing parent events are the sole activity
            // projection source after the versioned event spine landed.
            if (event.seq == 0) continue;
            if (event.seq <= self.last_event_seq) continue;
            if (event.seq != try nextProgressSeq(self.last_event_seq)) return error.EventSequenceGap;
            self.trackRunEvent(event.seq, event.event_type);
            self.last_event_seq = event.seq;
            if (replayProgressEvent(self.log_level, event.event_type)) try self.addProgress(event.event_type, event.message);
        }
        self.jumpToBottom();
    }

    /// TUI health read model / Copy canonical pool and ticket projections into
    /// frame state without admitting work. Why: later footer and Agent Hub views
    /// must not recompute idle or queue semantics. Preserves: old kernels remain
    /// parseable through additive defaults. Evidence: Move 28 telemetry test.
    fn applyHealthTelemetry(self: *ChatState, health: protocol.HealthGetResult) void {
        self.log_level = shared_types.LogLevel.fromString(health.log_level) orelse .silent;
        self.agent_pool_known = true;
        self.agent_pool_healthy = health.agent_pool_healthy;
        self.agent_pool_max = health.agent_pool_max;
        self.agent_pool_queued = health.agent_pool_queued;
        self.agent_pool_running = health.agent_pool_running;
        self.agent_pool_idle = health.agent_pool_idle;
        self.agent_pool_available = health.agent_pool_available;
        self.tickets_assigned = health.tickets_assigned;
        self.tickets_in_progress = health.tickets_in_progress;
        self.ticket_ledger_healthy = health.ticket_ledger_healthy;
    }

    fn refreshTuiPolicy(self: *ChatState) void {
        const policy = config_file.loadTuiPolicy(self.allocator, self.workspace_root) catch return;
        if (policy.theme != self.theme) {
            self.theme = policy.theme;
            applyTheme(policy.theme);
        }
        self.status_bar_position = policy.status_bar_position;
    }

    /// Refresh operator telemetry only from the idle UI loop. Provider
    /// streaming already has its own event path; polling here avoids a second
    /// status bus and keeps health reads bounded to one per half-second.
    fn refreshHealthIfDue(self: *ChatState) !void {
        const now_ms = std.time.milliTimestamp();
        if (self.last_health_refresh_ms > 0 and now_ms - self.last_health_refresh_ms < 500) return;
        self.last_health_refresh_ms = now_ms;

        const health_call = try self.client.call(protocol.methods.health_get, "{}");
        defer health_call.deinit(self.allocator);
        const health_result_json = try expectKernelResult(self.allocator, health_call);
        defer self.allocator.free(health_result_json);
        var parsed_health = try std.json.parseFromSlice(protocol.HealthGetResult, self.allocator, health_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_health.deinit();
        self.applyHealthTelemetry(parsed_health.value);
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
        self.active_run_seq = 0;
        self.received_assistant_delta = false;
        try self.startAssistantPlaceholder();
        input.clearAndFree();
        try draw(vx, writer, self, input);
        defer self.waiting = false;

        const turn = self.executePromptTurn(prompt, vx, tty, loop, writer, input) catch |err| {
            self.status = "RPC_ERROR";
            self.clearInputRequest();
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
            self.clearInputRequest();
            self.removeAssistantPlaceholder();
            const text = try std.fmt.allocPrint(self.allocator, "Session {s} failed: {s}", .{ turn.session_id, reason });
            defer self.allocator.free(text);
            try self.add(.system, text);
            return;
        }

        // A successful RPC can still race the final event notification. The
        // returned session projection is the terminal boundary, so never leave
        // an answer panel owned by a completed turn.
        self.clearInputRequest();
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
            self.full_access_mode = parsed_create.value.session.full_access_mode;
            break :blk owned;
        };

        const send_params = if (existing_session_id != null)
            try renderJsonAlloc(self.allocator, .{
                .session_id = session_id,
                .prompt = prompt,
                .enable_agent_tools = true,
                .prompt_mode = self.prompt_mode.label(),
            })
        else
            try renderJsonAlloc(self.allocator, .{
                .session_id = session_id,
                .enable_agent_tools = true,
                .prompt_mode = self.prompt_mode.label(),
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
        if (send_job.err) |err| {
            if (redraw_pending) try draw(vx, writer, self, input);
            return err;
        }
        // Verify the transport tail once at the durable turn boundary. This
        // recovers even when every active-session notification was evicted and
        // no later frame remained to expose a sequence gap.
        if (try self.syncProgressAfterSeq(session_id)) redraw_pending = true;
        if (redraw_pending) try draw(vx, writer, self, input);

        const send_call = send_job.result orelse return error.InvalidRpcResponse;
        const send_result_json = try expectKernelResult(self.allocator, send_call);
        defer self.allocator.free(send_result_json);

        var parsed_send = try std.json.parseFromSlice(protocol.SessionSendResult, self.allocator, send_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_send.deinit();
        self.full_access_mode = parsed_send.value.session.full_access_mode;

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
            const notification = try self.client.waitForNotificationAfter(self.last_transport_sequence, wait_ms) orelse return changed;
            const transport_sequence = notification.sequence;
            const notification_changed = self.recordProgressNotification(session_id, notification) catch |err| {
                notification.deinit(self.allocator);
                return err;
            };
            notification.deinit(self.allocator);
            self.last_transport_sequence = transport_sequence;
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
        if (parsed.value.seq == 0 or parsed.value.seq <= self.last_event_seq) return false;

        var changed = false;
        if (parsed.value.seq != try nextProgressSeq(self.last_event_seq)) {
            changed = try self.syncProgressAfterSeq(session_id);
        }
        if (parsed.value.seq <= self.last_event_seq) return changed;
        const notification_changed = try self.recordProgressEvent(parsed.value.seq, parsed.value.event_type, parsed.value.message);
        return changed or notification_changed;
    }

    /// Recover a dropped or physically reordered live notification from the
    /// existing durable tail. This is demand-driven: the normal contiguous path
    /// performs no RPC and no disk replay.
    fn syncProgressAfterSeq(self: *ChatState, session_id: []const u8) !bool {
        const params = try renderJsonAlloc(self.allocator, .{
            .session_id = session_id,
            .after_seq = self.last_event_seq,
            .events_only = true,
        });
        defer self.allocator.free(params);

        const get_call = try self.client.call(protocol.methods.session_get, params);
        defer get_call.deinit(self.allocator);
        const get_result_json = try expectKernelResult(self.allocator, get_call);
        defer self.allocator.free(get_result_json);

        var parsed = try std.json.parseFromSlice(protocol.SessionGetResult, self.allocator, get_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        self.full_access_mode = parsed.value.session.full_access_mode;
        return self.recordProgressEvents(parsed.value.events);
    }

    fn recordProgressEvents(self: *ChatState, events: []const VAR1.shared.types.SessionEvent) !bool {
        var changed = false;
        for (events) |event| {
            if (event.seq == 0 or event.seq <= self.last_event_seq) continue;
            const event_changed = try self.recordProgressEvent(event.seq, event.event_type, event.message);
            changed = changed or event_changed;
        }
        return changed;
    }

    fn recordProgressEvent(self: *ChatState, seq: u64, event_type: []const u8, message: []const u8) !bool {
        if (seq == 0 or seq <= self.last_event_seq) return false;
        if (seq != try nextProgressSeq(self.last_event_seq)) return error.EventSequenceGap;

        const changed = try self.applyProgressEvent(event_type, message);
        self.trackRunEvent(seq, event_type);
        self.last_event_seq = seq;
        return changed;
    }

    fn trackRunEvent(self: *ChatState, seq: u64, event_type: []const u8) void {
        if (std.mem.eql(u8, event_type, "session_started")) {
            self.active_run_seq = seq;
            return;
        }
        if (std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type) or
            std.mem.eql(u8, event_type, "turn_finished") or
            std.mem.eql(u8, event_type, "session_cancelled") or
            std.mem.eql(u8, event_type, "session_failed"))
        {
            self.active_run_seq = 0;
            self.cancel_requested = false;
        }
    }

    fn applyProgressEvent(self: *ChatState, event_type: []const u8, message: []const u8) !bool {
        if (std.mem.eql(u8, event_type, "input_requested")) {
            // Model-generated question payloads are untrusted at this client
            // boundary. A malformed request must not unwind the event loop and
            // crash the TUI; cancel the waiting run so the broker cannot remain
            // blocked behind an unrenderable question.
            self.beginInputRequest(message) catch {
                self.clearInputRequest();
                self.add(.system, "The agent sent an invalid question; the waiting turn was cancelled.") catch {};
                if (self.session_id) |session_id| self.cancelInvalidInputRun(session_id);
            };
            return true;
        }
        if (std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type) or
            std.mem.eql(u8, event_type, "turn_finished") or
            std.mem.eql(u8, event_type, "session_cancelled") or
            std.mem.eql(u8, event_type, "session_failed"))
        {
            // A terminal replay event is the durable cleanup boundary for an
            // unanswered or already-resolved request. This prevents a cold
            // TUI resume from resurrecting a stale question panel.
            self.clearInputRequest();
        }
        const recorded_telemetry = try self.recordTurnTelemetry(event_type, message);
        if (recorded_telemetry and self.log_level != .full and
            !std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type)) return true;
        if (std.mem.eql(u8, event_type, "assistant_delta")) {
            try self.addAssistantDelta(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "reasoning_delta")) {
            if (self.log_level == .silent) {
                self.clearReasoningBuffer();
                return false;
            }
            try self.addReasoningDelta(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "buffer_preview")) {
            if (self.log_level == .silent) return false;
            try self.setBufferPreview(message);
            return true;
        }
        if (std.mem.eql(u8, event_type, "user_message_queued")) return true;
        if (std.mem.eql(u8, event_type, "user_message_injected")) return true;
        if (!shouldRenderProgressEvent(self.log_level, event_type)) return false;

        try self.addProgress(event_type, message);
        return true;
    }

    fn recordTurnTelemetry(self: *ChatState, event_type: []const u8, message: []const u8) !bool {
        if (!std.mem.eql(u8, event_type, "turn_started") and
            !std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type) and
            !std.mem.eql(u8, event_type, "turn_finished")) return false;

        const TurnTelemetry = struct {
            window_tokens: u64 = 0,
            prompt_tokens: u64 = 0,
            completion_tokens: u64 = 0,
            cached_tokens: u64 = 0,
            cost_total_usd: ?f64 = null,
            outcome: []const u8 = "completed",
        };
        var parsed = std.json.parseFromSlice(TurnTelemetry, self.allocator, message, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        if (parsed.value.window_tokens > 0 or std.mem.eql(u8, event_type, "turn_started")) {
            self.context_used_tokens = parsed.value.window_tokens;
        }
        // Current completed terminal rows and read-only legacy turn_finished
        // rows carry measured provider tokens and priced cost.
        if (std.mem.eql(u8, event_type, "turn_finished") or
            (std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type) and
                std.mem.eql(u8, parsed.value.outcome, "completed")))
        {
            self.session_prompt_tokens += parsed.value.prompt_tokens;
            self.session_completion_tokens += parsed.value.completion_tokens;
            self.session_cached_tokens += parsed.value.cached_tokens;
            if (parsed.value.cost_total_usd) |cost| {
                self.session_cost_usd += cost;
                self.has_session_cost = true;
            }
        }
        return true;
    }

    fn addProgress(self: *ChatState, event_type: []const u8, message: []const u8) !void {
        if (!shouldRenderProgressEvent(self.log_level, event_type)) return;
        if (std.mem.startsWith(u8, event_type, "child_")) {
            try self.upsertChildProgress(event_type, message);
            return;
        }
        if ((std.mem.eql(u8, event_type, "tool_requested") or std.mem.eql(u8, event_type, "tool_completed")) and
            self.log_level != .full) return;
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
                try std.fmt.allocPrint(self.allocator, "Agents {d}/{d}", .{ finished, total });
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
            elapsed_ms: i64 = 0,
        };
        var parsed = std.json.parseFromSlice(ChildEvent, self.allocator, message, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        if (parsed.value.group_id.len == 0 or parsed.value.task_id.len == 0) return;
        const phase: ?[]const u8 = if (parsed.value.phase) |value|
            value
        else if (std.mem.eql(u8, event_type, "child_waiting"))
            "waiting"
        else
            null;
        const state: ActivityState = if (std.mem.eql(u8, event_type, "child_waiting"))
            .running
        else
            activityStateFromLabel(parsed.value.status);
        const key = try std.fmt.allocPrint(self.allocator, "agent:{s}:{s}", .{ parsed.value.group_id, parsed.value.task_id });
        defer self.allocator.free(key);

        // The child row is an agent summary surface. Tool lifecycle phases
        // remain available in the typed event spine, but they do not replace
        // the agent's own turn summary in the visible tree.
        const summary = if (phase != null and
            (std.mem.eql(u8, phase.?, "assistant_response") or std.mem.eql(u8, phase.?, "summary")) and
            parsed.value.detail != null)
            parsed.value.detail
        else if (std.mem.eql(u8, event_type, "child_finished") and parsed.value.detail != null)
            parsed.value.detail
        else
            null;
        if (try self.updateChildActivity(key, parsed.value.name, state, summary)) return;

        var compact_summary: ?[]u8 = null;
        defer if (compact_summary) |value| self.allocator.free(value);
        if (summary) |value| compact_summary = try compactAgentSummary(self.allocator, value);
        const text = try formatAgentActivitySummary(
            self.allocator,
            parsed.value.name,
            state,
            compact_summary,
            self.last_transcript_body_width,
        );
        defer self.allocator.free(text);
        try self.upsertActivityProgress(key, text, .item, state, parsed.value.group_id);
        try self.setActivityMetadata(key, parsed.value.name, compact_summary, phase, parsed.value.elapsed_ms);
    }

    fn updateChildActivity(
        self: *ChatState,
        activity_id: []const u8,
        name: []const u8,
        state: ActivityState,
        summary: ?[]const u8,
    ) !bool {
        for (self.messages.items) |*message| {
            if (message.role != .progress) continue;
            const existing = message.tool_call_id orelse continue;
            if (!std.mem.eql(u8, existing, activity_id)) continue;

            var compact_summary: ?[]u8 = null;
            defer if (compact_summary) |value| self.allocator.free(value);
            if (summary) |value| compact_summary = try compactAgentSummary(self.allocator, value);
            const display_summary = compact_summary orelse message.activity_summary;
            const replacement = try formatAgentActivitySummary(
                self.allocator,
                name,
                state,
                display_summary,
                self.last_transcript_body_width,
            );
            errdefer self.allocator.free(replacement);
            try self.replaceActivityName(message, name);
            if (compact_summary) |value| try self.replaceActivitySummary(message, value);
            message.replaceTextOwned(self.allocator, replacement);
            message.activity_state = state;
            return true;
        }
        return false;
    }

    fn setActivityMetadata(
        self: *ChatState,
        activity_id: []const u8,
        name: []const u8,
        summary: ?[]const u8,
        phase: ?[]const u8,
        elapsed_ms: i64,
    ) !void {
        for (self.messages.items) |*message| {
            if (message.role != .progress) continue;
            const existing = message.tool_call_id orelse continue;
            if (!std.mem.eql(u8, existing, activity_id)) continue;
            try self.replaceActivityName(message, name);
            if (summary) |value| try self.replaceActivitySummary(message, value);
            if (phase) |value| try self.replaceActivityPhase(message, value);
            if (elapsed_ms > 0) message.activity_elapsed_ms = elapsed_ms;
            return;
        }
    }

    fn replaceActivitySummary(self: *ChatState, message: *Message, summary: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, summary);
        if (message.activity_summary) |existing| self.allocator.free(existing);
        message.activity_summary = replacement;
    }

    fn replaceActivityName(self: *ChatState, message: *Message, name: []const u8) !void {
        if (name.len == 0) return;
        const replacement = try self.allocator.dupe(u8, name);
        if (message.activity_name) |existing| self.allocator.free(existing);
        message.activity_name = replacement;
    }

    fn replaceActivityPhase(self: *ChatState, message: *Message, phase: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, phase);
        if (message.activity_phase) |existing| self.allocator.free(existing);
        message.activity_phase = replacement;
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

    fn reflowActivityRows(self: *ChatState, body_width: usize) !void {
        if (body_width == self.last_transcript_body_width) return;

        for (self.messages.items) |*message| {
            if (message.role != .progress) continue;
            const name = message.activity_name orelse continue;
            const replacement = try formatAgentActivitySummary(
                self.allocator,
                name,
                message.activity_state,
                message.activity_summary,
                body_width,
            );
            message.replaceTextOwned(self.allocator, replacement);
        }
        self.last_transcript_body_width = body_width;
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
                    if (self.input_state != null) {
                        const action = try self.input_state.?.handleKey(key, input);
                        switch (action) {
                            .submit => try self.respondInput(false),
                            .cancel => try self.respondInput(true),
                            .consumed => {},
                        }
                        continue;
                    }
                    if (key.matches('c', .{ .ctrl = true })) {
                        try self.requestCancel(session_id);
                        continue;
                    }
                    if (key.matches(tui.Key.escape, .{})) {
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
                            if (std.mem.eql(u8, text, "/cancel")) {
                                try self.requestCancel(session_id);
                            } else {
                                try self.queueMessage(session_id, text);
                            }
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
        if (self.active_run_seq == 0) {
            _ = self.syncProgressAfterSeq(session_id) catch false;
        }
        if (self.active_run_seq == 0) {
            try self.add(.system, "No active run to cancel.");
            return;
        }

        const params = try renderCancelParams(self.allocator, session_id, self.active_run_seq);
        defer self.allocator.free(params);
        const call = try self.client.call(protocol.methods.session_cancel, params);
        defer call.deinit(self.allocator);
        const result_json = try expectKernelResult(self.allocator, call);
        defer self.allocator.free(result_json);
        var parsed = try std.json.parseFromSlice(protocol.SessionCancelResult, self.allocator, result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        if (!parsed.value.cancellation_requested) {
            if (std.mem.eql(u8, parsed.value.outcome, "stale_run")) {
                try self.add(.system, "Cancel ignored: the active run changed.");
            } else {
                try self.add(.system, "No active run was cancelled.");
            }
            return;
        }

        self.cancel_requested = true;
        self.status = "CANCELLING";
        try self.add(.progress, "cancelling");
    }

    /// Cancel a run while applying an input_requested event without re-entering
    /// the progress replay path. The normal cancel routine performs a replay
    /// repair when its run cursor is cold; doing that from event application
    /// creates a recursive error-set dependency and can deadlock the broker.
    fn cancelInvalidInputRun(self: *ChatState, session_id: []const u8) void {
        if (self.active_run_seq == 0) return;
        const params = renderCancelParams(self.allocator, session_id, self.active_run_seq) catch return;
        defer self.allocator.free(params);
        var call = self.client.call(protocol.methods.session_cancel, params) catch return;
        call.deinit(self.allocator);
        self.cancel_requested = true;
        self.status = "CANCELLING";
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
    const status_text = try commands.renderStatus(state.allocator, state.workspace_root, state.model, state.session_id, state.effort, .{
        .prompt_tokens = state.session_prompt_tokens,
        .completion_tokens = state.session_completion_tokens,
        .cached_tokens = state.session_cached_tokens,
        .cost_total_usd = if (state.has_session_cost) state.session_cost_usd else null,
    });
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
    if (!state.waiting) {
        try state.add(.system, "No active run to cancel.");
        return .handled;
    }
    const session_id = state.session_id orelse {
        try state.add(.system, "No active session to cancel.");
        return .handled;
    };
    try state.requestCancel(session_id);
    return .handled;
}

fn cmdSettings(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    // Open the settings overlay. Initialize state and load the first section.
    if (state.settings_state == null) {
        state.settings_state = settings_view.SettingsState.init(state.allocator, state.workspace_root);
    }
    state.settings_state.?.open = true;
    state.settings_state.?.loadSection() catch {
        // Keep the overlay open and make allocation/parse failures visible in
        // its own status row. A settings command must never fall through as a
        // model prompt merely because a persisted value could not be read.
        state.settings_state.?.setStatusMessage("Settings loaded with defaults; persisted values were unavailable.") catch {};
    };
    return .handled;
}

fn reportCommandFailure(state: *ChatState, err: anyerror) void {
    const message = std.fmt.allocPrint(state.allocator, "Command failed: {s}", .{@errorName(err)}) catch return;
    defer state.allocator.free(message);
    state.add(.system, message) catch {};
}

/// One-shot model switch. Calls config/set to write runtime.openai_model.
fn cmdModel(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    if (args.len == 0) {
        // Show current model.
        const msg = try std.fmt.allocPrint(allocator, "Current model: {s}. Use /model <name> to switch.", .{state.model});
        defer allocator.free(msg);
        try state.add(.system, msg);
        return .handled;
    }
    const params = try std.fmt.allocPrint(allocator, "{{\"section\":\"runtime\",\"key\":\"openai_model\",\"value\":\"{s}\"}}", .{args});
    defer allocator.free(params);
    const call = state.client.call(protocol.methods.config_set, params) catch {
        try state.add(.system, "Error: config/set RPC failed");
        return .handled;
    };
    defer call.deinit(allocator);
    const msg = try std.fmt.allocPrint(allocator, "Model set to {s}. Applies on next turn.", .{args});
    defer allocator.free(msg);
    try state.add(.system, msg);
    return .handled;
}

/// One-shot effort switch. Validates against allowed levels.
fn cmdEffort(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    const valid_levels = [_][]const u8{ "low", "medium", "high", "max" };
    if (args.len == 0) {
        const msg = try std.fmt.allocPrint(allocator, "Current effort: {s}. Levels: low, medium, high, max.", .{state.effort});
        defer allocator.free(msg);
        try state.add(.system, msg);
        return .handled;
    }
    var valid = false;
    for (valid_levels) |level| {
        if (std.mem.eql(u8, args, level)) {
            valid = true;
            break;
        }
    }
    if (!valid) {
        try state.add(.system, "Invalid effort. Levels: low, medium, high, max.");
        return .handled;
    }
    const params = try std.fmt.allocPrint(allocator, "{{\"section\":\"runtime\",\"key\":\"effort\",\"value\":\"{s}\"}}", .{args});
    defer allocator.free(params);
    const call = state.client.call(protocol.methods.config_set, params) catch {
        try state.add(.system, "Error: config/set RPC failed");
        return .handled;
    };
    defer call.deinit(allocator);
    const msg = try std.fmt.allocPrint(allocator, "Effort set to {s}. Applies on next turn.", .{args});
    defer allocator.free(msg);
    try state.add(.system, msg);
    return .handled;
}

/// One-shot persona edit. Sets prompts.persona inline.
fn cmdPersona(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    if (args.len == 0) {
        // Show current persona by reading config.
        var parsed = VAR1.core.config_file.readValidatedDocument(allocator, state.workspace_root) catch {
            try state.add(.system, "Unable to read config.");
            return .handled;
        };
        defer parsed.deinit();
        const prompts = parsed.value.object.get("prompts") orelse {
            try state.add(.system, "No prompts section in config.");
            return .handled;
        };
        const persona = prompts.object.get("persona");
        if (persona) |p| {
            if (p == .string) {
                const msg = try std.fmt.allocPrint(allocator, "Current persona: {s}", .{p.string});
                defer allocator.free(msg);
                try state.add(.system, msg);
            }
        } else {
            try state.add(.system, "Persona is not set (null). Use /persona <text> to set.");
        }
        return .handled;
    }
    if (std.mem.eql(u8, args, "--clear")) {
        const params = try std.fmt.allocPrint(allocator, "{{\"section\":\"prompts\",\"key\":\"persona\",\"value\":null}}", .{});
        defer allocator.free(params);
        const call = state.client.call(protocol.methods.config_set, params) catch {
            try state.add(.system, "Error: config/set RPC failed");
            return .handled;
        };
        defer call.deinit(allocator);
        try state.add(.system, "Persona cleared (reverted to compiled default).");
        return .handled;
    }
    // Escape the args for JSON string.
    const escaped = try escapeForJson(allocator, args);
    defer allocator.free(escaped);
    const params = try std.fmt.allocPrint(allocator, "{{\"section\":\"prompts\",\"key\":\"persona\",\"value\":\"{s}\"}}", .{escaped});
    defer allocator.free(params);
    const call = state.client.call(protocol.methods.config_set, params) catch {
        try state.add(.system, "Error: config/set RPC failed");
        return .handled;
    };
    defer call.deinit(allocator);
    const msg = try std.fmt.allocPrint(allocator, "Persona updated. Applies on next turn.", .{});
    defer allocator.free(msg);
    try state.add(.system, msg);
    return .handled;
}

/// List specialist agent personas from config.
fn cmdAgents(state: *ChatState, _: []const u8) anyerror!commands.CommandResult {
    const allocator = state.allocator;
    var parsed = VAR1.core.config_file.readValidatedDocument(allocator, state.workspace_root) catch {
        try state.add(.system, "Unable to read config.");
        return .handled;
    };
    defer parsed.deinit();
    const agents_section = parsed.value.object.get("agents") orelse {
        try state.add(.system, "No agents section in config.");
        return .handled;
    };
    const defs = agents_section.object.get("definitions") orelse {
        try state.add(.system, "No agent definitions in config.");
        return .handled;
    };
    if (defs != .object) {
        try state.add(.system, "Agent definitions are not an object.");
        return .handled;
    }
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.writer().writeAll("Specialist Agents:\n");
    var iter = defs.object.iterator();
    while (iter.next()) |entry| {
        const id = entry.key_ptr.*;
        const agent = entry.value_ptr.*;
        const enabled = if (agent == .object) blk: {
            const e = agent.object.get("enabled") orelse break :blk true;
            if (e == .bool) break :blk e.bool;
            break :blk true;
        } else true;
        const role = if (agent == .object) blk: {
            const r = agent.object.get("route_role") orelse break :blk "general";
            if (r == .string) break :blk r.string;
            break :blk "general";
        } else "general";
        const status_str = if (enabled) "enabled" else "disabled";
        try output.writer().print("  {s: <16} [{s}] role={s}\n", .{ id, status_str, role });
    }
    try output.writer().writeAll("\nUse settings to edit agent definitions. The /settings alias remains compatible. Use configure_agent for programmatic mutation.");
    try state.add(.system, output.items);
    return .handled;
}

/// Escape a string for embedding in a JSON string literal value.
fn escapeForJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    for (text) |char| {
        switch (char) {
            '"' => try output.appendSlice("\\\""),
            '\\' => try output.appendSlice("\\\\"),
            '\n' => try output.appendSlice("\\n"),
            '\r' => try output.appendSlice("\\r"),
            '\t' => try output.appendSlice("\\t"),
            else => try output.append(char),
        }
    }
    return output.toOwnedSlice();
}

fn cmdStub(state: *ChatState, args: []const u8) anyerror!commands.CommandResult {
    _ = args;
    try state.add(.system, "This command is not yet available. Use settings to configure.");
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
    // Settings-dependent one-shot commands:
    .{ .name = "settings", .description = "Open settings panel.", .category = .config, .execute = cmdSettings },
    .{ .name = "model", .description = "Switch model.", .category = .model, .execute = cmdModel },
    .{ .name = "effort", .description = "Set effort: low/medium/high/max.", .category = .model, .execute = cmdEffort },
    .{ .name = "persona", .description = "Edit persona inline.", .category = .config, .execute = cmdPersona },
    .{ .name = "agents", .description = "List specialist agents.", .category = .agent, .execute = cmdAgents },
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
        .log_level = shared_types.LogLevel.fromString(parsed_health.value.log_level) orelse .silent,
        .context_window_tokens = parsed_health.value.context_window_tokens,
        .reserve_output_tokens = parsed_health.value.reserve_output_tokens,
        .agent_pool_max = parsed_health.value.agent_pool_max,
        .agent_pool_queued = parsed_health.value.agent_pool_queued,
        .agent_pool_running = parsed_health.value.agent_pool_running,
        .agent_pool_idle = parsed_health.value.agent_pool_idle,
        .agent_pool_available = parsed_health.value.agent_pool_available,
        .agent_pool_healthy = parsed_health.value.agent_pool_healthy,
        .agent_pool_known = true,
        .tickets_assigned = parsed_health.value.tickets_assigned,
        .tickets_in_progress = parsed_health.value.tickets_in_progress,
        .ticket_ledger_healthy = parsed_health.value.ticket_ledger_healthy,
    };
    defer state.deinit();
    state.refreshTuiPolicy();

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
        state.refreshHealthIfDue() catch {};
        try draw(&vx, writer, &state, &input);

        const settings_open = if (state.settings_state) |settings| settings.open else false;
        const footer_animation_visible = state.footer_effect.selected_effect != .none and
            state.input_state == null and
            !settings_open;
        const event = if (!footer_animation_visible)
            loop.nextEvent()
        else blk: {
            while (true) {
                if (loop.tryEvent()) |queued_event| break :blk queued_event;

                const now_ms = std.time.milliTimestamp();
                const mode_label = state.prompt_mode.label();
                if (state.footer_effect.needsRender(mode_label, now_ms)) {
                    try draw(&vx, writer, &state, &input);
                }

                const wait_ms = state.footer_effect.nextWaitMs(mode_label, now_ms);
                if (wait_ms > 0) {
                    std.Thread.sleep(@as(u64, @intCast(wait_ms)) * std.time.ns_per_ms);
                }
            }
        };
        switch (event) {
            .key_press => |key| {
                // Settings overlay key routing — when the panel is open, all keys
                // go to the settings handler except Ctrl-C (force exit).
                if (state.settings_state) |*ss| {
                    if (ss.open) {
                        if (key.matches('c', .{ .ctrl = true })) break;
                        const consumed = ss.handleKey(key, state.client) catch false;
                        if (ss.takeConfigChanged()) state.refreshTuiPolicy();
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

                if (state.input_state != null) {
                    const action = try state.input_state.?.handleKey(key, &input);
                    switch (action) {
                        .submit => try state.respondInput(false),
                        .cancel => try state.respondInput(true),
                        .consumed => {},
                    }
                    continue;
                }

                if (key.matches('c', .{ .ctrl = true })) break;

                // Shift+Tab cycles only the session's prompt lens. The next
                // session/send carries the selected label to the kernel; no
                // executor or capability branch is involved.
                if (key.matches(tui.Key.tab, .{ .shift = true })) {
                    state.cyclePromptMode();
                    continue;
                }

                // The palette owns navigation while it is visible. Enter
                // activates the highlighted command; Tab accepts its spelling
                // into the composer for a second look before submission.
                if (state.autocomplete_visible) {
                    if (key.matches(tui.Key.escape, .{})) {
                        state.clearAutocomplete();
                        continue;
                    }
                    if (key.matches(tui.Key.up, .{})) {
                        state.moveAutocompleteCursor(-1);
                        continue;
                    }
                    if (key.matches(tui.Key.down, .{})) {
                        state.moveAutocompleteCursor(1);
                        continue;
                    }
                    if (key.matches(tui.Key.tab, .{})) {
                        if (state.selectedAutocompleteName()) |name| {
                            input.clearAndFree();
                            input.insertSliceAtCursor(name) catch {};
                            state.refreshAutocomplete(&input) catch state.clearAutocomplete();
                        }
                        continue;
                    }
                    if (key.matches(tui.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                        if (state.selectedAutocompleteName()) |name| {
                            const result = commands.dispatchBare(ChatState, &state, &command_registry, name) catch |err| blk: {
                                reportCommandFailure(&state, err);
                                break :blk .handled;
                            };
                            state.clearAutocomplete();
                            switch (result) {
                                .exit => break,
                                .handled => {
                                    input.clearAndFree();
                                    continue;
                                },
                                .not_a_command => {},
                            }
                        }
                    }
                }

                // Ctrl+R — enter/continue reverse history search.
                if (key.matches('r', .{ .ctrl = true })) {
                    if (!state.search_mode) {
                        state.search_mode = true;
                        state.search_buffer.clearRetainingCapacity();
                        state.search_result_index = 0;
                    } else {
                        // Cycle to older matches.
                        state.search_result_index += 1;
                    }
                    continue;
                }

                // Reverse search mode key routing.
                if (state.search_mode) {
                    if (key.matches(tui.Key.escape, .{})) {
                        state.search_mode = false;
                        state.search_buffer.clearRetainingCapacity();
                        state.search_result_index = 0;
                        continue;
                    }
                    if (key.matches(tui.Key.enter, .{})) {
                        // Exit search mode — the match is shown in the search bar.
                        // The operator can copy it or retype. This avoids TextInput
                        // API complexity; the match text is visible in the last
                        // search bar render.
                        state.search_mode = false;
                        state.search_buffer.clearRetainingCapacity();
                        state.search_result_index = 0;
                        continue;
                    }
                    if (key.matches(tui.Key.backspace, .{})) {
                        if (state.search_buffer.items.len > 0) {
                            _ = state.search_buffer.pop();
                            state.search_result_index = 0;
                        }
                        continue;
                    }
                    // Printable chars go to the search buffer.
                    const ch = keyToPrintable(key);
                    if (ch) |c| {
                        state.search_buffer.append(allocator, c) catch {};
                        state.search_result_index = 0;
                    }
                    continue;
                }

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
                    state.refreshAutocomplete(&input) catch state.clearAutocomplete();
                    continue;
                }
                if (state.scroll_offset == 0 and key.matches(tui.Key.down, .{})) {
                    try state.historyNavigateDown(&input);
                    state.refreshAutocomplete(&input) catch state.clearAutocomplete();
                    continue;
                }
                if (key.matches(tui.Key.enter, .{}) or key.matches('j', .{ .ctrl = true })) {
                    state.clearAutocomplete();
                    const owned_prompt = try input.toOwnedSlice();
                    defer allocator.free(owned_prompt);
                    const prompt = std.mem.trim(u8, owned_prompt, " \t\r\n");
                    // Slash command dispatch — intercept /-prefixed input before
                    // submitting to the model.
                    const cmd_result = commands.dispatch(ChatState, &state, &command_registry, prompt) catch |err| blk: {
                        reportCommandFailure(&state, err);
                        break :blk .handled;
                    };
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
                state.refreshAutocomplete(&input) catch state.clearAutocomplete();
            },
            .mouse => |mouse| {
                if (applyMouseScroll(&state, mouse)) continue;
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.anyWriter(), ws);
            },
            .input_error => |err_name| {
                const message = std.fmt.allocPrint(allocator, "Terminal input stopped: {s}", .{err_name}) catch null;
                if (message) |value| {
                    defer allocator.free(value);
                    state.add(.system, value) catch {};
                }
                draw(&vx, writer, &state, &input) catch {};
                break;
            },
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
        error.OwnerStartFailed => "TUI startup failed: the execution owner for this workspace exited during startup. The workspace may not be configured for provider execution (check auth and config), or another vantari process may hold the owner lease.",
        error.OwnerStartTimeout => "TUI startup timed out waiting for the execution owner for this workspace. The workspace may not be configured for provider execution, or the owner is not becoming healthy.",
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
    const footer_frame = state.footer_effect.markRendered(
        state.prompt_mode.label(),
        std.time.milliTimestamp(),
    );

    // Settings overlay — when open, render full-screen instead of normal layout.
    if (state.settings_state) |*ss| {
        if (ss.open) {
            settings_view.drawSettings(root, ss);
            // Settings paints the same Vaxis frame as the chat view. It must
            // go through the normal render boundary or the operator sees the
            // old frame and the panel appears frozen after the command.
            try vx.render(writer);
            try writer.flush();
            return;
        }
    }

    // Vaxis retains printed text until this frame reaches `vx.render`.
    // Interactive question rows use the same boundary, so give their bounded
    // formatting one frame-owned arena instead of borrowing helper-stack or
    // immediately-freed buffers.
    var frame_arena = std.heap.ArenaAllocator.init(state.allocator);
    defer frame_arena.deinit();
    const frame_allocator = frame_arena.allocator();

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
    // Vaxis screen cells borrow printed text until vx.render completes.
    // Keep the frame-owned footer backing bytes alive through that call.
    var footer_meta_owned: ?[]u8 = null;
    defer if (footer_meta_owned) |value| state.allocator.free(value);
    const top_status_height: u16 = if (state.status_bar_position == .top) @min(@as(u16, 1), root.height) else 0;
    const base_footer_height: u16 = if (state.status_bar_position == .top)
        @min(@as(u16, 1), root.height -| top_status_height)
    else
        @min(@as(u16, 3), root.height -| top_status_height);
    const available_autocomplete_height = root.height -| top_status_height -| base_footer_height;
    const autocomplete_height: u16 = if (state.input_state == null)
        @intCast(@min(state.autocompleteHeight(), @as(usize, available_autocomplete_height)))
    else
        0;
    const question_footer_height = if (state.input_state) |*active|
        active.panelHeight(root.height -| top_status_height)
    else
        base_footer_height +| autocomplete_height;
    var layout = computeLayoutForPosition(
        root.height,
        @intCast(reasoning_rows.items.len),
        question_footer_height,
        state.status_bar_position,
    );
    if (state.input_state == null) {
        layout.editor_y = @min(autocomplete_height, layout.footer_height -| 1);
        layout.meta_y = @min(layout.footer_height -| 1, layout.editor_y +| 2);
    }

    const transcript = root.child(.{
        .x_off = 0,
        .y_off = @intCast(layout.transcript_y),
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
    if (state.input_state) |*active| {
        active.draw(
            input_win,
            input,
            .{
                .panel = styles.composer,
                .title = styles.assistant,
                .prompt = styles.text,
                .option = styles.user_text,
                .selected = styles.assistant,
                .hint = styles.meta_value,
                .input = styles.composer,
                .confirm = styles.text,
            },
            frame_allocator,
        );
    } else {
        input_win.fill(.{ .style = styles.meta_surface });
        drawAutocomplete(input_win, state, layout.editor_y);
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
        if (state.status_bar_position == .bottom) {
            footer_meta_owned = try drawStatusBar(input_win, state, footer_frame, layout.meta_y);
        }
    }

    if (state.status_bar_position == .top) {
        const status_win = root.child(.{
            .x_off = 0,
            .y_off = 0,
            .width = root.width,
            .height = top_status_height,
        });
        status_win.fill(.{ .style = styles.meta_surface });
        footer_meta_owned = try drawStatusBar(status_win, state, footer_frame, 0);
    }

    // Reverse search overlay — show search bar at the bottom when active.
    if (state.search_mode) {
        const search_win = root.child(.{
            .x_off = 0,
            .y_off = @intCast(@max(0, @as(i64, root.height) - 1)),
            .width = root.width,
            .height = 1,
        });
        const match_text = state.currentSearchMatch() orelse "(no match)";
        _ = search_win.print(
            &.{
                .{ .text = " search: ", .style = .{ .fg = Color.rgbFromUint(0xffd700), .bg = Color.rgbFromUint(0x08110f), .bold = true } },
                .{ .text = state.search_buffer.items, .style = .{ .fg = Color.rgbFromUint(0xe8fff8), .bg = Color.rgbFromUint(0x08110f) } },
                .{ .text = "  > ", .style = .{ .fg = Color.rgbFromUint(0x4a6a5c), .bg = Color.rgbFromUint(0x08110f) } },
                .{ .text = match_text, .style = .{ .fg = Color.rgbFromUint(0x8ce6c8), .bg = Color.rgbFromUint(0x08110f) } },
            },
            .{ .wrap = .none },
        );
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

fn drawStatusBar(
    win: Window,
    state: *const ChatState,
    frame: footer_effects.Frame,
    row: u16,
) ![]u8 {
    const agent_counts = state.agentCounts();
    const meta = try formatFooterMetaWithScope(
        state.allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        state.prompt_mode,
        state.status,
        state.full_access_mode,
        state.context_used_tokens,
        state.context_window_tokens,
        agent_counts.running,
        agent_counts.total,
        state.waiting,
        state.cancel_requested,
        state.scroll_offset,
        .{
            .known = state.agent_pool_known,
            .healthy = state.agent_pool_healthy,
            .max = state.agent_pool_max,
            .running = state.agent_pool_running,
            .tickets_assigned = state.tickets_assigned,
            .tickets_in_progress = state.tickets_in_progress,
            .ticket_ledger_healthy = state.ticket_ledger_healthy,
        },
        if (state.has_session_cost) state.session_cost_usd else null,
        @as(usize, win.width) -| 4,
    );
    errdefer state.allocator.free(meta);

    if (win.width > 1) {
        _ = win.print(&.{.{ .text = "●", .style = footerStatusStyle(state) }}, .{
            .row_offset = row,
            .col_offset = 1,
            .wrap = .none,
        });
    }
    if (meta.len > 0 and win.width > 3) {
        var segments: [32]tui.Cell.Segment = undefined;
        const segment_count = footer_effects.writeSegments(
            &segments,
            meta,
            frame,
            .{
                .base = styles.meta_value,
                .edge = styles.footer_sweep_edge,
                .core = styles.footer_sweep_core,
                .fade = styles.footer_sweep_fade,
            },
        );
        _ = win.print(segments[0..segment_count], .{
            .row_offset = row,
            .col_offset = 3,
            .wrap = .none,
        });
    }
    return meta;
}

const ChatLayout = struct {
    transcript_height: u16,
    transcript_y: u16 = 0,
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
const startup_intro_hint = "help · settings · model";
const startup_intro_gap_rows: usize = 1;
const startup_intro_projected_rows: usize = startup_intro_lines.len + 2 + startup_intro_gap_rows;

fn computeLayout(root_height: u16) ChatLayout {
    return computeLayoutForFooter(root_height, @min(@as(u16, 3), root_height));
}

fn computeLayoutForFooter(root_height: u16, requested_footer_height: u16) ChatLayout {
    return computeLayoutForPosition(root_height, 0, requested_footer_height, .bottom);
}

fn computeLayoutWithReasoningDock(root_height: u16, requested_reasoning_height: u16) ChatLayout {
    return computeLayoutWithReasoningDockAndFooter(root_height, requested_reasoning_height, @min(@as(u16, 3), root_height));
}

fn computeLayoutWithReasoningDockAndFooter(
    root_height: u16,
    requested_reasoning_height: u16,
    requested_footer_height: u16,
) ChatLayout {
    return computeLayoutForPosition(root_height, requested_reasoning_height, requested_footer_height, .bottom);
}

fn computeLayoutForPosition(
    root_height: u16,
    requested_reasoning_height: u16,
    requested_footer_height: u16,
    status_bar_position: config_file.StatusBarPosition,
) ChatLayout {
    const status_height: u16 = if (status_bar_position == .top) @min(@as(u16, 1), root_height) else 0;
    const footer_height = @min(requested_footer_height, root_height -| status_height);
    const content_height = root_height -| status_height -| footer_height;
    var layout = ChatLayout{
        .transcript_height = content_height,
        .transcript_y = status_height,
        .footer_y = status_height +| content_height,
        .footer_height = footer_height,
        .editor_y = 0,
        .meta_y = if (status_bar_position == .bottom and footer_height > 1) footer_height - 1 else 0,
    };
    layout.reasoning_height = @min(requested_reasoning_height, layout.transcript_height);
    const remaining_height = layout.transcript_height - layout.reasoning_height;
    layout.reasoning_gap_height = @intFromBool(layout.reasoning_height > 0 and remaining_height > 0);
    layout.transcript_height = remaining_height - layout.reasoning_gap_height;
    layout.reasoning_y = layout.transcript_y +| layout.transcript_height +| layout.reasoning_gap_height;
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

fn activityStateLabel(state: ActivityState) []const u8 {
    return switch (state) {
        .pending => "queued",
        .running => "running",
        .completed => "complete",
        .failed => "failed",
        .cancelled => "cancelled",
    };
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
    return tool_name;
}

fn compactAgentSummary(allocator: std.mem.Allocator, summary: []const u8) ![]u8 {
    var compact = std.array_list.Managed(u8).init(allocator);
    errdefer compact.deinit();

    var tokens = std.mem.tokenizeAny(u8, summary, " \t\r\n");
    while (tokens.next()) |token| {
        if (compact.items.len > 0) try compact.append(' ');
        try compact.appendSlice(token);
    }
    return compact.toOwnedSlice();
}

fn formatAgentActivityHeader(
    allocator: std.mem.Allocator,
    name: []const u8,
    state: ActivityState,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s} - {s}", .{ name, activityStateLabel(state) });
}

fn formatAgentActivitySummary(
    allocator: std.mem.Allocator,
    name: []const u8,
    state: ActivityState,
    summary: ?[]const u8,
    body_width: usize,
) ![]u8 {
    const header = try formatAgentActivityHeader(allocator, name, state);
    defer allocator.free(header);
    const value = summary orelse return truncateEnd(allocator, header, body_width);
    if (value.len == 0) return truncateEnd(allocator, header, body_width);

    const available = body_width -| (footerVisualWidth(header) + 3);
    if (available == 0) return truncateEnd(allocator, header, body_width);
    const compact = try truncateEnd(allocator, value, available);
    defer allocator.free(compact);
    return std.fmt.allocPrint(allocator, "{s} \"{s}\"", .{ header, compact });
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
        .running => "○ ",
        .completed => "◉ ",
        .failed => "✗ ",
        .cancelled => "⊘ ",
    };
}

fn activityGroupMarker(state: ActivityState) []const u8 {
    return switch (state) {
        .completed => "◉ ",
        .failed => "✗ ",
        .cancelled => "⊘ ",
        else => "○ ",
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

const ThemeColors = struct {
    surface_bg: Color,
    meta_bg: Color,
    composer_bg: Color,
    selected_bg: Color,
    text_fg: Color,
    accent_fg: Color,
    assistant_fg: Color,
    muted_fg: Color,
    progress_fg: Color,
    warning_fg: Color,
    error_fg: Color,
};

const ThemePalette = struct {
    surface: Style,
    meta_surface: Style,
    composer: Style,
    user: Style,
    assistant: Style,
    user_text: Style,
    assistant_text: Style,
    thinking: Style,
    progress: Style,
    system: Style,
    intro: Style,
    intro_version: Style,
    intro_hint: Style,
    text: Style,
    meta_label: Style,
    meta_value: Style,
    footer_sweep_fade: Style,
    footer_sweep_edge: Style,
    footer_sweep_core: Style,
    autocomplete: Style,
    autocomplete_name: Style,
    autocomplete_selected: Style,
    autocomplete_selected_name: Style,
    status_ready: Style,
    status_working: Style,
    status_failed: Style,
};

fn makeTheme(colors: ThemeColors) ThemePalette {
    return .{
        .surface = .{ .fg = colors.text_fg, .bg = colors.surface_bg },
        // Footer metadata is a quiet intermediate tint. The background
        // hierarchy remains surface < meta_surface < composer in every named
        // palette; no border or extra chrome is needed.
        .meta_surface = .{ .fg = colors.muted_fg, .bg = colors.meta_bg },
        .composer = .{ .fg = colors.text_fg, .bg = colors.composer_bg },
        .user = .{ .fg = colors.accent_fg, .bg = colors.surface_bg, .bold = true },
        .assistant = .{ .fg = colors.assistant_fg, .bg = colors.surface_bg, .bold = true },
        .user_text = .{ .fg = colors.text_fg, .bg = colors.surface_bg },
        .assistant_text = .{ .fg = colors.assistant_fg, .bg = colors.surface_bg },
        .thinking = .{ .fg = colors.accent_fg, .bg = colors.surface_bg, .dim = true, .blink = true },
        .progress = .{ .fg = colors.progress_fg, .bg = colors.surface_bg, .dim = true },
        .system = .{ .fg = colors.muted_fg, .bg = colors.surface_bg, .dim = true },
        .intro = .{ .fg = colors.accent_fg, .bg = colors.surface_bg, .bold = true },
        .intro_version = .{ .fg = colors.muted_fg, .bg = colors.surface_bg, .dim = true },
        .intro_hint = .{ .fg = colors.assistant_fg, .bg = colors.surface_bg, .dim = true },
        .text = .{ .fg = colors.text_fg, .bg = colors.surface_bg },
        .meta_label = .{ .fg = colors.progress_fg, .bg = colors.meta_bg, .dim = true },
        .meta_value = .{ .fg = colors.assistant_fg, .bg = colors.meta_bg, .dim = true },
        .footer_sweep_fade = .{ .fg = colors.muted_fg, .bg = colors.meta_bg },
        .footer_sweep_edge = .{ .fg = colors.accent_fg, .bg = colors.meta_bg },
        .footer_sweep_core = .{ .fg = colors.assistant_fg, .bg = colors.meta_bg, .bold = true },
        .autocomplete = .{ .fg = colors.assistant_fg, .bg = colors.meta_bg },
        .autocomplete_name = .{ .fg = colors.assistant_fg, .bg = colors.meta_bg, .bold = true },
        .autocomplete_selected = .{ .fg = colors.text_fg, .bg = colors.selected_bg },
        .autocomplete_selected_name = .{ .fg = colors.text_fg, .bg = colors.selected_bg, .bold = true },
        .status_ready = .{ .fg = colors.accent_fg, .bg = colors.meta_bg },
        .status_working = .{ .fg = colors.warning_fg, .bg = colors.meta_bg },
        .status_failed = .{ .fg = colors.error_fg, .bg = colors.meta_bg },
    };
}

const vantari_theme = makeTheme(.{
    .surface_bg = Color.rgbFromUint(0x08110f),
    .meta_bg = Color.rgbFromUint(0x0a1614),
    .composer_bg = Color.rgbFromUint(0x10221f),
    .selected_bg = Color.rgbFromUint(0x18302b),
    .text_fg = Color.rgbFromUint(0xd9f7ef),
    .accent_fg = Color.rgbFromUint(0x43c58b),
    .assistant_fg = Color.rgbFromUint(0x8ff5d2),
    .muted_fg = Color.rgbFromUint(0x78958d),
    .progress_fg = Color.rgbFromUint(0x9fbeb5),
    .warning_fg = Color.rgbFromUint(0xd7ad5a),
    .error_fg = Color.rgbFromUint(0xe06c75),
});

const midnight_theme = makeTheme(.{
    .surface_bg = Color.rgbFromUint(0x070d18),
    .meta_bg = Color.rgbFromUint(0x0c1728),
    .composer_bg = Color.rgbFromUint(0x16263d),
    .selected_bg = Color.rgbFromUint(0x203b5e),
    .text_fg = Color.rgbFromUint(0xe6f0ff),
    .accent_fg = Color.rgbFromUint(0x70b7ff),
    .assistant_fg = Color.rgbFromUint(0x9ed1ff),
    .muted_fg = Color.rgbFromUint(0x7e94ae),
    .progress_fg = Color.rgbFromUint(0xa9bbd2),
    .warning_fg = Color.rgbFromUint(0xf0c674),
    .error_fg = Color.rgbFromUint(0xff7b86),
});

const high_contrast_theme = makeTheme(.{
    .surface_bg = Color.rgbFromUint(0x000000),
    .meta_bg = Color.rgbFromUint(0x101010),
    .composer_bg = Color.rgbFromUint(0x262626),
    .selected_bg = Color.rgbFromUint(0x4a4a4a),
    .text_fg = Color.rgbFromUint(0xffffff),
    .accent_fg = Color.rgbFromUint(0x00ff9d),
    .assistant_fg = Color.rgbFromUint(0x7dffcf),
    .muted_fg = Color.rgbFromUint(0xc8c8c8),
    .progress_fg = Color.rgbFromUint(0xe0e0e0),
    .warning_fg = Color.rgbFromUint(0xffff00),
    .error_fg = Color.rgbFromUint(0xff5555),
});

const amber_theme = makeTheme(.{
    .surface_bg = Color.rgbFromUint(0x120d05),
    .meta_bg = Color.rgbFromUint(0x20170a),
    .composer_bg = Color.rgbFromUint(0x33230d),
    .selected_bg = Color.rgbFromUint(0x503913),
    .text_fg = Color.rgbFromUint(0xfff1cf),
    .accent_fg = Color.rgbFromUint(0xffb84d),
    .assistant_fg = Color.rgbFromUint(0xffd27a),
    .muted_fg = Color.rgbFromUint(0xb99a70),
    .progress_fg = Color.rgbFromUint(0xd8bd91),
    .warning_fg = Color.rgbFromUint(0xffd166),
    .error_fg = Color.rgbFromUint(0xff6b5e),
});

var styles: ThemePalette = vantari_theme;

fn applyTheme(theme: config_file.TuiTheme) void {
    styles = switch (theme) {
        .vantari => vantari_theme,
        .midnight => midnight_theme,
        .high_contrast => high_contrast_theme,
        .amber => amber_theme,
    };
}

fn drawAutocomplete(win: Window, state: *const ChatState, rows: u16) void {
    if (rows == 0 or state.autocomplete_matches.items.len == 0) return;

    const visible = @min(@as(usize, rows), state.autocomplete_matches.items.len);
    const max_scroll = state.autocomplete_matches.items.len - visible;
    const start = @min(state.autocomplete_scroll, max_scroll);
    for (state.autocomplete_matches.items[start .. start + visible], 0..) |command_index, row_index| {
        const absolute_index = start + row_index;
        const selected = absolute_index == @min(state.autocomplete_cursor, state.autocomplete_matches.items.len - 1);
        const row = win.child(.{
            .x_off = 0,
            .y_off = @intCast(row_index),
            .width = win.width,
            .height = 1,
        });
        const row_style = if (selected) styles.autocomplete_selected else styles.autocomplete;
        row.fill(.{ .style = row_style });

        _ = row.print(&.{.{
            .text = if (selected) "▸ " else "  ",
            .style = row_style,
        }}, .{ .col_offset = 1, .wrap = .none });

        const info = command_registry[command_index];
        const name_style = if (selected) styles.autocomplete_selected_name else styles.autocomplete_name;
        _ = row.print(&.{.{ .text = info.name, .style = name_style }}, .{
            .col_offset = 3,
            .wrap = .none,
        });

        const description_col = 5 + info.name.len;
        if (description_col < @as(usize, win.width)) {
            _ = row.print(&.{.{ .text = info.description, .style = row_style }}, .{
                .col_offset = @intCast(description_col),
                .wrap = .none,
            });
        }
    }
}

fn colorLevel(color: Color) u32 {
    return switch (color) {
        .rgb => |rgb| @as(u32, rgb[0]) * 2126 + @as(u32, rgb[1]) * 7152 + @as(u32, rgb[2]) * 722,
        else => 0,
    };
}

fn drawTranscript(win: Window, state: *ChatState) void {
    win.fill(.{ .style = styles.surface });
    const content = win.child(.{
        .x_off = 1,
        .y_off = 0,
        .width = win.width -| 2,
        .height = win.height,
    });
    if (content.height <= 1) return;

    const body_width = @max(@as(usize, 1), @as(usize, content.width -| 4));
    state.reflowActivityRows(body_width) catch return;
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
    intro_hint: bool = false,
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
    try rows.append(allocator, .{
        .role = .system,
        .text = startup_intro_hint,
        .intro = true,
        .intro_hint = true,
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
        drawIntroRow(win, row, transcript_row.text, transcript_row.intro_version, transcript_row.intro_hint);
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
        // Groups and child rows share the same compact state language:
        // ○ means queued/running and ◉ means complete.
        if (transcript_row.activity_kind == .group) {
            const group_glyph = activityGroupMarker(transcript_row.activity_state);
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

fn drawIntroRow(win: Window, row: u16, text: []const u8, version: bool, hint: bool) void {
    const visual_width = introVisualWidth(text);
    const col: u16 = if (win.width > visual_width)
        @intCast((@as(usize, win.width) - visual_width) / 2)
    else
        0;
    const style = if (version) styles.intro_version else if (hint) styles.intro_hint else styles.intro;
    _ = win.print(&.{.{ .text = text, .style = style }}, .{
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
    const hint_start = @intFromPtr(startup_intro_hint.ptr);
    const hint_end = hint_start + startup_intro_hint.len;
    if (slice_start >= hint_start and slice_end <= hint_end) return true;
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
    // Progress rows are deliberately dense. System output can be multiline
    // (`/help`, `/history`, `/status`) and must flow through the wrapped-row
    // path or the renderer would show only its first physical line.
    return role == .progress;
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
    return formatFooterMetaWithPool(
        allocator,
        model,
        effort,
        thinking_mode,
        .orchestrate,
        "READY",
        context_used_tokens,
        context_window_tokens,
        running_agents,
        total_agents,
        waiting,
        cancel_requested,
        scroll_offset,
        .{},
        null,
        width,
    );
}

fn formatFooterMetaWithPool(
    allocator: std.mem.Allocator,
    model: []const u8,
    effort: []const u8,
    thinking_mode: []const u8,
    prompt_mode: prompt_modes.PromptMode,
    runtime_status: []const u8,
    context_used_tokens: ?u64,
    context_window_tokens: u64,
    running_agents: usize,
    total_agents: usize,
    waiting: bool,
    cancel_requested: bool,
    scroll_offset: usize,
    pool: FooterPool,
    session_cost_usd: ?f64,
    width: usize,
) ![]u8 {
    return formatFooterMetaWithScope(
        allocator,
        model,
        effort,
        thinking_mode,
        prompt_mode,
        runtime_status,
        null,
        context_used_tokens,
        context_window_tokens,
        running_agents,
        total_agents,
        waiting,
        cancel_requested,
        scroll_offset,
        pool,
        session_cost_usd,
        width,
    );
}

fn formatFooterMetaWithScope(
    allocator: std.mem.Allocator,
    model: []const u8,
    effort: []const u8,
    thinking_mode: []const u8,
    prompt_mode: prompt_modes.PromptMode,
    runtime_status: []const u8,
    full_access_mode: ?bool,
    context_used_tokens: ?u64,
    context_window_tokens: u64,
    running_agents: usize,
    total_agents: usize,
    waiting: bool,
    cancel_requested: bool,
    scroll_offset: usize,
    pool: FooterPool,
    session_cost_usd: ?f64,
    width: usize,
) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");

    const effort_label = footerEffortLabel(effort, thinking_mode);
    const context_full = try formatContextMeta(allocator, context_used_tokens, context_window_tokens, true);
    defer allocator.free(context_full);
    const context_compact = try formatContextMeta(allocator, context_used_tokens, context_window_tokens, false);
    defer allocator.free(context_compact);

    var agents = std.array_list.Managed(u8).init(allocator);
    defer agents.deinit();
    if (waiting and total_agents > 0) {
        try agents.writer().print("agents {d}/{d}", .{ running_agents, total_agents });
    }
    if (pool.known and pool.max > 0 and (pool.running > 0 or pool.tickets_assigned > 0 or pool.tickets_in_progress > 0)) {
        if (agents.items.len > 0) try agents.appendSlice(" · ");
        try agents.writer().print("pool {d}/{d}", .{ pool.running, pool.max });
    }
    if (pool.known and !pool.healthy) {
        if (agents.items.len > 0) try agents.appendSlice(" · ");
        try agents.appendSlice("pool ?");
    }
    if (pool.tickets_assigned > 0 or !pool.ticket_ledger_healthy) {
        if (agents.items.len > 0) try agents.appendSlice(" · ");
        if (pool.ticket_ledger_healthy) {
            try agents.writer().print("queue {d}", .{pool.tickets_assigned});
        } else {
            try agents.appendSlice("queue ?");
        }
    }
    if (session_cost_usd) |cost| {
        if (std.math.isFinite(cost) and cost >= 0.0) {
            if (agents.items.len > 0) try agents.appendSlice(" · ");
            try agents.writer().print("cost ${d:.6}", .{cost});
        }
    }

    const status = footerStatusLabel(runtime_status, waiting, cancel_requested);
    const mode = prompt_mode.label();
    const scope = if (full_access_mode) |enabled|
        if (enabled) "scope full" else "scope workspace"
    else
        "";
    const transient = try formatFooterTransient(allocator, scroll_offset);
    defer allocator.free(transient);

    var candidate = try buildFooterMetaLine(allocator, status, mode, model, scope, effort_label, context_full, agents.items, transient, true, true, true, true);
    if (footerVisualWidth(candidate) <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, status, mode, model, scope, effort_label, context_full, "", "", true, false, false, true);
    if (footerVisualWidth(candidate) <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, status, mode, model, scope, "", context_compact, agents.items, "", false, true, false, true);
    if (footerVisualWidth(candidate) <= width) return candidate;
    allocator.free(candidate);

    candidate = try buildFooterMetaLine(allocator, status, mode, model, scope, "", context_compact, "", "", false, false, false, true);
    defer allocator.free(candidate);
    return truncateFooterEnd(allocator, candidate, width);
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
    status: []const u8,
    prompt_mode: []const u8,
    model: []const u8,
    scope: []const u8,
    effort: []const u8,
    context: []const u8,
    agents: []const u8,
    transient: []const u8,
    include_effort: bool,
    include_agents: bool,
    include_transient: bool,
    include_scope: bool,
) ![]u8 {
    var line = std.array_list.Managed(u8).init(allocator);
    errdefer line.deinit();
    var first = true;
    try appendFooterPart(&line, &first, status);
    try appendFooterPart(&line, &first, prompt_mode);
    try appendFooterPart(&line, &first, model);
    if (include_scope) try appendFooterPart(&line, &first, scope);
    if (include_effort) try appendFooterPart(&line, &first, effort);
    try appendFooterPart(&line, &first, context);
    if (include_agents) try appendFooterPart(&line, &first, agents);
    if (include_transient) try appendFooterPart(&line, &first, transient);
    return line.toOwnedSlice();
}

fn appendFooterPart(line: *std.array_list.Managed(u8), first: *bool, part: []const u8) !void {
    if (part.len == 0) return;
    if (!first.*) try line.appendSlice(" · ");
    try line.appendSlice(part);
    first.* = false;
}

fn footerStatusLabel(
    runtime_status: []const u8,
    waiting: bool,
    cancel_requested: bool,
) []const u8 {
    if (std.ascii.eqlIgnoreCase(runtime_status, "FAILED") or
        std.ascii.eqlIgnoreCase(runtime_status, "RPC_ERROR")) return "failed";
    if ((waiting and cancel_requested) or std.ascii.eqlIgnoreCase(runtime_status, "CANCELLING")) return "cancelling";
    if (waiting or std.ascii.eqlIgnoreCase(runtime_status, "RUNNING")) return "working";
    return "ready";
}

fn formatFooterTransient(allocator: std.mem.Allocator, scroll_offset: usize) ![]u8 {
    if (scroll_offset == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "older +{d}", .{scroll_offset});
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
    const value_width = footerVisualWidth(value);
    if (value_width <= width) return allocator.dupe(u8, value);
    if (width <= 3) return dotted(allocator, width);

    const prefix_width = width - 3;
    var byte_end: usize = 0;
    var codepoints: usize = 0;
    while (byte_end < value.len and codepoints < prefix_width) {
        const byte_length = std.unicode.utf8ByteSequenceLength(value[byte_end]) catch {
            const out = try allocator.alloc(u8, width);
            @memcpy(out[0..prefix_width], value[0..prefix_width]);
            @memcpy(out[prefix_width..], "...");
            return out;
        };
        if (byte_length > value.len - byte_end) break;
        byte_end += byte_length;
        codepoints += 1;
    }

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(value[0..byte_end]);
    try out.appendSlice("...");
    return out.toOwnedSlice();
}

fn footerVisualWidth(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

fn truncateFooterEnd(allocator: std.mem.Allocator, value: []const u8, width: usize) ![]u8 {
    if (footerVisualWidth(value) <= width) return allocator.dupe(u8, value);
    if (width <= 3) return dotted(allocator, width);

    const prefix_width = width - 3;
    var byte_end: usize = 0;
    var codepoints: usize = 0;
    while (byte_end < value.len and codepoints < prefix_width) {
        const byte_length = std.unicode.utf8ByteSequenceLength(value[byte_end]) catch 1;
        byte_end += @min(@as(usize, byte_length), value.len - byte_end);
        codepoints += 1;
    }

    const out = try allocator.alloc(u8, byte_end + 3);
    @memcpy(out[0..byte_end], value[0..byte_end]);
    @memcpy(out[byte_end..], "...");
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

fn nextProgressSeq(seq: u64) !u64 {
    if (seq == std.math.maxInt(u64)) return error.EventSequenceOverflow;
    return seq + 1;
}

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
    if (std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type)) return formatTurnTerminal(allocator, message);
    if (std.mem.eql(u8, event_type, "session_failed")) return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "failed: {s}", .{message}));
    if (std.mem.startsWith(u8, event_type, "context_compaction_")) return formatContextCompaction(allocator, event_type, message);

    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ progressLabel(event_type), message }));
}

fn formatTurnTerminal(allocator: std.mem.Allocator, message: []const u8) !?[]u8 {
    const Terminal = struct {
        outcome: []const u8,
        detail: []const u8 = "",
    };
    var parsed = std.json.parseFromSlice(Terminal, allocator, message, .{
        .ignore_unknown_fields = true,
    }) catch return try allocator.dupe(u8, "terminal event malformed");
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.outcome, "completed")) return null;
    const label = if (std.mem.eql(u8, parsed.value.outcome, "timed_out")) "timed out" else parsed.value.outcome;
    if (parsed.value.detail.len == 0) return try allocator.dupe(u8, label);
    return try trimOwnedProgress(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ label, parsed.value.detail }));
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

fn shouldRenderProgressEvent(log_level: shared_types.LogLevel, event_type: []const u8) bool {
    // Assistant output and reasoning have dedicated projections. Rendering
    // them as generic progress would duplicate the operator's answer.
    if (std.mem.eql(u8, event_type, "assistant_response") or
        std.mem.eql(u8, event_type, "reasoning_delta")) return false;

    if (log_level == .full) return true;
    if (log_level == .silent) {
        return std.mem.startsWith(u8, event_type, "child_") or
            std.mem.eql(u8, event_type, "input_requested") or
            std.mem.eql(u8, event_type, "session_failed") or
            std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type);
    }
    return !skipProgressEvent(event_type);
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
        // Read-only compatibility for pre-v1 terminal ledgers.
        std.mem.eql(u8, event_type, "turn_finished") or
        std.mem.eql(u8, event_type, "provider_turn_recovered") or
        std.mem.eql(u8, event_type, "branch_converged") or
        std.mem.eql(u8, event_type, "session_delegated") or
        std.mem.startsWith(u8, event_type, "context_compaction_");
}

fn replayProgressEvent(log_level: shared_types.LogLevel, event_type: []const u8) bool {
    if (log_level == .full) return true;
    return std.mem.startsWith(u8, event_type, "child_") or
        std.mem.eql(u8, event_type, "session_waiting") or
        std.mem.eql(u8, event_type, "input_requested");
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
    if (std.mem.eql(u8, event_type, protocol_events.turn_terminal_event_type)) return "terminal";
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

fn renderCancelParams(allocator: std.mem.Allocator, session_id: []const u8, expected_run_seq: u64) ![]u8 {
    return renderJsonAlloc(allocator, .{
        .session_id = session_id,
        .expected_run_seq = expected_run_seq,
    });
}

test "tui cancel params carry the exact observed run generation" {
    const params = try renderCancelParams(std.testing.allocator, "session-one", 73);
    defer std.testing.allocator.free(params);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, params, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("session-one", parsed.value.object.get("session_id").?.string);
    try std.testing.expectEqual(@as(i64, 73), parsed.value.object.get("expected_run_seq").?.integer);
}

test "tui run generation follows session lifecycle events" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    _ = try state.recordProgressEvent(1, "session_started", "");
    state.cancel_requested = true;
    try std.testing.expectEqual(@as(u64, 1), state.active_run_seq);
    _ = try state.recordProgressEvent(2, "assistant_response", "done");
    try std.testing.expectEqual(@as(u64, 1), state.active_run_seq);
    _ = try state.recordProgressEvent(3, protocol_events.turn_terminal_event_type, "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":1,\"outcome\":\"completed\",\"detail\":\"\"}");
    try std.testing.expectEqual(@as(u64, 0), state.active_run_seq);
    try std.testing.expect(!state.cancel_requested);
    _ = try state.recordProgressEvent(4, "session_started", "");
    try std.testing.expectEqual(@as(u64, 4), state.active_run_seq);
    _ = try state.recordProgressEvent(5, protocol_events.turn_terminal_event_type, "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":4,\"outcome\":\"failed\",\"detail\":\"failed\"}");
    try std.testing.expectEqual(@as(u64, 0), state.active_run_seq);
}

test "tui slash cancel is truthful while idle" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    try std.testing.expectEqual(commands.CommandResult.handled, try cmdCancel(&state, ""));
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("No active run to cancel.", state.messages.items[0].text);
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

    const owner_failed = try renderStartupFailure(std.testing.allocator, error.OwnerStartFailed);
    defer std.testing.allocator.free(owner_failed);
    try std.testing.expect(std.mem.indexOf(u8, owner_failed, "code=OwnerStartFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_failed, "not be configured for provider execution") != null);
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
    try std.testing.expect(rows.items[startup_intro_lines.len + 1].intro_hint);
    try std.testing.expectEqualStrings(startup_intro_hint, rows.items[startup_intro_lines.len + 1].text);
    try std.testing.expect(rows.items[startup_intro_lines.len + 2].gap);
    try std.testing.expectEqualStrings("first operator message", rows.items[startup_intro_projected_rows].text);
    try std.testing.expectEqual(@as(usize, 7), visibleTranscriptRowCount(rows.items));
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

test "tui durable cursor preserves 100 identical same timestamp events and rejects every replay" {
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

    const Fixture = struct {
        fn init(allocator: std.mem.Allocator, transport_seq: u64, event_seq: u64) !stdio_rpc.Notification {
            const method = try allocator.dupe(u8, protocol.notification_methods.session_event);
            errdefer allocator.free(method);
            return .{
                .sequence = transport_seq,
                .method = method,
                .params_json = try std.fmt.allocPrint(
                    allocator,
                    "{{\"schema\":\"var1.session_event_notification.v1\",\"session_id\":\"session-one\",\"seq\":{d},\"event_type\":\"assistant_delta\",\"message\":\"same\",\"status\":\"running\",\"timestamp_ms\":42}}",
                    .{event_seq},
                ),
            };
        }
    };

    try state.startAssistantPlaceholder();
    for (1..101) |raw_seq| {
        const seq: u64 = @intCast(raw_seq);
        var notification = try Fixture.init(std.testing.allocator, seq, seq);
        defer notification.deinit(std.testing.allocator);
        try std.testing.expect(try state.recordProgressNotification("session-one", notification));
    }

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqual(@as(usize, 400), state.messages.items[0].text.len);
    for (0..100) |index| {
        try std.testing.expectEqualStrings("same", state.messages.items[0].text[index * 4 ..][0..4]);
    }
    try std.testing.expectEqual(@as(u64, 100), state.last_event_seq);

    for (1..101) |raw_seq| {
        const seq: u64 = @intCast(raw_seq);
        var replay = try Fixture.init(std.testing.allocator, seq + 100, seq);
        defer replay.deinit(std.testing.allocator);
        try std.testing.expect(!try state.recordProgressNotification("session-one", replay));
    }
    try std.testing.expectEqual(@as(usize, 400), state.messages.items[0].text.len);
    try std.testing.expectEqual(@as(u64, 100), state.last_event_seq);
}

test "tui durable catch-up applies an exact missing suffix in ledger order" {
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
    try std.testing.expect(try state.recordProgressEvent(1, "assistant_delta", "one"));
    const durable_suffix = [_]VAR1.shared.types.SessionEvent{
        .{ .seq = 1, .event_type = "assistant_delta", .message = "one", .timestamp_ms = 42 },
        .{ .seq = 2, .event_type = "assistant_delta", .message = "two", .timestamp_ms = 42 },
        .{ .seq = 3, .event_type = "assistant_delta", .message = "three", .timestamp_ms = 42 },
    };
    try std.testing.expect(try state.recordProgressEvents(&durable_suffix));

    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expectEqualStrings("onetwothree", state.messages.items[0].text);
    try std.testing.expectEqual(@as(u64, 3), state.last_event_seq);
}

test "tui ignores sequence-less legacy activity events" {
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

    const legacy = [_]VAR1.shared.types.SessionEvent{
        .{
            .seq = 0,
            .event_type = "child_progress",
            .message = "{\"group_id\":\"legacy\",\"task_id\":\"task\",\"name\":\"Legacy\",\"status\":\"running\"}",
            .timestamp_ms = 42,
        },
    };
    try std.testing.expect(!try state.recordProgressEvents(&legacy));
    try std.testing.expectEqual(@as(usize, 0), state.messages.items.len);
    try std.testing.expectEqual(@as(u64, 0), state.last_event_seq);
}

test "tui child activity replay equals contiguous live event projection" {
    const allocator = std.testing.allocator;
    var live = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.2",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer live.deinit();
    var replay = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "glm-5.2",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .auth_provider = "zai",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer replay.deinit();

    const events = [_]VAR1.shared.types.SessionEvent{
        .{ .seq = 1, .event_type = "child_group_started", .message = "{\"group_id\":\"group\",\"queued\":1,\"terminal\":false}", .timestamp_ms = 1 },
        .{ .seq = 2, .event_type = "child_admitted", .message = "{\"group_id\":\"group\",\"task_id\":\"task\",\"name\":\"Scout\",\"status\":\"queued\"}", .timestamp_ms = 2 },
        .{ .seq = 3, .event_type = "child_progress", .message = "{\"group_id\":\"group\",\"task_id\":\"task\",\"name\":\"Scout\",\"status\":\"running\",\"phase\":\"assistant_response\",\"detail\":\"Mapped the workspace.\"}", .timestamp_ms = 3 },
        .{ .seq = 4, .event_type = "child_finished", .message = "{\"group_id\":\"group\",\"task_id\":\"task\",\"name\":\"Scout\",\"status\":\"completed\"}", .timestamp_ms = 4 },
        .{ .seq = 5, .event_type = "child_group_finished", .message = "{\"group_id\":\"group\",\"completed\":1,\"terminal\":true}", .timestamp_ms = 5 },
    };

    for (events) |event| {
        _ = try live.recordProgressEvent(event.seq, event.event_type, event.message);
    }
    _ = try replay.recordProgressEvents(&events);

    try std.testing.expectEqual(live.last_event_seq, replay.last_event_seq);
    try std.testing.expectEqual(live.messages.items.len, replay.messages.items.len);
    for (live.messages.items, replay.messages.items) |live_message, replay_message| {
        try std.testing.expectEqual(live_message.role, replay_message.role);
        try std.testing.expectEqualStrings(live_message.text, replay_message.text);
        try std.testing.expectEqual(live_message.activity_kind, replay_message.activity_kind);
        try std.testing.expectEqual(live_message.activity_state, replay_message.activity_state);
        try std.testing.expectEqual(live_message.activity_last, replay_message.activity_last);
    }
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
    try std.testing.expectEqual(@as(usize, 11), row_count);
    try std.testing.expectEqual(@as(usize, 11), visibleEndRow(&state, row_count));
    state.scrollUp(1);
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, row_count));
    try std.testing.expect(applyMouseScroll(&state, .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(@as(usize, 7), visibleEndRow(&state, row_count));
    try std.testing.expect(applyMouseScroll(&state, .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    }));
    try std.testing.expectEqual(@as(usize, 10), visibleEndRow(&state, row_count));
    state.scrollUp(100);
    try std.testing.expectEqual(@as(usize, 1), visibleEndRow(&state, row_count));
    state.scrollDown(1);
    try std.testing.expectEqual(@as(usize, 2), visibleEndRow(&state, row_count));
    state.jumpToBottom();
    try std.testing.expectEqual(@as(usize, 11), visibleEndRow(&state, row_count));
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
    try std.testing.expectEqual(@as(usize, 13), before_rows);
    try std.testing.expectEqual(@as(usize, 11), visibleEndRow(&state, before_rows));

    const output_event = "{\"schema\":\"var1.tool_output_delta.v1\",\"tool\":\"shell_exec\",\"tool_call_id\":\"call_1\",\"stream\":\"stdout\",\"chunk_b64\":\"bGl2ZS1saW5l\",\"cap_reached\":false}";
    try state.addProgress("tool_output_delta", output_event);
    try state.addProgress("tool_output_delta", output_event);

    try std.testing.expectEqual(@as(usize, 3), state.scroll_offset);
    const after_rows = transcriptRowCount(&state, 80);
    try std.testing.expectEqual(@as(usize, 14), after_rows);
    try std.testing.expectEqual(@as(usize, 11), visibleEndRow(&state, after_rows));
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
    try std.testing.expectEqual(@as(usize, 9), before_rows);

    state.scrollUp(1);
    try state.addAssistantDelta(" gamma delta");

    const after_rows = transcriptRowCount(&state, 6);
    try std.testing.expectEqual(@as(usize, 11), after_rows);
    try std.testing.expectEqual(@as(usize, 3), state.scroll_offset);
    try std.testing.expectEqual(@as(usize, 8), visibleEndRow(&state, after_rows));
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

test "tui composer surfaces preserve a strict lightness hierarchy" {
    const transcript_level = colorLevel(styles.surface.bg);
    const metadata_level = colorLevel(styles.meta_surface.bg);
    const composer_level = colorLevel(styles.composer.bg);

    try std.testing.expect(transcript_level < metadata_level);
    try std.testing.expect(metadata_level < composer_level);
}

test "tui named themes preserve the surface hierarchy" {
    const themes = [_]config_file.TuiTheme{ .vantari, .midnight, .high_contrast, .amber };
    for (themes) |theme| {
        applyTheme(theme);
        try std.testing.expect(colorLevel(styles.surface.bg) < colorLevel(styles.meta_surface.bg));
        try std.testing.expect(colorLevel(styles.meta_surface.bg) < colorLevel(styles.composer.bg));
    }
    applyTheme(.vantari);
}

test "tui top status layout reserves one row without moving the composer contract" {
    const layout = computeLayoutForPosition(30, 0, 1, .top);
    try std.testing.expectEqual(@as(u16, 1), layout.transcript_y);
    try std.testing.expectEqual(@as(u16, 28), layout.transcript_height);
    try std.testing.expectEqual(@as(u16, 29), layout.footer_y);
    try std.testing.expectEqual(@as(u16, 1), layout.footer_height);
    try std.testing.expectEqual(@as(u16, 0), layout.meta_y);
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
        "ready · orchestrate · glm-5.1 · high · ctx 5k / 200k (3%) · 195k left",
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
    try std.testing.expectEqualStrings("ready · orchestrate · glm-5.1 · ctx 5...", narrow);
}

test "tui footer maps runtime status and active prompt mode" {
    const allocator = std.testing.allocator;

    const working = try formatFooterMetaWithPool(
        allocator,
        "glm-5.1",
        "high",
        "",
        .build,
        "RUNNING",
        5_000,
        200_000,
        0,
        0,
        true,
        false,
        0,
        .{},
        null,
        120,
    );
    defer allocator.free(working);
    try std.testing.expectEqualStrings(
        "working · build · glm-5.1 · high · ctx 5k / 200k (3%) · 195k left",
        working,
    );

    const failed = try formatFooterMetaWithPool(
        allocator,
        "glm-5.1",
        "high",
        "",
        .@"align",
        "FAILED",
        5_000,
        200_000,
        0,
        0,
        false,
        false,
        0,
        .{},
        null,
        120,
    );
    defer allocator.free(failed);
    try std.testing.expect(std.mem.startsWith(u8, failed, "failed · align ·"));
}

test "tui footer exposes immutable session access scope" {
    const allocator = std.testing.allocator;

    const workspace = try formatFooterMetaWithScope(
        allocator,
        "glm-5.1",
        "high",
        "",
        .orchestrate,
        "READY",
        false,
        5_000,
        200_000,
        0,
        0,
        false,
        false,
        0,
        .{},
        null,
        120,
    );
    defer allocator.free(workspace);
    try std.testing.expect(std.mem.indexOf(u8, workspace, "scope workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, workspace, "scope full") == null);

    const full = try formatFooterMetaWithScope(
        allocator,
        "glm-5.1",
        "high",
        "",
        .orchestrate,
        "READY",
        true,
        5_000,
        200_000,
        0,
        0,
        false,
        false,
        0,
        .{},
        null,
        120,
    );
    defer allocator.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "scope full") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "scope workspace") == null);
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

    const idle = try formatFooterMeta(
        allocator,
        "glm-5.1",
        "high",
        "",
        5_000,
        200_000,
        0,
        0,
        false,
        true,
        0,
        96,
    );
    defer allocator.free(idle);
    try std.testing.expect(std.mem.indexOf(u8, idle, "cancelling") == null);
    try std.testing.expect(std.mem.indexOf(u8, idle, "Esc cancel") == null);
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
        1,
        "turn_started",
        "{\"schema\":\"var1.turn_started.v1\",\"window_tokens\":5000}",
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

test "tui footer projects canonical pool and buffered ticket pressure" {
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

    state.applyHealthTelemetry(.{
        .ok = true,
        .model = state.model,
        .workspace_root = state.workspace_root,
        .base_url = state.base_url,
        .agent_pool_healthy = true,
        .agent_pool_max = 4,
        .agent_pool_queued = 2,
        .agent_pool_running = 1,
        .agent_pool_idle = 3,
        .agent_pool_available = 1,
        .tickets_assigned = 2,
        .tickets_in_progress = 1,
        .ticket_ledger_healthy = true,
    });
    try std.testing.expectEqual(@as(usize, 4), state.agent_pool_max);
    try std.testing.expectEqual(@as(usize, 2), state.agent_pool_queued);
    try std.testing.expectEqual(@as(usize, 1), state.agent_pool_running);
    try std.testing.expectEqual(@as(usize, 3), state.agent_pool_idle);
    try std.testing.expectEqual(@as(usize, 1), state.agent_pool_available);
    try std.testing.expectEqual(@as(usize, 2), state.tickets_assigned);
    try std.testing.expectEqual(@as(usize, 1), state.tickets_in_progress);
    try std.testing.expect(state.ticket_ledger_healthy);
    state.session_cost_usd = 0.001234;
    state.has_session_cost = true;

    const footer = try formatFooterMetaWithPool(
        allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        .orchestrate,
        "READY",
        5_000,
        state.context_window_tokens,
        1,
        2,
        state.waiting,
        false,
        0,
        .{
            .known = state.agent_pool_known,
            .healthy = state.agent_pool_healthy,
            .max = state.agent_pool_max,
            .running = state.agent_pool_running,
            .tickets_assigned = state.tickets_assigned,
            .tickets_in_progress = state.tickets_in_progress,
            .ticket_ledger_healthy = state.ticket_ledger_healthy,
        },
        if (state.has_session_cost) state.session_cost_usd else null,
        140,
    );
    defer allocator.free(footer);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Qwen3.6 35B-A3B") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "high") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "ctx 5k / 200k (3%)") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "195k left") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "agents 1/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "pool 1/4") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "queue 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "cost $0.001234") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "Esc cancel") == null);

    const quiet = try formatFooterMeta(
        allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        5_000,
        state.context_window_tokens,
        0,
        0,
        false,
        false,
        0,
        140,
    );
    defer allocator.free(quiet);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "pool") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "queue") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "cost") == null);

    const unhealthy = try formatFooterMetaWithPool(
        allocator,
        state.model,
        state.effort,
        state.thinking_mode,
        .orchestrate,
        "READY",
        null,
        state.context_window_tokens,
        0,
        0,
        false,
        false,
        0,
        .{ .known = true, .healthy = false, .ticket_ledger_healthy = false },
        null,
        140,
    );
    defer allocator.free(unhealthy);
    try std.testing.expect(std.mem.indexOf(u8, unhealthy, "queue ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, unhealthy, "pool ?") != null);
    try std.testing.expect(std.mem.indexOf(u8, unhealthy, "ctx —") != null);

    const compacted = try formatContextMeta(allocator, 5_000, 0, true);
    defer allocator.free(compacted);
    try std.testing.expectEqualStrings("ctx —", compacted);
}

test "tui transcript keeps progress dense and preserves multiline system output" {
    try std.testing.expect(isCompactRole(.progress));
    try std.testing.expect(!isCompactRole(.system));
    try std.testing.expect(!isCompactRole(.assistant));
    try std.testing.expect(!isCompactRole(.user));

    var progress_message = Message{ .role = .progress, .text = try std.testing.allocator.dupe(u8, "stdout: one | two") };
    defer progress_message.deinit(std.testing.allocator);
    var system_message = Message{ .role = .system, .text = try std.testing.allocator.dupe(u8, "VAR1 Status\n  Cost:      $0.000000") };
    defer system_message.deinit(std.testing.allocator);
    var assistant_message = Message{ .role = .assistant, .text = try std.testing.allocator.dupe(u8, "Readable answer.") };
    defer assistant_message.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), messageRowCount(progress_message.role, progress_message.text, false, 80));
    try std.testing.expectEqual(@as(usize, 3), messageRowCount(system_message.role, system_message.text, false, 80));
    try std.testing.expectEqual(@as(usize, 2), messageRowCount(assistant_message.role, assistant_message.text, false, 80));

    var rows: std.ArrayList(TranscriptRow) = .{};
    defer rows.deinit(std.testing.allocator);
    try appendMessageRows(std.testing.allocator, &rows, system_message, 80);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    try std.testing.expectEqualStrings("VAR1 Status", rows.items[0].text);
    try std.testing.expectEqualStrings("  Cost:      $0.000000", rows.items[1].text);
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
    try std.testing.expect(try state.recordProgressEvent(1, "reasoning_delta", "checking the first seam"));
    try std.testing.expect(try state.recordProgressEvent(2, "session_waiting", "child group"));
    try std.testing.expect(try state.recordProgressEvent(3, "reasoning_delta", " and now the newest words"));

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
    state.last_transcript_body_width = 120;

    try state.addProgress("child_group_started", "{\"group_id\":\"group-one\",\"queued\":1,\"terminal\":false}");
    try std.testing.expectEqualStrings("Agents 0/1", state.messages.items[0].text);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "waiting on") == null);
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
    try state.addProgress("child_waiting", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"waiting\",\"elapsed_ms\":900}");
    try std.testing.expectEqualStrings("Recon - running", state.messages.items[1].text);
    try state.addProgress("child_progress", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"tool_completed\",\"detail\":\"tool completed: read_file\",\"elapsed_ms\":1250}");
    try std.testing.expectEqualStrings("Recon - running", state.messages.items[1].text);
    try state.addProgress("child_progress", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"assistant_response\",\"detail\":\"Mapped the workspace and found the backend owner.\",\"elapsed_ms\":2345}");
    try std.testing.expectEqualStrings("Recon - running \"Mapped the workspace and found the backend owner.\"", state.messages.items[1].text);
    try state.addProgress("child_progress", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"tool_completed\",\"detail\":\"tool completed: read_file\",\"elapsed_ms\":3125}");
    try std.testing.expectEqualStrings("Recon - running \"Mapped the workspace and found the backend owner.\"", state.messages.items[1].text);
    try state.addProgress("child_progress", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"running\",\"phase\":\"summary\",\"detail\":\"Found the tweet and queued the next check.\",\"elapsed_ms\":4125}");
    try std.testing.expectEqualStrings("Recon - running \"Found the tweet and queued the next check.\"", state.messages.items[1].text);
    try state.addProgress("child_finished", "{\"group_id\":\"group-one\",\"task_id\":\"task-one\",\"name\":\"Recon\",\"status\":\"completed\",\"phase\":\"complete\",\"elapsed_ms\":4567}");
    try state.addProgress("child_group_finished", "{\"group_id\":\"group-one\",\"completed\":1,\"terminal\":true}");
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("Agents 1/1", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityState.completed, state.messages.items[0].activity_state);
    try std.testing.expectEqualStrings("Recon - complete \"Found the tweet and queued the next check.\"", state.messages.items[1].text);
    try std.testing.expectEqual(ActivityState.completed, state.messages.items[1].activity_state);

    try state.addProgress("child_group_recovered", "{\"group_id\":\"group-one\",\"tasks\":1,\"stale_owners_reconciled\":1,\"terminal\":true}");
    try std.testing.expectEqual(@as(usize, 2), state.messages.items.len);
    try std.testing.expectEqualStrings("Agents 1/1 - 1 failed, 0 cancelled", state.messages.items[0].text);
    try std.testing.expectEqual(ActivityState.failed, state.messages.items[0].activity_state);
    try std.testing.expect(replayProgressEvent(.normal, "child_progress"));
    try std.testing.expect(replayProgressEvent(.normal, "session_waiting"));
    try std.testing.expect(!replayProgressEvent(.normal, "assistant_delta"));
}

test "tui log posture filters internal chat detail without dropping durable sequencing" {
    const allocator = std.testing.allocator;

    var silent = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
        .log_level = .silent,
    };
    defer silent.deinit();
    try std.testing.expect(!try silent.recordProgressEvent(1, "agent_message_received", "internal mailbox detail"));
    try std.testing.expectEqual(@as(usize, 0), silent.messages.items.len);
    try std.testing.expectEqual(@as(u64, 1), silent.last_event_seq);

    var normal = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
        .log_level = .normal,
    };
    defer normal.deinit();
    try std.testing.expect(try normal.recordProgressEvent(1, "agent_message_received", "mailbox checkpoint"));
    try std.testing.expectEqual(@as(usize, 1), normal.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, normal.messages.items[0].text, "mailbox checkpoint") != null);

    var full = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
        .log_level = .full,
    };
    defer full.deinit();
    try std.testing.expect(try full.recordProgressEvent(1, "tool_requested", "tool requested: search_files"));
    try std.testing.expectEqual(@as(usize, 1), full.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, full.messages.items[0].text, "search_files") != null);
}

test "tui question requests share one crash-safe panel in every prompt mode" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    const request = "{\"request_id\":\"call-panel\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Direction\",\"options\":[{\"id\":\"a\",\"label\":\"Fast\"},{\"id\":\"b\",\"label\":\"Careful\"}]},{\"id\":\"q2\",\"prompt\":\"Scope\",\"options\":[{\"id\":\"a\",\"label\":\"Local\"},{\"id\":\"b\",\"label\":\"Full\"}]}]}";
    const modes = [_]prompt_modes.PromptMode{ .orchestrate, .build, .@"align", .plan };
    for (modes) |mode| {
        state.prompt_mode = mode;
        state.last_event_seq = 0;
        try std.testing.expect(try state.recordProgressEvent(1, "input_requested", request));
        try std.testing.expect(state.input_state != null);
        try std.testing.expectEqual(@as(usize, 2), state.input_state.?.questions.items.len);
        try std.testing.expectEqual(@as(u16, 6), state.input_state.?.panelHeight(20));
        state.clearInputRequest();
    }

    state.prompt_mode = .@"align";
    state.last_event_seq = 0;
    try std.testing.expect(try state.recordProgressEvent(1, "input_requested", "{\"request_id\":\"call-bad\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Broken\",\"options\":[]}]}"));
    try std.testing.expect(state.input_state == null);
    try std.testing.expectEqual(@as(usize, 1), state.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "invalid question") != null);
}

test "tui question panel cannot survive an orphaned or terminal turn" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    const request = "{\"request_id\":\"call-orphan\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Choose\",\"options\":[{\"id\":\"a\",\"label\":\"One\"},{\"id\":\"b\",\"label\":\"Two\"}]}]}";
    try state.beginInputRequest(request);
    try std.testing.expect(state.input_state != null);
    try state.respondInput(true);
    try std.testing.expect(state.input_state == null);

    state.session_id = try std.testing.allocator.dupe(u8, "session-question");
    _ = try state.recordProgressEvent(1, "input_requested", request);
    try std.testing.expect(state.input_state != null);
    _ = try state.recordProgressEvent(2, protocol_events.turn_terminal_event_type, "{\"outcome\":\"failed\"}");
    try std.testing.expect(state.input_state == null);
}

test "tui question panel survives the Vaxis render boundary in every prompt mode" {
    const allocator = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    var vx = try tui.init(allocator, .{});
    defer vx.deinit(allocator, &writer.writer);
    try vx.resize(allocator, &writer.writer, .{
        .rows = 14,
        .cols = 120,
        .x_pixel = 0,
        .y_pixel = 0,
    });

    var input = TextInput.init(allocator, &vx.unicode);
    defer input.deinit();
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "workspace",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    const request = "{\"request_id\":\"call-render\",\"questions\":[{\"id\":\"q1\",\"prompt\":\"Direction\",\"options\":[{\"id\":\"a\",\"label\":\"Fast\"},{\"id\":\"b\",\"label\":\"Careful\"}]},{\"id\":\"q2\",\"prompt\":\"Scope\",\"options\":[{\"id\":\"a\",\"label\":\"Local\"},{\"id\":\"b\",\"label\":\"Full\"}]}]}";
    const modes = [_]prompt_modes.PromptMode{ .orchestrate, .build, .@"align", .plan };
    for (modes) |mode| {
        state.prompt_mode = mode;
        state.last_event_seq = 0;
        try std.testing.expect(try state.recordProgressEvent(1, "input_requested", request));
        try draw(&vx, &writer.writer, &state, &input);
        try std.testing.expect(writer.written().len > 0);
        state.clearInputRequest();
    }
}

test "tui agent child rows show a bounded turn summary instead of tool phases" {
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
    state.last_transcript_body_width = 42;

    try state.addProgress("child_admitted", "{\"group_id\":\"group-two\",\"task_id\":\"task-two\",\"name\":\"Scout\",\"status\":\"queued\"}");
    try state.addProgress("child_progress", "{\"group_id\":\"group-two\",\"task_id\":\"task-two\",\"name\":\"Scout\",\"status\":\"running\",\"phase\":\"tool_completed\",\"detail\":\"tool completed: search_files\",\"elapsed_ms\":1250}");
    try std.testing.expectEqualStrings("Scout - running", state.messages.items[0].text);

    try state.addProgress("child_progress", "{\"group_id\":\"group-two\",\"task_id\":\"task-two\",\"name\":\"Scout\",\"status\":\"running\",\"phase\":\"assistant_response\",\"detail\":\"This is a long agent turn summary that must stay on one compact row for the operator.\",\"elapsed_ms\":2345}");
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "tool_completed") == null);
    try std.testing.expect(std.mem.indexOf(u8, state.messages.items[0].text, "...\"") != null);
    try std.testing.expect(footerVisualWidth(state.messages.items[0].text) <= 42);
}

test "tui agent summary truncation preserves utf8 and display width" {
    const allocator = std.testing.allocator;
    const rendered = try formatAgentActivitySummary(
        allocator,
        "Scout",
        .running,
        "分析 workspace 🛰️ and preserve the latest agent summary",
        32,
    );
    defer allocator.free(rendered);
    try std.testing.expect(std.unicode.utf8ValidateSlice(rendered));
    try std.testing.expect(footerVisualWidth(rendered) <= 32);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "...\"") != null);
}

test "tui activity families share nested checkbox grammar" {
    try std.testing.expectEqualStrings("Search", activityTitle("web_search"));
    try std.testing.expectEqualStrings("Explore", activityTitle("read_file"));
    try std.testing.expectEqualStrings("Agents", activityTitle("agents"));

    try std.testing.expectEqualStrings("○ ", activityMarker(.pending));
    try std.testing.expectEqualStrings("○ ", activityMarker(.running));
    try std.testing.expectEqualStrings("◉ ", activityMarker(.completed));
    try std.testing.expectEqualStrings("✗ ", activityMarker(.failed));
    try std.testing.expectEqualStrings("⊘ ", activityMarker(.cancelled));
    try std.testing.expectEqualStrings("○ ", activityGroupMarker(.running));
    try std.testing.expectEqualStrings("◉ ", activityGroupMarker(.completed));
    try std.testing.expectEqualStrings("├── ", activityConnector(.item, false));
    try std.testing.expectEqualStrings("└── ", activityConnector(.item, true));
    try std.testing.expectEqualStrings("", activityConnector(.group, false));
}

test "tui completed terminal telemetry parses tokens and priced cost" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "deepseek-v4-flash",
        .base_url = "https://api.deepseek.com",
        .auth_provider = "deepseek",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const payload = "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":1,\"outcome\":\"completed\",\"detail\":\"\",\"step\":1,\"window_tokens\":2000,\"output_bytes\":10,\"prompt_tokens\":1234,\"completion_tokens\":567,\"cached_tokens\":89,\"cost_total_usd\":0.001234}";
    try std.testing.expect(try state.recordTurnTelemetry(protocol_events.turn_terminal_event_type, payload));

    try std.testing.expectEqual(@as(u64, 1234), state.session_prompt_tokens);
    try std.testing.expectEqual(@as(u64, 567), state.session_completion_tokens);
    try std.testing.expectEqual(@as(u64, 89), state.session_cached_tokens);
    try std.testing.expect(state.has_session_cost);
    try std.testing.expectApproxEqAbs(@as(f64, 0.001234), state.session_cost_usd, 1e-9);
}

test "tui terminal telemetry accumulates session cost across turns" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "deepseek-v4-flash",
        .base_url = "https://api.deepseek.com",
        .auth_provider = "deepseek",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const first = "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":1,\"outcome\":\"completed\",\"prompt_tokens\":100,\"completion_tokens\":50,\"cached_tokens\":0,\"cost_total_usd\":0.0001}";
    const second = "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":2,\"outcome\":\"completed\",\"prompt_tokens\":200,\"completion_tokens\":100,\"cached_tokens\":10,\"cost_total_usd\":0.0002}";
    try std.testing.expect(try state.recordTurnTelemetry(protocol_events.turn_terminal_event_type, first));
    try std.testing.expect(try state.recordTurnTelemetry(protocol_events.turn_terminal_event_type, second));

    try std.testing.expectEqual(@as(u64, 300), state.session_prompt_tokens);
    try std.testing.expectEqual(@as(u64, 150), state.session_completion_tokens);
    try std.testing.expectEqual(@as(u64, 10), state.session_cached_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0003), state.session_cost_usd, 1e-12);
}

test "tui terminal null cost leaves has_session_cost false" {
    const allocator = std.testing.allocator;
    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = "E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE",
        .model = "custom-local",
        .base_url = "http://localhost:1234/v1",
        .auth_provider = "local",
        .plan = "coding",
        .subscription_status = "active",
    };
    defer state.deinit();

    const payload = "{\"schema\":\"var1.turn_terminal.v1\",\"run_seq\":1,\"outcome\":\"completed\",\"prompt_tokens\":42,\"completion_tokens\":7,\"cached_tokens\":0,\"cost_total_usd\":null}";
    try std.testing.expect(try state.recordTurnTelemetry(protocol_events.turn_terminal_event_type, payload));

    try std.testing.expectEqual(@as(u64, 42), state.session_prompt_tokens);
    try std.testing.expect(!state.has_session_cost);
    try std.testing.expectApproxEqAbs(@as(f64, 0), state.session_cost_usd, 1e-12);
}

test "tui turn_started refreshes window estimate without accumulating cost" {
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

    const payload = "{\"schema\":\"var1.turn_started.v1\",\"step\":2,\"window_tokens\":5000}";
    try std.testing.expect(try state.recordTurnTelemetry("turn_started", payload));

    try std.testing.expectEqual(@as(u64, 5000), state.context_used_tokens);
    try std.testing.expectEqual(@as(u64, 0), state.session_prompt_tokens);
    try std.testing.expect(!state.has_session_cost);
}

test "tui prompt mode defaults to orchestrate and cycles for the session" {
    var state = ChatState{
        .allocator = std.testing.allocator,
        .client = undefined,
        .workspace_root = ".",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    try std.testing.expectEqual(prompt_modes.PromptMode.orchestrate, state.prompt_mode);
    state.cyclePromptMode();
    try std.testing.expectEqual(prompt_modes.PromptMode.build, state.prompt_mode);
    state.cyclePromptMode();
    try std.testing.expectEqual(prompt_modes.PromptMode.@"align", state.prompt_mode);
    state.cyclePromptMode();
    state.cyclePromptMode();
    try std.testing.expectEqual(prompt_modes.PromptMode.orchestrate, state.prompt_mode);
}

test "tui command palette matches reserved bare tokens and hides on prose" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var input = TextInput.init(allocator, &unicode);
    defer input.deinit();

    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = ".",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    try input.insertSliceAtCursor("s");
    try state.refreshAutocomplete(&input);
    try std.testing.expect(state.autocomplete_visible);
    try std.testing.expectEqual(@as(usize, 2), state.autocomplete_matches.items.len);
    try std.testing.expectEqualStrings("status", state.selectedAutocompleteName().?);

    input.clearAndFree();
    try input.insertSliceAtCursor("settings");
    try state.refreshAutocomplete(&input);
    try std.testing.expectEqual(@as(usize, 1), state.autocomplete_matches.items.len);
    try std.testing.expectEqualStrings("settings", state.selectedAutocompleteName().?);

    input.clearAndFree();
    try input.insertSliceAtCursor("settings now");
    try state.refreshAutocomplete(&input);
    try std.testing.expect(!state.autocomplete_visible);
    try std.testing.expectEqual(@as(usize, 0), state.autocomplete_matches.items.len);
}

test "tui command palette preserves slash compatibility and caps its popover" {
    const allocator = std.testing.allocator;
    var unicode = try tui.Unicode.init(allocator);
    defer unicode.deinit(allocator);
    var input = TextInput.init(allocator, &unicode);
    defer input.deinit();

    var state = ChatState{
        .allocator = allocator,
        .client = undefined,
        .workspace_root = ".",
        .model = "model",
        .base_url = "base",
        .auth_provider = "provider",
        .plan = "plan",
        .subscription_status = "active",
    };
    defer state.deinit();

    try input.insertSliceAtCursor("/");
    try state.refreshAutocomplete(&input);
    try std.testing.expect(state.autocomplete_visible);
    try std.testing.expectEqual(@as(usize, 5), state.autocompleteHeight());
    try std.testing.expectEqualStrings("help", state.selectedAutocompleteName().?);

    state.moveAutocompleteCursor(1);
    state.moveAutocompleteCursor(1);
    state.moveAutocompleteCursor(1);
    state.moveAutocompleteCursor(1);
    state.moveAutocompleteCursor(1);
    try std.testing.expectEqual(@as(usize, 5), state.autocomplete_cursor);
    try std.testing.expectEqual(@as(usize, 1), state.autocomplete_scroll);
    try std.testing.expect(state.selectedAutocompleteName() != null);
}
