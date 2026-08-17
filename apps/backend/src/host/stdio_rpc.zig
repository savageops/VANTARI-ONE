const std = @import("std");
const context_compactor = @import("../core/context/compactor.zig");
const config_file = @import("../core/config/file.zig");
const loop = @import("../core/executor/loop.zig");
const prompts = @import("../core/prompts/index.zig");
const protocol_events = @import("../shared/protocol/events.zig");
const input_protocol = @import("../shared/protocol/input.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const provider_profile = @import("../core/providers/profile.zig");
const models = @import("../core/providers/models.zig");
const scheduler = @import("../core/scheduler/index.zig");
const tickets = @import("../core/tickets/index.zig");
const buffer_service = @import("../core/executor/buffer.zig");
const store = @import("../core/sessions/store.zig");
const auth_store = @import("../core/auth/store.zig");
const auth_detect = @import("../core/auth/detect.zig");
const auth_import = @import("../core/auth/import.zig");
const agent_spec = @import("../core/agents/spec.zig");
const tools = @import("../core/tools/runtime.zig");
const eval_tool = @import("../core/tools/builtin/eval.zig");
const types = @import("../shared/types.zig");
const stdio_client = @import("stdio_client.zig");
const owner_client = @import("owner_client.zig");
const wire = @import("stdio_wire.zig");

pub const ChildClient = stdio_client.ChildClient;
pub const LocalClient = owner_client.LocalClient;
pub const Notification = stdio_client.Notification;
pub const RpcCallResult = stdio_client.RpcCallResult;

const errorResponseOrNull = wire.errorResponseOrNull;
const renderErrorResponse = wire.renderErrorResponse;
const renderJsonAlloc = wire.renderJsonAlloc;
const renderSuccessResponse = wire.renderSuccessResponse;

pub const Error = error{
    InvalidRequest,
    InvalidParams,
    MethodNotFound,
    ManualCompactionDisabled,
    SessionNotFound,
    ScheduleNotFound,
    SessionRunning,
    ProviderNotFound,
    ExecutionFailed,
    InvalidFrame,
    MissingChildPipes,
    InvalidRpcResponse,
    InputAlreadyPending,
    InputAlreadyResolved,
    InputNotFound,
    InputSessionMismatch,
    InputUnavailable,
    RpcRemoteError,
    ServerShuttingDown,
};

/// Stale-running reconciliation window. A session is considered stale when
/// its persisted status is `.running` but no in-process kernel owns it AND
/// no event has touched it for this duration. The previous 120s window was
/// too long — a crashed process left the session unresumable for 2 minutes.
/// 5s is enough to cover normal turn latency between events while ensuring
/// a crashed/restarted process can self-heal near-instantly.
const stale_running_session_ms: i64 = 30_000;

const SessionRuntimeState = struct {
    enable_agent_tools: bool = true,
    cancel_requested: bool = false,
    running: bool = false,
    active_run_seq: u64 = 0,
    pending_messages: std.ArrayListUnmanaged([]u8) = .{},
};

const SessionStartAdmission = enum {
    started,
    already_running,
};

const RuntimeCancelOutcome = enum {
    requested,
    not_running,
    run_not_observed,
    generation_required,
    stale_run,
};

const RuntimeCancelResult = struct {
    outcome: RuntimeCancelOutcome,
    active_run_seq: ?u64 = null,
};

const max_pending_messages = 5;
const max_request_workers = 4;
const max_admitted_requests = 32;
const rpc_server_busy_code: i32 = -32005;

const RequestAdmission = struct {
    mutex: std.Thread.Mutex = .{},
    accepting: bool = false,
    admitted: usize = 0,

    fn start(self: *RequestAdmission) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.accepting = true;
    }

    fn stop(self: *RequestAdmission) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.accepting = false;
    }

    fn tryAcquire(self: *RequestAdmission) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.accepting or self.admitted >= max_admitted_requests) return false;
        self.admitted += 1;
        return true;
    }

    fn release(self: *RequestAdmission) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.admitted > 0);
        self.admitted -= 1;
    }
};

const Runtime = struct {
    mutex: std.Thread.Mutex = .{},
    sessions: std.StringHashMapUnmanaged(SessionRuntimeState) = .{},
    shutting_down: bool = false,

    fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.pending_messages.items) |msg| allocator.free(msg);
            entry.value_ptr.pending_messages.deinit(allocator);
        }
        self.sessions.deinit(allocator);
    }

    fn ensureSession(
        self: *Runtime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        enable_agent_tools: ?bool,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (enable_agent_tools) |value| state.enable_agent_tools = value;
            return;
        }

        try self.sessions.put(allocator, try allocator.dupe(u8, session_id), .{
            .enable_agent_tools = enable_agent_tools orelse true,
        });
    }

    /// Atomically choose the one provider-turn owner for a session. A prompt
    /// that loses admission becomes a bounded interjection under the same lock,
    /// so it cannot fall between a stale running check and queue insertion.
    fn tryStartSession(
        self: *Runtime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        pending_message: ?[]const u8,
    ) !SessionStartAdmission {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.shutting_down) return Error.ServerShuttingDown;
        const state = self.sessions.getPtr(session_id) orelse return Error.SessionNotFound;
        if (state.running) {
            if (pending_message) |message| try appendPendingMessageLocked(state, allocator, message);
            return .already_running;
        }

        state.running = true;
        state.cancel_requested = false;
        state.active_run_seq = 0;
        return .started;
    }

    fn finishSession(self: *Runtime, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            state.running = false;
            state.cancel_requested = false;
            state.active_run_seq = 0;
        }
    }

    fn isRunning(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.running;
        return false;
    }

    /// Bind the durable session_started event sequence to the admitted run.
    /// Duplicate observation is idempotent; a second generation cannot replace
    /// the active owner before finishSession clears it.
    fn observeRunStart(self: *Runtime, session_id: []const u8, run_seq: u64) bool {
        if (run_seq == 0) return false;
        self.mutex.lock();
        defer self.mutex.unlock();

        const state = self.sessions.getPtr(session_id) orelse return false;
        if (!state.running) return false;
        if (state.active_run_seq != 0 and state.active_run_seq != run_seq) return false;
        state.active_run_seq = run_seq;
        return true;
    }

    fn requestCancel(self: *Runtime, session_id: []const u8, expected_run_seq: ?u64) RuntimeCancelResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (!state.running) return .{ .outcome = .not_running };
            if (state.active_run_seq == 0) return .{ .outcome = .run_not_observed };
            const active_run_seq = state.active_run_seq;
            const expected = expected_run_seq orelse return .{
                .outcome = .generation_required,
                .active_run_seq = active_run_seq,
            };
            if (expected != active_run_seq) return .{
                .outcome = .stale_run,
                .active_run_seq = active_run_seq,
            };
            state.cancel_requested = true;
            return .{
                .outcome = .requested,
                .active_run_seq = active_run_seq,
            };
        }

        return .{ .outcome = .not_running };
    }

    /// Fence new turns and signal every active owner in one runtime transition.
    /// Queued RPC jobs observe the fence in tryStartSession instead of starting
    /// after the shutdown cancellation sweep.
    fn beginShutdown(self: *Runtime) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.shutting_down = true;
        var cancelled: usize = 0;
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            if (!entry.value_ptr.running) continue;
            entry.value_ptr.cancel_requested = true;
            cancelled += 1;
        }
        return cancelled;
    }

    fn shouldCancel(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.cancel_requested;
        return false;
    }

    /// Drain all pending messages for a session. Returns an owned slice of owned
    /// strings. The caller must free each string and the slice itself.
    fn drainPendingMessages(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8) ?[][]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (state.pending_messages.items.len == 0) return null;
            const drained = state.pending_messages.toOwnedSlice(allocator) catch return null;
            return drained;
        }
        return null;
    }

    /// Non-destructive peek: check if a session has pending messages.
    fn hasPendingMessages(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            return state.pending_messages.items.len > 0;
        }
        return false;
    }

    fn enableAgentTools(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.enable_agent_tools;
        return true;
    }
};

fn appendPendingMessageLocked(state: *SessionRuntimeState, allocator: std.mem.Allocator, message: []const u8) !void {
    const owned = try allocator.dupe(u8, message);
    errdefer allocator.free(owned);
    try state.pending_messages.ensureUnusedCapacity(allocator, 1);
    if (state.pending_messages.items.len >= max_pending_messages) {
        const oldest = state.pending_messages.orderedRemove(0);
        allocator.free(oldest);
    }
    state.pending_messages.appendAssumeCapacity(owned);
}

const BufferProjection = struct {
    mutex: std.Thread.Mutex = .{},
    session_id: ?[]u8 = null,
    preview: ?[]u8 = null,

    fn deinit(self: *BufferProjection, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.preview) |value| allocator.free(value);
        self.* = .{};
    }

    fn activate(self: *BufferProjection, allocator: std.mem.Allocator, session_id: []const u8) !void {
        const owned = try allocator.dupe(u8, session_id);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.session_id) |value| allocator.free(value);
        if (self.preview) |value| allocator.free(value);
        self.session_id = owned;
        self.preview = null;
    }

    fn store(self: *BufferProjection, allocator: std.mem.Allocator, session_id: []const u8, preview: []const u8) !bool {
        const owned = try allocator.dupe(u8, preview);
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = self.session_id orelse {
            allocator.free(owned);
            return false;
        };
        if (!std.mem.eql(u8, current, session_id)) {
            allocator.free(owned);
            return false;
        }
        if (self.preview) |value| allocator.free(value);
        self.preview = owned;
        return true;
    }

    fn copy(self: *BufferProjection, allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const current = self.session_id orelse return null;
        if (!std.mem.eql(u8, current, session_id)) return null;
        const preview = self.preview orelse return null;
        return allocator.dupe(u8, preview) catch null;
    }
};

const InputPending = struct {
    session_id: []u8,
    response_json: ?[]u8 = null,
    cancelled: bool = false,
    condition: std.Thread.Condition = .{},
};

/// One bounded wait point for the interactive root. The request itself is a
/// durable input_requested event; this broker is only the process-local wake
/// path that lets input/respond unblock the provider tool call without a
/// second session owner or status bus.
const InputBroker = struct {
    mutex: std.Thread.Mutex = .{},
    pending: std.StringHashMapUnmanaged(*InputPending) = .{},
    stopping: bool = false,

    fn pendingKey(allocator: std.mem.Allocator, session_id: []const u8, request_id: []const u8) ![]u8 {
        // Tool-call ids are only unique inside a provider turn. Prefixing the
        // session length keeps concurrent sessions from colliding without
        // introducing a second map or registry.
        return std.fmt.allocPrint(allocator, "{d}:{s}{s}", .{ session_id.len, session_id, request_id });
    }

    fn begin(
        self: *InputBroker,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        request_id: []const u8,
    ) !void {
        const owned_key = try pendingKey(allocator, session_id, request_id);
        errdefer allocator.free(owned_key);
        const pending = try allocator.create(InputPending);
        errdefer allocator.destroy(pending);
        pending.* = .{ .session_id = try allocator.dupe(u8, session_id) };
        errdefer allocator.free(pending.session_id);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) return Error.InputUnavailable;
        if (self.pending.contains(owned_key)) return Error.InputAlreadyPending;
        try self.pending.put(allocator, owned_key, pending);
    }

    fn wait(
        self: *InputBroker,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        request_id: []const u8,
    ) ![]u8 {
        const key = try pendingKey(allocator, session_id, request_id);
        defer allocator.free(key);
        self.mutex.lock();
        const pending = self.pending.get(key) orelse {
            self.mutex.unlock();
            return Error.InputNotFound;
        };
        while (pending.response_json == null and !pending.cancelled) {
            pending.condition.wait(&self.mutex);
        }

        const response = if (pending.response_json) |value| blk: {
            const owned = allocator.dupe(u8, value) catch |err| {
                self.mutex.unlock();
                return err;
            };
            break :blk owned;
        } else null;
        const removed = self.pending.fetchRemove(key) orelse unreachable;
        self.mutex.unlock();

        allocator.free(removed.key);
        if (pending.response_json) |value| allocator.free(value);
        allocator.free(pending.session_id);
        allocator.destroy(pending);
        if (response) |value| return value;
        return error.InputCancelled;
    }

    fn resolve(
        self: *InputBroker,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        request_id: []const u8,
        response_json: []const u8,
    ) !void {
        const key = try pendingKey(allocator, session_id, request_id);
        defer allocator.free(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping) return Error.InputUnavailable;
        const pending = self.pending.get(key) orelse return Error.InputNotFound;
        if (!std.mem.eql(u8, pending.session_id, session_id)) return Error.InputSessionMismatch;
        if (pending.cancelled or pending.response_json != null) return Error.InputAlreadyResolved;
        pending.response_json = try allocator.dupe(u8, response_json);
        pending.condition.broadcast();
    }

    fn cancel(self: *InputBroker, allocator: std.mem.Allocator, session_id: []const u8, request_id: []const u8) void {
        const key = pendingKey(allocator, session_id, request_id) catch return;
        defer allocator.free(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.pending.get(key)) |pending| {
            pending.cancelled = true;
            pending.condition.broadcast();
        }
    }

    fn cancelSession(self: *InputBroker, session_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            if (!std.mem.eql(u8, entry.value_ptr.*.session_id, session_id)) continue;
            entry.value_ptr.*.cancelled = true;
            entry.value_ptr.*.condition.broadcast();
        }
    }

    fn shutdown(self: *InputBroker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopping = true;
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.cancelled = true;
            entry.value_ptr.*.condition.broadcast();
        }
    }

    fn deinit(self: *InputBroker, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.response_json) |value| allocator.free(value);
            allocator.free(entry.value_ptr.*.session_id);
            allocator.destroy(entry.value_ptr.*);
        }
        self.pending.deinit(allocator);
        self.mutex.unlock();
    }
};

