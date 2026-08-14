const std = @import("std");

const process = @import("../process.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

/// One DAP adapter stays attached to one VAR1 session. The tool sockets remain
/// separate because attach/continue/detach are high-impact while stack/scopes/
/// variables are read-only; the transport and lifecycle state have one owner.
const dap_timeout_ms: usize = 15_000;
const dap_frame_bytes: usize = 1024 * 1024;

pub const Error = error{
    DapRequestFailed,
    DapReadTimedOut,
    DapFrameTooLarge,
    DapInvalidMessage,
    AdapterRequestUnsupported,
    SessionRequired,
    SessionNotFound,
};

pub const DapStatus = enum {
    starting,
    attached,
    running,
    paused,
    terminated,
    detached,
};

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    process: process.PersistentProcess,
    next_seq: u64 = 1,
    initialized: bool = false,
    supports_configuration_done: bool = false,
    status: DapStatus = .starting,
    thread_id: ?i64 = null,

    pub fn spawn(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        adapter_command: []const []const u8,
    ) !DapClient {
        return .{
            .allocator = allocator,
            .process = try process.PersistentProcess.spawn(allocator, cwd, adapter_command),
        };
    }

    pub fn deinit(self: *DapClient) void {
        self.process.deinit();
        self.status = .detached;
    }

    /// Send one request and consume interleaved adapter events until its
    /// response arrives. Why: DAP emits initialized/stopped/continued events
    /// on the same channel as responses. Preserves one ordered client without
    /// losing events when the adapter batches frames in one pipe read.
    pub fn request(self: *DapClient, command: []const u8, arguments: []const u8) ![]u8 {
        const seq = self.next_seq;
        self.next_seq += 1;

        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{s}}}",
            .{ seq, command, arguments },
        );
        defer self.allocator.free(payload);
        try self.writeFrame(payload);

        while (true) {
            var frame = self.process.readContentLengthFrame(
                self.allocator,
                dap_timeout_ms,
                dap_frame_bytes,
                dap_frame_bytes,
            ) catch |err| switch (err) {
                error.ProcessNotRunning, error.ProcessPipeClosed => return error.DapRequestFailed,
                else => return err,
            };
            defer frame.deinit(self.allocator);
            if (frame.timed_out) return error.DapReadTimedOut;
            if (frame.truncated) return error.DapFrameTooLarge;

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.frame, .{
                .ignore_unknown_fields = true,
            }) catch return error.DapInvalidMessage;
            defer parsed.deinit();
            if (parsed.value != .object) return error.DapInvalidMessage;
            const object = parsed.value.object;
            const message_type = object.get("type") orelse return error.DapInvalidMessage;

            if (message_type == .string and std.mem.eql(u8, message_type.string, "event")) {
                self.handleEvent(object);
                continue;
            }
            if (message_type == .string and std.mem.eql(u8, message_type.string, "request")) {
                return error.AdapterRequestUnsupported;
            }
            if (message_type != .string or !std.mem.eql(u8, message_type.string, "response")) continue;

            const request_seq_value = object.get("request_seq") orelse return error.DapInvalidMessage;
            const request_seq: u64 = switch (request_seq_value) {
                .integer => |value| @intCast(value),
                else => return error.DapInvalidMessage,
            };
            if (request_seq != seq) continue;

            if (object.get("success")) |success| {
                if (success == .bool and !success.bool) return error.DapRequestFailed;
            }
            self.markRequestCompletion(command);
            if (object.get("body")) |body| {
                return std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(body, .{})});
            }
            return self.allocator.dupe(u8, "{}");
        }
    }

    fn markRequestCompletion(self: *DapClient, command: []const u8) void {
        if (std.mem.eql(u8, command, "attach")) self.status = .attached;
        if (std.mem.eql(u8, command, "pause")) self.status = .paused;
        if (std.mem.eql(u8, command, "continue")) self.status = .running;
        if (std.mem.eql(u8, command, "disconnect")) self.status = .detached;
    }

    fn handleEvent(self: *DapClient, object: std.json.ObjectMap) void {
        const event_value = object.get("event") orelse return;
        if (event_value != .string) return;
        const event = event_value.string;

        if (std.mem.eql(u8, event, "initialized")) {
            self.initialized = true;
            return;
        }
        if (std.mem.eql(u8, event, "stopped")) {
            self.status = .paused;
            if (object.get("body")) |body| {
                if (body == .object) {
                    if (body.object.get("threadId")) |thread| {
                        if (thread == .integer) self.thread_id = thread.integer;
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, event, "continued")) {
            self.status = .running;
            return;
        }
        if (std.mem.eql(u8, event, "terminated") or std.mem.eql(u8, event, "exited")) {
            self.status = .terminated;
        }
    }

    fn writeFrame(self: *DapClient, payload: []const u8) !void {
        const frame = try std.fmt.allocPrint(
            self.allocator,
            "Content-Length: {d}\r\n\r\n{s}",
            .{ payload.len, payload },
        );
        defer self.allocator.free(frame);
        try self.process.writeBytes(frame);
    }
};

const DapSession = struct {
    pid: i32,
    client: DapClient,

    fn deinit(self: *DapSession) void {
        self.client.deinit();
    }
};

/// Process-local adapter registry. It is lifecycle state, not transcript
/// truth; the host tears it down only after request workers have joined, just
/// like persistent eval kernels.
const DapRegistry = struct {
    mutex: std.Thread.Mutex = .{},
    sessions: std.StringHashMapUnmanaged(*DapSession) = .{},

    fn deinit(self: *DapRegistry) void {
        const allocator = std.heap.page_allocator;
        self.mutex.lock();
        defer self.mutex.unlock();

        var iterator = self.sessions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
            allocator.destroy(entry.value_ptr.*);
            allocator.free(entry.key_ptr.*);
        }
        self.sessions.deinit(allocator);
        self.sessions = .{};
    }
};

