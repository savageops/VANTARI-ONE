const std = @import("std");
const context_compactor = @import("../core/context/compactor.zig");
const config_file = @import("../core/config/file.zig");
const loop = @import("../core/executor/loop.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const models = @import("../core/providers/models.zig");
const scheduler = @import("../core/scheduler/index.zig");
const tickets = @import("../core/tickets/index.zig");
const buffer_service = @import("../core/executor/buffer.zig");
const store = @import("../core/sessions/store.zig");
const auth_store = @import("../core/auth/store.zig");
const tools = @import("../core/tools/runtime.zig");
const types = @import("../shared/types.zig");
const stdio_client = @import("stdio_client.zig");
const wire = @import("stdio_wire.zig");

pub const LocalClient = stdio_client.LocalClient;
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
    ExecutionFailed,
    InvalidFrame,
    MissingChildPipes,
    InvalidRpcResponse,
    RpcRemoteError,
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
    pending_messages: std.ArrayListUnmanaged([]u8) = .{},
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

    fn setRunning(self: *Runtime, session_id: []const u8, running: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            state.running = running;
            if (running) state.cancel_requested = false;
        }
    }

    fn isRunning(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.running;
        return false;
    }

    fn requestCancel(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (!state.running) return false;
            state.cancel_requested = true;
            return true;
        }

        return false;
    }

    fn shouldCancel(self: *Runtime, session_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.get(session_id)) |state| return state.cancel_requested;
        return false;
    }

    /// Queue a user message for mid-turn injection. Bounded at max_pending_messages;
    /// oldest is dropped on overflow. The caller owns the message slice; we dupe it.
    fn queuePendingMessage(self: *Runtime, allocator: std.mem.Allocator, session_id: []const u8, message: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sessions.getPtr(session_id)) |state| {
            if (state.pending_messages.items.len >= max_pending_messages) {
                const oldest = state.pending_messages.orderedRemove(0);
                allocator.free(oldest);
            }
            try state.pending_messages.append(allocator, try allocator.dupe(u8, message));
        }
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
    scheduler_service: ?scheduler.Service = null,
    scheduler_thread: ?std.Thread = null,
    buffer_srv: ?buffer_service.Service = null,
    buffer_thread: ?std.Thread = null,
    /// Active root session id for the buffer preview callback. Heap-owned
    /// (duped) because the session record is freed when the request handler
    /// returns — a borrowed pointer would dangle.
    buffer_session_id: ?[]u8 = null,
    /// Latest buffer preview text — written by the buffer thread callback,
    /// read by the executor via peekBufferPreview hook. Mutex-guarded swap.
    buffer_preview_mutex: std.Thread.Mutex = .{},
    buffer_preview_text: ?[]u8 = null,

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
        if (self.buffer_session_id) |sid| self.allocator.free(sid);
        if (self.buffer_preview_text) |text| self.allocator.free(text);
        self.runtime.deinit(self.allocator);
    }

    fn emitSessionEvent(
        self: *Server,
        session_id: []const u8,
        event_type: []const u8,
        message: []const u8,
        status: []const u8,
        timestamp_ms: i64,
    ) !void {
        const params_json = try renderJsonAlloc(self.allocator, protocol_types.SessionEventNotification{
            .session_id = session_id,
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
        try store.appendEvent(self.allocator, self.config.workspace_root, session_id, .{
            .event_type = event_type,
            .message = message,
            .timestamp_ms = timestamp_ms,
        });
        try store.touchSessionUpdatedAt(self.allocator, self.config.workspace_root, session_id, timestamp_ms);
        try self.emitSessionEvent(session_id, event_type, message, status, timestamp_ms);
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
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    // Live notification is a read model over the durable event spine
    // (AGENTS.md §IV). A slow/broken TUI pipe must never corrupt a child
    // agent delegation turn.
    server.emitSessionEvent(parent_session_id, event_type, message, "running", timestamp_ms) catch {};
}

fn runSchedulerService(service: *scheduler.Service) void {
    service.run();
}

/// Buffer preview callback — stores the latest preview for executor injection
/// and emits a buffer_preview session event to the TUI.
fn onBufferPreview(ctx: ?*anyopaque, preview: []const u8) void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));

    // Store for executor injection (thread-safe swap)
    {
        server.buffer_preview_mutex.lock();
        defer server.buffer_preview_mutex.unlock();
        if (server.buffer_preview_text) |old| server.allocator.free(old);
        server.buffer_preview_text = server.allocator.dupe(u8, preview) catch null;
    }

    // Emit to TUI
    const session_id = server.buffer_session_id orelse return;
    server.emitSessionEvent(session_id, "buffer_preview", preview, "running", std.time.milliTimestamp()) catch {};
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
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_get)) {
        return handleSessionGet(server, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_list)) {
        return handleSessionList(server);
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
    if (std.mem.eql(u8, method_name, protocol_types.methods.models_list)) {
        return handleModelsList(server, params);
    }

    if (std.mem.eql(u8, method_name, protocol_types.methods.config_set)) {
        return handleConfigSet(server, params);
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
    };

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

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

    if (parsed.value.prompt) |next_prompt_raw| {
        const next_prompt = std.mem.trim(u8, next_prompt_raw, " \t\r\n");
        if (next_prompt.len == 0) return Error.InvalidParams;
        const timestamp_ms = std.time.milliTimestamp();
        // Don't persist to transcript yet if the session is running — the
        // interjection drain in loop.zig will persist the tagged version.
        // For non-running sessions, persist now (normal submit path).
        if (!server.runtime.isRunning(session.id)) {
            try store.appendSessionMessage(server.allocator, server.config.workspace_root, session.id, .user, next_prompt, timestamp_ms);
            try store.setSessionPrompt(server.allocator, server.config.workspace_root, &session, next_prompt, .initialized);
        }
    } else if (session.status == .completed or session.status == .failed or session.status == .cancelled) {
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    if (server.runtime.isRunning(session.id)) {
        // Interjection protocol: queue the message for mid-turn injection
        // instead of silently returning stale state. The message is already
        // persisted to the transcript at line 549. Emit a user_message_queued
        // event so the TUI acknowledges receipt in the reasoning dock.
        if (parsed.value.prompt) |prompt| {
            server.runtime.queuePendingMessage(server.allocator, session.id, prompt) catch {};
            server.emitSessionEvent(session.id, "user_message_queued", prompt, "running", std.time.milliTimestamp()) catch {};
        }
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    server.runtime.setRunning(session.id, true);
    defer server.runtime.setRunning(session.id, false);

    // Apply per-invocation provider overrides to a local config copy. The
    // server's canonical config is untouched — overrides live only for this
    // run. This lets the operator test a lesser model or a smaller context
    // window without editing auth.json or config.json.
    var effective_config = server.config.*;
    var model_override_owned: ?[]u8 = null;
    defer if (model_override_owned) |m| server.allocator.free(m);
    if (parsed.value.model_override) |model| {
        model_override_owned = try server.allocator.dupe(u8, model);
        effective_config.openai_model = model_override_owned.?;
    }
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
        .peekBufferPreviewFn = onLoopPeekBufferPreview,
    };

    // Set the buffer service's active session context for root sessions.
    // The buffer thread reads this to know what prompt to speculate on.
    // Work-state context is served by the buffer service itself from the
    // durable session summary ledger (.var/sessions/summaries.json) — the
    // orchestrator's mandatory pre-turn-end update, not a raw transcript tail.
    if (server.buffer_srv != null and session.parent_session_id == null) {
        // Dupe session.id because session.deinit will free it when the
        // request handler returns. The buffer preview callback reads
        // buffer_session_id on a background thread after that point.
        if (server.buffer_session_id) |old| server.allocator.free(old);
        server.buffer_session_id = server.allocator.dupe(u8, session.id) catch null;
        server.buffer_srv.?.setSessionId(session.id);
        if (parsed.value.prompt) |prompt| {
            server.buffer_srv.?.setActivePrompt(prompt);
        }
    }

    const result = loop.runPromptWithOptions(server.allocator, effective_config, "", .{
        .transport = server.transport,
        .execution_context = .{
            .workspace_root = effective_config.workspace_root,
            .parent_session_id = session.parent_session_id,
            .agent_service = if (server.runtime.enableAgentTools(session.id)) server.agent_service else null,
        },
        .session_id = session.id,
        .hooks = hooks,
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

    var parsed = try parseParams(Args, server.allocator, params);
    defer parsed.deinit();

    var session = store.readSessionRecord(server.allocator, server.config.workspace_root, parsed.value.session_id) catch {
        return Error.SessionNotFound;
    };
    defer session.deinit(server.allocator);

    try server.runtime.ensureSession(server.allocator, session.id, null);

    var cancellation_requested = false;
    if (session.status == .initialized) {
        try store.setSessionStatus(server.allocator, server.config.workspace_root, &session, .cancelled);
        cancellation_requested = true;
        server.recordAndEmitSessionEvent(
            session.id,
            "session_cancelled",
            "Cancellation requested before execution started.",
            types.statusLabel(session.status),
            session.updated_at_ms,
        ) catch {};
    } else if (session.status == .running) {
        if (server.runtime.requestCancel(session.id)) {
            cancellation_requested = true;
        } else if (try isStaleUnownedRunningSession(server, &session)) {
            try store.setSessionStatus(server.allocator, server.config.workspace_root, &session, .cancelled);
            cancellation_requested = true;
            server.recordAndEmitSessionEvent(
                session.id,
                "session_cancelled",
                "Cancellation closed a stale running session with no active kernel execution owner.",
                types.statusLabel(session.status),
                session.updated_at_ms,
            ) catch {};
        }
    }

    return renderJsonAlloc(server.allocator, protocol_types.SessionCancelResult{
        .session_id = session.id,
        .status = types.statusLabel(session.status),
        .cancellation_requested = cancellation_requested,
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

    // events_only: skip re-reading and serializing messages. During streaming
    // the TUI polls session/get every ~100ms; serializing the full message
    // array on every poll is the dominant cost. The TUI only needs events.
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

    // When after_seq is provided, use the incremental tail-read path.
    // This reads ONLY new events from disk (backward scan from EOF) instead
    // of reading + parsing the entire events.jsonl on every TUI poll.
    // This is the critical streaming-performance fix: O(k) where k is the
    // number of NEW events, not O(n) where n is the total event count.
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
    if (session.status != .running) return;
    if (!(try isStaleUnownedRunningSession(server, session))) return;

    const timestamp_ms = std.time.milliTimestamp();
    const failure_reason = "Session was marked running but no active kernel execution owns it.";
    // Durable write first — this is the source of truth. The live notification
    // is a read model (AGENTS.md §IV); a broken TUI pipe must not corrupt the
    // reconciliation RPC (session/get is polled by the TUI every ~100ms).
    try store.setSessionFailure(server.allocator, server.config.workspace_root, session, failure_reason);
    server.recordAndEmitSessionEvent(session.id, "session_failed", failure_reason, "failed", timestamp_ms) catch {};
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

fn handleSessionList(server: *Server) ![]u8 {
    const sessions = try store.listSessionRecords(server.allocator, server.config.workspace_root);
    defer types.deinitSessionRecords(server.allocator, sessions);

    var outputs = try server.allocator.alloc(?[]u8, sessions.len);
    defer {
        for (outputs) |maybe_output| {
            if (maybe_output) |output| server.allocator.free(output);
        }
        server.allocator.free(outputs);
    }
    @memset(outputs, null);

    var summaries = try server.allocator.alloc(protocol_types.SessionSummary, sessions.len);
    defer server.allocator.free(summaries);

    for (sessions, 0..) |*session, index| {
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

fn handleHealthGet(server: *Server) ![]u8 {
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
        .effort = server.config.effort,
        .thinking_mode = server.config.thinking_mode,
        .context_window_tokens = server.config.context_policy.context_window_tokens,
        .reserve_output_tokens = server.config.context_policy.reserve_output_tokens,
        .agent_pool_healthy = agent_pool_healthy,
        .agent_pool_max = capacity.max,
        .agent_pool_queued = capacity.queued,
        .agent_pool_running = capacity.running,
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

fn handleModelsList(server: *Server, params: ?std.json.Value) ![]u8 {
    // Optional provider switch: when provider_id is present and differs from
    // the active provider, resolve that provider's credentials from the auth
    // ledger's providers map. This is multi-provider routing — the operator
    // can discover models on a non-active provider without changing the
    // active config.
    var requested_provider: ?[]const u8 = null;
    if (params) |value| {
        if (value == .object) {
            requested_provider = try optionalStringFromObject(&value.object, "provider_id");
        }
    }

    const active_provider = server.config.auth_provider orelse "openai-compatible";
    const is_active = requested_provider == null or
        (requested_provider != null and std.mem.eql(u8, requested_provider.?, active_provider));

    var resolved_provider_id: []const u8 = active_provider;
    var resolved_base_url: []const u8 = server.config.openai_base_url;
    var resolved_api_key: []const u8 = server.config.openai_api_key;
    var resolved_auth: ?auth_store.ResolvedAuth = null;
    defer if (resolved_auth) |ra| ra.deinit(server.allocator);

    if (!is_active) {
        // Resolve the requested provider from the auth ledger.
        resolved_auth = auth_store.readProviderById(
            server.allocator,
            server.config.workspace_root,
            requested_provider.?,
        ) catch |err| switch (err) {
            auth_store.Error.MissingProvider, auth_store.Error.MissingAuth => {
                return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
                    .provider = requested_provider.?,
                    .base_url = "",
                    .models = &.{},
                    .status = "provider_not_found",
                    .error_message = "requested provider is not in the auth ledger",
                });
            },
            else => {
                return renderJsonAlloc(server.allocator, protocol_types.ModelsListResult{
                    .provider = requested_provider.?,
                    .base_url = "",
                    .models = &.{},
                    .status = "unreachable",
                    .error_message = "failed to read auth ledger",
                });
            },
        };
        resolved_provider_id = resolved_auth.?.provider_id;
        resolved_base_url = resolved_auth.?.base_url;
        resolved_api_key = resolved_auth.?.api_key;
    }

    var discovered = models.listModels(server.allocator, resolved_base_url, resolved_api_key, null, resolved_provider_id) catch |err| switch (err) {
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

fn onLoopSessionInitialized(ctx: ?*anyopaque, session_id: []const u8) anyerror!void {
    _ = ctx;
    _ = session_id;
}

fn onLoopSessionEvent(
    ctx: ?*anyopaque,
    session_id: []const u8,
    event_type: []const u8,
    message: []const u8,
    status: []const u8,
    timestamp_ms: i64,
) anyerror!void {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    // The live notification is a read model over events.jsonl (AGENTS.md §IV).
    // The durable event has already been appended to the event spine by
    // recordSessionEvent before this hook fires — losing a live frame to a
    // slow/broken TUI pipe must never corrupt the provider turn. Swallowing
    // WriteFailed here breaks the producer-consumer coupling that bricked
    // sessions under sustained streaming when the TUI fell behind.
    server.emitSessionEvent(session_id, event_type, message, status, timestamp_ms) catch {};
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

/// Peek the latest buffer model preview for advisory injection.
/// Returns a borrowed slice — caller must not free.
fn onLoopPeekBufferPreview(ctx: ?*anyopaque) ?[]const u8 {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    server.buffer_preview_mutex.lock();
    defer server.buffer_preview_mutex.unlock();
    return server.buffer_preview_text;
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

fn testHealthCapacity(_: ?*anyopaque) anyerror!tools.AgentCapacitySnapshot {
    return .{ .max = 4, .queued = 2, .running = 1, .available = 3 };
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
    try std.testing.expectEqual(@as(usize, 3), parsed.value.agent_pool_available);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_unassigned);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.tickets_assigned);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_in_progress);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_blocked);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_completed);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tickets_closed);
    try std.testing.expect(parsed.value.ticket_ledger_healthy);
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
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\":\"session_failed\"") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\":\"session_failed\"") == null);

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
    try std.testing.expectEqualStrings("session_failed", latest_event.?.event_type);
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
    try std.testing.expectEqualStrings("session_cancelled", latest_event.?.event_type);
    try std.testing.expect(std.mem.indexOf(u8, latest_event.?.message, "before execution started") != null);
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
    try std.testing.expectEqualStrings("session_cancelled", latest_event.?.event_type);
    try std.testing.expect(std.mem.indexOf(u8, latest_event.?.message, "no active kernel execution owner") != null);
}
