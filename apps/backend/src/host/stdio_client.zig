const std = @import("std");
const json = @import("../shared/json.zig");
const wire = @import("stdio_wire.zig");

/// Client side of the VAR1 stdio JSON-RPC protocol. Extracted from
/// stdio_rpc.zig for seam isolation: the client (used by cli.zig and
/// http_bridge.zig to drive the kernel as a subprocess) is fully separable
/// from the server (dispatch, handlers, worker pool).
///
/// The client spawns a child `vantari kernel-stdio` process, writes framed
/// JSON-RPC requests to its stdin, and reads framed responses/notifications
/// from its stdout on a dedicated reader thread.

pub const Error = error{
    MissingChildPipes,
    InvalidRpcResponse,
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

const max_notification_backlog = 512;
const notification_poll_ms: u64 = 50;

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
        // Preserve kernel diagnostics for provider and startup failures; stderr is
        // separate from the framed stdout protocol and does not corrupt RPC data.
        child.stderr_behavior = .Inherit;
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

        const request_payload = try renderRpcRequest(self.allocator, request_id, method, params_json);
        defer self.allocator.free(request_payload);

        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        try wire.writeFrame(self.child.stdin.?, request_payload);

        const response_payload = try waitForResponse(self, request_id);
        defer self.allocator.free(response_payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_payload, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return Error.InvalidRpcResponse;
        const object = parsed.value.object;

        if (object.get("error")) |error_value| {
            return .{
                .error_json = try json.renderAlloc(self.allocator, error_value),
            };
        }

        const result_value = object.get("result") orelse return Error.InvalidRpcResponse;
        return .{
            .result_json = try json.renderAlloc(self.allocator, result_value),
        };
    }

    pub fn notify(self: *LocalClient, method: []const u8, params_json: []const u8) !void {
        if (self.child.stdin == null) return Error.MissingChildPipes;

        const request_payload = try renderRpcNotification(self.allocator, method, params_json);
        defer self.allocator.free(request_payload);

        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        try wire.writeFrame(self.child.stdin.?, request_payload);
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

pub fn renderRpcRequest(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const id_json = try json.renderAlloc(allocator, request_id);
    defer allocator.free(id_json);
    const method_json = try json.renderAlloc(allocator, method);
    defer allocator.free(method_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"method\":{s},\"params\":{s}}}",
        .{ id_json, method_json, params_json },
    );
}

fn renderRpcNotification(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
) ![]u8 {
    const method_json = try json.renderAlloc(allocator, method);
    defer allocator.free(method_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"method\":{s},\"params\":{s}}}",
        .{ method_json, params_json },
    );
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
        const payload = wire.readFrame(reader_context.allocator, stdout_file) catch |err| {
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
            try json.renderAlloc(reader_context.allocator, params_value)
        else
            try reader_context.allocator.dupe(u8, "null");
        errdefer reader_context.allocator.free(params_json);

        try reader_context.state.recordNotification(method_value.string, params_json);
        reader_context.allocator.free(payload);
        return;
    }

    const request_id = extractRequestId(object) orelse return Error.InvalidRpcResponse;
    try reader_context.state.recordResponse(request_id, payload);
}

fn extractRequestId(object: std.json.ObjectMap) ?[]const u8 {
    const value = object.get("id") orelse return null;
    if (value != .string) return null;
    return value.string;
}