const Server = struct {
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
    stdout_file: std.fs.File,
    write_mutex: std.Thread.Mutex = .{},
    request_pool: std.Thread.Pool = undefined,
    request_pool_started: bool = false,
    request_admission: RequestAdmission = .{},
    runtime: Runtime = .{},
    input_broker: InputBroker = .{},
    scheduler_service: ?scheduler.Service = null,
    scheduler_thread: ?std.Thread = null,
    buffer_srv: ?buffer_service.Service = null,
    buffer_thread: ?std.Thread = null,
    /// One session-keyed projection prevents late buffer callbacks and
    /// concurrent root turns from crossing identity or preview ownership.
    buffer_projection: BufferProjection = .{},

    fn startRequestExecutor(self: *Server) !void {
        try self.request_pool.init(.{
            .allocator = std.heap.page_allocator,
            .n_jobs = max_request_workers,
        });
        self.request_pool_started = true;
        self.request_admission.start();
    }

    fn stopRequestExecutor(self: *Server) void {
        self.request_admission.stop();
        _ = self.runtime.beginShutdown();
        self.input_broker.shutdown();
        if (!self.request_pool_started) return;
        self.request_pool.deinit();
        self.request_pool_started = false;
        std.debug.assert(self.request_admission.admitted == 0);
    }

    fn submitRequest(self: *Server, request_payload: []u8) !bool {
        if (!self.request_admission.tryAcquire()) return false;
        errdefer self.request_admission.release();

        const job = try std.heap.page_allocator.create(RequestJob);
        errdefer std.heap.page_allocator.destroy(job);
        job.* = .{
            .server = self,
            .request_payload = request_payload,
        };
        try self.request_pool.spawn(processRequestWorker, .{job});
        return true;
    }

    fn deinit(self: *Server) void {
        self.stopRequestExecutor();
        self.agent_service.bindEventSink(.{});
        if (self.scheduler_service) |*service| {
            service.requestStop();
            if (self.scheduler_thread) |thread| thread.join();
            service.deinit();
        }
        if (self.buffer_srv) |*bsrv| {
            bsrv.requestStop();
            if (self.buffer_thread) |thread| thread.join();
            bsrv.deinit();
        }
        // Request workers and services are joined above. Only then may the
        // process-local session-owned workers be terminated.
        eval_tool.deinitAll();
        tools.dap_tool.deinitAll();
        self.buffer_projection.deinit(self.allocator);
        self.runtime.deinit(self.allocator);
        self.input_broker.deinit(self.allocator);
    }

    fn emitSessionEvent(
        self: *Server,
        session_id: []const u8,
        seq: u64,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        const params_json = try renderJsonAlloc(self.allocator, protocol_types.SessionEventNotification{
            .session_id = session_id,
            .seq = seq,
            .event_type = event_type,
            .message = message,
            .status = status,
            .timestamp_ms = timestamp_ms,
        });
        defer self.allocator.free(params_json);

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ protocol_types.notification_methods.session_event, params_json },
        );
        defer self.allocator.free(payload);

        try self.writePayload(payload);
    }

    fn recordAndEmitSessionEvent(
        self: *Server,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        const seq = try store.appendEventWithSeq(self.allocator, self.config.workspace_root, session_id, .{
            .event_type = event_type,
            .message = message,
            .timestamp_ms = timestamp_ms,
        });
        try store.touchSessionUpdatedAt(self.allocator, self.config.workspace_root, session_id, timestamp_ms);
        try self.emitSessionEvent(session_id, seq, event_type, message, status, timestamp_ms);
    }

    fn writePayload(self: *Server, payload: []const u8) !void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        try wire.writeFrame(self.stdout_file, payload);
    }
};

const RequestJob = struct {
    server: *Server,
    request_payload: []u8,
};

pub fn serveKernel(
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
) !void {
    var server = Server{
        .allocator = allocator,
        .config = config,
        .transport = transport,
        .agent_service = agent_service,
        .stdout_file = std.fs.File.stdout(),
    };
    defer server.deinit();
    server.agent_service.bindEventSink(.{
        .context = &server,
        .notifyFn = onAgentParentEvent,
    });
    try server.startRequestExecutor();
    server.scheduler_service = try scheduler.Service.initWithAgentService(allocator, config, transport, agent_service);
    server.scheduler_thread = try std.Thread.spawn(.{}, runSchedulerService, .{&server.scheduler_service.?});

    // Buffer speculation service (background thread, concurrent with heavyweight).
    // Only spawned if buffer is enabled in config; preview callback emits a
    // buffer_preview session event to the TUI.
    {
        const buf_policy = buffer_service.loadBufferPolicy(allocator, config.workspace_root);
        defer buf_policy.deinit(allocator);
        if (buf_policy.enabled) {
            server.buffer_srv = buffer_service.Service.init(allocator, config.*, transport, .{
                .context = &server,
                .onPreviewFn = onBufferPreview,
            });
            server.buffer_thread = try std.Thread.spawn(.{}, runBufferService, .{&server.buffer_srv.?});
        }
    }

    const stdin_file = std.fs.File.stdin();
    var frame_reader = wire.FrameReader.init(allocator);
    defer frame_reader.deinit();
    while (true) {
        const request_payload = try frame_reader.readFrame(stdin_file) orelse break;

        if (!try server.submitRequest(request_payload)) {
            defer allocator.free(request_payload);
            const response = try renderBusyResponse(allocator, request_payload);
            if (response) |payload| {
                defer allocator.free(payload);
                try server.writePayload(payload);
            }
        }
    }
}

/// Project already-persisted child-group events onto the live stdio notification lane.
fn onAgentParentEvent(
    ctx: ?*anyopaque,
    parent_session_id: []const u8,
    seq: u64,
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    // Live notification is a read model over the durable event spine
    // (AGENTS.md §IV). A slow/broken TUI pipe must never corrupt a child
    // agent delegation turn.
    server.emitSessionEvent(parent_session_id, seq, event_type, message, "running", timestamp_ms) catch {};
}

fn runSchedulerService(service: *scheduler.Service) void {
    service.run();
}

/// Buffer preview callback — stores the latest preview for executor injection
/// and emits a buffer_preview session event to the TUI.
fn onBufferPreview(ctx: ?*anyopaque, session_id: []const u8, preview: []const u8) void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    if (!(server.buffer_projection.store(server.allocator, session_id, preview) catch false)) return;
    server.recordAndEmitSessionEvent(session_id, "buffer_preview", preview, "running", std.time.milliTimestamp()) catch {};
}

fn runBufferService(service: *buffer_service.Service) void {
    service.run();
}

fn processRequestWorker(job: *RequestJob) void {
    defer std.heap.page_allocator.destroy(job);
    defer job.server.allocator.free(job.request_payload);
    defer job.server.request_admission.release();

    const response_payload = processRequest(job.server, job.request_payload) catch return;
    if (response_payload) |payload| {
        defer job.server.allocator.free(payload);
        job.server.writePayload(payload) catch {};
    }
}

fn renderBusyResponse(allocator: std.mem.Allocator, request_payload: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_payload, .{}) catch {
        return try renderErrorResponse(allocator, null, rpc_server_busy_code, "Server request capacity exhausted");
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try renderErrorResponse(allocator, null, rpc_server_busy_code, "Server request capacity exhausted");
    }
    const id = extractRequestId(parsed.value.object) catch null;
    return errorResponseOrNull(allocator, id, rpc_server_busy_code, "Server request capacity exhausted");
}

fn processRequest(server: *Server, request_payload: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, server.allocator, request_payload, .{}) catch {
        const response = try renderErrorResponse(server.allocator, null, -32700, "Parse error");
        return response;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        const response = try renderErrorResponse(server.allocator, null, -32600, "Invalid Request");
        return response;
    }

    const object = parsed.value.object;
    const id = extractRequestId(object) catch {
        const response = try renderErrorResponse(server.allocator, null, -32600, "Invalid Request");
        return response;
    };

    const jsonrpc_value = object.get("jsonrpc") orelse {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    };
    if (jsonrpc_value != .string or !std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    }

    const method_value = object.get("method") orelse {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    };
    if (method_value != .string) {
        const response = try renderErrorResponse(server.allocator, id, -32600, "Invalid Request");
        return response;
    }

    const result_payload = dispatch(server, method_value.string, object.get("params")) catch |err| switch (err) {
        Error.MethodNotFound => return errorResponseOrNull(server.allocator, id, -32601, "Method not found"),
        Error.InvalidParams => return errorResponseOrNull(server.allocator, id, -32602, "Invalid params"),
        Error.ManualCompactionDisabled => return errorResponseOrNull(server.allocator, id, -32003, "Manual compaction disabled"),
        Error.SessionNotFound => return errorResponseOrNull(server.allocator, id, -32001, "Session not found"),
        Error.ScheduleNotFound => return errorResponseOrNull(server.allocator, id, -32004, "Schedule not found"),
        Error.SessionRunning => return errorResponseOrNull(server.allocator, id, -32002, "Session already running"),
        Error.InputNotFound, Error.InputSessionMismatch, Error.InputAlreadyResolved, Error.InputAlreadyPending, Error.InputUnavailable => return errorResponseOrNull(server.allocator, id, -32602, "Input request is no longer available"),
        Error.ProviderNotFound => return errorResponseOrNull(server.allocator, id, -32006, "Provider not found"),
        Error.ServerShuttingDown => return errorResponseOrNull(server.allocator, id, rpc_server_busy_code, "Server shutting down"),
        Error.ExecutionFailed => return errorResponseOrNull(server.allocator, id, -32000, "Execution failed"),
        else => return errorResponseOrNull(server.allocator, id, -32603, "Internal error"),
    };
    defer server.allocator.free(result_payload);

    if (id == null) return null;
    const response = try renderSuccessResponse(server.allocator, id.?, result_payload);
    return response;
}

fn dispatch(
    server: *Server,
    method_name: []const u8,
    params: ?std.json.Value,
) ![]u8 {
    if (std.mem.eql(u8, method_name, protocol_types.methods.initialize)) {
        return handleInitialize(server.allocator);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_create)) {
        return handleSessionCreate(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_resume)) {
        return handleSessionResume(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_send)) {
        return handleSessionSend(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_compact)) {
        return handleSessionCompact(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_cancel)) {
        return handleSessionCancel(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.input_respond)) {
        return handleInputRespond(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_get)) {
        return handleSessionGet(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_list)) {
        return handleSessionList(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.schedule_get)) {
        return handleScheduleGet(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.schedule_list)) {
        return handleScheduleList(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.tools_list)) {
        return handleToolsList(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.events_subscribe)) {
        return handleEventsSubscribe(server.allocator);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.health_get)) {
        return handleHealthGet(server);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.providers_list)) {
        return handleProvidersList(server);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.models_list)) {
        return handleModelsList(server, params);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.config_set)) {
        return handleConfigSet(server, params);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.provider_model_set)) {
        return handleProviderModelSet(server, params);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.auth_detect)) {
        return handleAuthDetect(server);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.auth_import)) {
        return handleAuthImport(server, params);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.agents_list)) {
        return handleAgentsList(server);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.agents_configure)) {
        return handleAgentsConfigure(server, params);
    }

    return Error.MethodNotFound;
}

fn handleInitialize(allocator: std.mem.Allocator) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.InitializeResult{
        .server_version = "VAR1-kernel-stdio-v2",
        .capabilities = .{},
    });
}

fn handleSessionCreate(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        prompt: []const u8,
        parent_session_id: ?[]const u8 = null,
        continued_from_session_id: ?[]const u8 = null,
        display_name: ?[]const u8 = null,
        agent_profile: ?[]const u8 = null,
        enable_agent_tools: ?bool = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.prompt, " \t\r\n");
    if (prompt.len == 0) return Error.InvalidParams;

    var session = try store.initSessionWithOptions(server.allocator, server.config.workspace_root, prompt, .{
        .status = .initialized,
        .parent_session_id = parsed.value.parent_session_id,
        .continued_from_session_id = parsed.value.continued_from_session_id,
        .display_name = parsed.value.display_name,
        .agent_profile = parsed.value.agent_profile,
        .full_access_mode = server.config.full_access_mode,
    });
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);

    return renderJsonAlloc(server.allocator, protocol_types.SessionCreateResult{
        .session = makeSessionSummary(session, null),
    });
}

fn handleSessionResume(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
        enable_agent_tools: ?bool = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);
    try reconcileStaleRunningSession(server, &session);

    const output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
    defer if (output) |value| server.allocator.free(value);

    return renderJsonAlloc(server.allocator, protocol_types.SessionResumeResult{
        .session = makeSessionSummary(session, output),
    });
}

