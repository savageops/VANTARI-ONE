const std = @import("std");
const agent_scope = @import("../agents/scope.zig");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

pub const DelegationScope = agent_scope.DelegationScope;

pub const DependencyKind = types.DependencyKind;
pub const Dependency = types.Dependency;
pub const AvailabilitySpec = types.AvailabilitySpec;

pub const CommandProbe = struct {
    context: ?*anyopaque = null,
    commandExistsFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        command_name: []const u8,
    ) anyerror!bool,
    commandMatchesFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        command_name: []const u8,
        argv: []const []const u8,
        stdout_needles: []const []const u8,
    ) anyerror!bool = null,

    pub fn commandExists(
        self: CommandProbe,
        allocator: std.mem.Allocator,
        command_name: []const u8,
    ) anyerror!bool {
        return self.commandExistsFn(self.context, allocator, command_name);
    }

    pub fn commandMatches(
        self: CommandProbe,
        allocator: std.mem.Allocator,
        command_name: []const u8,
        argv: []const []const u8,
        stdout_needles: []const []const u8,
    ) anyerror!bool {
        if (self.commandMatchesFn) |matches| {
            return matches(self.context, allocator, command_name, argv, stdout_needles);
        }
        return self.commandExists(allocator, command_name);
    }
};

pub const Error = error{
    AgentEligibilityRequired,
    AgentServiceUnavailable,
    CapabilityDenied,
    CommandFailed,
    CommandTerminated,
    CommandTimedOut,
    FileNotInspected,
    InvalidArguments,
    InputUnavailable,
    MissingParentSession,
    MemoryWritesDisabled,
    PatternNotFound,
    ToolPayloadExceeded,
    ToolUnavailable,
    UnknownTool,
};

pub const InputService = struct {
    context: ?*anyopaque = null,
    requestFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        request_id: []const u8,
        request_json: []const u8,
    ) anyerror![]u8 = null,

    pub fn request(
        self: InputService,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        request_id: []const u8,
        request_json: []const u8,
    ) ![]u8 {
        const callback = self.requestFn orelse return Error.InputUnavailable;
        return callback(self.context, allocator, session_id, request_id, request_json);
    }
};

pub const CommandOutput = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool = false,
    /// True when stdout or stderr exceeded `max_output_bytes` and was
    /// truncated. The caller must surface this as typed evidence — silent
    /// truncation is a contract violation (AGENTS.md §IV).
    truncated: bool = false,

    pub fn deinit(self: CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandOutputStream = enum {
    stdout,
    stderr,
};

pub const CommandOutputCallback = struct {
    context: ?*anyopaque = null,
    onOutputFn: ?*const fn (
        ctx: ?*anyopaque,
        stream: CommandOutputStream,
        chunk: []const u8,
        cap_reached: bool,
    ) anyerror!void = null,

    pub fn onOutput(
        self: CommandOutputCallback,
        stream: CommandOutputStream,
        chunk: []const u8,
        cap_reached: bool,
    ) !void {
        if (chunk.len == 0 and !cap_reached) return;
        if (self.onOutputFn) |callback| {
            try callback(self.context, stream, chunk, cap_reached);
        }
    }
};

pub const CommandLimits = struct {
    timeout_ms: usize = 10_000,
    max_output_bytes: usize = 16 * 1024,
    output_callback: CommandOutputCallback = .{},
};

pub const CommandRunner = struct {
    context: ?*anyopaque,
    runFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput,
    runWithLimitsFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
        limits: CommandLimits,
    ) anyerror!CommandOutput = null,

    pub fn run(
        self: CommandRunner,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) anyerror!CommandOutput {
        return self.runFn(self.context, allocator, cwd, argv);
    }

    pub fn runWithLimits(
        self: CommandRunner,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
        limits: CommandLimits,
    ) anyerror!CommandOutput {
        if (self.runWithLimitsFn) |run_limited| {
            return run_limited(self.context, allocator, cwd, argv, limits);
        }
        return self.runFn(self.context, allocator, cwd, argv);
    }
};

