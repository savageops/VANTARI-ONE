const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_steps: usize,
) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "gemma-4-e2b-it"),
        .max_steps = max_steps,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn makeTestToolCall(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) !VAR1.shared.types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    };
}

fn mockSendSuccess(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"There are 3 'r's in the word \"strawberry\"."}}]}
    );
}

fn mockSendFailure(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.ConnectionRefused;
}

fn mockSendTimeout(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.ConnectionTimedOut;
}

fn mockSendLeakyOperatorReply(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"I launched the child agents. You can check progress with agent_status or wait_agent."}}]}
    );
}

const ToolLoopContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    payloads: [3]?[]u8 = .{ null, null, null },

    fn deinit(self: *ToolLoopContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

const StreamingToolLoopContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    payloads: [3]?[]u8 = .{ null, null, null },

    fn deinit(self: *StreamingToolLoopContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

const StreamRuleLoopContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    saw_injection: bool = false,
    payloads: [3]?[]u8 = .{ null, null, null },

    fn deinit(self: *StreamRuleLoopContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |relative_index| {
        count += 1;
        offset += relative_index + needle.len;
    }
    return count;
}

fn expectOneTurnTerminal(events: []const VAR1.shared.types.SessionEvent, expected_outcome: []const u8) !void {
    const TerminalPayload = struct {
        schema: []const u8,
        run_seq: u64,
        outcome: []const u8,
    };
    var count: usize = 0;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, "turn_terminal")) continue;
        count += 1;
        var parsed = try std.json.parseFromSlice(TerminalPayload, std.testing.allocator, event.message, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try std.testing.expectEqualStrings("var1.turn_terminal.v1", parsed.value.schema);
        try std.testing.expect(parsed.value.run_seq > 0);
        try std.testing.expectEqualStrings(expected_outcome, parsed.value.outcome);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

const ResumePromptContext = struct {
    allocator: std.mem.Allocator,
    payload: ?[]u8 = null,

    fn deinit(self: *ResumePromptContext) void {
        if (self.payload) |value| self.allocator.free(value);
    }
};

const ProviderCallCapture = struct {
    called: bool = false,
};

const OverflowRetryContext = struct {
    allocator: std.mem.Allocator,
    call_count: usize = 0,
    payloads: [2]?[]u8 = .{ null, null },

    fn deinit(self: *OverflowRetryContext) void {
        for (self.payloads) |payload| {
            if (payload) |value| self.allocator.free(value);
        }
    }
};

const MidTurnWakeContext = struct {
    workspace_root: []const u8,
    sender_session_id: []const u8,
    call_count: usize = 0,
    observed_wake: bool = false,
};

const CancelContext = struct {
    checks: usize = 0,
};

const EventCapture = struct {
    allocator: std.mem.Allocator,
    last_event_type: ?[]u8 = null,
    last_status: ?[]u8 = null,
    last_seq: u64 = 0,

    fn deinit(self: *EventCapture) void {
        if (self.last_event_type) |value| self.allocator.free(value);
        if (self.last_status) |value| self.allocator.free(value);
    }
};

fn captureSessionEvent(
    ctx: ?*anyopaque,
    _: []const u8,
    seq: u64,
    event_type: []const u8,
    _: []const u8,
    status: []const u8,
    _: i64,
) anyerror!void {
    var capture: *EventCapture = @ptrCast(@alignCast(ctx.?));
    if (capture.last_event_type) |value| capture.allocator.free(value);
    if (capture.last_status) |value| capture.allocator.free(value);
    capture.last_event_type = try capture.allocator.dupe(u8, event_type);
    capture.last_status = try capture.allocator.dupe(u8, status);
    capture.last_seq = seq;
}

const LocalHttpServer = struct {
    server: std.net.Server,
    response: []const u8,
    raw_response: ?[]const u8 = null,
    status: std.http.Status = .ok,
    method: ?std.http.Method = null,
    target_buffer: [256]u8 = undefined,
    target_len: usize = 0,
    authorization_ok: bool = false,
    accept_encoding_ok: bool = false,
    content_type_ok: bool = false,
    body_ok: bool = false,
    err: ?anyerror = null,

    fn serve(ctx: *LocalHttpServer) void {
        ctx.run() catch |err| {
            ctx.err = err;
        };
    }

    fn run(ctx: *LocalHttpServer) !void {
        defer ctx.server.deinit();

        var connection = try ctx.server.accept();
        defer connection.stream.close();
        var read_buffer: [1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = connection.stream.reader(&read_buffer);
        var writer = connection.stream.writer(&write_buffer);
        var server = std.http.Server.init(reader.interface(), &writer.interface);
        var request = try server.receiveHead();

        ctx.method = request.head.method;
        if (request.head.target.len > ctx.target_buffer.len) return error.HttpTargetTooLong;
        @memcpy(ctx.target_buffer[0..request.head.target.len], request.head.target);
        ctx.target_len = request.head.target.len;

        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                ctx.authorization_ok = std.mem.eql(u8, header.value, "Bearer test-key");
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) {
                ctx.accept_encoding_ok = std.mem.eql(u8, header.value, "identity");
                continue;
            }
            if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                ctx.content_type_ok = std.mem.eql(u8, header.value, "application/json");
            }
        }

        if (request.head.content_length) |content_length| {
            const body_len = std.math.cast(usize, content_length) orelse return error.HttpBodyTooLarge;
            if (body_len > 256) return error.HttpBodyTooLarge;

            var body_reader_buffer: [256]u8 = undefined;
            var body_storage: [256]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&body_reader_buffer);
            try body_reader.readSliceAll(body_storage[0..body_len]);
            ctx.body_ok = std.mem.eql(u8, body_storage[0..body_len], "{\"hello\":true}");
        }

        if (ctx.raw_response) |raw_response| {
            try writer.interface.writeAll(raw_response);
            try writer.interface.flush();
            return;
        }

        try request.respond(ctx.response, .{ .status = ctx.status });
    }
};

