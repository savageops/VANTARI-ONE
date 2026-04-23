const std = @import("std");

// TODO: Expand these types only when the runtime gains a new durable surface.

pub const Config = struct {
    openai_base_url: []u8,
    openai_api_key: []u8,
    openai_model: []u8,
    harness_max_steps: usize,
    workspace_root: []u8,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.openai_base_url);
        allocator.free(self.openai_api_key);
        allocator.free(self.openai_model);
        allocator.free(self.workspace_root);
    }
};

pub const TaskStatus = enum {
    pending,
    running,
    completed,
    failed,
};

pub const TaskRecord = struct {
    id: []u8,
    prompt: []u8,
    status: TaskStatus,
    parent_task_id: ?[]u8 = null,
    display_name: ?[]u8 = null,
    agent_profile: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: TaskRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.prompt);
        if (self.parent_task_id) |value| allocator.free(value);
        if (self.display_name) |value| allocator.free(value);
        if (self.agent_profile) |value| allocator.free(value);
        if (self.failure_reason) |value| allocator.free(value);
    }
};

pub const ProgressSnapshot = struct {
    task_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    answer: []const u8,
    updated_at_ms: i64,
};

pub const JournalEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,

    pub fn deinit(self: JournalEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.message);
    }
};

pub fn deinitTaskRecords(allocator: std.mem.Allocator, tasks: []TaskRecord) void {
    for (tasks) |task| task.deinit(allocator);
    allocator.free(tasks);
}

pub fn deinitJournalEvents(allocator: std.mem.Allocator, events: []JournalEvent) void {
    for (events) |event| event.deinit(allocator);
    allocator.free(events);
}

pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ConversationTurnRole = enum {
    user,
    assistant,
};

pub const ConversationTurn = struct {
    role: ConversationTurnRole,
    content: []u8,
    timestamp_ms: i64,

    pub fn deinit(self: ConversationTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub fn deinitConversationTurns(allocator: std.mem.Allocator, turns: []ConversationTurn) void {
    for (turns) |turn| turn.deinit(allocator);
    allocator.free(turns);
}

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    example_json: ?[]const u8 = null,
    usage_hint: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
    }
};

pub const ChatMessage = struct {
    role: MessageRole,
    content: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},

    pub fn deinit(self: ChatMessage, allocator: std.mem.Allocator) void {
        if (self.content) |value| allocator.free(value);
        if (self.tool_call_id) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }
};

pub const CompletionRequest = struct {
    messages: []const ChatMessage,
    tool_definitions: []const ToolDefinition = &.{},
};

pub const CompletionResponse = struct {
    model: []u8,
    content: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},

    pub fn deinit(self: CompletionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        if (self.content) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
    }

    pub fn hasToolCalls(self: CompletionResponse) bool {
        return self.tool_calls.len > 0;
    }
};

pub const RunResult = struct {
    task_id: []u8,
    answer: []u8,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.answer);
    }
};

pub fn statusLabel(status: TaskStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
    };
}

pub fn parseStatusLabel(label: []const u8) !TaskStatus {
    if (std.mem.eql(u8, label, "pending")) return .pending;
    if (std.mem.eql(u8, label, "running")) return .running;
    if (std.mem.eql(u8, label, "completed")) return .completed;
    if (std.mem.eql(u8, label, "failed")) return .failed;
    return error.InvalidStatus;
}

pub fn roleLabel(role: MessageRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn conversationTurnRoleLabel(role: ConversationTurnRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
    };
}

pub fn parseConversationTurnRole(label: []const u8) !ConversationTurnRole {
    if (std.mem.eql(u8, label, "user")) return .user;
    if (std.mem.eql(u8, label, "assistant")) return .assistant;
    return error.InvalidConversationTurnRole;
}

pub fn initTextMessage(
    allocator: std.mem.Allocator,
    role: MessageRole,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = role,
        .content = try allocator.dupe(u8, text),
    };
}

pub fn initToolMessage(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = .tool,
        .content = try allocator.dupe(u8, text),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
    };
}

pub fn initAssistantToolCallMessage(
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: []const ToolCall,
) !ChatMessage {
    return .{
        .role = .assistant,
        .content = if (content) |value| try allocator.dupe(u8, value) else null,
        .tool_calls = try cloneToolCalls(allocator, tool_calls),
    };
}

pub fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ToolCall) ![]ToolCall {
    if (tool_calls.len == 0) return &.{};

    var owned_calls = try allocator.alloc(ToolCall, tool_calls.len);
    errdefer allocator.free(owned_calls);

    for (tool_calls, 0..) |tool_call, index| {
        owned_calls[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments_json = try allocator.dupe(u8, tool_call.arguments_json),
        };
    }

    return owned_calls;
}

test "status labels stay stable" {
    try std.testing.expectEqualStrings("completed", statusLabel(.completed));
}

test "status labels round-trip" {
    try std.testing.expectEqual(TaskStatus.running, try parseStatusLabel("running"));
}

test "role labels stay stable" {
    try std.testing.expectEqualStrings("tool", roleLabel(.tool));
}
