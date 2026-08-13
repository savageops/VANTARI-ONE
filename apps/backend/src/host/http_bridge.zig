const std = @import("std");
const bridge_access = @import("bridge_access.zig");
const owner_state = @import("owner_state.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const stdio_rpc = @import("stdio_rpc.zig");
const types = @import("../shared/types.zig");

const max_request_body_bytes = 256 * 1024;
const connection_read_buffer_size = 16 * 1024;
const connection_write_buffer_size = 16 * 1024;
const max_active_connections: usize = 64;
const sse_poll_timeout_ms: usize = 1000;
pub const test_bridge_token = "test-bridge-token";
pub const test_owner_token = "test-owner-token";
pub const test_owner_generation = "test-owner-generation";
pub const owner_schema_version = owner_state.schema_version;
pub const owner_protocol_version = owner_state.protocol_version;

const Disclosure = enum {
    browser_redacted,
    owner_exact,
};

const ConnectionJob = struct {
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    lifecycle: *OwnerLifecycle,
    connection: std.net.Server.Connection,
};

const OwnerLifecycle = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    wake_address: std.net.Address,
    active_connections: usize = 0,
    stopping: bool = false,

    fn tryAcquire(self: *OwnerLifecycle) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or self.active_connections >= max_active_connections) return false;
        self.active_connections += 1;
        return true;
    }

    fn release(self: *OwnerLifecycle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.active_connections > 0);
        self.active_connections -= 1;
        if (self.active_connections == 0) self.condition.broadcast();
    }

    fn requestShutdown(self: *OwnerLifecycle) void {
        self.mutex.lock();
        if (self.stopping) {
            self.mutex.unlock();
            return;
        }
        self.stopping = true;
        const wake_address = self.wake_address;
        self.mutex.unlock();

        var wake_stream = std.net.tcpConnectToAddress(wake_address) catch return;
        wake_stream.close();
    }

    fn isStopping(self: *OwnerLifecycle) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stopping;
    }

    fn drain(self: *OwnerLifecycle) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.active_connections != 0) self.condition.wait(&self.mutex);
    }
};

pub const ServeOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4310,
    transport: provider.Transport,
    publish_owner: bool = false,
    announce_listener: bool = true,
};