fn mockSendToolLoop(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":1,\"end_line\":1}"}}]}}]}
        );
    }

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"The first line in context.txt is hello from file."}}]}
    );
}

fn mockSendInvalidShellExecThenSuccess(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_bad_shell","type":"function","function":{"name":"shell_exec","arguments":"{\"mode\":\"shell\",\"argv\":[\"cmd\",\"/c\",\"find\"]}"}}]}}]}
        );
    }

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"I saw the shell_exec schema failure and corrected the command contract."}}]}
    );
}

fn mockSendMultiToolLoop(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_first","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":1,\"end_line\":1}"}},{"id":"call_second","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":2,\"end_line\":2}"}}]}}]}
        );
    }

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"The first two lines are alpha and beta."}}]}
    );
}

fn mockStreamingSendShouldNotBeUsed(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    return error.TestExpectedStreamingTransport;
}

fn mockStreamAssistantToolAssistantLoop(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
    hooks: VAR1.core.provider_runtime.StreamHooks,
) anyerror![]u8 {
    var ctx: *StreamingToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        try hooks.onAssistantDelta("I will inspect ");
        try hooks.onAssistantDelta("the file first.");
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"I will inspect the file first.","tool_calls":[{"id":"call_stream_read","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":1,\"end_line\":1}"}}]}}]}
        );
    }

    try hooks.onAssistantDelta("Observed ");
    try hooks.onAssistantDelta("alpha.");
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Observed alpha."}}]}
    );
}

fn mockStreamRuleAbortThenSuccess(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
    hooks: VAR1.core.provider_runtime.StreamHooks,
) anyerror![]u8 {
    var ctx: *StreamRuleLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);
    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        try hooks.onAssistantDelta("The unsafe branch begins with eval(");
        if (!hooks.shouldAbort()) return error.TestStreamAbortNotRequested;
        return error.StreamAborted;
    }

    ctx.saw_injection = std.mem.indexOf(u8, payload, "[Stream rule 'no-eval' triggered]") != null;
    try hooks.onAssistantDelta("Safe completion.");
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Safe completion."}}]}
    );
}

fn mockSendToolLoopOverflowThenSuccess(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_retry_boundary","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\",\"start_line\":1,\"end_line\":1}"}}]}}]}
        );
    }
    if (ctx.call_count == 1) return error.ContextWindowExceeded;

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Recovered with the sentinel exactly once."}}]}
    );
}

fn mockSendBlockedToolLoop(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);

    defer ctx.call_count += 1;

    if (ctx.call_count == 0) {
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_blocked","type":"function","function":{"name":"unknown_runtime_mutation","arguments":"{\"path\":\"context.txt\"}"}}]}}]}
        );
    }

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"The runtime blocked the undeclared capability."}}]}
    );
}

fn mockSendOverBudgetToolBatch(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ToolLoopContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);
    defer ctx.call_count += 1;

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\"}"}},{"id":"call_2","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\"}"}},{"id":"call_3","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"context.txt\"}"}}]}}]}
    );
}

fn mockSendResumePrompt(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *ResumePromptContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.payload) |value| ctx.allocator.free(value);
    ctx.payload = try ctx.allocator.dupe(u8, payload);

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"3"}}]}
    );
}

fn mockSendMidTurnWake(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *MidTurnWakeContext = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.call_count += 1;
    if (ctx.call_count == 1) {
        var receipt = try VAR1.core.agent_mailbox.send(allocator, ctx.workspace_root, .{
            .sender_session_id = ctx.sender_session_id,
            .tool_call_id = "mid-provider-wake",
            .target = .parent,
            .delivery = .wake,
            .body = "MID_TURN_WAKE_SENTINEL_529",
        });
        defer receipt.deinit(allocator);
        return allocator.dupe(u8,
            \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Provider progress before wake."}}]}
        );
    }
    ctx.observed_wake = std.mem.indexOf(u8, payload, "MID_TURN_WAKE_SENTINEL_529") != null;
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Wake incorporated at the next safe boundary."}}]}
    );
}

fn mockSendOverflowThenSuccess(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    payload: []const u8,
) anyerror![]u8 {
    var ctx: *OverflowRetryContext = @ptrCast(@alignCast(ctx_ptr.?));
    if (ctx.call_count < ctx.payloads.len) {
        ctx.payloads[ctx.call_count] = try ctx.allocator.dupe(u8, payload);
    }

    defer ctx.call_count += 1;
    if (ctx.call_count == 0) return error.ContextWindowExceeded;

    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"Recovered after compaction."}}]}
    );
}

fn mockSendShouldNotRun(
    ctx_ptr: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    var ctx: *ProviderCallCapture = @ptrCast(@alignCast(ctx_ptr.?));
    ctx.called = true;
    return allocator.dupe(u8,
        \\{"model":"gemma-4-e2b-it","choices":[{"message":{"content":"provider should not have run"}}]}
    );
}

fn shouldCancelOnFirstCheck(ctx_ptr: ?*anyopaque, _: []const u8) bool {
    var ctx: *CancelContext = @ptrCast(@alignCast(ctx_ptr.?));
    defer ctx.checks += 1;
    return ctx.checks == 0;
}

