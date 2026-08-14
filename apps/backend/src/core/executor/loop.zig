const std = @import("std");
const config_file = @import("../config/file.zig");
const context_builder = @import("../context/index.zig");
const context_stream_rules = @import("../context/stream_rules.zig");
const agent_mailbox = @import("../agents/mailbox.zig");
const prompts = @import("../prompts/index.zig");
const draft = @import("draft.zig");
const turn_payload = @import("turn_payload.zig");
const provider = @import("../providers/openai_compatible.zig");
const dispatch = @import("../providers/dispatch.zig");
const store = @import("../sessions/store.zig");
const summaries = @import("../sessions/summaries.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");
const protocol_events = @import("../../shared/protocol/events.zig");

pub const Error = error{
    Cancelled,
    ContextWindowExceeded,
    MissingAssistantContent,
    StepLimitExceeded,
    StreamRuleMatched,
    ToolBudgetExceeded,
};

pub const Hooks = struct {
    context: ?*anyopaque = null,
    onSessionInitializedFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!void = null,
    onSessionEventFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,
    shouldCancelFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) bool = null,
    drainPendingMessagesFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) ?[][]u8 = null,
    hasPendingMessagesFn: ?*const fn (ctx: ?*anyopaque, session_id: []const u8) bool = null,
    copyBufferPreviewFn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 = null,

    pub fn onSessionInitialized(self: Hooks, session_id: []const u8) !void {
        if (self.onSessionInitializedFn) |callback| {
            try callback(self.context, session_id);
        }
    }

    pub fn onSessionEvent(
        self: Hooks,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.onSessionEventFn) |callback| {
            try callback(self.context, session_id, seq, event_type, message, status, timestamp_ms);
        }
    }

    pub fn shouldCancel(self: Hooks, session_id: []const u8) bool {
        if (self.shouldCancelFn) |callback| {
            return callback(self.context, session_id);
        }
        return false;
    }

    /// Drain pending user messages queued during an active turn (interjection protocol).
    /// Returns an owned slice of owned strings, or null if no messages are queued.
    pub fn drainPendingMessages(self: Hooks, session_id: []const u8) ?[][]u8 {
        if (self.drainPendingMessagesFn) |callback| {
            return callback(self.context, session_id);
        }
        return null;
    }

    /// Non-destructive peek: returns true if the session has pending messages.
    pub fn hasPendingMessages(self: Hooks, session_id: []const u8) bool {
        if (self.hasPendingMessagesFn) |callback| {
            return callback(self.context, session_id);
        }
        return false;
    }

    /// Copy the latest preview for this exact session. The caller owns the
    /// returned slice. Null means no matching preview is available.
    pub fn copyBufferPreview(self: Hooks, allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 {
        if (self.copyBufferPreviewFn) |callback| {
            return callback(self.context, allocator, session_id);
        }
        return null;
    }
};

pub const RunOptions = struct {
    transport: provider.Transport,
    execution_context: tools.ExecutionContext,
    session_id: ?[]const u8 = null,
    hooks: Hooks = .{},
    prompt_mode: prompts.PromptMode = .orchestrate,
};

