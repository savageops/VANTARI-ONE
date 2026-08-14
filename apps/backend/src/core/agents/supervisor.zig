const std = @import("std");
const config_file = @import("../config/file.zig");
const executor = @import("../executor/loop.zig");
const turn_payload = @import("../executor/turn_payload.zig");
const mailbox = @import("mailbox.zig");
const profile_contract = @import("profile.zig");
const provider = @import("../providers/openai_compatible.zig");
const provider_dispatch = @import("../providers/dispatch.zig");
const routes = @import("../providers/routes.zig");
const store = @import("../sessions/store.zig");
const summaries = @import("../sessions/summaries.zig");
const tools = @import("../tools/runtime.zig");
const protocol_events = @import("../../shared/protocol/events.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    DuplicateGroup,
    EmptyGroup,
    InvalidConcurrency,
    InvalidModelTaskOutput,
    ModelTaskToolCall,
    PoolFull,
    UnknownGroup,
};

pub const TaskLifecycle = enum {
    queued,
    running,
    completed,
    failed,
    cancelled,
};

const ConvergenceState = enum {
    open,
    reserved,
    committed,
};

const ActiveCounts = struct {
    queued: usize = 0,
    running: usize = 0,
};

pub const TaskInput = struct {
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    session_id: []const u8,
    task_id: []const u8,
    name: []const u8,
    agent_spec_id: []const u8,
    route_role: []const u8,
    capability_profile_id: []const u8,
    branch_seq: u64,
    remaining_depth: usize,
    output_schema_json: []const u8,
    route: *routes.ResolvedRoute,
    transport: provider.Transport,
    agent_service: tools.AgentService,
};

pub const RecoveredTaskInput = struct {
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    session_id: []const u8,
    task_id: []const u8,
    name: []const u8,
    agent_spec_id: []const u8,
    route_role: []const u8,
    capability_profile_id: []const u8,
    branch_seq: u64,
    lifecycle: TaskLifecycle,
    converged: bool = false,
    failure_class: ?[]const u8 = null,
};

pub const GroupInput = struct {
    id: []const u8,
    parent_session_id: []const u8,
    workspace_root: []const u8,
    shared_context: []const u8,
};

pub const Task = struct {
    group: ?*Group = null,
    parent_session_id: []u8,
    parent_checkpoint_id: []u8,
    session_id: []u8,
    task_id: []u8,
    name: []u8,
    agent_spec_id: []u8,
    route_role: []u8,
    capability_profile_id: []u8,
    output_schema_json: []u8,
    branch_seq: u64,
    remaining_depth: usize,
    route: ?*routes.ResolvedRoute,
    transport: provider.Transport,
    agent_service: tools.AgentService,
    lifecycle: TaskLifecycle = .queued,
    convergence: ConvergenceState = .open,
    cancel_requested: bool = false,
    terminal_evidence_committed: bool = false,
    failure_class: ?[]u8 = null,
    next_event_seq: u64 = 1,
    started_at_ms: i64 = 0,
    finished_at_ms: i64 = 0,

    fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        if (self.route) |route| {
            route.deinit(allocator);
            allocator.destroy(route);
        }
        allocator.free(self.parent_session_id);
        allocator.free(self.parent_checkpoint_id);
        allocator.free(self.session_id);
        allocator.free(self.task_id);
        allocator.free(self.name);
        allocator.free(self.agent_spec_id);
        allocator.free(self.route_role);
        allocator.free(self.capability_profile_id);
        allocator.free(self.output_schema_json);
        if (self.failure_class) |value| allocator.free(value);
        allocator.destroy(self);
    }
};

const Group = struct {
    supervisor: *Supervisor,
    id: []u8,
    parent_session_id: []u8,
    workspace_root: []u8,
    shared_context: []u8,
    tasks: []*Task,
    convergence: ConvergenceState = .open,
    terminal_emitted: bool = false,
    terminal_evidence_committed: bool = false,
    next_event_seq: u64 = 1,
    created_at_ms: i64,

    fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        for (self.tasks) |task| task.deinit(allocator);
        allocator.free(self.tasks);
        allocator.free(self.id);
        allocator.free(self.parent_session_id);
        allocator.free(self.workspace_root);
        allocator.free(self.shared_context);
        allocator.destroy(self);
    }
};

const ParentState = struct {
    id: []u8,
    groups: std.ArrayListUnmanaged(*Group) = .{},

    fn deinit(self: *ParentState, allocator: std.mem.Allocator) void {
        self.groups.deinit(allocator);
        allocator.free(self.id);
        allocator.destroy(self);
    }
};