test "provider parses a mock OpenAI-compatible chat completion" {
    const config = try makeConfig(std.testing.allocator, ".", 4);
    defer config.deinit(std.testing.allocator);

    var messages = [_]VAR1.shared.types.ChatMessage{
        try VAR1.shared.types.initTextMessage(std.testing.allocator, .user, "how many r in strawberry"),
    };
    defer messages[0].deinit(std.testing.allocator);

    const completion = try VAR1.core.provider_runtime.completeWithTransport(std.testing.allocator, config, .{
        .messages = messages[0..],
        .tool_definitions = VAR1.core.tool_runtime.builtinDefinitions(false),
    }, .{
        .context = null,
        .sendFn = mockSendSuccess,
    });
    defer completion.deinit(std.testing.allocator);

    try std.testing.expect(!completion.hasToolCalls());
    try std.testing.expect(std.mem.indexOf(u8, completion.content.?, "3") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion.content.?, "strawberry") != null);
}

test "provider completion url keeps explicit versioned bases intact" {
    const versioned = try VAR1.core.provider_runtime.completionUrl(std.testing.allocator, "https://api.z.ai/api/coding/paas/v4");
    defer std.testing.allocator.free(versioned);

    const local = try VAR1.core.provider_runtime.completionUrl(std.testing.allocator, "http://127.0.0.1:1234");
    defer std.testing.allocator.free(local);

    try std.testing.expectEqualStrings("https://api.z.ai/api/coding/paas/v4/chat/completions", versioned);
    try std.testing.expectEqualStrings("http://127.0.0.1:1234/v1/chat/completions", local);
}

test "provider native http transport posts JSON over a single in-process path" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "{\"ok\":true}",
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    const body = try VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    );
    defer std.testing.allocator.free(body);

    if (local_server.err) |err| return err;

    try std.testing.expectEqualStrings("{\"ok\":true}", body);
    try std.testing.expectEqual(.POST, local_server.method.?);
    try std.testing.expectEqualStrings("/v1/chat/completions", local_server.target_buffer[0..local_server.target_len]);
    try std.testing.expect(local_server.authorization_ok);
    try std.testing.expect(local_server.accept_encoding_ok);
    try std.testing.expect(local_server.content_type_ok);
    try std.testing.expect(local_server.body_ok);
}

test "provider native http transport classifies context overflow status" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "{\"error\":{\"message\":\"maximum context length exceeded\"}}",
        .status = .payload_too_large,
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.ContextWindowExceeded, VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    ));

    if (local_server.err) |err| return err;
}

test "provider native http transport classifies malformed response headers" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "",
        .raw_response = "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n",
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.MalformedHttpResponse, VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    ));

    if (local_server.err) |err| return err;
}

test "provider native http transport classifies short declared bodies" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "",
        .raw_response = "HTTP/1.1 200 OK\r\ncontent-length: 8\r\n\r\n{}",
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.ShortHttpResponseBody, VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    ));

    if (local_server.err) |err| return err;
}

test "provider native http transport classifies malformed chunk boundaries" {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const server = try address.listen(.{ .reuse_address = true });

    var local_server = LocalHttpServer{
        .server = server,
        .response = "",
        .raw_response = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n2\r\nabXX",
    };

    const thread = try std.Thread.spawn(.{}, LocalHttpServer.serve, .{&local_server});
    defer thread.join();

    const url = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/chat/completions",
        .{local_server.server.listen_address.getPort()},
    );
    defer std.testing.allocator.free(url);

    try std.testing.expectError(error.MalformedChunkedResponse, VAR1.core.provider_runtime.httpSend(
        null,
        std.testing.allocator,
        url,
        "test-key",
        "{\"hello\":true}",
    ));

    if (local_server.err) |err| return err;
}

test "loop writes runtime state and archives docs on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var capture = EventCapture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "how many r in strawberry", .{
        .transport = .{
            .context = null,
            .sendFn = mockSendSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .hooks = .{
            .context = &capture,
            .onSessionEventFn = captureSessionEvent,
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "3") != null);
    try std.testing.expectEqualStrings("turn_terminal", capture.last_event_type.?);
    try std.testing.expectEqualStrings("completed", capture.last_status.?);
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expect(events.len > 0);
    try std.testing.expectEqual(events[events.len - 1].seq, capture.last_seq);
    try std.testing.expectEqualStrings(events[events.len - 1].event_type, capture.last_event_type.?);
    try expectOneTurnTerminal(events, "completed");
}

test "loop can resume a precreated child session and preserve delegation metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var child_session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .initialized,
            .parent_session_id = "session-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer child_session.deinit(std.testing.allocator);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = child_session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(child_session.id, result.session_id);

    var persisted = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, child_session.id);
    defer persisted.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.completed, persisted.status);
    try std.testing.expectEqualStrings("session-parent", persisted.parent_session_id.?);
    try std.testing.expectEqualStrings("berry-child", persisted.display_name.?);
    try std.testing.expectEqualStrings("subagent", persisted.agent_profile.?);
    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "how many r in strawberry") != null);
}

