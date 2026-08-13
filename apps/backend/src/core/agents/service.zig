const std = @import("std");
const docs_sync = @import("../docs/sync.zig");
const config_file = @import("../config/file.zig");
const fsutil = @import("../../shared/fsutil.zig");
const mailbox = @import("mailbox.zig");
const profile_contract = @import("profile.zig");
const agent_spec = @import("spec.zig");
const child_supervisor = @import("supervisor.zig");
const provider = @import("../providers/openai_compatible.zig");
const routes = @import("../providers/routes.zig");
const store = @import("../sessions/store.zig");
const tickets = @import("../tickets/index.zig");
const scope_contract = @import("scope.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    AgentNameTaken,
    SpawnFailed,
    UnknownAgent,
    NoBranchesToConverge,
    InvalidBatch,
    MissingParentSession,
    TicketClaimReplay,
};

pub const Service = struct {
    config: *const types.Config,
    transport: provider.Transport,
    supervisor: child_supervisor.Supervisor = .{},
    recovery_mutex: std.Thread.Mutex = .{},
    recovered_parents: std.StringHashMapUnmanaged(void) = .{},

    pub fn init(config: *const types.Config) Service {
        return initWithTransport(config, .{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
        });
    }

    pub fn initWithTransport(config: *const types.Config, transport: provider.Transport) Service {
        return .{
            .config = config,
            .transport = transport,
        };
    }

    pub fn deinit(self: *Service) void {
        self.supervisor.deinit();
        var recovered = self.recovered_parents.iterator();
        while (recovered.next()) |entry| std.heap.page_allocator.free(entry.key_ptr.*);
        self.recovered_parents.deinit(std.heap.page_allocator);
    }

    pub fn handle(self: *Service) tools.AgentService {
        return .{
            .context = self,
            .launchFn = launchFromHandle,
            .launchBatchFn = launchBatchFromHandle,
            .launchTicketFn = launchTicketFromHandle,
            .capacityFn = capacityFromHandle,
            .eligibilityFn = eligibilityFromHandle,
            .statusFn = statusFromHandle,
            .waitFn = waitFromHandle,
            .listFn = listFromHandle,
            .convergeFn = convergeFromHandle,
            .reconcileFn = reconcileFromHandle,
            .waitParentFn = waitParentFromHandle,
            .cancelGroupFn = cancelGroupFromHandle,
            .cancelParentFn = cancelParentFromHandle,
            .bindEventSinkFn = bindEventSinkFromHandle,
            .notifySessionEventFn = notifySessionEventFromHandle,
        };
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

fn launchBatchFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    shared_context: []const u8,
    tasks_to_launch: []const tools.AgentTaskRequest,
    delegation_scope: scope_contract.DelegationScope,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return launchBatch(service, allocator, parent_session_id, shared_context, tasks_to_launch, delegation_scope);
}

fn launchTicketFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: tools.TicketTaskRequest,
) anyerror!tools.TicketLaunchReceipt {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return launchTicket(service, allocator, request);
}

fn capacityFromHandle(ctx_ptr: ?*anyopaque) anyerror!tools.AgentCapacitySnapshot {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return readCapacity(service);
}

fn eligibilityFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    parent_profile_id: []const u8,
    depth_remaining: usize,
) anyerror![]u8 {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return renderEligibilitySnapshot(service, allocator, session_id, parent_profile_id, depth_remaining);
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
    _ = try recoverReceiptGroups(service, allocator, parent_session_id);
    if (try service.supervisor.convergeParent(allocator, parent_session_id) > 0) return;
    return convergeLegacyChildren(service, allocator, parent_session_id);
}

fn reconcileFromHandle(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) anyerror!usize {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    const stale_receipts = try recoverReceiptGroups(service, allocator, parent_session_id);
    const abandoned_legacy = try reconcileOpenShards(service, allocator, parent_session_id);
    return stale_receipts + abandoned_legacy;
}

fn waitParentFromHandle(
    ctx_ptr: ?*anyopaque,
    parent_session_id: []const u8,
    timeout_ms: usize,
) anyerror!tools.AgentGroupSnapshot {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    _ = try recoverReceiptGroups(service, std.heap.page_allocator, parent_session_id);
    return service.supervisor.waitParent(parent_session_id, timeout_ms);
}

fn cancelGroupFromHandle(
    ctx_ptr: ?*anyopaque,
    group_id: []const u8,
    reason: []const u8,
) anyerror!usize {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    return service.supervisor.cancelGroup(group_id, reason);
}

fn cancelParentFromHandle(
    ctx_ptr: ?*anyopaque,
    parent_session_id: []const u8,
    reason: []const u8,
) anyerror!usize {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    _ = recoverReceiptGroups(service, std.heap.page_allocator, parent_session_id) catch 0;
    return service.supervisor.cancelParent(parent_session_id, reason);
}

fn bindEventSinkFromHandle(ctx_ptr: ?*anyopaque, sink: tools.AgentEventSink) void {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    service.supervisor.bindEventSink(sink);
}

fn notifySessionEventFromHandle(
    ctx_ptr: ?*anyopaque,
    session_id: []const u8,
    seq: u64,
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const service: *Service = @ptrCast(@alignCast(ctx_ptr.?));
    try service.supervisor.notifySessionEvent(session_id, seq, event_type, message, timestamp_ms);
}