pub const Supervisor = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    pool: std.Thread.Pool = undefined,
    started: bool = false,
    max_concurrency: usize = 0,
    pool_entries: usize = 0,
    groups: std.StringHashMapUnmanaged(*Group) = .{},
    parents: std.StringHashMapUnmanaged(*ParentState) = .{},
    event_sink: tools.AgentEventSink = .{},
    cold_start_directory_scans: usize = 0,

    const allocator = std.heap.page_allocator;

    /// Fixed-pool activation / Start the one physical pool after Service has a
    /// stable address and refresh its configured size only when no submitted
    /// closure can still touch Supervisor state. Why: config remains effective
    /// without a second pool or unsafe live replacement. Preserves: a busy pool
    /// reports its actual ceiling until it drains. Evidence: Move 28
    /// idle-boundary refresh and contention tests.
    pub fn start(self: *Supervisor, max_concurrency: usize) !usize {
        if (max_concurrency == 0 or max_concurrency > 64) return Error.InvalidConcurrency;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started and self.max_concurrency == max_concurrency) return self.max_concurrency;
        if (self.started) {
            const active = self.activeCountsLocked();
            if (self.pool_entries != 0 or active.queued != 0 or active.running != 0) return self.max_concurrency;
            self.pool.deinit();
            self.started = false;
            self.max_concurrency = 0;
        }
        try self.pool.init(.{ .allocator = allocator, .n_jobs = max_concurrency });
        self.max_concurrency = max_concurrency;
        self.started = true;
        return self.max_concurrency;
    }

    pub fn deinit(self: *Supervisor) void {
        self.mutex.lock();
        if (self.started) {
            var iterator = self.groups.iterator();
            while (iterator.next()) |entry| {
                for (entry.value_ptr.*.tasks) |task| task.cancel_requested = true;
            }
        }
        self.mutex.unlock();
        self.condition.broadcast();

        if (self.started) self.pool.deinit();

        var parent_iterator = self.parents.iterator();
        while (parent_iterator.next()) |entry| entry.value_ptr.*.deinit(allocator);
        self.parents.deinit(allocator);
        var group_iterator = self.groups.iterator();
        while (group_iterator.next()) |entry| entry.value_ptr.*.deinit(allocator);
        self.groups.deinit(allocator);
        self.* = undefined;
    }

    pub fn bindEventSink(self: *Supervisor, sink: tools.AgentEventSink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.event_sink = sink;
    }

    pub fn notifySessionEvent(
        self: *Supervisor,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) !void {
        self.mutex.lock();
        const sink = self.event_sink;
        self.mutex.unlock();
        try sink.notify(session_id, seq, event_type, message, timestamp_ms);
    }

    /// Allocate one admitted task. Ownership transfers to submitGroup on success.
    pub fn createTask(self: *Supervisor, input: TaskInput) !*Task {
        _ = self;
        const parent_session_id = try allocator.dupe(u8, input.parent_session_id);
        errdefer allocator.free(parent_session_id);
        const parent_checkpoint_id = try allocator.dupe(u8, input.parent_checkpoint_id);
        errdefer allocator.free(parent_checkpoint_id);
        const session_id = try allocator.dupe(u8, input.session_id);
        errdefer allocator.free(session_id);
        const task_id = try allocator.dupe(u8, input.task_id);
        errdefer allocator.free(task_id);
        const name = try allocator.dupe(u8, input.name);
        errdefer allocator.free(name);
        const agent_spec_id = try allocator.dupe(u8, input.agent_spec_id);
        errdefer allocator.free(agent_spec_id);
        const route_role = try allocator.dupe(u8, input.route_role);
        errdefer allocator.free(route_role);
        const capability_profile_id = try allocator.dupe(u8, input.capability_profile_id);
        errdefer allocator.free(capability_profile_id);
        const output_schema_json = try allocator.dupe(u8, input.output_schema_json);
        errdefer allocator.free(output_schema_json);
        const task = try allocator.create(Task);
        task.* = .{
            .parent_session_id = parent_session_id,
            .parent_checkpoint_id = parent_checkpoint_id,
            .session_id = session_id,
            .task_id = task_id,
            .name = name,
            .agent_spec_id = agent_spec_id,
            .route_role = route_role,
            .capability_profile_id = capability_profile_id,
            .output_schema_json = output_schema_json,
            .branch_seq = input.branch_seq,
            .remaining_depth = input.remaining_depth,
            .route = input.route,
            .transport = input.transport,
            .agent_service = input.agent_service,
        };
        return task;
    }

    pub fn destroyPreparedTask(self: *Supervisor, task: *Task) void {
        _ = self;
        task.deinit(allocator);
    }

    /// Rebuild one terminal task from its durable execution receipt. Recovered
    /// tasks never retain provider credentials or an executable route.
    pub fn createRecoveredTask(self: *Supervisor, input: RecoveredTaskInput) !*Task {
        _ = self;
        const parent_session_id = try allocator.dupe(u8, input.parent_session_id);
        errdefer allocator.free(parent_session_id);
        const parent_checkpoint_id = try allocator.dupe(u8, input.parent_checkpoint_id);
        errdefer allocator.free(parent_checkpoint_id);
        const session_id = try allocator.dupe(u8, input.session_id);
        errdefer allocator.free(session_id);
        const task_id = try allocator.dupe(u8, input.task_id);
        errdefer allocator.free(task_id);
        const name = try allocator.dupe(u8, input.name);
        errdefer allocator.free(name);
        const agent_spec_id = try allocator.dupe(u8, input.agent_spec_id);
        errdefer allocator.free(agent_spec_id);
        const route_role = try allocator.dupe(u8, input.route_role);
        errdefer allocator.free(route_role);
        const capability_profile_id = try allocator.dupe(u8, input.capability_profile_id);
        errdefer allocator.free(capability_profile_id);
        const output_schema_json = try allocator.dupe(u8, "{}");
        errdefer allocator.free(output_schema_json);
        const failure_class = if (input.failure_class) |value| try allocator.dupe(u8, value) else null;
        errdefer if (failure_class) |value| allocator.free(value);
        const task = try allocator.create(Task);
        task.* = .{
            .parent_session_id = parent_session_id,
            .parent_checkpoint_id = parent_checkpoint_id,
            .session_id = session_id,
            .task_id = task_id,
            .name = name,
            .agent_spec_id = agent_spec_id,
            .route_role = route_role,
            .capability_profile_id = capability_profile_id,
            .output_schema_json = output_schema_json,
            .branch_seq = input.branch_seq,
            .remaining_depth = 0,
            .route = null,
            .transport = .{ .context = null, .sendFn = provider.httpSend },
            .agent_service = undefined,
            .lifecycle = input.lifecycle,
            .convergence = if (input.converged) .committed else .open,
            .terminal_evidence_committed = true,
            .failure_class = failure_class,
            .finished_at_ms = std.time.milliTimestamp(),
        };
        return task;
    }

    /// Publish one fully admitted group, then queue all members on the fixed pool.
    pub fn submitGroup(self: *Supervisor, input: GroupInput, prepared_tasks: []const *Task) !void {
        return self.submitGroupInternal(input, prepared_tasks, false);
    }

    /// Publish exactly one scheduler-admitted ticket task only when the fixed
    /// pool has an available slot. Ordinary child batches retain their
    /// existing queue semantics through submitGroup.
    pub fn submitTicketGroup(self: *Supervisor, input: GroupInput, prepared_task: *Task) !void {
        return self.submitGroupInternal(input, &.{prepared_task}, true);
    }

    /// Group admission / Publish one group into the sole Supervisor queue and
    /// reserve closure-tail accounting before spawning. Why: pool replacement
    /// must see queued work even between publication and worker entry.
    /// Preserves: ticket groups require admission headroom while model-selected
    /// batches may queue. Evidence: Move 28 contention test.
    fn submitGroupInternal(
        self: *Supervisor,
        input: GroupInput,
        prepared_tasks: []const *Task,
        require_capacity: bool,
    ) !void {
        if (prepared_tasks.len == 0) return Error.EmptyGroup;

        const group = try allocator.create(Group);
        errdefer allocator.destroy(group);
        const id = try allocator.dupe(u8, input.id);
        errdefer allocator.free(id);
        const parent_session_id = try allocator.dupe(u8, input.parent_session_id);
        errdefer allocator.free(parent_session_id);
        const workspace_root = try allocator.dupe(u8, input.workspace_root);
        errdefer allocator.free(workspace_root);
        const shared_context = try allocator.dupe(u8, input.shared_context);
        errdefer allocator.free(shared_context);
        const tasks = try allocator.dupe(*Task, prepared_tasks);
        errdefer allocator.free(tasks);
        group.* = .{
            .supervisor = self,
            .id = id,
            .parent_session_id = parent_session_id,
            .workspace_root = workspace_root,
            .shared_context = shared_context,
            .tasks = tasks,
            .created_at_ms = std.time.milliTimestamp(),
        };

        self.mutex.lock();
        if (!self.started) {
            self.mutex.unlock();
            return Error.InvalidConcurrency;
        }
        if (require_capacity) {
            if (self.capacityLocked().available == 0) {
                self.mutex.unlock();
                return Error.PoolFull;
            }
        }
        if (self.groups.contains(group.id)) {
            self.mutex.unlock();
            return Error.DuplicateGroup;
        }
        const parent = try self.ensureParentLocked(group.parent_session_id);
        try self.groups.put(allocator, group.id, group);
        parent.groups.append(allocator, group) catch |err| {
            _ = self.groups.remove(group.id);
            self.mutex.unlock();
            return err;
        };
        for (group.tasks) |task| task.group = group;
        self.pool_entries += group.tasks.len;
        self.mutex.unlock();

        self.emitGroupEvent(group, "child_group_started") catch {};
        for (group.tasks) |task| {
            self.emitTaskEvent(task, "child_admitted", null, null) catch {};
            self.emitTaskEvent(task, "child_queued", null, null) catch {};
        }
        for (group.tasks) |task| {
            self.pool.spawn(runTaskEntry, .{ self, task }) catch |err| {
                self.finishTask(task, .failed, @errorName(err));
                self.releasePoolEntry();
            };
        }
    }

    /// Publish one terminal group reconstructed from session receipts. This is
    /// the only disk-to-live-index bridge and never queues provider work.
    pub fn submitRecoveredGroup(
        self: *Supervisor,
        input: GroupInput,
        prepared_tasks: []const *Task,
    ) !void {
        if (prepared_tasks.len == 0) return Error.EmptyGroup;
        const group = try allocator.create(Group);
        errdefer allocator.destroy(group);
        const id = try allocator.dupe(u8, input.id);
        errdefer allocator.free(id);
        const parent_session_id = try allocator.dupe(u8, input.parent_session_id);
        errdefer allocator.free(parent_session_id);
        const workspace_root = try allocator.dupe(u8, input.workspace_root);
        errdefer allocator.free(workspace_root);
        const shared_context = try allocator.dupe(u8, input.shared_context);
        errdefer allocator.free(shared_context);
        const tasks = try allocator.dupe(*Task, prepared_tasks);
        errdefer allocator.free(tasks);
        group.* = .{
            .supervisor = self,
            .id = id,
            .parent_session_id = parent_session_id,
            .workspace_root = workspace_root,
            .shared_context = shared_context,
            .tasks = tasks,
            .convergence = if (allTasksConverged(prepared_tasks)) .committed else .open,
            .terminal_emitted = true,
            .terminal_evidence_committed = true,
            .created_at_ms = std.time.milliTimestamp(),
        };

        self.mutex.lock();
        if (self.groups.contains(group.id)) {
            self.mutex.unlock();
            return Error.DuplicateGroup;
        }
        const parent = try self.ensureParentLocked(group.parent_session_id);
        try self.groups.put(allocator, group.id, group);
        parent.groups.append(allocator, group) catch |err| {
            _ = self.groups.remove(group.id);
            self.mutex.unlock();
            return err;
        };
        for (group.tasks) |task| task.group = group;
        self.mutex.unlock();
        self.condition.broadcast();
    }

    pub fn renderGroup(self: *Supervisor, output_allocator: std.mem.Allocator, group_id: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const group = self.groups.get(group_id) orelse return Error.UnknownGroup;
        return renderGroupJsonLocked(output_allocator, group);
    }

    pub fn renderParent(self: *Supervisor, output_allocator: std.mem.Allocator, parent_session_id: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var output = std.array_list.Managed(u8).init(output_allocator);
        errdefer output.deinit();
        const writer = output.writer();
        const parent = self.parents.get(parent_session_id);
        try writer.writeAll("{\"schema\":\"var1.child_groups.v1\",\"parent_session_id\":");
        try writer.print("{f}", .{std.json.fmt(parent_session_id, .{})});
        try writer.writeAll(",\"groups\":[");
        if (parent) |value| {
            for (value.groups.items, 0..) |group, index| {
                if (index > 0) try writer.writeByte(',');
                const rendered = try renderGroupJsonLocked(output_allocator, group);
                defer output_allocator.free(rendered);
                try writer.writeAll(rendered);
            }
        }
        try writer.writeAll("]}");
        return output.toOwnedSlice();
    }

    pub fn hasParent(self: *Supervisor, parent_session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.parents.contains(parent_session_id);
    }

    pub fn hasGroup(self: *Supervisor, group_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.groups.contains(group_id);
    }

    /// Live session ownership / Scan the bounded fixed-pool inventory at one
    /// mutex point. Terminal receipts are not liveness evidence.
    pub fn ownsSession(self: *Supervisor, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var groups = self.groups.iterator();
        while (groups.next()) |entry| {
            for (entry.value_ptr.*.tasks) |task| {
                if (std.mem.eql(u8, task.session_id, session_id) and !isTerminal(task.lifecycle)) return true;
            }
        }
        return false;
    }

    pub fn waitGroup(self: *Supervisor, group_id: []const u8, timeout_ms: usize) !tools.AgentGroupSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const group = self.groups.get(group_id) orelse return Error.UnknownGroup;
        var snapshot = snapshotGroupLocked(group);
        if (snapshot.ready or snapshot.terminal or timeout_ms == 0) return snapshot;
        self.condition.timedWait(&self.mutex, timeoutToNs(timeout_ms)) catch {};
        snapshot = snapshotGroupLocked(group);
        return snapshot;
    }

    pub fn waitParent(self: *Supervisor, parent_session_id: []const u8, timeout_ms: usize) tools.AgentGroupSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var snapshot = snapshotParentLocked(self.parents.get(parent_session_id));
        if (snapshot.ready or snapshot.terminal or timeout_ms == 0) return snapshot;
        self.condition.timedWait(&self.mutex, timeoutToNs(timeout_ms)) catch {};
        snapshot = snapshotParentLocked(self.parents.get(parent_session_id));
        return snapshot;
    }

    pub fn cancelGroup(self: *Supervisor, group_id: []const u8, reason: []const u8) !usize {
        self.mutex.lock();
        const group = self.groups.get(group_id) orelse {
            self.mutex.unlock();
            return Error.UnknownGroup;
        };
        const cancelled_at_ms = std.time.milliTimestamp();
        var count: usize = 0;
        for (group.tasks) |task| {
            if (isTerminal(task.lifecycle)) continue;
            task.cancel_requested = true;
            count += 1;
            if (task.lifecycle == .queued) {
                task.lifecycle = .cancelled;
                task.finished_at_ms = cancelled_at_ms;
                if (task.failure_class) |value| allocator.free(value);
                task.failure_class = allocator.dupe(u8, reason) catch null;
            }
        }
        self.mutex.unlock();

        for (group.tasks) |task| {
            if (task.lifecycle != .cancelled or task.finished_at_ms != cancelled_at_ms) continue;
            markSessionTerminal(task, .cancelled, reason);
            if (self.commitTerminalTaskEvidence(task, reason)) disposeRoute(task);
        }
        self.condition.broadcast();
        return count;
    }

    pub fn cancelParent(self: *Supervisor, parent_session_id: []const u8, reason: []const u8) usize {
        self.mutex.lock();
        const parent = self.parents.get(parent_session_id);
        var group_ids = std.array_list.Managed([]const u8).init(allocator);
        defer group_ids.deinit();
        if (parent) |value| {
            group_ids.ensureTotalCapacity(value.groups.items.len) catch {
                self.mutex.unlock();
                return 0;
            };
            for (value.groups.items) |group| group_ids.appendAssumeCapacity(group.id);
        }
        self.mutex.unlock();

        var count: usize = 0;
        for (group_ids.items) |group_id| count += self.cancelGroup(group_id, reason) catch 0;
        return count;
    }

    /// Commit every terminal, unconsumed child for one parent exactly once.
    /// Siblings may remain queued or running; their later terminal signals
    /// create independent parent resumptions without duplicating this result.
    pub fn convergeParent(self: *Supervisor, output_allocator: std.mem.Allocator, parent_session_id: []const u8) !usize {
        var pending = std.array_list.Managed(*Task).init(output_allocator);
        defer pending.deinit();

        self.mutex.lock();
        if (self.parents.get(parent_session_id)) |parent| {
            for (parent.groups.items) |group| {
                for (group.tasks) |task| {
                    if (task.convergence != .open or !isTerminal(task.lifecycle) or !task.terminal_evidence_committed) continue;
                    task.convergence = .reserved;
                    pending.append(task) catch |err| {
                        task.convergence = .open;
                        self.mutex.unlock();
                        return err;
                    };
                }
            }
        }
        self.mutex.unlock();

        var committed: usize = 0;
        for (pending.items) |task| {
            self.commitTask(output_allocator, task) catch |err| {
                self.mutex.lock();
                task.convergence = .open;
                self.mutex.unlock();
                return err;
            };
            self.mutex.lock();
            task.convergence = .committed;
            const group = task.group.?;
            if (allTasksConverged(group.tasks)) group.convergence = .committed;
            self.mutex.unlock();
            committed += 1;
        }
        return committed;
    }

    pub fn workerLimit(self: *Supervisor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.max_concurrency;
    }

    pub fn capacity(self: *Supervisor) tools.AgentCapacitySnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.capacityLocked();
    }

    /// Discovery capacity projection / Avoid starting an unused pool, but apply
    /// changed config at an idle boundary once a physical pool exists. Why:
    /// model discovery must see the same ceiling as health and launch without
    /// manufacturing resident workers. Preserves: busy projections stay actual.
    /// Evidence: Move 27 no-start and Move 28 config-refresh tests.
    pub fn capacityProjection(self: *Supervisor, configured_max: usize) !tools.AgentCapacitySnapshot {
        self.mutex.lock();
        const was_started = self.started;
        self.mutex.unlock();
        if (was_started) _ = try self.start(configured_max);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started) return self.capacityLocked();
        return tools.AgentCapacitySnapshot.fromCounts(configured_max, 0, 0);
    }

    /// Live capacity projection / Read active and queued task state while the
    /// Supervisor mutex fixes one causal point. Why: every consumer must share
    /// the same idle and admission arithmetic. Preserves: terminal tasks release
    /// both projections. Evidence: Move 28 saturation and release tests.
    fn capacityLocked(self: *Supervisor) tools.AgentCapacitySnapshot {
        const active = self.activeCountsLocked();
        return tools.AgentCapacitySnapshot.fromCounts(self.max_concurrency, active.queued, active.running);
    }

    /// Pool-entry release / Mark one submitted closure unable to touch this
    /// Supervisor again. Why: task lifecycle may become terminal before event
    /// persistence returns. Preserves: pool replacement waits through that tail.
    /// Evidence: Move 28 idle resize plus full shutdown tests.
    fn releasePoolEntry(self: *Supervisor) void {
        self.mutex.lock();
        std.debug.assert(self.pool_entries > 0);
        self.pool_entries -= 1;
        self.mutex.unlock();
        self.condition.broadcast();
    }

    fn activeCountsLocked(self: *Supervisor) ActiveCounts {
        var counts = ActiveCounts{};
        var groups = self.groups.iterator();
        while (groups.next()) |entry| {
            for (entry.value_ptr.*.tasks) |task| {
                switch (task.lifecycle) {
                    .queued => counts.queued += 1,
                    .running => counts.running += 1,
                    .completed, .failed, .cancelled => {},
                }
            }
        }
        return counts;
    }

    pub fn liveDirectoryScanCount(_: *Supervisor) usize {
        return 0;
    }

    pub fn coldStartDirectoryScanCount(self: *Supervisor) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cold_start_directory_scans;
    }

    pub fn recordColdStartDirectoryScan(self: *Supervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cold_start_directory_scans += 1;
    }

    fn ensureParentLocked(self: *Supervisor, parent_session_id: []const u8) !*ParentState {
        if (self.parents.get(parent_session_id)) |parent| return parent;
        const parent = try allocator.create(ParentState);
        errdefer allocator.destroy(parent);
        parent.* = .{ .id = try allocator.dupe(u8, parent_session_id) };
        errdefer allocator.free(parent.id);
        try self.parents.put(allocator, parent.id, parent);
        return parent;
    }

    fn commitTask(self: *Supervisor, output_allocator: std.mem.Allocator, task: *Task) !void {
        const group = task.group.?;
        var summary = std.array_list.Managed(u8).init(output_allocator);
        defer summary.deinit();
        const writer = summary.writer();
        var session = try store.readSessionRecord(output_allocator, group.workspace_root, task.session_id);
        defer session.deinit(output_allocator);
        const output = try store.readOutput(output_allocator, group.workspace_root, task.session_id);
        defer if (output) |value| output_allocator.free(value);
        try writer.print("Converged child {s} ({s}) from group {s} [{s}]:\n", .{
            task.name,
            task.agent_spec_id,
            group.id,
            types.statusLabel(session.status),
        });
        if (summaries.readSummary(output_allocator, group.workspace_root, task.session_id) catch null) |row_value| {
            var row = row_value;
            defer row.deinit(output_allocator);
            try writer.print("{s}\n", .{row.summary});
        } else if (output) |value| {
            try writer.print("{s}\n", .{value});
        } else if (session.failure_reason) |value| {
            try writer.print("Failure: {s}\n", .{value});
        } else {
            try writer.writeAll("(no terminal output)\n");
        }
        try store.appendShardCheckpoint(
            output_allocator,
            group.workspace_root,
            group.parent_session_id,
            task.parent_checkpoint_id,
            task.branch_seq,
            if (session.status == .completed) .converged else .abandoned,
            output orelse session.failure_reason orelse "Child terminated without output.",
        );

        if (summary.items.len > mailbox.max_body_bytes) {
            summary.shrinkRetainingCapacity(boundedUtf8PrefixLen(summary.items, mailbox.max_body_bytes));
        }
        const tool_call_id = try convergenceToolCallId(output_allocator, group.id, task.task_id);
        defer output_allocator.free(tool_call_id);
        const summary_reference = try std.fmt.allocPrint(output_allocator, "summary:{s}", .{task.session_id});
        defer output_allocator.free(summary_reference);
        const group_reference = try std.fmt.allocPrint(output_allocator, "group:{s}", .{group.id});
        defer output_allocator.free(group_reference);
        const references = [_][]const u8{ summary_reference, group_reference };
        var receipt = try mailbox.send(output_allocator, group.workspace_root, .{
            .sender_session_id = task.session_id,
            .tool_call_id = tool_call_id,
            .target = .parent,
            .delivery = .wake,
            .body = summary.items,
            .references = references[0..],
            .delivery_sink = .{
                .context = self,
                .notifyFn = notifyMailboxDelivery,
            },
        });
        receipt.deinit(output_allocator);
    }

    fn emitTaskEvent(
        self: *Supervisor,
        task: *Task,
        event_type: []const u8,
        phase: ?[]const u8,
        detail: ?[]const u8,
    ) !void {
        const group = task.group orelse return;
        const now_ms = std.time.milliTimestamp();
        self.mutex.lock();
        const child_seq = task.next_event_seq;
        task.next_event_seq += 1;
        const lifecycle = task.lifecycle;
        const elapsed_ms = taskElapsedMs(task.started_at_ms, task.finished_at_ms, now_ms);
        self.mutex.unlock();
        const message = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"var1.child_event.v1\",\"group_id\":{f},\"child_session_id\":{f},\"task_id\":{f},\"child_seq\":{d},\"name\":{f},\"agent_spec_id\":{f},\"route_role\":{f},\"capability_profile_id\":{f},\"status\":{f},\"phase\":{f},\"detail\":{f},\"elapsed_ms\":{d}}}",
            .{
                std.json.fmt(group.id, .{}),
                std.json.fmt(task.session_id, .{}),
                std.json.fmt(task.task_id, .{}),
                child_seq,
                std.json.fmt(task.name, .{}),
                std.json.fmt(task.agent_spec_id, .{}),
                std.json.fmt(task.route_role, .{}),
                std.json.fmt(task.capability_profile_id, .{}),
                std.json.fmt(taskLifecycleLabel(lifecycle), .{}),
                std.json.fmt(phase, .{}),
                std.json.fmt(detail, .{}),
                elapsed_ms,
            },
        );
        defer allocator.free(message);
        try self.persistAndNotify(group, event_type, message);
    }

    fn emitGroupEvent(self: *Supervisor, group: *Group, event_type: []const u8) !void {
        self.mutex.lock();
        const snapshot = snapshotGroupLocked(group);
        const group_seq = group.next_event_seq;
        group.next_event_seq += 1;
        self.mutex.unlock();
        const message = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"var1.child_group.v1\",\"group_id\":{f},\"parent_session_id\":{f},\"group_seq\":{d},\"queued\":{d},\"running\":{d},\"completed\":{d},\"failed\":{d},\"cancelled\":{d},\"terminal\":{s}}}",
            .{
                std.json.fmt(group.id, .{}),
                std.json.fmt(group.parent_session_id, .{}),
                group_seq,
                snapshot.queued,
                snapshot.running,
                snapshot.completed,
                snapshot.failed,
                snapshot.cancelled,
                if (snapshot.terminal or std.mem.eql(u8, event_type, "child_group_finished")) "true" else "false",
            },
        );
        defer allocator.free(message);
        try self.persistAndNotify(group, event_type, message);
    }

    fn persistAndNotify(self: *Supervisor, group: *Group, event_type: []const u8, message: []const u8) !void {
        const timestamp_ms = std.time.milliTimestamp();
        const seq = try store.appendEventWithSeq(allocator, group.workspace_root, group.parent_session_id, .{
            .event_type = event_type,
            .message = message,
            .timestamp_ms = timestamp_ms,
        });
        self.mutex.lock();
        const sink = self.event_sink;
        self.mutex.unlock();
        sink.notify(group.parent_session_id, seq, event_type, message, timestamp_ms) catch {};
    }

    fn finishTask(self: *Supervisor, task: *Task, lifecycle: TaskLifecycle, failure_class: ?[]const u8) void {
        self.mutex.lock();
        if (isTerminal(task.lifecycle)) {
            self.mutex.unlock();
            return;
        }
        task.lifecycle = lifecycle;
        task.finished_at_ms = std.time.milliTimestamp();
        if (task.failure_class) |value| allocator.free(value);
        task.failure_class = if (failure_class) |value| allocator.dupe(u8, value) catch null else null;
        self.mutex.unlock();

        _ = self.commitTerminalTaskEvidence(task, failure_class);
    }

    /// Publish one child terminal event before making the enclosing group
    /// terminal. Concurrent workers cannot overtake one another at this gate.
    fn commitTerminalTaskEvidence(self: *Supervisor, task: *Task, detail: ?[]const u8) bool {
        if (!hasDurableTerminalState(task)) {
            self.condition.broadcast();
            return false;
        }
        const task_event_committed = blk: {
            self.emitTaskEvent(task, "child_finished", "complete", detail) catch break :blk false;
            break :blk true;
        };

        self.mutex.lock();
        if (task_event_committed) task.terminal_evidence_committed = true;
        const group = task.group.?;
        const became_terminal = if (task_event_committed) markGroupTerminalLocked(group) else false;
        self.mutex.unlock();

        if (became_terminal) {
            const group_event_committed = blk: {
                self.emitGroupEvent(group, "child_group_finished") catch break :blk false;
                break :blk true;
            };
            self.mutex.lock();
            group.terminal_evidence_committed = group_event_committed;
            if (!group_event_committed) group.terminal_emitted = false;
            self.mutex.unlock();
        }
        self.condition.broadcast();
        return true;
    }
};