fn handleSessionSend(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
        prompt: ?[]const u8 = null,
        enable_agent_tools: ?bool = null,
        model_override: ?[]const u8 = null,
        provider_id: ?[]const u8 = null,
        prompt_mode: ?[]const u8 = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    const prompt_mode = if (parsed.value.prompt_mode) |label|
        prompts.PromptMode.fromString(label) orelse return Error.InvalidParams
    else
        prompts.PromptMode.orchestrate;
    var prompt_mode_override = config_file.loadPromptModeOverride(
        server.allocator,
        server.config.workspace_root,
        prompt_mode.label(),
    ) catch return Error.InvalidParams;
    defer prompt_mode_override.deinit(server.allocator);

    // Extract optional u64 overrides manually — std.json's optional-u64
    // static parser overflows at comptime (f64 cannot represent maxInt(u64)).
    const context_window_override: ?u64 = if (params) |v| blk: {
        if (v != .object) break :blk null;
        break :blk optionalU64FromObject(&v.object, "context_window_override") catch return Error.InvalidParams;
    } else null;
    const max_output_tokens: ?u64 = if (params) |v| blk: {
        if (v != .object) break :blk null;
        break :blk optionalU64FromObject(&v.object, "max_output_tokens") catch return Error.InvalidParams;
    } else null;

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, parsed.value.enable_agent_tools);
    try reconcileStaleRunningSession(server, &session);

    // Cold-start shard reconciliation: mark any orphaned open shard branches
    // (whose owning child process died) as `abandoned`. This ensures a
    // crashed parent never leaves phantom open branches in the shard ledger.
    // (roadmap P0-4b)
    _ = server.agent_service.reconcile(server.allocator, session.id) catch 0;

    const next_prompt: ?[]const u8 = if (parsed.value.prompt) |next_prompt_raw| blk: {
        const next_prompt = std.mem.trim(u8, next_prompt_raw, " \t\r\n");
        if (next_prompt.len == 0) return Error.InvalidParams;
        break :blk next_prompt;
    } else null;

    if (next_prompt == null and (session.status == .completed or session.status == .failed or session.status == .cancelled)) {
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    const admission = try server.runtime.tryStartSession(server.allocator, session.id, next_prompt);
    if (admission == .already_running) {
        // Interjection protocol: queue the message for mid-turn injection
        // instead of rejecting useful steering or starting a second turn. The
        // loop persists the tagged message when it drains the bounded queue.
        if (next_prompt) |prompt| {
            server.recordAndEmitSessionEvent(session.id, "user_message_queued", prompt, "running", std.time.milliTimestamp()) catch {};
        }
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }
    defer server.runtime.finishSession(session.id);

    var selected_auth: ?auth_store.ResolvedAuth = null;
    defer if (selected_auth) |value| value.deinit(server.allocator);
    const requested_provider_id = parsed.value.provider_id orelse prompt_mode_override.provider_id;
    const requested_model = parsed.value.model_override orelse prompt_mode_override.model;
    var selected_provider_id: ?[]const u8 = null;
    var selected_model: ?[]const u8 = null;
    if (requested_provider_id) |provider_id| {
        if (provider_id.len == 0) return Error.InvalidParams;
        selected_provider_id = provider_profile.canonicalProviderId(provider_id);
    }
    if (requested_model) |model| {
        if (model.len == 0) return Error.InvalidParams;
        const selection = provider_profile.resolveModelSelection(model, selected_provider_id);
        selected_provider_id = selection.provider_id orelse selected_provider_id;
        selected_model = selection.model_id;
    }
    if (selected_provider_id) |provider_id| {
        // An explicitly named provider is always an explicit ledger read —
        // even when it names the snapshot's active provider. `auth/import`,
        // `auth use`, and `providers/set-model` mutate the ledger after this
        // kernel started; an explicit request must observe them, and a
        // missing record is a typed failure rather than a silent fallback to
        // the startup snapshot.
        selected_auth = auth_store.readProviderById(
            server.allocator,
            server.config.workspace_root,
            provider_id,
        ) catch |err| switch (err) {
            auth_store.Error.MissingProvider, auth_store.Error.MissingAuth => return Error.ProviderNotFound,
            else => return err,
        };
    } else {
        // No explicit provider: refresh the ACTIVE provider credential from
        // the ledger so ledger mutations apply on the next turn without a
        // restart. Env-configured workspaces without a resolvable ledger
        // keep the startup snapshot.
        selected_auth = refreshActiveAuthFromLedger(server.allocator, server.config.workspace_root);
    }

    if (next_prompt) |prompt| {
        const timestamp_ms = std.time.milliTimestamp();
        try store.appendSessionMessage(server.allocator, server.config.workspace_root, session.id, .user, prompt, timestamp_ms);
        try store.setSessionPrompt(server.allocator, server.config.workspace_root, &session, prompt, .initialized);
    }

    // Apply per-invocation provider overrides to a local config copy. The
    // server's canonical config is untouched — overrides live only for this
    // run. This lets the operator test a lesser model or a smaller context
    // window without editing auth.json or config.json.
    var effective_config = server.config.*;
    // Chat posture is hot-loaded so settings changes apply on the next turn
    // without mutating the server's provider/auth snapshot.
    var runtime_policy = config_file.loadRuntimePolicy(server.allocator, server.config.workspace_root) catch config_file.RuntimePolicy{};
    defer runtime_policy.deinit(server.allocator);
    effective_config.log_level = runtime_policy.log_level;
    // Access scope is immutable session state. A config reload must not widen
    // or narrow a live transcript behind the operator's back.
    effective_config.full_access_mode = session.full_access_mode;
    var provider_base_owned: ?[]u8 = null;
    var provider_api_key_owned: ?[]u8 = null;
    var provider_model_owned: ?[]u8 = null;
    var provider_id_owned: ?[]u8 = null;
    var provider_account_owned: ?[]u8 = null;
    var provider_plan_owned: ?[]u8 = null;
    var provider_status_owned: ?[]u8 = null;
    defer {
        if (provider_base_owned) |value| server.allocator.free(value);
        if (provider_api_key_owned) |value| server.allocator.free(value);
        if (provider_model_owned) |value| server.allocator.free(value);
        if (provider_id_owned) |value| server.allocator.free(value);
        if (provider_account_owned) |value| server.allocator.free(value);
        if (provider_plan_owned) |value| server.allocator.free(value);
        if (provider_status_owned) |value| server.allocator.free(value);
    }
    var model_override_owned: ?[]u8 = null;
    defer if (model_override_owned) |m| server.allocator.free(m);
    if (selected_auth) |resolved| {
        provider_base_owned = try server.allocator.dupe(u8, resolved.base_url);
        provider_api_key_owned = try server.allocator.dupe(u8, resolved.api_key);
        provider_model_owned = try server.allocator.dupe(u8, resolved.model);
        provider_id_owned = try server.allocator.dupe(u8, resolved.provider_id);
        provider_account_owned = if (resolved.account_id) |value| try server.allocator.dupe(u8, value) else null;
        provider_plan_owned = if (resolved.subscription_plan_label) |value| try server.allocator.dupe(u8, value) else null;
        provider_status_owned = if (resolved.subscription_status) |value| try server.allocator.dupe(u8, value) else null;
        effective_config.openai_base_url = provider_base_owned.?;
        effective_config.openai_api_key = provider_api_key_owned.?;
        effective_config.openai_model = provider_model_owned.?;
        effective_config.auth_provider = provider_id_owned.?;
        effective_config.auth_type = resolved.auth_type;
        effective_config.auth_scheme = resolved.auth_scheme;
        effective_config.auth_account_id = provider_account_owned;
        effective_config.auth_expires_at_ms = resolved.expires_at_ms;
        effective_config.subscription_plan_label = provider_plan_owned;
        effective_config.subscription_status = provider_status_owned;
        effective_config.wire_api = resolved.wire_api;
    }
    if (selected_model) |model| {
        model_override_owned = try server.allocator.dupe(u8, model);
        effective_config.openai_model = model_override_owned.?;
    }
    if (prompt_mode_override.wire_api) |wire_api| effective_config.wire_api = wire_api;
    if (prompt_mode_override.thinking_mode) |thinking_mode| effective_config.thinking_mode = thinking_mode;
    if (prompt_mode_override.effort) |effort| effective_config.effort = effort;
    if (prompt_mode_override.temperature) |temperature| effective_config.temperature = temperature;
    if (prompt_mode_override.context_window_tokens) |window| effective_config.context_policy.context_window_tokens = window;
    if (prompt_mode_override.reserve_output_tokens) |tokens| effective_config.context_policy.reserve_output_tokens = tokens;
    if (context_window_override) |window| {
        effective_config.context_policy.context_window_tokens = window;
    }
    if (max_output_tokens) |tokens| {
        effective_config.context_policy.reserve_output_tokens = tokens;
    }

    const hooks = loop.Hooks{
        .context = server,
        .onSessionInitializedFn = onLoopSessionInitialized,
        .onSessionEventFn = onLoopSessionEvent,
        .shouldCancelFn = onLoopShouldCancel,
        .drainPendingMessagesFn = onLoopDrainPendingMessages,
        .hasPendingMessagesFn = onLoopHasPendingMessages,
        .copyBufferPreviewFn = onLoopCopyBufferPreview,
    };

    // Set the buffer service's active session context for root sessions.
    // The buffer thread reads this to know what prompt to speculate on.
    // Work-state context is served by the buffer service itself from the
    // durable session summary ledger (.var/sessions/summaries.jsonl) — the
    // orchestrator's mandatory pre-turn-end update, not a raw transcript tail.
    if (server.buffer_srv != null and session.parent_session_id == null) {
        try server.buffer_projection.activate(server.allocator, session.id);
        server.buffer_srv.?.setActiveSession(session.id, next_prompt);
    }

    const result = loop.runPromptWithOptions(server.allocator, effective_config, "", .{
        .transport = server.transport,
        .execution_context = .{
            .workspace_root = effective_config.workspace_root,
            .parent_session_id = session.parent_session_id,
            .agent_service = if (server.runtime.enableAgentTools(session.id)) server.agent_service else null,
            .input_service = .{
                .context = server,
                .requestFn = onInputRequest,
            },
        },
        .session_id = session.id,
        .hooks = hooks,
        .prompt_mode = prompt_mode,
    }) catch |err| switch (err) {
        loop.Error.Cancelled => {
            var cancelled = try store.readSessionRecord(server.allocator, server.config.workspace_root, session.id);
            defer cancelled.deinit(server.allocator);
            const cancelled_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
            defer if (cancelled_output) |value| server.allocator.free(value);
            return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
                .session = makeSessionSummary(cancelled, cancelled_output),
            });
        },
        else => {
            var failed = store.readSessionRecord(server.allocator, server.config.workspace_root, session.id) catch return Error.ExecutionFailed;
            defer failed.deinit(server.allocator);
            if (failed.status != .failed) return Error.ExecutionFailed;

            const failed_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
            defer if (failed_output) |value| server.allocator.free(value);
            return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
                .session = makeSessionSummary(failed, failed_output),
            });
        },
    };
    defer result.deinit(server.allocator);
    var completed = try store.readSessionRecord(server.allocator, server.config.workspace_root, result.session_id);
    defer completed.deinit(server.allocator);
    const output = try store.readOutput(server.allocator, server.config.workspace_root, result.session_id);
    defer if (output) |value| server.allocator.free(value);

    return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
        .session = makeSessionSummary(completed, output),
    });
}

fn handleSessionCompact(server: *Server, params: ?std.json.Value) ![]u8 {
    if (!server.config.context_policy.manual_compaction) return Error.ManualCompactionDisabled;

    const Args = struct {
        session_id: []const u8,
        keep_recent_messages: ?u32 = null,
        max_entries_per_checkpoint: ?u32 = null,
        aggressiveness: ?f64 = null,
        trigger: ?[]const u8 = null,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, null);
    try reconcileStaleRunningSession(server, &session);
    if (server.runtime.isRunning(session.id)) return Error.SessionRunning;

    const trigger = parsed.value.trigger orelse "manual";
    const keep_recent_messages = @as(usize, parsed.value.keep_recent_messages orelse @intCast(server.config.context_policy.keep_recent_messages));
    const max_entries_per_checkpoint = @as(usize, parsed.value.max_entries_per_checkpoint orelse @intCast(server.config.context_policy.max_entries_per_checkpoint));
    const aggressiveness_milli = try compactAggressivenessMilli(parsed.value.aggressiveness, server.config.context_policy.aggressiveness_milli);
    const compact_result = context_compactor.compactSession(server.allocator, server.config.workspace_root, session.id, .{
        .keep_recent_messages = keep_recent_messages,
        .max_entries_per_checkpoint = max_entries_per_checkpoint,
        .aggressiveness_milli = aggressiveness_milli,
        .trigger = trigger,
    }) catch |err| switch (err) {
        context_compactor.Error.InvalidCompactionOptions => return Error.InvalidParams,
        else => return err,
    };
    defer compact_result.deinit(server.allocator);

    return renderJsonAlloc(server.allocator, protocol_types.SessionCompactResult{
        .session_id = session.id,
        .compacted = compact_result.checkpoint != null,
        .checkpoint = compact_result.checkpoint,
        .reason = if (compact_result.checkpoint == null) compact_result.reason else null,
    });
}

fn compactAggressivenessMilli(value: ?f64, default_milli: u16) !u16 {
    const provided = value orelse return default_milli;
    if (!std.math.isFinite(provided) or provided < 0.0 or provided > 1.0) return Error.InvalidParams;
    return @intFromFloat(provided * 1000.0 + 0.5);
}

