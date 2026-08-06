const std = @import("std");
const docs_sync = @import("../docs/sync.zig");
const context_builder = @import("../context/index.zig");
const context_stream_rules = @import("../context/stream_rules.zig");
const prompts = @import("../prompts/index.zig");
const provider = @import("../providers/openai_compatible.zig");
const dispatch = @import("../providers/dispatch.zig");
const store = @import("../sessions/store.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    Cancelled,
    ContextWindowExceeded,
    MissingAssistantContent,
    StepLimitExceeded,
    ToolBudgetExceeded,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    onSessionInitializedFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!void = null,
    onSessionEventFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,
    shouldCancelFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) bool = null,

    pub fn onSessionInitialized(self: Hooks, session_id: []const u8) !void {
        if (self.onSessionInitializedFn) |callback| {
            try callback(self.context, session_id);
        }
    }

    pub fn onSessionEvent(
        self: Hooks,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.onSessionEventFn) |callback| {
            try callback(self.context, session_id, event_type, message, status, timestamp_ms);
        }
    }

    pub fn shouldCancel(self: Hooks, session_id: []const u8) bool {
        if (self.shouldCancelFn) |callback| {
            return callback(self.context, session_id);
        }
        return false;
    }
};

pub const RunOptions = struct {
    transport: provider.Transport,
    execution_context: tools.ExecutionContext,
    session_id: ?[]const u8 = null,
    hooks: Hooks = .{},
};