test "loop injects unread agent mail once and acknowledges only provider observation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);
    const config = try makeConfig(allocator, workspace_root, 4);
    defer config.deinit(allocator);

    var recipient = try VAR1.core.session_store.initSession(allocator, workspace_root, "recipient prompt");
    defer recipient.deinit(allocator);
    var sender = try VAR1.core.session_store.initSessionWithOptions(allocator, workspace_root, "sender prompt", .{
        .parent_session_id = recipient.id,
        .display_name = "mail-sender",
        .agent_profile = "recon",
    });
    defer sender.deinit(allocator);

    var receipt = try VAR1.core.agent_mailbox.send(allocator, workspace_root, .{
        .sender_session_id = sender.id,
        .tool_call_id = "mail-before-run",
        .target = .parent,
        .delivery = .queue,
        .body = "MAIL_CONTEXT_SENTINEL_731",
        .references = &.{"artifact:apps/backend/src/core/agents/mailbox.zig"},
    });
    defer receipt.deinit(allocator);

    var first_capture = ResumePromptContext{ .allocator = allocator };
    defer first_capture.deinit();
    const first = try VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = .{ .context = &first_capture, .sendFn = mockSendResumePrompt },
        .execution_context = .{ .workspace_root = config.workspace_root },
        .session_id = recipient.id,
    });
    defer first.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, first_capture.payload.?, "AGENT_MAILBOX") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_capture.payload.?, "MAIL_CONTEXT_SENTINEL_731") != null);

    const messages = try VAR1.core.session_store.readSessionMessages(allocator, workspace_root, recipient.id);
    defer VAR1.shared.types.deinitSessionMessages(allocator, messages);
    for (messages) |message| {
        try std.testing.expect(std.mem.indexOf(u8, message.content, "MAIL_CONTEXT_SENTINEL_731") == null);
    }

    const events = try VAR1.core.session_store.readEvents(allocator, workspace_root, recipient.id);
    defer VAR1.shared.types.deinitSessionEvents(allocator, events);
    var cursor_count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.cursor_event_type)) cursor_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), cursor_count);

    var second_capture = ResumePromptContext{ .allocator = allocator };
    defer second_capture.deinit();
    const second = try VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = .{ .context = &second_capture, .sendFn = mockSendResumePrompt },
        .execution_context = .{ .workspace_root = config.workspace_root },
        .session_id = recipient.id,
    });
    defer second.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, second_capture.payload.?, "MAIL_CONTEXT_SENTINEL_731") == null);
}

test "loop leaves agent mail unread when provider observation fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);
    const config = try makeConfig(allocator, workspace_root, 4);
    defer config.deinit(allocator);

    var recipient = try VAR1.core.session_store.initSession(allocator, workspace_root, "recipient prompt");
    defer recipient.deinit(allocator);
    var sender = try VAR1.core.session_store.initSessionWithOptions(allocator, workspace_root, "sender prompt", .{
        .parent_session_id = recipient.id,
    });
    defer sender.deinit(allocator);
    var receipt = try VAR1.core.agent_mailbox.send(allocator, workspace_root, .{
        .sender_session_id = sender.id,
        .tool_call_id = "mail-before-failure",
        .target = .parent,
        .delivery = .queue,
        .body = "MAIL_REPLAY_SENTINEL_947",
    });
    defer receipt.deinit(allocator);

    try std.testing.expectError(error.ConnectionRefused, VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = .{ .context = null, .sendFn = mockSendFailure },
        .execution_context = .{ .workspace_root = config.workspace_root },
        .session_id = recipient.id,
    }));
    const failed_events = try VAR1.core.session_store.readEvents(allocator, workspace_root, recipient.id);
    defer VAR1.shared.types.deinitSessionEvents(allocator, failed_events);
    for (failed_events) |event| {
        try std.testing.expect(!std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.cursor_event_type));
    }

    var capture = ResumePromptContext{ .allocator = allocator };
    defer capture.deinit();
    const recovered = try VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = .{ .context = &capture, .sendFn = mockSendResumePrompt },
        .execution_context = .{ .workspace_root = config.workspace_root },
        .session_id = recipient.id,
    });
    defer recovered.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, capture.payload.?, "MAIL_REPLAY_SENTINEL_947") != null);
}

test "wake mail arriving during provider execution forces one safe-boundary continuation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);
    const config = try makeConfig(allocator, workspace_root, 4);
    defer config.deinit(allocator);

    var recipient = try VAR1.core.session_store.initSession(allocator, workspace_root, "recipient prompt");
    defer recipient.deinit(allocator);
    var sender = try VAR1.core.session_store.initSessionWithOptions(allocator, workspace_root, "sender prompt", .{
        .parent_session_id = recipient.id,
    });
    defer sender.deinit(allocator);

    var context = MidTurnWakeContext{
        .workspace_root = workspace_root,
        .sender_session_id = sender.id,
    };
    const result = try VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = .{ .context = &context, .sendFn = mockSendMidTurnWake },
        .execution_context = .{ .workspace_root = config.workspace_root },
        .session_id = recipient.id,
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(context.observed_wake);
    try std.testing.expectEqualStrings("Wake incorporated at the next safe boundary.", result.output);

    const messages = try VAR1.core.session_store.readSessionMessages(allocator, workspace_root, recipient.id);
    defer VAR1.shared.types.deinitSessionMessages(allocator, messages);
    for (messages) |message| {
        try std.testing.expect(std.mem.indexOf(u8, message.content, "MID_TURN_WAKE_SENTINEL_529") == null);
    }
    const events = try VAR1.core.session_store.readEvents(allocator, workspace_root, recipient.id);
    defer VAR1.shared.types.deinitSessionEvents(allocator, events);
    var progress_count: usize = 0;
    var cursor_count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "assistant_progress")) progress_count += 1;
        if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.cursor_event_type)) cursor_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), progress_count);
    try std.testing.expectEqual(@as(usize, 1), cursor_count);
}

test "loop resumes a same-session transcript from canonical messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "What is VAR1?",
        .{
            .status = .completed,
        },
    );
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "VAR1 is the Zig kernel.");
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "VAR1 is the Zig kernel.", std.time.milliTimestamp());
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Can I continue the conversation?", std.time.milliTimestamp());
    try VAR1.core.session_store.setSessionPrompt(std.testing.allocator, workspace_root, &session, "Can I continue the conversation?", .initialized);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(session.id, result.session_id);

    const payload = context.payload.?;
    try std.testing.expect(std.mem.indexOf(u8, payload, "What is VAR1?") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "VAR1 is the Zig kernel.") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Can I continue the conversation?") != null);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);
    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("3", messages[3].content);
}