pub fn convergenceToolCallId(allocator_: std.mem.Allocator, group_id: []const u8, task_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator_, "child-convergence:{s}:{s}", .{ group_id, task_id });
}

fn boundedUtf8PrefixLen(value: []const u8, max_bytes: usize) usize {
    if (value.len <= max_bytes) return value.len;
    var end = max_bytes;
    while (end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    return end;
}

fn notifyMailboxDelivery(
    ctx: ?*anyopaque,
    session_id: []const u8,
    seq: u64,
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const supervisor: *Supervisor = @ptrCast(@alignCast(ctx.?));
    try supervisor.notifySessionEvent(session_id, seq, event_type, message, timestamp_ms);
}

fn runTaskEntry(supervisor: *Supervisor, task: *Task) void {
    defer supervisor.releasePoolEntry();
    supervisor.mutex.lock();
    if (isTerminal(task.lifecycle)) {
        supervisor.mutex.unlock();
        return;
    }
    task.lifecycle = .running;
    task.started_at_ms = std.time.milliTimestamp();
    supervisor.mutex.unlock();
    supervisor.emitTaskEvent(task, "child_started", "starting", null) catch {};

    const route = task.route orelse {
        supervisor.finishTask(task, .failed, "MissingResolvedRoute");
        return;
    };
    if (route.execution_kind == .kernel) {
        markSessionTerminal(task, .failed, "KernelRouteIsNotAgentExecutable");
        disposeRoute(task);
        supervisor.finishTask(task, .failed, "KernelRouteIsNotAgentExecutable");
        return;
    }
    if (route.execution_kind == .model_task) {
        if (runModelTask(supervisor, task, route)) |_| {
            disposeRoute(task);
            supervisor.finishTask(task, .completed, null);
        } else |err| {
            const lifecycle: TaskLifecycle = if (err == executor.Error.Cancelled) .cancelled else .failed;
            if (lifecycle == .cancelled) {
                markSessionTerminal(task, .cancelled, "ModelTaskCancelled");
            } else {
                markSessionTerminal(task, if (err == error.ConnectionTimedOut) .timed_out else .failed, @errorName(err));
            }
            disposeRoute(task);
            supervisor.finishTask(task, lifecycle, @errorName(err));
        }
        return;
    }

    _ = profile_contract.resolveProfile(task.capability_profile_id) catch {
        markSessionTerminal(task, .failed, "UnsupportedCapabilityProfile");
        disposeRoute(task);
        supervisor.finishTask(task, .failed, "UnsupportedCapabilityProfile");
        return;
    };
    const child_agent_service = if (route.execution_kind == .agent_session)
        task.agent_service
    else
        null;
    // Provider route construction stays provider-owned. Load the canonical
    // operator posture at the execution seam so every child receives the
    // same prompt policy as the parent without a second config owner.
    var runtime_policy = config_file.loadRuntimePolicy(std.heap.page_allocator, route.config.workspace_root) catch config_file.RuntimePolicy{};
    defer runtime_policy.deinit(std.heap.page_allocator);
    route.config.log_level = runtime_policy.log_level;
    const hooks = executor.Hooks{
        .context = task,
        .onSessionEventFn = onChildSessionEvent,
        .shouldCancelFn = shouldCancelTask,
    };

    const result = executor.runPromptWithOptions(std.heap.page_allocator, route.config, "", .{
        .transport = task.transport,
        .execution_context = childExecutionContext(route, task, child_agent_service),
        .session_id = task.session_id,
        .hooks = hooks,
    });

    var lifecycle: TaskLifecycle = .completed;
    var failure_class: ?[]const u8 = null;
    if (result) |run_result| {
        run_result.deinit(std.heap.page_allocator);
    } else |err| {
        lifecycle = if (err == executor.Error.Cancelled) .cancelled else .failed;
        failure_class = @errorName(err);
    }

    if (store.readSessionRecord(std.heap.page_allocator, route.config.workspace_root, task.session_id)) |session| {
        var owned_session = session;
        defer owned_session.deinit(std.heap.page_allocator);
        lifecycle = switch (owned_session.status) {
            .completed => .completed,
            .cancelled => .cancelled,
            .failed => .failed,
            else => lifecycle,
        };
        if (owned_session.failure_reason) |value| failure_class = value;
        supervisor.finishTask(task, lifecycle, failure_class);
    } else |_| {
        supervisor.finishTask(task, lifecycle, failure_class);
    }
    disposeRoute(task);
}

fn childExecutionContext(
    route: *const routes.ResolvedRoute,
    task: *const Task,
    child_agent_service: ?tools.AgentService,
) tools.ExecutionContext {
    return .{
        .workspace_root = route.config.workspace_root,
        .full_access_mode = route.config.full_access_mode,
        .parent_session_id = task.session_id,
        .agent_service = child_agent_service,
        .capability_profile_id = task.capability_profile_id,
        .delegation_depth_remaining = task.remaining_depth,
    };
}

fn runModelTask(supervisor: *Supervisor, task: *Task, route: *routes.ResolvedRoute) !void {
    const task_allocator = std.heap.page_allocator;
    if (shouldCancelTask(task, task.session_id)) return executor.Error.Cancelled;
    var session = try store.readSessionRecord(task_allocator, route.config.workspace_root, task.session_id);
    defer session.deinit(task_allocator);
    try store.setSessionStatus(task_allocator, route.config.workspace_root, &session, .running);
    const run_seq = try store.appendEventWithSeq(task_allocator, route.config.workspace_root, task.session_id, .{
        .event_type = "session_started",
        .message = "Bounded model task started.",
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try supervisor.emitTaskEvent(task, "child_progress", "model_task_provider_turn", null);

    var prompt_message = try types.initTextMessage(task_allocator, .user, session.prompt);
    defer prompt_message.deinit(task_allocator);
    const messages = [_]types.ChatMessage{prompt_message};
    var completion = try provider_dispatch.completeWithTransportAndHooks(
        task_allocator,
        route.config,
        .{ .messages = messages[0..], .tool_definitions = &.{} },
        task.transport,
        .{
            .context = task,
            .onAssistantDeltaFn = onModelTaskAssistantDelta,
            .onReasoningDeltaFn = onModelTaskReasoningDelta,
        },
    );
    defer completion.deinit(task_allocator);
    if (shouldCancelTask(task, task.session_id)) return executor.Error.Cancelled;
    if (completion.hasToolCalls()) return Error.ModelTaskToolCall;
    const content = completion.content orelse return Error.InvalidModelTaskOutput;
    try validateModelTaskOutput(task_allocator, task.output_schema_json, content);

    const now_ms = std.time.milliTimestamp();
    try store.upsertAssistantSessionMessageWithReasoning(task_allocator, route.config.workspace_root, task.session_id, content, completion.reasoning, now_ms);
    try store.writeOutput(task_allocator, route.config.workspace_root, task.session_id, content);
    try store.appendEvent(task_allocator, route.config.workspace_root, task.session_id, .{
        .event_type = "assistant_response",
        .message = content,
        .timestamp_ms = now_ms,
    });
    var terminal = try store.commitTurnTerminal(
        task_allocator,
        route.config.workspace_root,
        &session,
        run_seq,
        turn_payload.completedTerminalInput(0, &.{}, completion.model, completion.usage, content.len),
        now_ms,
    );
    defer terminal.deinit(task_allocator);
    store.syncSessionLedgers(task_allocator, route.config.workspace_root, task.session_id) catch {};
}

fn onModelTaskAssistantDelta(ctx: ?*anyopaque, delta: []const u8) anyerror!void {
    const task: *Task = @ptrCast(@alignCast(ctx.?));
    const route = task.route orelse return;
    try store.appendEvent(std.heap.page_allocator, route.config.workspace_root, task.session_id, .{
        .event_type = "assistant_delta",
        .message = delta,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

fn onModelTaskReasoningDelta(ctx: ?*anyopaque, delta: []const u8) anyerror!void {
    const task: *Task = @ptrCast(@alignCast(ctx.?));
    const route = task.route orelse return;
    try store.appendEvent(std.heap.page_allocator, route.config.workspace_root, task.session_id, .{
        .event_type = "reasoning_delta",
        .message = delta,
        .timestamp_ms = std.time.milliTimestamp(),
    });
}

fn validateModelTaskOutput(allocator_: std.mem.Allocator, schema_json: []const u8, content: []const u8) !void {
    const schema_text = std.mem.trim(u8, schema_json, " \t\r\n");
    if (schema_text.len == 0 or std.mem.eql(u8, schema_text, "{}")) return;
    var schema = std.json.parseFromSlice(std.json.Value, allocator_, schema_text, .{}) catch return Error.InvalidModelTaskOutput;
    defer schema.deinit();
    if (schema.value != .object) return Error.InvalidModelTaskOutput;
    var output = std.json.parseFromSlice(std.json.Value, allocator_, content, .{}) catch return Error.InvalidModelTaskOutput;
    defer output.deinit();

    if (schema.value.object.get("type")) |expected| {
        if (expected != .string or !jsonTypeMatches(expected.string, output.value)) return Error.InvalidModelTaskOutput;
    }
    if (schema.value.object.get("required")) |required| {
        if (required != .array or output.value != .object) return Error.InvalidModelTaskOutput;
        for (required.array.items) |field| {
            if (field != .string or !output.value.object.contains(field.string)) return Error.InvalidModelTaskOutput;
        }
    }
    if (schema.value.object.get("properties")) |properties| {
        if (properties != .object or output.value != .object) return Error.InvalidModelTaskOutput;
        var iterator = properties.object.iterator();
        while (iterator.next()) |entry| {
            const actual = output.value.object.get(entry.key_ptr.*) orelse continue;
            if (entry.value_ptr.* != .object) return Error.InvalidModelTaskOutput;
            if (entry.value_ptr.object.get("type")) |expected| {
                if (expected != .string or !jsonTypeMatches(expected.string, actual)) return Error.InvalidModelTaskOutput;
            }
        }
    }
}

fn jsonTypeMatches(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "object")) return value == .object;
    if (std.mem.eql(u8, expected, "array")) return value == .array;
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, expected, "integer")) return value == .integer;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "null")) return value == .null;
    return false;
}