pub fn runPrompt(allocator: std.mem.Allocator, config: types.Config, prompt: []const u8) !types.SessionRunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
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
) !types.SessionRunResult {
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
) !types.SessionRunResult {
    try store.ensureStoreReady(allocator, config.workspace_root);
    try docs_sync.ensureRunStart(allocator, config.workspace_root);

    var session = if (options.session_id) |existing_session_id|
        try store.readSessionRecord(allocator, config.workspace_root, existing_session_id)
    else
        try store.initSession(allocator, config.workspace_root, prompt);
    defer session.deinit(allocator);

    if (session.status == .cancelled) return Error.Cancelled;

    try store.setSessionStatus(allocator, config.workspace_root, &session, .running);
    try options.hooks.onSessionInitialized(session.id);
    try recordSessionEvent(
        allocator,
        config.workspace_root,
        options.hooks,
        session.id,
        "session_started",
        "VAR1 session initialized.",
        session.status,
    );
    try docs_sync.writePending(allocator, config.workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = "",
        .updated_at_ms = session.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, config.workspace_root, "session started");

    var messages = std.array_list.Managed(types.ChatMessage).init(allocator);
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var execution_context = options.execution_context;
    execution_context.workspace_root = config.workspace_root;
    execution_context.memory_policy = config.memory_policy;
    if (execution_context.parent_session_id == null) {
        execution_context.parent_session_id = session.id;
    }
    var file_inspection_ledger = tools.FileInspectionLedger.init(allocator);
    defer file_inspection_ledger.deinit();
    execution_context.file_inspection_ledger = &file_inspection_ledger;
    var tool_delta_context = ToolDeltaContext{
        .allocator = allocator,
        .workspace_root = config.workspace_root,
        .hooks = options.hooks,
        .session_id = session.id,
        .status = session.status,
    };
    execution_context.tool_events = .{
        .context = &tool_delta_context,
        .onOutputDeltaFn = onToolOutputDelta,
    };
    if (!execution_context.workspace_state_enabled and tools.workspaceStateRelevant(session.prompt)) {
        execution_context.workspace_state_enabled = true;
    }

    var base_message_count = rebuildProviderBaseMessages(
        allocator,
        config,
        execution_context,
        session,
        &messages,
        0,
    ) catch |err| {
        try failSession(allocator, config.workspace_root, options.hooks, &session, provider.failureDiagnosticForError(err));
        return err;
    };

    var requires_child_supervision = false;
    var executed_tool_calls: usize = 0;
    var provider_retries: u8 = 0;
    const max_provider_retries: u8 = 3;

    // Per-turn scoped arena (roadmap P1-15). Reset after each step to bound
    // memory growth across a long session. The arena scopes ephemeral
    // allocations: system prompt build, checkpoint reads, context compilation.
    // The persistent message list uses the parent allocator and survives resets.
    var turn_arena = @import("../memory/scopes.zig").ScopedArena.init(
        .turn, allocator, @import("../memory/scopes.zig").defaultQuota(.turn),
    );
    defer turn_arena.deinit();

    var step: usize = 0;
    while (step < config.max_steps) : (step += 1) {
        // Reset the turn arena at the start of each step — all ephemeral
        // allocations from the previous turn are freed in one operation.
        turn_arena.reset();
        if (options.hooks.shouldCancel(session.id)) {
            try cancelSession(allocator, config.workspace_root, options.hooks, &session, "Cancellation requested.");
            return Error.Cancelled;
        }

        // Typed turn ingress evidence: every provider turn starts with a
        // turn_started event carrying the step boundary and measured token
        // telemetry (AGENTS.md §IV, roadmap P0-2b). The message is allocated
        // on the parent allocator (not the turn arena) because it is persisted
        // to the event spine before this scope returns; free it immediately
        // after recordSessionEvent serializes it into the durable ledger.
        {
            const boundary_msg = turnBoundaryMessage(allocator, step, messages) catch "Provider turn started.";
            const owns_boundary = boundary_msg.ptr != "Provider turn started.".ptr;
            try recordSessionEvent(
                allocator,
                config.workspace_root,
                options.hooks,
                session.id,
                "turn_started",
                boundary_msg,
                session.status,
            );
            if (owns_boundary) allocator.free(boundary_msg);
        }

        base_message_count = ensureContextWithinBudget(
            allocator,
            config,
            options.hooks,
            execution_context,
            session,
            &messages,
            base_message_count,
        ) catch |err| {
            try failSession(allocator, config.workspace_root, options.hooks, &session, provider.failureDiagnosticForError(err));
            return err;
        };

        // Provider call with resilience: any provider failure (timeout, bad
        // status, malformed response, empty content) is retried with a nudge
        // rather than bricking the session. The loop is the sole authority
        // on session termination — a bad turn is overwritten by the next turn.
        // Only truly unrecoverable states (step limit, cancellation, context
        // overflow that can't compact) escape this block.
        const completion = completeWithContextRecovery(
            allocator,
            config,
            options.hooks,
            execution_context,
            session,
            &messages,
            &base_message_count,
            options.transport,
        ) catch |err| {
            // Connection-level failures are genuinely unrecoverable — the
            // server is unreachable. Propagate immediately.
            if (err == error.ConnectionRefused or
                err == error.NetworkUnreachable or
                err == error.ConnectionTimedOut)
            {
                try failSession(allocator, config.workspace_root, options.hooks, &session, provider.failureDiagnosticForError(err));
                return err;
            }
            // ContextWindowExceeded is NOT terminal — it triggers the
            // compaction lane inside completeWithContextRecovery. If that
            // recovery succeeds, we never see this error. If it fails,
            // we fall through to the provider-retry path below and try
            // again after compaction. Context overflow is always recoverable.
            //
            // Response-level errors (BadStatus, MalformedHttpResponse,
            // MissingContent, streaming parse errors) are transient. The
            // server is reachable but returned something broken. Retry
            // with a nudge — the next provider turn overwrites this
            // failure as if it never existed. The session never bricks
            // from a single bad response.
            const diag = provider.failureDiagnosticForError(err);
            try recordSessionEvent(
                allocator,
                config.workspace_root,
                options.hooks,
                session.id,
                "provider_turn_recovered",
                diag,
                session.status,
            );
            provider_retries += 1;
            if (provider_retries >= max_provider_retries) {
                try failSession(allocator, config.workspace_root, options.hooks, &session, diag);
                return err;
            }
            // Brief backoff before retry
            std.Thread.sleep(@as(u64, @intCast(provider_retries)) * 500 * std.time.ns_per_ms);
            const nudge = try std.fmt.allocPrint(allocator, "Previous request failed ({s}). Please continue with the task.", .{@errorName(err)});
            defer allocator.free(nudge);
            try messages.append(try types.initTextMessage(allocator, .user, nudge));
            continue;
        };
        defer completion.deinit(allocator);
        provider_retries = 0; // reset on success

        if (completion.hasToolCalls()) {
            const session_budget_exceeded = completion.tool_calls.len > config.max_tool_calls_per_session or
                executed_tool_calls > config.max_tool_calls_per_session - completion.tool_calls.len;
            if (completion.tool_calls.len > config.max_tool_calls_per_turn or
                session_budget_exceeded)
            {
                const budget_message = try std.fmt.allocPrint(
                    allocator,
                    "tool budget exceeded: requested={d} turn_limit={d} session_used={d} session_limit={d}",
                    .{
                        completion.tool_calls.len,
                        config.max_tool_calls_per_turn,
                        executed_tool_calls,
                        config.max_tool_calls_per_session,
                    },
                );
                defer allocator.free(budget_message);
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_budget_exceeded",
                    budget_message,
                    session.status,
                );
                try docs_sync.appendLog(allocator, config.workspace_root, budget_message);
                try failSession(allocator, config.workspace_root, options.hooks, &session, @errorName(Error.ToolBudgetExceeded));
                return Error.ToolBudgetExceeded;
            }

            executed_tool_calls += completion.tool_calls.len;

            const summary = try tools.renderToolCallSummary(allocator, completion.tool_calls);
            defer allocator.free(summary);

            const request_log = try std.fmt.allocPrint(allocator, "tool requested: {s}", .{summary});
            defer allocator.free(request_log);
            try recordSessionEvent(
                allocator,
                config.workspace_root,
                options.hooks,
                session.id,
                "tool_requested",
                request_log,
                session.status,
            );
            try docs_sync.appendLog(allocator, config.workspace_root, request_log);

            const tool_request_timestamp = std.time.milliTimestamp();
            try messages.append(try types.initAssistantToolCallMessage(allocator, completion.content, completion.tool_calls));
            try store.appendAssistantToolCallSessionMessage(
                allocator,
                config.workspace_root,
                session.id,
                completion.content,
                completion.tool_calls,
                completion.reasoning,
                tool_request_timestamp,
            );

            for (completion.tool_calls) |tool_call| {
                if (options.hooks.shouldCancel(session.id)) {
                    try cancelSession(allocator, config.workspace_root, options.hooks, &session, "Cancellation requested.");
                    return Error.Cancelled;
                }

                const active_tool_definitions = tools.builtinDefinitionsForContext(execution_context);
                const review_decision = tools.review.reviewToolCall(tool_call, active_tool_definitions);
                const review_event = try tools.review.renderReviewEvent(allocator, tool_call, review_decision);
                defer allocator.free(review_event);
                const review_log = try tools.review.renderReviewLog(allocator, tool_call, review_decision);
                defer allocator.free(review_log);
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_reviewed",
                    review_event,
                    session.status,
                );
                try docs_sync.appendLog(allocator, config.workspace_root, review_log);

                if (!review_decision.approved) {
                    const blocked_output = try tools.review.renderBlockedToolResult(allocator, tool_call, review_decision);
                    defer allocator.free(blocked_output);
                    const blocked_log = try std.fmt.allocPrint(allocator, "tool blocked: {s} risk={s}", .{
                        tool_call.name,
                        tools.review.riskLabel(review_decision.risk),
                    });
                    defer allocator.free(blocked_log);
                    try recordSessionEvent(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        session.id,
                        "tool_blocked",
                        review_event,
                        session.status,
                    );
                    try docs_sync.appendLog(allocator, config.workspace_root, blocked_log);
                    try messages.append(try types.initToolMessage(allocator, tool_call.id, blocked_output));
                    try store.appendToolSessionMessage(
                        allocator,
                        config.workspace_root,
                        session.id,
                        tool_call.id,
                        blocked_output,
                        std.time.milliTimestamp(),
                    );
                    continue;
                }

                const tool_started_at_ms = std.time.milliTimestamp();
                const tool_started_event = try renderToolStartedEvent(allocator, tool_call, tool_started_at_ms);
                defer allocator.free(tool_started_event);
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_started",
                    tool_started_event,
                    session.status,
                );

                const tool_result = try executeToolCall(allocator, execution_context, tool_call);
                defer allocator.free(tool_result.output);
                defer allocator.free(tool_result.log_line);
                if (tool_result.launched_child) requires_child_supervision = true;

                const tool_finished_at_ms = std.time.milliTimestamp();
                const tool_finished_event = try renderToolFinishedEvent(
                    allocator,
                    tool_call,
                    tool_result.ok,
                    tool_result.error_name,
                    tool_started_at_ms,
                    tool_finished_at_ms,
                );
                defer allocator.free(tool_finished_event);
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_finished",
                    tool_finished_event,
                    session.status,
                );

                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_completed",
                    tool_result.log_line,
                    session.status,
                );
                try docs_sync.appendLog(allocator, config.workspace_root, tool_result.log_line);
                try messages.append(try types.initToolMessage(allocator, tool_call.id, tool_result.output));
                try store.appendToolSessionMessage(
                    allocator,
                    config.workspace_root,
                    session.id,
                    tool_call.id,
                    tool_result.output,
                    std.time.milliTimestamp(),
                );
            }

            base_message_count = messages.items.len;
            continue;
        }

        if (completion.content) |content| {
            if (requires_child_supervision) {
                const child_summary = childStatusSummary(allocator, execution_context) catch ChildStatusSummary{};
                if (child_summary.pending > 0) {
                    const waiting_message = "I will continue once agents complete; if any fail, I will follow up.";
                    try recordSessionEvent(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        session.id,
                        "session_waiting",
                        waiting_message,
                        session.status,
                    );
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
                // All children are terminal — converge their outputs into the
                // parent transcript. This writes a `converged` shard checkpoint
                // + merged assistant message to the parent's ledgers. The
                // merged result becomes part of the context the provider sees
                // when synthesizing the final response below. (roadmap P0-2)
                if (execution_context.agent_service) |agent_service| {
                    agent_service.converge(allocator, session.id) catch |err| {
                        const converge_warn = std.fmt.allocPrint(allocator, "branch convergence failed: {s}", .{@errorName(err)}) catch "branch convergence failed";
                        defer allocator.free(converge_warn);
                        docs_sync.appendLog(allocator, config.workspace_root, converge_warn) catch {};
                    };
                    // Rebuild the message list so the convergence summary is
                    // visible in the provider's context window for the final
                    // synthesis turn. The convergence appended a new assistant
                    // message to the transcript — the context builder will pick
                    // it up from first_kept_seq on the next compilation.
                }
                requires_child_supervision = false;
            }

            const final_output = try sanitizeOperatorResponse(allocator, session.prompt, content);
            defer allocator.free(final_output);

            const final_timestamp = std.time.milliTimestamp();
            try store.upsertAssistantSessionMessageWithReasoning(allocator, config.workspace_root, session.id, final_output, completion.reasoning, final_timestamp);
            try store.writeOutput(allocator, config.workspace_root, session.id, final_output);
            try store.setSessionStatus(allocator, config.workspace_root, &session, .completed);
            try store.appendEvent(allocator, config.workspace_root, session.id, .{
                .event_type = "assistant_response",
                .message = final_output,
                .timestamp_ms = final_timestamp,
            });
            // Typed turn terminal evidence: every completed turn emits
            // turn_finished with measured token telemetry (AGENTS.md §IV, P0-3a).
            // Same ownership pattern as turn_started: allocate, persist, free.
            {
                const finished_msg = turnFinishedMessage(allocator, step, messages, final_output.len) catch "Provider turn completed.";
                const owns_finished = finished_msg.ptr != "Provider turn completed.".ptr;
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "turn_finished",
                    finished_msg,
                    session.status,
                );
                if (owns_finished) allocator.free(finished_msg);
            }
            // Force the final durability flush — the batched sync gate in
            // appendJsonlRecord skips most per-event flushes for streaming
            // speed; the terminal assistant response must be durable before
            // the RPC returns (AGENTS.md §II durability gate at boundaries).
            store.syncSessionLedgers(allocator, config.workspace_root, session.id) catch {};
            try options.hooks.onSessionEvent(
                session.id,
                "assistant_response",
                final_output,
                types.statusLabel(session.status),
                final_timestamp,
            );
            try docs_sync.completeSession(allocator, config.workspace_root, .{
                .session_id = session.id,
                .status = types.statusLabel(session.status),
                .prompt = session.prompt,
                .output = final_output,
                .updated_at_ms = session.updated_at_ms,
            });
            try docs_sync.appendLog(allocator, config.workspace_root, "session completed");

            return .{
                .session_id = try allocator.dupe(u8, session.id),
                .output = try allocator.dupe(u8, final_output),
            };
        }

        // Self-healing: if we reach here, the model returned no content and
        // no tool calls (empty response). This is handled by the provider-
        // resilience block above — but if the completion succeeded with null
        // content and no tool calls, we still need to handle it gracefully.
        // The provider-resilience retry covers BadStatus/network errors;
        // a structurally empty success response means the model is done or
        // confused. Treat it as a completion with a minimal default rather
        // than bricking the session.
        const final_output = "Session completed with no final output from the assistant.";

        const final_timestamp = std.time.milliTimestamp();
        try store.upsertAssistantSessionMessage(allocator, config.workspace_root, session.id, final_output, final_timestamp);
        try store.writeOutput(allocator, config.workspace_root, session.id, final_output);
        try store.setSessionStatus(allocator, config.workspace_root, &session, .completed);
        try store.appendEvent(allocator, config.workspace_root, session.id, .{
            .event_type = "assistant_response",
            .message = final_output,
            .timestamp_ms = final_timestamp,
        });
        try options.hooks.onSessionEvent(
            session.id,
            "assistant_response",
            final_output,
            types.statusLabel(session.status),
            final_timestamp,
        );
        try docs_sync.completeSession(allocator, config.workspace_root, .{
            .session_id = session.id,
            .status = types.statusLabel(session.status),
            .prompt = session.prompt,
            .output = final_output,
            .updated_at_ms = session.updated_at_ms,
        });

        return .{
            .session_id = try allocator.dupe(u8, session.id),
            .output = try allocator.dupe(u8, final_output),
        };
    }

    try failSession(allocator, config.workspace_root, options.hooks, &session, "StepLimitExceeded");
    return Error.StepLimitExceeded;
}