test "loop auto-compacts before provider call when policy threshold is crossed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.context_policy = .{
        .auto_compaction = true,
        .context_window_tokens = 80,
        .compact_at_ratio_milli = 500,
        .reserve_output_tokens = 10,
        .keep_recent_messages = 2,
        .max_entries_per_checkpoint = 0,
        .aggressiveness_milli = 350,
    };

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt with enough words to matter.");
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer with enough words to matter.", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt with enough words to matter.", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer with enough words to matter.", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt with enough words to matter.", 500);

    var context = ResumePromptContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendResumePrompt,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "VAR1 context checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payload.?, "Final prompt with enough words") != null);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "auto_threshold") != null);
}

test "loop retries once after provider-declared context overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.context_policy = .{
        .auto_compaction = false,
        .retry_on_provider_overflow = true,
        .context_window_tokens = 80,
        .compact_at_ratio_milli = 500,
        .reserve_output_tokens = 10,
        .keep_recent_messages = 2,
        .max_entries_per_checkpoint = 0,
        .aggressiveness_milli = 350,
    };

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt before overflow.");
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer before overflow.", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt before overflow.", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer before overflow.", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt before overflow.", 500);

    var context = OverflowRetryContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &context,
            .sendFn = mockSendOverflowThenSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Recovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "VAR1 context checkpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "VAR1 context checkpoint") != null);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "provider_overflow") != null);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    // Event spine: session_started, turn_started (step 0), context compaction,
    // assistant_response, then one typed terminal row.
    try std.testing.expect(events.len >= 5);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("turn_started", events[1].event_type);
    try std.testing.expectEqualStrings("context_compaction_started", events[2].event_type);
    try std.testing.expectEqualStrings("context_compaction_completed", events[3].event_type);
    try std.testing.expectEqualStrings("turn_terminal", events[events.len - 1].event_type);
    try expectOneTurnTerminal(events, "completed");
    try std.testing.expect(std.mem.indexOf(u8, events[2].message, "provider_overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[3].message, "source_seq=") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[3].message, "first_kept_seq=") != null);
}

test "loop records a failed session when provider transport fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var capture = EventCapture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    try std.testing.expectError(error.ConnectionRefused, VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "how many r in strawberry", .{
        .transport = .{
            .context = null,
            .sendFn = mockSendFailure,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .hooks = .{
            .context = &capture,
            .onSessionEventFn = captureSessionEvent,
        },
    }));

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, sessions[0].status);
    try std.testing.expect(std.mem.eql(u8, sessions[0].failure_reason.?, "ConnectionRefused"));

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, sessions[0].id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    // Event spine: session_started, turn_started, then one failed terminal.
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("turn_started", events[1].event_type);
    try std.testing.expectEqualStrings("turn_terminal", events[2].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[2].message, "ConnectionRefused") != null);
    try expectOneTurnTerminal(events, "failed");
    try std.testing.expectEqualStrings("turn_terminal", capture.last_event_type.?);
    try std.testing.expectEqualStrings("failed", capture.last_status.?);
}

test "loop preserves provider timeout as a distinct terminal outcome" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectError(error.ConnectionTimedOut, VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "timeout", .{
        .transport = .{ .context = null, .sendFn = mockSendTimeout },
        .execution_context = .{ .workspace_root = config.workspace_root },
    }));

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, sessions[0].id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try expectOneTurnTerminal(events, "timed_out");
}

test "loop marks a session cancelled when hooks request cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Cancel me");
    defer session.deinit(std.testing.allocator);

    var cancel_context = CancelContext{};
    try std.testing.expectError(VAR1.core.executor.Error.Cancelled, VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = null,
            .sendFn = mockSendSuccess,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
        .hooks = .{
            .context = &cancel_context,
            .shouldCancelFn = shouldCancelOnFirstCheck,
        },
    }));

    var persisted = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.cancelled, persisted.status);

    const latest_event = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event != null);
    try std.testing.expectEqualStrings("turn_terminal", latest_event.?.event_type);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("turn_terminal", events[1].event_type);
    try expectOneTurnTerminal(events, "cancelled");
}

test "loop sanitizes leaked internal tool names without false child-wait messaging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "launch three child agents and keep me posted", .{
        .context = null,
        .sendFn = mockSendLeakyOperatorReply,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "agent_status") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wait_agent") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "child-run status checks") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "child-run wait checks") != null);
    try std.testing.expect(!std.mem.eql(u8, result.output, "I will continue once agents complete; if any fail, I will follow up."));
}

test "loop allows internal tool names when prompt requests tool documentation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Document launch_agent, agent_status, wait_agent, and list_agents usage.", .{
        .context = null,
        .sendFn = mockSendLeakyOperatorReply,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "agent_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "wait_agent") != null);
}