pub const AgentTaskRequest = struct {
    name: ?[]const u8 = null,
    agent_id: []const u8,
    task: []const u8,
    output_schema_json: []const u8 = "{}",
};

pub const AgentGroupSnapshot = struct {
    groups: usize = 0,
    queued: usize = 0,
    running: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
    /// At least one terminal child has durable evidence that has not yet been
    /// converged into the parent context.
    ready: bool = false,
    terminal: bool = true,
};

pub const AgentCapacitySnapshot = struct {
    max: usize = 0,
    queued: usize = 0,
    running: usize = 0,
    idle: usize = 0,
    available: usize = 0,

    /// Capacity projection / Derive every pool count from one configured
    /// ceiling. Why: idle workers and new-ticket admission are not the same
    /// quantity when admitted work is queued. Preserves: running remains
    /// unclamped so `running <= max` stays falsifiable. Evidence: Move 28
    /// contention and health projection tests.
    pub fn fromCounts(max: usize, queued: usize, running: usize) AgentCapacitySnapshot {
        const idle = max -| running;
        return .{
            .max = max,
            .queued = queued,
            .running = running,
            .idle = idle,
            .available = idle -| queued,
        };
    }
};

/// One scheduler-admitted ticket carried into the canonical agent runtime.
/// Claim identity stays typed so a ticket cannot silently become a generic
/// child batch with a different session or agent.
pub const TicketTaskRequest = struct {
    ticket_id: []const u8,
    title: []const u8,
    description: []const u8,
    category: []const u8,
    source_session_id: []const u8 = "",
    expected_revision: u64,
    worker_id: []const u8,
    worker_generation: u64,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    attempt: u32,
    agent_hint: []const u8,
    idempotency_key: []const u8,
};

/// One expired claim fenced onto its existing child session. Recovery may
/// replace process ownership, but it cannot replace the durable work identity.
pub const ResumeTicketRequest = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    worker_id: []const u8,
    worker_generation: u64,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    session_id: []const u8,
    idempotency_key: []const u8,
    resumed_at_ms: i64,
};

pub const TicketLaunchReceipt = struct {
    ticket_id: []u8,
    group_id: []u8,
    task_id: []u8,
    session_id: []u8,
    agent_id: []u8,
    route_role: []u8,
    capability_profile_id: []u8,
    capability_hash: []u8,
    model: []u8,

    pub fn deinit(self: *TicketLaunchReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.ticket_id);
        allocator.free(self.group_id);
        allocator.free(self.task_id);
        allocator.free(self.session_id);
        allocator.free(self.agent_id);
        allocator.free(self.route_role);
        allocator.free(self.capability_profile_id);
        allocator.free(self.capability_hash);
        allocator.free(self.model);
    }
};

pub const AgentEventSink = struct {
    context: ?*anyopaque = null,
    notifyFn: ?*const fn (
        ctx: ?*anyopaque,
        parent_session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,

    pub fn notify(
        self: AgentEventSink,
        parent_session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.notifyFn) |callback| {
            try callback(self.context, parent_session_id, seq, event_type, message, timestamp_ms);
        }
    }
};

