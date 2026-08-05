const std = @import("std");
const docs_sync = @import("../docs/sync.zig");
const fsutil = @import("../../shared/fsutil.zig");
const profile_contract = @import("profile.zig");
const store = @import("../sessions/store.zig");
const scope_contract = @import("scope.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    AgentNameTaken,
    SpawnFailed,
    UnknownAgent,
    NoBranchesToConverge,
};

pub const Service = struct {
    config: *const types.Config,

    pub fn init(config: *const types.Config) Service {
        return .{
            .config = config,
        };
    }

    pub fn handle(self: *Service) tools.AgentService {
        return .{
            .context = self,
            .launchFn = launchFromHandle,
            .statusFn = statusFromHandle,
            .waitFn = waitFromHandle,
            .listFn = listFromHandle,
            .convergeFn = convergeFromHandle,
            .reconcileFn = reconcileFromHandle,
        };
    }
};

const WatchJob = struct {
    workspace_root: []u8,
    session_id: []u8,
    child: std.process.Child,

    fn deinit(self: *WatchJob) void {
        const allocator = std.heap.page_allocator;
        allocator.free(self.workspace_root);
        allocator.free(self.session_id);
        allocator.destroy(self);
    }
};

const heartbeat_stale_ms: i64 = 20_000;

const ChildLifecycle = struct {
    state: []const u8,
    next_parent_action: []const u8,
    heartbeat_event_type: []const u8,
    heartbeat_at_ms: i64,
    heartbeat_age_ms: i64,
};

fn launchFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    prompt: []const u8,
    requested_name: ?[]const u8,
    delegation_scope: scope_contract.DelegationScope,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return launch(service, allocator, parent_session_id, prompt, requested_name, delegation_scope);
}

/// Launch a child session checkpoint-addressed to a parent checkpoint. The
/// child's context window starts from the shard checkpoint (parent checkpoint
/// + branch input), not the full parent transcript. This is the
/// checkpoint-addressed child launch (roadmap P1-06).
///
/// Writes an `open` shard checkpoint to the parent's context.jsonl linking
/// the child to the parent checkpoint. When the child completes, the
/// convergeBranches function marks it `converged`.
pub fn launchFromCheckpoint(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    branch_seq: u64,
    prompt: []const u8,
    requested_name: ?[]const u8,
) ![]u8 {
    // Create the child session with the parent reference.
    const child_profile = profile_contract.defaultSubagentProfile();
    const agent_name = if (requested_name) |value|
        try allocator.dupe(u8, value)
    else
        try newAgentName(allocator);
    defer allocator.free(agent_name);

    var child_session = try store.initSessionWithOptions(allocator, service.config.workspace_root, prompt, .{
        .status = .initialized,
        .parent_session_id = parent_session_id,
        .display_name = agent_name,
        .agent_profile = child_profile.id,
    });
    defer child_session.deinit(allocator);

    // Write an open shard checkpoint to the PARENT's context.jsonl.
    // This marks the branch as active — the child's context starts from
    // parent_checkpoint_id + this branch's prompt.
    const branch_summary = try std.fmt.allocPrint(allocator, "Branch {d} ({s}): {s}", .{ branch_seq, agent_name, prompt });
    defer allocator.free(branch_summary);
    try store.appendShardCheckpoint(
        allocator,
        service.config.workspace_root,
        parent_session_id,
        parent_checkpoint_id,
        branch_seq,
        .open,
        branch_summary,
    );

    // Emit the delegation event on the child's event spine.
    try store.appendEvent(allocator, service.config.workspace_root, child_session.id, .{
        .event_type = "session_delegated",
        .message = branch_summary,
        .timestamp_ms = std.time.milliTimestamp(),
    });

    // Return the child session id for the caller to track.
    return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"session_id\":{f},\"agent_name\":{f},\"parent_checkpoint_id\":{f},\"branch_seq\":{d}}}", .{
        std.json.fmt(child_session.id, .{}),
        std.json.fmt(agent_name, .{}),
        std.json.fmt(parent_checkpoint_id, .{}),
        branch_seq,
    });
}

