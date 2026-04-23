const std = @import("std");
const docs_sync = @import("docs_sync.zig");
const provider = @import("provider.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

// TODO: Add compaction only when the tool-capable loop needs it.

pub const Error = error{
    MissingAssistantContent,
    StepLimitExceeded,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    onTaskInitializedFn: ?*const fn (ctx: ?*anyopaque, task_id: []const u8) anyerror!void = null,

    pub fn onTaskInitialized(self: Hooks, task_id: []const u8) !void {
        if (self.onTaskInitializedFn) |callback| {
            try callback(self.context, task_id);
        }
    }
};

pub const RunOptions = struct {
    transport: provider.Transport,
    execution_context: tools.ExecutionContext,
    task_id: ?[]const u8 = null,
    hooks: Hooks = .{},
};

pub fn runPrompt(allocator: std.mem.Allocator, config: types.Config, prompt: []const u8) !types.RunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = provider.httpSend,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    });
}

pub fn runPromptWithTransport(
    allocator: std.mem.Allocator,
    config: types.Config,
    prompt: []const u8,
    transport: provider.Transport,
) !types.RunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = transport,
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    });
}

pub fn runPromptWithOptions(
    allocator: std.mem.Allocator,
    config: types.Config,
    prompt: []const u8,
    options: RunOptions,
) !types.RunResult {
    try docs_sync.ensureRunStart(allocator, config.workspace_root);

    var task = if (options.task_id) |existing_task_id|
        try store.readTaskRecord(allocator, config.workspace_root, existing_task_id)
    else
        try store.initTask(allocator, config.workspace_root, prompt);
    defer task.deinit(allocator);

    const effective_prompt = task.prompt;

    if (options.task_id != null) {
        try store.setTaskStatus(allocator, config.workspace_root, &task, .running);
    }

    try options.hooks.onTaskInitialized(task.id);

    try store.appendJournal(allocator, config.workspace_root, task.id, .{
        .event_type = "task_started",
        .message = "Harness task initialized.",
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try docs_sync.writePending(allocator, config.workspace_root, .{
        .task_id = task.id,
        .status = types.statusLabel(task.status),
        .prompt = task.prompt,
        .answer = "",
        .updated_at_ms = task.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, config.workspace_root, "task started");

    var messages = std.array_list.Managed(types.ChatMessage).init(allocator);
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var execution_context = options.execution_context;
    execution_context.workspace_root = config.workspace_root;
    if (execution_context.parent_task_id == null) {
        execution_context.parent_task_id = task.id;
    }
    if (!execution_context.harness_tools_enabled and tools.harnessToolsRelevant(effective_prompt)) {
        execution_context.harness_tools_enabled = true;
    }

    const system_prompt = try tools.buildAgentSystemPrompt(allocator, execution_context);
    defer allocator.free(system_prompt);

    try messages.append(try types.initTextMessage(allocator, .system, system_prompt));
    appendConversationMessages(allocator, config.workspace_root, &messages, task) catch |err| {
        try failTask(allocator, config.workspace_root, &task, @errorName(err));
        return err;
    };

    var requires_child_supervision = false;
    var step: usize = 0;
    while (step < config.harness_max_steps) : (step += 1) {
        const completion = provider.completeWithTransport(allocator, config, .{
            .messages = messages.items,
            .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
        }, options.transport) catch |err| {
            try failTask(allocator, config.workspace_root, &task, @errorName(err));
            return err;
        };
        defer completion.deinit(allocator);

        if (completion.hasToolCalls()) {
            const summary = try tools.renderToolCallSummary(allocator, completion.tool_calls);
            defer allocator.free(summary);

            const request_log = try std.fmt.allocPrint(allocator, "tool requested: {s}", .{summary});
            defer allocator.free(request_log);

            try store.appendJournal(allocator, config.workspace_root, task.id, .{
                .event_type = "tool_requested",
                .message = request_log,
                .timestamp_ms = std.time.milliTimestamp(),
            });
            try docs_sync.appendLog(allocator, config.workspace_root, request_log);

            try messages.append(try types.initAssistantToolCallMessage(allocator, completion.content, completion.tool_calls));

            for (completion.tool_calls) |tool_call| {
                const tool_result = try executeToolCall(allocator, execution_context, tool_call);
                defer allocator.free(tool_result.output);
                defer allocator.free(tool_result.log_line);
                if (tool_result.launched_child) requires_child_supervision = true;

                try store.appendJournal(allocator, config.workspace_root, task.id, .{
                    .event_type = "tool_completed",
                    .message = tool_result.log_line,
                    .timestamp_ms = std.time.milliTimestamp(),
                });
                try docs_sync.appendLog(allocator, config.workspace_root, tool_result.log_line);
                try messages.append(try types.initToolMessage(allocator, tool_call.id, tool_result.output));
            }

            continue;
        }

        if (completion.content) |content| {
            if (requires_child_supervision) {
                const child_summary = childStatusSummary(allocator, execution_context) catch ChildStatusSummary{};
                if (child_summary.pending > 0) {
                    const waiting_message = "I will continue once agents complete; if any fail, I will follow up.";
                    try store.appendJournal(allocator, config.workspace_root, task.id, .{
                        .event_type = "task_waiting",
                        .message = waiting_message,
                        .timestamp_ms = std.time.milliTimestamp(),
                    });
                    const waiting_log = try std.fmt.allocPrint(allocator, "parent waiting on child agents: {d} pending", .{child_summary.pending});
                    defer allocator.free(waiting_log);
                    try docs_sync.appendLog(allocator, config.workspace_root, waiting_log);

                    try messages.append(try types.initTextMessage(allocator, .assistant, content));
                    const supervision_prompt = try std.fmt.allocPrint(
                        allocator,
                        "Supervision checkpoint: {d} child runs are still non-terminal. Continue supervising child runs internally until they finish or fail. Do not ask the operator to run status tools.",
                        .{child_summary.pending},
                    );
                    defer allocator.free(supervision_prompt);
                    try messages.append(try types.initTextMessage(allocator, .user, supervision_prompt));
                    continue;
                }

                if (child_summary.failed > 0 and !contentMentionsFailure(content)) {
                    try messages.append(try types.initTextMessage(allocator, .assistant, content));
                    const failure_prompt = try std.fmt.allocPrint(
                        allocator,
                        "Child supervision checkpoint: {d} child runs failed. Follow up clearly on those failures in your operator response.",
                        .{child_summary.failed},
                    );
                    defer allocator.free(failure_prompt);
                    try messages.append(try types.initTextMessage(allocator, .user, failure_prompt));
                    continue;
                }
                requires_child_supervision = false;
            }

            const final_content = try sanitizeOperatorResponse(allocator, effective_prompt, content);
            defer allocator.free(final_content);
            const final_timestamp = std.time.milliTimestamp();
            try store.appendJournal(allocator, config.workspace_root, task.id, .{
                .event_type = "assistant_response",
                .message = final_content,
                .timestamp_ms = final_timestamp,
            });
            try store.upsertAssistantConversationTurn(allocator, config.workspace_root, task.id, final_content, final_timestamp);
            try store.writeFinalAnswer(allocator, config.workspace_root, task.id, final_content);
            try store.setTaskStatus(allocator, config.workspace_root, &task, .completed);
            try docs_sync.completeTask(allocator, config.workspace_root, .{
                .task_id = task.id,
                .status = types.statusLabel(task.status),
                .prompt = task.prompt,
                .answer = final_content,
                .updated_at_ms = task.updated_at_ms,
            });
            try docs_sync.appendLog(allocator, config.workspace_root, "task completed");

            return .{
                .task_id = try allocator.dupe(u8, task.id),
                .answer = try allocator.dupe(u8, final_content),
            };
        }

        try failTask(allocator, config.workspace_root, &task, "MissingAssistantContent");
        return Error.MissingAssistantContent;
    }

    try failTask(allocator, config.workspace_root, &task, "StepLimitExceeded");
    return Error.StepLimitExceeded;
}

fn executeToolCall(
    allocator: std.mem.Allocator,
    execution_context: tools.ExecutionContext,
    tool_call: types.ToolCall,
) !struct { output: []u8, log_line: []u8, launched_child: bool } {
    const tool_output = tools.execute(allocator, execution_context, tool_call) catch |err| {
        const error_name = @errorName(err);
        const error_output = try tools.renderExecutionError(allocator, tool_call.name, error_name, tool_call.arguments_json);
        const error_log = if (tools.toolErrorHint(tool_call.name, error_name)) |hint|
            try std.fmt.allocPrint(allocator, "tool errored: {s} ({s}) - {s}", .{
                tools.toolCallLogLabel(tool_call.name),
                error_name,
                hint,
            })
        else
            try std.fmt.allocPrint(allocator, "tool errored: {s} ({s})", .{
                tools.toolCallLogLabel(tool_call.name),
                error_name,
            });
        return .{ .output = error_output, .log_line = error_log, .launched_child = false };
    };

    const success_log = try std.fmt.allocPrint(allocator, "tool completed: {s}", .{tools.toolCallLogLabel(tool_call.name)});
    return .{
        .output = tool_output,
        .log_line = success_log,
        .launched_child = std.mem.eql(u8, tool_call.name, "launch_agent"),
    };
}

const ChildStatusSummary = struct {
    pending: usize = 0,
    failed: usize = 0,
};

fn childStatusSummary(allocator: std.mem.Allocator, execution_context: tools.ExecutionContext) !ChildStatusSummary {
    const service = execution_context.agent_service orelse return .{};
    const parent_task_id = execution_context.parent_task_id orelse return .{};

    const listing = try service.list(allocator, parent_task_id);
    defer allocator.free(listing);

    if (std.mem.eql(u8, std.mem.trim(u8, listing, " \r\n"), "No child agents.")) return .{};

    var summary: ChildStatusSummary = .{};
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        const status_label = statusLabelFromListLine(line) orelse continue;
        if (!isTerminalStatusLabel(status_label)) {
            summary.pending += 1;
            continue;
        }
        if (std.mem.eql(u8, status_label, "failed")) {
            summary.failed += 1;
        }
    }

    return summary;
}

fn statusLabelFromListLine(line: []const u8) ?[]const u8 {
    const status_key = " STATUS ";
    const status_start = std.mem.indexOf(u8, line, status_key) orelse return null;
    const value_start = status_start + status_key.len;
    const remainder = line[value_start..];
    const value_end = std.mem.indexOfScalar(u8, remainder, ' ') orelse remainder.len;
    return remainder[0..value_end];
}

fn isTerminalStatusLabel(status_label: []const u8) bool {
    return std.mem.eql(u8, status_label, "completed") or std.mem.eql(u8, status_label, "failed");
}

fn contentMentionsFailure(content: []const u8) bool {
    const keywords = [_][]const u8{
        "fail",
        "failed",
        "failure",
        "errored",
        "error",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(content, keyword) != null) return true;
    }

    return false;
}

fn sanitizeOperatorResponse(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    content: []const u8,
) ![]u8 {
    if (promptRequestsToolDocumentation(prompt) or !contentLeaksInternalToolNames(content)) {
        return allocator.dupe(u8, content);
    }

    const redacted = try redactInternalToolNames(allocator, content);
    if (!contentLeaksInternalToolNames(redacted)) {
        return redacted;
    }

    allocator.free(redacted);
    return allocator.dupe(u8, "I completed the task and can provide an operator-safe summary.");
}

fn promptRequestsToolDocumentation(prompt: []const u8) bool {
    const keywords = [_][]const u8{
        "tool",
        "tools",
        "catalog",
        "launch_agent",
        "agent_status",
        "wait_agent",
        "list_agents",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(prompt, keyword) != null) return true;
    }

    return false;
}

