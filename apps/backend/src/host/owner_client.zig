const builtin = @import("builtin");
const std = @import("std");
const workspace = @import("../core/config/workspace.zig");
const process_tree = @import("../shared/process_tree.zig");
const owner_state = @import("owner_state.zig");
const stdio_client = @import("stdio_client.zig");

const owner_start_timeout_ms: usize = 20_000;
const owner_resolution_timeout_ms: usize = owner_start_timeout_ms + 5_000;
const owner_start_poll_ms: u64 = 25;
const owner_event_poll_cap_ms: usize = 1_000;
const owner_health_timeout_ms: usize = 2_000;
const owner_transport_slack_ms: usize = 1_000;
const small_response_bytes: usize = 256 * 1024;
const rpc_response_bytes: usize = 8 * 1024 * 1024;

extern "kernel32" fn IsProcessInJob(
    process_handle: std.os.windows.HANDLE,
    job_handle: ?std.os.windows.HANDLE,
    result: *std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn ResumeThread(thread_handle: std.os.windows.HANDLE) callconv(.winapi) std.os.windows.DWORD;

pub const Error = error{
    InvalidOwnerHealth,
    InvalidOwnerEvent,
    OwnerHttpRejected,
    OwnerResponseTooLarge,
    OwnerJobConstrained,
    OwnerJobProbeFailed,
    OwnerStartFailed,
    OwnerStartTimeout,
    OwnerUnavailable,
    PersistentOwnerUnsupported,
    UnsupportedRpcTimeout,
};

const OwnerHealth = struct {
    schema: []const u8,
    protocol: []const u8,
    generation: []const u8,
    workspace_root: []const u8,
    kernel: std.json.Value,
};

/// Presentation facade for the one project-local execution owner. A facade
/// owns no child kernel and deinit never changes owner lifetime.
pub const LocalClient = struct {
    allocator: std.mem.Allocator,
    workspace_root: []u8,
    owner: owner_state.Snapshot,
    next_request_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    pub fn init(allocator: std.mem.Allocator) !LocalClient {
        return initInWorkspace(allocator, null);
    }

    pub fn initInWorkspace(allocator: std.mem.Allocator, workspace_root: ?[]const u8) !LocalClient {
        const resolved = if (workspace_root) |explicit|
            try std.fs.cwd().realpathAlloc(allocator, explicit)
        else
            try workspace.resolve(allocator);
        errdefer allocator.free(resolved);

        const owner = try ensureOwner(allocator, resolved);
        return .{
            .allocator = allocator,
            .workspace_root = resolved,
            .owner = owner,
        };
    }

    pub fn deinit(self: *LocalClient) void {
        self.owner.deinit();
        self.allocator.free(self.workspace_root);
        self.* = undefined;
    }

    pub fn call(self: *LocalClient, method: []const u8, params_json: []const u8) !stdio_client.RpcCallResult {
        return self.callWithTimeout(method, params_json, stdio_client.timeoutForMethod(method));
    }

    pub fn callWithTimeout(
        self: *LocalClient,
        method: []const u8,
        params_json: []const u8,
        timeout_ms: usize,
    ) !stdio_client.RpcCallResult {
        // The owner-side ChildClient owns the canonical per-method deadline.
        // Reject divergent deadlines instead of pretending std.http enforces one.
        if (timeout_ms != stdio_client.timeoutForMethod(method)) return Error.UnsupportedRpcTimeout;

        const request_number = self.next_request_id.fetchAdd(1, .monotonic);
        const request_id = try std.fmt.allocPrint(self.allocator, "owner-{d}", .{request_number});
        defer self.allocator.free(request_id);
        const payload = try stdio_client.renderRpcRequest(self.allocator, request_id, method, params_json);
        defer self.allocator.free(payload);
        const response = try request(
            self.allocator,
            self.owner,
            .POST,
            "/owner/rpc",
            payload,
            rpc_response_bytes,
            transportTimeout(timeout_ms),
        );
        defer self.allocator.free(response);
        return stdio_client.parseRpcCallResult(self.allocator, response);
    }

    pub fn notify(self: *LocalClient, method: []const u8, params_json: []const u8) !void {
        const payload = try stdio_client.renderRpcNotification(self.allocator, method, params_json);
        defer self.allocator.free(payload);
        const response = try request(
            self.allocator,
            self.owner,
            .POST,
            "/owner/rpc",
            payload,
            small_response_bytes,
            transportTimeout(stdio_client.timeoutForMethod(method)),
        );
        self.allocator.free(response);
    }

    pub fn waitForNotificationAfter(
        self: *LocalClient,
        after_sequence: u64,
        timeout_ms: usize,
    ) !?stdio_client.Notification {
        var timer = try std.time.Timer.start();
        while (true) {
            const elapsed_ms: usize = @intCast(@min(timer.read() / std.time.ns_per_ms, std.math.maxInt(usize)));
            const wait_ms = @min(timeout_ms -| elapsed_ms, owner_event_poll_cap_ms);
            const path = try std.fmt.allocPrint(
                self.allocator,
                "/owner/events?since={d}&wait_ms={d}",
                .{ after_sequence, wait_ms },
            );
            const response = request(
                self.allocator,
                self.owner,
                .GET,
                path,
                null,
                small_response_bytes,
                transportTimeout(wait_ms),
            ) catch |err| {
                self.allocator.free(path);
                return err;
            };
            self.allocator.free(path);
            const notification = parseEventPayload(self.allocator, response) catch |err| {
                self.allocator.free(response);
                return err;
            };
            self.allocator.free(response);
            if (notification) |event| return event;
            if (timeout_ms == 0 or timer.read() / std.time.ns_per_ms >= timeout_ms) return null;
        }
    }
};

fn ensureOwner(allocator: std.mem.Allocator, workspace_root: []const u8) !owner_state.Snapshot {
    var timer = try std.time.Timer.start();
    while (true) {
        if (readHealthyOwner(allocator, workspace_root)) |snapshot| return snapshot else |_| {}

        var start_lock = owner_state.acquireStartLock(allocator, workspace_root, 0) catch |err| switch (err) {
            error.OwnerLockUnavailable => {
                if (timer.read() / std.time.ns_per_ms >= owner_resolution_timeout_ms) return Error.OwnerStartTimeout;
                std.Thread.sleep(owner_start_poll_ms * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };

        if (readHealthyOwner(allocator, workspace_root)) |snapshot| {
            start_lock.deinit();
            return snapshot;
        } else |_| {}

        const lease_available = owner_state.ownerLeaseAvailable(allocator, workspace_root) catch |err| {
            start_lock.deinit();
            return err;
        };
        if (lease_available) {
            const snapshot = spawnOwner(allocator, workspace_root) catch |err| {
                start_lock.deinit();
                return err;
            };
            start_lock.deinit();
            return snapshot;
        }
        start_lock.deinit();

        if (timer.read() / std.time.ns_per_ms >= owner_resolution_timeout_ms) return Error.OwnerUnavailable;
        std.Thread.sleep(owner_start_poll_ms * std.time.ns_per_ms);
    }
}

fn readHealthyOwner(allocator: std.mem.Allocator, workspace_root: []const u8) !owner_state.Snapshot {
    const snapshot = try owner_state.read(allocator, workspace_root);
    errdefer snapshot.deinit();

    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    const same_executable = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(snapshot.executable_path, executable_path)
    else
        std.mem.eql(u8, snapshot.executable_path, executable_path);
    if (!same_executable) return Error.OwnerUnavailable;

    const response = try request(
        allocator,
        snapshot,
        .GET,
        "/owner/health",
        null,
        small_response_bytes,
        owner_health_timeout_ms,
    );
    defer allocator.free(response);
    try validateHealth(allocator, snapshot, response);
    return snapshot;
}

fn spawnOwner(allocator: std.mem.Allocator, workspace_root: []const u8) !owner_state.Snapshot {
    if (builtin.os.tag != .windows) return Error.PersistentOwnerUnsupported;

    const executable_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable_path);
    var child = try spawnDetachedWindowsOwner(allocator, executable_path, workspace_root);
    var child_live = true;
    errdefer if (child_live) stopSpawnedOwner(child);

    var timer = try std.time.Timer.start();
    while (timer.read() / std.time.ns_per_ms < owner_start_timeout_ms) {
        if (readHealthyOwner(allocator, workspace_root)) |snapshot| {
            child.close();
            child_live = false;
            return snapshot;
        } else |_| {}

        if (try process_tree.waitForProcess(child.process_handle, 0)) {
            child.close();
            child_live = false;
            return Error.OwnerStartFailed;
        }
        std.Thread.sleep(owner_start_poll_ms * std.time.ns_per_ms);
    }
    return Error.OwnerStartTimeout;
}

const SpawnedOwner = struct {
    process_handle: std.os.windows.HANDLE,
    thread_handle: std.os.windows.HANDLE,

    fn close(self: *SpawnedOwner) void {
        process_tree.closeProcessHandles(self.process_handle, self.thread_handle);
        self.* = undefined;
    }
};

fn spawnDetachedWindowsOwner(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    workspace_root: []const u8,
) !SpawnedOwner {
    const windows = std.os.windows;
    const executable_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, executable_path);
    defer allocator.free(executable_w);
    // The selected workspace is already the child cwd. Pass an explicit dot so
    // an inherited VANTARI_WORKSPACE cannot redirect the detached owner.
    const command_line = try std.fmt.allocPrint(allocator, "\"{s}\" execution-owner --workspace .", .{executable_path});
    defer allocator.free(command_line);
    const command_line_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command_line);
    defer allocator.free(command_line_w);
    const workspace_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, workspace_root);
    defer allocator.free(workspace_w);

    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    var process_info: windows.PROCESS_INFORMATION = undefined;
    windows.CreateProcessW(
        executable_w.ptr,
        command_line_w.ptr,
        null,
        null,
        windows.FALSE,
        .{
            .create_breakaway_from_job = true,
            .create_no_window = true,
            .create_suspended = true,
            .create_unicode_environment = true,
        },
        null,
        workspace_w.ptr,
        &startup_info,
        &process_info,
    ) catch |err| switch (err) {
        error.AccessDenied => return Error.OwnerJobConstrained,
        else => return err,
    };
    var child_in_job: windows.BOOL = windows.FALSE;
    if (IsProcessInJob(process_info.hProcess, null, &child_in_job) == windows.FALSE) {
        windows.TerminateProcess(process_info.hProcess, 1) catch {};
        _ = process_tree.waitForProcess(process_info.hProcess, 5_000) catch false;
        process_tree.closeProcessHandles(process_info.hProcess, process_info.hThread);
        return Error.OwnerJobProbeFailed;
    }
    if (child_in_job != windows.FALSE) {
        windows.TerminateProcess(process_info.hProcess, 1) catch {};
        _ = process_tree.waitForProcess(process_info.hProcess, 5_000) catch false;
        process_tree.closeProcessHandles(process_info.hProcess, process_info.hThread);
        return Error.OwnerJobConstrained;
    }
    if (ResumeThread(process_info.hThread) == std.math.maxInt(windows.DWORD)) {
        windows.TerminateProcess(process_info.hProcess, 1) catch {};
        _ = process_tree.waitForProcess(process_info.hProcess, 5_000) catch false;
        process_tree.closeProcessHandles(process_info.hProcess, process_info.hThread);
        return Error.OwnerStartFailed;
    }
    return .{
        .process_handle = process_info.hProcess,
        .thread_handle = process_info.hThread,
    };
}

