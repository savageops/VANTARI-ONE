const std = @import("std");
const context_compactor = @import("../core/context/compactor.zig");
const loop = @import("../core/executor/loop.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const models = @import("../core/providers/models.zig");
const scheduler = @import("../core/scheduler/index.zig");
const store = @import("../core/sessions/store.zig");
const auth_store = @import("../core/auth/store.zig");
const tools = @import("../core/tools/runtime.zig");
const types = @import("../shared/types.zig");

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

const max_header_line_bytes = 8 * 1024;
const max_notification_backlog = 512;
const notification_poll_ms: u64 = 50;
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
};

const Runtime = struct {
    mutex: std.Thread.Mutex = .{},
    sessions: std.StringHashMapUnmanaged(SessionRuntimeState) = .{},

    fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
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
    runtime: Runtime = .{},
    scheduler_service: ?scheduler.Service = null,
    scheduler_thread: ?std.Thread = null,
    /// Delta coalescer: consecutive assistant_delta / reasoning_delta tokens
    /// are buffered here and flushed as a single batched notification. This
    /// turns 91 single-token frames into ~10 batched frames during a
    /// streaming turn, eliminating the per-frame pipe round-trip that
    /// throttled the TUI to 1 word/sec.
    delta_coalesce_buf: std.array_list.Managed(u8) = undefined,
    delta_coalesce_init: bool = false,
    delta_coalesce_session: ?[]u8 = null,
    delta_coalesce_status: ?[]u8 = null,
    delta_coalesce_kind: ?[]u8 = null, // "assistant_delta" or "reasoning_delta"
    delta_coalesce_count: usize = 0,
    delta_coalesce_first_ms: i64 = 0,

    fn deinit(self: *Server) void {
        if (self.delta_coalesce_init) {
            self.delta_coalesce_buf.deinit();
            if (self.delta_coalesce_session) |s| self.allocator.free(s);
            if (self.delta_coalesce_status) |s| self.allocator.free(s);
            if (self.delta_coalesce_kind) |s| self.allocator.free(s);
        }
        if (self.scheduler_service) |*service| {
            service.requestStop();
            if (self.scheduler_thread) |thread| thread.join();
            service.deinit();
        }
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
        try writeFrame(self.stdout_file, payload);
    }

    /// Flush the delta coalesce buffer as a single batched notification.
    /// The batched message is the concatenated text of all buffered deltas.
    fn flushDeltaCoalesce(self: *Server) !void {
        if (!self.delta_coalesce_init or self.delta_coalesce_count == 0) return;

        const message = self.delta_coalesce_buf.items;
        const session_id = self.delta_coalesce_session orelse return;
        const status = self.delta_coalesce_status orelse "running";
        const event_type = self.delta_coalesce_kind orelse "assistant_delta";
        const timestamp_ms = self.delta_coalesce_first_ms;

        try self.emitSessionEvent(session_id, event_type, message, status, timestamp_ms);

        // Reset for the next batch.
        self.delta_coalesce_buf.clearRetainingCapacity();
        self.delta_coalesce_count = 0;
    }
};

const RequestJob = struct {
    server: *Server,
    request_payload: []u8,
};

pub const RpcCallResult = struct {
    result_json: ?[]u8 = null,
    error_json: ?[]u8 = null,

    pub fn deinit(self: RpcCallResult, allocator: std.mem.Allocator) void {
        if (self.result_json) |value| allocator.free(value);
        if (self.error_json) |value| allocator.free(value);
    }
};

pub const Notification = struct {
    sequence: u64,
    method: []u8,
    params_json: []u8,

    pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        allocator.free(self.params_json);
    }
};