pub fn runPrompt(allocator: std.mem.Allocator, config: types.Config, prompt: []const u8) !types.SessionRunResult {
    return runPromptWithOptions(allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
            .sendWithHeadersFn = provider.httpSendWithHeaders,
            .streamWithHeadersFn = provider.httpSendStreamingWithHeaders,
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

    var session = if (options.session_id) |existing_session_id|
        try store.readSessionRecord(allocator, config.workspace_root, existing_session_id)
    else
        try store.initSession(allocator, config.workspace_root, prompt);
    defer session.deinit(allocator);

    // A prior owner may have died after reserving a file mutation. Close that
    // nonterminal evidence before this execution becomes the new owner.
    const abandoned_write_intents = if (session.status == .running)
        0
    else
        try store.reconcileAbandonedIntents(
            allocator,
            config.workspace_root,
            session.id,
        );

    // Turn-end freshness gate anchor: any summary row updated after this
    // instant is evidence the agent satisfied the mandatory pre-turn-end
    // update (AGENTS.md summary discipline). Rows older than this trigger
    // the kernel fallback in finalizeSessionSummary.
    const run_start_ms = std.time.milliTimestamp();

    if (session.status == .cancelled) return Error.Cancelled;
    const should_recover_child_groups = options.session_id != null and session.status != .initialized;

    try store.setSessionStatus(allocator, config.workspace_root, &session, .running);
    try options.hooks.onSessionInitialized(session.id);
    const run_seq = try recordSessionEventWithSeq(
        allocator,
        config.workspace_root,
        options.hooks,
        session.id,
        "session_started",
        "VAR1 session initialized.",
        session.status,
    );
    if (abandoned_write_intents > 0) {
        const reconciliation = try std.fmt.allocPrint(
            allocator,
            "Reconciled {d} abandoned write intent{s} at cold start.",
            .{ abandoned_write_intents, if (abandoned_write_intents == 1) "" else "s" },
        );
        defer allocator.free(reconciliation);
        try recordSessionEvent(
            allocator,
            config.workspace_root,
            options.hooks,
            session.id,
            "write_intents_reconciled",
            reconciliation,
            session.status,
        );
    }
    var messages = std.array_list.Managed(types.ChatMessage).init(allocator);
    defer {
        for (messages.items) |message| message.deinit(allocator);
        messages.deinit();
    }

    var execution_context = options.execution_context;
    execution_context.workspace_root = config.workspace_root;
    execution_context.full_access_mode = config.full_access_mode;
    execution_context.log_level = config.log_level;
    execution_context.session_id = session.id;
    execution_context.memory_policy = config.memory_policy;
    if (execution_context.parent_session_id == null) {
        execution_context.parent_session_id = session.id;
    }
    var file_inspection_ledger = tools.FileInspectionLedger.init(allocator);
    defer file_inspection_ledger.deinit();
    execution_context.file_inspection_ledger = &file_inspection_ledger;
    var agent_eligibility_ledger = tools.AgentEligibilityLedger{};
    const root_agent_run = execution_context.agent_service != null and
        (execution_context.capability_profile_id == null or
            std.mem.eql(u8, execution_context.capability_profile_id.?, "root"));
    if (execution_context.agent_service != null) {
        execution_context.agent_eligibility_ledger = &agent_eligibility_ledger;
    }
    if (root_agent_run) {
        // Shift+Tab selects the session-local prompt lens. `orchestrate` is
        // the only root posture that narrows the model-visible catalog; build,
        // align, and plan retain the normal root tools. Child profiles never
        // inherit this root-only posture.
        execution_context.orchestrator_only = options.prompt_mode.enforcesOrchestration();
    }
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

    // A resumed parent rebuilds its child-group index from receipts before the
    // first provider dispatch. Any recovered group is parked/converged through
    // the same condition path as a live launch, so cold start cannot skip or
    // duplicate child evidence.
    if (should_recover_child_groups) if (execution_context.agent_service) |agent_service| {
        if (agent_service.waitParentFn != null) {
            _ = try agent_service.reconcile(allocator, session.id);
            _ = try awaitChildGroups(
                allocator,
                config.workspace_root,
                options.hooks,
                &session,
                run_seq,
                agent_service,
            );
        }
    };

    var base_message_count = rebuildProviderBaseMessages(
        allocator,
        config,
        options.hooks,
        execution_context,
        session,
        &messages,
        0,
        options.prompt_mode,
    ) catch |err| {
        try failSession(allocator, config.workspace_root, options.hooks, &session, run_seq, .failed, provider.failureDiagnosticForError(err), run_start_ms);
        return err;
    };

    // Draft compilation (root sessions only): a lightweight model restructures
    // the user's raw input before the heavyweight's first turn. Failures fall
    // back gracefully to the raw prompt — never blocks the session.
    if (execution_context.parent_session_id == null and options.session_id == null) {
        const draft_policy = draft.loadDraftPolicy(allocator, config.workspace_root);
        defer draft_policy.deinit(allocator);
        if (draft_policy.enabled) {
            if (draft.runDraft(allocator, config, draft_policy, session.prompt, options.transport)) |compiled| {
                defer allocator.free(compiled);
                // Append the compiled prompt as a system message after the
                // agent system prompt, before the transcript context.
                const msg = types.initTextMessage(allocator, .system, compiled) catch null;
                if (msg) |m| {
                    messages.insert(1, m) catch {};
                    base_message_count = messages.items.len;
                }
            }
        }
    }

    var requires_child_supervision = false;
    var mailbox_context = MailboxContext{};
    var executed_tool_calls: usize = 0;
    var provider_retries: u8 = 0;
    const max_provider_retries: u8 = 4;

    var step: usize = 0;
    while (step < config.max_steps) : (step += 1) {
        if (options.hooks.shouldCancel(session.id)) {
            try cancelSession(allocator, config.workspace_root, options.hooks, &session, run_seq, "Cancellation requested.");
            return Error.Cancelled;
        }

        // Interjection protocol: drain queued operator messages and inject them
        // as user messages at the step boundary. Tagged as USER_STEER_MESSAGE
        // so the model's reasoning trace naturally acknowledges the interjection.
        if (options.hooks.drainPendingMessages(session.id)) |drained| {
            const has_messages = drained.len > 0;
            defer allocator.free(drained);
            for (drained) |msg| {
                defer allocator.free(msg);
                const tagged = std.fmt.allocPrint(allocator, "USER_STEER_MESSAGE: {s} (DO NOT IGNORE)", .{msg}) catch msg;
                defer if (tagged.ptr != msg.ptr) allocator.free(tagged);
                try store.appendSessionMessage(allocator, config.workspace_root, session.id, .user, tagged, std.time.milliTimestamp());
                try messages.append(try types.initTextMessage(allocator, .user, tagged));
            }
            if (has_messages) {
                try recordSessionEvent(allocator, config.workspace_root, options.hooks, session.id, "user_message_injected", "Interjected user message injected into context.", session.status);
                base_message_count = try rebuildProviderBaseMessages(
                    allocator,
                    config,
                    options.hooks,
                    execution_context,
                    session,
                    &messages,
                    messages.items.len,
                    options.prompt_mode,
                );
            }
        }

        mailbox_context.injectIfEligible(
            allocator,
            config.workspace_root,
            session.id,
            run_seq,
            &messages,
        ) catch |err| {
            try failSession(
                allocator,
                config.workspace_root,
                options.hooks,
                &session,
                run_seq,
                .failed,
                @errorName(err),
                run_start_ms,
            );
            return err;
        };

        // Typed turn ingress evidence: every provider turn starts with a
        // turn_started event carrying the step boundary and measured token
        // telemetry (AGENTS.md §IV, roadmap P0-2b). The message is allocated
        // on the parent allocator because it is persisted to the event spine
        // before this scope returns; free it immediately
        // after recordSessionEvent serializes it into the durable ledger.
        {
            const boundary_msg = turn_payload.turnStartedPayload(allocator, step, messages.items) catch "Provider turn started.";
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
            options.prompt_mode,
        ) catch |err| {
            try failSession(allocator, config.workspace_root, options.hooks, &session, run_seq, .failed, provider.failureDiagnosticForError(err), run_start_ms);
            return err;
        };

        // Provider call with resilience: any provider failure (timeout, bad
        // status, malformed response, empty content) is retried with a nudge
        // rather than bricking the session. The loop is the sole authority
        // on session termination — a bad turn is overwritten by the next turn.
        // Only truly unrecoverable states (step limit, cancellation, context
        // overflow that can't compact) escape this block.

        // Buffer speculation injection: if the buffer model produced a navigation
        // preview, inject it as an advisory system message before the provider
        // call. The model sees it as pre-computed guidance — it can use it or
        // ignore it. Advisory only, never blocks. The copy is session-keyed so
        // concurrent root turns cannot consume each other's preview.
        if (options.hooks.copyBufferPreview(allocator, session.id)) |preview| {
            defer allocator.free(preview);
            if (preview.len > 0) {
                const advisory = std.fmt.allocPrint(allocator, "BUFFER_INSIGHT (advisory, from lightweight model):\n{s}", .{preview}) catch null;
                if (advisory) |text| {
                    defer allocator.free(text);
                    messages.insert(1, types.initTextMessage(allocator, .system, text) catch null orelse continue) catch {};
                }
            }
        }

        const completion = completeWithContextRecovery(
            allocator,
            config,
            options.hooks,
            execution_context,
            session,
            &messages,
            &base_message_count,
            options.transport,
            options.prompt_mode,
        ) catch |err| {
            if (err == Error.StreamRuleMatched) {
                provider_retries = 0;
                continue;
            }
            // Connection-level failures are genuinely unrecoverable — the
            // server is unreachable. Propagate immediately.
            //
            // Note: error.WriteFailed is NOT unrecoverable. On Windows, the
            // socket writer's drain wraps WSASend; a provider-side connection
            // reset (WSAECONNRESET/WSAECONNABORTED) surfaces as WriteFailed.
            // This is a transient transport failure — the provider rate-limited
            // or reset the connection mid-write. It MUST go through the retry
            // path below, not brick the session.
            if (err == error.ConnectionRefused or
                err == error.NetworkUnreachable or
                err == error.ConnectionTimedOut)
            {
                try failSession(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    &session,
                    run_seq,
                    if (err == error.ConnectionTimedOut) .timed_out else .failed,
                    provider.failureDiagnosticForError(err),
                    run_start_ms,
                );
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
                try failSession(allocator, config.workspace_root, options.hooks, &session, run_seq, .failed, diag, run_start_ms);
                return err;
            }
            // Exponential backoff before retry: 1s, 2s, 4s, 8s. A provider
            // connection reset (WriteFailed from WSASend) needs time to clear
            // — the provider rate-limits under concurrent connections (buffer
            // thread + main loop). The old 500ms linear backoff was too
            // aggressive: all 3 retries hit the same rate-limited state.
            const backoff_ms: u64 = @as(u64, 1000) << @intCast(provider_retries - 1);
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            const nudge = try std.fmt.allocPrint(allocator, "Previous request failed ({s}). Please continue with the task.", .{@errorName(err)});
            defer allocator.free(nudge);
            try messages.append(try types.initTextMessage(allocator, .user, nudge));
            continue;
        };
        defer completion.deinit(allocator);
        provider_retries = 0; // reset on success
        mailbox_context.acknowledgeObservation(
            allocator,
            config.workspace_root,
            session.id,
            run_seq,
            &messages,
        ) catch |err| {
            try failSession(
                allocator,
                config.workspace_root,
                options.hooks,
                &session,
                run_seq,
                .failed,
                @errorName(err),
                run_start_ms,
            );
            return err;
        };
        if (options.hooks.shouldCancel(session.id)) {
            try cancelSession(allocator, config.workspace_root, options.hooks, &session, run_seq, "Cancellation requested during provider execution.");
            return Error.Cancelled;
        }

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
                try failSession(allocator, config.workspace_root, options.hooks, &session, run_seq, .failed, @errorName(Error.ToolBudgetExceeded), run_start_ms);
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
                    try cancelSession(allocator, config.workspace_root, options.hooks, &session, run_seq, "Cancellation requested.");
                    return Error.Cancelled;
                }

                const active_tool_definitions = tools.builtinDefinitionsForContext(execution_context);
                const review_decision = tools.review.reviewToolCall(tool_call, active_tool_definitions);
                const review_event = try tools.review.renderReviewEvent(allocator, tool_call, review_decision);
                defer allocator.free(review_event);
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "tool_reviewed",
                    review_event,
                    session.status,
                );

                if (!review_decision.approved) {
                    const blocked_output = try tools.review.renderBlockedToolResult(allocator, tool_call, review_decision);
                    defer allocator.free(blocked_output);
                    try recordSessionEvent(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        session.id,
                        "tool_blocked",
                        review_event,
                        session.status,
                    );
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

            if (requires_child_supervision) {
                const agent_service = execution_context.agent_service orelse return tools.Error.AgentServiceUnavailable;
                const park_after_launch = if (execution_context.agent_eligibility_ledger) |ledger|
                    ledger.consumeParkRequest()
                else
                    true;
                if (park_after_launch) {
                    requires_child_supervision = try awaitChildGroups(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        &session,
                        run_seq,
                        agent_service,
                    );
                    base_message_count = try rebuildProviderBaseMessages(
                        allocator,
                        config,
                        options.hooks,
                        execution_context,
                        session,
                        &messages,
                        messages.items.len,
                        options.prompt_mode,
                    );
                    continue;
                }
                const child_snapshot = try agent_service.waitParent(session.id, 0);
                if (child_snapshot.ready) {
                    try recordSessionEvent(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        session.id,
                        "child_convergence_started",
                        "{\"schema\":\"var1.parent_wait.v1\",\"state\":\"compiling_ready_children\"}",
                        session.status,
                    );
                    try agent_service.converge(allocator, session.id);
                    base_message_count = try rebuildProviderBaseMessages(
                        allocator,
                        config,
                        options.hooks,
                        execution_context,
                        session,
                        &messages,
                        messages.items.len,
                        options.prompt_mode,
                    );
                    const after_convergence = try agent_service.waitParent(session.id, 0);
                    requires_child_supervision = !after_convergence.terminal or after_convergence.ready;
                } else {
                    // Give the parent another provider turn so it can dispatch
                    // more independent work or emit its waiting update. A text
                    // response while children remain active parks below.
                    base_message_count = messages.items.len;
                }
            } else {
                base_message_count = messages.items.len;
            }

            continue;
        }

        const wake_requires_continuation = agent_mailbox.hasEligibleUnread(
            allocator,
            config.workspace_root,
            session.id,
            run_seq,
        ) catch |err| {
            try failSession(
                allocator,
                config.workspace_root,
                options.hooks,
                &session,
                run_seq,
                .failed,
                @errorName(err),
                run_start_ms,
            );
            return err;
        };

        if (completion.content) |content| {
            const final_output = try sanitizeOperatorResponse(allocator, session.prompt, content);
            defer allocator.free(final_output);

            if (requires_child_supervision or wake_requires_continuation) {
                const progress_timestamp = std.time.milliTimestamp();
                try store.upsertAssistantSessionMessageWithReasoning(
                    allocator,
                    config.workspace_root,
                    session.id,
                    final_output,
                    completion.reasoning,
                    progress_timestamp,
                );
                try recordSessionEvent(
                    allocator,
                    config.workspace_root,
                    options.hooks,
                    session.id,
                    "assistant_progress",
                    final_output,
                    session.status,
                );
                if (requires_child_supervision) {
                    const agent_service = execution_context.agent_service orelse return tools.Error.AgentServiceUnavailable;
                    requires_child_supervision = try awaitChildGroups(
                        allocator,
                        config.workspace_root,
                        options.hooks,
                        &session,
                        run_seq,
                        agent_service,
                    );
                }
                base_message_count = try rebuildProviderBaseMessages(
                    allocator,
                    config,
                    options.hooks,
                    execution_context,
                    session,
                    &messages,
                    messages.items.len,
                    options.prompt_mode,
                );
                continue;
            }

            const final_timestamp = std.time.milliTimestamp();
            try store.upsertAssistantSessionMessageWithReasoning(allocator, config.workspace_root, session.id, final_output, completion.reasoning, final_timestamp);
            try store.writeOutput(allocator, config.workspace_root, session.id, final_output);
            // Mandatory summary discipline: the orchestrator must leave a fresh
            // <=100-word summary before the turn ends. If update_session_summary
            // was not called during this run, the kernel writes a deterministic
            // fallback so the ledger never goes stale. The fallback is durable
            // evidence itself (row.source == "kernel_fallback") — no extra event
            // is appended, keeping the typed turn grammar unchanged.
            _ = try summaries.ensureFreshSummary(
                allocator,
                config.workspace_root,
                session.id,
                session.parent_session_id orelse "",
                "completed",
                session.prompt,
                final_output,
                run_start_ms,
            );
            const assistant_response_seq = try store.appendEventWithSeq(allocator, config.workspace_root, session.id, .{
                .event_type = "assistant_response",
                .message = final_output,
                .timestamp_ms = final_timestamp,
            });
            try options.hooks.onSessionEvent(
                session.id,
                assistant_response_seq,
                "assistant_response",
                final_output,
                types.statusLabel(session.status),
                final_timestamp,
            );
            try commitTerminalEvent(
                allocator,
                config.workspace_root,
                options.hooks,
                &session,
                run_seq,
                turn_payload.completedTerminalInput(step, messages.items, completion.model, completion.usage, final_output.len),
            );
            // Force the final durability flush — the batched sync gate in
            // appendJsonlRecord skips most per-event flushes for streaming
            // speed; the terminal assistant response must be durable before
            // the RPC returns (AGENTS.md §II durability gate at boundaries).
            store.syncSessionLedgers(allocator, config.workspace_root, session.id) catch {};
            return .{
                .session_id = try allocator.dupe(u8, session.id),
                .output = try allocator.dupe(u8, final_output),
            };
        }

        if (wake_requires_continuation) {
            base_message_count = try rebuildProviderBaseMessages(
                allocator,
                config,
                options.hooks,
                execution_context,
                session,
                &messages,
                messages.items.len,
                options.prompt_mode,
            );
            continue;
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
        _ = try summaries.ensureFreshSummary(
            allocator,
            config.workspace_root,
            session.id,
            session.parent_session_id orelse "",
            "completed",
            session.prompt,
            final_output,
            run_start_ms,
        );
        const assistant_response_seq = try store.appendEventWithSeq(allocator, config.workspace_root, session.id, .{
            .event_type = "assistant_response",
            .message = final_output,
            .timestamp_ms = final_timestamp,
        });
        try options.hooks.onSessionEvent(
            session.id,
            assistant_response_seq,
            "assistant_response",
            final_output,
            types.statusLabel(session.status),
            final_timestamp,
        );
        try commitTerminalEvent(
            allocator,
            config.workspace_root,
            options.hooks,
            &session,
            run_seq,
            turn_payload.completedTerminalInput(step, messages.items, completion.model, completion.usage, final_output.len),
        );
        store.syncSessionLedgers(allocator, config.workspace_root, session.id) catch {};
        return .{
            .session_id = try allocator.dupe(u8, session.id),
            .output = try allocator.dupe(u8, final_output),
        };
    }

    try failSession(allocator, config.workspace_root, options.hooks, &session, run_seq, .failed, "StepLimitExceeded", run_start_ms);
    return Error.StepLimitExceeded;
}