fn rebuildProviderBaseMessages(
    allocator: std.mem.Allocator,
    config: types.Config,
    execution_context: tools.ExecutionContext,
    session: types.SessionRecord,
    messages: *std.array_list.Managed(types.ChatMessage),
    preserve_from_index: usize,
) !usize {
    const preserve_start = @min(preserve_from_index, messages.items.len);
    var preserved = std.array_list.Managed(types.ChatMessage).init(allocator);
    errdefer {
        for (preserved.items) |message| message.deinit(allocator);
        preserved.deinit();
    }

    for (messages.items[preserve_start..]) |message| {
        try preserved.append(try cloneChatMessage(allocator, message));
    }

    for (messages.items) |message| message.deinit(allocator);
    messages.clearRetainingCapacity();

    const system_prompt = try prompts.buildAgentSystemPromptWithMemory(
        allocator,
        execution_context,
        config.prompt_policy,
        config.memory_policy,
        session.prompt,
    );
    defer allocator.free(system_prompt);

    try messages.append(try types.initTextMessage(allocator, .system, system_prompt));
    try context_builder.appendProviderMessages(allocator, config.workspace_root, messages, session);

    const base_message_count = messages.items.len;
    try messages.appendSlice(preserved.items);
    preserved.clearRetainingCapacity();
    preserved.deinit();

    return base_message_count;
}