test "loop executes tool calls and exposes descriptors in the provider payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "hello from file\nsecond line\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and tell me the first line.", .{
        .context = &context,
        .sendFn = mockSendToolLoop,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello from file") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "search_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "todo_slice") == null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "hello from file") != null);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "tool_requested") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_reviewed") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_finished") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "var1.tool_started.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "var1.tool_finished.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\\\"duration_ms\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_requested").? < std.mem.indexOf(u8, events, "tool_reviewed").?);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_reviewed").? < std.mem.indexOf(u8, events, "tool_started").?);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_started").? < std.mem.indexOf(u8, events, "tool_finished").?);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_finished").? < std.mem.indexOf(u8, events, "tool_completed").?);

    const transcript = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, transcript);
    try std.testing.expectEqual(@as(usize, 4), transcript.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.user, transcript[0].role);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, transcript[1].role);
    try std.testing.expectEqual(@as(usize, 1), transcript[1].tool_calls.len);
    try std.testing.expectEqualStrings("call_1", transcript[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", transcript[1].tool_calls[0].name);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.tool, transcript[2].role);
    try std.testing.expectEqualStrings("call_1", transcript[2].tool_call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, transcript[2].content, "hello from file") != null);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, transcript[3].role);
}

test "loop turns malformed shell_exec arguments into provider-visible repair evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Count tests with a Windows-safe command.", .{
        .context = &context,
        .sendFn = mockSendInvalidShellExecThenSuccess,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "schema failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\\\"error\\\":\\\"InvalidArguments\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\\\"usage_hint\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "Use mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "Select-String") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "find/findstr") != null);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "var1.tool_finished.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\\\"error_name\\\":\\\"InvalidArguments\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\\\"hint\\\":\\\"Use mode=argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "Select-String") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_finished").? < std.mem.indexOf(u8, events, "tool_completed").?);
}

test "loop persists streamed assistant deltas around tool execution without collapsing phase order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "alpha\nbeta\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 5);
    defer config.deinit(std.testing.allocator);

    var context = StreamingToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and narrate the tool step while streaming.", .{
        .context = &context,
        .sendFn = mockStreamingSendShouldNotBeUsed,
        .streamFn = mockStreamAssistantToolAssistantLoop,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[0].?, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Observed alpha.") != null);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    const first_delta = std.mem.indexOf(u8, events, "I will inspect").?;
    const tool_requested = std.mem.indexOf(u8, events, "tool_requested").?;
    const tool_started = std.mem.indexOf(u8, events, "tool_started").?;
    const tool_finished = std.mem.indexOf(u8, events, "tool_finished").?;
    const second_delta = std.mem.indexOfPos(u8, events, tool_finished, "Observed").?;
    const final_response = std.mem.indexOf(u8, events, "assistant_response").?;

    try std.testing.expect(first_delta < tool_requested);
    try std.testing.expect(tool_requested < tool_started);
    try std.testing.expect(tool_started < tool_finished);
    try std.testing.expect(tool_finished < second_delta);
    try std.testing.expect(second_delta < final_response);
    try std.testing.expectEqual(@as(usize, 4), countOccurrences(events, "assistant_delta"));
    try std.testing.expect(std.mem.indexOf(u8, events, "call_stream_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "var1.tool_finished.v1") != null);
}

test "loop aborts TTSR before terminal state and retries with durable correction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = StreamRuleLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(
        std.testing.allocator,
        config,
        "Produce a safe answer.",
        .{
            .context = &context,
            .sendFn = mockStreamingSendShouldNotBeUsed,
            .streamFn = mockStreamRuleAbortThenSuccess,
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(context.saw_injection);
    try std.testing.expectEqualStrings("Safe completion.", result.output);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    var rule_index: ?usize = null;
    var assistant_response_index: ?usize = null;
    var terminal_count: usize = 0;
    for (events, 0..) |event, index| {
        if (std.mem.eql(u8, event.event_type, "rule_injected")) rule_index = index;
        if (assistant_response_index == null and std.mem.eql(u8, event.event_type, "assistant_response")) {
            assistant_response_index = index;
        }
        if (std.mem.eql(u8, event.event_type, "turn_terminal")) terminal_count += 1;
    }
    try std.testing.expect(rule_index != null);
    try std.testing.expect(assistant_response_index != null);
    try std.testing.expect(rule_index.? < assistant_response_index.?);
    try std.testing.expectEqual(@as(usize, 1), terminal_count);
    try std.testing.expectEqualStrings("turn_terminal", events[events.len - 1].event_type);

    const transcript = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, transcript);
    var correction_count: usize = 0;
    for (transcript) |message| {
        if (message.role == .user and std.mem.indexOf(u8, message.content, "[Stream rule 'no-eval' triggered]") != null) {
            correction_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), correction_count);
}

test "loop persists multi-tool batches in assistant source order before follow-up context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "alpha\nbeta\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read the first two lines in context.txt.", .{
        .context = &context,
        .sendFn = mockSendMultiToolLoop,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "beta") != null);
    try std.testing.expectEqual(@as(usize, 2), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    const first_payload_index = std.mem.indexOf(u8, context.payloads[1].?, "call_first").?;
    const second_payload_index = std.mem.indexOf(u8, context.payloads[1].?, "call_second").?;
    try std.testing.expect(first_payload_index < second_payload_index);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);
    const request_event_index = std.mem.indexOf(u8, events, "tool_requested").?;
    const first_completed_index = std.mem.indexOf(u8, events, "tool completed: read_file").?;
    const response_event_index = std.mem.indexOf(u8, events, "assistant_response").?;
    try std.testing.expect(request_event_index < first_completed_index);
    try std.testing.expect(first_completed_index < response_event_index);

    const transcript = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, transcript);
    try std.testing.expectEqual(@as(usize, 5), transcript.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.user, transcript[0].role);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, transcript[1].role);
    try std.testing.expectEqual(@as(usize, 2), transcript[1].tool_calls.len);
    try std.testing.expectEqualStrings("call_first", transcript[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("call_second", transcript[1].tool_calls[1].id);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.tool, transcript[2].role);
    try std.testing.expectEqualStrings("call_first", transcript[2].tool_call_id.?);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.tool, transcript[3].role);
    try std.testing.expectEqualStrings("call_second", transcript[3].tool_call_id.?);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, transcript[4].role);
}