fn handleSessionCancel(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
    };

    const params_value = params orelse return Error.InvalidParams;
    if (params_value != .object) return Error.InvalidParams;
    const expected_run_seq = try optionalU64FromObject(&params_value.object, "expected_run_seq");
    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, null);
    // A session cancel must wake an ask_user tool as well as the provider
    // transport. Otherwise the provider turn can remain blocked on the input
    // broker after the runtime cancellation flag is set.
    server.input_broker.cancelSession(session.id);

    var cancellation_requested = false;
    var outcome: []const u8 = "not_cancellable";
    var active_run_seq: ?u64 = null;
    if (session.status == .initialized) {
        cancellation_requested = true;
        outcome = "cancelled_before_start";
        try commitAndEmitTurnTerminal(server, &session, 0, .{
            .outcome = .cancelled,
            .detail = "Cancellation requested before execution started.",
        });
    } else if (session.status == .running) {
        const request = server.runtime.requestCancel(session.id, expected_run_seq);
        active_run_seq = request.active_run_seq;
        outcome = switch (request.outcome) {
            .requested => "requested",
            .not_running => "not_running",
            .run_not_observed => "run_not_observed",
            .generation_required => "generation_required",
            .stale_run => "stale_run",
        };
        if (request.outcome == .requested) {
            cancellation_requested = true;
        } else if (request.outcome == .not_running and try isStaleUnownedRunningSession(server, &session)) {
            cancellation_requested = true;
            outcome = "stale_owner_cancelled";
            try commitAndEmitTurnTerminal(server, &session, null, .{
                .outcome = .cancelled,
                .detail = "Cancellation closed a stale running session with no active kernel execution owner.",
            });
        }
    }

    return renderJsonAlloc(server.allocator, protocol_types.SessionCancelResult{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .cancellation_requested = cancellation_requested,
        .outcome = outcome,
        .active_run_seq = active_run_seq,
    });
}

fn handleInputRespond(server: *Server, params: ?std.json.Value) ![]u8 {
    const params_value = params orelse return Error.InvalidParams;
    if (params_value != .object) return Error.InvalidParams;
    const object = &params_value.object;
    const session_id = blk: {
        const value = object.get("session_id") orelse return Error.InvalidParams;
        if (value != .string or value.string.len == 0) return Error.InvalidParams;
        break :blk value.string;
    };
    const request_id = blk: {
        const value = object.get("request_id") orelse return Error.InvalidParams;
        if (value != .string or value.string.len == 0) return Error.InvalidParams;
        break :blk value.string;
    };
    const cancelled = if (object.get("cancelled")) |value| switch (value) {
        .bool => |flag| flag,
        else => return Error.InvalidParams,
    } else false;

    var answers_json: []u8 = try server.allocator.dupe(u8, "[]");
    defer server.allocator.free(answers_json);
    if (!cancelled) {
        const answers = object.get("answers") orelse return Error.InvalidParams;
        if (answers != .array or answers.array.items.len > input_protocol.max_questions) return Error.InvalidParams;
        for (answers.array.items) |answer| {
            if (answer != .object) return Error.InvalidParams;
            const question_id = answer.object.get("question_id") orelse return Error.InvalidParams;
            if (question_id != .string or question_id.string.len == 0) return Error.InvalidParams;
            if (answer.object.get("selected")) |selected| {
                if (selected != .array or selected.array.items.len > input_protocol.max_options) return Error.InvalidParams;
                for (selected.array.items) |choice| {
                    if (choice != .string or choice.string.len == 0) return Error.InvalidParams;
                }
            }
            if (answer.object.get("other")) |other| switch (other) {
                .null => {},
                .string => |value| if (value.len > input_protocol.max_other_bytes) return Error.InvalidParams,
                else => return Error.InvalidParams,
            };
        }
        server.allocator.free(answers_json);
        answers_json = try std.fmt.allocPrint(server.allocator, "{f}", .{std.json.fmt(answers, .{})});
    }

    const response_json = try std.fmt.allocPrint(
        server.allocator,
        "{{\"schema\":\"{s}\",\"request_id\":{f},\"cancelled\":{s},\"answers\":{s}}}",
        .{
            input_protocol.response_schema,
            std.json.fmt(request_id, .{}),
            if (cancelled) "true" else "false",
            answers_json,
        },
    );
    defer server.allocator.free(response_json);
    if (response_json.len > 64 * 1024) return Error.InvalidParams;

    try server.input_broker.resolve(server.allocator, session_id, request_id, response_json);
    return renderJsonAlloc(server.allocator, protocol_types.InputRespondResult{
        .session_id = session_id,
        .request_id = request_id,
        .accepted = true,
    });
}

fn handleSessionGet(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        session_id: []const u8,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    // Extract after_seq manually — std.json's optional u64 parser overflows
    // at comptime (f64 cannot represent maxInt(u64)).
    const after_seq: ?u64 = if (params) |v| blk: {
        if (v != .object) break :blk null;
        break :blk optionalU64FromObject(&v.object, "after_seq") catch return Error.InvalidParams;
    } else null;

    // events_only skips transcript serialization during demand-driven client
    // cursor catch-up. The live contiguous path uses notifications only.
    const events_only: bool = if (params) |v| blk: {
        if (v != .object) break :blk false;
        if (v.object.get("events_only")) |field| {
            break :blk switch (field) {
                .bool => |b| b,
                else => false,
            };
        }
        break :blk false;
    } else false;

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);
    try reconcileStaleRunningSession(server, &session);

    const output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
    defer if (output) |value| server.allocator.free(value);

    const latest_event = try store.readLatestEvent(server.allocator, server.config.workspace_root, session.id);
    defer if (latest_event) |value| value.deinit(server.allocator);

    // When after_seq is provided, parse only the durable suffix newer than the
    // client's exact ledger cursor. `readEventsAfterSeq` still reads current
    // file bytes once; it avoids parsing the already-consumed prefix.
    const events = if (after_seq) |min_seq| blk: {
        break :blk try store.readEventsAfterSeq(server.allocator, server.config.workspace_root, session.id, min_seq);
    } else blk: {
        break :blk try store.readEvents(server.allocator, server.config.workspace_root, session.id);
    };
    defer types.deinitSessionEvents(server.allocator, events);

    if (events_only) {
        // Lightweight poll: skip messages serialization entirely.
        const empty_messages = [_]types.SessionMessage{};
        return renderJsonAlloc(server.allocator, protocol_types.SessionGetResult{
            .session = makeSessionSummary(session, output),
            .latest_event = latest_event,
            .messages = @constCast(&empty_messages),
            .events = events,
        });
    }

    const messages = try store.readSessionMessages(server.allocator, server.config.workspace_root, session.id);
    defer types.deinitSessionMessages(server.allocator, messages);

    return renderJsonAlloc(server.allocator, protocol_types.SessionGetResult{
        .session = makeSessionSummary(session, output),
        .latest_event = latest_event,
        .messages = messages,
        .events = events,
    });
}

fn reconcileStaleRunningSession(server: *Server, session: *types.SessionRecord) !void {
    if (session.status == .running) {
        const persisted_terminal = try store.readCurrentTurnTerminal(server.allocator, server.config.workspace_root, session.id);
        defer if (persisted_terminal) |terminal| terminal.deinit(server.allocator);
        if (persisted_terminal) |terminal| {
            try commitAndEmitTurnTerminal(server, session, terminal.run_seq, .{
                .outcome = terminal.outcome,
                .detail = terminal.detail,
            });
        } else {
            if (!(try isStaleUnownedRunningSession(server, session))) return;

            const failure_reason = "Session was marked running but no active kernel execution owns it.";
            try commitAndEmitTurnTerminal(server, session, null, .{
                .outcome = .failed,
                .detail = failure_reason,
            });
        }
    }

    // Only non-running or proven-stale sessions are safe to reconcile. An
    // active owner may still be between reservation and commit.
    _ = try store.reconcileAbandonedIntents(server.allocator, server.config.workspace_root, session.id);
}

fn commitAndEmitTurnTerminal(
    server: *Server,
    session: *types.SessionRecord,
    expected_run_seq: ?u64,
    input: protocol_events.TurnTerminalInput,
) !void {
    const timestamp_ms = std.time.milliTimestamp();
    var commit = try store.commitTurnTerminal(
        server.allocator,
        server.config.workspace_root,
        session,
        expected_run_seq,
        input,
        timestamp_ms,
    );
    defer commit.deinit(server.allocator);
    if (!commit.appended) return;
    server.emitSessionEvent(
        session.id,
        commit.seq,
        protocol_events.turn_terminal_event_type,
        commit.payload.?,
        types.statusLabel(session.status),
        timestamp_ms,
    ) catch {};
}

fn isStaleUnownedRunningSession(server: *Server, session: *const types.SessionRecord) !bool {
    if (session.status != .running) return false;
    if (server.runtime.isRunning(session.id)) return false;

    const latest_event = try store.readLatestEvent(server.allocator, server.config.workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(server.allocator);

    const now = std.time.milliTimestamp();
    const last_observed_ms = if (latest_event) |event| event.timestamp_ms else session.updated_at_ms;
    return now - last_observed_ms >= stale_running_session_ms;
}

fn handleSessionList(server: *Server, params: ?std.json.Value) ![]u8 {
    const limit: ?u64 = if (params) |value| blk: {
        if (value != .object) return Error.InvalidParams;
        break :blk optionalU64FromObject(&value.object, "limit") catch return Error.InvalidParams;
    } else null;

    const sessions = try store.listSessionRecords(server.allocator, server.config.workspace_root);
    defer types.deinitSessionRecords(server.allocator, sessions);

    const visible_count = if (limit) |value| blk: {
        const bounded = @min(value, @as(u64, std.math.maxInt(usize)));
        break :blk @min(sessions.len, @as(usize, @intCast(bounded)));
    } else sessions.len;

    var outputs = try server.allocator.alloc(?[]u8, visible_count);
    defer {
        for (outputs) |maybe_output| {
            if (maybe_output) |output| server.allocator.free(output);
        }
        server.allocator.free(outputs);
    }
    @memset(outputs, null);

    var summaries = try server.allocator.alloc(protocol_types.SessionSummary, visible_count);
    defer server.allocator.free(summaries);

    for (sessions[0..visible_count], 0..) |*session, index| {
        try reconcileStaleRunningSession(server, session);

        outputs[index] = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        summaries[index] = makeSessionSummary(session.*, outputs[index]);
    }

    return renderJsonAlloc(server.allocator, protocol_types.SessionListResult{
        .sessions = summaries,
    });
}

fn handleScheduleGet(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        job_id: []const u8,
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var job = scheduler.readJob(server.allocator, server.config.workspace_root, parsed.value.job_id) catch |err| switch (err) {
        scheduler.store.Error.ScheduleNotFound => return Error.ScheduleNotFound,
        else => return err,
    };
    defer job.deinit(server.allocator);

    return renderJsonAlloc(server.allocator, protocol_types.ScheduleGetResult{
        .schedule = makeScheduleSummary(job),
    });
}

fn handleScheduleList(server: *Server, params: ?std.json.Value) ![]u8 {
    const Args = struct {
        include_deleted: ?bool = null,
    };

    var include_deleted = false;
    if (params) |_| {
        var parsed = try parseParams(Args, server.allocator, params);
        defer parsed.deinit();
        include_deleted = parsed.value.include_deleted orelse false;
    }

    const jobs = try scheduler.listJobs(server.allocator, server.config.workspace_root, include_deleted);
    defer {
        for (jobs) |job| job.deinit(server.allocator);
        server.allocator.free(jobs);
    }

    var summaries = try server.allocator.alloc(protocol_types.ScheduleSummary, jobs.len);
    defer server.allocator.free(summaries);
    for (jobs, 0..) |job, index| {
        summaries[index] = makeScheduleSummary(job);
    }

    return renderJsonAlloc(server.allocator, protocol_types.ScheduleListResult{
        .schedules = summaries,
    });
}

fn makeScheduleSummary(job: scheduler.types.ScheduleJob) protocol_types.ScheduleSummary {
    return .{
        .id = job.id,
        .title = job.title,
        .target_kind = job.target_kind.label(),
        .schedule_kind = job.schedule_kind.label(),
        .due_at_ms = job.due_at_ms,
        .interval_ms = job.interval_ms,
        .next_due_at_ms = job.next_due_at_ms,
        .status = job.status.label(),
        .misfire_policy = job.misfire_policy.label(),
        .max_catch_up = job.max_catch_up,
        .revision = job.revision,
        .created_at_ms = job.created_at_ms,
        .updated_at_ms = job.updated_at_ms,
    };
}

fn handleToolsList(server: *Server, params: ?std.json.Value) ![]u8 {
    var format: []const u8 = "text";
    if (params) |value| {
        if (value != .object) return Error.InvalidParams;
        if (try optionalStringFromObject(&value.object, "format")) |provided| format = provided;
    }

    if (!std.mem.eql(u8, format, "text") and !std.mem.eql(u8, format, "json")) {
        return Error.InvalidParams;
    }

    const execution_context = tools.ExecutionContext{
        .workspace_root = server.config.workspace_root,
        .agent_service = server.agent_service,
    };
    const output = if (std.mem.eql(u8, format, "json"))
        try tools.renderCatalogJson(server.allocator, execution_context)
    else
        try tools.renderCatalog(server.allocator, execution_context);
    defer server.allocator.free(output);

    return renderJsonAlloc(server.allocator, protocol_types.ToolsListResult{
        .format = format,
        .output = output,
    });
}

fn handleEventsSubscribe(allocator: std.mem.Allocator) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.EventsSubscribeResult{
        .subscribed = true,
        .notification_method = protocol_types.notification_methods.session_event,
    });
}

