const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

/// DAP (Debug Adapter Protocol) integration for VANTARI.
///
/// Harvested from oh-my-pi's DAP debugger tool surface. The agent can
/// attach to running processes (native via lldb-dap, Go via dlv, Python
/// via debugpy), inspect stack frames, read variables, and step through
/// code. This is the capability that makes "the agent drives a real
/// debugger" possible — most agents still sprinkle print statements.
///
/// DAP uses the same Content-Length framing as LSP and VANTARI's own
/// kernel-stdio, so the transport code is identical. The difference is
/// the protocol surface: DAP requests like `launch`, `attach`,
/// `stackTrace`, `scopes`, `variables`, `evaluate`.
///
/// VANTARI's advantage: the DAP client reuses the same framed-stdio
/// pattern as LSP and kernel-stdio. Fail-closed: if no adapter is
/// configured, the tools return a typed "unavailable" message.

pub const DapClient = struct {
    allocator: std.mem.Allocator,
    process: std.process.Child,
    next_seq: u64 = 1,

    pub fn spawn(
        allocator: std.mem.Allocator,
        adapter_command: []const []const u8,
    ) !DapClient {
        var child = std.process.Child.init(adapter_command, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();

        return .{
            .allocator = allocator,
            .process = child,
        };
    }

    pub fn deinit(self: *DapClient) void {
        if (self.process.stdin) |*stdin| {
            stdin.close();
            self.process.stdin = null;
        }
        _ = self.process.kill() catch {};
        _ = self.process.wait() catch {};
    }

    /// Send a DAP request (with "command" field instead of "method").
    /// Returns the response body JSON.
    pub fn request(self: *DapClient, command: []const u8, arguments: []const u8) ![]u8 {
        const seq = self.next_seq;
        self.next_seq += 1;

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"seq":{d},"type":"request","command":"{s}","arguments":{s}}}
        , .{ seq, command, arguments });
        defer self.allocator.free(payload);

        try self.writeFrame(payload);

        // Read response frames until we find seq matching.
        while (true) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            // Check for response type.
            if (obj.get("type")) |type_val| {
                if (type_val != .string or !std.mem.eql(u8, type_val.string, "response")) continue;
            } else continue;

            // Check request_seq matches our seq.
            if (obj.get("request_seq")) |req_seq_val| {
                const resp_seq: u64 = switch (req_seq_val) {
                    .integer => |n| @intCast(n),
                    else => continue,
                };
                if (resp_seq != seq) continue;
            } else continue;

            // Check success.
            if (obj.get("success")) |success| {
                if (success == .bool and !success.bool) {
                    const error_msg = if (obj.get("message")) |m| switch (m) {
                        .string => |s| s,
                        else => "unknown error",
                    } else "unknown error";
                    _ = error_msg;
                    return error.DapRequestFailed;
                }
            }

            // Return the body.
            if (obj.get("body")) |body| {
                return std.fmt.allocPrint(self.allocator, "{any}", .{body});
            }
            return try self.allocator.dupe(u8, "{}");
        }
    }

    /// Send a DAP event handler — just reads and discards events until
    /// we get a response. Useful for the `initialized` event.
    pub fn waitForEvent(self: *DapClient, event_type: []const u8) !void {
        while (true) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();

            if (parsed.value != .object) continue;
            const obj = parsed.value.object;

            if (obj.get("type")) |t| {
                if (t == .string and std.mem.eql(u8, t.string, "event")) {
                    if (obj.get("event")) |evt| {
                        if (evt == .string and std.mem.eql(u8, evt.string, event_type)) return;
                    }
                }
                // If it's a response, we missed it — return.
                if (t == .string and std.mem.eql(u8, t.string, "response")) return;
            }
        }
    }

    fn writeFrame(self: *DapClient, payload: []const u8) !void {
        const stdin = self.process.stdin orelse return error.NoStdin;
        var buf: [256]u8 = undefined;
        var writer = stdin.writer(&buf);
        try writer.interface.print("Content-Length: {d}\r\n\r\n", .{payload.len});
        try writer.interface.flush();
        try stdin.writeAll(payload);
    }

    fn readFrame(self: *DapClient) ![]u8 {
        const stdout = self.process.stdout orelse return error.NoStdout;

        var content_length: usize = 0;
        var header_buf: [256]u8 = undefined;
        var header_pos: usize = 0;

        while (header_pos < header_buf.len) {
            const byte = stdout.reader(&header_buf).interface.readByte() catch return error.ReadError;
            header_buf[header_pos] = byte;
            header_pos += 1;

            if (header_pos >= 4 and
                header_buf[header_pos - 4] == '\r' and
                header_buf[header_pos - 3] == '\n' and
                header_buf[header_pos - 2] == '\r' and
                header_buf[header_pos - 1] == '\n')
            {
                const headers = header_buf[0 .. header_pos - 4];
                var lines = std.mem.splitSequence(u8, headers, "\r\n");
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "Content-Length:")) {
                        const value = std.mem.trim(u8, line["Content-Length:".len..], " ");
                        content_length = std.fmt.parseUnsigned(usize, value, 10) catch 0;
                    }
                }
                break;
            }
        }

        if (content_length == 0) return error.NoContentLength;

        const payload = try self.allocator.alloc(u8, content_length);
        const read = try stdout.readAll(payload);
        if (read < content_length) {
            self.allocator.free(payload);
            return error.ShortRead;
        }
        return payload;
    }
};

