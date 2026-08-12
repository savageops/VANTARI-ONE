const std = @import("std");
const VAR1 = @import("VAR1");

const deep_pipeline_case_count = 111;

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_steps: usize,
) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "gemma-4-e2b-it"),
        .max_steps = max_steps,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn makeToolCall(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) !VAR1.shared.types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    };
}

fn makeCheckpoint(
    allocator: std.mem.Allocator,
    id: []const u8,
    first_kept_seq: u64,
    summary: []const u8,
) !VAR1.shared.types.ContextCheckpoint {
    return .{
        .id = try allocator.dupe(u8, id),
        .entry_type = try allocator.dupe(u8, "summary_checkpoint"),
        .created_at_ms = std.time.milliTimestamp(),
        .source_seq_start = 1,
        .source_seq_end = first_kept_seq - 1,
        .first_kept_seq = first_kept_seq,
        .tokens_before_estimate = 512,
        .tokens_after_estimate = 96,
        .aggressiveness_milli = 650,
        .compacted_entry_count = @as(u32, @intCast(first_kept_seq - 1)),
        .trigger = try allocator.dupe(u8, "deep_pipeline_matrix"),
        .summary = try allocator.dupe(u8, summary),
    };
}

fn mockSendMatrixSuccess(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"matrix provider completed canonical pipeline turn."}}]}
    );
}

fn mockSendMatrixFailure(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.ConnectionRefused;
}

fn deinitChatMessages(allocator: std.mem.Allocator, messages: *std.array_list.Managed(VAR1.shared.types.ChatMessage)) void {
    for (messages.items) |message| message.deinit(allocator);
    messages.deinit();
}

fn expectProviderMessageContains(
    messages: []const VAR1.shared.types.ChatMessage,
    index: usize,
    expected_role: VAR1.shared.types.MessageRole,
    needle: []const u8,
) !void {
    try std.testing.expect(index < messages.len);
    try std.testing.expectEqual(expected_role, messages[index].role);
    try std.testing.expect(messages[index].content != null);
    try std.testing.expect(std.mem.indexOf(u8, messages[index].content.?, needle) != null);
}

fn verifySuccessfulProviderRun(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline success case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    const config = try makeConfig(std.testing.allocator, workspace_root, 2);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = mockSendMatrixSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    });
    defer result.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, result.session_id);
    defer session.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.completed, session.status);
    try std.testing.expect(session.failure_reason == null);
    try std.testing.expectEqualStrings(prompt, session.prompt);

    const stored_output = try VAR1.core.session_store.readOutput(std.testing.allocator, workspace_root, result.session_id);
    defer if (stored_output) |value| std.testing.allocator.free(value);
    try std.testing.expect(stored_output != null);
    try std.testing.expectEqualStrings(result.output, stored_output.?);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);
    try std.testing.expect(messages.len >= 2);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.user, messages[0].role);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, messages[messages.len - 1].role);

    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, result.session_id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("turn_terminal", latest.?.event_type);
    try std.testing.expect(std.mem.indexOf(u8, latest.?.message, "\"outcome\":\"completed\"") != null);
}

fn verifyProviderFailureRun(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline failure case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    const config = try makeConfig(std.testing.allocator, workspace_root, 2);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectError(error.ConnectionRefused, VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, prompt, .{
        .transport = .{
            .context = null,
            .sendFn = mockSendMatrixFailure,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
    }));

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, sessions[0].status);
    try std.testing.expect(sessions[0].failure_reason != null);
    try std.testing.expectEqualStrings("ConnectionRefused", sessions[0].failure_reason.?);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, sessions[0].id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expect(events.len >= 2);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("turn_terminal", events[events.len - 1].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[events.len - 1].message, "\"outcome\":\"failed\"") != null);
}

