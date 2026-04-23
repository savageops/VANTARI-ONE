const std = @import("std");
const loop = @import("loop.zig");
const protocol_types = @import("protocol_types.zig");
const provider = @import("provider.zig");
const tools = @import("tools.zig");
const types = @import("types.zig");

pub const Error = error{
    InvalidRequest,
    InvalidParams,
    MethodNotFound,
    SessionNotFound,
    ExecutionFailed,
    InvalidFrame,
    MissingChildPipes,
    InvalidRpcResponse,
    RpcRemoteError,
};

const max_header_line_bytes = 8 * 1024;

const Runtime = struct {
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
    sessions: std.StringHashMapUnmanaged(SessionRecord) = .{},

    fn deinit(self: *Runtime, allocator: std.mem.Allocator) void {
        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.sessions.deinit(allocator);
    }
};

const SessionRecord = struct {
    id: []u8,
    prompt: ?[]u8 = null,
    task_id: ?[]u8 = null,
    enable_agent_tools: bool = true,
    state: protocol_types.SessionState = .initialized,
    answer: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,

    fn deinit(self: SessionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.prompt) |value| allocator.free(value);
        if (self.task_id) |value| allocator.free(value);
        if (self.answer) |value| allocator.free(value);
        if (self.failure_reason) |value| allocator.free(value);
    }
};

pub fn serveKernel(
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    agent_service: tools.AgentService,
) !void {
    var runtime = Runtime{
        .config = config,
        .transport = transport,
        .agent_service = agent_service,
    };
    defer runtime.deinit(allocator);

    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    while (true) {
        const request_payload = try readFrame(allocator, stdin_file) orelse break;
        defer allocator.free(request_payload);

        const response_payload = try processRequest(allocator, &runtime, request_payload);
        defer allocator.free(response_payload);

        try writeFrame(stdout_file, response_payload);
    }
}

pub const LocalClient = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    next_request_id: usize = 1,

    pub fn init(allocator: std.mem.Allocator) !LocalClient {
        const exe_path = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(exe_path);

        var argv = [_][]const u8{ exe_path, "kernel-stdio" };
        var child = std.process.Child.init(&argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        return .{
            .allocator = allocator,
            .child = child,
        };
    }

    pub fn deinit(self: *LocalClient) void {
        if (self.child.stdin) |*stdin_file| stdin_file.close();
        if (self.child.stdout) |*stdout_file| stdout_file.close();
        _ = self.child.wait() catch {};
    }

    pub fn call(self: *LocalClient, method: []const u8, params_json: []const u8) ![]u8 {
        if (self.child.stdin == null or self.child.stdout == null) {
            return Error.MissingChildPipes;
        }

        const request_payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":\"req-{d}\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ self.next_request_id, method, params_json },
        );
        defer self.allocator.free(request_payload);
        self.next_request_id += 1;

        try writeFrame(self.child.stdin.?, request_payload);

        const response_payload = try readFrame(self.allocator, self.child.stdout.?) orelse {
            return Error.InvalidRpcResponse;
        };
        defer self.allocator.free(response_payload);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_payload, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return Error.InvalidRpcResponse;
        const response_object = parsed.value.object;

        if (response_object.get("error")) |_| {
            return Error.RpcRemoteError;
        }

        const result_value = response_object.get("result") orelse return Error.InvalidRpcResponse;
        return std.json.stringifyAlloc(self.allocator, result_value, .{});
    }
};

fn processRequest(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    request_payload: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_payload, .{}) catch {
        return renderErrorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return renderErrorResponse(allocator, null, -32600, "Invalid Request");
    }

    const request_object = parsed.value.object;
    const id = extractRequestId(request_object) catch {
        return renderErrorResponse(allocator, null, -32600, "Invalid Request");
    };

    const jsonrpc_value = request_object.get("jsonrpc") orelse {
        return renderErrorResponse(allocator, id, -32600, "Invalid Request");
    };
    if (jsonrpc_value != .string or !std.mem.eql(u8, jsonrpc_value.string, "2.0")) {
        return renderErrorResponse(allocator, id, -32600, "Invalid Request");
    }

    const method_value = request_object.get("method") orelse {
        return renderErrorResponse(allocator, id, -32600, "Invalid Request");
    };
    if (method_value != .string) {
        return renderErrorResponse(allocator, id, -32600, "Invalid Request");
    }
    const method_name = method_value.string;
    const params = request_object.get("params");

    const result_payload = dispatch(allocator, runtime, method_name, params) catch |err| switch (err) {
        Error.MethodNotFound => return renderErrorResponse(allocator, id, -32601, "Method not found"),
        Error.InvalidParams => return renderErrorResponse(allocator, id, -32602, "Invalid params"),
        Error.SessionNotFound => return renderErrorResponse(allocator, id, -32001, "Session not found"),
        Error.ExecutionFailed => return renderErrorResponse(allocator, id, -32000, "Execution failed"),
        else => return renderErrorResponse(allocator, id, -32603, "Internal error"),
    };
    defer allocator.free(result_payload);

    return renderSuccessResponse(allocator, id, result_payload);
}

