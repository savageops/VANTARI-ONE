const std = @import("std");
const types = @import("../types.zig");

pub const notification_methods = struct {
    pub const session_event = "session/event";
};

pub const methods = struct {
    pub const initialize = "initialize";
    pub const session_create = "session/create";
    pub const session_resume = "session/resume";
    pub const session_send = "session/send";
    pub const session_compact = "session/compact";
    pub const session_cancel = "session/cancel";
    pub const session_get = "session/get";
    pub const session_list = "session/list";
    pub const schedule_get = "schedule/get";
    pub const schedule_list = "schedule/list";
    pub const tools_list = "tools/list";
    pub const events_subscribe = "events/subscribe";
    pub const health_get = "health/get";
    pub const models_list = "models/list";
    pub const config_set = "config/set";
};

pub const Capabilities = struct {
    session_create: bool = true,
    session_resume: bool = true,
    session_send: bool = true,
    session_compact: bool = true,
    session_cancel: bool = true,
    session_get: bool = true,
    session_list: bool = true,
    schedule_get: bool = true,
    schedule_list: bool = true,
    tools_list: bool = true,
    events_subscribe: bool = true,
    health_get: bool = true,
    models_list: bool = true,
    /// Advertises that events.jsonl carries a monotonic `seq` field and the
    /// event spine supports replay cursors. Clients can use seq for
    /// deterministic same-millisecond ordering (AGENTS.md §IV).
    event_seq_supported: bool = true,
    child_groups: bool = true,
    agent_route_receipts: bool = true,
};

pub const InitializeResult = struct {
    server_version: []const u8,
    capabilities: Capabilities,
};

pub const SessionSummary = struct {
    session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    output: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
    execution_receipt: ?types.ExecutionReceiptView = null,
    failure_reason: ?[]const u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const SessionEventNotification = struct {
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: []const u8,
    timestamp_ms: i64,
};

pub const SessionCreateResult = struct {
    session: SessionSummary,
};

pub const SessionResumeResult = struct {
    session: SessionSummary,
};

pub const SessionSendResult = struct {
    session: SessionSummary,
};

pub const SessionCompactResult = struct {
    session_id: []const u8,
    compacted: bool,
    checkpoint: ?types.ContextCheckpoint = null,
    reason: ?[]const u8 = null,
};

pub const SessionGetResult = struct {
    session: SessionSummary,
    latest_event: ?types.SessionEvent = null,
    messages: []const types.SessionMessage = &.{},
    events: []const types.SessionEvent = &.{},
};

pub const SessionListResult = struct {
    sessions: []const SessionSummary,
};

pub const SessionCancelResult = struct {
    session_id: []const u8,
    status: []const u8,
    cancellation_requested: bool,
};

pub const ScheduleSummary = struct {
    id: []const u8,
    title: []const u8,
    target_kind: []const u8,
    schedule_kind: []const u8,
    due_at_ms: i64,
    interval_ms: ?i64 = null,
    next_due_at_ms: i64,
    status: []const u8,
    misfire_policy: []const u8,
    max_catch_up: u16,
    revision: u64,
    created_at_ms: i64,
    updated_at_ms: i64,
};

pub const ScheduleGetResult = struct {
    schedule: ScheduleSummary,
};

pub const ScheduleListResult = struct {
    schedules: []const ScheduleSummary,
};

pub const EventsSubscribeResult = struct {
    subscribed: bool,
    notification_method: []const u8,
};

pub const HealthGetResult = struct {
    ok: bool,
    model: []const u8,
    workspace_root: []const u8,
    base_url: []const u8,
    auth_provider: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
    scheduler_supervisor: bool = false,
    /// Resolved runtime values used by operator-facing clients. These are
    /// additive so older clients can continue to parse health responses.
    effort: []const u8 = "",
    thinking_mode: []const u8 = "",
    context_window_tokens: u64 = 0,
    reserve_output_tokens: u64 = 0,
};

pub const ToolsListResult = struct {
    format: []const u8,
    output: []const u8,
};

pub const ModelSummary = struct {
    id: []const u8,
    owned_by: ?[]const u8 = null,
    context_length: ?u64 = null,
};

pub const ModelsListResult = struct {
    schema: []const u8 = "var1.models.v1",
    provider: []const u8,
    base_url: []const u8,
    models: []const ModelSummary,
    context_from_native_surface: bool = false,
    status: []const u8 = "ok",
    error_message: ?[]const u8 = null,
};

pub fn sessionStateLabel(state: types.SessionStatus) []const u8 {
    return types.statusLabel(state);
}

test "protocol capabilities advertise the full session surface" {
    const capabilities = Capabilities{};

    try std.testing.expect(capabilities.session_create);
    try std.testing.expect(capabilities.session_resume);
    try std.testing.expect(capabilities.session_send);
    try std.testing.expect(capabilities.session_compact);
    try std.testing.expect(capabilities.session_cancel);
    try std.testing.expect(capabilities.session_get);
    try std.testing.expect(capabilities.session_list);
    try std.testing.expect(capabilities.schedule_get);
    try std.testing.expect(capabilities.schedule_list);
    try std.testing.expect(capabilities.tools_list);
    try std.testing.expect(capabilities.events_subscribe);
    try std.testing.expect(capabilities.health_get);
    try std.testing.expect(capabilities.models_list);
    try std.testing.expect(capabilities.event_seq_supported);
}

test "session state labels stay stable" {
    try std.testing.expectEqualStrings("running", sessionStateLabel(.running));
    try std.testing.expectEqualStrings("cancelled", sessionStateLabel(.cancelled));
}