pub const AgentService = struct {
    context: ?*anyopaque,
    launchFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
        scope: DelegationScope,
    ) anyerror![]u8,
    launchBatchFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        shared_context: []const u8,
        tasks: []const AgentTaskRequest,
        scope: DelegationScope,
    ) anyerror![]u8 = null,
    launchTicketFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: TicketTaskRequest,
    ) anyerror!TicketLaunchReceipt = null,
    resumeTicketFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: ResumeTicketRequest,
    ) anyerror!TicketLaunchReceipt = null,
    capacityFn: ?*const fn (
        ctx: ?*anyopaque,
    ) anyerror!AgentCapacitySnapshot = null,
    ownsSessionFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
    ) anyerror!bool = null,
    eligibilityFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        parent_profile_id: []const u8,
        depth_remaining: usize,
    ) anyerror![]u8 = null,
    statusFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8,
    waitFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8,
    listFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8,
    convergeFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror!void,
    reconcileFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror!usize,
    waitParentFn: ?*const fn (
        ctx: ?*anyopaque,
        parent_session_id: []const u8,
        timeout_ms: usize,
    ) anyerror!AgentGroupSnapshot = null,
    cancelGroupFn: ?*const fn (
        ctx: ?*anyopaque,
        group_id: []const u8,
        reason: []const u8,
    ) anyerror!usize = null,
    cancelParentFn: ?*const fn (
        ctx: ?*anyopaque,
        parent_session_id: []const u8,
        reason: []const u8,
    ) anyerror!usize = null,
    bindEventSinkFn: ?*const fn (
        ctx: ?*anyopaque,
        sink: AgentEventSink,
    ) void = null,
    notifySessionEventFn: ?*const fn (
        ctx: ?*anyopaque,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) anyerror!void = null,

    pub fn launch(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        prompt: []const u8,
        name: ?[]const u8,
        scope: DelegationScope,
    ) anyerror![]u8 {
        return self.launchFn(self.context, allocator, parent_session_id, prompt, name, scope);
    }

    pub fn launchBatch(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        shared_context: []const u8,
        tasks: []const AgentTaskRequest,
        scope: DelegationScope,
    ) anyerror![]u8 {
        if (self.launchBatchFn) |launch_batch| {
            return launch_batch(self.context, allocator, parent_session_id, shared_context, tasks, scope);
        }
        if (tasks.len != 1) return Error.AgentServiceUnavailable;
        return self.launch(allocator, parent_session_id, tasks[0].task, tasks[0].name, scope);
    }

    pub fn launchTicket(
        self: AgentService,
        allocator: std.mem.Allocator,
        request: TicketTaskRequest,
    ) anyerror!TicketLaunchReceipt {
        const launch_ticket = self.launchTicketFn orelse return Error.AgentServiceUnavailable;
        return launch_ticket(self.context, allocator, request);
    }

    pub fn resumeTicket(
        self: AgentService,
        allocator: std.mem.Allocator,
        request: ResumeTicketRequest,
    ) anyerror!TicketLaunchReceipt {
        const resume_ticket = self.resumeTicketFn orelse return Error.AgentServiceUnavailable;
        return resume_ticket(self.context, allocator, request);
    }

    pub fn capacity(self: AgentService) anyerror!AgentCapacitySnapshot {
        const read_capacity = self.capacityFn orelse return Error.AgentServiceUnavailable;
        return read_capacity(self.context);
    }

    /// Return live fixed-pool ownership. Missing capability is false so a
    /// scheduler can never manufacture a heartbeat from absent evidence.
    pub fn ownsSession(self: AgentService, session_id: []const u8) anyerror!bool {
        const owns_session = self.ownsSessionFn orelse return false;
        return owns_session(self.context, session_id);
    }

    pub fn eligibility(
        self: AgentService,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        parent_profile_id: []const u8,
        depth_remaining: usize,
    ) anyerror![]u8 {
        const read_eligibility = self.eligibilityFn orelse return Error.AgentServiceUnavailable;
        return read_eligibility(self.context, allocator, session_id, parent_profile_id, depth_remaining);
    }

    pub fn status(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
    ) anyerror![]u8 {
        return self.statusFn(self.context, allocator, parent_session_id, agent_name);
    }

    pub fn wait(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
        agent_name: []const u8,
        timeout_ms: usize,
    ) anyerror![]u8 {
        return self.waitFn(self.context, allocator, parent_session_id, agent_name, timeout_ms);
    }

    pub fn list(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror![]u8 {
        return self.listFn(self.context, allocator, parent_session_id);
    }

    /// Reconcile completed child evidence and mark its shard checkpoint
    /// converged. Child summaries remain mailbox/context inputs; convergence
    /// never writes a synthetic assistant transcript message into the parent.
    pub fn converge(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror!void {
        return self.convergeFn(self.context, allocator, parent_session_id);
    }

    /// Reconcile orphaned open shard branches at cold start. Marks any open
    /// shard whose owning child process is dead as `abandoned`. Returns the
    /// count of shards marked abandoned. (roadmap P0-4b)
    pub fn reconcile(
        self: AgentService,
        allocator: std.mem.Allocator,
        parent_session_id: []const u8,
    ) anyerror!usize {
        return self.reconcileFn(self.context, allocator, parent_session_id);
    }

    pub fn waitParent(self: AgentService, parent_session_id: []const u8, timeout_ms: usize) anyerror!AgentGroupSnapshot {
        const wait_parent = self.waitParentFn orelse return Error.AgentServiceUnavailable;
        return wait_parent(self.context, parent_session_id, timeout_ms);
    }

    pub fn cancelGroup(self: AgentService, group_id: []const u8, reason: []const u8) anyerror!usize {
        const cancel_group = self.cancelGroupFn orelse return Error.AgentServiceUnavailable;
        return cancel_group(self.context, group_id, reason);
    }

    pub fn cancelParent(self: AgentService, parent_session_id: []const u8, reason: []const u8) anyerror!usize {
        const cancel_parent = self.cancelParentFn orelse return Error.AgentServiceUnavailable;
        return cancel_parent(self.context, parent_session_id, reason);
    }

    pub fn bindEventSink(self: AgentService, sink: AgentEventSink) void {
        if (self.bindEventSinkFn) |bind| bind(self.context, sink);
    }

    pub fn notifySessionEvent(
        self: AgentService,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        timestamp_ms: i64,
    ) !void {
        if (self.notifySessionEventFn) |notify| {
            try notify(self.context, session_id, seq, event_type, message, timestamp_ms);
        }
    }
};

pub const ToolEventSink = struct {
    context: ?*anyopaque = null,
    onOutputDeltaFn: ?*const fn (
        ctx: ?*anyopaque,
        tool_call_id: []const u8,
        tool_name: []const u8,
        stream: CommandOutputStream,
        chunk: []const u8,
        cap_reached: bool,
    ) anyerror!void = null,

    pub fn onOutputDelta(
        self: ToolEventSink,
        tool_call_id: []const u8,
        tool_name: []const u8,
        stream: CommandOutputStream,
        chunk: []const u8,
        cap_reached: bool,
    ) !void {
        if (chunk.len == 0 and !cap_reached) return;
        if (self.onOutputDeltaFn) |callback| {
            try callback(self.context, tool_call_id, tool_name, stream, chunk, cap_reached);
        }
    }
};

pub const ExecutionContext = struct {
    workspace_root: []const u8,
    /// When true, agent-facing path resolution may target explicit paths
    /// outside workspace_root. The default remains restricted.
    full_access_mode: bool = false,
    /// The session this tool call belongs to. Set by the executor loop;
    /// used by session-scoped tools (update_session_summary) to write into
    /// their own summary ledger row.
    session_id: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    agent_service: ?AgentService = null,
    input_service: InputService = .{},
    command_probe: ?CommandProbe = null,
    tool_events: ?ToolEventSink = null,
    file_inspection_ledger: ?*FileInspectionLedger = null,
    agent_eligibility_ledger: ?*AgentEligibilityLedger = null,
    orchestrator_only: bool = false,
    workspace_state_enabled: bool = false,
    capability_profile_id: ?[]const u8 = null,
    delegation_depth_remaining: usize = std.math.maxInt(usize),
    memory_policy: @import("../../shared/types.zig").MemoryPolicy = .{},
    /// Prompt-facing operator detail posture. The TUI owns projection
    /// filtering; this field keeps root and child prompts on one policy.
    log_level: @import("../../shared/types.zig").LogLevel = .silent,
};

pub const AgentEligibilityLedger = struct {
    current: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    park_after_launch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn markCurrent(self: *AgentEligibilityLedger) void {
        self.current.store(true, .release);
    }

    pub fn invalidate(self: *AgentEligibilityLedger) void {
        self.current.store(false, .release);
    }

    pub fn hasCurrent(self: *const AgentEligibilityLedger) bool {
        return self.current.load(.acquire);
    }

    pub fn noteLaunch(self: *AgentEligibilityLedger, background: bool) void {
        if (!background) self.park_after_launch.store(true, .release);
    }

    pub fn consumeParkRequest(self: *AgentEligibilityLedger) bool {
        return self.park_after_launch.swap(false, .acq_rel);
    }
};

pub const FileInspectionState = enum {
    exists,
    missing,
};

pub const FileInspectionMark = struct {
    resolved_path: []u8,
    state: FileInspectionState,

    fn deinit(self: FileInspectionMark, allocator: std.mem.Allocator) void {
        allocator.free(self.resolved_path);
    }
};

pub const FileInspectionLedger = struct {
    marks: std.array_list.Managed(FileInspectionMark),

    pub fn init(allocator: std.mem.Allocator) FileInspectionLedger {
        return .{ .marks = std.array_list.Managed(FileInspectionMark).init(allocator) };
    }

    pub fn deinit(self: *FileInspectionLedger) void {
        for (self.marks.items) |mark| mark.deinit(self.marks.allocator);
        self.marks.deinit();
    }

    pub fn record(self: *FileInspectionLedger, allocator: std.mem.Allocator, resolved_path: []const u8, exists: bool) !void {
        const next_state: FileInspectionState = if (exists) .exists else .missing;
        for (self.marks.items) |*mark| {
            if (std.mem.eql(u8, mark.resolved_path, resolved_path)) {
                mark.state = next_state;
                return;
            }
        }

        try self.marks.append(.{
            .resolved_path = try allocator.dupe(u8, resolved_path),
            .state = next_state,
        });
    }

    pub fn has(self: *const FileInspectionLedger, resolved_path: []const u8, exists: bool) bool {
        const required_state: FileInspectionState = if (exists) .exists else .missing;
        for (self.marks.items) |mark| {
            if (mark.state == required_state and std.mem.eql(u8, mark.resolved_path, resolved_path)) return true;
        }
        return false;
    }
};

pub fn recordFileInspection(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    resolved_path: []const u8,
    exists: bool,
) !void {
    if (execution_context.file_inspection_ledger) |ledger| {
        try ledger.record(allocator, resolved_path, exists);
    }
}

pub fn requireFileInspection(
    execution_context: ExecutionContext,
    resolved_path: []const u8,
    exists: bool,
) Error!void {
    if (execution_context.file_inspection_ledger) |ledger| {
        if (!ledger.has(resolved_path, exists)) return Error.FileNotInspected;
    }
}

pub fn okEnvelope(allocator: std.mem.Allocator, tool_name: []const u8, content: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":{f},\"content\":{f}}}",
        .{
            std.json.fmt(tool_name, .{}),
            std.json.fmt(content, .{}),
        },
    );
}