fn dispatch(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    method_name: []const u8,
    params: ?std.json.Value,
) ![]u8 {
    if (std.mem.eql(u8, method_name, protocol_types.methods.initialize)) {
        return handleInitialize(allocator);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_create)) {
        return handleSessionCreate(allocator, runtime, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_send)) {
        return handleSessionSend(allocator, runtime, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_get)) {
        return handleSessionGet(allocator, runtime, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.session_cancel)) {
        return handleSessionCancel(allocator, runtime, params);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.health_get)) {
        return handleHealthGet(allocator, runtime);
    }
    if (std.mem.eql(u8, method_name, protocol_types.methods.tools_list)) {
        return handleToolsList(allocator, runtime, params);
    }

    return Error.MethodNotFound;
}

fn handleInitialize(allocator: std.mem.Allocator) ![]u8 {
    const payload = protocol_types.InitializeResult{
        .server_version = "VAR1-kernel-stdio-v1",
        .capabilities = .{},
    };
    return std.json.stringifyAlloc(allocator, payload, .{});
}

fn handleSessionCreate(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    params: ?std.json.Value,
) ![]u8 {
    const object = try requireParamsObject(params);
    const prompt = try optionalStringFromObject(&object, "prompt");
    const task_id = try optionalStringFromObject(&object, "task_id");
    const enable_agent_tools = (try optionalBoolFromObject(&object, "enable_agent_tools")) orelse true;

    if (prompt == null and task_id == null) return Error.InvalidParams;

    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const session_id = try std.fmt.allocPrint(allocator, "session-{d}-{x}", .{ now, nonce });
    errdefer allocator.free(session_id);

    var session = SessionRecord{
        .id = session_id,
        .prompt = if (prompt) |value| try allocator.dupe(u8, value) else null,
        .task_id = if (task_id) |value| try allocator.dupe(u8, value) else null,
        .enable_agent_tools = enable_agent_tools,
        .state = .initialized,
        .created_at_ms = now,
        .updated_at_ms = now,
    };
    errdefer session.deinit(allocator);

    try runtime.sessions.put(allocator, session.id, session);

    return std.json.stringifyAlloc(
        allocator,
        protocol_types.SessionCreateResult{
            .session_id = session.id,
            .state = protocol_types.sessionStateLabel(session.state),
        },
        .{},
    );
}

fn handleSessionSend(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    params: ?std.json.Value,
) ![]u8 {
    const object = try requireParamsObject(params);
    const session_id = (try optionalStringFromObject(&object, "session_id")) orelse return Error.InvalidParams;

    const session = runtime.sessions.getPtr(session_id) orelse return Error.SessionNotFound;

    if (session.state == .completed) {
        const answer = session.answer orelse "";
        const task_id = session.task_id orelse "";
        return std.json.stringifyAlloc(
            allocator,
            protocol_types.SessionSendResult{
                .session_id = session.id,
                .task_id = task_id,
                .state = protocol_types.sessionStateLabel(session.state),
                .answer = answer,
            },
            .{},
        );
    }

    if (session.state == .cancelled) return Error.ExecutionFailed;

    session.state = .running;
    session.updated_at_ms = std.time.milliTimestamp();

    const run_prompt = session.prompt orelse "";
    const run_result = loop.runPromptWithOptions(allocator, runtime.config.*, run_prompt, .{
        .transport = runtime.transport,
        .execution_context = .{
            .workspace_root = runtime.config.workspace_root,
            .agent_service = if (session.enable_agent_tools) runtime.agent_service else null,
        },
        .task_id = session.task_id,
    }) catch |err| {
        if (session.failure_reason) |value| allocator.free(value);
        session.failure_reason = try allocator.dupe(u8, @errorName(err));
        session.state = .failed;
        session.updated_at_ms = std.time.milliTimestamp();
        return Error.ExecutionFailed;
    };
    defer run_result.deinit(allocator);

    if (session.task_id) |value| allocator.free(value);
    session.task_id = try allocator.dupe(u8, run_result.task_id);

    if (session.answer) |value| allocator.free(value);
    session.answer = try allocator.dupe(u8, run_result.answer);

    if (session.failure_reason) |value| {
        allocator.free(value);
        session.failure_reason = null;
    }
    session.state = .completed;
    session.updated_at_ms = std.time.milliTimestamp();

    return std.json.stringifyAlloc(
        allocator,
        protocol_types.SessionSendResult{
            .session_id = session.id,
            .task_id = run_result.task_id,
            .state = protocol_types.sessionStateLabel(session.state),
            .answer = run_result.answer,
        },
        .{},
    );
}