pub const KernelBridge = struct {
    context: ?*anyopaque,
    callFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) anyerror!stdio_rpc.RpcCallResult,
    waitNotificationAfterFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        after_sequence: u64,
        timeout_ms: usize,
    ) anyerror!?stdio_rpc.Notification,
    beginShutdownFn: ?*const fn (ctx: ?*anyopaque) void = null,
    deinitFn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) void = null,

    pub fn call(
        self: KernelBridge,
        allocator: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
    ) anyerror!stdio_rpc.RpcCallResult {
        return self.callFn(self.context, allocator, method, params_json);
    }

    pub fn waitNotificationAfter(
        self: KernelBridge,
        allocator: std.mem.Allocator,
        after_sequence: u64,
        timeout_ms: usize,
    ) anyerror!?stdio_rpc.Notification {
        return self.waitNotificationAfterFn(self.context, allocator, after_sequence, timeout_ms);
    }

    pub fn deinit(self: KernelBridge, allocator: std.mem.Allocator) void {
        if (self.deinitFn) |deinit_fn| deinit_fn(self.context, allocator);
    }

    pub fn beginShutdown(self: KernelBridge) void {
        if (self.beginShutdownFn) |begin_shutdown_fn| begin_shutdown_fn(self.context);
    }
};

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    kernel: KernelBridge,
    workspace_root: []const u8,
    token_storage: [64]u8 = undefined,
    token_len: usize = 0,
    owner_token_storage: [64]u8 = undefined,
    owner_token_len: usize = 0,
    owner_generation_storage: [64]u8 = undefined,
    owner_generation_len: usize = 0,

    pub fn initLocal(allocator: std.mem.Allocator, workspace_root: []const u8) !Bridge {
        const client = try allocator.create(stdio_rpc.ChildClient);
        errdefer allocator.destroy(client);
        client.* = try stdio_rpc.ChildClient.initInWorkspace(allocator, workspace_root);
        errdefer client.deinit();

        var bridge = Bridge{
            .allocator = allocator,
            .kernel = .{
                .context = client,
                .callFn = localKernelCall,
                .waitNotificationAfterFn = localKernelWaitNotificationAfter,
                .beginShutdownFn = localKernelBeginShutdown,
                .deinitFn = localKernelDeinit,
            },
            .workspace_root = workspace_root,
        };
        bridge.initRandomToken();
        bridge.initRandomOwnerIdentity();

        const subscribe_call = try bridge.kernel.call(allocator, protocol_types.methods.events_subscribe, "{}");
        defer subscribe_call.deinit(allocator);
        const subscribe_result = try expectKernelResult(allocator, subscribe_call);
        defer allocator.free(subscribe_result);

        return bridge;
    }

    pub fn initWithKernel(allocator: std.mem.Allocator, kernel: KernelBridge, workspace_root: []const u8) Bridge {
        var bridge = Bridge{
            .allocator = allocator,
            .kernel = kernel,
            .workspace_root = workspace_root,
        };
        bridge.setToken(test_bridge_token);
        bridge.setOwnerIdentity(test_owner_token, test_owner_generation);
        return bridge;
    }

    pub fn deinit(self: *Bridge) void {
        self.kernel.deinit(self.allocator);
    }

    pub fn bridgeToken(self: *const Bridge) []const u8 {
        return self.token_storage[0..self.token_len];
    }

    pub fn ownerToken(self: *const Bridge) []const u8 {
        return self.owner_token_storage[0..self.owner_token_len];
    }

    pub fn ownerGeneration(self: *const Bridge) []const u8 {
        return self.owner_generation_storage[0..self.owner_generation_len];
    }

    fn setToken(self: *Bridge, token: []const u8) void {
        std.debug.assert(token.len <= self.token_storage.len);
        @memcpy(self.token_storage[0..token.len], token);
        self.token_len = token.len;
    }

    fn initRandomToken(self: *Bridge) void {
        self.token_len = fillRandomHex(&self.token_storage, 24);
    }

    fn setOwnerIdentity(self: *Bridge, token: []const u8, generation: []const u8) void {
        std.debug.assert(token.len <= self.owner_token_storage.len);
        std.debug.assert(generation.len <= self.owner_generation_storage.len);
        @memcpy(self.owner_token_storage[0..token.len], token);
        @memcpy(self.owner_generation_storage[0..generation.len], generation);
        self.owner_token_len = token.len;
        self.owner_generation_len = generation.len;
    }

    fn initRandomOwnerIdentity(self: *Bridge) void {
        self.owner_token_len = fillRandomHex(&self.owner_token_storage, 24);
        self.owner_generation_len = fillRandomHex(&self.owner_generation_storage, 16);
    }
};