fn cloneChatMessage(allocator: std.mem.Allocator, message: types.ChatMessage) !types.ChatMessage {
    var cloned = types.ChatMessage{
        .role = message.role,
    };
    errdefer cloned.deinit(allocator);

    cloned.content = if (message.content) |content| try allocator.dupe(u8, content) else null;
    cloned.tool_call_id = if (message.tool_call_id) |tool_call_id| try allocator.dupe(u8, tool_call_id) else null;
    cloned.tool_calls = try types.cloneToolCalls(allocator, message.tool_calls);
    cloned.reasoning = if (message.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null;
    return cloned;
}

fn ensureContextWithinBudget(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: Hooks,
    execution_context: tools.ExecutionContext,
    session: types.SessionRecord,
    messages: *std.array_list.Managed(types.ChatMessage),
    base_message_count: usize,
) !usize {
    const estimate = context_builder.budget.estimateChatMessages(messages.items);
    if (!context_builder.budget.shouldCompact(estimate, config.context_policy)) return base_message_count;

    const compacted = try compactSessionForRuntime(
        allocator,
        config,
        hooks,
        session,
        "auto_threshold",
        estimate,
    );
    if (!compacted) return base_message_count;

    return rebuildProviderBaseMessages(
        allocator,
        config,
        execution_context,
        session,
        messages,
        base_message_count,
    );
}

fn completeWithContextRecovery(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: Hooks,
    execution_context: tools.ExecutionContext,
    session: types.SessionRecord,
    messages: *std.array_list.Managed(types.ChatMessage),
    base_message_count: *usize,
    transport: provider.Transport,
) !types.CompletionResponse {
    var stream_context = ProviderDeltaContext{
        .allocator = allocator,
        .workspace_root = config.workspace_root,
        .hooks = hooks,
        .session_id = session.id,
        .status = session.status,
    };
    const stream_hooks = provider.StreamHooks{
        .context = &stream_context,
        .onAssistantDeltaFn = onProviderAssistantDelta,
        .onReasoningDeltaFn = onProviderReasoningDelta,
    };

    defer stream_context.deinitAccumulators();

    const completion = dispatch.completeWithTransportAndHooks(allocator, config, .{
        .messages = messages.items,
        .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
    }, transport, stream_hooks) catch |err| {
        if (err != error.ContextWindowExceeded or !config.context_policy.retry_on_provider_overflow) return err;

        const estimate = context_builder.budget.estimateChatMessages(messages.items);
        const compacted = try compactSessionForRuntime(
            allocator,
            config,
            hooks,
            session,
            "provider_overflow",
            estimate,
        );
        if (!compacted) return err;

        base_message_count.* = try rebuildProviderBaseMessages(
            allocator,
            config,
            execution_context,
            session,
            messages,
            base_message_count.*,
        );

        return dispatch.completeWithTransportAndHooks(allocator, config, .{
            .messages = messages.items,
            .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
        }, transport, stream_hooks);
    };

    // Stream-rule (TTSR) post-completion check: if a rule fired during
    // streaming, emit the rule_injected event and add the correction message
    // to the context for the next turn. The model sees its mistake was caught
    // and the rule's guidance, then retries on the next loop iteration.
    if (stream_context.rule_abort_requested) {
        if (stream_context.rule_match) |match| {
            const injection_msg = context_stream_rules.formatInjectionMessage(allocator, match) catch {
                return completion;
            };
            defer allocator.free(injection_msg);

            try recordSessionEvent(
                allocator,
                config.workspace_root,
                hooks,
                session.id,
                "rule_injected",
                injection_msg,
                session.status,
            );

            try messages.append(try types.initTextMessage(allocator, .user, injection_msg));
        }
    }

    return completion;
}

const ProviderDeltaContext = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session_id: []const u8,
    status: types.SessionStatus,
    /// Accumulated visible text for stream-rule checking.
    text_accumulator: std.array_list.Managed(u8) = undefined,
    /// Accumulated reasoning text for stream-rule checking.
    reasoning_accumulator: std.array_list.Managed(u8) = undefined,
    /// Set to true when a stream rule fires — the provider call should abort.
    rule_abort_requested: bool = false,
    /// The rule match that triggered the abort (if any).
    rule_match: ?context_stream_rules.RuleMatch = null,
    /// Whether the accumulators are initialized.
    accumulators_init: bool = false,

    fn initAccumulators(self: *ProviderDeltaContext) void {
        if (self.accumulators_init) return;
        self.text_accumulator = std.array_list.Managed(u8).init(self.allocator);
        self.reasoning_accumulator = std.array_list.Managed(u8).init(self.allocator);
        self.accumulators_init = true;
    }

    fn deinitAccumulators(self: *ProviderDeltaContext) void {
        if (!self.accumulators_init) return;
        self.text_accumulator.deinit();
        self.reasoning_accumulator.deinit();
    }
};