fn onChildSessionEvent(
    ctx: ?*anyopaque,
    _: []const u8,
    _: u64,
    event_type: []const u8,
    message: []const u8,
    _: []const u8,
    _: i64,
) anyerror!void {
    if (!shouldProjectChildEvent(event_type)) return;
    const task: *Task = @ptrCast(@alignCast(ctx.?));

    // Summary updates are already durable tool events. Reuse that boundary to
    // refresh the parent's keyed child row while the child is still running;
    // do not add a poller or a second summary stream.
    if (isSummaryToolCompletion(event_type, message)) {
        if (summaries.readSummary(std.heap.page_allocator, task.group.?.workspace_root, task.session_id) catch null) |row_value| {
            var row = row_value;
            defer row.deinit(std.heap.page_allocator);
            taskSupervisor(task).emitTaskEvent(task, "child_progress", "summary", row.summary) catch {};
            return;
        }
    }

    const projected_type = if (std.mem.eql(u8, event_type, "session_waiting")) "child_waiting" else "child_progress";
    const phase = if (std.mem.eql(u8, event_type, "session_waiting")) "waiting" else event_type;

    // The turn-end summary is the operator-useful child projection. Prefer
    // the durable summary row, which is already refreshed before the final
    // assistant event, and fall back to the response payload for model-task
    // or legacy sessions without a summary row.
    if (std.mem.eql(u8, event_type, "assistant_response")) {
        if (summaries.readSummary(std.heap.page_allocator, task.group.?.workspace_root, task.session_id) catch null) |row_value| {
            var row = row_value;
            defer row.deinit(std.heap.page_allocator);
            taskSupervisor(task).emitTaskEvent(task, projected_type, phase, row.summary) catch {};
            return;
        }
    }
    taskSupervisor(task).emitTaskEvent(task, projected_type, phase, message) catch {};
}