const ClientState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    responses: std.StringHashMapUnmanaged([]u8) = .{},
    notifications: std.array_list.Managed(Notification),
    next_request_id: usize = 1,
    next_notification_sequence: u64 = 1,
    closed: bool = false,
    read_error: ?anyerror = null,

    fn init(allocator: std.mem.Allocator) ClientState {
        return .{
            .allocator = allocator,
            .notifications = std.array_list.Managed(Notification).init(allocator),
        };
    }

    fn deinit(self: *ClientState) void {
        var iterator = self.responses.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.responses.deinit(self.allocator);

        for (self.notifications.items) |notification| notification.deinit(self.allocator);
        self.notifications.deinit();
    }

    fn recordResponse(self: *ClientState, request_id: []const u8, response_payload: []u8) !void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        try self.responses.put(self.allocator, try self.allocator.dupe(u8, request_id), response_payload);
    }

    fn recordNotification(self: *ClientState, method: []const u8, params_json: []const u8) !void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        if (self.notifications.items.len >= max_notification_backlog) {
            const dropped = self.notifications.orderedRemove(0);
            dropped.deinit(self.allocator);
        }

        try self.notifications.append(.{
            .sequence = self.next_notification_sequence,
            .method = try self.allocator.dupe(u8, method),
            .params_json = try self.allocator.dupe(u8, params_json),
        });
        self.next_notification_sequence += 1;
    }

    fn recordClosure(self: *ClientState, read_error: ?anyerror) void {
        self.mutex.lock();
        defer {
            self.cond.broadcast();
            self.mutex.unlock();
        }

        self.closed = true;
        self.read_error = read_error;
    }

    fn nextRequestId(self: *ClientState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        const request_id = self.next_request_id;
        self.next_request_id += 1;
        return request_id;
    }
};

const ReaderContext = struct {
    allocator: std.mem.Allocator,
    stdout_file: std.fs.File,
    state: *ClientState,
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
    server.scheduler_service = try scheduler.Service.init(allocator, config, transport);
    server.scheduler_thread = try std.Thread.spawn(.{}, runSchedulerService, .{&server.scheduler_service.?});

    const stdin_file = std.fs.File.stdin();
    while (true) {
        const request_payload = try readFrame(allocator, stdin_file) orelse break;

        const job = try std.heap.page_allocator.create(RequestJob);
        job.* = .{
            .server = &server,
            .request_payload = request_payload,
        };

        const thread = try std.Thread.spawn(.{}, processRequestWorker, .{job});
        thread.detach();
    }
}

fn runSchedulerService(service: *scheduler.Service) void {
    service.run();
}

pub const LocalClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    state: *ClientState,
    stdin_mutex: std.Thread.Mutex = .{},
    reader_context: ?*ReaderContext = null,
    reader_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) !LocalClient {
        return initInWorkspace(allocator, null);
    }

    pub fn initInWorkspace(allocator: std.mem.Allocator, workspace_root: ?[]const u8) !LocalClient {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        var argv = [_][]const u8{ exe_path, "kernel-stdio" };
        var child = std.process.Child.init(&argv, allocator);
        child.cwd = workspace_root;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        errdefer {
            if (child.stdin) |*stdin_file| {
                stdin_file.close();
                child.stdin = null;
            }
            if (child.stdout) |*stdout_file| {
                stdout_file.close();
                child.stdout = null;
            }
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        const state = try allocator.create(ClientState);
        errdefer allocator.destroy(state);
        state.* = ClientState.init(allocator);
        errdefer state.deinit();

        const reader_context = try allocator.create(ReaderContext);
        errdefer allocator.destroy(reader_context);
        reader_context.* = .{
            .allocator = allocator,
            .stdout_file = child.stdout orelse return Error.MissingChildPipes,
            .state = state,
        };
        child.stdout = null;
        errdefer reader_context.stdout_file.close();

        var client = LocalClient{
            .allocator = allocator,
            .child = child,
            .state = state,
            .reader_context = reader_context,
        };

        const reader = try std.Thread.spawn(.{}, readerLoop, .{reader_context});
        client.reader_thread = reader;
        return client;
    }

    pub fn deinit(self: *LocalClient) void {
        if (self.child.stdin) |*stdin_file| {
            stdin_file.close();
            self.child.stdin = null;
        }

        _ = self.child.wait() catch {};

        if (self.reader_thread) |thread| thread.join();

        if (self.reader_context) |reader_context| {
            reader_context.stdout_file.close();
            self.allocator.destroy(reader_context);
            self.reader_context = null;
        }

        self.state.deinit();
        self.allocator.destroy(self.state);
    }

    pub fn call(self: *LocalClient, method: []const u8, params_json: []const u8) !RpcCallResult {
        if (self.child.stdin == null) return Error.MissingChildPipes;

        const request_number = self.state.nextRequestId();
        const request_id = try std.fmt.allocPrint(self.allocator, "req-{d}", .{request_number});
        defer self.allocator.free(request_id);

        const request_payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"{s}\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ request_id, method, params_json },
        );
        defer self.allocator.free(request_payload);

        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        try writeFrame(self.child.stdin.?, request_payload);

        const response_payload = try waitForResponse(self, request_id);
        defer self.allocator.free(response_payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_payload, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return Error.InvalidRpcResponse;
        const object = parsed.value.object;

        if (object.get("error")) |error_value| {
            return .{
                .error_json = try renderJsonAlloc(self.allocator, error_value),
            };
        }

        const result_value = object.get("result") orelse return Error.InvalidRpcResponse;
        return .{
            .result_json = try renderJsonAlloc(self.allocator, result_value),
        };
    }

    pub fn waitForNotificationAfter(
        self: *LocalClient,
        after_sequence: u64,
        timeout_ms: usize,
    ) !?Notification {
        const deadline_ms = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        while (true) {
            if (try takeNotificationAfter(self, after_sequence)) |notification| return notification;
            if (std.time.milliTimestamp() >= deadline_ms) return null;
            std.Thread.sleep(notification_poll_ms * std.time.ns_per_ms);
        }
    }
};