/// Compatibility convergence for receipt-less children created before group
/// receipts existed. Consume typed SessionRecord values directly; never parse
/// the plaintext list read model back into kernel state.
fn convergeLegacyChildren(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) !void {
    const sessions = try store.listSessionRecords(allocator, service.config.workspace_root);
    defer types.deinitSessionRecords(allocator, sessions);
    var results = std.array_list.Managed(ChildBranchResult).init(allocator);
    defer {
        for (results.items) |r| {
            allocator.free(r.agent_name);
            allocator.free(r.output);
        }
        results.deinit();
    }

    for (sessions) |session| {
        if (!matchesChildSession(session, parent_session_id, null) or
            session.execution_receipt != null or session.status != .completed) continue;
        const output = store.readOutput(allocator, service.config.workspace_root, session.id) catch null;
        const owned_output = output orelse try allocator.dupe(u8, "");
        try results.append(.{
            .agent_name = try allocator.dupe(u8, session.display_name orelse session.id),
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
        allocator,
        workspace_root,
        parent_session_id,
    ) catch return 1;
    defer types.deinitContextCheckpoints(allocator, checkpoints);

    var max_seq: u64 = 0;
    for (checkpoints) |cp| {
        if (!std.mem.eql(u8, cp.entry_type, "shard_checkpoint")) continue;
        if (cp.branch_seq > max_seq) max_seq = cp.branch_seq;
    }
    return max_seq + 1;
}

/// Configured capacity activation / Re-read the sole pool ceiling at every
/// admission or health boundary. Why: the long-lived execution owner must not
/// freeze the first Settings value. Preserves: Supervisor returns the actual
/// busy ceiling until idle replacement is safe. Evidence: Move 28 config-refresh
/// contention test.
fn ensureSupervisorStarted(service: *Service, allocator: std.mem.Allocator) !usize {
    const max_concurrency = try config_file.loadAgentMaxConcurrency(allocator, service.config.workspace_root);
    return service.supervisor.start(max_concurrency);
}

fn readCapacity(service: *Service) !tools.AgentCapacitySnapshot {
    _ = try ensureSupervisorStarted(service, std.heap.page_allocator);
    return service.supervisor.capacity();
}

fn appendEligibilityAgent(
    allocator: std.mem.Allocator,
    output: *std.array_list.Managed(agent_spec.EligibilityAgent),
    spec: agent_spec.AgentSpec,
    route: routes.ResolvedRoute,
) !void {
    const provider_id = try allocator.dupe(u8, route.providerId());
    errdefer allocator.free(provider_id);
    const model = try allocator.dupe(u8, route.config.openai_model);
    errdefer allocator.free(model);
    const effort = try allocator.dupe(u8, route.config.effort);
    errdefer allocator.free(effort);
    try output.append(.{
        .id = spec.id,
        .when_to_use = spec.when_to_use,
        .kind = route.execution_kind.label(),
        .route_role = route.role.label(),
        .capability_profile = spec.capability_profile_id,
        .provider = provider_id,
        .model = model,
        .effort = effort,
        .max_children = spec.max_children,
    });
}

fn eligibilityBlockReason(profile: profile_contract.CapabilityProfile, depth_remaining: usize) ?[]const u8 {
    if (!profile.delegation_policy.allow_child_launch) return "delegation_denied";
    if (depth_remaining == 0 or profile.budget_policy.max_scope_depth_without_reason == 0) return "depth_exhausted";
    if (profile.budget_policy.max_contact_budget_without_reason == 0) return "contact_budget_exhausted";
    return null;
}

/// Model eligibility projection / Join route-resolved specialists with the
/// actual configured pool and current team state. Why: the model chooses from
/// truthful active, idle, queued, and communication options. Preserves: an
/// unused pool is not started by discovery. Evidence: Moves 27-28 eligibility
/// receipt and capacity tests.
fn renderEligibilitySnapshot(
    service: *Service,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    parent_profile_id: []const u8,
    depth_remaining: usize,
) ![]u8 {
    const profile = try profile_contract.resolveProfile(parent_profile_id);
    const block_reason = eligibilityBlockReason(profile, depth_remaining);
    const configured_max = try config_file.loadAgentMaxConcurrency(allocator, service.config.workspace_root);
    const capacity = try service.supervisor.capacityProjection(configured_max);
    const team = service.supervisor.waitParent(session_id, 0);

    var session = try store.readSessionRecord(allocator, service.config.workspace_root, session_id);
    defer session.deinit(allocator);
    const has_group_target = if (session.execution_receipt) |receipt| receipt.group_id.len > 0 else false;

    var registry = try agent_spec.loadRegistry(allocator, service.config.workspace_root);
    defer registry.deinit();
    var eligible = std.array_list.Managed(agent_spec.EligibilityAgent).init(allocator);
    defer {
        for (eligible.items) |agent| {
            allocator.free(agent.provider);
            allocator.free(agent.model);
            allocator.free(agent.effort);
        }
        eligible.deinit();
    }
    var unavailable = std.array_list.Managed(agent_spec.UnavailableAgent).init(allocator);
    defer unavailable.deinit();

    if (block_reason == null) {
        for (registry.all()) |spec| {
            var route = routes.resolve(allocator, service.config.*, spec.route_role, .{
                .max_steps = spec.max_steps,
                .max_tool_calls = spec.max_tool_calls,
                .execution_kind = spec.execution_kind,
                .capability_profile_id = spec.capability_profile_id,
            }) catch |err| {
                if (err == error.OutOfMemory) return err;
                try unavailable.append(.{ .id = spec.id, .reason = "route_unavailable" });
                continue;
            };
            defer route.deinit(allocator);
            try appendEligibilityAgent(allocator, &eligible, spec, route);
        }
    }

    return agent_spec.renderEligibilitySnapshot(allocator, eligible.items, unavailable.items, .{
        .parent_profile_id = profile.id,
        .delegation_allowed = block_reason == null,
        .delegation_reason = block_reason,
        .depth_remaining = depth_remaining,
        .scope_without_reason = profile.budget_policy.max_scope_depth_without_reason,
        .contact_without_reason = profile.budget_policy.max_contact_budget_without_reason,
        .capacity_max = capacity.max,
        .capacity_queued = capacity.queued,
        .capacity_running = capacity.running,
        .capacity_idle = capacity.idle,
        .capacity_available = capacity.available,
        .team_groups = team.groups,
        .team_queued = team.queued,
        .team_running = team.running,
        .team_completed = team.completed,
        .team_failed = team.failed,
        .team_cancelled = team.cancelled,
        .team_ready = team.ready,
        .team_terminal = team.terminal,
        .has_parent_target = session.parent_session_id != null,
        .has_group_target = has_group_target,
    });
}

fn resolveTicketAgent(
    registry: *agent_spec.Registry,
    requested_hint: []const u8,
    category: []const u8,
) !agent_spec.AgentSpec {
    if (hasText(requested_hint)) {
        if (registry.resolve(requested_hint)) |spec| return spec else |err| switch (err) {
            agent_spec.Error.UnknownAgentSpec => {},
            else => return err,
        }
    }
    return registry.resolve(tickets.agentHintForCategory(category));
}

/// Launch one already-scheduled ticket through the existing route/session and
/// Supervisor owners. The serialized claim commits lease and deterministic
/// child identity before any child session can be materialized or submitted.
fn launchTicket(
    service: *Service,
    allocator: std.mem.Allocator,
    request: tools.TicketTaskRequest,
) !tools.TicketLaunchReceipt {
    if (!hasText(request.ticket_id) or !hasText(request.title) or !hasText(request.description) or !hasText(request.category)) return Error.InvalidBatch;
    if (!hasText(request.worker_id) or !hasText(request.lease_token) or !hasText(request.agent_hint) or !hasText(request.idempotency_key)) return Error.InvalidBatch;

    const capacity = try readCapacity(service);
    if (capacity.available == 0) return child_supervisor.Error.PoolFull;

    var registry = try agent_spec.loadRegistry(allocator, service.config.workspace_root);
    defer registry.deinit();
    const spec = try resolveTicketAgent(&registry, request.agent_hint, request.category);
    const route = try std.heap.page_allocator.create(routes.ResolvedRoute);
    var route_owned = true;
    defer if (route_owned) {
        route.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(route);
    };
    route.* = routes.resolve(std.heap.page_allocator, service.config.*, spec.route_role, .{
        .max_steps = spec.max_steps,
        .max_tool_calls = spec.max_tool_calls,
        .execution_kind = spec.execution_kind,
        .capability_profile_id = spec.capability_profile_id,
    }) catch |err| {
        std.heap.page_allocator.destroy(route);
        route_owned = false;
        return err;
    };

    const group_id = try newGroupId(allocator);
    defer allocator.free(group_id);
    const task_id = try std.fmt.allocPrint(allocator, "ticket-task-{s}-{d}", .{ request.ticket_id, request.attempt });
    defer allocator.free(task_id);
    const display_name = try std.fmt.allocPrint(allocator, "ticket-{s}-{s}", .{ request.ticket_id, spec.id });
    defer allocator.free(display_name);
    const shared_context = try std.fmt.allocPrint(allocator, "Ticket {s}\nTitle: {s}\nCategory: {s}", .{ request.ticket_id, request.title, request.category });
    defer allocator.free(shared_context);
    const child_prompt = try renderChildPrompt(allocator, shared_context, request.description, spec, "{}");
    defer allocator.free(child_prompt);
    const child_session_id = try ticketSessionId(allocator, "child", request.idempotency_key);
    defer allocator.free(child_session_id);

    const parent_session_id: []const u8 = if (request.source_session_id.len > 0) blk: {
        var parent = store.readSessionRecord(allocator, service.config.workspace_root, request.source_session_id) catch return Error.MissingParentSession;
        parent.deinit(allocator);
        break :blk request.source_session_id;
    } else try ticketSessionId(allocator, "coordinator", request.ticket_id);
    const owns_synthetic_parent = request.source_session_id.len == 0;
    defer if (owns_synthetic_parent) allocator.free(parent_session_id);

    const parent_checkpoint_id = blk: {
        const maybe_checkpoint = store.readLatestContextCheckpoint(allocator, service.config.workspace_root, parent_session_id) catch null;
        if (maybe_checkpoint) |checkpoint| {
            defer checkpoint.deinit(allocator);
            break :blk try allocator.dupe(u8, checkpoint.id);
        }
        break :blk try allocator.dupe(u8, "parent-root");
    };
    defer allocator.free(parent_checkpoint_id);
    const branch_seq = try nextBranchSeq(allocator, service.config.workspace_root, parent_session_id);
    const capability_hash = try agent_spec.capabilityHash(spec, route.capability_profile_id);
    const output_schema_hash = agent_spec.contentHash("{}");
    const created_at_ms = std.time.milliTimestamp();
    const execution_receipt = types.ExecutionReceiptView{
        .execution_kind = route.execution_kind.label(),
        .agent_spec_id = spec.id,
        .route_role = route.role.label(),
        .provider_id = route.providerId(),
        .model = route.config.openai_model,
        .wire_api = route.config.wire_api.label(),
        .thinking_mode = route.config.thinking_mode,
        .capability_profile_id = route.capability_profile_id,
        .capability_hash = capability_hash[0..],
        .parent_session_id = parent_session_id,
        .parent_checkpoint_id = parent_checkpoint_id,
        .group_id = group_id,
        .task_id = task_id,
        .branch_seq = branch_seq,
        .budget = .{
            .max_steps = spec.max_steps,
            .max_tool_calls = spec.max_tool_calls,
            .max_children = spec.max_children,
        },
        .output_schema_hash = output_schema_hash[0..],
        .created_at_ms = created_at_ms,
    };

    const ticket_store = tickets.TicketStore.init(allocator, service.config.workspace_root);
    var claim = try ticket_store.claim(.{
        .ticket_id = request.ticket_id,
        .expected_revision = request.expected_revision,
        .worker_id = request.worker_id,
        .worker_generation = request.worker_generation,
        .lease_token = request.lease_token,
        .lease_expires_at_ms = request.lease_expires_at_ms,
        .attempt = request.attempt,
        .session_id = child_session_id,
        .agent_hint = spec.id,
        .capability_hash = capability_hash[0..],
        .idempotency_key = request.idempotency_key,
        .claimed_at_ms = created_at_ms,
    });
    defer claim.deinit(allocator);
    if (!claim.appended or !std.mem.eql(u8, claim.session_id, child_session_id)) return Error.TicketClaimReplay;

    if (owns_synthetic_parent) {
        const coordinator_prompt = try std.fmt.allocPrint(allocator, "Ticket coordinator for {s}: {s}", .{ request.ticket_id, request.title });
        defer allocator.free(coordinator_prompt);
        var coordinator = store.readSessionRecord(allocator, service.config.workspace_root, parent_session_id) catch |err| switch (err) {
            error.FileNotFound => try store.initSessionWithOptions(allocator, service.config.workspace_root, coordinator_prompt, .{
                .session_id = parent_session_id,
                .status = .initialized,
                .display_name = display_name,
                .agent_profile = "root",
            }),
            else => return err,
        };
        coordinator.deinit(allocator);
    }

    var child_session = try store.initSessionWithExecutionReceipt(allocator, service.config.workspace_root, child_prompt, .{
        .session_id = child_session_id,
        .status = .initialized,
        .parent_session_id = parent_session_id,
        .display_name = display_name,
        .agent_profile = route.capability_profile_id,
    }, &execution_receipt);
    defer child_session.deinit(allocator);
    errdefer |err| markSessionAdmissionFailed(service.config.workspace_root, child_session.id, @errorName(err));

    const claim_message = try std.fmt.allocPrint(allocator, "Ticket {s} claimed by {s}; group={s} task={s}", .{ request.ticket_id, spec.id, group_id, task_id });
    defer allocator.free(claim_message);
    const ticket_reference = try std.fmt.allocPrint(allocator, "ticket:{s}", .{request.ticket_id});
    defer allocator.free(ticket_reference);
    const group_reference = try std.fmt.allocPrint(allocator, "group:{s}", .{group_id});
    defer allocator.free(group_reference);
    const notice_references = [_][]const u8{ ticket_reference, group_reference };
    var claim_notice = try mailbox.send(allocator, service.config.workspace_root, .{
        .sender_session_id = child_session.id,
        .tool_call_id = request.idempotency_key,
        .target = .parent,
        .delivery = .wake,
        .body = claim_message,
        .references = notice_references[0..],
        .delivery_sink = .{
            .context = service,
            .notifyFn = notifySessionEventFromHandle,
        },
    });
    claim_notice.deinit(allocator);
    try docs_sync.writePending(allocator, service.config.workspace_root, .{
        .session_id = child_session.id,
        .status = types.statusLabel(child_session.status),
        .prompt = child_session.prompt,
        .output = "",
        .updated_at_ms = child_session.updated_at_ms,
    });

    const prepared_task = try service.supervisor.createTask(.{
        .parent_session_id = parent_session_id,
        .parent_checkpoint_id = parent_checkpoint_id,
        .session_id = child_session.id,
        .task_id = task_id,
        .name = display_name,
        .agent_spec_id = spec.id,
        .route_role = route.role.label(),
        .capability_profile_id = route.capability_profile_id,
        .branch_seq = branch_seq,
        .remaining_depth = if (spec.max_children > 0) 1 else 0,
        .output_schema_json = "{}",
        .route = route,
        .transport = service.transport,
        .agent_service = service.handle(),
    });
    route_owned = false;
    var submitted = false;
    defer if (!submitted) service.supervisor.destroyPreparedTask(prepared_task);

    try service.supervisor.submitTicketGroup(.{
        .id = group_id,
        .parent_session_id = parent_session_id,
        .workspace_root = service.config.workspace_root,
        .shared_context = shared_context,
    }, prepared_task);
    submitted = true;

    return .{
        .ticket_id = try allocator.dupe(u8, request.ticket_id),
        .group_id = try allocator.dupe(u8, group_id),
        .task_id = try allocator.dupe(u8, task_id),
        .session_id = try allocator.dupe(u8, child_session.id),
        .agent_id = try allocator.dupe(u8, spec.id),
        .route_role = try allocator.dupe(u8, route.role.label()),
        .capability_profile_id = try allocator.dupe(u8, route.capability_profile_id),
        .capability_hash = try allocator.dupe(u8, capability_hash[0..]),
        .model = try allocator.dupe(u8, route.config.openai_model),
    };
}

fn launch(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    prompt: []const u8,
    requested_name: ?[]const u8,
    delegation_scope: scope_contract.DelegationScope,
) ![]u8 {
    const task = [_]tools.AgentTaskRequest{.{
        .name = requested_name,
        .agent_id = "general",
        .task = prompt,
    }};
    return launchBatch(service, allocator, parent_session_id, "", task[0..], delegation_scope);
}

/// Compile, persist, and admit one canonical batch before any child executes.
fn launchBatch(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    shared_context: []const u8,
    tasks_to_launch: []const tools.AgentTaskRequest,
    delegation_scope: scope_contract.DelegationScope,
) ![]u8 {
    if (tasks_to_launch.len == 0 or tasks_to_launch.len > 100) return Error.InvalidBatch;
    if (shared_context.len > 128 * 1024) return Error.InvalidBatch;
    if (delegation_scope.contact_budget < tasks_to_launch.len) return Error.InvalidBatch;
    try docs_sync.ensureRunStart(allocator, service.config.workspace_root);
    var registry = try agent_spec.loadRegistry(allocator, service.config.workspace_root);
    defer registry.deinit();

    const parent_profile_id = delegation_scope.parent_capability_profile orelse "root";
    const parent_profile = try profile_contract.resolveProfile(parent_profile_id);
    try scope_contract.validateDelegationScope(delegation_scope, parent_profile);
    var parent_session = try store.readSessionRecord(allocator, service.config.workspace_root, parent_session_id);
    defer parent_session.deinit(allocator);
    if (parent_session.execution_receipt) |receipt| {
        if (tasks_to_launch.len > receipt.budget.max_children) return Error.InvalidBatch;
    }

    for (tasks_to_launch, 0..) |task, task_index| {
        if (!hasText(task.task) or task.task.len > 256 * 1024) return Error.InvalidBatch;
        _ = try registry.resolve(task.agent_id);
        var output_schema = std.json.parseFromSlice(std.json.Value, allocator, task.output_schema_json, .{}) catch return Error.InvalidBatch;
        defer output_schema.deinit();
        if (output_schema.value != .object) return Error.InvalidBatch;
        if (task.name) |name| {
            if (!hasText(name) or name.len > 96) return Error.InvalidBatch;
            for (tasks_to_launch[0..task_index]) |prior| {
                if (prior.name) |prior_name| {
                    if (std.mem.eql(u8, name, prior_name)) return Error.AgentNameTaken;
                }
            }
        }
    }

    // Resolve each distinct AgentSpec before the first session/effect. Batch
    // fan-out clones this invocation-local receipt source instead of reparsing
    // config/auth once per child.
    var route_templates: std.StringHashMapUnmanaged(*routes.ResolvedRoute) = .{};
    defer {
        var iterator = route_templates.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(entry.value_ptr.*);
        }
        route_templates.deinit(allocator);
    }
    for (tasks_to_launch) |task| {
        const spec = try registry.resolve(task.agent_id);
        if (route_templates.contains(spec.id)) continue;
        const template = try std.heap.page_allocator.create(routes.ResolvedRoute);
        template.* = routes.resolve(std.heap.page_allocator, service.config.*, spec.route_role, .{
            .max_steps = spec.max_steps,
            .max_tool_calls = spec.max_tool_calls,
            .execution_kind = spec.execution_kind,
            .capability_profile_id = spec.capability_profile_id,
        }) catch |err| {
            std.heap.page_allocator.destroy(template);
            return err;
        };
        route_templates.put(allocator, spec.id, template) catch |err| {
            template.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(template);
            return err;
        };
    }

    const max_concurrency = try ensureSupervisorStarted(service, allocator);
    const group_id = try newGroupId(allocator);
    defer allocator.free(group_id);
    const parent_checkpoint_id = blk: {
        const maybe_checkpoint = store.readLatestContextCheckpoint(allocator, service.config.workspace_root, parent_session_id) catch null;
        if (maybe_checkpoint) |checkpoint| {
            defer checkpoint.deinit(allocator);
            break :blk try allocator.dupe(u8, checkpoint.id);
        }
        break :blk try allocator.dupe(u8, "parent-root");
    };
    defer allocator.free(parent_checkpoint_id);
    const first_branch_seq = try nextBranchSeq(allocator, service.config.workspace_root, parent_session_id);

    var prepared = std.array_list.Managed(*child_supervisor.Task).init(allocator);
    defer prepared.deinit();
    var submitted = false;
    defer if (!submitted) {
        for (prepared.items) |task| {
            markAdmissionFailed(task, "BatchAdmissionFailed");
            service.supervisor.destroyPreparedTask(task);
        }
    };

    for (tasks_to_launch, 0..) |task_request, index| {
        const spec = try registry.resolve(task_request.agent_id);
        const route = try std.heap.page_allocator.create(routes.ResolvedRoute);
        route.* = route_templates.get(spec.id).?.clone(std.heap.page_allocator) catch |err| {
            std.heap.page_allocator.destroy(route);
            return err;
        };
        var route_owned = true;
        defer if (route_owned) {
            route.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(route);
        };

        const name = if (task_request.name) |value|
            try allocator.dupe(u8, value)
        else
            try std.fmt.allocPrint(allocator, "{s}-{d}", .{ spec.id, index + 1 });
        defer allocator.free(name);
        const task_id = try std.fmt.allocPrint(allocator, "task-{d}", .{index + 1});
        defer allocator.free(task_id);
        const child_prompt = try renderChildPrompt(allocator, shared_context, task_request.task, spec, task_request.output_schema_json);
        defer allocator.free(child_prompt);
        const capability_hash = try agent_spec.capabilityHash(spec, route.capability_profile_id);
        const output_schema_hash = agent_spec.contentHash(task_request.output_schema_json);
        const branch_seq = first_branch_seq + @as(u64, @intCast(index));
        const created_at_ms = std.time.milliTimestamp();

        const execution_receipt = types.ExecutionReceiptView{
            .execution_kind = route.execution_kind.label(),
            .agent_spec_id = spec.id,
            .route_role = route.role.label(),
            .provider_id = route.providerId(),
            .model = route.config.openai_model,
            .wire_api = route.config.wire_api.label(),
            .thinking_mode = route.config.thinking_mode,
            .capability_profile_id = route.capability_profile_id,
            .capability_hash = capability_hash[0..],
            .parent_session_id = parent_session_id,
            .parent_checkpoint_id = parent_checkpoint_id,
            .group_id = group_id,
            .task_id = task_id,
            .branch_seq = branch_seq,
            .budget = .{
                .max_steps = spec.max_steps,
                .max_tool_calls = spec.max_tool_calls,
                .max_children = spec.max_children,
            },
            .output_schema_hash = output_schema_hash[0..],
            .created_at_ms = created_at_ms,
        };
        var child_session = try store.initSessionWithExecutionReceipt(allocator, service.config.workspace_root, child_prompt, .{
            .status = .initialized,
            .parent_session_id = parent_session_id,
            .display_name = name,
            .agent_profile = route.capability_profile_id,
        }, &execution_receipt);
        defer child_session.deinit(allocator);

        const branch_summary = try std.fmt.allocPrint(allocator, "Group {s} branch {d} ({s}): {s}", .{ group_id, branch_seq, name, task_request.task });
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
        const delegation_event = try scope_contract.renderDelegationEvent(allocator, delegation_scope, try profile_contract.resolveProfile(route.capability_profile_id));
        defer allocator.free(delegation_event);
        try store.appendEvent(allocator, service.config.workspace_root, child_session.id, .{
            .event_type = "session_delegated",
            .message = delegation_event,
            .timestamp_ms = created_at_ms,
        });
        try docs_sync.writePending(allocator, service.config.workspace_root, .{
            .session_id = child_session.id,
            .status = types.statusLabel(child_session.status),
            .prompt = child_session.prompt,
            .output = "",
            .updated_at_ms = child_session.updated_at_ms,
        });

        const prepared_task = try service.supervisor.createTask(.{
            .parent_session_id = parent_session_id,
            .parent_checkpoint_id = parent_checkpoint_id,
            .session_id = child_session.id,
            .task_id = task_id,
            .name = name,
            .agent_spec_id = spec.id,
            .route_role = route.role.label(),
            .capability_profile_id = route.capability_profile_id,
            .branch_seq = branch_seq,
            .remaining_depth = delegation_scope.scope_depth - 1,
            .output_schema_json = task_request.output_schema_json,
            .route = route,
            .transport = service.transport,
            .agent_service = service.handle(),
        });
        route_owned = false;
        prepared.append(prepared_task) catch |err| {
            service.supervisor.destroyPreparedTask(prepared_task);
            return err;
        };
    }

    try service.supervisor.submitGroup(.{
        .id = group_id,
        .parent_session_id = parent_session_id,
        .workspace_root = service.config.workspace_root,
        .shared_context = shared_context,
    }, prepared.items);
    submitted = true;
    const result = try service.supervisor.renderGroup(allocator, group_id);
    const log_line = try std.fmt.allocPrint(allocator, "child group admitted: {s} tasks={d} concurrency={d}", .{ group_id, tasks_to_launch.len, max_concurrency });
    defer allocator.free(log_line);
    docs_sync.appendLog(allocator, service.config.workspace_root, log_line) catch {};
    return result;
}

fn status(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    group_id_or_name: []const u8,
) ![]u8 {
    _ = try recoverReceiptGroups(service, allocator, parent_session_id);
    return service.supervisor.renderGroup(allocator, group_id_or_name) catch |err| switch (err) {
        child_supervisor.Error.UnknownGroup => statusLegacy(service, allocator, parent_session_id, group_id_or_name),
        else => err,
    };
}

fn statusLegacy(
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
    group_id_or_name: []const u8,
    timeout_ms: usize,
) ![]u8 {
    _ = try recoverReceiptGroups(service, allocator, parent_session_id);
    _ = service.supervisor.waitGroup(group_id_or_name, timeout_ms) catch |err| switch (err) {
        child_supervisor.Error.UnknownGroup => return waitLegacy(service, allocator, parent_session_id, group_id_or_name, timeout_ms),
        else => return err,
    };
    return service.supervisor.renderGroup(allocator, group_id_or_name);
}

fn waitLegacy(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    agent_name: []const u8,
    timeout_ms: usize,
) ![]u8 {
    var session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
    defer session.deinit(allocator);
    if (!isTerminal(session.status) and timeout_ms > 0) {
        const bounded_ms = @min(timeout_ms, std.math.maxInt(u64) / std.time.ns_per_ms);
        std.Thread.sleep(@as(u64, @intCast(bounded_ms)) * std.time.ns_per_ms);
        session.deinit(allocator);
        session = try findChildSessionByName(allocator, service.config.workspace_root, parent_session_id, agent_name);
    }
    return renderChildSession(allocator, service.config.workspace_root, session, .{
        .wait_state = if (isTerminal(session.status)) "terminal" else "timeout",
        .wait_timeout_ms = timeout_ms,
    });
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

/// Rebuild the live parent/group index from secret-free child receipts exactly
/// once per Service lifetime. A process restart cannot resume in-process
/// workers, so initialized/running receipts become typed StaleAgentOwner
/// failures; already-terminal receipts remain eligible for idempotent group
/// convergence.
fn recoverReceiptGroups(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) !usize {
    service.recovery_mutex.lock();
    defer service.recovery_mutex.unlock();
    if (service.supervisor.hasParent(parent_session_id)) return 0;
    if (service.recovered_parents.contains(parent_session_id)) return 0;

    const sessions = try store.listSessionRecords(allocator, service.config.workspace_root);
    defer types.deinitSessionRecords(allocator, sessions);
    service.supervisor.recordColdStartDirectoryScan();
    const parent_messages = try store.readSessionMessages(allocator, service.config.workspace_root, parent_session_id);
    defer types.deinitSessionMessages(allocator, parent_messages);

    var seen_groups: std.StringHashMapUnmanaged(void) = .{};
    defer seen_groups.deinit(allocator);
    var stale_count: usize = 0;

    for (sessions) |candidate| {
        const receipt = candidate.execution_receipt orelse continue;
        if (!std.mem.eql(u8, receipt.parent_session_id, parent_session_id)) continue;
        if (seen_groups.contains(receipt.group_id)) continue;
        try seen_groups.put(allocator, receipt.group_id, {});
        if (service.supervisor.hasGroup(receipt.group_id)) continue;

        var prepared = std.array_list.Managed(*child_supervisor.Task).init(allocator);
        defer prepared.deinit();
        var submitted = false;
        defer if (!submitted) {
            for (prepared.items) |task| service.supervisor.destroyPreparedTask(task);
        };
        var group_stale_count: usize = 0;
        const legacy_group_converged = groupHasConvergenceMessage(allocator, parent_messages, receipt.group_id);

        for (sessions) |*member| {
            const member_receipt = member.execution_receipt orelse continue;
            if (!std.mem.eql(u8, member_receipt.parent_session_id, parent_session_id) or
                !std.mem.eql(u8, member_receipt.group_id, receipt.group_id)) continue;

            var lifecycle: child_supervisor.TaskLifecycle = switch (member.status) {
                .completed => .completed,
                .failed => .failed,
                .cancelled => .cancelled,
                .initialized, .running => .failed,
            };
            var failure_class: ?[]const u8 = member.failure_reason;
            if (member.status == .initialized or member.status == .running) {
                const stale_reason = "StaleAgentOwner";
                var terminal = try store.commitTurnTerminal(
                    allocator,
                    service.config.workspace_root,
                    member,
                    null,
                    .{ .outcome = .failed, .detail = stale_reason },
                    std.time.milliTimestamp(),
                );
                terminal.deinit(allocator);
                try appendRecoveredTaskFinishedEvent(service, allocator, parent_session_id, member.*, stale_reason);
                docs_sync.completeSession(allocator, service.config.workspace_root, .{
                    .session_id = member.id,
                    .status = types.statusLabel(member.status),
                    .prompt = member.prompt,
                    .output = stale_reason,
                    .updated_at_ms = member.updated_at_ms,
                }) catch {};
                lifecycle = .failed;
                failure_class = stale_reason;
                stale_count += 1;
                group_stale_count += 1;
            }

            const convergence_call_id = try child_supervisor.convergenceToolCallId(
                allocator,
                member_receipt.group_id,
                member_receipt.task_id,
            );
            defer allocator.free(convergence_call_id);
            const mailbox_converged = try mailbox.hasSentReceipt(
                allocator,
                service.config.workspace_root,
                member.id,
                convergence_call_id,
            );

            const task = try service.supervisor.createRecoveredTask(.{
                .parent_session_id = parent_session_id,
                .parent_checkpoint_id = member_receipt.parent_checkpoint_id,
                .session_id = member.id,
                .task_id = member_receipt.task_id,
                .name = member.display_name orelse member.id,
                .agent_spec_id = member_receipt.agent_spec_id,
                .route_role = member_receipt.route_role,
                .capability_profile_id = member_receipt.capability_profile_id,
                .branch_seq = member_receipt.branch_seq,
                .lifecycle = lifecycle,
                .converged = mailbox_converged or legacy_group_converged or taskHasConvergenceMessage(
                    allocator,
                    parent_messages,
                    member_receipt.group_id,
                    member_receipt.task_id,
                ),
                .failure_class = failure_class,
            });
            prepared.append(task) catch |err| {
                service.supervisor.destroyPreparedTask(task);
                return err;
            };
        }

        if (prepared.items.len == 0) continue;
        try service.supervisor.submitRecoveredGroup(.{
            .id = receipt.group_id,
            .parent_session_id = parent_session_id,
            .workspace_root = service.config.workspace_root,
            .shared_context = "",
        }, prepared.items);
        submitted = true;
        try appendGroupRecoveredEvent(service, allocator, parent_session_id, receipt.group_id, prepared.items.len, group_stale_count);
    }

    const owned_parent_id = try std.heap.page_allocator.dupe(u8, parent_session_id);
    errdefer std.heap.page_allocator.free(owned_parent_id);
    try service.recovered_parents.put(std.heap.page_allocator, owned_parent_id, {});
    return stale_count;
}

fn groupHasConvergenceMessage(
    allocator: std.mem.Allocator,
    messages: []const types.SessionMessage,
    group_id: []const u8,
) bool {
    const expected = std.fmt.allocPrint(allocator, "group-convergence-{s}", .{group_id}) catch return false;
    defer allocator.free(expected);
    for (messages) |message| if (std.mem.eql(u8, message.id, expected)) return true;
    return false;
}

fn taskHasConvergenceMessage(
    allocator: std.mem.Allocator,
    messages: []const types.SessionMessage,
    group_id: []const u8,
    task_id: []const u8,
) bool {
    const expected = std.fmt.allocPrint(allocator, "child-convergence-{s}-{s}", .{ group_id, task_id }) catch return false;
    defer allocator.free(expected);
    for (messages) |message| if (std.mem.eql(u8, message.id, expected)) return true;
    return false;
}

fn appendRecoveredTaskFinishedEvent(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    session: types.SessionRecord,
    failure_class: []const u8,
) !void {
    const receipt = session.execution_receipt orelse return;
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.child_event.v1\",\"group_id\":{f},\"child_session_id\":{f},\"task_id\":{f},\"child_seq\":0,\"name\":{f},\"agent_spec_id\":{f},\"route_role\":{f},\"status\":\"failed\",\"phase\":\"cold_start_reconciliation\",\"detail\":{f}}}",
        .{
            std.json.fmt(receipt.group_id, .{}),
            std.json.fmt(session.id, .{}),
            std.json.fmt(receipt.task_id, .{}),
            std.json.fmt(session.display_name orelse session.id, .{}),
            std.json.fmt(receipt.agent_spec_id, .{}),
            std.json.fmt(receipt.route_role, .{}),
            std.json.fmt(failure_class, .{}),
        },
    );
    defer allocator.free(message);
    try store.appendEvent(allocator, service.config.workspace_root, parent_session_id, .{
        .event_type = "child_finished",
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

fn appendGroupRecoveredEvent(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    group_id: []const u8,
    task_count: usize,
    stale_count: usize,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.child_group_recovery.v1\",\"group_id\":{f},\"parent_session_id\":{f},\"tasks\":{d},\"stale_owners_reconciled\":{d},\"terminal\":true}}",
        .{ std.json.fmt(group_id, .{}), std.json.fmt(parent_session_id, .{}), task_count, stale_count },
    );
    defer allocator.free(message);
    try store.appendEvent(allocator, service.config.workspace_root, parent_session_id, .{
        .event_type = "child_group_recovered",
        .message = message,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

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
    const sessions = try store.listSessionRecords(allocator, service.config.workspace_root);
    defer types.deinitSessionRecords(allocator, sessions);
    const checkpoints = try store.readAllContextCheckpoints(
        allocator,
        service.config.workspace_root,
        parent_session_id,
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
        if (hasReceiptBranch(sessions, parent_session_id, cp.parent_checkpoint_id.?, cp.branch_seq)) continue;

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

fn hasReceiptBranch(
    sessions: []const types.SessionRecord,
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    branch_seq: u64,
) bool {
    for (sessions) |session| {
        const receipt = session.execution_receipt orelse continue;
        if (receipt.branch_seq == branch_seq and
            std.mem.eql(u8, receipt.parent_session_id, parent_session_id) and
            std.mem.eql(u8, receipt.parent_checkpoint_id, parent_checkpoint_id)) return true;
    }
    return false;
}

fn list(
    service: *Service,
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
) ![]u8 {
    _ = try recoverReceiptGroups(service, allocator, parent_session_id);
    if (service.supervisor.hasParent(parent_session_id)) {
        return service.supervisor.renderParent(allocator, parent_session_id);
    }
    return listLegacy(service, allocator, parent_session_id);
}

fn listLegacy(
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

/// Compile shared batch context and one finite specialist task into the child purpose.
fn renderChildPrompt(
    allocator: std.mem.Allocator,
    shared_context: []const u8,
    task: []const u8,
    spec: agent_spec.AgentSpec,
    output_schema_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Agent: {s}\nMethod: {s}\nShared context:\n{s}\n\nTask:\n{s}\n\nOutput contract: {s}\nOutput schema: {s}",
        .{ spec.id, spec.instruction_capsule, shared_context, task, spec.output_contract, output_schema_json },
    );
}

/// Mark every partially persisted child truthfully when atomic batch admission fails.
fn markAdmissionFailed(task: *child_supervisor.Task, reason: []const u8) void {
    const route = task.route orelse return;
    markSessionAdmissionFailed(route.config.workspace_root, task.session_id, reason);
}

/// A ticket claim can lose a revision/idempotency race after the child session
/// has been persisted because the session id is part of the durable claim.
/// Keep that loser session truthful and terminal; never leave an initialized
/// orphan for cold-start recovery to mistake for live work.
fn markSessionAdmissionFailed(workspace_root: []const u8, session_id: []const u8, reason: []const u8) void {
    var session = store.readSessionRecord(std.heap.page_allocator, workspace_root, session_id) catch return;
    defer session.deinit(std.heap.page_allocator);
    var terminal = store.commitTurnTerminal(
        std.heap.page_allocator,
        workspace_root,
        &session,
        null,
        .{ .outcome = .failed, .detail = reason },
        std.time.milliTimestamp(),
    ) catch return;
    terminal.deinit(std.heap.page_allocator);
}

fn hasText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn ticketSessionId(allocator: std.mem.Allocator, role: []const u8, identity: []const u8) ![]u8 {
    const digest = agent_spec.contentHash(identity);
    return std.fmt.allocPrint(allocator, "session-ticket-{s}-{s}", .{ role, digest[0..24] });
}

fn newGroupId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "group-{d}-{x}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u64),
    });
}

fn newAgentName(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "agent-{d}-{x}", .{
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    });
}

fn isTerminal(status_value: types.SessionStatus) bool {
    return status_value == .completed or status_value == .failed or status_value == .cancelled;
}

test "ticket launch rejects incomplete admission before capacity or session work" {
    var service = Service{ .config = undefined, .transport = undefined };
    var request = tools.TicketTaskRequest{
        .ticket_id = "ticket-test",
        .title = "Ticket",
        .description = "Description",
        .category = "bug",
        .expected_revision = 1,
        .worker_id = "scheduler-test",
        .worker_generation = 1,
        .lease_token = "lease-test",
        .lease_expires_at_ms = 100,
        .attempt = 1,
        .agent_hint = "recon",
        .idempotency_key = "claim-test",
    };

    request.ticket_id = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request = .{
        .ticket_id = "ticket-test",
        .title = "",
        .description = "Description",
        .category = "bug",
        .expected_revision = 1,
        .worker_id = "scheduler-test",
        .worker_generation = 1,
        .lease_token = "lease-test",
        .lease_expires_at_ms = 100,
        .attempt = 1,
        .agent_hint = "recon",
        .idempotency_key = "claim-test",
    };
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));

    request.description = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request.description = "Description";
    request.category = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request.category = "bug";
    request.worker_id = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request.worker_id = "scheduler-test";
    request.lease_token = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request.lease_token = "lease-test";
    request.agent_hint = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
    request.agent_hint = "recon";
    request.idempotency_key = "";
    try std.testing.expectError(Error.InvalidBatch, launchTicket(&service, std.testing.allocator, request));
}

test "ticket child identity is stable per claim" {
    const allocator = std.testing.allocator;
    const first = try ticketSessionId(allocator, "child", "ticket-claim:abc:2:1");
    defer allocator.free(first);
    const replay = try ticketSessionId(allocator, "child", "ticket-claim:abc:2:1");
    defer allocator.free(replay);
    const next_attempt = try ticketSessionId(allocator, "child", "ticket-claim:abc:4:2");
    defer allocator.free(next_attempt);

    try std.testing.expectEqualStrings(first, replay);
    try std.testing.expect(!std.mem.eql(u8, first, next_attempt));
    try std.testing.expect(std.mem.startsWith(u8, first, "session-ticket-child-"));
}