pub const FileSnapshot = struct {
    exists: bool,
    len: usize,
    sha256_hex: ?[]u8 = null,

    pub fn deinit(self: FileSnapshot, allocator: std.mem.Allocator) void {
        if (self.sha256_hex) |hash| allocator.free(hash);
    }
};

pub const FileEffectAction = enum {
    write_file,
    append_file,
    replace_in_file,
};

pub const FileEffectMetricName = enum {
    bytes_written,
    bytes_appended,
    replacements,
};

pub const FileEffectMetric = struct {
    name: FileEffectMetricName,
    value: usize,
};

const file_effect_schema_version = "var1.tool_effect.v1";

pub fn captureFileSnapshot(allocator: std.mem.Allocator, path: []const u8) !FileSnapshot {
    const contents = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .exists = false, .len = 0 },
        else => return err,
    };
    defer allocator.free(contents);

    return fileSnapshotFromContents(allocator, true, contents);
}

pub fn fileSnapshotFromContents(
    allocator: std.mem.Allocator,
    exists: bool,
    contents: []const u8,
) !FileSnapshot {
    if (!exists) return .{ .exists = false, .len = 0 };

    return .{
        .exists = exists,
        .len = contents.len,
        .sha256_hex = try sha256HexAlloc(allocator, contents),
    };
}