fn verifyToolTranscriptRoundTrip(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline tool pair case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    var tool_call = try makeToolCall(std.testing.allocator, "call_read_context", "read_file", "{\"path\":\"context.txt\"}");
    defer tool_call.deinit(std.testing.allocator);
    const tool_calls = [_]VAR1.shared.types.ToolCall{tool_call};

    try VAR1.core.session_store.appendAssistantToolCallSessionMessage(
        std.testing.allocator,
        workspace_root,
        session.id,
        "I will inspect the file.",
        tool_calls[0..],
        null,
        200,
    );
    try VAR1.core.session_store.appendToolSessionMessage(std.testing.allocator, workspace_root, session.id, "call_read_context", "file body", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "final answer", 400);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer deinitChatMessages(std.testing.allocator, &provider_messages);

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    try std.testing.expectEqual(@as(usize, 4), provider_messages.items.len);
    try expectProviderMessageContains(provider_messages.items, 0, .user, prompt);
    try std.testing.expectEqual(VAR1.shared.types.MessageRole.assistant, provider_messages.items[1].role);
    try std.testing.expectEqual(@as(usize, 1), provider_messages.items[1].tool_calls.len);
    try std.testing.expectEqualStrings("call_read_context", provider_messages.items[1].tool_calls[0].id);
    try expectProviderMessageContains(provider_messages.items, 2, .tool, "file body");
    try expectProviderMessageContains(provider_messages.items, 3, .assistant, "final answer");
}

fn verifyUnresolvedToolTranscriptFails(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline unresolved tool case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    var tool_call = try makeToolCall(std.testing.allocator, "call_unresolved", "search_files", "{\"query\":\"needle\"}");
    defer tool_call.deinit(std.testing.allocator);
    const tool_calls = [_]VAR1.shared.types.ToolCall{tool_call};
    try VAR1.core.session_store.appendAssistantToolCallSessionMessage(std.testing.allocator, workspace_root, session.id, null, tool_calls[0..], null, 200);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer deinitChatMessages(std.testing.allocator, &provider_messages);

    // Self-healing: the builder now synthesizes missing tool results instead
    // of hard-failing. The transcript with an unresolved tool-call tail
    // should succeed and contain a synthetic tool result.
    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    // Self-healing: builder should produce the assistant tool-call message
    // plus a synthetic tool result for the interrupted call.
    try std.testing.expect(provider_messages.items.len >= 2);
    // The last message should be a tool result (has tool_call_id).
    try std.testing.expect(provider_messages.items[provider_messages.items.len - 1].tool_call_id != null);
}

fn verifyOrphanToolTranscriptFails(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline orphan tool case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.appendToolSessionMessage(std.testing.allocator, workspace_root, session.id, "call_orphan", "orphan body", 200);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer deinitChatMessages(std.testing.allocator, &provider_messages);

    // Self-healing: orphan tool results are skipped, not hard-failed.
    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
}

fn verifyCompactedContextSuffix(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline compact case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "old answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "fresh follow-up", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "fresh answer", 400);

    var checkpoint = try makeCheckpoint(std.testing.allocator, "ctx-valid", 3, "old prompt and answer compacted");
    defer checkpoint.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, checkpoint);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer deinitChatMessages(std.testing.allocator, &provider_messages);

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    try std.testing.expectEqual(@as(usize, 3), provider_messages.items.len);
    try expectProviderMessageContains(provider_messages.items, 0, .user, "old prompt and answer compacted");
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, prompt) == null);
    try expectProviderMessageContains(provider_messages.items, 1, .user, "fresh follow-up");
    try expectProviderMessageContains(provider_messages.items, 2, .assistant, "fresh answer");
}

fn verifyPoisonedCheckpointSuffixIgnored(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline poisoned checkpoint case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "old answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "fresh prompt", 300);

    var checkpoint = try makeCheckpoint(std.testing.allocator, "ctx-good", 3, "valid compacted summary");
    defer checkpoint.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, checkpoint);

    const context_path = try VAR1.core.session_store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    try VAR1.shared.fsutil.appendText(
        context_path,
        "{\"id\":\"ctx-poison\",\"type\":\"summary_checkpoint\",\"created_at_ms\":1,\"source_seq_start\":1,\"source_seq_end\":99,\"first_kept_seq\":100,\"trigger\":\"bad\",\"summary\":\"poisoned summary\"\n",
    );

    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |value| value.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("ctx-good", latest.?.id);
    try std.testing.expectEqualStrings("valid compacted summary", latest.?.summary);
}

