const std = @import("std");
const agents = @import("agents.zig");
const docs_sync = @import("docs_sync.zig");
const loop = @import("loop.zig");
const provider = @import("provider.zig");
const store = @import("store.zig");
const types = @import("types.zig");

const workbench_html = @embedFile("ui/index.html");
const max_request_body_bytes = 64 * 1024;
const connection_read_buffer_size = 16 * 1024;
const connection_write_buffer_size = 16 * 1024;

pub const ServeOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4310,
    transport: provider.Transport,
};

const App = struct {
    config: *const types.Config,
    transport: provider.Transport,
};

const Response = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

const CreateTaskRequest = struct {
    prompt: []const u8,
    continue_from_task_id: ?[]const u8 = null,
};

const TaskMessageRequest = struct {
    prompt: []const u8,
};

const BackgroundRun = struct {
    config: types.Config,
    task_id: []u8,
    transport: provider.Transport,

    fn deinit(self: *BackgroundRun) void {
        const allocator = std.heap.page_allocator;
        self.config.deinit(allocator);
        allocator.free(self.task_id);
        allocator.destroy(self);
    }
};

pub fn serve(allocator: std.mem.Allocator, config: types.Config, options: ServeOptions) !void {
    const address = try std.net.Address.parseIp(options.host, options.port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();

    const app = App{
        .config = &config,
        .transport = options.transport,
    };

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.print(
        "VAR1 workbench listening on http://{s}:{d}\n",
        .{ options.host, options.port },
    );
    try stdout_writer.interface.flush();

    while (true) {
        var connection = try listener.accept();
        handleConnection(allocator, &app, &connection) catch |err| {
            logRuntimeError("http_connection", null, err);
        };
    }
}

pub fn route(
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) !Response {
    const app = App{
        .config = config,
        .transport = transport,
    };
    return routeApp(allocator, &app, method, target, body);
}

fn handleConnection(
    allocator: std.mem.Allocator,
    app: *const App,
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

    const body = try readRequestBody(allocator, &request);
    defer allocator.free(body);

    const response = routeApp(allocator, app, request.head.method, target, body) catch |err| {
        const failure = try jsonErrorResponse(allocator, .internal_server_error, @errorName(err));
        defer failure.deinit(allocator);
        try respond(&request, failure);
        return;
    };
    defer response.deinit(allocator);

    try respond(&request, response);
}

fn routeApp(
    allocator: std.mem.Allocator,
    app: *const App,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) !Response {
    const path = requestPath(target);

    if (method == .GET and std.mem.eql(u8, path, "/")) {
        return .{
            .status = .ok,
            .content_type = "text/html; charset=utf-8",
            .body = try allocator.dupe(u8, workbench_html),
        };
    }

    if (method == .GET and std.mem.eql(u8, path, "/api/health")) {
        return jsonSuccess(allocator, .ok, .{
            .ok = true,
            .model = app.config.openai_model,
            .workspace_root = app.config.workspace_root,
        });
    }

    if (std.mem.eql(u8, path, "/api/tasks")) {
        if (method == .GET) return renderTaskListResponse(allocator, app.config.workspace_root);
        if (method == .POST) return createTaskResponse(allocator, app, body);
        return jsonErrorResponse(allocator, .method_not_allowed, "MethodNotAllowed");
    }

    if (std.mem.startsWith(u8, path, "/api/tasks/")) {
        const remainder = path["/api/tasks/".len..];
        var parts = std.mem.splitScalar(u8, remainder, '/');
        const task_id = parts.next() orelse return jsonErrorResponse(allocator, .not_found, "NotFound");
        const action = parts.next();
        if (parts.next() != null) return jsonErrorResponse(allocator, .not_found, "NotFound");

        if (action == null and method == .GET) {
            return renderTaskDetailResponse(allocator, app.config.workspace_root, task_id);
        }
        if (action != null and std.mem.eql(u8, action.?, "journal") and method == .GET) {
            return renderTaskJournalResponse(allocator, app.config.workspace_root, task_id);
        }
        if (action != null and std.mem.eql(u8, action.?, "turns") and method == .GET) {
            return renderTaskTurnsResponse(allocator, app.config.workspace_root, task_id);
        }
        if (action != null and std.mem.eql(u8, action.?, "messages") and method == .POST) {
            return appendTaskMessageResponse(allocator, app, task_id, body);
        }
        if (action != null and std.mem.eql(u8, action.?, "resume") and method == .POST) {
            return resumeTaskResponse(allocator, app, task_id);
        }
        return jsonErrorResponse(allocator, .method_not_allowed, "MethodNotAllowed");
    }

    return jsonErrorResponse(allocator, .not_found, "NotFound");
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

fn createTaskResponse(
    allocator: std.mem.Allocator,
    app: *const App,
    body: []const u8,
) !Response {
    var parsed = std.json.parseFromSlice(CreateTaskRequest, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return jsonErrorResponse(allocator, .bad_request, "InvalidJson");
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.prompt, " \t\r\n");
    if (prompt.len == 0) return jsonErrorResponse(allocator, .bad_request, "MissingPrompt");
    if (parsed.value.continue_from_task_id != null) {
        return jsonErrorResponse(allocator, .bad_request, "UseTaskMessagesEndpoint");
    }

    try docs_sync.ensureRunStart(allocator, app.config.workspace_root);
    var task = try store.initTaskWithOptions(allocator, app.config.workspace_root, prompt, .{ .status = .pending });
    defer task.deinit(allocator);

    try docs_sync.writePending(allocator, app.config.workspace_root, .{
        .task_id = task.id,
        .status = types.statusLabel(task.status),
        .prompt = task.prompt,
        .answer = "",
        .updated_at_ms = task.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, app.config.workspace_root, "workbench task enqueued");

    try startBackgroundRun(app, task.id);
    return renderTaskDetailResponseWithStatus(allocator, app.config.workspace_root, task.id, .created);
}

fn appendTaskMessageResponse(
    allocator: std.mem.Allocator,
    app: *const App,
    task_id: []const u8,
    body: []const u8,
) !Response {
    var parsed = std.json.parseFromSlice(TaskMessageRequest, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return jsonErrorResponse(allocator, .bad_request, "InvalidJson");
    defer parsed.deinit();

    const prompt = std.mem.trim(u8, parsed.value.prompt, " \t\r\n");
    if (prompt.len == 0) return jsonErrorResponse(allocator, .bad_request, "MissingPrompt");

    try docs_sync.ensureRunStart(allocator, app.config.workspace_root);

    var task = store.readTaskRecord(allocator, app.config.workspace_root, task_id) catch {
        return jsonErrorResponse(allocator, .not_found, "UnknownTask");
    };
    defer task.deinit(allocator);

    if (task.status == .running or task.status == .pending) {
        return jsonErrorResponse(allocator, .conflict, "TaskNotReadyForMessage");
    }
    if (task.status != .completed) {
        return jsonErrorResponse(allocator, .conflict, "TaskMessageTargetNotCompleted");
    }

    const answer = try store.readFinalAnswer(allocator, app.config.workspace_root, task.id);
    defer if (answer) |value| allocator.free(value);
    if (answer == null) {
        return jsonErrorResponse(allocator, .conflict, "TaskMessageTargetMissingAnswer");
    }

    const timestamp_ms = std.time.milliTimestamp();
    try store.appendConversationTurn(allocator, app.config.workspace_root, task.id, .user, prompt, timestamp_ms);
    try store.setTaskPrompt(allocator, app.config.workspace_root, &task, prompt, .pending);
    try docs_sync.writePending(allocator, app.config.workspace_root, .{
        .task_id = task.id,
        .status = types.statusLabel(task.status),
        .prompt = task.prompt,
        .answer = "",
        .updated_at_ms = task.updated_at_ms,
    });
    try docs_sync.appendLog(allocator, app.config.workspace_root, "workbench task message enqueued");

    try startBackgroundRun(app, task.id);
    return renderTaskDetailResponse(allocator, app.config.workspace_root, task.id);
}

fn resumeTaskResponse(
    allocator: std.mem.Allocator,
    app: *const App,
    task_id: []const u8,
) !Response {
    try docs_sync.ensureRunStart(allocator, app.config.workspace_root);

    var task = store.readTaskRecord(allocator, app.config.workspace_root, task_id) catch {
        return jsonErrorResponse(allocator, .not_found, "UnknownTask");
    };
    defer task.deinit(allocator);

    if (task.status == .running) {
        return jsonErrorResponse(allocator, .conflict, "TaskAlreadyRunning");
    }
    if (task.status == .completed) {
        return jsonErrorResponse(allocator, .conflict, "TaskAlreadyCompleted");
    }

    try docs_sync.appendLog(allocator, app.config.workspace_root, "workbench task resumed");
    try startBackgroundRun(app, task.id);
    return renderTaskDetailResponse(allocator, app.config.workspace_root, task.id);
}

fn startBackgroundRun(app: *const App, task_id: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const job = try allocator.create(BackgroundRun);
    errdefer allocator.destroy(job);

    job.* = .{
        .config = try cloneConfig(allocator, app.config.*),
        .task_id = try allocator.dupe(u8, task_id),
        .transport = app.transport,
    };

    const thread = try std.Thread.spawn(.{}, runTaskThread, .{job});
    thread.detach();
}

fn runTaskThread(job: *BackgroundRun) void {
    defer job.deinit();

    var service = agents.Service.init(&job.config);

    _ = loop.runPromptWithOptions(std.heap.page_allocator, job.config, "", .{
        .transport = job.transport,
        .execution_context = .{
            .workspace_root = job.config.workspace_root,
            .agent_service = service.handle(),
        },
        .task_id = job.task_id,
    }) catch |err| {
        logRuntimeError("background_task", job.task_id, err);
        recordBackgroundTaskFailure(&job.config, job.task_id, @errorName(err));
    };
}

fn logRuntimeError(scope: []const u8, task_id: ?[]const u8, err: anyerror) void {
    if (task_id) |value| {
        std.debug.print("VAR1 runtime error scope={s} task_id={s} error={s}\n", .{
            scope,
            value,
            @errorName(err),
        });
        return;
    }

    std.debug.print("VAR1 runtime error scope={s} error={s}\n", .{
        scope,
        @errorName(err),
    });
}

fn recordBackgroundTaskFailure(config: *const types.Config, task_id: []const u8, failure_reason: []const u8) void {
    var task = store.readTaskRecord(std.heap.page_allocator, config.workspace_root, task_id) catch return;
    defer task.deinit(std.heap.page_allocator);

    if (task.status == .completed or task.status == .failed) return;

    store.appendJournal(std.heap.page_allocator, config.workspace_root, task.id, .{
        .event_type = "task_failed",
        .message = failure_reason,
        .timestamp_ms = std.time.milliTimestamp(),
    }) catch {};
    store.setTaskFailure(std.heap.page_allocator, config.workspace_root, &task, failure_reason) catch {};
    docs_sync.writePending(std.heap.page_allocator, config.workspace_root, .{
        .task_id = task.id,
        .status = types.statusLabel(task.status),
        .prompt = task.prompt,
        .answer = failure_reason,
        .updated_at_ms = task.updated_at_ms,
    }) catch {};

    const log_line = std.fmt.allocPrint(std.heap.page_allocator, "task failed: {s}", .{failure_reason}) catch return;
    defer std.heap.page_allocator.free(log_line);
    docs_sync.appendLog(std.heap.page_allocator, config.workspace_root, log_line) catch {};
}

fn cloneConfig(allocator: std.mem.Allocator, config: types.Config) !types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, config.openai_base_url),
        .openai_api_key = try allocator.dupe(u8, config.openai_api_key),
        .openai_model = try allocator.dupe(u8, config.openai_model),
        .harness_max_steps = config.harness_max_steps,
        .workspace_root = try allocator.dupe(u8, config.workspace_root),
    };
}

fn renderTaskListResponse(allocator: std.mem.Allocator, workspace_root: []const u8) !Response {
    const tasks = try store.listTaskRecords(allocator, workspace_root);
    defer types.deinitTaskRecords(allocator, tasks);

    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();
    const writer = body.writer();

    try writer.writeAll("{\"ok\":true,\"tasks\":[");
    for (tasks, 0..) |task, index| {
        if (index > 0) try writer.writeAll(",");
        const latest_event = try store.readLatestJournalEvent(allocator, workspace_root, task.id);
        defer if (latest_event) |event| event.deinit(allocator);
        try writeTaskObject(writer, task, latest_event, null);
    }
    try writer.writeAll("]}");

    return .{
        .status = .ok,
        .content_type = "application/json; charset=utf-8",
        .body = try body.toOwnedSlice(),
    };
}

fn renderTaskDetailResponse(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !Response {
    return renderTaskDetailResponseWithStatus(allocator, workspace_root, task_id, .ok);
}

fn renderTaskDetailResponseWithStatus(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
    status: std.http.Status,
) !Response {
    var task = store.readTaskRecord(allocator, workspace_root, task_id) catch {
        return jsonErrorResponse(allocator, .not_found, "UnknownTask");
    };
    defer task.deinit(allocator);

    const latest_event = try store.readLatestJournalEvent(allocator, workspace_root, task.id);
    defer if (latest_event) |event| event.deinit(allocator);

    const answer = try store.readFinalAnswer(allocator, workspace_root, task.id);
    defer if (answer) |value| allocator.free(value);

    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();
    const writer = body.writer();

    try writer.writeAll("{\"ok\":true,\"task\":");
    try writeTaskObject(writer, task, latest_event, answer);
    try writer.writeAll("}");

    return .{
        .status = status,
        .content_type = "application/json; charset=utf-8",
        .body = try body.toOwnedSlice(),
    };
}

fn renderTaskJournalResponse(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !Response {
    var task = store.readTaskRecord(allocator, workspace_root, task_id) catch {
        return jsonErrorResponse(allocator, .not_found, "UnknownTask");
    };
    defer task.deinit(allocator);

    const events = try store.readJournalEvents(allocator, workspace_root, task_id);
    defer types.deinitJournalEvents(allocator, events);

    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();
    const writer = body.writer();

    try writer.writeAll("{\"ok\":true,\"events\":[");
    for (events, 0..) |event, index| {
        if (index > 0) try writer.writeAll(",");
        try writeJournalEventObject(writer, event);
    }
    try writer.writeAll("]}");

    return .{
        .status = .ok,
        .content_type = "application/json; charset=utf-8",
        .body = try body.toOwnedSlice(),
    };
}

fn renderTaskTurnsResponse(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    task_id: []const u8,
) !Response {
    var task = store.readTaskRecord(allocator, workspace_root, task_id) catch {
        return jsonErrorResponse(allocator, .not_found, "UnknownTask");
    };
    defer task.deinit(allocator);

    const turns = try store.readConversationTurns(allocator, workspace_root, task_id);
    defer types.deinitConversationTurns(allocator, turns);

    var body = std.array_list.Managed(u8).init(allocator);
    errdefer body.deinit();
    const writer = body.writer();

    try writer.writeAll("{\"ok\":true,\"turns\":[");
    for (turns, 0..) |turn, index| {
        if (index > 0) try writer.writeAll(",");
        try writeConversationTurnObject(writer, turn);
    }
    try writer.writeAll("]}");

    return .{
        .status = .ok,
        .content_type = "application/json; charset=utf-8",
        .body = try body.toOwnedSlice(),
    };
}

fn jsonSuccess(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    payload: anytype,
) !Response {
    return .{
        .status = status,
        .content_type = "application/json; charset=utf-8",
        .body = try std.fmt.allocPrint(allocator, "{f}", .{
            std.json.fmt(payload, .{}),
        }),
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

fn writeTaskObject(
    writer: anytype,
    task: types.TaskRecord,
    latest_event: ?types.JournalEvent,
    answer: ?[]const u8,
) !void {
    try writer.writeAll("{\"id\":");
    try writeJsonValue(writer, task.id);
    try writer.writeAll(",\"prompt\":");
    try writeJsonValue(writer, task.prompt);
    try writer.writeAll(",\"status\":");
    try writeJsonValue(writer, types.statusLabel(task.status));
    try writer.writeAll(",\"parent_task_id\":");
    try writeOptionalString(writer, task.parent_task_id);
    try writer.writeAll(",\"display_name\":");
    try writeOptionalString(writer, task.display_name);
    try writer.writeAll(",\"agent_profile\":");
    try writeOptionalString(writer, task.agent_profile);
    try writer.writeAll(",\"failure_reason\":");
    try writeOptionalString(writer, task.failure_reason);
    try writer.print(",\"created_at_ms\":{d}", .{task.created_at_ms});
    try writer.print(",\"updated_at_ms\":{d}", .{task.updated_at_ms});
    try writer.writeAll(",\"latest_event\":");
    if (latest_event) |event| {
        try writeJournalEventObject(writer, event);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"answer\":");
    try writeOptionalString(writer, answer);
    try writer.writeAll("}");
}

fn writeJournalEventObject(writer: anytype, event: types.JournalEvent) !void {
    try writer.writeAll("{\"event_type\":");
    try writeJsonValue(writer, event.event_type);
    try writer.writeAll(",\"message\":");
    try writeJsonValue(writer, event.message);
    try writer.print(",\"timestamp_ms\":{d}", .{event.timestamp_ms});
    try writer.writeAll("}");
}

fn writeConversationTurnObject(writer: anytype, turn: types.ConversationTurn) !void {
    try writer.writeAll("{\"role\":");
    try writeJsonValue(writer, types.conversationTurnRoleLabel(turn.role));
    try writer.writeAll(",\"content\":");
    try writeJsonValue(writer, turn.content);
    try writer.print(",\"timestamp_ms\":{d}", .{turn.timestamp_ms});
    try writer.writeAll("}");
}

fn writeOptionalString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonValue(writer, text);
        return;
    }
    try writer.writeAll("null");
}

fn writeJsonValue(writer: anytype, value: anytype) !void {
    const json = try std.fmt.allocPrint(std.heap.page_allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
    defer std.heap.page_allocator.free(json);
    try writer.writeAll(json);
}