/// Operator health projection / Join canonical Supervisor capacity and ticket
/// ledger counts without taking scheduling authority. Why: clients need active,
/// idle, queued, and admission truth from one read path. Preserves: unavailable
/// capacity is explicit rather than a healthy zero pool. Evidence: Move 28 RPC
/// projection tests.
fn handleHealthGet(server: *Server) ![]u8 {
    var runtime_policy = config_file.loadRuntimePolicy(server.allocator, server.config.workspace_root) catch config_file.RuntimePolicy{};
    defer runtime_policy.deinit(server.allocator);
    var agent_pool_healthy = true;
    const capacity = server.agent_service.capacity() catch blk: {
        agent_pool_healthy = false;
        break :blk tools.AgentCapacitySnapshot{};
    };
    const ticket_snapshot = (tickets.TicketStore.init(server.allocator, server.config.workspace_root).snapshot() catch tickets.TicketSnapshot{ .healthy = false });
    return renderJsonAlloc(server.allocator, protocol_types.HealthGetResult{
        .ok = true,
        .model = server.config.openai_model,
        .workspace_root = server.config.workspace_root,
        .base_url = server.config.openai_base_url,
        .auth_provider = server.config.auth_provider,
        .subscription_plan_label = server.config.subscription_plan_label,
        .subscription_status = server.config.subscription_status,
        .scheduler_supervisor = server.scheduler_thread != null,
        .log_level = runtime_policy.log_level.label(),
        .effort = server.config.effort,
        .thinking_mode = server.config.thinking_mode,
        .context_window_tokens = server.config.context_policy.context_window_tokens,
        .reserve_output_tokens = server.config.context_policy.reserve_output_tokens,
        .agent_pool_healthy = agent_pool_healthy,
        .agent_pool_max = capacity.max,
        .agent_pool_queued = capacity.queued,
        .agent_pool_running = capacity.running,
        .agent_pool_idle = capacity.idle,
        .agent_pool_available = capacity.available,
        .tickets_unassigned = ticket_snapshot.unassigned,
        .tickets_assigned = ticket_snapshot.assigned,
        .tickets_in_progress = ticket_snapshot.in_progress,
        .tickets_blocked = ticket_snapshot.blocked,
        .tickets_completed = ticket_snapshot.completed,
        .tickets_closed = ticket_snapshot.closed,
        .ticket_ledger_healthy = ticket_snapshot.healthy,
    });
}
/// Refresh the ACTIVE provider credential from the workspace auth ledger for
/// one turn. Returns null when no ledger is resolvable (env-configured
/// workspace) so the caller keeps the startup snapshot. Mirrors the startup
/// ladder: whenever the workspace ledger exists its `active_provider` record
/// wins; no bootstrap seeding or installed-path fallback runs at turn time.
/// This is the one per-turn refresh owner shared by `session/send` and
/// `models/list` so `auth/import`, `auth use`, and `providers/set-model`
/// apply on the next turn without restarting the kernel.
fn refreshActiveAuthFromLedger(allocator: std.mem.Allocator, workspace_root: []const u8) ?auth_store.ResolvedAuth {
    return auth_store.resolveOrSeedWithInstalledAuthPath(allocator, workspace_root, null, null) catch null;
}

/// Expose configured provider identities and availability metadata without
/// exposing API keys or OAuth tokens. Selection remains a separate
/// `session/send.provider_id` override or `auth use` mutation.
fn handleProvidersList(server: *Server) ![]u8 {
    var inventory = auth_store.listProviderSummaries(
        server.allocator,
        server.config.workspace_root,
    ) catch |err| switch (err) {
        auth_store.Error.MissingAuth, auth_store.Error.MissingProvider => {
            return renderJsonAlloc(server.allocator, protocol_types.ProvidersListResult{
                .active_provider = server.config.auth_provider orelse "openai-compatible",
                .providers = &.{},
                .status = "missing_auth",
                .error_message = "no provider records are available in the auth ledger",
            });
        },
        else => {
            return renderJsonAlloc(server.allocator, protocol_types.ProvidersListResult{
                .active_provider = server.config.auth_provider orelse "openai-compatible",
                .providers = &.{},
                .status = "invalid_auth",
                .error_message = "the auth ledger provider projection is invalid",
            });
        },
    };
    defer inventory.deinit(server.allocator);

    var summaries = try server.allocator.alloc(protocol_types.ProviderSummary, inventory.providers.len);
    defer server.allocator.free(summaries);
    for (inventory.providers, 0..) |provider_summary, index| {
        summaries[index] = .{
            .provider_id = provider_summary.provider_id,
            .auth_type = provider_summary.auth_type,
            .wire_api = provider_summary.wire_api,
            .auth_scheme = provider_summary.auth_scheme,
            .model = provider_summary.model,
            .base_url = provider_summary.base_url,
            .active = provider_summary.active,
            .expires_at_ms = provider_summary.expires_at_ms,
            .subscription_status = provider_summary.subscription_status,
            .credential_source = provider_summary.credential_source,
        };
    }

    return renderJsonAlloc(server.allocator, protocol_types.ProvidersListResult{
        .active_provider = inventory.active_provider,
        .providers = summaries,
    });
}

fn handleModelsList(server: *Server, params: ?std.json.Value) ![]u8 {
    // Provider resolution mirrors session/send: an explicit provider_id is
    // always an explicit ledger read, and a bare request resolves the
    // LEDGER's active provider — never the startup snapshot — so models are
    // discovered against the provider an import or `auth use` actually
    // selected. Only an env-configured workspace without a ledger keeps the
    // snapshot fields.
    var requested_provider: ?[]const u8 = null;
    if (params) |value| {
        if (value == .object) {
            requested_provider = try optionalStringFromObject(&value.object, "provider_id");
        }
    }

    var resolved_provider_id: []const u8 = server.config.auth_provider orelse "openai-compatible";
    var resolved_base_url: []const u8 = server.config.openai_base_url;
    var resolved_api_key: []const u8 = server.config.openai_api_key;
    var resolved_account_id: ?[]const u8 = server.config.auth_account_id;
    var resolved_auth_scheme: types.AuthScheme = server.config.auth_scheme;
    var resolved_auth: ?auth_store.ResolvedAuth = null;
    defer if (resolved_auth) |ra| ra.deinit(server.allocator);

    if (requested_provider) |provider_id| {
        resolved_auth = auth_store.readProviderById(
            server.allocator,
            server.config.workspace_root,
            provider_id,
        ) catch |err| switch (err) {
            auth_store.Error.MissingProvider, auth_store.Error.MissingAuth => {
                return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
                    .provider = provider_id,
                    .base_url = "",
                    .models = &.{},
                    .status = "provider_not_found",
                    .error_message = "requested provider is not in the auth ledger",
                });
            },
            else => {
                return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
                    .provider = provider_id,
                    .base_url = "",
                    .models = &.{},
                    .status = "unreachable",
                    .error_message = "failed to read auth ledger",
                });
            },
        };
    } else {
        // Bare request: the ledger's active provider is authoritative. A
        // null refresh means no resolvable ledger — the startup snapshot
        // fields stand (env-configured workspace).
        resolved_auth = refreshActiveAuthFromLedger(server.allocator, server.config.workspace_root);
    }
    var resolved_model: []const u8 = "";
    if (resolved_auth) |auth| {
        resolved_provider_id = auth.provider_id;
        resolved_base_url = auth.base_url;
        resolved_api_key = auth.api_key;
        resolved_account_id = auth.account_id;
        resolved_auth_scheme = auth.auth_scheme;
        resolved_model = auth.model;
    }

    // One family, three sources: live endpoint per transport → vendored
    // models.dev snapshot → the credential's configured model. The RPC
    // surface never branches on provider id for discovery.
    var discovered = models.discoverModels(
        server.allocator,
        resolved_provider_id,
        resolved_base_url,
        resolved_api_key,
        resolved_account_id,
        resolved_auth_scheme,
        if (resolved_model.len > 0) resolved_model else null,
    ) catch |err| switch (err) {
        models.Error.Unreachable => return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
            .provider = resolved_provider_id,
            .base_url = resolved_base_url,
            .models = &.{},
            .status = "unreachable",
            .error_message = "provider offline or connection refused",
        }),
        models.Error.BadStatus => return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
            .provider = resolved_provider_id,
            .base_url = resolved_base_url,
            .models = &.{},
            .status = "bad_status",
            .error_message = "provider returned a non-200 response",
        }),
        models.Error.MalformedResponse => return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
            .provider = resolved_provider_id,
            .base_url = resolved_base_url,
            .models = &.{},
            .status = "malformed",
            .error_message = "provider returned an unexpected model list shape",
        }),
        else => return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
            .provider = resolved_provider_id,
            .base_url = resolved_base_url,
            .models = &.{},
            .status = "unreachable",
            .error_message = "unexpected discovery failure",
        }),
    };
    defer discovered.deinit(server.allocator);

    var summaries = try server.allocator.alloc(protocol_types.ModelSummary, discovered.models.len);
    defer server.allocator.free(summaries);
    for (discovered.models, 0..) |model, i| {
        summaries[i] = .{
            .id = model.id,
            .owned_by = model.owned_by,
            .context_length = model.context_length,
        };
    }

    return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
        .provider = discovered.provider_id,
        .base_url = discovered.base_url,
        .models = summaries,
        .context_from_native_surface = discovered.context_from_native_surface,
        .status = "ok",
    });
}

/// config/set RPC handler — atomically mutates one config key with validation.
/// Params: {"section":"runtime","key":"effort","value":"max"}
/// The value can be a string, number, bool, object, or null (to disable).
/// Validation-before-write: if the mutation produces an invalid document,
/// the file is NOT modified and an error is returned.
fn handleConfigSet(server: *Server, params: ?std.json.Value) ![]u8 {
    const params_value = params orelse return Error.InvalidParams;
    if (params_value != .object) return Error.InvalidParams;

    const section = blk: {
        const v = params_value.object.get("section") orelse return Error.InvalidParams;
        if (v != .string) return Error.InvalidParams;
        break :blk v.string;
    };
    const key = blk: {
        const v = params_value.object.get("key") orelse return Error.InvalidParams;
        if (v != .string) return Error.InvalidParams;
        break :blk v.string;
    };
    const value = params_value.object.get("value") orelse return Error.InvalidParams;

    config_file.writeConfigKey(server.allocator, server.config.workspace_root, section, key, value) catch {
        return Error.ExecutionFailed;
    };

    // Build the success response as a JSON string.
    return std.fmt.allocPrint(server.allocator, "{{\"schema\":\"var1.config_set.v1\",\"section\":{f},\"key\":{f},\"hotload\":\"applies on next turn\"}}", .{
        std.json.fmt(section, .{}),
        std.json.fmt(key, .{}),
    });
}

/// Set the `model` field on one provider record in the auth ledger. The
/// canonical config `provider` section only permits `wire_api`; the model lives
/// on the ledger record, so the Models tab mutates it here (store-owned) rather
/// than through config/set.
fn handleProviderModelSet(server: *Server, params: ?std.json.Value) ![]u8 {
    const params_value = params orelse return Error.InvalidParams;
    if (params_value != .object) return Error.InvalidParams;
    const provider_id = blk: {
        const v = params_value.object.get("provider_id") orelse return Error.InvalidParams;
        if (v != .string) return Error.InvalidParams;
        break :blk v.string;
    };
    const model = blk: {
        const v = params_value.object.get("model") orelse return Error.InvalidParams;
        if (v != .string) return Error.InvalidParams;
        break :blk v.string;
    };

    auth_store.setProviderModel(server.allocator, server.config.workspace_root, provider_id, model) catch {
        return Error.ExecutionFailed;
    };
    return renderJsonAlloc(server.allocator, protocol_types.ProviderModelSetResult{
        .provider_id = provider_id,
        .model = model,
    });
}

/// Secret-free detection inventory of native Codex/Claude/OpenCode credentials.
/// The TUI shows these as "detected, not connected" rows so the operator can
/// import one in-panel. Never returns tokens.
fn handleAuthDetect(server: *Server) ![]u8 {
    var detection = auth_detect.detect(server.allocator) catch {
        return renderJsonAlloc(server.allocator, protocol_types.AuthDetectResult{
            .detected = &.{},
            .status = "unavailable",
        });
    };
    defer detection.deinit();

    var rows = try server.allocator.alloc(protocol_types.DetectedCredential, detection.detected.len);
    defer server.allocator.free(rows);
    for (detection.detected, 0..) |entry, i| {
        rows[i] = .{
            .source = entry.source,
            .kind = @tagName(entry.kind),
            .provider_id = entry.provider_id,
            .source_path = entry.source_path,
            .model = entry.model,
            .live = entry.live,
            .account_hint = entry.account_hint,
            .note = entry.note,
        };
    }
    return renderJsonAlloc(server.allocator, protocol_types.AuthDetectResult{
        .detected = rows,
    });
}