fn onProviderAssistantDelta(ctx: ?*anyopaque, delta: []const u8) !void {
    const delta_context: *ProviderDeltaContext = @ptrCast(@alignCast(ctx.?));
    try recordSessionEvent(
        delta_context.allocator,
        delta_context.workspace_root,
        delta_context.hooks,
        delta_context.session_id,
        "assistant_delta",
        delta,
        delta_context.status,
    );

    // Stream-rule checking: accumulate visible text and check against rules.
    // If a rule fires, set the abort flag so the provider call terminates
    // and the executor retries with the injected correction.
    delta_context.initAccumulators();
    delta_context.text_accumulator.appendSlice(delta) catch return;

    if (!delta_context.rule_abort_requested) {
        const match = context_stream_rules.checkRules(
            delta_context.allocator,
            &context_stream_rules.builtin_rules,
            delta_context.text_accumulator.items,
            delta_context.reasoning_accumulator.items,
        ) catch null;
        if (match) |m| {
            delta_context.rule_abort_requested = true;
            delta_context.rule_match = m;
        }
    }
}

fn onProviderReasoningDelta(ctx: ?*anyopaque, delta: []const u8) !void {
    const delta_context: *ProviderDeltaContext = @ptrCast(@alignCast(ctx.?));
    try recordSessionEvent(
        delta_context.allocator,
        delta_context.workspace_root,
        delta_context.hooks,
        delta_context.session_id,
        "reasoning_delta",
        delta,
        delta_context.status,
    );

    // Stream-rule checking on reasoning trace (same as visible text).
    delta_context.initAccumulators();
    delta_context.reasoning_accumulator.appendSlice(delta) catch return;

    if (!delta_context.rule_abort_requested) {
        const match = context_stream_rules.checkRules(
            delta_context.allocator,
            &context_stream_rules.builtin_rules,
            delta_context.text_accumulator.items,
            delta_context.reasoning_accumulator.items,
        ) catch null;
        if (match) |m| {
            delta_context.rule_abort_requested = true;
            delta_context.rule_match = m;
        }
    }
}