const MailboxContext = struct {
    through_seq: u64 = 0,

    fn injectIfEligible(
        self: *MailboxContext,
        allocator: std.mem.Allocator,
        workspace_root: []const u8,
        session_id: []const u8,
        run_seq: u64,
        messages: *std.array_list.Managed(types.ChatMessage),
    ) !void {
        if (self.through_seq != 0) return;
        const batch_value = try agent_mailbox.readUnreadBatch(
            allocator,
            workspace_root,
            session_id,
            run_seq,
        ) orelse return;
        var batch = batch_value;
        defer batch.deinit(allocator);
        try messages.append(try types.initTextMessage(allocator, .system, batch.rendered));
        self.through_seq = batch.through_seq;
    }

    fn acknowledgeObservation(
        self: *MailboxContext,
        allocator: std.mem.Allocator,
        workspace_root: []const u8,
        session_id: []const u8,
        run_seq: u64,
        messages: *std.array_list.Managed(types.ChatMessage),
    ) !void {
        if (self.through_seq == 0) return;
        try agent_mailbox.acknowledge(
            allocator,
            workspace_root,
            session_id,
            self.through_seq,
            run_seq,
        );
        removeMailboxContextMessage(allocator, messages);
        self.through_seq = 0;
    }
};

fn removeMailboxContextMessage(
    allocator: std.mem.Allocator,
    messages: *std.array_list.Managed(types.ChatMessage),
) void {
    var index = messages.items.len;
    while (index > 0) {
        index -= 1;
        const message = messages.items[index];
        if (message.role != .system) continue;
        const content = message.content orelse continue;
        if (!std.mem.startsWith(u8, content, "AGENT_MAILBOX (")) continue;
        var removed = messages.orderedRemove(index);
        removed.deinit(allocator);
        return;
    }
}