pub fn fileSnapshotFromParts(
    allocator: std.mem.Allocator,
    exists: bool,
    len: usize,
    parts: []const []const u8,
) !FileSnapshot {
    if (!exists) return .{ .exists = false, .len = 0 };

    return .{
        .exists = exists,
        .len = len,
        .sha256_hex = try sha256HexPartsAlloc(allocator, parts),
    };
}

pub fn fileEffectEnvelope(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    content: []const u8,
    action: FileEffectAction,
    requested_path: []const u8,
    resolved_path: []const u8,
    before: FileSnapshot,
    after: FileSnapshot,
    metric: FileEffectMetric,
) ![]u8 {
    const effect_content = try fileEffectContentAlloc(
        allocator,
        content,
        action,
        requested_path,
        resolved_path,
        before,
        after,
        metric,
    );
    defer allocator.free(effect_content);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.writeAll("{\"ok\":true,\"tool\":");
    try writer.print("{f}", .{std.json.fmt(tool_name, .{})});
    try writer.writeAll(",\"content\":");
    try writer.print("{f}", .{std.json.fmt(effect_content, .{})});
    try writer.writeAll(",\"effect\":{\"schema_version\":");
    try writer.print("{f}", .{std.json.fmt(file_effect_schema_version, .{})});
    try writer.writeAll(",\"action\":");
    try writer.print("{f}", .{std.json.fmt(fileEffectActionLabel(action), .{})});
    try writer.writeAll(",\"path\":");
    try writer.print("{f}", .{std.json.fmt(requested_path, .{})});
    try writer.writeAll(",\"resolved_path\":");
    try writer.print("{f}", .{std.json.fmt(resolved_path, .{})});
    try writer.writeAll(",\"before_exists\":");
    try writer.writeAll(if (before.exists) "true" else "false");
    try writer.print(",\"before_bytes\":{d},\"after_bytes\":{d},", .{ before.len, after.len });
    try writer.print("\"{s}\":{d},", .{ fileEffectMetricLabel(metric.name), metric.value });
    try writer.writeAll("\"before_sha256\":");
    try writeOptionalHash(writer, before.sha256_hex);
    try writer.writeAll(",\"after_sha256\":");
    try writeOptionalHash(writer, after.sha256_hex);
    try writer.writeAll("}}");

    return output.toOwnedSlice();
}