var dap_registry: DapRegistry = .{};

/// Stop every session-owned adapter during host teardown. The registry is
/// process-local execution state, never durable debugger/session truth.
pub fn deinitAll() void {
    dap_registry.deinit();
}

fn registryKey(workspace_root: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}\x1f{s}", .{ workspace_root, session_id });
}

fn findSessionLocked(execution_context: module.ExecutionContext) ?*DapSession {
    const session_id = execution_context.session_id orelse return null;
    const key = registryKey(execution_context.workspace_root, session_id) catch return null;
    defer std.heap.page_allocator.free(key);
    return dap_registry.sessions.get(key);
}

fn removeSessionLocked(execution_context: module.ExecutionContext) void {
    const session_id = execution_context.session_id orelse return;
    const key = registryKey(execution_context.workspace_root, session_id) catch return;
    defer std.heap.page_allocator.free(key);

    if (dap_registry.sessions.fetchRemove(key)) |removed| {
        removed.value.deinit();
        std.heap.page_allocator.destroy(removed.value);
        std.heap.page_allocator.free(removed.key);
    }
}

fn statusContent(allocator: std.mem.Allocator, session: *const DapSession) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"status\":\"{s}\",\"pid\":{d}}}", .{
        @tagName(session.client.status),
        session.pid,
    });
}

fn missingSession(allocator: std.mem.Allocator, tool_name: []const u8) ![]u8 {
    return module.okEnvelope(allocator, tool_name, "No DAP session is attached to this VAR1 session. Call dap_attach first.");
}

fn supportsConfigurationDone(allocator: std.mem.Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const value = parsed.value.object.get("supportsConfigurationDoneRequest") orelse return false;
    return value == .bool and value.bool;
}

fn parsedSessionId(execution_context: module.ExecutionContext) ?[]const u8 {
    return execution_context.session_id;
}

pub const attach = types.ToolDefinition{
    .name = "dap_attach",
    .description = "Attach one configured DAP adapter to a running process for this VAR1 session. The adapter remains alive for pause, stack, scopes, variables, continue, and detach.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pid": { "type": "integer", "description": "Process ID to attach to." },
    \\    "adapter": { "type": "string", "description": "Optional space-delimited adapter command. Defaults to VANTARI_DAP_ADAPTER." }
    \\  },
    \\  "required": ["pid"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"pid\":12345,\"adapter\":\"lldb-dap\"}",
    .usage_hint = "Attach once. Use dap_pause, dap_stacktrace, dap_scopes, dap_variables, dap_continue, and dap_detach on the same session.",
};

pub const pause = types.ToolDefinition{
    .name = "dap_pause",
    .description = "Pause the debuggee through the existing DAP session.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": { "thread_id": { "type": "integer", "description": "Optional thread ID; uses the last stopped thread when omitted." } },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"thread_id\":1}",
};