/// Park one parent on its in-memory child condition until the first
/// unconsumed terminal result is ready. This path performs no provider
/// dispatch. It converges every result ready at wake time exactly once, then
/// returns whether unfinished or newly-ready siblings still require
/// supervision.
fn awaitChildGroups(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    run_seq: u64,
    agent_service: tools.AgentService,
) !bool {
    var snapshot = try agent_service.waitParent(session.id, 0);
    if (snapshot.groups == 0) return false;
    if (!snapshot.ready and !snapshot.terminal) {
        try recordSessionEvent(
            allocator,
            workspace_root,
            hooks,
            session.id,
            "session_waiting",
            "{\"schema\":\"var1.parent_wait.v1\",\"state\":\"waiting_first_child\"}",
            session.status,
        );
    }

    while (!snapshot.ready and !snapshot.terminal) {
        if (hooks.shouldCancel(session.id)) {
            _ = agent_service.cancelParent(session.id, "Parent cancellation requested.") catch 0;
            try cancelSession(allocator, workspace_root, hooks, session, run_seq, "Cancellation requested while waiting for child groups.");
            return Error.Cancelled;
        }
        // If the operator interjected while parked, break early so the step
        // loop can drain and inject the message. The step loop's drain will
        // consume the queue; we just need to stop blocking.
        if (hooks.hasPendingMessages(session.id)) break;
        snapshot = try agent_service.waitParent(session.id, 250);
    }

    if (snapshot.ready) {
        try recordSessionEvent(
            allocator,
            workspace_root,
            hooks,
            session.id,
            "child_convergence_started",
            "{\"schema\":\"var1.parent_wait.v1\",\"state\":\"compiling_ready_children\"}",
            session.status,
        );
        try agent_service.converge(allocator, session.id);
    }
    const after_convergence = try agent_service.waitParent(session.id, 0);
    return !after_convergence.terminal or after_convergence.ready;
}