fn fileEffectContentAlloc(
    allocator: std.mem.Allocator,
    display_content: []const u8,
    action: FileEffectAction,
    requested_path: []const u8,
    resolved_path: []const u8,
    before: FileSnapshot,
    after: FileSnapshot,
    metric: FileEffectMetric,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const writer = output.writer();
    try writer.print(
        "EFFECT_SCHEMA {s}\nEFFECT_KEY effect\nEFFECT_ACTION {s}\nEFFECT_PATH {s}\nEFFECT_RESOLVED_PATH {s}\nEFFECT_BEFORE_EXISTS {s}\nEFFECT_BEFORE_BYTES {d}\nEFFECT_AFTER_BYTES {d}\n{s} {d}\n",
        .{
            file_effect_schema_version,
            fileEffectActionLabel(action),
            requested_path,
            resolved_path,
            if (before.exists) "true" else "false",
            before.len,
            after.len,
            fileEffectMetricContentLabel(metric.name),
            metric.value,
        },
    );
    try writeEffectContentHash(writer, "EFFECT_BEFORE_SHA256", before.sha256_hex);
    try writeEffectContentHash(writer, "EFFECT_AFTER_SHA256", after.sha256_hex);
    try writer.writeAll("DISPLAY_OUTPUT\n");
    try writer.writeAll(display_content);

    return output.toOwnedSlice();
}

fn sha256HexAlloc(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    return sha256HexPartsAlloc(allocator, &.{contents});
}

fn sha256HexPartsAlloc(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        hasher.update(part);
    }
    hasher.final(&digest);

    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, digest.len * 2);
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[index * 2 + 1] = hex_chars[@as(usize, byte & 0x0f)];
    }
    return hex;
}