fn fillRandomHex(storage: []u8, byte_count: usize) usize {
    std.debug.assert(byte_count * 2 <= storage.len);
    var bytes: [32]u8 = undefined;
    std.debug.assert(byte_count <= bytes.len);
    std.crypto.random.bytes(bytes[0..byte_count]);
    const alphabet = "0123456789abcdef";
    for (bytes[0..byte_count], 0..) |byte, index| {
        storage[index * 2] = alphabet[byte >> 4];
        storage[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return byte_count * 2;
}

const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []u8,
    cors_origin: []const u8 = bridge_access.default_cors_origin,
    shutdown: bool = false,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub fn serve(allocator: std.mem.Allocator, config: types.Config, options: ServeOptions) !void {
    const address = try std.net.Address.parseIp(options.host, options.port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const listening_port = listener.listen_address.getPort();
    var lifecycle = OwnerLifecycle{ .wake_address = listener.listen_address };

    var bridge = try Bridge.initLocal(allocator, config.workspace_root);
    defer bridge.deinit();

    if (options.publish_owner) {
        const readiness = try callKernelResult(allocator, &bridge, protocol_types.methods.health_get, "{}");
        defer allocator.free(readiness);
        const executable_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(executable_path);
        try owner_state.write(allocator, .{
            .generation = bridge.ownerGeneration(),
            .pid = owner_state.currentPid(),
            .port = listening_port,
            .token = bridge.ownerToken(),
            .workspace_root = config.workspace_root,
            .executable_path = executable_path,
            .started_at_ms = std.time.milliTimestamp(),
        });
    }

    if (options.announce_listener) {
        var stdout_buffer: [256]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        try stdout_writer.interface.print(
            "VAR1 bridge listening on http://{s}:{d}\n",
            .{ options.host, listening_port },
        );
        try stdout_writer.interface.flush();
    }

    while (true) {
        var connection = try listener.accept();
        if (!lifecycle.tryAcquire()) {
            connection.stream.close();
            if (lifecycle.isStopping()) break;
            continue;
        }
        const job = allocator.create(ConnectionJob) catch |err| {
            connection.stream.close();
            lifecycle.release();
            bridge_access.logError("http_connection_alloc", null, err);
            continue;
        };
        job.* = .{
            .allocator = allocator,
            .bridge = &bridge,
            .lifecycle = &lifecycle,
            .connection = connection,
        };

        const thread = std.Thread.spawn(.{}, handleConnectionJob, .{job}) catch |err| {
            job.connection.stream.close();
            allocator.destroy(job);
            lifecycle.release();
            bridge_access.logError("http_connection_spawn", null, err);
            continue;
        };
        thread.detach();
    }
    lifecycle.drain();
}

fn handleConnectionJob(job: *ConnectionJob) void {
    const allocator = job.allocator;
    const lifecycle = job.lifecycle;
    defer {
        lifecycle.release();
        allocator.destroy(job);
    }
    handleConnection(job.allocator, job.bridge, job.lifecycle, &job.connection) catch |err| {
        bridge_access.logError("http_connection", null, err);
    };
}

pub fn route(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) !Response {
    return routeWithOwnerAccess(allocator, bridge, method, target, body, null, null, null);
}

pub fn routeWithAccess(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    origin: ?[]const u8,
    bridge_token: ?[]const u8,
) !Response {
    return routeWithOwnerAccess(allocator, bridge, method, target, body, origin, bridge_token, null);
}

pub fn routeWithOwnerAccess(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    origin: ?[]const u8,
    bridge_token: ?[]const u8,
    owner_token: ?[]const u8,
) !Response {
    return routeBridge(allocator, bridge, method, target, body, origin, bridge_token, owner_token);
}

fn handleConnection(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    lifecycle: *OwnerLifecycle,
    connection: *std.net.Server.Connection,
) !void {
    defer connection.stream.close();

    var read_buffer: [connection_read_buffer_size]u8 = undefined;
    var write_buffer: [connection_write_buffer_size]u8 = undefined;
    var reader = connection.stream.reader(&read_buffer);
    var writer = connection.stream.writer(&write_buffer);
    var server = std.http.Server.init(reader.interface(), &writer.interface);

    var request = server.receiveHead() catch return;

    const target = try allocator.dupe(u8, request.head.target);
    defer allocator.free(target);

    const origin = requestHeader(&request, "origin");
    const bridge_token = requestHeader(&request, "x-var1-bridge-token");
    const owner_token = requestHeader(&request, "x-var1-owner-token");

    const body = try readRequestBody(allocator, &request);
    defer allocator.free(body);

    const response = routeBridge(allocator, bridge, request.head.method, target, body, origin, bridge_token, owner_token) catch |err| {
        const failure = try jsonErrorResponse(allocator, .internal_server_error, "InternalServerError");
        defer failure.deinit(allocator);
        bridge_access.logError("bridge_route", null, err);
        try respond(&request, failure);
        return;
    };
    defer response.deinit(allocator);

    try respond(&request, response);
    if (response.shutdown) {
        bridge.kernel.beginShutdown();
        lifecycle.requestShutdown();
    }
}

fn routeBridge(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    origin: ?[]const u8,
    bridge_token: ?[]const u8,
    owner_token: ?[]const u8,
) !Response {
    const path = requestPath(target);
    const cors_origin = bridge_access.allowedCorsOrigin(origin) orelse {
        return jsonErrorResponseWithCors(allocator, .forbidden, "ForbiddenOrigin", bridge_access.default_cors_origin);
    };

    if (method == .OPTIONS) {
        return .{
            .status = .no_content,
            .content_type = "text/plain; charset=utf-8",
            .body = try allocator.dupe(u8, ""),
            .cors_origin = cors_origin,
        };
    }

    const owner_route = std.mem.eql(u8, path, "/owner/health") or
        std.mem.eql(u8, path, "/owner/rpc") or
        std.mem.eql(u8, path, "/owner/events") or
        std.mem.eql(u8, path, "/owner/shutdown");
    if (owner_route and !bridge_access.tokenValid(bridge.ownerToken(), owner_token)) {
        return jsonErrorResponseWithCors(allocator, .unauthorized, "OwnerTokenRequired", cors_origin);
    }

    if (bridge_access.isTokenRequired(method, path) and !bridge_access.tokenValid(bridge.bridgeToken(), bridge_token)) {
        return jsonErrorResponseWithCors(allocator, .unauthorized, "BridgeTokenRequired", cors_origin);
    }

    if (method == .GET and std.mem.eql(u8, path, "/")) {
        return .{
            .status = .ok,
            .content_type = "text/plain; charset=utf-8",
            .body = try allocator.dupe(u8, "VAR1 HTTP bridge ready. Use POST /rpc, GET /events, or the external client in apps/frontend/var1-client.\n"),
            .cors_origin = cors_origin,
        };
    }

    if (method == .POST and std.mem.eql(u8, path, "/rpc")) {
        var response = try forwardRpcRequest(allocator, bridge, body, .browser_redacted);
        response.cors_origin = cors_origin;
        return response;
    }

    if (method == .GET and std.mem.eql(u8, path, "/events")) {
        var response = try renderEventSnapshotResponse(allocator, bridge, target, .browser_redacted);
        response.cors_origin = cors_origin;
        return response;
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/health")) {
        const result_json = try callKernelResult(allocator, bridge, protocol_types.methods.health_get, "{}");
        defer allocator.free(result_json);
        const health_json = try bridge_access.redactAndAttachHandshake(allocator, result_json, bridge.bridgeToken());
        defer allocator.free(health_json);
        return jsonResponseWithCors(allocator, .ok, health_json, cors_origin);
    }

    if (method == .GET and std.mem.eql(u8, path, "/owner/health")) {
        const kernel_json = try callKernelResult(allocator, bridge, protocol_types.methods.health_get, "{}");
        defer allocator.free(kernel_json);
        const health_json = try std.fmt.allocPrint(
            allocator,
            "{{\"schema\":{f},\"protocol\":{f},\"generation\":{f},\"workspace_root\":{f},\"kernel\":{s}}}",
            .{
                std.json.fmt(owner_schema_version, .{}),
                std.json.fmt(owner_protocol_version, .{}),
                std.json.fmt(bridge.ownerGeneration(), .{}),
                std.json.fmt(bridge.workspace_root, .{}),
                kernel_json,
            },
        );
        defer allocator.free(health_json);
        return jsonResponseWithCors(allocator, .ok, health_json, cors_origin);
    }

    if (method == .POST and std.mem.eql(u8, path, "/owner/rpc")) {
        var response = try forwardRpcRequest(allocator, bridge, body, .owner_exact);
        response.cors_origin = cors_origin;
        return response;
    }

    if (method == .GET and std.mem.eql(u8, path, "/owner/events")) {
        var response = try renderEventSnapshotResponse(allocator, bridge, target, .owner_exact);
        response.cors_origin = cors_origin;
        return response;
    }

    if (method == .POST and std.mem.eql(u8, path, "/owner/shutdown")) {
        const shutdown_json = try std.fmt.allocPrint(
            allocator,
            "{{\"type\":\"var1.owner_shutdown.v1\",\"status\":\"accepted\",\"generation\":{f}}}",
            .{std.json.fmt(bridge.ownerGeneration(), .{})},
        );
        defer allocator.free(shutdown_json);
        var response = try jsonResponseWithCors(allocator, .accepted, shutdown_json, cors_origin);
        response.shutdown = true;
        return response;
    }

    return jsonErrorResponseWithCors(allocator, .not_found, "NotFound", cors_origin);
}

fn forwardRpcRequest(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    body: []const u8,
    disclosure: Disclosure,
) !Response {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");
    };
    defer parsed.deinit();

    if (parsed.value != .object) return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");
    const object = parsed.value.object;

    const jsonrpc_value = object.get("jsonrpc") orelse return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");
    if (jsonrpc_value != .string or !std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
        return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");
    }

    const method_value = object.get("method") orelse return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");
    if (method_value != .string) return jsonErrorResponse(allocator, .bad_request, "InvalidJsonRpc");

    const id_json = if (object.get("id")) |id_value|
        try renderJsonAlloc(allocator, id_value)
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_json);

    const params_json = if (object.get("params")) |params_value|
        try renderJsonAlloc(allocator, params_value)
    else
        try allocator.dupe(u8, "{}");
    defer allocator.free(params_json);

    const audit_session_id = try bridge_access.extractSessionId(allocator, params_json);
    defer if (audit_session_id) |value| allocator.free(value);
    try bridge_access.appendAuditEvent(allocator, bridge.workspace_root, method_value.string, audit_session_id);

    const call = try bridge.kernel.call(allocator, method_value.string, params_json);
    defer call.deinit(allocator);

    const body_json = if (call.error_json) |error_json|
        try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}",
            .{ id_json, error_json },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
            .{ id_json, call.result_json orelse "null" },
        );
    defer allocator.free(body_json);

    const response_body_json = switch (disclosure) {
        .browser_redacted => try bridge_access.redactJsonPayload(allocator, body_json),
        .owner_exact => try allocator.dupe(u8, body_json),
    };

    return .{
        .status = .ok,
        .content_type = "application/json; charset=utf-8",
        .body = response_body_json,
    };
}