pub const stacktrace = types.ToolDefinition{
    .name = "dap_stacktrace",
    .description = "Read the call stack from the paused DAP session. Uses the last stopped thread when thread_id is omitted.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "thread_id": { "type": "integer" },
    \\    "start_frame": { "type": "integer" },
    \\    "levels": { "type": "integer" }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"levels\":10}",
};

pub const scopes = types.ToolDefinition{
    .name = "dap_scopes",
    .description = "Read the scopes for one stack frame in the paused DAP session.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": { "frame_id": { "type": "integer", "description": "Frame ID from dap_stacktrace." } },
    \\  "required": ["frame_id"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"frame_id\":42}",
};

pub const variables = types.ToolDefinition{
    .name = "dap_variables",
    .description = "Read variables from one DAP scope in the paused session.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": { "variables_reference": { "type": "integer", "description": "variablesReference from dap_scopes." } },
    \\  "required": ["variables_reference"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"variables_reference\":2}",
};

pub const continue_execution = types.ToolDefinition{
    .name = "dap_continue",
    .description = "Continue the debuggee through the existing DAP session.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": { "thread_id": { "type": "integer", "description": "Optional thread ID; uses the last stopped thread when omitted." } },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"thread_id\":1}",
};

pub const detach = types.ToolDefinition{
    .name = "dap_detach",
    .description = "Detach the adapter from the debuggee and release the session-owned adapter process without terminating the debuggee.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {},
    \\  "additionalProperties": false
    \\}
    ,
};

pub const definitions = [_]types.ToolDefinition{
    attach,
    pause,
    stacktrace,
    scopes,
    variables,
    continue_execution,
    detach,
};

pub fn handles(tool_name: []const u8) bool {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.name, tool_name)) return true;
    }
    return false;
}

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    tool_name: []const u8,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "dap_attach")) return executeAttach(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_pause")) return executePause(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_stacktrace")) return executeStacktrace(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_scopes")) return executeScopes(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_variables")) return executeVariables(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_continue")) return executeContinue(allocator, execution_context, arguments_json);
    if (std.mem.eql(u8, tool_name, "dap_detach")) return executeDetach(allocator, execution_context, arguments_json);
    return module.Error.UnknownTool;
}

pub fn executeAttach(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const session_id = parsedSessionId(execution_context) orelse return error.SessionRequired;
    const Args = struct {
        pid: i32,
        adapter: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();

    var owned_env: ?[]u8 = null;
    defer if (owned_env) |value| allocator.free(value);
    const adapter_command = if (parsed.value.adapter) |value| value else blk: {
        owned_env = std.process.getEnvVarOwned(allocator, "VANTARI_DAP_ADAPTER") catch null;
        break :blk owned_env orelse return module.okEnvelope(allocator, "dap_attach", "DAP adapter not configured. Set VANTARI_DAP_ADAPTER or pass adapter.");
    };

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    var tokens = std.mem.tokenizeAny(u8, adapter_command, " \t");
    while (tokens.next()) |token| try argv.append(token);
    if (argv.items.len == 0) return module.okEnvelope(allocator, "dap_attach", "DAP adapter command is empty.");

    var client = DapClient.spawn(std.heap.page_allocator, execution_context.workspace_root, argv.items) catch {
        return module.okEnvelope(allocator, "dap_attach", "Could not start the DAP adapter. Check the adapter command and installation.");
    };
    var client_owned = true;
    defer if (client_owned) client.deinit();

    const initialize_result = client.request(
        "initialize",
        "{\"clientID\":\"vantari\",\"clientName\":\"VANTARI\",\"adapterID\":\"vantari\",\"linesStartAt1\":true,\"columnsStartAt1\":true}",
    ) catch {
        return module.okEnvelope(allocator, "dap_attach", "DAP initialize failed. The adapter did not return a valid response.");
    };
    defer std.heap.page_allocator.free(initialize_result);
    client.supports_configuration_done = supportsConfigurationDone(std.heap.page_allocator, initialize_result);

    const attach_args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"processId\":{d}}}", .{parsed.value.pid});
    defer std.heap.page_allocator.free(attach_args);
    const attach_result = client.request("attach", attach_args) catch {
        return module.okEnvelope(allocator, "dap_attach", "DAP attach failed. Check that the process ID is valid and attachable.");
    };
    defer std.heap.page_allocator.free(attach_result);
    if (client.supports_configuration_done and client.initialized) {
        const configuration_result = client.request("configurationDone", "{}") catch {
            return module.okEnvelope(allocator, "dap_attach", "DAP configuration handshake failed.");
        };
        defer std.heap.page_allocator.free(configuration_result);
    }
    client.status = .attached;

    const state_allocator = std.heap.page_allocator;
    const session = try state_allocator.create(DapSession);
    var session_installed = false;
    errdefer if (!session_installed) {
        session.deinit();
        state_allocator.destroy(session);
    };
    session.* = .{ .pid = parsed.value.pid, .client = client };
    client_owned = false;

    const key = try registryKey(execution_context.workspace_root, session_id);
    errdefer state_allocator.free(key);
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    if (dap_registry.sessions.fetchRemove(key)) |removed| {
        removed.value.deinit();
        state_allocator.destroy(removed.value);
        state_allocator.free(removed.key);
    }
    try dap_registry.sessions.put(state_allocator, key, session);
    session_installed = true;

    const content = try statusContent(allocator, session);
    defer allocator.free(content);
    return module.okEnvelope(allocator, "dap_attach", content);
}