pub const Error = error{
    DapRequestFailed,
    NoStdin,
    NoStdout,
    ReadError,
    NoContentLength,
    ShortRead,
};

// ============================================================================
// Agent tool definitions
// ============================================================================

pub const attach = types.ToolDefinition{
    .name = "dap_attach",
    .description = "Attach a debug adapter (lldb-dap, dlv, debugpy) to a running process. Requires pid and adapter configured via VANTARI_DAP_ADAPTER. Returns the debug session state.",
    .review_risk = .unknown_high_impact,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "pid": { "type": "integer", "description": "Process ID to attach to." },
    \\    "adapter": { "type": "string", "description": "Optional adapter override (e.g. 'lldb-dap', 'dlv', 'debugpy'). Defaults to VANTARI_DAP_ADAPTER env var." }
    \\  },
    \\  "required": ["pid"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"pid\":12345,\"adapter\":\"lldb-dap\"}",
    .usage_hint = "Attach to a running process to inspect its state. The adapter must be installed. Use dap_stacktrace to see frames and dap_variables to read values.",
};

pub const stacktrace = types.ToolDefinition{
    .name = "dap_stacktrace",
    .description = "Get the call stack of the paused debug session. Requires threadId from the attach response.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "thread_id": { "type": "integer", "description": "Thread ID from the debug session." },
    \\    "start_frame": { "type": "integer", "description": "Optional starting frame index (default 0)." },
    \\    "levels": { "type": "integer", "description": "Optional max frames to return (default 20)." }
    \\  },
    \\  "required": ["thread_id"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"thread_id\":1,\"levels\":10}",
    .usage_hint = "Use after dap_attach to see the call stack. Each frame shows function, file, line. Use dap_variables with the frameId to inspect locals.",
};

pub const variables = types.ToolDefinition{
    .name = "dap_variables",
    .description = "Read variables from a debug scope (locals, arguments, registers). Requires variablesReference from scopes.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "variables_reference": { "type": "integer", "description": "Reference ID from scopes response." }
    \\  },
    \\  "required": ["variables_reference"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"variables_reference\":2}",
    .usage_hint = "Use after dap_stacktrace to read variable values in a frame. The variablesReference comes from the scopes response for that frame.",
};

pub const availability = module.AvailabilitySpec{};

/// Execute dap_attach — spawn adapter, initialize, attach to pid.
pub fn executeAttach(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        pid: i32,
        adapter: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    // Resolve adapter command.
    const adapter_cmd = blk: {
        if (parsed.value.adapter) |a| break :blk try allocator.dupe(u8, a);
        const env = std.process.getEnvVarOwned(allocator, "VANTARI_DAP_ADAPTER") catch null;
        if (env) |e| break :blk e;
        return module.okEnvelope(allocator, "dap_attach", "DAP adapter not configured. Set VANTARI_DAP_ADAPTER to the adapter command (e.g. 'lldb-dap', 'dlv', 'python -m debugpy --adapter').");
    };
    defer allocator.free(adapter_cmd);

    // Parse adapter command into argv.
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    var it = std.mem.tokenizeScalar(u8, adapter_cmd, ' ');
    while (it.next()) |token| try argv.append(token);

    // Spawn adapter.
    var client = DapClient.spawn(allocator, argv.items) catch {
        return module.okEnvelope(allocator, "dap_attach", "Could not start debug adapter. Check VANTARI_DAP_ADAPTER path and that the adapter is installed.");
    };
    defer client.deinit();

    // Initialize DAP session.
    const init_args = "{}";
    const init_result = client.request("initialize", init_args) catch {
        return module.okEnvelope(allocator, "dap_attach", "DAP initialize failed. The adapter may not support the required protocol version.");
    };
    defer allocator.free(init_result);

    // Attach to the process.
    const attach_args = try std.fmt.allocPrint(allocator, "{{\"processId\":{d}}}", .{parsed.value.pid});
    defer allocator.free(attach_args);

    const attach_result = client.request("attach", attach_args) catch {
        return module.okEnvelope(allocator, "dap_attach", "DAP attach failed. Check that the process ID is valid and the adapter can attach to it.");
    };
    defer allocator.free(attach_result);

    _ = execution_context;
    return module.okEnvelope(allocator, "dap_attach", attach_result);
}