fn statusFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return status(service, allocator, parent_session_id, agent_name);
}

fn waitFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
    timeout_ms: usize,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return wait(service, allocator, parent_session_id, agent_name, timeout_ms);
}

fn listFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return list(service, allocator, parent_session_id);
}

fn convergeFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) anyerror!void {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return convergeFromListing(service, allocator, parent_session_id);
}

fn reconcileFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) anyerror!usize {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return reconcileOpenShards(service, allocator, parent_session_id);
}

/// Extract a field value from a single-line list entry. The list format is
/// space-separated `KEY VALUE` pairs on one line. Returns the value token
/// after the key, or null if the key is not found.
fn fieldValueFromListLine(line: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        // Skip whitespace to find the next token start.
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) break;

        // Read the token.
        const tok_start = i;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        const token = line[tok_start..i];

        // The NEXT token (if any) is this key's value.
        while (i < line.len and line[i] == ' ') : (i += 1) {}
        if (i >= line.len) return null;
        const val_start = i;
        while (i < line.len and line[i] != ' ') : (i += 1) {}
        const value = line[val_start..i];

        if (std.mem.eql(u8, token, key)) return value;
    }
    return null;
}

/// Converge all terminal children of a parent session. Reads the child list,
/// collects outputs from completed children, and calls convergeBranches to
/// write the convergence evidence. This is called by the executor loop when
/// all children are terminal — it's the live branch-and-converge path.
fn convergeFromListing(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) !void {
    const listing = try list(service, allocator, parent_session_id);
    defer allocator.free(listing);

    if (std.mem.eql(u8, std.mem.trim(u8, listing, " \r\n"), "No child agents.")) return;

    // The list output is one line per child with space-separated KEY VALUE pairs:
    // AGENT_NAME <name> STATUS <status> SESSION_ID <id> LIFECYCLE_STATE ... ...
    var results = std.array_list.Managed(ChildBranchResult).init(allocator);
    defer {
        for (results.items) |r| {
            allocator.free(r.agent_name);
            allocator.free(r.output);
        }
        results.deinit();
    }

    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;

        const child_status = fieldValueFromListLine(line, "STATUS") orelse continue;
        if (!std.mem.eql(u8, child_status, "completed")) continue;

        const session_id = fieldValueFromListLine(line, "SESSION_ID") orelse continue;
        const agent_name = fieldValueFromListLine(line, "AGENT_NAME") orelse "unknown";

        const output = store.readOutput(allocator, service.config.workspace_root, session_id) catch null;
        const owned_output = output orelse try allocator.dupe(u8, "");
        try results.append(.{
            .agent_name = try allocator.dupe(u8, agent_name),
            .output = owned_output,
        });
    }

    if (results.items.len == 0) return;

    // Determine the parent checkpoint ID for the convergence shard checkpoint.
    const parent_cp_id = blk: {
        const maybe_cp = store.readLatestContextCheckpoint(allocator, service.config.workspace_root, parent_session_id) catch null;
        if (maybe_cp) |cp| {
            defer cp.deinit(allocator);
            break :blk try allocator.dupe(u8, cp.id);
        }
        break :blk try allocator.dupe(u8, "parent-root");
    };
    defer allocator.free(parent_cp_id);

    try convergeBranches(service, allocator, parent_session_id, parent_cp_id, results.items);
}

/// Count existing shard_checkpoint entries for a parent session to derive
/// the next branch_seq. Each new branch gets a monotonically increasing seq
/// so multiple branches from the same parent are distinguishable (1, 2, 3...).
fn nextBranchSeq(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    parent_session_id: []const u8,
) !u64 {
    const checkpoints = store.readAllContextCheckpoints(
        allocator, workspace_root, parent_session_id,
    ) catch return 1;
    defer types.deinitContextCheckpoints(allocator, checkpoints);

    var max_seq: u64 = 0;
    for (checkpoints) |cp| {
        if (!std.mem.eql(u8, cp.entry_type, "shard_checkpoint")) continue;
        if (cp.branch_seq > max_seq) max_seq = cp.branch_seq;
    }
    return max_seq + 1;
}