fn stopSpawnedOwner(child: SpawnedOwner) void {
    if (builtin.os.tag != .windows) return;
    var owned = child;
    std.os.windows.TerminateProcess(owned.process_handle, 1) catch {};
    _ = process_tree.waitForProcess(owned.process_handle, 5_000) catch false;
    owned.close();
}

fn validateHealth(allocator: std.mem.Allocator, snapshot: owner_state.Snapshot, response: []const u8) !void {
    var parsed = std.json.parseFromSlice(OwnerHealth, allocator, response, .{
        .ignore_unknown_fields = true,
    }) catch return Error.InvalidOwnerHealth;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema, owner_state.schema_version) or
        !std.mem.eql(u8, parsed.value.protocol, owner_state.protocol_version) or
        !std.mem.eql(u8, parsed.value.generation, snapshot.generation) or
        !std.mem.eql(u8, parsed.value.workspace_root, snapshot.workspace_root) or
        parsed.value.kernel != .object)
    {
        return Error.InvalidOwnerHealth;
    }
}

fn request(
    allocator: std.mem.Allocator,
    snapshot: owner_state.Snapshot,
    method: std.http.Method,
    path: []const u8,
    payload: ?[]const u8,
    max_response_bytes: usize,
    timeout_ms: usize,
) ![]u8 {
    const storage = try allocator.alloc(u8, max_response_bytes);
    errdefer allocator.free(storage);
    const response_len = try requestInto(allocator, snapshot, method, path, payload, storage, timeout_ms);
    return allocator.realloc(storage, response_len);
}