fn contentLeaksInternalToolNames(content: []const u8) bool {
    const tool_names = [_][]const u8{
        "launch_agent",
        "agent_status",
        "wait_agent",
        "list_agents",
    };

    for (tool_names) |tool_name| {
        if (std.ascii.indexOfIgnoreCase(content, tool_name) != null) return true;
    }

    return false;
}

const ToolNameAlias = struct {
    internal_name: []const u8,
    public_phrase: []const u8,
};

fn redactInternalToolNames(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const aliases = [_]ToolNameAlias{
        .{ .internal_name = "launch_agent", .public_phrase = "child-run orchestration" },
        .{ .internal_name = "agent_status", .public_phrase = "child-run status checks" },
        .{ .internal_name = "wait_agent", .public_phrase = "child-run wait checks" },
        .{ .internal_name = "list_agents", .public_phrase = "child-run listing" },
    };

    var redacted = try allocator.dupe(u8, content);
    errdefer allocator.free(redacted);

    for (aliases) |alias| {
        const updated = try replaceAllIgnoreCaseOwned(allocator, redacted, alias.internal_name, alias.public_phrase);
        allocator.free(redacted);
        redacted = updated;
    }

    return redacted;
}

fn replaceAllIgnoreCaseOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, input);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    while (indexOfIgnoreCasePos(input, needle, cursor)) |match_index| {
        try output.appendSlice(input[cursor..match_index]);
        try output.appendSlice(replacement);
        cursor = match_index + needle.len;
    }

    try output.appendSlice(input[cursor..]);
    return output.toOwnedSlice();
}