fn rebuildProviderBaseMessages(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: Hooks,
    execution_context: tools.ExecutionContext,
    session: types.SessionRecord,
    messages: *std.array_list.Managed(types.ChatMessage),
    preserve_from_index: usize,
    prompt_mode: prompts.PromptMode,
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

    // Hot-load prompt policy from disk on every prompt rebuild so config.json
    // changes (persona, guardrails, user_context, prompt files) take effect
    // on the next turn, not the next session start. The disk read is
    // sub-millisecond for a local file. Falls back to the cached policy
    // if the file cannot be read (graceful degradation).
    const hot_prompt_policy = config_file.loadPromptPolicy(allocator, config.workspace_root, config.prompt_policy) catch config.prompt_policy;
    defer hot_prompt_policy.deinit(allocator);

    const system_prompt = try prompts.buildAgentSystemPromptWithOptions(
        allocator,
        execution_context,
        hot_prompt_policy,
        config.memory_policy,
        session.prompt,
        prompt_mode,
        .{ .prompt_budget_tokens = config.context_policy.prompt_budget_tokens },
    );
    defer allocator.free(system_prompt);

    try messages.append(try types.initTextMessage(allocator, .system, system_prompt));
    var compile_report = context_builder.CompileReport{};
    try context_builder.appendProviderMessagesWithReport(
        allocator,
        config.workspace_root,
        messages,
        session,
        &compile_report,
    );
    if (compile_report.hasDiagnostics()) {
        const diagnostic = try protocol_events.serializeContextCompileDiagnostic(
            allocator,
            "provider_rebuild",
            compile_report.synthesized_tool_results,
            compile_report.skipped_tool_results,
        );
        defer allocator.free(diagnostic);
        try recordSessionEvent(
            allocator,
            config.workspace_root,
            hooks,
            session.id,
            protocol_events.context_compile_diagnostic_event_type,
            diagnostic,
            session.status,
        );
    }

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
    prompt_mode: prompts.PromptMode,
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
        hooks,
        execution_context,
        session,
        messages,
        base_message_count,
        prompt_mode,
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
    prompt_mode: prompts.PromptMode,
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
        .shouldAbortFn = shouldAbortProviderStream,
    };

    defer stream_context.deinitAccumulators();

    const completion = dispatch.completeWithTransportAndHooks(allocator, config, .{
        .messages = messages.items,
        .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
    }, transport, stream_hooks) catch |err| {
        if (err == provider.Error.StreamAborted and stream_context.rule_abort_requested) {
            if (try injectStreamRule(allocator, config, hooks, session, messages, &stream_context)) {
                return Error.StreamRuleMatched;
            }
        }
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
            hooks,
            execution_context,
            session,
            messages,
            base_message_count.*,
            prompt_mode,
        );

        return dispatch.completeWithTransportAndHooks(allocator, config, .{
            .messages = messages.items,
            .tool_definitions = tools.builtinDefinitionsForContext(execution_context),
        }, transport, stream_hooks) catch |retry_err| {
            if (retry_err == provider.Error.StreamAborted and stream_context.rule_abort_requested) {
                if (try injectStreamRule(allocator, config, hooks, session, messages, &stream_context)) {
                    return Error.StreamRuleMatched;
                }
            }
            return retry_err;
        };
    };

    // Fixture transports and provider adapters that do not honor shouldAbort
    // can still return a completion after a rule fired. Discard that completion
    // before the caller can execute tools or commit terminal assistant state.
    if (stream_context.rule_abort_requested) {
        if (try injectStreamRule(allocator, config, hooks, session, messages, &stream_context)) {
            completion.deinit(allocator);
            return Error.StreamRuleMatched;
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

fn shouldAbortProviderStream(ctx: ?*anyopaque) bool {
    const delta_context: *ProviderDeltaContext = @ptrCast(@alignCast(ctx.?));
    return delta_context.rule_abort_requested;
}

fn injectStreamRule(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: Hooks,
    session: types.SessionRecord,
    messages: *std.array_list.Managed(types.ChatMessage),
    stream_context: *ProviderDeltaContext,
) !bool {
    const match = stream_context.rule_match orelse return false;
    const injection_msg = try context_stream_rules.formatInjectionMessage(allocator, match);
    defer allocator.free(injection_msg);

    // Persist the correction before emitting its event. The next provider
    // attempt uses the same in-memory message, while a cold rebuild obtains
    // the identical correction from messages.jsonl.
    try store.appendSessionMessage(
        allocator,
        config.workspace_root,
        session.id,
        .user,
        injection_msg,
        std.time.milliTimestamp(),
    );
    try messages.append(try types.initTextMessage(allocator, .user, injection_msg));
    try recordSessionEvent(
        allocator,
        config.workspace_root,
        hooks,
        session.id,
        "rule_injected",
        injection_msg,
        session.status,
    );
    return true;
}

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
    const message = try protocol_events.serializeToolOutputDelta(
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

test "tool finished schema errors carry actionable typed correction hints" {
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
    run_seq: u64,
    reason: []const u8,
) !void {
    try commitTerminalEvent(allocator, workspace_root, hooks, session, run_seq, .{
        .outcome = .cancelled,
        .detail = reason,
    });
    store.syncSessionLedgers(allocator, workspace_root, session.id) catch {};
}

fn failSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    run_seq: u64,
    outcome: protocol_events.TurnTerminalOutcome,
    failure_reason: []const u8,
    run_start_ms: i64,
) !void {
    if (outcome != .failed and outcome != .timed_out) return error.InvalidFailureTerminalOutcome;
    try commitTerminalEvent(allocator, workspace_root, hooks, session, run_seq, .{
        .outcome = outcome,
        .detail = failure_reason,
    });
    // Failed turns still end the session — the summary timeline must show why.
    // The fallback row (source == "kernel_fallback") is the durable evidence.
    _ = try summaries.ensureFreshSummary(
        allocator,
        workspace_root,
        session.id,
        session.parent_session_id orelse "",
        types.statusLabel(session.status),
        session.prompt,
        failure_reason,
        run_start_ms,
    );
    store.syncSessionLedgers(allocator, workspace_root, session.id) catch {};
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
    _ = try recordSessionEventWithSeq(allocator, workspace_root, hooks, session_id, event_type, message, status);
}

fn recordSessionEventWithSeq(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: types.SessionStatus,
) !u64 {
    const timestamp_ms = std.time.milliTimestamp();
    const seq = try store.appendEventWithSeq(allocator, workspace_root, session_id, .{
        .event_type = event_type,
        .message = message,
        .timestamp_ms = timestamp_ms,
    });
    try store.touchSessionUpdatedAt(allocator, workspace_root, session_id, timestamp_ms);
    // Live notification is a read model over the durable event spine
    // (AGENTS.md §IV). A slow/broken TUI pipe must never corrupt the
    // provider turn — the durable event has already been persisted above.
    hooks.onSessionEvent(session_id, seq, event_type, message, types.statusLabel(status), timestamp_ms) catch {};
    return seq;
}

fn commitTerminalEvent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    hooks: Hooks,
    session: *types.SessionRecord,
    run_seq: u64,
    input: protocol_events.TurnTerminalInput,
) !void {
    const timestamp_ms = std.time.milliTimestamp();
    var commit = try store.commitTurnTerminal(allocator, workspace_root, session, run_seq, input, timestamp_ms);
    defer commit.deinit(allocator);
    if (!commit.appended) return;
    hooks.onSessionEvent(
        session.id,
        commit.seq,
        protocol_events.turn_terminal_event_type,
        commit.payload.?,
        types.statusLabel(session.status),
        timestamp_ms,
    ) catch {};
}