fn requestInto(
    allocator: std.mem.Allocator,
    snapshot: owner_state.Snapshot,
    method: std.http.Method,
    path: []const u8,
    payload: ?[]const u8,
    storage: []u8,
    timeout_ms: usize,
) !usize {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ snapshot.port, path });
    defer allocator.free(url);
    const extra_headers = [_]std.http.Header{
        .{ .name = "x-var1-owner-token", .value = snapshot.token },
    };
    var response_writer = std.Io.Writer.fixed(storage);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = &extra_headers,
    });
    defer req.deinit();
    setSocketDeadline(&req, timeout_ms) catch return Error.OwnerUnavailable;

    if (payload) |body_payload| {
        req.transfer_encoding = .{ .content_length = body_payload.len };
        var body = req.sendBody(&.{}) catch return Error.OwnerUnavailable;
        body.writer.writeAll(body_payload) catch return Error.OwnerUnavailable;
        body.end() catch return Error.OwnerUnavailable;
    } else {
        req.sendBodiless() catch return Error.OwnerUnavailable;
    }

    var response = req.receiveHead(&.{}) catch return Error.OwnerUnavailable;
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&response_writer) catch |err| switch (err) {
        error.WriteFailed => return Error.OwnerResponseTooLarge,
        error.ReadFailed => return Error.OwnerUnavailable,
    };
    if (response.head.status != .ok) return Error.OwnerHttpRejected;
    return response_writer.buffered().len;
}