const ToolDeltaContext = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session_id: []const u8,
    status: types.SessionStatus,
};

fn onToolOutputDelta(
    ctx: ?*anyopaque,
    tool_call_id: []const u8,
    tool_name: []const u8,
    stream: tools.CommandOutputStream,
    chunk: []const u8,
    cap_reached: bool,
) !void {
    const delta_context: *ToolDeltaContext = @ptrCast(@alignCast(ctx.?));
    const message = try renderToolOutputDelta(
        delta_context.allocator,
        tool_call_id,
        tool_name,
        streamLabel(stream),
        chunk,
        cap_reached,
    );
    defer delta_context.allocator.free(message);

    try recordSessionEvent(
        delta_context.allocator,
        delta_context.workspace_root,
        delta_context.hooks,
        delta_context.session_id,
        "tool_output_delta",
        message,
        delta_context.status,
    );
}

fn renderToolOutputDelta(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    tool_name: []const u8,
    stream: []const u8,
    chunk: []const u8,
    cap_reached: bool,
) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, chunk);

    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.tool_output_delta.v1\",\"tool_call_id\":{f},\"tool\":{f},\"stream\":{f},\"chunk_b64\":{f},\"cap_reached\":{s}}}",
        .{
            std.json.fmt(tool_call_id, .{}),
            std.json.fmt(tool_name, .{}),
            std.json.fmt(stream, .{}),
            std.json.fmt(encoded, .{}),
            if (cap_reached) "true" else "false",
        },
    );
}

fn streamLabel(stream: tools.CommandOutputStream) []const u8 {
    return switch (stream) {
        .stdout => "stdout",
        .stderr => "stderr",
    };
}

fn renderToolStartedEvent(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    timestamp_ms: i64,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.tool_started.v1\",\"tool_call_id\":{f},\"tool\":{f},\"timestamp_ms\":{d}}}",
        .{
            std.json.fmt(tool_call.id, .{}),
            std.json.fmt(tool_call.name, .{}),
            timestamp_ms,
        },
    );
}

/// Typed turn boundary message carrying the step index and measured token
/// telemetry. Every provider turn emits turn_started with this payload so
/// the event spine has per-turn ingress evidence AND token cost evidence
/// (AGENTS.md §IV, roadmap P0-2b).
fn turnBoundaryMessage(
    allocator: std.mem.Allocator,
    step: usize,
    messages: std.array_list.Managed(types.ChatMessage),
) ![]u8 {
    const window_tokens = context_builder.budget.estimateChatMessages(messages.items);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.turn_started.v1\",\"step\":{d},\"window_tokens\":{d}}}",
        .{ step, window_tokens },
    );
}