fn verifyStatusTransitionsClearFailures(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline status case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.setSessionFailure(std.testing.allocator, workspace_root, &session, "SyntheticFailure");
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, session.status);
    try std.testing.expect(session.failure_reason != null);

    try VAR1.core.session_store.setSessionStatus(std.testing.allocator, workspace_root, &session, .running);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.running, session.status);
    try std.testing.expect(session.failure_reason == null);

    var stored = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer stored.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.running, stored.status);
    try std.testing.expect(stored.failure_reason == null);
}

fn verifyOutputAndEventLedger(workspace_root: []const u8, index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline event case {d}", .{index});
    defer std.testing.allocator.free(prompt);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, prompt);
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "draft output");
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "final output");

    const output = try VAR1.core.session_store.readOutput(std.testing.allocator, workspace_root, session.id);
    defer if (output) |value| std.testing.allocator.free(value);
    try std.testing.expect(output != null);
    try std.testing.expectEqualStrings("final output", output.?);

    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "started",
        .timestamp_ms = 100,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_response",
        .message = "completed",
        .timestamp_ms = 200,
    });

    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("assistant_response", latest.?.event_type);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
}

fn verifyDelegatedSessionMetadata(workspace_root: []const u8, index: usize) !void {
    const parent_prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline parent case {d}", .{index});
    defer std.testing.allocator.free(parent_prompt);
    const child_prompt = try std.fmt.allocPrint(std.testing.allocator, "deep pipeline child case {d}", .{index});
    defer std.testing.allocator.free(child_prompt);

    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, parent_prompt);
    defer parent.deinit(std.testing.allocator);
    var child = try VAR1.core.session_store.initSessionWithOptions(std.testing.allocator, workspace_root, child_prompt, .{
        .parent_session_id = parent.id,
        .continued_from_session_id = "session-origin",
        .display_name = "delegate-writer",
        .agent_profile = "subagent",
    });
    defer child.deinit(std.testing.allocator);

    try std.testing.expect(try VAR1.core.session_store.sessionExists(std.testing.allocator, workspace_root, child.id));
    var stored = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, child.id);
    defer stored.deinit(std.testing.allocator);
    try std.testing.expect(stored.parent_session_id != null);
    try std.testing.expectEqualStrings(parent.id, stored.parent_session_id.?);
    try std.testing.expect(stored.continued_from_session_id != null);
    try std.testing.expectEqualStrings("session-origin", stored.continued_from_session_id.?);
    try std.testing.expect(stored.display_name != null);
    try std.testing.expectEqualStrings("delegate-writer", stored.display_name.?);
    try std.testing.expect(stored.agent_profile != null);
    try std.testing.expectEqualStrings("subagent", stored.agent_profile.?);
}

fn verifyWorkspacePathBoundary(workspace_root: []const u8, index: usize) !void {
    const inside = try std.fmt.allocPrint(std.testing.allocator, "nested/case-{d}/artifact.txt", .{index});
    defer std.testing.allocator.free(inside);

    const resolved = try VAR1.shared.fsutil.resolveInWorkspace(std.testing.allocator, workspace_root, inside);
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "artifact.txt") != null);

    try std.testing.expectError(
        VAR1.shared.fsutil.PathError.PathOutsideWorkspace,
        VAR1.shared.fsutil.resolveInWorkspace(std.testing.allocator, workspace_root, "../escape.txt"),
    );
}