fn launch(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    prompt: []const u8,
    requested_name: ?[]const u8,
    delegation_scope: scope_contract.DelegationScope,
) ![]u8 {
    try docs_sync.ensureRunStart(allocator, service.config.workspace_root);
    const child_profile = profile_contract.defaultSubagentProfile();
    try scope_contract.validateDelegationScope(delegation_scope, child_profile);

    const agent_name = if (requested_name) |value|
        try allocator.dupe(u8, value)
    else
        try newAgentName(allocator);
    defer allocator.free(agent_name);

    if (try childNameExists(allocator, service.config.workspace_root, parent_session_id, agent_name)) {
        return Error.AgentNameTaken;
    }

    var child_session = try store.initSessionWithOptions(allocator, service.config.workspace_root, prompt, .{
        .status = .initialized,
        .parent_session_id = parent_session_id,
        .display_name = agent_name,
        .agent_profile = child_profile.id,
    });
    defer child_session.deinit(allocator);

    const delegation_event = try scope_contract.renderDelegationEvent(allocator, delegation_scope, child_profile);
    defer allocator.free(delegation_event);

    try store.appendEvent(allocator, service.config.workspace_root, child_session.id, .{
        .event_type = "session_delegated",
        .message = delegation_event,
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try docs_sync.writePending(allocator, service.config.workspace_root, .{
        .session_id = child_session.id,
        .status = types.statusLabel(child_session.status),
        .prompt = child_session.prompt,
        .output = "",
        .updated_at_ms = child_session.updated_at_ms,
    });

    const delegation_log = try std.fmt.allocPrint(allocator, "child session delegated: {s} -> {s}", .{
        agent_name,
        child_session.id,
    });
    defer allocator.free(delegation_log);
    try docs_sync.appendLog(allocator, service.config.workspace_root, delegation_log);

    // Write an `open` shard checkpoint to the PARENT's context.jsonl. This
    // marks the branch as active in the shard ledger — the child's work is
    // tracked as a branch of the parent. When the child completes and the
    // executor's convergence path runs, this entry is superseded by a
    // `converged` (or cold-start `abandoned`) entry. (roadmap P0-1, P0-2)
    {
        const branch_seq = try nextBranchSeq(allocator, service.config.workspace_root, parent_session_id);
        const parent_cp_id = blk: {
            const maybe_cp = store.readLatestContextCheckpoint(allocator, service.config.workspace_root, parent_session_id) catch null;
            if (maybe_cp) |cp| {
                defer allocator.free(cp.id);
                break :blk try allocator.dupe(u8, cp.id);
            }
            break :blk try allocator.dupe(u8, "parent-root");
        };
        defer allocator.free(parent_cp_id);

        const branch_summary = try std.fmt.allocPrint(allocator, "Branch {d} ({s}): {s}", .{ branch_seq, agent_name, prompt });
        defer allocator.free(branch_summary);
        store.appendShardCheckpoint(
            allocator,
            service.config.workspace_root,
            parent_session_id,
            parent_cp_id,
            branch_seq,
            .open,
            branch_summary,
        ) catch |err| {
            // A shard checkpoint write failure is not fatal to the delegation
            // itself — the child can still run. But it means the branch won't
            // be tracked in the shard ledger, so log the failure.
            const warn = try std.fmt.allocPrint(allocator, "shard checkpoint write failed for branch {d}: {s}", .{ branch_seq, @errorName(err) });
            defer allocator.free(warn);
            docs_sync.appendLog(allocator, service.config.workspace_root, warn) catch {};
        };
    }

    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(exe_path);
    try argv.append("run");
    try argv.append("--json");
    try argv.append("--no-agent-tools");
    try argv.append("--session-id");
    try argv.append(child_session.id);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = service.config.workspace_root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const job = try std.heap.page_allocator.create(WatchJob);
    errdefer std.heap.page_allocator.destroy(job);
    job.* = .{
        .workspace_root = try std.heap.page_allocator.dupe(u8, service.config.workspace_root),
        .session_id = try std.heap.page_allocator.dupe(u8, child_session.id),
        .child = child,
    };

    const thread = try std.Thread.spawn(.{}, watchChildProcess, .{job});
    thread.detach();

    return std.fmt.allocPrint(
        allocator,
        "AGENT_NAME {s}\nSTATUS {s}\nSESSION_ID {s}\nPARENT_SESSION_ID {s}\nCAPABILITY_PROFILE {s}\nSCOPE_DEPTH {}\nCONTACT_BUDGET {}\nVALIDATION_STATUS {s}\nESCALATION_REASON {s}\nPARENT_CAPABILITY_PROFILE {s}\nPROMPT {s}",
        .{
            agent_name,
            types.statusLabel(child_session.status),
            child_session.id,
            parent_session_id,
            child_profile.id,
            delegation_scope.scope_depth,
            delegation_scope.contact_budget,
            scope_contract.validationStatusLabel(delegation_scope.validation_status),
            scope_contract.escalationReasonLabel(delegation_scope),
            scope_contract.parentCapabilityProfileLabel(delegation_scope),
            prompt,
        },
    );
}

fn status(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
) ![]u8 {
    var session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
    defer session.deinit(allocator);
    return renderChildSession(allocator, service.config.workspace_root, session, .{});
}

fn wait(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
    timeout_ms: usize,
) ![]u8 {
    const started_at = std.time.milliTimestamp();

    while (true) {
        var session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
        defer session.deinit(allocator);

        if (isTerminal(session.status)) {
            return renderChildSession(allocator, service.config.workspace_root, session, .{
                .wait_state = "terminal",
            });
        }

        if (timeout_ms > 0 and std.time.milliTimestamp() - started_at >= @as(i64, @intCast(timeout_ms))) {
            return renderChildSession(allocator, service.config.workspace_root, session, .{
                .wait_state = "timeout",
                .wait_timeout_ms = timeout_ms,
            });
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

/// Converge N child branch results into the parent session. This is the
/// branch-and-converge reprocessing loop (roadmap P0-2):
///
/// 1. Read the output from each completed child session.
/// 2. Merge them into a convergence summary.
/// 3. Append a `converged` shard checkpoint to the parent's context.jsonl.
/// 4. Append the merged result as an assistant message to the parent's transcript.
///
/// The parent transcript is append-only — convergence adds evidence, never
/// rewrites. The shard checkpoint marks the branch lifecycle as converged.
pub fn convergeBranches(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    child_sessions: []const ChildBranchResult,
) !void {
    if (child_sessions.len == 0) return Error.NoBranchesToConverge;

    // 1. Merge child outputs into a convergence summary.
    var summary = std.array_list.Managed(u8).init(allocator);
    errdefer summary.deinit();
    const writer = summary.writer();
    try writer.print("Converged {d} branch(es):\n", .{child_sessions.len});
    for (child_sessions, 0..) |branch, i| {
        try writer.print("\n## Branch {d} ({s})\n", .{ i + 1, branch.agent_name });
        if (branch.output.len > 0) {
            try writer.print("{s}\n", .{branch.output});
        } else {
            try writer.writeAll("(no output)\n");
        }
    }
    const summary_str = try summary.toOwnedSlice();
    defer allocator.free(summary_str);

    // 2. Append a converged shard checkpoint to the parent's context.jsonl.
    try store.appendShardCheckpoint(
        allocator,
        service.config.workspace_root,
        parent_session_id,
        parent_checkpoint_id,
        1, // branch_seq for the convergence
        .converged,
        summary_str,
    );

    // 3. Append the merged result as an assistant message to the parent.
    try store.appendSessionMessage(
        allocator,
        service.config.workspace_root,
        parent_session_id,
        .assistant,
        summary_str,
        std.time.milliTimestamp(),
    );

    // 4. Emit a convergence event on the parent's event spine.
    try store.appendEvent(allocator, service.config.workspace_root, parent_session_id, .{
        .event_type = "branch_converged",
        .message = summary_str,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

/// Result of a completed child branch — the agent name and its output.
pub const ChildBranchResult = struct {
    agent_name: []const u8,
    output: []const u8,
};

/// Reconcile open shard branches at cold start. Scans the parent session's
/// context.jsonl for shard_checkpoint entries with branch_status "open".
/// Any open shard whose latest lifecycle state is still "open" (no subsequent
/// converged/abandoned entry for the same parent+branch_seq) is marked
/// abandoned — the owning child process is presumed dead.
///
/// This is the shard-graph cold-start recovery primitive (roadmap P0-4b).
/// Returns the count of shards marked abandoned.
pub fn reconcileOpenShards(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) !usize {
    const checkpoints = try store.readAllContextCheckpoints(
        allocator, service.config.workspace_root, parent_session_id,
    );
    defer types.deinitContextCheckpoints(allocator, checkpoints);

    // Track which (parent_checkpoint_id, branch_seq) pairs are still open.
    // A pair is "settled" if any subsequent entry for the same pair has
    // status converged or abandoned.
    var abandoned_count: usize = 0;

    for (checkpoints, 0..) |cp, i| {
        // Only shard checkpoints with parent_checkpoint_id are relevant.
        if (cp.parent_checkpoint_id == null) continue;
        if (!std.mem.eql(u8, cp.entry_type, "shard_checkpoint")) continue;

        // Only "open" shards are candidates for abandonment. If the branch
        // status is converged or abandoned, it's already settled.
        if (cp.branch_status != .open) continue;

        // Check if any later checkpoint settles this branch (same parent +
        // branch_seq, with a non-open status). If so, the open entry was
        // already superseded and should NOT be re-abandoned.
        var settled = false;
        for (checkpoints[i + 1 ..]) |later| {
            if (later.parent_checkpoint_id == null) continue;
            if (!std.mem.eql(u8, later.entry_type, "shard_checkpoint")) continue;
            if (std.mem.eql(u8, later.parent_checkpoint_id.?, cp.parent_checkpoint_id.?) and
                later.branch_seq == cp.branch_seq and
                later.branch_status != .open)
            {
                settled = true;
                break;
            }
        }

        // If already settled by a later entry, skip.
        if (settled) continue;

        if (!settled) {
            // This open shard was never converged or abandoned — mark it
            // abandoned now (the child process is presumed dead at cold start).
            try store.appendShardCheckpoint(
                allocator,
                service.config.workspace_root,
                parent_session_id,
                cp.parent_checkpoint_id.?,
                cp.branch_seq,
                .abandoned,
                "Branch abandoned at cold start: owning process is no longer running.",
            );
            try store.appendEvent(allocator, service.config.workspace_root, parent_session_id, .{
                .event_type = "branch_abandoned",
                .message = "Open shard abandoned at cold-start reconciliation.",
                .timestamp_ms = std.time.milliTimestamp(),
            });
            abandoned_count += 1;
        }
    }

    return abandoned_count;
}

fn list(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) ![]u8 {
    const sessions_root = try store.sessionsRootPath(allocator, service.config.workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return allocator.dupe(u8, "No child agents.");

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const now_ms = std.time.milliTimestamp();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var session = store.readSessionRecord(allocator, service.config.workspace_root, entry.name) catch continue;
        defer session.deinit(allocator);

        if (!matchesChildSession(session, parent_session_id, null)) continue;

        const latest_event = try store.readLatestEvent(allocator, service.config.workspace_root, session.id);
        defer if (latest_event) |event| event.deinit(allocator);
        const lifecycle = lifecycleForSession(session, latest_event, now_ms);

        try output.writer().print(
            "AGENT_NAME {s} STATUS {s} SESSION_ID {s} LIFECYCLE_STATE {s} HEARTBEAT_AT_MS {d} HEARTBEAT_AGE_MS {d} NEXT_PARENT_ACTION {s} UPDATED_AT_MS {d}\n",
            .{
                session.display_name orelse session.id,
                types.statusLabel(session.status),
                session.id,
                lifecycle.state,
                lifecycle.heartbeat_at_ms,
                lifecycle.heartbeat_age_ms,
                lifecycle.next_parent_action,
                session.updated_at_ms,
            },
        );
        count += 1;
    }

    if (count == 0) return allocator.dupe(u8, "No child agents.");
    return output.toOwnedSlice();
}

fn watchChildProcess(job: *WatchJob) void {
    defer job.deinit();

    const allocator = std.heap.page_allocator;
    const term = job.child.wait() catch {
        finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildWaitFailed", null) catch {};
        return;
    };

    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        .Signal => |signal| @as(i32, @intCast(signal)),
        .Stopped => |signal| @as(i32, @intCast(signal)),
        .Unknown => |code| @as(i32, @intCast(code)),
    };

    if (exit_code != 0) {
        finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildExitNonZero", exit_code) catch {};
        return;
    }

    var session = store.readSessionRecord(allocator, job.workspace_root, job.session_id) catch return;
    defer session.deinit(allocator);

    if (isTerminal(session.status)) return;
    finalizeAbnormalExit(allocator, job.workspace_root, job.session_id, "ChildExitWithoutTerminalState", exit_code) catch {};
}

fn finalizeAbnormalExit(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    reason: []const u8,
    exit_code: ?i32,
) !void {
    var session = store.readSessionRecord(allocator, workspace_root, session_id) catch return;
    defer session.deinit(allocator);

    if (isTerminal(session.status)) return;

    const failure_reason = if (exit_code) |value|
        try std.fmt.allocPrint(allocator, "{s} (exit code {d})", .{ reason, value })
    else
        try allocator.dupe(u8, reason);
    defer allocator.free(failure_reason);

    try store.appendEvent(allocator, workspace_root, session.id, .{
        .event_type = "session_failed",
        .message = failure_reason,
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try store.setSessionFailure(allocator, workspace_root, &session, failure_reason);
    try docs_sync.writePending(allocator, workspace_root, .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = failure_reason,
        .updated_at_ms = session.updated_at_ms,
    });

    const log_line = try std.fmt.allocPrint(allocator, "child session failed: {s} ({s})", .{
        session.display_name orelse session.id,
        failure_reason,
    });
    defer allocator.free(log_line);
    try docs_sync.appendLog(allocator, workspace_root, log_line);
}

fn findChildSessionByName(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    parent_session_id: []const u8,
    agent_name: []const u8,
) !types.SessionRecord {
    const sessions_root = try store.sessionsRootPath(allocator, workspace_root);
    defer allocator.free(sessions_root);

    if (!fsutil.fileExists(sessions_root)) return Error.UnknownAgent;

    const sessions_root_abs = try fsutil.resolveAbsolute(allocator, sessions_root);
    defer allocator.free(sessions_root_abs);

    var dir = try std.fs.openDirAbsolute(sessions_root_abs, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var session = store.readSessionRecord(allocator, workspace_root, entry.name) catch continue;
        if (matchesChildSession(session, parent_session_id, agent_name)) {
            return session;
        }
        session.deinit(allocator);
    }

    return Error.UnknownAgent;
}

fn childNameExists(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    parent_session_id: []const u8,
    agent_name: []const u8,
) !bool {
    _ = findChildSessionByName(allocator, workspace_root, parent_session_id, agent_name) catch |err| switch (err) {
        Error.UnknownAgent => return false,
        else => return err,
    };
    return true;
}

fn matchesChildSession(session: types.SessionRecord, parent_session_id: []const u8, agent_name: ?[]const u8) bool {
    const session_parent = session.parent_session_id orelse return false;
    if (!std.mem.eql(u8, session_parent, parent_session_id)) return false;

    if (agent_name) |value| {
        const session_name = session.display_name orelse return false;
        return std.mem.eql(u8, session_name, value);
    }

    return true;
}

fn renderChildSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session: types.SessionRecord,
    options: RenderOptions,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const latest_event = try store.readLatestEvent(allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(allocator);
    const lifecycle = lifecycleForSession(session, latest_event, std.time.milliTimestamp());

    try output.writer().print(
        "AGENT_NAME {s}\nSTATUS {s}\nSESSION_ID {s}\n",
        .{
            session.display_name orelse session.id,
            types.statusLabel(session.status),
            session.id,
        },
    );

    if (session.parent_session_id) |value| try output.writer().print("PARENT_SESSION_ID {s}\n", .{value});
    if (session.agent_profile) |value| try output.writer().print("AGENT_PROFILE {s}\n", .{value});
    try output.writer().print("CREATED_AT_MS {d}\n", .{session.created_at_ms});
    try output.writer().print("UPDATED_AT_MS {d}\n", .{session.updated_at_ms});
    try output.writer().print("TERMINAL {s}\n", .{if (isTerminal(session.status)) "true" else "false"});
    try output.writer().print("LIFECYCLE_STATE {s}\n", .{lifecycle.state});
    try output.writer().print("NEXT_PARENT_ACTION {s}\n", .{lifecycle.next_parent_action});
    try output.writer().print("HEARTBEAT_EVENT_TYPE {s}\n", .{lifecycle.heartbeat_event_type});
    try output.writer().print("HEARTBEAT_AT_MS {d}\n", .{lifecycle.heartbeat_at_ms});
    try output.writer().print("HEARTBEAT_AGE_MS {d}\n", .{lifecycle.heartbeat_age_ms});
    if (options.wait_state) |value| try output.writer().print("WAIT_STATE {s}\n", .{value});
    if (options.wait_timeout_ms) |value| try output.writer().print("WAIT_TIMEOUT_MS {d}\n", .{value});
    try output.writer().print("PROMPT {s}\n", .{session.prompt});
    if (latest_event) |event| {
        try output.writer().print("LATEST_EVENT_TYPE {s}\n", .{event.event_type});
        try output.writer().print("LATEST_EVENT_AT_MS {d}\n", .{event.timestamp_ms});
        try output.writer().print("LATEST_EVENT_MESSAGE {s}\n", .{event.message});
    }

    if (session.status == .completed) {
        if (try store.readOutput(allocator, workspace_root, session.id)) |result| {
            defer allocator.free(result);
            try output.writer().print("OUTPUT {s}\n", .{result});
        }
    }

    if (session.failure_reason) |value| try output.writer().print("FAILURE_REASON {s}\n", .{value});

    return output.toOwnedSlice();
}

fn lifecycleForSession(session: types.SessionRecord, latest_event: ?types.SessionEvent, now_ms: i64) ChildLifecycle {
    const heartbeat_at_ms = if (latest_event) |event| event.timestamp_ms else session.updated_at_ms;
    const heartbeat_age_ms = if (now_ms > heartbeat_at_ms) now_ms - heartbeat_at_ms else 0;
    const heartbeat_event_type = if (latest_event) |event| event.event_type else "none";

    if (session.status == .completed) {
        return .{
            .state = "completed",
            .next_parent_action = "collect_result",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    if (session.status == .failed or session.status == .cancelled) {
        return .{
            .state = "errored",
            .next_parent_action = "follow_up",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    if (session.status == .initialized or heartbeat_age_ms >= heartbeat_stale_ms) {
        return .{
            .state = "waiting_for_input",
            .next_parent_action = "follow_up",
            .heartbeat_event_type = heartbeat_event_type,
            .heartbeat_at_ms = heartbeat_at_ms,
            .heartbeat_age_ms = heartbeat_age_ms,
        };
    }

    return .{
        .state = "processing",
        .next_parent_action = "monitor",
        .heartbeat_event_type = heartbeat_event_type,
        .heartbeat_at_ms = heartbeat_at_ms,
        .heartbeat_age_ms = heartbeat_age_ms,
    };
}

const RenderOptions = struct {
    wait_state: ?[]const u8 = null,
    wait_timeout_ms: ?usize = null,
};

fn newAgentName(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent-{d}-{x}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

fn isTerminal(status_value: types.SessionStatus) bool {
    return status_value == .completed or status_value == .failed or status_value == .cancelled;
}