/// Typed turn terminal message carrying the step index, window token count,
/// and output byte count. Closes the turn lifecycle with measured evidence
/// (AGENTS.md §IV, roadmap P0-3a).
fn turnFinishedMessage(
    allocator: std.mem.Allocator,
    step: usize,
    messages: std.array_list.Managed(types.ChatMessage),
    output_bytes: usize,
) ![]u8 {
    const window_tokens = context_builder.budget.estimateChatMessages(messages.items);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.turn_finished.v1\",\"step\":{d},\"window_tokens\":{d},\"output_bytes\":{d}}}",
        .{ step, window_tokens, output_bytes },
    );
}

fn renderToolFinishedEvent(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    ok: bool,
    error_name: ?[]const u8,
    started_at_ms: i64,
    finished_at_ms: i64,
) ![]u8 {
    const duration_ms: i64 = @max(@as(i64, 0), finished_at_ms - started_at_ms);
    if (error_name) |name| {
        if (tools.toolErrorHint(tool_call.name, name)) |hint| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"schema\":\"var1.tool_finished.v1\",\"tool_call_id\":{f},\"tool\":{f},\"ok\":{s},\"error_name\":{f},\"duration_ms\":{d},\"hint\":{f}}}",
                .{
                    std.json.fmt(tool_call.id, .{}),
                    std.json.fmt(tool_call.name, .{}),
                    if (ok) "true" else "false",
                    std.json.fmt(name, .{}),
                    duration_ms,
                    std.json.fmt(hint, .{}),
                },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"var1.tool_finished.v1\",\"tool_call_id\":{f},\"tool\":{f},\"ok\":{s},\"error_name\":{f},\"duration_ms\":{d}}}",
            .{
                std.json.fmt(tool_call.id, .{}),
                std.json.fmt(tool_call.name, .{}),
                if (ok) "true" else "false",
                std.json.fmt(name, .{}),
                duration_ms,
            },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.tool_finished.v1\",\"tool_call_id\":{f},\"tool\":{f},\"ok\":{s},\"duration_ms\":{d}}}",
        .{
            std.json.fmt(tool_call.id, .{}),
            std.json.fmt(tool_call.name, .{}),
            if (ok) "true" else "false",
            duration_ms,
        },
    );
}

test "tool finished schema errors carry actionable typed repair hints" {
    const allocator = std.testing.allocator;
    var tool_call = types.ToolCall{
        .id = try allocator.dupe(u8, "call_schema"),
        .name = try allocator.dupe(u8, "shell_exec"),
        .arguments_json = try allocator.dupe(u8, "{\"mode\":\"shell\",\"argv\":[\"cmd\",\"/c\",\"find\"]}"),
    };
    defer tool_call.deinit(allocator);

    const event = try renderToolFinishedEvent(allocator, tool_call, false, "InvalidArguments", 10, 14);
    defer allocator.free(event);

    try std.testing.expect(std.mem.indexOf(u8, event, "\"schema\":\"var1.tool_finished.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"error_name\":\"InvalidArguments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "\"hint\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, event, "Select-String") != null);
}

fn compactSessionForRuntime(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: Hooks,
    session: types.SessionRecord,
    trigger: []const u8,
    estimated_tokens: u64,
) !bool {
    // Compaction lane with progressive aggressiveness. Each retry increases
    // aggressiveness, which causes the entry-aware compactor to recompact
    // already-summarized ranges with a tighter summary. This implements the
    // chunked fallback pattern: initial-compact → fail → higher aggressiveness
    // → recompact wider range → success.
    //
    // initial-compact(aggressiveness=config) → success → end
    // initial-compact → not enough → compact(aggressiveness+=200) → success → end
    // initial-compact → not enough → compact(aggressiveness+=200) → not enough → compact(aggressiveness+=200) → ...
    //
    // The compactor's buildPlan detects when aggressiveness_milli exceeds
    // the existing checkpoint's value and recompacts from source_seq_start,
    // effectively merging chunks into a tighter summary.
    const start_message = try std.fmt.allocPrint(
        allocator,
        "Context compaction started: trigger={s} estimated_tokens={d}.",
        .{ trigger, estimated_tokens },
    );
    defer allocator.free(start_message);
    try recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "context_compaction_started", start_message, session.status);

    // Try compaction with progressively higher aggressiveness (up to 3 passes).
    // Each pass that succeeds writes a checkpoint; the provider retry will
    // use the compacted window. If the provider overflows again, the next
    // call to compactSessionForRuntime will hit the higher-aggressiveness
    // checkpoint and recompact.
    const aggressiveness_steps = [_]u16{ 0, 200, 400 };
    for (aggressiveness_steps) |step| {
        const effective_aggressiveness = @min(
            @as(u16, config.context_policy.aggressiveness_milli) + step,
            @as(u16, 1000),
        );

        const result = context_builder.compactor.compactSession(allocator, config.workspace_root, session.id, .{
            .keep_recent_messages = config.context_policy.keep_recent_messages,
            .trigger = trigger,
            .aggressiveness_milli = effective_aggressiveness,
            .max_entries_per_checkpoint = config.context_policy.max_entries_per_checkpoint,
        }) catch |err| {
            const failure_message = try std.fmt.allocPrint(
                allocator,
                "Context compaction failed: trigger={s} aggressiveness={d} error={s}.",
                .{ trigger, effective_aggressiveness, @errorName(err) },
            );
            defer allocator.free(failure_message);
            try recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "context_compaction_failed", failure_message, session.status);
            return err;
        };
        defer result.deinit(allocator);

        if (result.checkpoint) |checkpoint| {
            const complete_message = try std.fmt.allocPrint(
                allocator,
                "Context compaction completed: trigger={s} aggressiveness={d} source_seq={d}..{d} first_kept_seq={d} compacted_entries={d}.",
                .{
                    trigger,
                    effective_aggressiveness,
                    checkpoint.source_seq_start,
                    checkpoint.source_seq_end,
                    checkpoint.first_kept_seq,
                    checkpoint.compacted_entry_count,
                },
            );
            defer allocator.free(complete_message);
            try recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "context_compaction_completed", complete_message, session.status);
            return true;
        }

        // Compaction returned no checkpoint (not enough messages or already current).
        // Try next aggressiveness step if available.
    }

    // All aggressiveness steps returned no checkpoint — nothing to compact.
    const skipped_message = try std.fmt.allocPrint(
        allocator,
        "Context compaction skipped: trigger={s} reason=no_messages_to_compact.",
        .{trigger},
    );
    defer allocator.free(skipped_message);
    try recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "context_compaction_skipped", skipped_message, session.status);
    return false;
}