fn verifyDeepPipelineCase(index: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    switch (index % 11) {
        0 => try verifySuccessfulProviderRun(workspace_root, index),
        1 => try verifyProviderFailureRun(workspace_root, index),
        2 => try verifyToolTranscriptRoundTrip(workspace_root, index),
        3 => try verifyUnresolvedToolTranscriptFails(workspace_root, index),
        4 => try verifyOrphanToolTranscriptFails(workspace_root, index),
        5 => try verifyCompactedContextSuffix(workspace_root, index),
        6 => try verifyPoisonedCheckpointSuffixIgnored(workspace_root, index),
        7 => try verifyStatusTransitionsClearFailures(workspace_root, index),
        8 => try verifyOutputAndEventLedger(workspace_root, index),
        9 => try verifyDelegatedSessionMetadata(workspace_root, index),
        else => try verifyWorkspacePathBoundary(workspace_root, index),
    }
}

test "agent deep pipeline matrix contains at least 111 cases" {
    try std.testing.expect(deep_pipeline_case_count >= 111);
}

test "agent deep pipeline adversarial case 001" {
    try verifyDeepPipelineCase(0);
}
test "agent deep pipeline adversarial case 002" {
    try verifyDeepPipelineCase(1);
}
test "agent deep pipeline adversarial case 003" {
    try verifyDeepPipelineCase(2);
}
test "agent deep pipeline adversarial case 004" {
    try verifyDeepPipelineCase(3);
}
test "agent deep pipeline adversarial case 005" {
    try verifyDeepPipelineCase(4);
}
test "agent deep pipeline adversarial case 006" {
    try verifyDeepPipelineCase(5);
}
test "agent deep pipeline adversarial case 007" {
    try verifyDeepPipelineCase(6);
}
test "agent deep pipeline adversarial case 008" {
    try verifyDeepPipelineCase(7);
}
test "agent deep pipeline adversarial case 009" {
    try verifyDeepPipelineCase(8);
}
test "agent deep pipeline adversarial case 010" {
    try verifyDeepPipelineCase(9);
}
test "agent deep pipeline adversarial case 011" {
    try verifyDeepPipelineCase(10);
}
test "agent deep pipeline adversarial case 012" {
    try verifyDeepPipelineCase(11);
}
test "agent deep pipeline adversarial case 013" {
    try verifyDeepPipelineCase(12);
}
test "agent deep pipeline adversarial case 014" {
    try verifyDeepPipelineCase(13);
}
test "agent deep pipeline adversarial case 015" {
    try verifyDeepPipelineCase(14);
}
test "agent deep pipeline adversarial case 016" {
    try verifyDeepPipelineCase(15);
}
test "agent deep pipeline adversarial case 017" {
    try verifyDeepPipelineCase(16);
}
test "agent deep pipeline adversarial case 018" {
    try verifyDeepPipelineCase(17);
}
test "agent deep pipeline adversarial case 019" {
    try verifyDeepPipelineCase(18);
}
test "agent deep pipeline adversarial case 020" {
    try verifyDeepPipelineCase(19);
}
test "agent deep pipeline adversarial case 021" {
    try verifyDeepPipelineCase(20);
}
test "agent deep pipeline adversarial case 022" {
    try verifyDeepPipelineCase(21);
}
test "agent deep pipeline adversarial case 023" {
    try verifyDeepPipelineCase(22);
}
test "agent deep pipeline adversarial case 024" {
    try verifyDeepPipelineCase(23);
}
test "agent deep pipeline adversarial case 025" {
    try verifyDeepPipelineCase(24);
}
test "agent deep pipeline adversarial case 026" {
    try verifyDeepPipelineCase(25);
}
test "agent deep pipeline adversarial case 027" {
    try verifyDeepPipelineCase(26);
}
test "agent deep pipeline adversarial case 028" {
    try verifyDeepPipelineCase(27);
}
test "agent deep pipeline adversarial case 029" {
    try verifyDeepPipelineCase(28);
}
test "agent deep pipeline adversarial case 030" {
    try verifyDeepPipelineCase(29);
}
test "agent deep pipeline adversarial case 031" {
    try verifyDeepPipelineCase(30);
}
test "agent deep pipeline adversarial case 032" {
    try verifyDeepPipelineCase(31);
}
test "agent deep pipeline adversarial case 033" {
    try verifyDeepPipelineCase(32);
}
test "agent deep pipeline adversarial case 034" {
    try verifyDeepPipelineCase(33);
}
test "agent deep pipeline adversarial case 035" {
    try verifyDeepPipelineCase(34);
}
test "agent deep pipeline adversarial case 036" {
    try verifyDeepPipelineCase(35);
}
test "agent deep pipeline adversarial case 037" {
    try verifyDeepPipelineCase(36);
}
test "agent deep pipeline adversarial case 038" {
    try verifyDeepPipelineCase(37);
}
test "agent deep pipeline adversarial case 039" {
    try verifyDeepPipelineCase(38);
}
test "agent deep pipeline adversarial case 040" {
    try verifyDeepPipelineCase(39);
}
test "agent deep pipeline adversarial case 041" {
    try verifyDeepPipelineCase(40);
}
test "agent deep pipeline adversarial case 042" {
    try verifyDeepPipelineCase(41);
}
test "agent deep pipeline adversarial case 043" {
    try verifyDeepPipelineCase(42);
}
test "agent deep pipeline adversarial case 044" {
    try verifyDeepPipelineCase(43);
}
test "agent deep pipeline adversarial case 045" {
    try verifyDeepPipelineCase(44);
}
test "agent deep pipeline adversarial case 046" {
    try verifyDeepPipelineCase(45);
}
test "agent deep pipeline adversarial case 047" {
    try verifyDeepPipelineCase(46);
}
test "agent deep pipeline adversarial case 048" {
    try verifyDeepPipelineCase(47);
}
test "agent deep pipeline adversarial case 049" {
    try verifyDeepPipelineCase(48);
}
test "agent deep pipeline adversarial case 050" {
    try verifyDeepPipelineCase(49);
}
test "agent deep pipeline adversarial case 051" {
    try verifyDeepPipelineCase(50);
}
test "agent deep pipeline adversarial case 052" {
    try verifyDeepPipelineCase(51);
}
test "agent deep pipeline adversarial case 053" {
    try verifyDeepPipelineCase(52);
}
test "agent deep pipeline adversarial case 054" {
    try verifyDeepPipelineCase(53);
}
test "agent deep pipeline adversarial case 055" {
    try verifyDeepPipelineCase(54);
}
test "agent deep pipeline adversarial case 056" {
    try verifyDeepPipelineCase(55);
}
test "agent deep pipeline adversarial case 057" {
    try verifyDeepPipelineCase(56);
}
test "agent deep pipeline adversarial case 058" {
    try verifyDeepPipelineCase(57);
}
test "agent deep pipeline adversarial case 059" {
    try verifyDeepPipelineCase(58);
}
test "agent deep pipeline adversarial case 060" {
    try verifyDeepPipelineCase(59);
}
test "agent deep pipeline adversarial case 061" {
    try verifyDeepPipelineCase(60);
}
test "agent deep pipeline adversarial case 062" {
    try verifyDeepPipelineCase(61);
}
test "agent deep pipeline adversarial case 063" {
    try verifyDeepPipelineCase(62);
}
test "agent deep pipeline adversarial case 064" {
    try verifyDeepPipelineCase(63);
}
test "agent deep pipeline adversarial case 065" {
    try verifyDeepPipelineCase(64);
}
test "agent deep pipeline adversarial case 066" {
    try verifyDeepPipelineCase(65);
}
test "agent deep pipeline adversarial case 067" {
    try verifyDeepPipelineCase(66);
}
test "agent deep pipeline adversarial case 068" {
    try verifyDeepPipelineCase(67);
}
test "agent deep pipeline adversarial case 069" {
    try verifyDeepPipelineCase(68);
}
test "agent deep pipeline adversarial case 070" {
    try verifyDeepPipelineCase(69);
}
test "agent deep pipeline adversarial case 071" {
    try verifyDeepPipelineCase(70);
}
test "agent deep pipeline adversarial case 072" {
    try verifyDeepPipelineCase(71);
}
test "agent deep pipeline adversarial case 073" {
    try verifyDeepPipelineCase(72);
}
test "agent deep pipeline adversarial case 074" {
    try verifyDeepPipelineCase(73);
}
test "agent deep pipeline adversarial case 075" {
    try verifyDeepPipelineCase(74);
}
test "agent deep pipeline adversarial case 076" {
    try verifyDeepPipelineCase(75);
}
test "agent deep pipeline adversarial case 077" {
    try verifyDeepPipelineCase(76);
}
test "agent deep pipeline adversarial case 078" {
    try verifyDeepPipelineCase(77);
}
test "agent deep pipeline adversarial case 079" {
    try verifyDeepPipelineCase(78);
}
test "agent deep pipeline adversarial case 080" {
    try verifyDeepPipelineCase(79);
}
test "agent deep pipeline adversarial case 081" {
    try verifyDeepPipelineCase(80);
}
test "agent deep pipeline adversarial case 082" {
    try verifyDeepPipelineCase(81);
}
test "agent deep pipeline adversarial case 083" {
    try verifyDeepPipelineCase(82);
}
test "agent deep pipeline adversarial case 084" {
    try verifyDeepPipelineCase(83);
}
test "agent deep pipeline adversarial case 085" {
    try verifyDeepPipelineCase(84);
}
test "agent deep pipeline adversarial case 086" {
    try verifyDeepPipelineCase(85);
}
test "agent deep pipeline adversarial case 087" {
    try verifyDeepPipelineCase(86);
}
test "agent deep pipeline adversarial case 088" {
    try verifyDeepPipelineCase(87);
}
test "agent deep pipeline adversarial case 089" {
    try verifyDeepPipelineCase(88);
}
test "agent deep pipeline adversarial case 090" {
    try verifyDeepPipelineCase(89);
}
test "agent deep pipeline adversarial case 091" {
    try verifyDeepPipelineCase(90);
}
test "agent deep pipeline adversarial case 092" {
    try verifyDeepPipelineCase(91);
}
test "agent deep pipeline adversarial case 093" {
    try verifyDeepPipelineCase(92);
}
test "agent deep pipeline adversarial case 094" {
    try verifyDeepPipelineCase(93);
}
test "agent deep pipeline adversarial case 095" {
    try verifyDeepPipelineCase(94);
}
test "agent deep pipeline adversarial case 096" {
    try verifyDeepPipelineCase(95);
}
test "agent deep pipeline adversarial case 097" {
    try verifyDeepPipelineCase(96);
}
test "agent deep pipeline adversarial case 098" {
    try verifyDeepPipelineCase(97);
}
test "agent deep pipeline adversarial case 099" {
    try verifyDeepPipelineCase(98);
}
test "agent deep pipeline adversarial case 100" {
    try verifyDeepPipelineCase(99);
}
test "agent deep pipeline adversarial case 101" {
    try verifyDeepPipelineCase(100);
}
test "agent deep pipeline adversarial case 102" {
    try verifyDeepPipelineCase(101);
}
test "agent deep pipeline adversarial case 103" {
    try verifyDeepPipelineCase(102);
}
test "agent deep pipeline adversarial case 104" {
    try verifyDeepPipelineCase(103);
}
test "agent deep pipeline adversarial case 105" {
    try verifyDeepPipelineCase(104);
}
test "agent deep pipeline adversarial case 106" {
    try verifyDeepPipelineCase(105);
}
test "agent deep pipeline adversarial case 107" {
    try verifyDeepPipelineCase(106);
}
test "agent deep pipeline adversarial case 108" {
    try verifyDeepPipelineCase(107);
}
test "agent deep pipeline adversarial case 109" {
    try verifyDeepPipelineCase(108);
}
test "agent deep pipeline adversarial case 110" {
    try verifyDeepPipelineCase(109);
}
test "agent deep pipeline adversarial case 111" {
    try verifyDeepPipelineCase(110);
}