pub fn executePause(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct { thread_id: ?i64 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_pause");
    const thread_id = parsed.value.thread_id orelse session.client.thread_id orelse 0;
    const args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"threadId\":{d}}}", .{thread_id});
    defer std.heap.page_allocator.free(args);
    const pause_result = session.client.request("pause", args) catch return module.okEnvelope(allocator, "dap_pause", "DAP pause failed.");
    defer std.heap.page_allocator.free(pause_result);
    session.client.thread_id = thread_id;
    session.client.status = .paused;
    const content = try statusContent(allocator, session);
    defer allocator.free(content);
    return module.okEnvelope(allocator, "dap_pause", content);
}

pub fn executeStacktrace(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct { thread_id: ?i64 = null, start_frame: ?i64 = null, levels: ?i64 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_stacktrace");
    const thread_id = parsed.value.thread_id orelse session.client.thread_id orelse return module.okEnvelope(allocator, "dap_stacktrace", "No stopped thread is known. Call dap_pause first or provide thread_id.");
    const args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"threadId\":{d},\"startFrame\":{d},\"levels\":{d}}}", .{
        thread_id,
        parsed.value.start_frame orelse 0,
        parsed.value.levels orelse 20,
    });
    defer std.heap.page_allocator.free(args);
    const result = session.client.request("stackTrace", args) catch return module.okEnvelope(allocator, "dap_stacktrace", "DAP stackTrace failed. Ensure the debuggee is paused.");
    defer std.heap.page_allocator.free(result);
    return module.okEnvelope(allocator, "dap_stacktrace", result);
}

pub fn executeScopes(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct { frame_id: i64 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_scopes");
    const args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"frameId\":{d}}}", .{parsed.value.frame_id});
    defer std.heap.page_allocator.free(args);
    const result = session.client.request("scopes", args) catch return module.okEnvelope(allocator, "dap_scopes", "DAP scopes failed. Ensure the frame ID is valid and paused.");
    defer std.heap.page_allocator.free(result);
    return module.okEnvelope(allocator, "dap_scopes", result);
}

pub fn executeVariables(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct { variables_reference: i64 };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_variables");
    const args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"variablesReference\":{d}}}", .{parsed.value.variables_reference});
    defer std.heap.page_allocator.free(args);
    const result = session.client.request("variables", args) catch return module.okEnvelope(allocator, "dap_variables", "DAP variables failed. Ensure the variables reference is valid and paused.");
    defer std.heap.page_allocator.free(result);
    return module.okEnvelope(allocator, "dap_variables", result);
}

pub fn executeContinue(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct { thread_id: ?i64 = null };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_continue");
    const thread_id = parsed.value.thread_id orelse session.client.thread_id orelse 0;
    const args = try std.fmt.allocPrint(std.heap.page_allocator, "{{\"threadId\":{d}}}", .{thread_id});
    defer std.heap.page_allocator.free(args);
    const continue_result = session.client.request("continue", args) catch return module.okEnvelope(allocator, "dap_continue", "DAP continue failed.");
    defer std.heap.page_allocator.free(continue_result);
    session.client.status = .running;
    const content = try statusContent(allocator, session);
    defer allocator.free(content);
    return module.okEnvelope(allocator, "dap_continue", content);
}