/// Import detected native credentials into the auth ledger. Accepts an optional
/// `sources` array and `force` flag, mirroring the CLI. Returns the provider ids
/// imported and skipped — never a token.
fn handleAuthImport(server: *Server, params: ?std.json.Value) ![]u8 {
    var sources = std.array_list.Managed([]const u8).init(server.allocator);
    defer sources.deinit();
    var force = false;
    if (params) |value| {
        if (value == .object) {
            if (value.object.get("sources")) |sources_value| {
                if (sources_value == .array) {
                    for (sources_value.array.items) |item| {
                        if (item != .string) return Error.InvalidParams;
                        try sources.append(item.string);
                    }
                }
            }
            if (value.object.get("force")) |force_value| {
                if (force_value != .bool) return Error.InvalidParams;
                force = force_value.bool;
            }
        }
    }

    var result = auth_import.importSources(server.allocator, server.config.workspace_root, sources.items, force) catch |err| {
        return renderJsonAlloc(server.allocator, protocol_types.AuthImportResult{
            .imported = &.{},
            .skipped = &.{},
            .status = "failed",
            .error_message = switch (err) {
                error.HomeUnavailable => "home directory unavailable",
                error.NoSourceSelected => "no native source matched",
                else => "import failed",
            },
        });
    };
    defer result.deinit();
    return renderJsonAlloc(server.allocator, protocol_types.AuthImportResult{
        .imported = result.imported,
        .skipped = result.skipped,
    });
}

/// Secret-free agent registry listing for the Models tab's agent-assignment
/// cycler. Returns ids, descriptions, and any per-agent provider/model/effort
/// override so the tab can show what each agent currently runs on.
fn handleAgentsList(server: *Server) ![]u8 {
    var registry = agent_spec.loadRegistry(server.allocator, server.config.workspace_root) catch {
        return renderJsonAlloc(server.allocator, protocol_types.AgentsListResult{
            .agents = &.{},
            .status = "unavailable",
        });
    };
    defer registry.deinit();

    var summaries = try server.allocator.alloc(protocol_types.AgentSummary, registry.all().len);
    defer server.allocator.free(summaries);
    for (registry.all(), 0..) |spec, i| {
        summaries[i] = .{
            .id = spec.id,
            .description = spec.description,
            .route_role = spec.route_role.label(),
            .provider_id = spec.provider_id,
            .model = spec.model,
            .effort = spec.effort,
            .enabled = true,
        };
    }
    return renderJsonAlloc(server.allocator, protocol_types.AgentsListResult{
        .agents = summaries,
    });
}

/// Assign a provider_id and/or model to one agent via the agent registry
/// owner (`upsertConfiguredAgent`). This is the canonical mutation for
/// per-agent model overrides — config/set cannot write nested agent
/// definitions, and the config `provider` section only permits `wire_api`.
fn handleAgentsConfigure(server: *Server, params: ?std.json.Value) ![]u8 {
    const params_value = params orelse return Error.InvalidParams;
    if (params_value != .object) return Error.InvalidParams;
    const agent_id = blk: {
        const v = params_value.object.get("agent_id") orelse return Error.InvalidParams;
        if (v != .string) return Error.InvalidParams;
        break :blk v.string;
    };
    var patch = agent_spec.DefinitionPatch{ .id = agent_id };
    if (params_value.object.get("provider_id")) |v| {
        if (v != .string) return Error.InvalidParams;
        patch.provider_id = v.string;
    }
    if (params_value.object.get("model")) |v| {
        if (v != .string) return Error.InvalidParams;
        patch.model = v.string;
    }

    var evidence = agent_spec.upsertConfiguredAgent(server.allocator, server.config.workspace_root, patch) catch {
        return renderJsonAlloc(server.allocator, protocol_types.AgentsConfigureResult{
            .agent_id = agent_id,
            .status = "rejected",
            .error_message = "agent mutation rejected by the registry owner",
        });
    };
    defer evidence.deinit(server.allocator);
    return renderJsonAlloc(server.allocator, protocol_types.AgentsConfigureResult{
        .agent_id = agent_id,
    });
}

fn onLoopSessionInitialized(ctx: ?*anyopaque, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = session_id;
}

fn onLoopSessionEvent(
    ctx: ?*anyopaque,
    session_id: []const u8,
    seq: u64,
    event_type: []const u8,
    message: []const u8,
    status: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, event_type, "session_started")) {
        _ = server.runtime.observeRunStart(session_id, seq);
    }
    // The live notification is a read model over events.jsonl (AGENTS.md §IV).
    // The durable event has already been appended to the event spine by
    // recordSessionEvent before this hook fires — losing a live frame to a
    // slow/broken TUI pipe must never corrupt the provider turn. Swallowing
    // WriteFailed here breaks the producer-consumer coupling that bricked
    // sessions under sustained streaming when the TUI fell behind.
    server.emitSessionEvent(session_id, seq, event_type, message, status, timestamp_ms) catch {};
}

fn onLoopShouldCancel(ctx: ?*anyopaque, session_id: []const u8) bool {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.runtime.shouldCancel(session_id);
}

/// Drain pending user messages queued during an active turn (interjection protocol).
/// Returns an owned slice of owned strings, or null if the queue is empty.
fn onLoopDrainPendingMessages(ctx: ?*anyopaque, session_id: []const u8) ?[][]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.runtime.drainPendingMessages(server.allocator, session_id);
}

fn onLoopHasPendingMessages(ctx: ?*anyopaque, session_id: []const u8) bool {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.runtime.hasPendingMessages(session_id);
}

/// Return an owned preview only when its session identity matches this loop.
fn onLoopCopyBufferPreview(ctx: ?*anyopaque, allocator: std.mem.Allocator, session_id: []const u8) ?[]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.buffer_projection.copy(allocator, session_id);
}

fn onInputRequest(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    session_id: []const u8,
    request_id: []const u8,
    request_json: []const u8,
) anyerror![]u8 {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    try server.input_broker.begin(allocator, session_id, request_id);
    server.recordAndEmitSessionEvent(
        session_id,
        "input_requested",
        request_json,
        "waiting",
        std.time.milliTimestamp(),
    ) catch |err| {
        server.input_broker.cancel(allocator, session_id, request_id);
        _ = server.input_broker.wait(allocator, session_id, request_id) catch {};
        return err;
    };
    return server.input_broker.wait(allocator, session_id, request_id);
}

fn makeSessionSummary(session: types.SessionRecord, output: ?[]const u8) protocol_types.SessionSummary {
    return .{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = output,
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .full_access_mode = session.full_access_mode,
        .execution_receipt = if (session.execution_receipt) |receipt| receipt.*.view() else null,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
}

fn parseParams(comptime T: type, allocator: std.mem.Allocator, params: ?std.json.Value) !std.json.Parsed(T) {
    const value = params orelse return Error.InvalidParams;
    if (value != .object) return Error.InvalidParams;
    return std.json.parseFromValue(T, allocator, value, .{
        .ignore_unknown_fields = true,
    }) catch Error.InvalidParams;
}

fn optionalStringFromObject(object: *const std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    switch (value) {
        .string => |s| return s,
        .null => return null,
        else => return Error.InvalidParams,
    }
}

/// Extract an optional u64 from a JSON object. Accepts integer or float JSON
/// numbers (defensive — some clients emit floats). Returns null when the key
/// is absent or JSON null; returns InvalidParams on a non-numeric value.
fn optionalU64FromObject(object: *const std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |n| if (n < 0) Error.InvalidParams else @as(u64, @intCast(n)),
        .float => |n| if (n < 0) Error.InvalidParams else @as(u64, @intFromFloat(n)),
        .null => null,
        else => Error.InvalidParams,
    };
}

fn extractRequestId(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("id") orelse return null;
    if (value != .string) return Error.InvalidRequest;
    return value.string;
}

test "request admission is bounded and closes before shutdown" {
    var admission = RequestAdmission{};
    admission.start();
    for (0..max_admitted_requests) |_| try std.testing.expect(admission.tryAcquire());
    try std.testing.expect(!admission.tryAcquire());
    for (0..max_admitted_requests) |_| admission.release();
    admission.stop();
    try std.testing.expect(!admission.tryAcquire());
}

test "input broker scopes duplicate tool-call ids and wakes cancellation" {
    var broker = InputBroker{};
    defer broker.deinit(std.testing.allocator);

    try broker.begin(std.testing.allocator, "session-a", "call-1");
    try broker.begin(std.testing.allocator, "session-b", "call-1");
    try broker.resolve(std.testing.allocator, "session-a", "call-1", "{\"cancelled\":false}");

    const response = try broker.wait(std.testing.allocator, "session-a", "call-1");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"cancelled\":false}", response);

    broker.cancelSession("session-b");
    try std.testing.expectError(
        error.InputCancelled,
        broker.wait(std.testing.allocator, "session-b", "call-1"),
    );
    try std.testing.expectError(
        Error.InputNotFound,
        broker.wait(std.testing.allocator, "session-a", "call-1"),
    );
}

test "100 concurrent session sends admit one turn owner" {
    const Race = struct {
        runtime: *Runtime,
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        ready: usize = 0,
        open: bool = false,

        fn run(self: *@This(), outcome: *SessionStartAdmission) void {
            self.mutex.lock();
            self.ready += 1;
            self.condition.broadcast();
            while (!self.open) self.condition.wait(&self.mutex);
            self.mutex.unlock();

            outcome.* = self.runtime.tryStartSession(std.testing.allocator, "session-race", null) catch unreachable;
        }

        fn release(self: *@This(), expected: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.ready < expected) self.condition.wait(&self.mutex);
            self.open = true;
            self.condition.broadcast();
        }
    };

    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    try runtime.ensureSession(std.testing.allocator, "session-race", null);

    var race = Race{ .runtime = &runtime };
    var outcomes: [100]SessionStartAdmission = undefined;
    var threads: [100]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Race.run, .{ &race, &outcomes[index] });
    }
    race.release(threads.len);
    for (threads) |thread| thread.join();

    var started: usize = 0;
    var already_running: usize = 0;
    for (outcomes) |outcome| switch (outcome) {
        .started => started += 1,
        .already_running => already_running += 1,
    };
    try std.testing.expectEqual(@as(usize, 1), started);
    try std.testing.expectEqual(@as(usize, 99), already_running);
    try std.testing.expect(runtime.isRunning("session-race"));
    runtime.finishSession("session-race");
    try std.testing.expect(!runtime.isRunning("session-race"));
}

test "shutdown fence reaches 100 active session owners before late admission" {
    const Gate = struct {
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        ready: usize = 0,
        open: bool = false,

        // Keep every observer behind one boundary until beginShutdown has
        // atomically fenced admission and marked all active owners.
        fn wait(self: *@This()) void {
            self.mutex.lock();
            self.ready += 1;
            self.condition.broadcast();
            while (!self.open) self.condition.wait(&self.mutex);
            self.mutex.unlock();
        }

        fn release(self: *@This(), expected: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.ready < expected) self.condition.wait(&self.mutex);
            self.open = true;
            self.condition.broadcast();
        }
    };
    const Observer = struct {
        gate: *Gate,
        runtime: *Runtime,
        session_id: []const u8,
        saw_cancel: *bool,

        fn run(self: @This()) void {
            self.gate.wait();
            self.saw_cancel.* = self.runtime.shouldCancel(self.session_id);
        }
    };

    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    var id_buffers: [100][32]u8 = undefined;
    var session_ids: [100][]const u8 = undefined;
    for (&session_ids, 0..) |*session_id, index| {
        session_id.* = try std.fmt.bufPrint(&id_buffers[index], "shutdown-session-{d}", .{index});
        try runtime.ensureSession(std.testing.allocator, session_id.*, null);
        try std.testing.expectEqual(SessionStartAdmission.started, try runtime.tryStartSession(std.testing.allocator, session_id.*, null));
        try std.testing.expect(runtime.observeRunStart(session_id.*, @intCast(index + 1)));
    }

    var gate = Gate{};
    var saw_cancel = [_]bool{false} ** 100;
    var threads: [100]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Observer.run, .{Observer{
            .gate = &gate,
            .runtime = &runtime,
            .session_id = session_ids[index],
            .saw_cancel = &saw_cancel[index],
        }});
    }

    try std.testing.expectEqual(@as(usize, 100), runtime.beginShutdown());
    gate.release(threads.len);
    for (threads) |thread| thread.join();
    for (saw_cancel) |observed| try std.testing.expect(observed);
    for (session_ids) |session_id| {
        try std.testing.expectError(Error.ServerShuttingDown, runtime.tryStartSession(std.testing.allocator, session_id, null));
    }
}

test "stale cancel generation cannot stop a newer session run" {
    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    try runtime.ensureSession(std.testing.allocator, "session-cancel-generation", null);

    try std.testing.expectEqual(SessionStartAdmission.started, try runtime.tryStartSession(std.testing.allocator, "session-cancel-generation", null));
    const not_observed = runtime.requestCancel("session-cancel-generation", 11);
    try std.testing.expectEqual(RuntimeCancelOutcome.run_not_observed, not_observed.outcome);
    try std.testing.expect(!runtime.shouldCancel("session-cancel-generation"));
    try std.testing.expect(runtime.observeRunStart("session-cancel-generation", 11));
    runtime.finishSession("session-cancel-generation");

    try std.testing.expectEqual(SessionStartAdmission.started, try runtime.tryStartSession(std.testing.allocator, "session-cancel-generation", null));
    try std.testing.expect(runtime.observeRunStart("session-cancel-generation", 22));

    const missing = runtime.requestCancel("session-cancel-generation", null);
    try std.testing.expectEqual(RuntimeCancelOutcome.generation_required, missing.outcome);
    try std.testing.expectEqual(@as(?u64, 22), missing.active_run_seq);
    try std.testing.expect(!runtime.shouldCancel("session-cancel-generation"));

    const stale = runtime.requestCancel("session-cancel-generation", 11);
    try std.testing.expectEqual(RuntimeCancelOutcome.stale_run, stale.outcome);
    try std.testing.expectEqual(@as(?u64, 22), stale.active_run_seq);
    try std.testing.expect(!runtime.shouldCancel("session-cancel-generation"));

    const current = runtime.requestCancel("session-cancel-generation", 22);
    try std.testing.expectEqual(RuntimeCancelOutcome.requested, current.outcome);
    try std.testing.expectEqual(@as(?u64, 22), current.active_run_seq);
    try std.testing.expect(runtime.shouldCancel("session-cancel-generation"));
}

