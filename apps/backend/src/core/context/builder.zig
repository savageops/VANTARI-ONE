const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

const summary_prefix =
    "The conversation history before this point was compacted into the following summary:\n\n";

/// Legacy error type retained for backward compatibility. The builder now
/// self-heals orphan/unresolved tool-call tails by synthesizing interrupted
/// tool results rather than hard-failing. These errors are no longer returned
/// but tests and callers may still reference the type.
pub const Error = error{
    OrphanToolResultTranscript,
    UnresolvedToolCallTranscript,
};

/// Diagnostics produced while compiling durable session rows into provider
/// messages. The report is per compile and is emitted by the executor through
/// the existing event spine; it is not a second context ledger.
pub const CompileReport = struct {
    synthesized_tool_results: u32 = 0,
    skipped_tool_results: u32 = 0,

    pub fn hasDiagnostics(self: CompileReport) bool {
        return self.synthesized_tool_results > 0 or self.skipped_tool_results > 0;
    }
};

/// Synthetic tool result text appended when a tool call was interrupted
/// before producing a result (crash, cancellation, or cold-start recovery).
/// This makes the transcript structurally valid so the provider turn can
/// proceed instead of hard-failing with UnresolvedToolCallTranscript.
/// Harvested from Codex's and pi-mono's orphan-tail repair: they synthesize
/// placeholder results rather than rejecting the transcript.
const interrupted_tool_result = "[Tool execution was interrupted before producing a result. The session was recovered automatically.]";

pub fn appendProviderMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session: types.SessionRecord,
) !void {
    var report = CompileReport{};
    try appendProviderMessagesWithReport(allocator, workspace_root, messages, session, &report);
}

/// Compile the durable transcript and return repair/skip evidence to the
/// caller. The compatibility wrapper above intentionally keeps existing
/// callers free of diagnostics until they opt into the report.
pub fn appendProviderMessagesWithReport(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session: types.SessionRecord,
    report: *CompileReport,
) !void {
    report.* = .{};
    const checkpoint = try store.readLatestContextCheckpoint(allocator, workspace_root, session.id);
    if (checkpoint) |value| {
        defer value.deinit(allocator);
        try appendCompactedMessages(allocator, workspace_root, messages, session.id, value, report);
        return;
    }

    try appendRawMessages(allocator, workspace_root, messages, session.id, 0, report);
}

fn appendCompactedMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session_id: []const u8,
    checkpoint: types.ContextCheckpoint,
    report: *CompileReport,
) !void {
    const summary_message = try std.fmt.allocPrint(allocator, "{s}{s}", .{ summary_prefix, checkpoint.summary });
    defer allocator.free(summary_message);

    try messages.append(try types.initTextMessage(allocator, .user, summary_message));
    try appendRawMessages(allocator, workspace_root, messages, session_id, checkpoint.first_kept_seq, report);
}

fn appendRawMessages(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    messages: *std.array_list.Managed(types.ChatMessage),
    session_id: []const u8,
    first_kept_seq: u64,
    report: *CompileReport,
) !void {
    const turns = try store.readSessionMessages(allocator, workspace_root, session_id);
    defer types.deinitSessionMessages(allocator, turns);

    var pending_tool_calls: []const types.ToolCall = &.{};
    var pending_tool_index: usize = 0;

    for (turns) |turn| {
        if (first_kept_seq > 0 and turn.seq < first_kept_seq) continue;
        switch (turn.role) {
            .user => {
                // Self-healing: if tool calls are pending and a user message
                // arrives, the previous tool-call batch was interrupted.
                // Synthesize missing tool results so the transcript remains
                // structurally valid and the provider turn can proceed.
                if (pending_tool_index < pending_tool_calls.len) {
                    try synthesizePendingToolResults(allocator, messages, pending_tool_calls, pending_tool_index, report);
                    pending_tool_calls = &.{};
                    pending_tool_index = 0;
                }
                try messages.append(try types.initTextMessage(allocator, .user, turn.content));
            },
            .assistant => {
                // Self-healing: same repair when a new assistant message
                // arrives with unresolved tool calls from the previous one.
                if (pending_tool_index < pending_tool_calls.len) {
                    try synthesizePendingToolResults(allocator, messages, pending_tool_calls, pending_tool_index, report);
                    pending_tool_calls = &.{};
                    pending_tool_index = 0;
                }
                if (turn.tool_calls.len > 0) {
                    var msg = try types.initAssistantToolCallMessage(
                        allocator,
                        if (turn.content.len > 0) turn.content else null,
                        turn.tool_calls,
                    );
                    if (turn.reasoning) |reasoning| {
                        msg.reasoning = try allocator.dupe(u8, reasoning);
                    }
                    try messages.append(msg);
                    pending_tool_calls = turn.tool_calls;
                    pending_tool_index = 0;
                } else if (turn.reasoning != null) {
                    try messages.append(try types.initAssistantMessageWithReasoning(
                        allocator,
                        turn.content,
                        turn.reasoning,
                    ));
                } else {
                    try messages.append(try types.initTextMessage(allocator, .assistant, turn.content));
                }
            },
            .tool => {
                if (pending_tool_index >= pending_tool_calls.len) {
                    // Orphan tool result with no preceding tool call — skip it.
                    // This is self-healing for torn writes or duplicate rows.
                    report.skipped_tool_results += 1;
                    continue;
                }
                const tool_call_id = turn.tool_call_id orelse {
                    report.skipped_tool_results += 1;
                    continue;
                };
                if (!std.mem.eql(u8, tool_call_id, pending_tool_calls[pending_tool_index].id)) {
                    // ID mismatch — skip this orphan result and keep looking.
                    report.skipped_tool_results += 1;
                    continue;
                }
                try messages.append(try types.initToolMessage(allocator, tool_call_id, turn.content));
                pending_tool_index += 1;
                if (pending_tool_index == pending_tool_calls.len) {
                    pending_tool_calls = &.{};
                    pending_tool_index = 0;
                }
            },
        }
    }

    // Self-healing: if the transcript ends with unresolved tool calls (the
    // most common orphan — crash/cancel after the assistant tool_call was
    // persisted but before all tool results were appended), synthesize the
    // missing results. This makes the transcript structurally valid for the
    // provider dispatch. Previously this hard-failed with
    // UnresolvedToolCallTranscript, permanently bricking the session.
    if (pending_tool_index < pending_tool_calls.len) {
        try synthesizePendingToolResults(allocator, messages, pending_tool_calls, pending_tool_index, report);
    }
}

/// Append synthetic tool results for tool calls that were never resolved.
/// Each missing result carries the `interrupted_tool_result` text so the
/// provider understands the tool was interrupted, not that it failed with
/// an application error.
fn synthesizePendingToolResults(
    allocator: std.mem.Allocator,
    messages: *std.array_list.Managed(types.ChatMessage),
    tool_calls: []const types.ToolCall,
    start_index: usize,
    report: *CompileReport,
) !void {
    var i = start_index;
    while (i < tool_calls.len) : (i += 1) {
        try messages.append(try types.initToolMessage(allocator, tool_calls[i].id, interrupted_tool_result));
        report.synthesized_tool_results += 1;
    }
}