fn shouldCancelTask(ctx: ?*anyopaque, _: []const u8) bool {
    const task: *Task = @ptrCast(@alignCast(ctx.?));
    const supervisor = taskSupervisor(task);
    supervisor.mutex.lock();
    defer supervisor.mutex.unlock();
    return task.cancel_requested;
}

fn taskSupervisor(task: *Task) *Supervisor {
    return task.group.?.supervisor;
}

fn shouldProjectChildEvent(event_type: []const u8) bool {
    const projected = [_][]const u8{
        "session_started",
        "tool_requested",
        "tool_reviewed",
        "tool_started",
        "tool_finished",
        "tool_completed",
        "session_waiting",
        "assistant_response",
        protocol_events.turn_terminal_event_type,
    };
    for (projected) |candidate| if (std.mem.eql(u8, event_type, candidate)) return true;
    return false;
}

fn isSummaryToolCompletion(event_type: []const u8, message: []const u8) bool {
    return std.mem.eql(u8, event_type, "tool_completed") and
        std.mem.eql(u8, message, "tool completed: update_session_summary");
}

fn disposeRoute(task: *Task) void {
    if (task.route) |route| {
        route.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(route);
        task.route = null;
    }
}

fn markSessionTerminal(task: *Task, outcome: protocol_events.TurnTerminalOutcome, reason: []const u8) void {
    const route = task.route orelse return;
    var session = store.readSessionRecord(std.heap.page_allocator, route.config.workspace_root, task.session_id) catch return;
    defer session.deinit(std.heap.page_allocator);
    var terminal = store.commitTurnTerminal(
        std.heap.page_allocator,
        route.config.workspace_root,
        &session,
        null,
        .{ .outcome = outcome, .detail = reason },
        std.time.milliTimestamp(),
    ) catch return;
    terminal.deinit(std.heap.page_allocator);
}