fn renderEventSnapshotResponse(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    target: []const u8,
    disclosure: Disclosure,
) !Response {
    const after_sequence = parseSinceQuery(target);
    const notification = try bridge.kernel.waitNotificationAfter(allocator, after_sequence, parseWaitQuery(target));
    defer if (notification) |value| value.deinit(allocator);

    const body = if (notification) |event|
        try renderSseEvent(allocator, event, disclosure)
    else
        try allocator.dupe(u8, ": keepalive\n\n");

    return .{
        .status = .ok,
        .content_type = "text/event-stream; charset=utf-8",
        .body = body,
    };
}

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    if (!request.head.method.requestHasBody()) return allocator.dupe(u8, "");

    var body_buffer: [4096]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buffer);
    return reader.allocRemaining(allocator, .limited(max_request_body_bytes));
}

fn respond(request: *std.http.Server.Request, response: Response) !void {
    const headers = [_]std.http.Header{
        .{ .name = "content-type", .value = response.content_type },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "access-control-allow-origin", .value = response.cors_origin },
        .{ .name = "access-control-allow-headers", .value = "content-type,last-event-id,x-var1-bridge-token" },
        .{ .name = "access-control-allow-methods", .value = "GET,POST,OPTIONS" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    };

    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = &headers,
    });
}

