const std = @import("std");
const store = @import("../sessions/store.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");
const loop = @import("loop.zig");

/// Unified tool batch execution. Extracted from loop.zig for seam isolation.
/// The parallel path runs all-parallel batches concurrently on worker threads;
/// the sequential path is handled inline in loop.zig. Both preserve source-order
/// append to messages.jsonl (single-threaded).
pub fn toolDefinitionSignalsCompletion(definitions: []const types.ToolDefinition, tool_name: []const u8) bool {
    for (definitions) |def| {
        if (std.mem.eql(u8, def.name, tool_name)) return def.signals_completion;
    }
    return false;
}

pub const ToolCallResult = struct {
    output: []u8,
    log_line: []u8,
    launched_child: bool,
    ok: bool,
    error_name: ?[]const u8,
};

pub fn executeToolCall(
    allocator: std.mem.Allocator,
    execution_context: tools.ExecutionContext,
    tool_call: types.ToolCall,
) !ToolCallResult {
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

const ParallelToolResult = struct {
    output: []u8 = &.{},
    log_line: []u8 = &.{},
    launched_child: bool = false,
    ok: bool = false,
    error_name: ?[]const u8 = null,
    completed: bool = false,
};

const ParallelWorkerContext = struct {
    allocator: std.mem.Allocator,
    execution_context: tools.ExecutionContext,
    tool_call: types.ToolCall,
    result: *ParallelToolResult,
};

fn parallelWorker(ctx: *ParallelWorkerContext) void {
    const r = executeToolCall(ctx.allocator, ctx.execution_context, ctx.tool_call) catch {
        ctx.result.completed = true;
        return;
    };
    ctx.result.output = r.output;
    ctx.result.log_line = r.log_line;
    ctx.result.launched_child = r.launched_child;
    ctx.result.ok = r.ok;
    ctx.result.error_name = r.error_name;
    ctx.result.completed = true;
}

/// Runs an all-parallel tool batch: preflight review sequentially, execute
/// concurrently on worker threads, append results in source order on the
/// caller thread. Preserves messages.jsonl source order and event spine
/// coherence (per-tool lifecycle stays ordered; cross-tool interleaving is
/// permitted by AGENTS.md §IV).
pub fn runParallel(
    allocator: std.mem.Allocator,
    config: types.Config,
    hooks: loop.Hooks,
    execution_context: tools.ExecutionContext,
    session: *types.SessionRecord,
    tool_calls: []const types.ToolCall,
    messages: *std.array_list.Managed(types.ChatMessage),
    cancel_token: *const tools.CancellationToken,
    requires_child_supervision: *bool,
) !void {
    const active_tool_definitions = tools.builtinDefinitionsForContext(execution_context);

    // Phase 1: Preflight review (sequential). Emit tool_reviewed events and
    // capture started timestamps. All tools are pre-approved (the caller
    // verified all_parallel); review events still fire for observability.
    var started_times = try allocator.alloc(i64, tool_calls.len);
    defer allocator.free(started_times);
    for (tool_calls, 0..) |tool_call, i| {
        const review_decision = tools.review.reviewToolCall(tool_call, active_tool_definitions);
        const review_event = try tools.review.renderReviewEvent(allocator, tool_call, review_decision);
        defer allocator.free(review_event);
        try loop.recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "tool_reviewed", review_event, session.status);

        started_times[i] = std.time.milliTimestamp();
        const started_event = try loop.renderToolStartedEvent(allocator, tool_call, started_times[i]);
        defer allocator.free(started_event);
        try loop.recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "tool_started", started_event, session.status);
    }

    // Phase 2: Execute concurrently. Each worker writes into its own result slot.
    var results = try allocator.alloc(ParallelToolResult, tool_calls.len);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};

    var worker_ctxs = try allocator.alloc(ParallelWorkerContext, tool_calls.len);
    defer allocator.free(worker_ctxs);

    var threads = try allocator.alloc(std.Thread, tool_calls.len);
    defer allocator.free(threads);

    for (tool_calls, 0..) |tool_call, i| {
        worker_ctxs[i] = .{
            .allocator = allocator,
            .execution_context = execution_context,
            .tool_call = tool_call,
            .result = &results[i],
        };
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{&worker_ctxs[i]});
    }

    for (threads) |t| t.join();

    // Check cancellation after workers finish.
    if (cancel_token.check()) {
        for (results) |r| {
            if (r.completed) {
                allocator.free(r.output);
                allocator.free(r.log_line);
            }
        }
        try loop.cancelSession(allocator, config.workspace_root, hooks, session, "Cancellation requested during parallel batch.");
        return loop.Error.Cancelled;
    }

    // Phase 3: Append in source order (single-threaded).
    for (tool_calls, 0..) |tool_call, i| {
        const r = results[i];
        if (r.launched_child) requires_child_supervision.* = true;

        const finished_at = std.time.milliTimestamp();
        const finished_event = try loop.renderToolFinishedEvent(
            allocator,
            tool_call,
            r.ok,
            r.error_name,
            started_times[i],
            finished_at,
        );
        defer allocator.free(finished_event);
        try loop.recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "tool_finished", finished_event, session.status);

        try loop.recordSessionEvent(allocator, config.workspace_root, hooks, session.id, "tool_completed", r.log_line, session.status);
        try messages.append(try types.initToolMessage(allocator, tool_call.id, r.output));
        try store.appendToolSessionMessage(
            allocator,
            config.workspace_root,
            session.id,
            tool_call.id,
            r.output,
            std.time.milliTimestamp(),
        );
        allocator.free(r.output);
        allocator.free(r.log_line);
    }
}