fn hasDurableTerminalState(task: *Task) bool {
    const group = task.group orelse return false;
    var session = store.readSessionRecord(std.heap.page_allocator, group.workspace_root, task.session_id) catch return false;
    defer session.deinit(std.heap.page_allocator);
    return switch (task.lifecycle) {
        .completed => session.status == .completed,
        .failed => session.status == .failed,
        .cancelled => session.status == .cancelled,
        else => false,
    };
}

fn renderGroupJsonLocked(output_allocator: std.mem.Allocator, group: *Group) ![]u8 {
    var output = std.array_list.Managed(u8).init(output_allocator);
    errdefer output.deinit();
    const writer = output.writer();
    const snapshot = snapshotGroupLocked(group);
    try writer.writeAll("{\"schema\":\"var1.child_group.v1\",\"group_id\":");
    try writer.print("{f}", .{std.json.fmt(group.id, .{})});
    try writer.writeAll(",\"parent_session_id\":");
    try writer.print("{f}", .{std.json.fmt(group.parent_session_id, .{})});
    var terminal_at_ms = group.created_at_ms;
    for (group.tasks) |task| {
        if (task.finished_at_ms > terminal_at_ms) terminal_at_ms = task.finished_at_ms;
    }
    const duration_ms = if (snapshot.terminal) @max(@as(i64, 0), terminal_at_ms - group.created_at_ms) else @max(@as(i64, 0), std.time.milliTimestamp() - group.created_at_ms);
    try writer.print(",\"created_at_ms\":{d},\"duration_ms\":{d},\"queued\":{d},\"running\":{d},\"completed\":{d},\"failed\":{d},\"cancelled\":{d},\"ready\":{s},\"terminal\":{s},\"converged\":{s},\"tasks\":[", .{
        group.created_at_ms,
        duration_ms,
        snapshot.queued,
        snapshot.running,
        snapshot.completed,
        snapshot.failed,
        snapshot.cancelled,
        if (snapshot.ready) "true" else "false",
        if (snapshot.terminal) "true" else "false",
        if (group.convergence == .committed) "true" else "false",
    });
    for (group.tasks, 0..) |task, index| {
        if (index > 0) try writer.writeByte(',');
        const task_duration_ms = if (task.started_at_ms > 0 and task.finished_at_ms >= task.started_at_ms) task.finished_at_ms - task.started_at_ms else 0;
        try writer.print("{{\"task_id\":{f},\"name\":{f},\"session_id\":{f},\"agent_spec_id\":{f},\"route_role\":{f},\"capability_profile_id\":{f},\"branch_seq\":{d},\"status\":{f},\"converged\":{s},\"started_at_ms\":{d},\"finished_at_ms\":{d},\"duration_ms\":{d},\"failure_class\":{f}}}", .{
            std.json.fmt(task.task_id, .{}),
            std.json.fmt(task.name, .{}),
            std.json.fmt(task.session_id, .{}),
            std.json.fmt(task.agent_spec_id, .{}),
            std.json.fmt(task.route_role, .{}),
            std.json.fmt(task.capability_profile_id, .{}),
            task.branch_seq,
            std.json.fmt(taskLifecycleLabel(task.lifecycle), .{}),
            if (task.convergence == .committed) "true" else "false",
            task.started_at_ms,
            task.finished_at_ms,
            task_duration_ms,
            std.json.fmt(task.failure_class, .{}),
        });
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice();
}

fn snapshotGroupLocked(group: *Group) tools.AgentGroupSnapshot {
    var snapshot = tools.AgentGroupSnapshot{ .groups = 1 };
    for (group.tasks) |task| {
        switch (task.lifecycle) {
            .queued => snapshot.queued += 1,
            .running => snapshot.running += 1,
            .completed => snapshot.completed += 1,
            .failed => snapshot.failed += 1,
            .cancelled => snapshot.cancelled += 1,
        }
        if (isTerminal(task.lifecycle) and task.terminal_evidence_committed and task.convergence == .open) snapshot.ready = true;
    }
    snapshot.terminal = snapshot.queued == 0 and snapshot.running == 0 and group.terminal_evidence_committed;
    return snapshot;
}

fn snapshotParentLocked(parent: ?*ParentState) tools.AgentGroupSnapshot {
    var snapshot = tools.AgentGroupSnapshot{};
    const value = parent orelse return snapshot;
    snapshot.groups = value.groups.items.len;
    snapshot.terminal = true;
    for (value.groups.items) |group| {
        const group_snapshot = snapshotGroupLocked(group);
        snapshot.queued += group_snapshot.queued;
        snapshot.running += group_snapshot.running;
        snapshot.completed += group_snapshot.completed;
        snapshot.failed += group_snapshot.failed;
        snapshot.cancelled += group_snapshot.cancelled;
        if (group_snapshot.ready) snapshot.ready = true;
        if (!group_snapshot.terminal) snapshot.terminal = false;
    }
    return snapshot;
}

fn markGroupTerminalLocked(group: *Group) bool {
    const has_active_tasks = for (group.tasks) |task| {
        if (!isTerminal(task.lifecycle) or !task.terminal_evidence_committed) break true;
    } else false;
    if (has_active_tasks or group.terminal_emitted) return false;
    group.terminal_emitted = true;
    return true;
}

fn taskLifecycleLabel(lifecycle: TaskLifecycle) []const u8 {
    return @tagName(lifecycle);
}

fn isTerminal(lifecycle: TaskLifecycle) bool {
    return lifecycle == .completed or lifecycle == .failed or lifecycle == .cancelled;
}

fn allTasksConverged(tasks: []const *Task) bool {
    if (tasks.len == 0) return false;
    for (tasks) |task| if (task.convergence != .committed) return false;
    return true;
}

fn timeoutToNs(timeout_ms: usize) u64 {
    return std.math.mul(u64, @intCast(timeout_ms), std.time.ns_per_ms) catch std.math.maxInt(u64);
}

fn taskElapsedMs(started_at_ms: i64, finished_at_ms: i64, now_ms: i64) i64 {
    if (started_at_ms <= 0) return 0;
    const end_ms = if (finished_at_ms > 0) finished_at_ms else now_ms;
    return @max(@as(i64, 0), end_ms - started_at_ms);
}

test "child elapsed snapshot uses live or terminal task time and clamps invalid values" {
    try std.testing.expectEqual(@as(i64, 0), taskElapsedMs(0, 0, 500));
    try std.testing.expectEqual(@as(i64, 1_250), taskElapsedMs(1_000, 0, 2_250));
    try std.testing.expectEqual(@as(i64, 2_000), taskElapsedMs(1_000, 3_000, 9_999));
    try std.testing.expectEqual(@as(i64, 0), taskElapsedMs(3_000, 2_000, 9_999));
}

test "summary tool completion is the live child-summary projection boundary" {
    try std.testing.expect(isSummaryToolCompletion("tool_completed", "tool completed: update_session_summary"));
    try std.testing.expect(!isSummaryToolCompletion("tool_started", "tool completed: update_session_summary"));
    try std.testing.expect(!isSummaryToolCompletion("tool_completed", "tool completed: read_file"));
}

test "child execution context preserves the resolved access mode" {
    var route: routes.ResolvedRoute = undefined;
    route.config.workspace_root = "launch-workspace";
    route.config.full_access_mode = true;

    var task: Task = undefined;
    task.session_id = "child-session";
    task.capability_profile_id = "subagent";
    task.remaining_depth = 1;

    var execution_context = childExecutionContext(&route, &task, null);
    try std.testing.expect(execution_context.full_access_mode);
    try std.testing.expectEqualStrings("launch-workspace", execution_context.workspace_root);
    try std.testing.expectEqualStrings("child-session", execution_context.parent_session_id.?);

    route.config.full_access_mode = false;
    execution_context = childExecutionContext(&route, &task, null);
    try std.testing.expect(!execution_context.full_access_mode);
}

test "group snapshots are terminal only after every task reaches a terminal state" {
    var first = Task{
        .parent_session_id = undefined,
        .parent_checkpoint_id = undefined,
        .session_id = undefined,
        .task_id = undefined,
        .name = undefined,
        .agent_spec_id = undefined,
        .route_role = undefined,
        .capability_profile_id = undefined,
        .output_schema_json = undefined,
        .branch_seq = 1,
        .remaining_depth = 0,
        .route = null,
        .transport = undefined,
        .agent_service = undefined,
    };
    var second = first;
    var task_list = [_]*Task{ &first, &second };
    var group = Group{
        .supervisor = undefined,
        .id = undefined,
        .parent_session_id = undefined,
        .workspace_root = undefined,
        .shared_context = undefined,
        .tasks = task_list[0..],
        .created_at_ms = 0,
    };
    try std.testing.expect(!snapshotGroupLocked(&group).terminal);
    first.lifecycle = .completed;
    second.lifecycle = .failed;
    try std.testing.expect(!snapshotGroupLocked(&group).terminal);
    first.terminal_evidence_committed = true;
    second.terminal_evidence_committed = true;
    group.terminal_evidence_committed = true;
    try std.testing.expect(snapshotGroupLocked(&group).terminal);
}

test "ticket capacity counts queued and running work and releases terminal tasks" {
    var supervisor = Supervisor{ .max_concurrency = 3 };
    defer supervisor.groups.deinit(std.heap.page_allocator);

    var queued = Task{
        .parent_session_id = undefined,
        .parent_checkpoint_id = undefined,
        .session_id = undefined,
        .task_id = undefined,
        .name = undefined,
        .agent_spec_id = undefined,
        .route_role = undefined,
        .capability_profile_id = undefined,
        .output_schema_json = undefined,
        .branch_seq = 1,
        .remaining_depth = 0,
        .route = null,
        .transport = undefined,
        .agent_service = undefined,
        .lifecycle = .queued,
    };
    var running = queued;
    running.lifecycle = .running;
    var tasks = [_]*Task{ &queued, &running };
    var group = Group{
        .supervisor = &supervisor,
        .id = undefined,
        .parent_session_id = undefined,
        .workspace_root = undefined,
        .shared_context = undefined,
        .tasks = tasks[0..],
        .created_at_ms = 0,
    };
    try supervisor.groups.put(std.heap.page_allocator, "ticket-capacity", &group);

    var snapshot = supervisor.capacity();
    try std.testing.expectEqual(@as(usize, 3), snapshot.max);
    try std.testing.expectEqual(@as(usize, 1), snapshot.queued);
    try std.testing.expectEqual(@as(usize, 1), snapshot.running);
    try std.testing.expectEqual(@as(usize, 2), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 1), snapshot.available);

    queued.lifecycle = .completed;
    running.lifecycle = .failed;
    snapshot = supervisor.capacity();
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued);
    try std.testing.expectEqual(@as(usize, 0), snapshot.running);
    try std.testing.expectEqual(@as(usize, 3), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 3), snapshot.available);

    queued.lifecycle = .queued;
    running.lifecycle = .running;
    supervisor.max_concurrency = 1;
    snapshot = supervisor.capacity();
    try std.testing.expectEqual(@as(usize, 1), snapshot.max);
    try std.testing.expectEqual(@as(usize, 2), snapshot.queued + snapshot.running);
    try std.testing.expectEqual(@as(usize, 0), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 0), snapshot.available);
}