fn requestPath(target: []const u8) []const u8 {
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..query_index];
}

fn requestHeader(request: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn parseSinceQuery(target: []const u8) u64 {
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse return 0;
    const query = target[query_index + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "since=")) continue;
        return std.fmt.parseInt(u64, entry["since=".len..], 10) catch 0;
    }
    return 0;
}

fn parseWaitQuery(target: []const u8) usize {
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse return sse_poll_timeout_ms;
    const query = target[query_index + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "wait_ms=")) continue;
        const requested = std.fmt.parseInt(usize, entry["wait_ms=".len..], 10) catch return 0;
        return @min(requested, sse_poll_timeout_ms);
    }
    return sse_poll_timeout_ms;
}

fn renderSseEvent(
    allocator: std.mem.Allocator,
    notification: stdio_rpc.Notification,
    disclosure: Disclosure,
) ![]u8 {
    const params_json = switch (disclosure) {
        .browser_redacted => try bridge_access.redactJsonPayload(allocator, notification.params_json),
        .owner_exact => try allocator.dupe(u8, notification.params_json),
    };
    defer allocator.free(params_json);

    return std.fmt.allocPrint(
        allocator,
        "id: {d}\nevent: {s}\ndata: {s}\n\n",
        .{ notification.sequence, notification.method, params_json },
    );
}

