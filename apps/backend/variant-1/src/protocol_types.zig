const std = @import("std");

pub const SessionState = enum {
    initialized,
    running,
    completed,
    failed,
    cancelled,
};

pub fn sessionStateLabel(state: SessionState) []const u8 {
    return switch (state) {
        .initialized => "initialized",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

pub const methods = struct {
    pub const initialize = "initialize";
    pub const session_create = "session/create";
    pub const session_send = "session/send";
    pub const session_get = "session/get";
    pub const session_cancel = "session/cancel";
    pub const health_get = "health/get";
    pub const tools_list = "tools/list";
};

pub const InitializeResult = struct {
    server_version: []const u8,
    capabilities: Capabilities,
};

pub const Capabilities = struct {
    session_create: bool = true,
    session_send: bool = true,
    session_get: bool = true,
    session_cancel: bool = true,
    health_get: bool = true,
    tools_list: bool = true,
};

pub const SessionCreateResult = struct {
    session_id: []const u8,
    state: []const u8,
};

pub const SessionSendResult = struct {
    session_id: []const u8,
    task_id: []const u8,
    state: []const u8,
    answer: []const u8,
};

pub const SessionGetResult = struct {
    session_id: []const u8,
    task_id: ?[]const u8 = null,
    state: []const u8,
    answer: ?[]const u8 = null,
    failure_reason: ?[]const u8 = null,
};

pub const SessionCancelResult = struct {
    session_id: []const u8,
    cancelled: bool,
    state: []const u8,
};

pub const HealthGetResult = struct {
    ok: bool,
    model: []const u8,
    workspace_root: []const u8,
    openai_base_url: []const u8,
};

pub const ToolsListResult = struct {
    format: []const u8,
    output: []const u8,
};

test "session state labels stay stable" {
    try std.testing.expectEqualStrings("running", sessionStateLabel(.running));
}