fn fileEffectActionLabel(action: FileEffectAction) []const u8 {
    return switch (action) {
        .write_file => "write_file",
        .append_file => "append_file",
        .replace_in_file => "replace_in_file",
    };
}

fn fileEffectMetricLabel(metric: FileEffectMetricName) []const u8 {
    return switch (metric) {
        .bytes_written => "bytes_written",
        .bytes_appended => "bytes_appended",
        .replacements => "replacements",
    };
}

fn fileEffectMetricContentLabel(metric: FileEffectMetricName) []const u8 {
    return switch (metric) {
        .bytes_written => "EFFECT_BYTES_WRITTEN",
        .bytes_appended => "EFFECT_BYTES_APPENDED",
        .replacements => "EFFECT_REPLACEMENTS",
    };
}

fn writeOptionalHash(writer: anytype, value: ?[]const u8) !void {
    if (value) |hash| {
        try writer.print("{f}", .{std.json.fmt(hash, .{})});
    } else {
        try writer.writeAll("null");
    }
}

fn writeEffectContentHash(writer: anytype, label: []const u8, value: ?[]const u8) !void {
    try writer.print("{s} ", .{label});
    if (value) |hash| {
        try writer.print("{s}\n", .{hash});
    } else {
        try writer.writeAll("null\n");
    }
}

pub fn renderLineRange(
    allocator: std.mem.Allocator,
    content: []const u8,
    start_line: ?usize,
    end_line: ?usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    const start = start_line orelse 1;
    const finish = end_line orelse std.math.maxInt(usize);

    var line_number: usize = 1;
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| : (line_number += 1) {
        if (line_number < start or line_number > finish) continue;
        try output.writer().print("{d}: {s}\n", .{ line_number, line });
    }

    return output.toOwnedSlice();
}

pub fn replaceText(
    allocator: std.mem.Allocator,
    input: []const u8,
    old_text: []const u8,
    new_text: []const u8,
    replace_all: bool,
) !struct { contents: []u8, replacements: usize } {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    var replacements: usize = 0;

    while (std.mem.indexOfPos(u8, input, cursor, old_text)) |match_index| {
        try output.writer().writeAll(input[cursor..match_index]);
        try output.writer().writeAll(new_text);
        cursor = match_index + old_text.len;
        replacements += 1;

        if (!replace_all) break;
    }

    try output.writer().writeAll(input[cursor..]);

    return .{
        .contents = try output.toOwnedSlice(),
        .replacements = replacements,
    };
}

pub fn collectFiles(
    allocator: std.mem.Allocator,
    search_path: []const u8,
    search_prefix: []const u8,
    max_results: usize,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var dir = std.fs.openDirAbsolute(search_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const single_path = try normalizeToolPath(
                allocator,
                if (std.mem.eql(u8, search_prefix, ".")) std.fs.path.basename(search_path) else search_prefix,
            );
            defer allocator.free(single_path);

            try output.writer().print("{s}\n", .{single_path});
            return output.toOwnedSlice();
        },
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var line_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (line_count >= max_results) break;

        const display_path = if (std.mem.eql(u8, search_prefix, "."))
            try allocator.dupe(u8, entry.path)
        else
            try fsutil.join(allocator, &.{ search_prefix, entry.path });
        defer allocator.free(display_path);

        const normalized_path = try normalizeToolPath(allocator, display_path);
        defer allocator.free(normalized_path);

        try output.writer().print("{s}\n", .{normalized_path});
        line_count += 1;
    }

    return output.toOwnedSlice();
}

fn normalizeToolPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep == '/') return normalized;

    for (normalized) |*byte| {
        if (byte.* == std.fs.path.sep) byte.* = '/';
    }

    return normalized;
}