fn handleSessionGet(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    params: ?std.json.Value,
) ![]u8 {
    const object = try requireParamsObject(params);
    const session_id = (try optionalStringFromObject(&object, "session_id")) orelse return Error.InvalidParams;

    const session = runtime.sessions.get(session_id) orelse return Error.SessionNotFound;
    const payload = protocol_types.SessionGetResult{
        .session_id = session.id,
        .task_id = session.task_id,
        .state = protocol_types.sessionStateLabel(session.state),
        .answer = session.answer,
        .failure_reason = session.failure_reason,
    };
    return std.json.stringifyAlloc(allocator, payload, .{});
}

fn handleSessionCancel(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    params: ?std.json.Value,
) ![]u8 {
    const object = try requireParamsObject(params);
    const session_id = (try optionalStringFromObject(&object, "session_id")) orelse return Error.InvalidParams;

    const session = runtime.sessions.getPtr(session_id) orelse return Error.SessionNotFound;
    var cancelled = false;
    if (session.state == .initialized) {
        session.state = .cancelled;
        session.updated_at_ms = std.time.milliTimestamp();
        cancelled = true;
    }

    return std.json.stringifyAlloc(
        allocator,
        protocol_types.SessionCancelResult{
            .session_id = session.id,
            .cancelled = cancelled,
            .state = protocol_types.sessionStateLabel(session.state),
        },
        .{},
    );
}

fn handleHealthGet(allocator: std.mem.Allocator, runtime: *Runtime) ![]u8 {
    return std.json.stringifyAlloc(
        allocator,
        protocol_types.HealthGetResult{
            .ok = true,
            .model = runtime.config.openai_model,
            .workspace_root = runtime.config.workspace_root,
            .openai_base_url = runtime.config.openai_base_url,
        },
        .{},
    );
}

fn handleToolsList(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    params: ?std.json.Value,
) ![]u8 {
    var format: []const u8 = "text";
    if (params) |value| {
        if (value != .object) return Error.InvalidParams;
        if (try optionalStringFromObject(&value.object, "format")) |provided| {
            format = provided;
        }
    }

    if (!std.mem.eql(u8, format, "text") and !std.mem.eql(u8, format, "json")) {
        return Error.InvalidParams;
    }

    const execution_context = tools.ExecutionContext{
        .workspace_root = runtime.config.workspace_root,
        .agent_service = runtime.agent_service,
    };
    const output = if (std.mem.eql(u8, format, "json"))
        try tools.renderCatalogJson(allocator, execution_context)
    else
        try tools.renderCatalog(allocator, execution_context);
    defer allocator.free(output);

    return std.json.stringifyAlloc(
        allocator,
        protocol_types.ToolsListResult{
            .format = format,
            .output = output,
        },
        .{},
    );
}

fn requireParamsObject(params: ?std.json.Value) !std.json.ObjectMap {
    const value = params orelse return Error.InvalidParams;
    if (value != .object) return Error.InvalidParams;
    return value.object;
}

fn optionalStringFromObject(object: *const std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return Error.InvalidParams;
    return value.string;
}

fn optionalBoolFromObject(object: *const std.json.ObjectMap, key: []const u8) !?bool {
    const value = object.get(key) orelse return null;
    if (value != .bool) return Error.InvalidParams;
    return value.bool;
}

fn extractRequestId(object: std.json.ObjectMap) !?[]const u8 {
    const value = object.get("id") orelse return null;
    if (value != .string) return Error.InvalidRequest;
    return value.string;
}

fn renderSuccessResponse(
    allocator: std.mem.Allocator,
    id: ?[]const u8,
    result_payload: []const u8,
) ![]u8 {
    const id_payload = if (id) |value|
        try std.json.stringifyAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
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
        try std.json.stringifyAlloc(allocator, value, .{})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(id_payload);

    const error_payload = try std.json.stringifyAlloc(allocator, .{
        .code = code,
        .message = message,
    }, .{});
    defer allocator.free(error_payload);

    return std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{s}}}",
        .{ id_payload, error_payload },
    );
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
    var payload = try allocator.alloc(u8, expected_len);
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
        if (byte[0] == '\n') return line.toOwnedSlice();
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