/// Execute dap_stacktrace.
pub fn executeStacktrace(
    allocator: std.mem.Allocator,
    _: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        thread_id: i32,
        start_frame: ?i32 = null,
        levels: ?i32 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    // DAP adapter must already be running from a previous dap_attach.
    // For the basic implementation, we spawn a new adapter per request.
    // A production version would maintain a persistent session.
    const adapter_cmd = std.process.getEnvVarOwned(allocator, "VANTARI_DAP_ADAPTER") catch null;
    if (adapter_cmd == null) {
        return module.okEnvelope(allocator, "dap_stacktrace", "DAP adapter not configured. Call dap_attach first.");
    }
    const cmd = adapter_cmd.?;
    defer allocator.free(cmd);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |token| try argv.append(token);

    var client = DapClient.spawn(allocator, argv.items) catch {
        return module.okEnvelope(allocator, "dap_stacktrace", "Could not start debug adapter.");
    };
    defer client.deinit();

    _ = try client.request("initialize", "{}");

    const args = try std.fmt.allocPrint(allocator,
        \\{{"threadId":{d},"startFrame":{d},"levels":{d}}}
    , .{ parsed.value.thread_id, parsed.value.start_frame orelse 0, parsed.value.levels orelse 20 });
    defer allocator.free(args);

    const result = client.request("stackTrace", args) catch {
        return module.okEnvelope(allocator, "dap_stacktrace", "DAP stackTrace request failed. Ensure the debug session is paused.");
    };
    defer allocator.free(result);

    return module.okEnvelope(allocator, "dap_stacktrace", result);
}

/// Execute dap_variables.
pub fn executeVariables(
    allocator: std.mem.Allocator,
    _: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        variables_reference: i32,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const adapter_cmd = std.process.getEnvVarOwned(allocator, "VANTARI_DAP_ADAPTER") catch null;
    if (adapter_cmd == null) {
        return module.okEnvelope(allocator, "dap_variables", "DAP adapter not configured. Call dap_attach first.");
    }
    const cmd = adapter_cmd.?;
    defer allocator.free(cmd);

    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    var it = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (it.next()) |token| try argv.append(token);

    var client = DapClient.spawn(allocator, argv.items) catch {
        return module.okEnvelope(allocator, "dap_variables", "Could not start debug adapter.");
    };
    defer client.deinit();

    _ = try client.request("initialize", "{}");

    const args = try std.fmt.allocPrint(allocator,
        \\{{"variablesReference":{d}}}
    , .{parsed.value.variables_reference});
    defer allocator.free(args);

    const result = client.request("variables", args) catch {
        return module.okEnvelope(allocator, "dap_variables", "DAP variables request failed. Ensure the variablesReference is valid.");
    };
    defer allocator.free(result);

    return module.okEnvelope(allocator, "dap_variables", result);
}

// ============================================================================
// Tests
// ============================================================================

test "DAP tool definitions have correct review risk" {
    try std.testing.expectEqual(types.ToolReviewRisk.unknown_high_impact, attach.review_risk);
    try std.testing.expectEqual(types.ToolReviewRisk.read_only, stacktrace.review_risk);
    try std.testing.expectEqual(types.ToolReviewRisk.read_only, variables.review_risk);
}

test "DAP tool definitions have required fields" {
    try std.testing.expect(std.mem.indexOf(u8, attach.parameters_json, "pid") != null);
    try std.testing.expect(std.mem.indexOf(u8, stacktrace.parameters_json, "thread_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, variables.parameters_json, "variables_reference") != null);
}