fn processRequestWorker(job: *RequestJob) void {
    defer std.heap.page_allocator.destroy(job);
    defer job.server.allocator.free(job.request_payload);

    const response_payload = processRequest(job.server, job.request_payload) catch return;
    if (response_payload) |payload| {
        defer job.server.allocator.free(payload);
        job.server.writePayload(payload) catch {};
    }
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
        try store.appendSessionMessage(server.allocator, server.config.workspace_root, session.id, .user, next_prompt, timestamp_ms);
        try store.setSessionPrompt(server.allocator, server.config.workspace_root, &session, next_prompt, .initialized);
    } else if (session.status == .completed or session.status == .failed or session.status == .cancelled) {
        const current_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
        defer if (current_output) |value| server.allocator.free(value);
        return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
            .session = makeSessionSummary(session, current_output),
        });
    }

    if (server.runtime.isRunning(session.id)) {
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
    };

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
            server.flushDeltaCoalesce() catch {};
            var cancelled = try store.readSessionRecord(server.allocator, server.config.workspace_root, session.id);
            defer cancelled.deinit(server.allocator);
            const cancelled_output = try store.readOutput(server.allocator, server.config.workspace_root, session.id);
            defer if (cancelled_output) |value| server.allocator.free(value);
            return renderJsonAlloc(server.allocator, protocol_types.SessionSendResult{
                .session = makeSessionSummary(cancelled, cancelled_output),
            });
        },
        else => {
            server.flushDeltaCoalesce() catch {};
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
    server.flushDeltaCoalesce() catch {};
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
        try server.recordAndEmitSessionEvent(
            session.id,
            "session_cancelled",
            "Cancellation requested before execution started.",
            types.statusLabel(session.status),
            session.updated_at_ms,
        );
    } else if (session.status == .running) {
        if (server.runtime.requestCancel(session.id)) {
            cancellation_requested = true;
        } else if (try isStaleUnownedRunningSession(server, &session)) {
            try store.setSessionStatus(server.allocator, server.config.workspace_root, &session, .cancelled);
            cancellation_requested = true;
            try server.recordAndEmitSessionEvent(
                session.id,
                "session_cancelled",
                "Cancellation closed a stale running session with no active kernel execution owner.",
                types.statusLabel(session.status),
                session.updated_at_ms,
            );
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

    const all_events = try store.readEvents(server.allocator, server.config.workspace_root, session.id);
    defer types.deinitSessionEvents(server.allocator, all_events);

    // Filter events by after_seq if provided — avoids re-transferring the
    // full event spine on every TUI poll. With 120+ reasoning deltas,
    // this is the difference between a responsive and frozen TUI.
    const events = blk: {
        if (after_seq) |min_seq| {
            var filtered = std.array_list.Managed(types.SessionEvent).init(server.allocator);
            defer filtered.deinit();
            for (all_events) |event| {
                if (event.seq > min_seq) {
                    try filtered.append(.{
                        .event_type = try server.allocator.dupe(u8, event.event_type),
                        .message = try server.allocator.dupe(u8, event.message),
                        .timestamp_ms = event.timestamp_ms,
                        .seq = event.seq,
                        .bytes_b64 = if (event.bytes_b64) |b| try server.allocator.dupe(u8, b) else null,
                    });
                }
            }
            break :blk try filtered.toOwnedSlice();
        }
        break :blk all_events;
    };
    defer if (after_seq != null) types.deinitSessionEvents(server.allocator, events);

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
    try server.recordAndEmitSessionEvent(session.id, "session_failed", failure_reason, "failed", timestamp_ms);
    try store.setSessionFailure(server.allocator, server.config.workspace_root, session, failure_reason);
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
    return renderJsonAlloc(server.allocator, protocol_types.HealthGetResult{
        .ok = true,
        .model = server.config.openai_model,
        .workspace_root = server.config.workspace_root,
        .base_url = server.config.openai_base_url,
        .auth_provider = server.config.auth_provider,
        .subscription_plan_label = server.config.subscription_plan_label,
        .subscription_status = server.config.subscription_status,
        .scheduler_supervisor = server.scheduler_thread != null,
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

    // Delta coalescing: consecutive assistant_delta / reasoning_delta events
    // are buffered into a single notification frame. A streaming turn emits
    // 50-200 token-sized deltas; without coalescing each one is a separate
    // Content-Length frame through the mutex-locked stdout pipe. Coalescing
    // turns ~100 frames into ~10, eliminating the per-frame round-trip.
    const is_delta = std.mem.eql(u8, event_type, "assistant_delta") or
        std.mem.eql(u8, event_type, "reasoning_delta");

    if (!is_delta) {
        // Flush any pending delta buffer before emitting a non-delta event.
        try server.flushDeltaCoalesce();
        try server.emitSessionEvent(session_id, event_type, message, status, timestamp_ms);
        return;
    }

    // Check if we need to flush the existing buffer first (different session,
    // different delta kind, or buffer is getting large / old).
    if (server.delta_coalesce_init and server.delta_coalesce_count > 0) {
        const kind_match = if (server.delta_coalesce_kind) |k| std.mem.eql(u8, k, event_type) else false;
        const session_match = if (server.delta_coalesce_session) |s| std.mem.eql(u8, s, session_id) else false;
        const buf_age = std.time.milliTimestamp() - server.delta_coalesce_first_ms;
        const buf_full = server.delta_coalesce_buf.items.len > 4096;
        const buf_old = buf_age > 80;
        if (!kind_match or !session_match or buf_full or buf_old) {
            try server.flushDeltaCoalesce();
        }
    }

    // Initialize buffer on first use.
    if (!server.delta_coalesce_init) {
        server.delta_coalesce_buf = std.array_list.Managed(u8).init(server.allocator);
        server.delta_coalesce_init = true;
    }

    // Start a new coalesce batch.
    if (server.delta_coalesce_count == 0) {
        if (server.delta_coalesce_session) |s| server.allocator.free(s);
        server.delta_coalesce_session = try server.allocator.dupe(u8, session_id);
        if (server.delta_coalesce_status) |s| server.allocator.free(s);
        server.delta_coalesce_status = try server.allocator.dupe(u8, status);
        if (server.delta_coalesce_kind) |k| server.allocator.free(k);
        server.delta_coalesce_kind = try server.allocator.dupe(u8, event_type);
        server.delta_coalesce_first_ms = timestamp_ms;
    }

    try server.delta_coalesce_buf.appendSlice(message);
    server.delta_coalesce_count += 1;
}

const delta_coalesce_max_batch: usize = 64;
const delta_coalesce_flush_ms: i64 = 80;

fn onLoopShouldCancel(ctx: ?*anyopaque, session_id: []const u8) bool {
    const server: *Server = @ptrCast(@alignCast(ctx.?));
    return server.runtime.shouldCancel(session_id);
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

fn waitForResponse(self: *LocalClient, request_id: []const u8) ![]u8 {
    while (true) {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();

        if (self.state.responses.fetchRemove(request_id)) |entry| {
            self.allocator.free(entry.key);
            return entry.value;
        }

        if (self.state.closed) {
            if (self.state.read_error) |read_error| return read_error;
            return Error.InvalidRpcResponse;
        }

        self.state.cond.wait(&self.state.mutex);
    }
}

fn takeNotificationAfter(self: *LocalClient, after_sequence: u64) !?Notification {
    self.state.mutex.lock();
    defer self.state.mutex.unlock();

    for (self.state.notifications.items) |notification| {
        if (notification.sequence <= after_sequence) continue;
        return .{
            .sequence = notification.sequence,
            .method = try self.allocator.dupe(u8, notification.method),
            .params_json = try self.allocator.dupe(u8, notification.params_json),
        };
    }

    if (self.state.closed) {
        if (self.state.read_error) |read_error| return read_error;
    }
    return null;
}

fn readerLoop(reader_context: *ReaderContext) void {
    const stdout_file = reader_context.stdout_file;

    while (true) {
        const payload = readFrame(reader_context.allocator, stdout_file) catch |err| {
            reader_context.state.recordClosure(err);
            return;
        } orelse {
            reader_context.state.recordClosure(null);
            return;
        };

        processIncomingFrame(reader_context, payload) catch |err| {
            reader_context.allocator.free(payload);
            reader_context.state.recordClosure(err);
            return;
        };
    }
}

fn processIncomingFrame(reader_context: *ReaderContext, payload: []u8) !void {
    errdefer reader_context.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, reader_context.allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidRpcResponse;
    const object = parsed.value.object;

    if (object.get("method")) |method_value| {
        if (method_value != .string) return Error.InvalidRpcResponse;
        const params_json = if (object.get("params")) |params_value|
            try renderJsonAlloc(reader_context.allocator, params_value)
        else
            try reader_context.allocator.dupe(u8, "null");
        errdefer reader_context.allocator.free(params_json);

        try reader_context.state.recordNotification(method_value.string, params_json);
        reader_context.allocator.free(payload);
        return;
    }

    const request_id = (try extractRequestId(object)) orelse return Error.InvalidRpcResponse;
    try reader_context.state.recordResponse(request_id, payload);
}

fn renderSuccessResponse(
    allocator: std.mem.Allocator,
    id: []const u8,
    result_payload: []const u8,
) ![]u8 {
    const id_payload = try renderJsonAlloc(allocator, id);
    defer allocator.free(id_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_payload, result_payload },
    );
}

fn renderErrorResponse(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) ![]u8 {
    const id_payload = if (id) |value|
        try renderJsonAlloc(allocator, value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_payload);

    const error_payload = try renderJsonAlloc(allocator, .{
        .code = code,
        .message = message,
    });
    defer allocator.free(error_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}",
        .{ id_payload, error_payload },
    );
}

fn errorResponseOrNull(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    code: i32,
    message: []const u8,
) !?[]u8 {
    if (id) |request_id| {
        const response = try renderErrorResponse(allocator, request_id, code, message);
        return response;
    }

    return null;
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

fn writeFrame(file: std.fs.File, payload: []const u8) !void {
    var write_buffer: [4096]u8 = undefined;
    var writer = file.writer(&write_buffer);
    try writer.interface.print("Content-Length: {d}\r\n\r\n", .{payload.len});
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try readHeaderLine(allocator, file);
        if (line == null) {
            if (content_length == null) return null;
            return Error.InvalidFrame;
        }
        defer allocator.free(line.?);

        const trimmed = std.mem.trimRight(u8, line.?, "\r\n");
        if (trimmed.len == 0) break;

        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const value_text = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, value_text, 10) catch return Error.InvalidFrame;
        }
    }

    const expected_len = content_length orelse return Error.InvalidFrame;
    const payload = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(payload);
    try readExactly(file, payload);
    return payload;
}

fn readHeaderLine(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var line = std.array_list.Managed(u8).init(allocator);
    errdefer line.deinit();

    while (true) {
        var byte: [1]u8 = undefined;
        const read_len = try file.read(&byte);
        if (read_len == 0) {
            if (line.items.len == 0) {
                line.deinit();
                return null;
            }
            return Error.InvalidFrame;
        }

        try line.append(byte[0]);
        if (byte[0] == '\n') return try line.toOwnedSlice();
        if (line.items.len > max_header_line_bytes) return Error.InvalidFrame;
    }
}

fn readExactly(file: std.fs.File, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const read_len = try file.read(buffer[offset..]);
        if (read_len == 0) return Error.InvalidFrame;
        offset += read_len;
    }
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

fn appendStaleStartedEvent(workspace_root: []const u8, session_id: []const u8) !void {
    try store.appendEvent(std.testing.allocator, workspace_root, session_id, .{
        .event_type = "session_started",
        .message = "VAR1 session initialized.",
        .timestamp_ms = std.time.milliTimestamp() - stale_running_session_ms - 1,
    });
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