fn executeToolCall(
    allocator: std.mem.Allocator,
    execution_context: tools.ExecutionContext,
    tool_call: types.ToolCall,
) !struct { output: []u8, log_line: []u8, launched_child: bool, ok: bool, error_name: ?[]const u8 } {
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
        return .{ .output = error_output, .log_line = error_log, .launched_child = false, .ok = false, .error_name = error_name };
    };

    const success_log = try std.fmt.allocPrint(allocator, "tool completed: {s}", .{tools.toolCallLogLabel(tool_call.name)});
    return .{
        .output = tool_output,
        .log_line = success_log,
        .launched_child = std.mem.eql(u8, tool_call.name, "launch_agent"),
        .ok = true,
        .error_name = null,
    };
}

const ChildStatusSummary = struct {
    pending: usize = 0,
    failed: usize = 0,
};

fn childStatusSummary(allocator: std.mem.Allocator, execution_context: tools.ExecutionContext) !ChildStatusSummary {
    const service = execution_context.agent_service orelse return .{};
    const parent_session_id = execution_context.parent_session_id orelse return .{};

    const listing = try service.list(allocator, parent_session_id);
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
        if (std.mem.eql(u8, status_label, "failed") or std.mem.eql(u8, status_label, "cancelled")) {
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
    return std.mem.eql(u8, status_label, "completed") or
        std.mem.eql(u8, status_label, "failed") or
        std.mem.eql(u8, status_label, "cancelled");
}

fn contentMentionsFailure(content: []const u8) bool {
    const keywords = [_][]const u8{
        "fail",
        "failed",
        "failure",
        "errored",
        "error",
        "cancelled",
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
    return allocator.dupe(u8, "I completed the request and can provide an operator-safe summary.");
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

fn cancelSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    reason: []const u8,
) !void {
    try store.setSessionStatus(allocator, workspace_root, session, .cancelled);
    try recordSessionEvent(allocator, workspace_root, hooks, session.id, "session_cancelled", reason, session.status);
    store.syncSessionLedgers(allocator, workspace_root, session.id) catch {};
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = reason,
        .updated_at_ms = session.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, workspace_root, "session cancelled");
}

fn failSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    failure_reason: []const u8,
) !void {
    try store.setSessionFailure(allocator, workspace_root, session, failure_reason);
    try recordSessionEvent(allocator, workspace_root, hooks, session.id, "session_failed", failure_reason, session.status);
    store.syncSessionLedgers(allocator, workspace_root, session.id) catch {};
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = failure_reason,
        .updated_at_ms = session.updated_at_ms,
    });

    const log_line = try std.fmt.allocPrint(allocator, "session failed: {s}", .{failure_reason});
    defer allocator.free(log_line);
    try docs_sync.appendLog(allocator, workspace_root, log_line);
}

fn recordSessionEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: types.SessionStatus,
) !void {
    const timestamp_ms = std.time.milliTimestamp();
    try store.appendEvent(allocator, workspace_root, session_id, .{
        .event_type = event_type,
        .message = message,
        .timestamp_ms = timestamp_ms,
    });
    try store.touchSessionUpdatedAt(allocator, workspace_root, session_id, timestamp_ms);
    try hooks.onSessionEvent(session_id, event_type, message, types.statusLabel(status), timestamp_ms);
}