fn transportTimeout(operation_ms: usize) usize {
    return std.math.add(usize, operation_ms, owner_transport_slack_ms) catch std.math.maxInt(usize);
}

/// Bound the blocking loopback socket beneath Zig 0.15.1's HTTP client. Its
/// one-shot fetch helper has no timeout field, so the deadline must live on the
/// connected socket before any request bytes or response wait.
fn setSocketDeadline(req: *std.http.Client.Request, timeout_ms: usize) !void {
    if (builtin.os.tag != .windows) return;
    const connection = req.connection orelse return Error.OwnerUnavailable;
    const stream = connection.stream_reader.getStream();
    const bounded_ms: u32 = @intCast(@min(timeout_ms, std.math.maxInt(u32)));
    const timeout_bytes = std.mem.asBytes(&bounded_ms);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, timeout_bytes);
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, timeout_bytes);
}

fn parseEventPayload(allocator: std.mem.Allocator, payload: []const u8) !?stdio_client.Notification {
    if (std.mem.startsWith(u8, payload, ": keepalive")) return null;
    var sequence: ?u64 = null;
    var method: ?[]const u8 = null;
    var params_json: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "id: ")) {
            sequence = std.fmt.parseInt(u64, line[4..], 10) catch return Error.InvalidOwnerEvent;
        } else if (std.mem.startsWith(u8, line, "event: ")) {
            method = line[7..];
        } else if (std.mem.startsWith(u8, line, "data: ")) {
            params_json = line[6..];
        }
    }
    const event_method = method orelse return Error.InvalidOwnerEvent;
    const event_params = params_json orelse return Error.InvalidOwnerEvent;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, event_params, .{}) catch return Error.InvalidOwnerEvent;
    defer parsed.deinit();
    const owned_method = try allocator.dupe(u8, event_method);
    errdefer allocator.free(owned_method);
    return .{
        .sequence = sequence orelse return Error.InvalidOwnerEvent,
        .method = owned_method,
        .params_json = try allocator.dupe(u8, event_params),
    };
}

pub const testing_hooks = struct {
    pub fn parseEvent(allocator: std.mem.Allocator, payload: []const u8) !?stdio_client.Notification {
        return parseEventPayload(allocator, payload);
    }

    pub fn requestWithTimeout(
        allocator: std.mem.Allocator,
        snapshot: owner_state.Snapshot,
        path: []const u8,
        timeout_ms: usize,
    ) ![]u8 {
        return request(allocator, snapshot, .GET, path, null, small_response_bytes, timeout_ms);
    }
};