test "loop rebuilds provider payload after tool overflow without duplicating durable tool context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "READ_RESULT_SENTINEL_829\n");

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.context_policy = .{
        .auto_compaction = false,
        .retry_on_provider_overflow = true,
        .context_window_tokens = 80,
        .compact_at_ratio_milli = 500,
        .reserve_output_tokens = 10,
        .keep_recent_messages = 1,
        .max_entries_per_checkpoint = 0,
        .aggressiveness_milli = 350,
    };

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and return the first line.", .{
        .context = &context,
        .sendFn = mockSendToolLoopOverflowThenSuccess,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Recovered") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[2].?, "VAR1 context checkpoint") != null);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(context.payloads[2].?, "call_retry_boundary"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(context.payloads[2].?, "\"role\":\"tool\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(context.payloads[2].?, "READ_RESULT_SENTINEL_829"));

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "provider_overflow") != null);
}

test "loop self-heals unresolved persisted tool calls before provider dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Read context.txt");
    defer session.deinit(std.testing.allocator);

    var tool_call = try makeTestToolCall(std.testing.allocator, "call_unresolved", "read_file", "{\"path\":\"context.txt\"}");
    defer tool_call.deinit(std.testing.allocator);
    const tool_calls = [_]VAR1.shared.types.ToolCall{tool_call};
    try VAR1.core.session_store.appendAssistantToolCallSessionMessage(
        std.testing.allocator,
        workspace_root,
        session.id,
        null,
        tool_calls[0..],
        null,
        200,
    );

    // Self-healing: the builder synthesizes a missing tool result for the
    // unresolved tool call. The loop should proceed to the provider and
    // complete the session — NOT hard-fail with UnresolvedToolCallTranscript.
    var capture = ProviderCallCapture{};
    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{
            .context = &capture,
            .sendFn = mockSendShouldNotRun,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .session_id = session.id,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(capture.called);

    var completed = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer completed.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.completed, completed.status);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var diagnostic_seen = false;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, VAR1.shared.protocol.events.context_compile_diagnostic_event_type)) {
            diagnostic_seen = true;
            try std.testing.expect(std.mem.indexOf(u8, event.message, "var1.context_compile_diagnostic.v1") != null);
            try std.testing.expect(std.mem.indexOf(u8, event.message, "\"synthesized_tool_results\":1") != null);
            try std.testing.expect(std.mem.indexOf(u8, event.message, "\"skipped_tool_results\":0") != null);
        }
    }
    try std.testing.expect(diagnostic_seen);
}

test "loop blocks undeclared tool calls before execution and returns protocol-visible denial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    const result = try VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Try the undeclared mutation.", .{
        .context = &context,
        .sendFn = mockSendBlockedToolLoop,
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "blocked the undeclared capability") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "\"role\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "ToolReviewBlocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, context.payloads[1].?, "UnknownTool") == null);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", result.session_id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "tool_requested") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_reviewed") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_completed") == null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_requested").? < std.mem.indexOf(u8, events, "tool_reviewed").?);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_reviewed").? < std.mem.indexOf(u8, events, "tool_blocked").?);

    const transcript = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, transcript);
    try std.testing.expectEqual(@as(usize, 4), transcript.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.tool, transcript[2].role);
    try std.testing.expectEqualStrings("call_blocked", transcript[2].tool_call_id.?);
    try std.testing.expect(std.mem.indexOf(u8, transcript[2].content, "ToolReviewBlocked") != null);
}

test "loop enforces the step budget when tool use does not conclude in time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "hello from file\n");

    const config = try makeConfig(std.testing.allocator, workspace_root, 1);
    defer config.deinit(std.testing.allocator);

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    try std.testing.expectError(VAR1.core.executor.Error.StepLimitExceeded, VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt and tell me the first line.", .{
        .context = &context,
        .sendFn = mockSendToolLoop,
    }));
}

test "loop enforces the per-turn tool budget before dispatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const file_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "context.txt" });
    defer std.testing.allocator.free(file_path);
    try VAR1.shared.fsutil.writeText(file_path, "hello from file\n");

    var config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);
    config.max_tool_calls_per_turn = 2;
    config.max_tool_calls_per_session = 8;

    var context = ToolLoopContext{ .allocator = std.testing.allocator };
    defer context.deinit();

    try std.testing.expectError(VAR1.core.executor.Error.ToolBudgetExceeded, VAR1.core.executor.runPromptWithTransport(std.testing.allocator, config, "Read context.txt several times.", .{
        .context = &context,
        .sendFn = mockSendOverBudgetToolBatch,
    }));

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, sessions[0].status);
    try std.testing.expectEqualStrings("ToolBudgetExceeded", sessions[0].failure_reason.?);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", sessions[0].id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_budget_exceeded") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "tool_completed") == null);
}

fn mockSendEmptyResponse(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: []const u8,
) anyerror![]u8 {
    // Provider returns a structurally valid response with no content and no
    // tool calls. The loop must handle this gracefully without crashing.
    return allocator.dupe(u8,
        \\{"model":"test","choices":[{"message":{"content":""}}]}
    );
}

test "loop completes gracefully when provider returns empty response" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 3);
    defer config.deinit(std.testing.allocator);

    var capture = EventCapture{ .allocator = std.testing.allocator };
    defer capture.deinit();

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "empty response test", .{
        .transport = .{
            .context = null,
            .sendFn = mockSendEmptyResponse,
        },
        .execution_context = .{
            .workspace_root = config.workspace_root,
        },
        .hooks = .{
            .context = &capture,
            .onSessionEventFn = captureSessionEvent,
        },
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("completed", capture.last_status.?);
    try std.testing.expectEqualStrings("turn_terminal", capture.last_event_type.?);
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, result.session_id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try expectOneTurnTerminal(events, "completed");
}