test "losing session send atomically queues the steer message" {
    var runtime = Runtime{};
    defer runtime.deinit(std.testing.allocator);
    try runtime.ensureSession(std.testing.allocator, "session-steer", null);

    try std.testing.expectEqual(SessionStartAdmission.started, try runtime.tryStartSession(std.testing.allocator, "session-steer", null));
    try std.testing.expectEqual(SessionStartAdmission.already_running, try runtime.tryStartSession(std.testing.allocator, "session-steer", "change direction"));

    const pending = runtime.drainPendingMessages(std.testing.allocator, "session-steer").?;
    defer {
        for (pending) |message| std.testing.allocator.free(message);
        std.testing.allocator.free(pending);
    }
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("change direction", pending[0]);
    runtime.finishSession("session-steer");
}

test "buffer projection rejects a late preview from the previous session" {
    var projection = BufferProjection{};
    defer projection.deinit(std.testing.allocator);

    try projection.activate(std.testing.allocator, "session-a");
    try std.testing.expect(try projection.store(std.testing.allocator, "session-a", "preview-a"));
    const copy_a = projection.copy(std.testing.allocator, "session-a").?;
    defer std.testing.allocator.free(copy_a);

    try projection.activate(std.testing.allocator, "session-b");
    try std.testing.expect(!try projection.store(std.testing.allocator, "session-a", "late-a"));
    try std.testing.expect(projection.copy(std.testing.allocator, "session-a") == null);
    try std.testing.expect(projection.copy(std.testing.allocator, "session-b") == null);
    try std.testing.expectEqualStrings("preview-a", copy_a);

    try std.testing.expect(try projection.store(std.testing.allocator, "session-b", "preview-b"));
    const copy_b = projection.copy(std.testing.allocator, "session-b").?;
    defer std.testing.allocator.free(copy_b);
    try std.testing.expectEqualStrings("preview-b", copy_b);
}

test "request overload preserves request id and ignores notifications" {
    const response = (try renderBusyResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"req-busy\",\"method\":\"health/get\"}")).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-busy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32005") != null);

    const notification = try renderBusyResponse(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"events/subscribe\"}");
    try std.testing.expect(notification == null);
}

test "success response includes id and payload" {
    const allocator = std.testing.allocator;
    const response = try renderSuccessResponse(allocator, "abc", "{\"ok\":true}");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"result\":{\"ok\":true}") != null);
}

test "error response uses json-rpc envelope" {
    const allocator = std.testing.allocator;
    const response = try renderErrorResponse(allocator, "req-1", -32601, "Method not found");
    defer allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"code\":-32601") != null);
}

fn noopSend(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopLaunch(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: ?[]const u8,
    _: tools.DelegationScope,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopAgentStatus(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopWait(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: usize,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopList(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
) anyerror![]u8 {
    return error.UnexpectedCall;
}

fn noopConverge(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!void {
    return error.UnexpectedCall;
}

fn noopReconcile(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!usize {
    return error.UnexpectedCall;
}

// Keep the health fixture internally coherent so projection tests catch drift.
fn testHealthCapacity(_: ?*anyopaque) anyerror!tools.AgentCapacitySnapshot {
    return tools.AgentCapacitySnapshot.fromCounts(4, 2, 1);
}

const test_config = types.Config{
    .openai_base_url = @constCast("http://127.0.0.1:1234"),
    .openai_api_key = @constCast("test-key"),
    .openai_model = @constCast("test-model"),
    .max_steps = 2,
    .workspace_root = @constCast("."),
};

fn makeTestServer() Server {
    return .{
        .allocator = std.testing.allocator,
        .config = &test_config,
        .transport = .{
            .context = null,
            .sendFn = noopSend,
        },
        .agent_service = .{
            .context = null,
            .launchFn = noopLaunch,
            .statusFn = noopAgentStatus,
            .waitFn = noopWait,
            .listFn = noopList,
            .convergeFn = noopConverge,
            .reconcileFn = noopReconcile,
        },
        .stdout_file = std.fs.File.stdout(),
    };
}

fn makeTestConfig(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "test-model"),
        .max_steps = 2,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn attachTestStdout(tmp: *std.testing.TmpDir, server: *Server, name: []const u8) !std.fs.File {
    const file = try tmp.dir.createFile(name, .{ .read = true });
    server.stdout_file = file;
    return file;
}

test "session event notification carries the exact stored sequence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var session = try store.initSession(std.testing.allocator, workspace_root, "prove event identity");
    defer session.deinit(std.testing.allocator);
    const timestamp_ms: i64 = 123_456_789;

    var first_capture = try attachTestStdout(&tmp, &server, "event-sequence-1.bin");
    defer first_capture.close();
    try server.recordAndEmitSessionEvent(session.id, "assistant_delta", "same", "running", timestamp_ms);
    try first_capture.seekTo(0);
    const first_output = try first_capture.readToEndAlloc(std.testing.allocator, 8 * 1024);
    defer std.testing.allocator.free(first_output);

    var second_capture = try attachTestStdout(&tmp, &server, "event-sequence-2.bin");
    defer second_capture.close();
    try server.recordAndEmitSessionEvent(session.id, "assistant_delta", "same", "running", timestamp_ms);
    try second_capture.seekTo(0);
    const second_output = try second_capture.readToEndAlloc(std.testing.allocator, 8 * 1024);
    defer std.testing.allocator.free(second_output);

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u64, 1), events[0].seq);
    try std.testing.expectEqual(@as(u64, 2), events[1].seq);

    try std.testing.expect(std.mem.indexOf(u8, first_output, "\"schema\":\"var1.session_event_notification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_output, "\"seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\"schema\":\"var1.session_event_notification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_output, "\"seq\":2") != null);
}

test "request executor drains admitted frames before server teardown" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = makeTestServer();
    defer server.deinit();
    const stdout_file = try attachTestStdout(&tmp, &server, "rpc-output.bin");
    defer stdout_file.close();

    try server.startRequestExecutor();
    const request = try std.testing.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":\"drain-1\",\"method\":\"initialize\"}");
    errdefer std.testing.allocator.free(request);
    try std.testing.expect(try server.submitRequest(request));
    server.stopRequestExecutor();

    try std.testing.expectEqual(@as(usize, 0), server.request_admission.admitted);
    try stdout_file.seekTo(0);
    const output = try stdout_file.readToEndAlloc(std.testing.allocator, 16 * 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":\"drain-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VAR1-kernel-stdio-v2") != null);
}

test "active request shutdown cancels before join and persists one terminal event" {
    const ShutdownTransport = struct {
        server: ?*Server = null,
        session_id: []const u8,
        mutex: std.Thread.Mutex = .{},
        entered: bool = false,
        saw_cancel: bool = false,
        timed_out: bool = false,

        fn send(
            ctx: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: []const u8,
        ) anyerror![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.mutex.lock();
            self.entered = true;
            self.mutex.unlock();

            var timer = try std.time.Timer.start();
            while (timer.read() < 5_000 * std.time.ns_per_ms) {
                if (self.server.?.runtime.shouldCancel(self.session_id)) {
                    self.saw_cancel = true;
                    return allocator.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"shutdown probe\"}}]}");
                }
                std.Thread.sleep(std.time.ns_per_ms);
            }

            self.timed_out = true;
            return allocator.dupe(u8, "{\"choices\":[{\"message\":{\"content\":\"shutdown probe timed out\"}}]}");
        }

        fn waitUntilEntered(self: *@This(), timeout_ms: u64) !bool {
            var timer = try std.time.Timer.start();
            while (timer.read() < timeout_ms * std.time.ns_per_ms) {
                self.mutex.lock();
                const ready = self.entered;
                self.mutex.unlock();
                if (ready) return true;
                std.Thread.sleep(std.time.ns_per_ms);
            }
            return false;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var session = try store.initSession(std.testing.allocator, workspace_root, "stay active until shutdown");
    defer session.deinit(std.testing.allocator);

    var shutdown_transport = ShutdownTransport{ .session_id = session.id };
    var server = makeTestServer();
    server.config = &config;
    server.transport = .{ .context = &shutdown_transport, .sendFn = ShutdownTransport.send };
    shutdown_transport.server = &server;
    defer server.deinit();
    const stdout_file = try attachTestStdout(&tmp, &server, "shutdown-rpc-output.bin");
    defer stdout_file.close();

    try server.startRequestExecutor();
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"shutdown-1\",\"method\":\"session/send\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    const submitted = server.submitRequest(request) catch |err| {
        std.testing.allocator.free(request);
        return err;
    };
    if (!submitted) std.testing.allocator.free(request);
    try std.testing.expect(submitted);
    try std.testing.expect(try shutdown_transport.waitUntilEntered(2_000));

    var shutdown_timer = try std.time.Timer.start();
    server.stopRequestExecutor();
    const shutdown_ns = shutdown_timer.read();

    try std.testing.expect(shutdown_transport.saw_cancel);
    try std.testing.expect(!shutdown_transport.timed_out);
    try std.testing.expect(shutdown_ns < 2_000 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 0), server.request_admission.admitted);
    try std.testing.expectError(Error.ServerShuttingDown, server.runtime.tryStartSession(std.testing.allocator, session.id, null));

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.cancelled, persisted.status);

    const events = try store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer types.deinitSessionEvents(std.testing.allocator, events);
    var terminal_events: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, protocol_events.turn_terminal_event_type)) terminal_events += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), terminal_events);

    try stdout_file.seekTo(0);
    const output = try stdout_file.readToEndAlloc(std.testing.allocator, 64 * 1024);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"id\":\"shutdown-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"cancelled\"") != null);
}

fn appendStaleStartedEvent(workspace_root: []const u8, session_id: []const u8) !void {
    try store.appendEvent(std.testing.allocator, workspace_root, session_id, .{
        .event_type = "session_started",
        .message = "VAR1 session initialized.",
        .timestamp_ms = std.time.milliTimestamp() - stale_running_session_ms - 1,
    });
}

test "health/get projects Supervisor capacity and ticket ledger pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    server.agent_service.capacityFn = testHealthCapacity;
    defer server.deinit();

    const ticket_store = tickets.TicketStore.init(std.testing.allocator, workspace_root);
    var assigned = try ticket_store.create(.{
        .title = "health queue",
        .description = "health projection",
        .category = "bug",
        .severity = "high",
        .status = .assigned,
        .workspace_root = workspace_root,
        .created_at_ms = 1,
    });
    defer assigned.deinit(std.testing.allocator);

    const response = try handleHealthGet(&server);
    defer std.testing.allocator.free(response);
    var parsed = try std.json.parseFromSlice(protocol_types.HealthGetResult, std.testing.allocator, response, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.agent_pool_max);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.agent_pool_queued);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.agent_pool_running);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.agent_pool_idle);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.agent_pool_available);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_unassigned);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tickets_assigned);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_in_progress);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_blocked);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_completed);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_closed);
    try std.testing.expect(parsed.value.ticket_ledger_healthy);
    try std.testing.expect(std.mem.indexOf(u8, response, "agent_pool_idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "agent_pool_available") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "tickets_assigned") != null);
}

test "health/get marks unavailable Supervisor capacity instead of healthy zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const response = try handleHealthGet(&server);
    defer std.testing.allocator.free(response);
    var parsed = try std.json.parseFromSlice(protocol_types.HealthGetResult, std.testing.allocator, response, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.agent_pool_healthy);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.agent_pool_max);
    try std.testing.expect(std.mem.indexOf(u8, response, "agent_pool_healthy") != null);
}

test "processRequest returns parse errors for malformed json-rpc payloads" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(u8, "{\"jsonrpc\":");
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);
    defer if (response) |value| std.testing.allocator.free(value);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32700") != null);
}

test "processRequest returns method-not-found errors for unknown methods" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-1\",\"method\":\"missing/method\",\"params\":{}}",
    );
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);
    defer if (response) |value| std.testing.allocator.free(value);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32601") != null);
}

test "session/send rejects unknown prompt modes before session execution" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"id\":\"req-prompt-mode\",\"method\":\"session/send\",\"params\":{\"session_id\":\"missing\",\"prompt_mode\":\"unknown\"}}",
    );
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);
    defer if (response) |value| std.testing.allocator.free(value);

    try std.testing.expect(response != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"id\":\"req-prompt-mode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32602") != null);
}

test "processRequest treats id-less initialize requests as notifications" {
    var server = makeTestServer();
    defer server.deinit();

    const payload = try std.testing.allocator.dupe(
        u8,
        "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{}}",
    );
    defer std.testing.allocator.free(payload);
    const response = try processRequest(&server, payload);

    try std.testing.expect(response == null);
}