fn indexOfIgnoreCasePos(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len) return null;

    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }

    return null;
}

fn failTask(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task: *types.TaskRecord,
    failure_reason: []const u8,
) !void {
    try store.appendJournal(allocator, workspace_root, task.id, .{
        .event_type = "task_failed",
        .message = failure_reason,
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try store.setTaskFailure(allocator, workspace_root, task, failure_reason);
    try docs_sync.writePending(allocator, workspace_root, .{
        .task_id = task.id,
        .status = types.statusLabel(task.status),
        .prompt = task.prompt,
        .answer = failure_reason,
        .updated_at_ms = task.updated_at_ms,
    });

    const log_line = try std.fmt.allocPrint(allocator, "task failed: {s}", .{failure_reason});
    defer allocator.free(log_line);
    try docs_sync.appendLog(allocator, workspace_root, log_line);
}

fn appendConversationMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    task: types.TaskRecord,
) !void {
    const turns = try store.readConversationTurns(allocator, workspace_root, task.id);
    defer types.deinitConversationTurns(allocator, turns);

    for (turns) |turn| {
        switch (turn.role) {
            .user => try messages.append(try types.initTextMessage(allocator, .user, turn.content)),
            .assistant => try messages.append(try types.initTextMessage(allocator, .assistant, turn.content)),
        }
    }
}