// =============================================================================
// Branch-and-converge wired path probes (roadmap P0-1, P0-2, P0-4b)
// These tests verify the shard ledger is live, not just unit-tested.
// =============================================================================

fn seedParentAndBranch(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    branch_prompt: []const u8,
    agent_name: []const u8,
) !struct { parent_id: []u8, child_id: []u8 } {
    var parent = try VAR1.core.session_store.initSession(allocator, workspace_root, "parent task");
    defer parent.deinit(allocator);

    var cp = VAR1.shared.types.ContextCheckpoint{
        .id = try allocator.dupe(u8, "parent-cp-1"),
        .entry_type = try allocator.dupe(u8, "compaction"),
        .created_at_ms = 1000,
        .source_seq_start = 0,
        .source_seq_end = 5,
        .first_kept_seq = 3,
        .tokens_before_estimate = 1000,
        .tokens_after_estimate = 500,
        .aggressiveness_milli = 500,
        .compacted_entry_count = 3,
        .trigger = try allocator.dupe(u8, "auto"),
        .summary = try allocator.dupe(u8, "Parent context summary."),
    };
    defer cp.deinit(allocator);
    try VAR1.core.session_store.appendContextCheckpoint(allocator, workspace_root, parent.id, cp);

    var child = try VAR1.core.session_store.initSessionWithOptions(allocator, workspace_root, branch_prompt, .{
        .status = .initialized,
        .parent_session_id = parent.id,
        .display_name = agent_name,
        .agent_profile = "default_subagent",
    });
    defer child.deinit(allocator);

    const branch_summary = try std.fmt.allocPrint(allocator, "Branch 1 ({s}): {s}", .{ agent_name, branch_prompt });
    defer allocator.free(branch_summary);
    try VAR1.core.session_store.appendShardCheckpoint(
        allocator,
        workspace_root,
        parent.id,
        "parent-cp-1",
        1,
        .open,
        branch_summary,
    );

    return .{
        .parent_id = try allocator.dupe(u8, parent.id),
        .child_id = try allocator.dupe(u8, child.id),
    };
}

test "launch writes open shard checkpoint to parent context.jsonl" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var service = VAR1.core.agent_runtime.Service.init(&config);
    _ = service.handle();

    const refs = try seedParentAndBranch(std.testing.allocator, workspace_root, "Research topic A", "scout-a");
    defer std.testing.allocator.free(refs.parent_id);
    defer std.testing.allocator.free(refs.child_id);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", refs.parent_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);

    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "shard_checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "parent_checkpoint_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "scout-a") != null);
}

test "convergence writes converged shard checkpoint and merged message to parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const refs = try seedParentAndBranch(std.testing.allocator, workspace_root, "Research topic A", "scout-a");
    defer std.testing.allocator.free(refs.parent_id);
    defer std.testing.allocator.free(refs.child_id);

    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, refs.child_id, "Found 3 relevant files in src/core/.");
    var child_session = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, refs.child_id);
    defer child_session.deinit(std.testing.allocator);
    try VAR1.core.session_store.setSessionStatus(std.testing.allocator, workspace_root, &child_session, .completed);

    var service = VAR1.core.agent_runtime.Service.init(&config);
    const agent_service = service.handle();
    try agent_service.converge(std.testing.allocator, refs.parent_id);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", refs.parent_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "\"converged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "Converged 1 branch") != null);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, refs.parent_id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var found_converge_event = false;
    for (events) |ev| {
        if (std.mem.eql(u8, ev.event_type, "branch_converged")) {
            found_converge_event = true;
            break;
        }
    }
    try std.testing.expect(found_converge_event);
}

test "cold start reconciles orphaned open shards as abandoned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const refs = try seedParentAndBranch(std.testing.allocator, workspace_root, "Research topic B", "scout-b");
    defer std.testing.allocator.free(refs.parent_id);
    defer std.testing.allocator.free(refs.child_id);

    var service = VAR1.core.agent_runtime.Service.init(&config);
    const agent_service = service.handle();
    const abandoned = try agent_service.reconcile(std.testing.allocator, refs.parent_id);
    try std.testing.expectEqual(@as(usize, 1), abandoned);

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", refs.parent_id, "context.jsonl" });
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "\"abandoned\"") != null);

    const abandoned_again = try agent_service.reconcile(std.testing.allocator, refs.parent_id);
    try std.testing.expectEqual(@as(usize, 0), abandoned_again);
}

test "convergence leaves parent transcript append-only (byte-identical prefix)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    const refs = try seedParentAndBranch(std.testing.allocator, workspace_root, "Research topic C", "scout-c");
    defer std.testing.allocator.free(refs.parent_id);
    defer std.testing.allocator.free(refs.child_id);

    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, refs.child_id, "Result C.");
    var child_session = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, refs.child_id);
    defer child_session.deinit(std.testing.allocator);
    try VAR1.core.session_store.setSessionStatus(std.testing.allocator, workspace_root, &child_session, .completed);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", refs.parent_id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);
    const before = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(before);

    var service = VAR1.core.agent_runtime.Service.init(&config);
    const agent_service = service.handle();
    try agent_service.converge(std.testing.allocator, refs.parent_id);

    const after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(after);

    try std.testing.expect(after.len > before.len);
    try std.testing.expectEqualStrings(before, after[0..before.len]);
}