test "session/get reconciles stale running sessions into user-visible failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "stale-get-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "show me live progress", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);

    try appendStaleStartedEvent(workspace_root, session.id);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-stale\",\"method\":\"session/get\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-stale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\":\"turn_terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "no active kernel execution owns it") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);
    try std.testing.expect(std.mem.indexOf(u8, persisted.failure_reason.?, "no active kernel execution owns it") != null);
}

test "session/get preserves fresh running sessions without live owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "fresh-get-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "active stream", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);

    const now_ms = std.time.milliTimestamp();
    try store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_delta",
        .message = "still streaming",
        .timestamp_ms = now_ms,
    });
    try store.touchSessionUpdatedAt(std.testing.allocator, workspace_root, session.id, now_ms);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-fresh\",\"method\":\"session/get\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-fresh\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\":\"turn_terminal\"") == null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.running, persisted.status);
}

test "session/list reconciles stale running sessions for dashboard surfaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "stale-list-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "show active dashboard state", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);

    try appendStaleStartedEvent(workspace_root, session.id);

    const response = (try processRequest(&server, "{\"jsonrpc\":\"2.0\",\"id\":\"req-list\",\"method\":\"session/list\",\"params\":{}}")).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "no active kernel execution owns it") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);
}

test "session/list keeps hydrated outputs alive through response render" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "list-output-lifetime-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "resume visible transcript", .{
        .status = .completed,
    });
    defer session.deinit(std.testing.allocator);
    try store.writeOutput(std.testing.allocator, workspace_root, session.id, "assistant output must survive stdio render");

    const response = (try processRequest(&server, "{\"jsonrpc\":\"2.0\",\"id\":\"req-list-output\",\"method\":\"session/list\",\"params\":{}}")).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-list-output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "assistant output must survive stdio render") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, session.id) != null);
}

test "session/list bounds the response for lightweight selectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "bounded-list-stdout.bin");
    defer stdout_capture.close();

    var first = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "first session", .{
        .status = .completed,
    });
    defer first.deinit(std.testing.allocator);
    var second = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "second session", .{
        .status = .completed,
    });
    defer second.deinit(std.testing.allocator);

    const response = (try processRequest(&server, "{\"jsonrpc\":\"2.0\",\"id\":\"req-list-limit\",\"method\":\"session/list\",\"params\":{\"limit\":1}}")).?;
    defer std.testing.allocator.free(response);

    const first_present = std.mem.indexOf(u8, response, first.id) != null;
    const second_present = std.mem.indexOf(u8, response, second.id) != null;
    try std.testing.expect(first_present != second_present);
}

test "session/resume reconciles stale running sessions before returning state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "stale-resume-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "resume stale run", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);
    try appendStaleStartedEvent(workspace_root, session.id);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-resume-stale\",\"method\":\"session/resume\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "no active kernel execution owns it") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);
}

test "session/compact reconciles stale running sessions before running compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "stale-compact-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "compact stale run", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);
    try appendStaleStartedEvent(workspace_root, session.id);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-compact-stale\",\"method\":\"session/compact\",\"params\":{{\"session_id\":\"{s}\",\"trigger\":\"test\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-compact-stale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") == null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);

    const latest_event = try store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event != null);
    try std.testing.expectEqualStrings(protocol_events.turn_terminal_event_type, latest_event.?.event_type);
}

test "session/send without prompt reconciles stale running sessions without implicit execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "stale-send-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "send stale run", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);
    try appendStaleStartedEvent(workspace_root, session.id);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-send-stale\",\"method\":\"session/send\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-send-stale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "no active kernel execution owns it") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);
}

test "session/send without prompt returns failed sessions without implicit retry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "failed run", .{});
    defer session.deinit(std.testing.allocator);
    try store.setSessionFailure(std.testing.allocator, workspace_root, &session, "ProviderTransportFailed");

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-send-failed\",\"method\":\"session/send\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"req-send-failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "ProviderTransportFailed") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.failed, persisted.status);
    try std.testing.expectEqualStrings("ProviderTransportFailed", persisted.failure_reason.?);
}

test "session/cancel persists initialized-session cancellation events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "cancel-initialized-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "cancel before execution", .{});
    defer session.deinit(std.testing.allocator);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-cancel-initialized\",\"method\":\"session/cancel\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"cancellation_requested\":true") != null);

    const latest_event = try store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event != null);
    try std.testing.expectEqualStrings(protocol_events.turn_terminal_event_type, latest_event.?.event_type);
    try std.testing.expect(std.mem.indexOf(u8, latest_event.?.message, "before execution started") != null);
}

test "session/cancel rejects a stale run generation before accepting the active one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "cancel exact run", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);
    try server.runtime.ensureSession(std.testing.allocator, session.id, null);
    try std.testing.expectEqual(SessionStartAdmission.started, try server.runtime.tryStartSession(std.testing.allocator, session.id, null));
    try std.testing.expect(server.runtime.observeRunStart(session.id, 22));

    const unguarded_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-cancel-unguarded\",\"method\":\"session/cancel\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(unguarded_request);
    const unguarded_response = (try processRequest(&server, unguarded_request)).?;
    defer std.testing.allocator.free(unguarded_response);

    try std.testing.expect(std.mem.indexOf(u8, unguarded_response, "\"cancellation_requested\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, unguarded_response, "\"outcome\":\"generation_required\"") != null);
    try std.testing.expect(!server.runtime.shouldCancel(session.id));

    const stale_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-cancel-old-run\",\"method\":\"session/cancel\",\"params\":{{\"session_id\":\"{s}\",\"expected_run_seq\":11}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(stale_request);
    const stale_response = (try processRequest(&server, stale_request)).?;
    defer std.testing.allocator.free(stale_response);

    try std.testing.expect(std.mem.indexOf(u8, stale_response, "\"cancellation_requested\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_response, "\"outcome\":\"stale_run\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stale_response, "\"active_run_seq\":22") != null);
    try std.testing.expect(!server.runtime.shouldCancel(session.id));

    const active_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-cancel-active-run\",\"method\":\"session/cancel\",\"params\":{{\"session_id\":\"{s}\",\"expected_run_seq\":22}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(active_request);
    const active_response = (try processRequest(&server, active_request)).?;
    defer std.testing.allocator.free(active_response);

    try std.testing.expect(std.mem.indexOf(u8, active_response, "\"cancellation_requested\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, active_response, "\"outcome\":\"requested\"") != null);
    try std.testing.expect(server.runtime.shouldCancel(session.id));
}

test "session/cancel closes stale running sessions without live owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);

    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();
    var stdout_capture = try attachTestStdout(&tmp, &server, "cancel-stale-stdout.bin");
    defer stdout_capture.close();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "cancel stale run", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);

    try appendStaleStartedEvent(workspace_root, session.id);

    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-cancel-stale\",\"method\":\"session/cancel\",\"params\":{{\"session_id\":\"{s}\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);

    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"cancellation_requested\":true") != null);

    var persisted = try store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.SessionStatus.cancelled, persisted.status);

    const latest_event = try store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event != null);
    try std.testing.expectEqualStrings(protocol_events.turn_terminal_event_type, latest_event.?.event_type);
    try std.testing.expect(std.mem.indexOf(u8, latest_event.?.message, "no active kernel execution owner") != null);
}

/// Build a request payload for the kernel RPC dispatch path.
fn rpcRequest(method: []const u8, params: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"t\",\"method\":\"{s}\",\"params\":{s}}}",
        .{ method, params },
    );
}

test "providers/set-model mutates only the ledger model via dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    // Seed a provider in the ledger.
    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "zai",
        .base_url = "https://api.z.ai/api/coding/paas/v4",
        .model = "glm-5.2",
        .api_key = "k1",
    });
    defer auth_store.removeProvider(std.testing.allocator, workspace_root, "zai") catch {};

    const request = try rpcRequest(protocol_types.methods.provider_model_set, "{\"provider_id\":\"zai\",\"model\":\"glm-5.5\"}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"model\":\"glm-5.5\"") != null);

    var auth = try auth_store.readProviderById(std.testing.allocator, workspace_root, "zai");
    defer auth.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("glm-5.5", auth.model);
    try std.testing.expectEqualStrings("k1", auth.api_key);
}

test "providers/set-model returns a rejection envelope for a missing provider" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.provider_model_set, "{\"provider_id\":\"absent\",\"model\":\"m\"}");
    defer std.testing.allocator.free(request);
    const response = try processRequest(&server, request);
    // The handler raises ExecutionFailed; processRequest renders a JSON-RPC
    // error frame (never a fake ok status).
    defer if (response) |value| std.testing.allocator.free(value);
    try std.testing.expect(response != null);
    if (response) |value| {
        try std.testing.expect(std.mem.indexOf(u8, value, "\"error\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, value, "\"status\":\"ok\"") == null);
    }
}

test "agents/list dispatch returns the loaded registry ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    // Seed a minimal config so the agent registry loads (not just built-ins).
    const config_path = try config_file.ensure(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(config_path);
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = "{\"version\":1}\n" });

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.agents_list, "{}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":\"recon\"") != null);
}

test "agents/configure assigns provider and model through the registry owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    const config_path = try config_file.ensure(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(config_path);
    try std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = "{\"version\":1}\n" });

    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.agents_configure,
        "{\"agent_id\":\"recon\",\"provider_id\":\"openrouter\",\"model\":\"openrouter/deepseek/deepseek-chat\"}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);

    // Read the agent back from the registry.
    var registry = try agent_spec.loadRegistry(std.testing.allocator, workspace_root);
    defer registry.deinit();
    const recon = try registry.resolve("recon");
    try std.testing.expectEqualStrings("openrouter", recon.provider_id);
    try std.testing.expectEqualStrings("openrouter/deepseek/deepseek-chat", recon.model);
}

test "auth/detect dispatch returns an ok envelope (secret-free)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.auth_detect, "{}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"detected\":[") != null);
    // Never leaks a token into the projection.
    try std.testing.expect(std.mem.indexOf(u8, response, "access_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, response, "refresh_token") == null);
}

test "auth/import dispatch returns a structured result envelope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.auth_import, "{\"sources\":[\"codex\"]}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    // Must be a structured envelope (imported/skipped arrays), never a bare
    // transport error — even when the host has no codex file, the TUI reads
    // this to decide success.
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"imported\":[") != null);
}

test "models/list resolves the ledger active provider, not the startup snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    // An import-style upsert switches the ledger active provider to
    // anthropic while the kernel snapshot still names the startup provider.
    // The unroutable loopback base URL keeps discovery offline; the envelope
    // must still name the LEDGER provider, proving resolution provenance.
    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "anthropic",
        .base_url = "http://127.0.0.1:2/v1",
        .model = "claude-sonnet-4-5",
        .api_key = "k2",
    });
    defer auth_store.removeProvider(std.testing.allocator, workspace_root, "anthropic") catch {};

    const request = try rpcRequest(protocol_types.methods.models_list, "{}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"provider\":\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"base_url\":\"http://127.0.0.1:2/v1\"") != null);
    // The stale snapshot provider must not leak into the resolution.
    try std.testing.expect(std.mem.indexOf(u8, response, "127.0.0.1:1234") == null);
}

test "models/list keeps the startup snapshot when no ledger exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    const request = try rpcRequest(protocol_types.methods.models_list, "{}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    // Env-configured workspace: the snapshot fields stand (unroutable test
    // base URL fails discovery, but against the snapshot provider).
    try std.testing.expect(std.mem.indexOf(u8, response, "\"provider\":\"openai-compatible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "127.0.0.1:1234") != null);
}

test "session/send explicit provider equal to the snapshot active still reads the ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    var session = try store.initSessionWithOptions(std.testing.allocator, workspace_root, "explicit active provider", .{});
    defer session.deinit(std.testing.allocator);

    // The snapshot's active provider is absent from the ledger: the explicit
    // request must fail closed as ProviderNotFound instead of silently
    // proceeding on startup-snapshot credentials.
    const request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":\"req-send-explicit\",\"method\":\"session/send\",\"params\":{{\"session_id\":\"{s}\",\"prompt\":\"hi\",\"provider_id\":\"openai-compatible\"}}}}",
        .{session.id},
    );
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "Provider not found") != null);
    // No turn was attempted on snapshot credentials.
    try std.testing.expect(std.mem.indexOf(u8, response, "\"session\"") == null);
}

test "models/list answers no-catalog providers from the vendored snapshot without network" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);
    var config = try makeTestConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var server = makeTestServer();
    server.config = &config;
    defer server.deinit();

    // The OpenCode gateway base has no /models surface and the loopback
    // address is unroutable — the live tier fails and the vendored
    // models.dev snapshot answers with the real opencode catalog (context
    // windows included), not a fabricated single-model list.
    try auth_store.upsertApiKeyProvider(std.testing.allocator, workspace_root, .{
        .provider_id = "opencode",
        .base_url = "http://127.0.0.1:1/v1",
        .model = "opencode/glm-4.7",
        .api_key = "k1",
        .credential_source = "opencode",
    });
    defer auth_store.removeProvider(std.testing.allocator, workspace_root, "opencode") catch {};

    const request = try rpcRequest(protocol_types.methods.models_list, "{\"provider_id\":\"opencode\"}");
    defer std.testing.allocator.free(request);
    const response = (try processRequest(&server, request)).?;
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"status\":\"ok\"") != null);
    // The snapshot supplies many real opencode models with context windows.
    try std.testing.expect(std.mem.indexOf(u8, response, "\"glm-4.6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"context_length\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"context_from_native_surface\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"error_message\":null") != null);
}