fn jsonResponse(allocator: std.mem.Allocator, status: std.http.Status, payload_json: []const u8) !Response {
    return jsonResponseWithCors(allocator, status, payload_json, bridge_access.default_cors_origin);
}

fn jsonResponseWithCors(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    payload_json: []const u8,
    cors_origin: []const u8,
) !Response {
    return .{
        .status = status,
        .content_type = "application/json; charset=utf-8",
        .body = try allocator.dupe(u8, payload_json),
        .cors_origin = cors_origin,
    };
}

fn jsonSuccess(allocator: std.mem.Allocator, status: std.http.Status, payload: anytype) !Response {
    return .{
        .status = status,
        .content_type = "application/json; charset=utf-8",
        .body = try renderJsonAlloc(allocator, payload),
    };
}

fn jsonErrorResponse(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    error_code: []const u8,
) !Response {
    return jsonSuccess(allocator, status, .{
        .ok = false,
        .@"error" = error_code,
    });
}

fn jsonErrorResponseWithCors(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    error_code: []const u8,
    cors_origin: []const u8,
) !Response {
    var response = try jsonErrorResponse(allocator, status, error_code);
    response.cors_origin = cors_origin;
    return response;
}

fn callKernelResult(
    allocator: std.mem.Allocator,
    bridge: *Bridge,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const call = try bridge.kernel.call(allocator, method, params_json);
    defer call.deinit(allocator);
    return expectKernelResult(allocator, call);
}

fn expectKernelResult(allocator: std.mem.Allocator, call: stdio_rpc.RpcCallResult) ![]u8 {
    if (call.error_json) |_| return error.KernelRpcError;
    return allocator.dupe(u8, call.result_json orelse return error.KernelRpcError);
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

fn localKernelCall(
    ctx: ?*anyopaque,
    _: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) anyerror!stdio_rpc.RpcCallResult {
    var client: *stdio_rpc.ChildClient = @ptrCast(@alignCast(ctx.?));
    return client.call(method, params_json);
}

fn localKernelWaitNotificationAfter(
    ctx: ?*anyopaque,
    _: std.mem.Allocator,
    after_sequence: u64,
    timeout_ms: usize,
) anyerror!?stdio_rpc.Notification {
    var client: *stdio_rpc.ChildClient = @ptrCast(@alignCast(ctx.?));
    return client.waitForNotificationAfter(after_sequence, timeout_ms);
}

fn localKernelBeginShutdown(ctx: ?*anyopaque) void {
    var client: *stdio_rpc.ChildClient = @ptrCast(@alignCast(ctx.?));
    client.beginShutdown();
}

fn localKernelDeinit(ctx: ?*anyopaque, allocator: std.mem.Allocator) void {
    var client: *stdio_rpc.ChildClient = @ptrCast(@alignCast(ctx.?));
    client.deinit();
    allocator.destroy(client);
}