pub fn executeDetach(allocator: std.mem.Allocator, execution_context: module.ExecutionContext, arguments_json: []const u8) ![]u8 {
    const Args = struct {};
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    dap_registry.mutex.lock();
    defer dap_registry.mutex.unlock();
    const session = findSessionLocked(execution_context) orelse return missingSession(allocator, "dap_detach");
    if (session.client.request("disconnect", "{\"terminateDebuggee\":false}")) |disconnect_result| {
        std.heap.page_allocator.free(disconnect_result);
    } else |_| {}
    removeSessionLocked(execution_context);
    return module.okEnvelope(allocator, "dap_detach", "DAP session detached and adapter process released.");
}

test "DAP definitions preserve risk boundaries and lifecycle sockets" {
    try std.testing.expectEqual(types.ToolRiskClass.unknown_high_impact, attach.review_risk);
    try std.testing.expectEqual(types.ToolRiskClass.read_only, stacktrace.review_risk);
    try std.testing.expectEqual(types.ToolRiskClass.read_only, scopes.review_risk);
    try std.testing.expectEqual(@as(usize, 7), definitions.len);
    try std.testing.expect(handles("dap_attach"));
    try std.testing.expect(handles("dap_detach"));
    try std.testing.expect(!handles("dap_evaluate"));
}

test "DAP client keeps one adapter through the request lifecycle" {
    const adapter_source =
        \\import json,sys
        \\def send(message):
        \\    body=json.dumps(message,separators=(',',':')).encode()
        \\    sys.stdout.buffer.write(('Content-Length: '+str(len(body))+'\r\n\r\n').encode()+body)
        \\    sys.stdout.buffer.flush()
        \\while True:
        \\    header=b''
        \\    while not header.endswith(b'\r\n\r\n'):
        \\        byte=sys.stdin.buffer.read(1)
        \\        if not byte: raise SystemExit
        \\        header+=byte
        \\    length=int([line for line in header.decode().split('\r\n') if line.lower().startswith('content-length:')][0].split(':')[1])
        \\    request=json.loads(sys.stdin.buffer.read(length))
        \\    seq=request['seq']; command=request['command']
        \\    send({'type':'response','seq':seq+100,'request_seq':seq,'success':True,'command':command,'body':{'supportsConfigurationDoneRequest':True} if command=='initialize' else {}})
        \\    if command=='initialize': send({'type':'event','seq':seq+101,'event':'initialized'})
        \\    if command=='pause': send({'type':'event','seq':seq+101,'event':'stopped','body':{'threadId':1}})
        \\    if command=='continue': send({'type':'event','seq':seq+101,'event':'continued','body':{'threadId':1}})
        \\    if command=='stackTrace': send({'type':'event','seq':seq+101,'event':'stopped','body':{'threadId':1}})
        \\    if command=='disconnect': raise SystemExit
    ;

    var client = DapClient.spawn(std.heap.page_allocator, ".", &.{ "python", "-u", "-c", adapter_source }) catch return error.SkipZigTest;
    defer client.deinit();
    const process_id = client.process.child.id;
    const initialize_result = try client.request("initialize", "{}");
    defer std.heap.page_allocator.free(initialize_result);
    client.supports_configuration_done = supportsConfigurationDone(std.heap.page_allocator, initialize_result);
    try std.testing.expect(client.supports_configuration_done);
    const attach_result = try client.request("attach", "{\"processId\":1}");
    defer std.heap.page_allocator.free(attach_result);
    const configuration_result = try client.request("configurationDone", "{}");
    defer std.heap.page_allocator.free(configuration_result);
    client.status = .attached;
    const pause_result = try client.request("pause", "{\"threadId\":1}");
    defer std.heap.page_allocator.free(pause_result);
    try std.testing.expectEqual(DapStatus.paused, client.status);
    const stack_result = try client.request("stackTrace", "{\"threadId\":1}");
    defer std.heap.page_allocator.free(stack_result);
    const scopes_result = try client.request("scopes", "{\"frameId\":1}");
    defer std.heap.page_allocator.free(scopes_result);
    const variables_result = try client.request("variables", "{\"variablesReference\":1}");
    defer std.heap.page_allocator.free(variables_result);
    const continue_result = try client.request("continue", "{\"threadId\":1}");
    defer std.heap.page_allocator.free(continue_result);
    try std.testing.expectEqual(DapStatus.running, client.status);
    try std.testing.expectEqual(process_id, client.process.child.id);
}