test "file effect envelope exposes effect-first content and structured metadata" {
    const allocator = std.testing.allocator;

    const envelope = try fileEffectEnvelope(
        allocator,
        "write_file",
        "PATH resolved.txt\nBYTES 5",
        .write_file,
        "requested.txt",
        "resolved.txt",
        .{ .exists = false, .len = 0 },
        .{ .exists = true, .len = 5 },
        .{ .name = .bytes_written, .value = 5 },
    );
    defer allocator.free(envelope);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, envelope, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const content_value = root.get("content") orelse return error.MissingContent;
    try std.testing.expect(content_value == .string);
    const content = content_value.string;

    try std.testing.expect(std.mem.startsWith(u8, content, "EFFECT_SCHEMA var1.tool_effect.v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, content, "EFFECT_KEY effect\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "EFFECT_ACTION write_file\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "EFFECT_BYTES_WRITTEN 5\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "DISPLAY_OUTPUT\nPATH resolved.txt\nBYTES 5") != null);

    const effect_value = root.get("effect") orelse return error.MissingEffect;
    try std.testing.expect(effect_value == .object);
    const effect = effect_value.object;
    try std.testing.expectEqualStrings(file_effect_schema_version, effect.get("schema_version").?.string);
    try std.testing.expectEqualStrings("write_file", effect.get("action").?.string);
    try std.testing.expectEqual(@as(i64, 5), effect.get("bytes_written").?.integer);
}

fn testTicketLaunchCallback(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: TicketTaskRequest,
) anyerror!TicketLaunchReceipt {
    return .{
        .ticket_id = try allocator.dupe(u8, request.ticket_id),
        .group_id = try allocator.dupe(u8, "group-test"),
        .task_id = try allocator.dupe(u8, "task-test"),
        .session_id = try allocator.dupe(u8, "session-test"),
        .agent_id = try allocator.dupe(u8, request.agent_hint),
        .route_role = try allocator.dupe(u8, "implementer"),
        .capability_profile_id = try allocator.dupe(u8, "profile-test"),
        .capability_hash = try allocator.dupe(u8, "hash-test"),
        .model = try allocator.dupe(u8, "model-test"),
    };
}

fn testCapacityCallback(_: ?*anyopaque) anyerror!AgentCapacitySnapshot {
    return AgentCapacitySnapshot.fromCounts(4, 1, 2);
}

test "agent service exposes typed ticket launch and capacity callbacks" {
    var service = AgentService{
        .context = null,
        .launchFn = undefined,
        .statusFn = undefined,
        .waitFn = undefined,
        .listFn = undefined,
        .convergeFn = undefined,
        .reconcileFn = undefined,
        .launchTicketFn = testTicketLaunchCallback,
        .capacityFn = testCapacityCallback,
    };

    const snapshot = try service.capacity();
    try std.testing.expectEqual(@as(usize, 4), snapshot.max);
    try std.testing.expectEqual(@as(usize, 1), snapshot.queued);
    try std.testing.expectEqual(@as(usize, 2), snapshot.running);
    try std.testing.expectEqual(@as(usize, 2), snapshot.idle);
    try std.testing.expectEqual(@as(usize, 1), snapshot.available);

    var receipt = try service.launchTicket(std.testing.allocator, .{
        .ticket_id = "ticket-test",
        .title = "Typed launch",
        .description = "Prove the callback boundary",
        .category = "architecture",
        .expected_revision = 7,
        .worker_id = "scheduler-test",
        .worker_generation = 1,
        .lease_token = "lease-test",
        .lease_expires_at_ms = 123,
        .attempt = 1,
        .agent_hint = "implementer",
        .idempotency_key = "launch-test",
    });
    defer receipt.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ticket-test", receipt.ticket_id);
    try std.testing.expectEqualStrings("group-test", receipt.group_id);
    try std.testing.expectEqualStrings("task-test", receipt.task_id);
    try std.testing.expectEqualStrings("session-test", receipt.session_id);
    try std.testing.expectEqualStrings("implementer", receipt.agent_id);
    try std.testing.expectEqualStrings("implementer", receipt.route_role);
    try std.testing.expectEqualStrings("profile-test", receipt.capability_profile_id);
    try std.testing.expectEqualStrings("hash-test", receipt.capability_hash);
    try std.testing.expectEqualStrings("model-test", receipt.model);
}
