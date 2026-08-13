const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
}

fn makeConfig(allocator: std.mem.Allocator, workspace_root: []const u8) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "scale-secret"),
        .openai_model = try allocator.dupe(u8, "scale-model"),
        .auth_provider = try allocator.dupe(u8, "active"),
        .max_steps = 256,
        .max_tool_calls_per_turn = 32,
        .max_tool_calls_per_session = 256,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

test "store readiness never rewrites additive session fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "store-ready-forward-compat");
    defer std.testing.allocator.free(workspace_root);
    const session_id = "session-future-shape";
    const session_dir = try VAR1.core.session_store.sessionDirPath(std.testing.allocator, workspace_root, session_id);
    defer std.testing.allocator.free(session_dir);
    std.fs.cwd().makePath(session_dir) catch {};
    const session_path = try VAR1.core.session_store.sessionFilePath(std.testing.allocator, workspace_root, session_id);
    defer std.testing.allocator.free(session_path);
    const future_record =
        \\{"id":"session-future-shape","prompt":"forward compatible","status":"completed","parent_session_id":null,"continued_from_session_id":null,"display_name":null,"agent_profile":null,"execution_receipt":null,"failure_reason":null,"created_at_ms":1,"updated_at_ms":2,"future_execution_contract":{"schema_version":99}}
        \\ 
    ;
    try VAR1.shared.fsutil.writeText(session_path, future_record);

    try VAR1.core.session_store.ensureStoreReady(std.testing.allocator, workspace_root);
    const after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, session_path);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(future_record, after);
    var parsed = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session_id);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(session_id, parsed.id);
}

test "session JSON preserves the immutable execution receipt projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "receipt-projection");
    defer std.testing.allocator.free(workspace_root);
    const receipt = VAR1.shared.types.ExecutionReceiptView{
        .execution_kind = "model_task",
        .agent_spec_id = "planner",
        .route_role = "planning",
        .provider_id = "fixture-provider",
        .model = "fixture-model",
        .wire_api = "chat_completions",
        // Live route resolution intentionally emits an empty string when the
        // provider has no distinct thinking-mode control. Keep that exact
        // pressure case in the persistence regression.
        .thinking_mode = "",
        .capability_profile_id = "model_task",
        .capability_hash = "fixture-capability-hash",
        .parent_session_id = "fixture-parent",
        .parent_checkpoint_id = "parent-root",
        .group_id = "fixture-group",
        .task_id = "task-1",
        .branch_seq = 1,
        .budget = .{ .max_steps = 1, .max_tool_calls = 0, .max_children = 0 },
        .output_schema_hash = "fixture-schema-hash",
        .created_at_ms = 1,
    };
    var session = try VAR1.core.session_store.initSessionWithExecutionReceipt(
        std.testing.allocator,
        workspace_root,
        "receipt fixture",
        .{ .parent_session_id = "fixture-parent", .agent_profile = "model_task" },
        &receipt,
    );
    defer session.deinit(std.testing.allocator);
    const session_path = try VAR1.core.session_store.sessionFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(session_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, session_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"execution_receipt\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"agent_spec_id\": \"planner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"thinking_mode\": \"\"") != null);

    var round_trip = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer round_trip.deinit(std.testing.allocator);
    try std.testing.expect(round_trip.execution_receipt != null);
    try std.testing.expectEqualStrings("fixture-group", round_trip.execution_receipt.?.group_id);
}

const ScaleTransport = struct {
    mutex: std.Thread.Mutex = .{},
    active: usize = 0,
    max_active: usize = 0,
    calls: usize = 0,
    delay_ms: usize = 2,

    fn send(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) anyerror![]u8 {
        const ctx: *ScaleTransport = @ptrCast(@alignCast(ctx_ptr.?));
        ctx.mutex.lock();
        ctx.active += 1;
        ctx.calls += 1;
        ctx.max_active = @max(ctx.max_active, ctx.active);
        ctx.mutex.unlock();
        std.Thread.sleep(@as(u64, @intCast(ctx.delay_ms)) * std.time.ns_per_ms);
        ctx.mutex.lock();
        ctx.active -= 1;
        ctx.mutex.unlock();
        return allocator.dupe(u8, "{\"model\":\"scale-model\",\"choices\":[{\"message\":{\"content\":\"bounded child result\"}}]}");
    }
};

test "agent eligibility is deterministic and filters exhausted depth before launch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const workspace_root = try tmpWorkspacePath(allocator, &tmp, "eligibility");
    defer allocator.free(workspace_root);
    const config = try makeConfig(allocator, workspace_root);
    defer config.deinit(allocator);
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = null,
        .sendFn = ScaleTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(allocator, workspace_root, "eligibility parent");
    defer parent.deinit(allocator);
    const handle = service.handle();

    const first = try handle.eligibility(allocator, parent.id, "root", 3);
    defer allocator.free(first);
    const second = try handle.eligibility(allocator, parent.id, "root", 3);
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "var1.agent_eligibility.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"eligible\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"capacity\":{\"max\":6,\"queued\":0,\"running\":0,\"available\":6}") != null);
    try std.testing.expectEqual(@as(usize, 0), service.supervisor.workerLimit());

    const config_path = try VAR1.core.config_file.path(allocator, workspace_root);
    defer allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"agent_routes":{"roles":{"recon":{"provider_id":"missing-provider"}}}}
    );
    const filtered = try handle.eligibility(allocator, parent.id, "root", 3);
    defer allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "\"id\":\"recon\",\"reason\":\"route_unavailable\"") != null);
    try std.testing.expect(!std.mem.eql(u8, first, filtered));

    const exhausted = try handle.eligibility(allocator, parent.id, "root", 0);
    defer allocator.free(exhausted);
    try std.testing.expect(std.mem.indexOf(u8, exhausted, "\"eligible\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, exhausted, "\"reason\":\"depth_exhausted\"") != null);
}

const ProfileTransport = struct {
    calls: usize = 0,
    saw_profile: bool = false,
    saw_eligibility: bool = false,

    fn send(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        payload: []const u8,
    ) anyerror![]u8 {
        const ctx: *ProfileTransport = @ptrCast(@alignCast(ctx_ptr.?));
        ctx.calls += 1;
        if (std.mem.indexOf(u8, payload, "QUIET_PROFILE")) |_| {
            ctx.saw_profile = true;
            return allocator.dupe(u8, "{\"model\":\"profile-model\",\"choices\":[{\"message\":{\"content\":\"quiet-inline\"}}]}");
        }
        if (std.mem.indexOf(u8, payload, "HIVE_PROFILE")) |_| ctx.saw_profile = true;
        if (std.mem.indexOf(u8, payload, "var1.agent_eligibility.v1") != null and
            std.mem.indexOf(u8, payload, "model_choices") != null and
            std.mem.indexOf(u8, payload, "communication") != null)
        {
            ctx.saw_eligibility = true;
            return allocator.dupe(u8, "{\"model\":\"profile-model\",\"choices\":[{\"message\":{\"content\":\"hive-inspected-team\"}}]}");
        }
        return allocator.dupe(u8,
            \\{"model":"profile-model","choices":[{"message":{"tool_calls":[{"id":"profile-agents","type":"function","function":{"name":"agents","arguments":"{}"}}]}}]}
        );
    }
};

fn runPromptProfile(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    marker: []const u8,
    transport_state: *ProfileTransport,
) ![]u8 {
    const prompt_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "profile.md" });
    defer allocator.free(prompt_path);
    try VAR1.shared.fsutil.writeText(prompt_path, marker);
    var config = try makeConfig(allocator, workspace_root);
    defer config.deinit(allocator);
    config.prompt_policy.system_prompt_file = try allocator.dupe(u8, ".var/prompts/profile.md");
    const transport = VAR1.core.provider_runtime.Transport{
        .context = transport_state,
        .sendFn = ProfileTransport.send,
    };
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, transport);
    defer service.deinit();
    var session = try VAR1.core.session_store.initSession(allocator, workspace_root, "profile route proof");
    defer session.deinit(allocator);
    const result = try VAR1.core.executor.runPromptWithOptions(allocator, config, "", .{
        .transport = transport,
        .execution_context = .{
            .workspace_root = workspace_root,
            .agent_service = service.handle(),
            .orchestrator_only = true,
            .capability_profile_id = "root",
            .delegation_depth_remaining = 2,
        },
        .session_id = session.id,
    });
    defer result.deinit(allocator);
    return allocator.dupe(u8, result.output);
}

test "prompt profile alone selects solo or team inspection through one executor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const quiet_root = try tmpWorkspacePath(allocator, &tmp, "quiet-profile");
    defer allocator.free(quiet_root);
    const hive_root = try tmpWorkspacePath(allocator, &tmp, "hive-profile");
    defer allocator.free(hive_root);

    var quiet_transport = ProfileTransport{};
    const quiet = try runPromptProfile(allocator, quiet_root, "# QUIET_PROFILE\nWork inline and do not inspect the team.\n", &quiet_transport);
    defer allocator.free(quiet);
    try std.testing.expectEqualStrings("quiet-inline", quiet);
    try std.testing.expect(quiet_transport.saw_profile);
    try std.testing.expect(!quiet_transport.saw_eligibility);
    try std.testing.expectEqual(@as(usize, 1), quiet_transport.calls);

    var hive_transport = ProfileTransport{};
    const hive = try runPromptProfile(allocator, hive_root, "# HIVE_PROFILE\nInspect the eligible team before deciding.\n", &hive_transport);
    defer allocator.free(hive);
    try std.testing.expectEqualStrings("hive-inspected-team", hive);
    try std.testing.expect(hive_transport.saw_profile);
    try std.testing.expect(hive_transport.saw_eligibility);
    try std.testing.expectEqual(@as(usize, 2), hive_transport.calls);
}

const ParkTransport = struct {
    mutex: std.Thread.Mutex = .{},
    parent_calls: usize = 0,
    child_calls: usize = 0,
    parent_calls_while_child_running: usize = 0,
    child_running: bool = false,

    fn send(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        payload: []const u8,
    ) anyerror![]u8 {
        const ctx: *ParkTransport = @ptrCast(@alignCast(ctx_ptr.?));
        const is_child = std.mem.indexOf(u8, payload, "Output contract: var1.plan.v1") != null;
        if (is_child) {
            ctx.mutex.lock();
            ctx.child_calls += 1;
            ctx.child_running = true;
            ctx.mutex.unlock();
            std.Thread.sleep(75 * std.time.ns_per_ms);
            ctx.mutex.lock();
            ctx.child_running = false;
            ctx.mutex.unlock();
            return allocator.dupe(u8, "{\"model\":\"scale-model\",\"choices\":[{\"message\":{\"content\":\"child plan evidence\"}}]}");
        }

        ctx.mutex.lock();
        const call_index = ctx.parent_calls;
        ctx.parent_calls += 1;
        if (ctx.child_running) ctx.parent_calls_while_child_running += 1;
        ctx.mutex.unlock();
        if (call_index == 0) {
            return allocator.dupe(u8,
                \\{"model":"scale-model","choices":[{"message":{"tool_calls":[{"id":"call_agents","type":"function","function":{"name":"agents","arguments":"{}"}}]}}]}
            );
        }
        if (call_index == 1) {
            return allocator.dupe(u8,
                \\{"model":"scale-model","choices":[{"message":{"tool_calls":[{"id":"call_launch","type":"function","function":{"name":"launch_agent","arguments":"{\"context\":\"supplied evidence\",\"tasks\":[{\"name\":\"plan-one\",\"agent\":\"planner\",\"task\":\"Create the bounded plan.\",\"output_schema\":{}}],\"scope_depth\":1,\"contact_budget\":1}"}}]}}]}
            );
        }
        return allocator.dupe(u8, "{\"model\":\"scale-model\",\"choices\":[{\"message\":{\"content\":\"final synthesis after convergence\"}}]}");
    }
};

const SchemaTransport = struct {
    mutex: std.Thread.Mutex = .{},
    calls: usize = 0,

    fn send(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) anyerror![]u8 {
        const ctx: *SchemaTransport = @ptrCast(@alignCast(ctx_ptr.?));
        ctx.mutex.lock();
        const call_index = ctx.calls;
        ctx.calls += 1;
        ctx.mutex.unlock();
        if (call_index == 0) {
            return allocator.dupe(u8, "{\"model\":\"schema-model\",\"choices\":[{\"message\":{\"content\":\"{\\\"findings\\\":[]}\"}}]}");
        }
        return allocator.dupe(u8, "{\"model\":\"schema-model\",\"choices\":[{\"message\":{\"content\":\"{\\\"summary\\\":\\\"missing findings\\\"}\"}}]}");
    }
};

const FirstReadyTransport = struct {
    mutex: std.Thread.Mutex = .{},
    calls: usize = 0,

    fn send(
        ctx_ptr: ?*anyopaque,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) anyerror![]u8 {
        const ctx: *FirstReadyTransport = @ptrCast(@alignCast(ctx_ptr.?));
        ctx.mutex.lock();
        const call_index = ctx.calls;
        ctx.calls += 1;
        ctx.mutex.unlock();
        const delay_ms: u64 = if (call_index == 0) 10 else 250;
        std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        return std.fmt.allocPrint(
            allocator,
            "{{\"model\":\"scale-model\",\"choices\":[{{\"message\":{{\"content\":\"child result {d}\"}}}}]}}",
            .{call_index + 1},
        );
    }
};

fn groupIdFromJson(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    const value = parsed.value.object.get("group_id") orelse return error.MissingGroupId;
    if (value != .string) return error.MissingGroupId;
    return allocator.dupe(u8, value.string);
}

fn waitForParent(handle: VAR1.core.tool_runtime.AgentService, parent_session_id: []const u8) !VAR1.core.tool_runtime.AgentGroupSnapshot {
    var attempts: usize = 0;
    while (attempts < 120) : (attempts += 1) {
        const snapshot = try handle.waitParent(parent_session_id, 250);
        if (snapshot.terminal) return snapshot;
        if (snapshot.ready) try handle.converge(std.testing.allocator, parent_session_id);
    }
    return error.AgentWaitTimedOut;
}

fn definitionsContain(definitions: []const VAR1.shared.types.ToolDefinition, name: []const u8) bool {
    for (definitions) |definition| if (std.mem.eql(u8, definition.name, name)) return true;
    return false;
}

test "resolved profiles drive a thirty-case catalog matrix and dispatch denial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "profiles");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var service = VAR1.core.agent_runtime.Service.init(&config);
    defer service.deinit();

    const Case = struct { profile: []const u8, tool: []const u8, allowed: bool };
    const cases = [_]Case{
        .{ .profile = "root", .tool = "read_file", .allowed = true },
        .{ .profile = "root", .tool = "write_file", .allowed = true },
        .{ .profile = "root", .tool = "shell_exec", .allowed = true },
        .{ .profile = "root", .tool = "schedule_job", .allowed = true },
        .{ .profile = "root", .tool = "launch_agent", .allowed = true },
        .{ .profile = "root", .tool = "init_workspace", .allowed = true },
        .{ .profile = "subagent", .tool = "read_file", .allowed = true },
        .{ .profile = "subagent", .tool = "write_file", .allowed = true },
        .{ .profile = "subagent", .tool = "shell_exec", .allowed = true },
        .{ .profile = "subagent", .tool = "schedule_job", .allowed = false },
        .{ .profile = "subagent", .tool = "launch_agent", .allowed = true },
        .{ .profile = "subagent", .tool = "init_workspace", .allowed = false },
        .{ .profile = "recon", .tool = "read_file", .allowed = true },
        .{ .profile = "recon", .tool = "write_file", .allowed = false },
        .{ .profile = "recon", .tool = "shell_exec", .allowed = false },
        .{ .profile = "recon", .tool = "schedule_job", .allowed = false },
        .{ .profile = "recon", .tool = "launch_agent", .allowed = false },
        .{ .profile = "recon", .tool = "init_workspace", .allowed = false },
        .{ .profile = "write", .tool = "read_file", .allowed = true },
        .{ .profile = "write", .tool = "write_file", .allowed = true },
        .{ .profile = "write", .tool = "shell_exec", .allowed = true },
        .{ .profile = "write", .tool = "schedule_job", .allowed = false },
        .{ .profile = "write", .tool = "launch_agent", .allowed = false },
        .{ .profile = "write", .tool = "init_workspace", .allowed = false },
        .{ .profile = "model_task", .tool = "read_file", .allowed = false },
        .{ .profile = "model_task", .tool = "write_file", .allowed = false },
        .{ .profile = "model_task", .tool = "shell_exec", .allowed = false },
        .{ .profile = "model_task", .tool = "schedule_job", .allowed = false },
        .{ .profile = "model_task", .tool = "launch_agent", .allowed = false },
        .{ .profile = "model_task", .tool = "init_workspace", .allowed = false },
    };
    for (cases) |case| {
        const definitions = VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
            .workspace_root = workspace_root,
            .agent_service = service.handle(),
            .workspace_state_enabled = true,
            .capability_profile_id = case.profile,
            .delegation_depth_remaining = 1,
        });
        try std.testing.expectEqual(case.allowed, definitionsContain(definitions, case.tool));
    }

    var denied = VAR1.shared.types.ToolCall{
        .id = try std.testing.allocator.dupe(u8, "denied-write"),
        .name = try std.testing.allocator.dupe(u8, "write_file"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"forbidden.txt\",\"content\":\"no\"}"),
    };
    defer denied.deinit(std.testing.allocator);
    try std.testing.expectError(VAR1.core.tool_runtime.Error.CapabilityDenied, VAR1.core.tool_runtime.execute(std.testing.allocator, .{
        .workspace_root = workspace_root,
        .capability_profile_id = "recon",
    }, denied));
}

test "route roles resolve non-active provider model wire and thinking without persisting secrets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "routes");
    defer std.testing.allocator.free(workspace_root);
    std.fs.cwd().makePath(workspace_root) catch {};
    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"agent_routes":{"max_concurrency":4,"roles":{"recon":{"provider_id":"secondary","model":"recon-model","wire_api":"responses","thinking_mode":"high"}}}}
    );
    const auth_path = try VAR1.core.auth_store.authFilePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(auth_path);
    try VAR1.shared.fsutil.writeText(auth_path,
        \\{"active_provider":"active","providers":{"active":{"base_url":"http://active.test","api_key":"active-secret","model":"active-model"},"secondary":{"base_url":"http://secondary.test","api_key":"secondary-secret","model":"secondary-default"}}}
    );
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var resolved = try VAR1.core.provider_routes.resolve(std.testing.allocator, config, .recon, .{ .max_steps = 20, .max_tool_calls = 10 });
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("secondary", resolved.providerId());
    try std.testing.expectEqualStrings("recon-model", resolved.config.openai_model);
    try std.testing.expectEqualStrings("secondary-secret", resolved.config.openai_api_key);
    try std.testing.expectEqual(VAR1.shared.types.WireApi.responses, resolved.config.wire_api);
    try std.testing.expectEqualStrings("high", resolved.config.thinking_mode);
    try std.testing.expectEqual(@as(usize, 4), try VAR1.core.config_file.loadAgentMaxConcurrency(std.testing.allocator, workspace_root));

    var active = try VAR1.core.provider_routes.resolve(std.testing.allocator, config, .general, .{ .max_steps = 20, .max_tool_calls = 10 });
    defer active.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("active", active.providerId());
    try std.testing.expectEqualStrings("scale-model", active.config.openai_model);
    try std.testing.expectEqual(VAR1.shared.types.WireApi.chat_completions, active.config.wire_api);
}

test "batch groups scale through one bounded pool at 1 5 20 and 100 tasks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cardinalities = [_]usize{ 1, 5, 20, 100 };
    for (cardinalities) |task_count| {
        const suffix = try std.fmt.allocPrint(std.testing.allocator, "batch-{d}", .{task_count});
        defer std.testing.allocator.free(suffix);
        const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, suffix);
        defer std.testing.allocator.free(workspace_root);
        const config = try makeConfig(std.testing.allocator, workspace_root);
        defer config.deinit(std.testing.allocator);
        var transport_state = ScaleTransport{};
        var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
            .context = &transport_state,
            .sendFn = ScaleTransport.send,
        });
        defer service.deinit();
        var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "scale parent");
        defer parent.deinit(std.testing.allocator);

        const tasks = try std.testing.allocator.alloc(VAR1.core.tool_runtime.AgentTaskRequest, task_count);
        defer std.testing.allocator.free(tasks);
        for (tasks) |*task| task.* = .{ .agent_id = "planner", .task = "Return one deterministic fixture result." };
        const handle = service.handle();
        const launched = try handle.launchBatch(std.testing.allocator, parent.id, "shared scale fixture", tasks, .{
            .scope_depth = 1,
            .contact_budget = task_count,
            .escalation_reason = if (task_count > 1) "bounded scale acceptance matrix" else null,
            .parent_capability_profile = "root",
        });
        defer std.testing.allocator.free(launched);
        const group_id = try groupIdFromJson(std.testing.allocator, launched);
        defer std.testing.allocator.free(group_id);
        const snapshot = try waitForParent(handle, parent.id);
        try std.testing.expectEqual(task_count, snapshot.completed);
        try std.testing.expectEqual(@as(usize, 0), snapshot.failed + snapshot.cancelled);
        try std.testing.expectEqual(task_count, transport_state.calls);
        try std.testing.expect(transport_state.max_active <= service.supervisor.workerLimit());
        try std.testing.expectEqual(@as(usize, 0), service.supervisor.liveDirectoryScanCount());

        const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
        defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
        var child_finished_count: usize = 0;
        var last_child_finished_seq: u64 = 0;
        var group_finished_seq: u64 = 0;
        for (events) |event| {
            if (std.mem.indexOf(u8, event.message, group_id) == null) continue;
            if (std.mem.eql(u8, event.event_type, "child_finished")) {
                child_finished_count += 1;
                last_child_finished_seq = event.seq;
                try std.testing.expect(std.mem.indexOf(u8, event.message, "\"capability_profile_id\":\"model_task\"") != null);
            }
            if (std.mem.eql(u8, event.event_type, "child_group_finished")) group_finished_seq = event.seq;
        }
        try std.testing.expectEqual(task_count, child_finished_count);
        try std.testing.expect(group_finished_seq > last_child_finished_seq);

        try handle.converge(std.testing.allocator, parent.id);
        try handle.converge(std.testing.allocator, parent.id);
        const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, parent.id);
        defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);
        var convergence_messages: usize = 0;
        for (messages) |message| {
            if (std.mem.startsWith(u8, message.id, "child-convergence-")) convergence_messages += 1;
        }
        try std.testing.expectEqual(@as(usize, 0), convergence_messages);
        const convergence_events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
        defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, convergence_events);
        var mailbox_deliveries: usize = 0;
        for (convergence_events) |event| {
            if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type)) mailbox_deliveries += 1;
        }
        try std.testing.expectEqual(task_count, mailbox_deliveries);

        const records = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
        defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, records);
        var receipt_count: usize = 0;
        for (records) |record| {
            const receipt = record.execution_receipt orelse continue;
            if (!std.mem.eql(u8, receipt.group_id, group_id)) continue;
            receipt_count += 1;
            try std.testing.expectEqualStrings("model_task", receipt.execution_kind);
            try std.testing.expectEqualStrings("planner", receipt.agent_spec_id);
            try std.testing.expectEqualStrings("active", receipt.provider_id);
            try std.testing.expectEqual(@as(usize, 0), receipt.budget.max_tool_calls);
            try std.testing.expect(std.mem.indexOf(u8, receipt.model, "secret") == null);
        }
        try std.testing.expectEqual(task_count, receipt_count);
    }
}

test "ticket claim notice uses mailbox evidence without transcript or bespoke event" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(allocator, &tmp, "ticket-mailbox");
    defer allocator.free(workspace_root);
    const config = try makeConfig(allocator, workspace_root);
    defer config.deinit(allocator);
    var transport_state = ScaleTransport{};
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = ScaleTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(allocator, workspace_root, "ticket parent");
    defer parent.deinit(allocator);

    const ticket_store = VAR1.core.tickets.TicketStore.init(allocator, workspace_root);
    const now_ms = std.time.milliTimestamp();
    var created = try ticket_store.create(.{
        .title = "Mailbox ticket",
        .description = "Return bounded ticket evidence.",
        .category = "bug",
        .severity = "high",
        .workspace_root = workspace_root,
        .session_id = parent.id,
        .idempotency_key = "ticket-mail-create",
        .created_at_ms = now_ms,
    });
    defer created.deinit(allocator);
    var assigned = try ticket_store.transition(.{
        .ticket_id = created.ticket_id,
        .status = .assigned,
        .reason = "admit to queue",
        .idempotency_key = "ticket-mail-assign",
        .transitioned_at_ms = now_ms + 1,
    });
    defer assigned.deinit(allocator);

    var launch = try service.handle().launchTicket(allocator, .{
        .ticket_id = created.ticket_id,
        .title = "Mailbox ticket",
        .description = "Return bounded ticket evidence.",
        .category = "bug",
        .source_session_id = parent.id,
        .expected_revision = assigned.revision,
        .worker_id = "ticket-mail-worker",
        .worker_generation = 1,
        .lease_token = "ticket-mail-lease",
        .lease_expires_at_ms = now_ms + 60_000,
        .attempt = 1,
        .agent_hint = "recon",
        .idempotency_key = "ticket-mail-claim",
    });
    defer launch.deinit(allocator);
    _ = try waitForParent(service.handle(), parent.id);

    const parent_events = try VAR1.core.session_store.readEvents(allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(allocator, parent_events);
    var claim_notice_count: usize = 0;
    for (parent_events) |event| {
        try std.testing.expect(!std.mem.eql(u8, event.event_type, "ticket_claimed"));
        if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type) and
            std.mem.indexOf(u8, event.message, "Ticket ") != null and
            std.mem.indexOf(u8, event.message, " claimed by ") != null)
        {
            claim_notice_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), claim_notice_count);

    const child_events = try VAR1.core.session_store.readEvents(allocator, workspace_root, launch.session_id);
    defer VAR1.shared.types.deinitSessionEvents(allocator, child_events);
    for (child_events) |event| try std.testing.expect(!std.mem.eql(u8, event.event_type, "ticket_claimed"));
    const parent_messages = try VAR1.core.session_store.readSessionMessages(allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionMessages(allocator, parent_messages);
    for (parent_messages) |message| try std.testing.expect(std.mem.indexOf(u8, message.content, " claimed by ") == null);
}

test "first child result wakes the parent and each result converges exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "first-ready");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = FirstReadyTransport{};
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = FirstReadyTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "first result parent");
    defer parent.deinit(std.testing.allocator);
    const tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{
        .{ .agent_id = "planner", .task = "Return the fast bounded result." },
        .{ .agent_id = "planner", .task = "Return the slow bounded result." },
    };
    const handle = service.handle();
    const launched = try handle.launchBatch(std.testing.allocator, parent.id, "bounded shared packet", tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = tasks.len,
        .escalation_reason = "first-result wake pressure",
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(launched);

    const first = try handle.waitParent(parent.id, 1000);
    try std.testing.expect(first.ready);
    try std.testing.expect(!first.terminal);
    try std.testing.expectEqual(@as(usize, 1), first.completed);
    try handle.converge(std.testing.allocator, parent.id);
    {
        const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
        defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
        var converged: usize = 0;
        for (events) |event| {
            if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type)) converged += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), converged);
    }

    const terminal = try waitForParent(handle, parent.id);
    try std.testing.expect(terminal.terminal);
    try std.testing.expectEqual(@as(usize, 2), terminal.completed);
    try handle.converge(std.testing.allocator, parent.id);
    try handle.converge(std.testing.allocator, parent.id);
    {
        const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
        defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
        var converged: usize = 0;
        for (events) |event| {
            if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type)) converged += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), converged);
    }
}

test "child session owns only the supplied context packet and never copies parent history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "context-isolation");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = ScaleTransport{ .delay_ms = 25 };
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = ScaleTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(
        std.testing.allocator,
        workspace_root,
        "PARENT-TRANSCRIPT-SECRET-MUST-NOT-COPY",
    );
    defer parent.deinit(std.testing.allocator);
    const tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{
        .{ .agent_id = "planner", .task = "Use only the supplied packet." },
    };
    const handle = service.handle();
    const launched = try handle.launchBatch(std.testing.allocator, parent.id, "ALLOWED-EXPLICIT-CONTEXT", tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = 1,
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(launched);
    const group_id = try groupIdFromJson(std.testing.allocator, launched);
    defer std.testing.allocator.free(group_id);

    const records = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, records);
    var child_prompt: ?[]const u8 = null;
    for (records) |record| {
        const receipt = record.execution_receipt orelse continue;
        if (std.mem.eql(u8, receipt.group_id, group_id)) child_prompt = record.prompt;
    }
    try std.testing.expect(child_prompt != null);
    try std.testing.expect(std.mem.indexOf(u8, child_prompt.?, "ALLOWED-EXPLICIT-CONTEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, child_prompt.?, "Use only the supplied packet.") != null);
    try std.testing.expect(std.mem.indexOf(u8, child_prompt.?, "PARENT-TRANSCRIPT-SECRET-MUST-NOT-COPY") == null);

    _ = try waitForParent(handle, parent.id);
    try handle.converge(std.testing.allocator, parent.id);
}

test "parent parks without provider dispatch and resumes once after convergence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "parent-park");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = ParkTransport{};
    const transport = VAR1.core.provider_runtime.Transport{
        .context = &transport_state,
        .sendFn = ParkTransport.send,
    };
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, transport);
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "delegate one supplied-evidence plan");
    defer parent.deinit(std.testing.allocator);

    const result = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = transport,
        .execution_context = .{
            .workspace_root = workspace_root,
            .agent_service = service.handle(),
        },
        .session_id = parent.id,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("final synthesis after convergence", result.output);
    try std.testing.expectEqual(@as(usize, 3), transport_state.parent_calls);
    try std.testing.expectEqual(@as(usize, 1), transport_state.child_calls);
    try std.testing.expectEqual(@as(usize, 0), transport_state.parent_calls_while_child_running);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var saw_wait = false;
    var saw_group_finished = false;
    var saw_convergence = false;
    var previous_seq: u64 = 0;
    for (events) |event| {
        try std.testing.expect(event.seq > previous_seq);
        previous_seq = event.seq;
        saw_wait = saw_wait or std.mem.eql(u8, event.event_type, "session_waiting");
        saw_group_finished = saw_group_finished or std.mem.eql(u8, event.event_type, "child_group_finished");
        saw_convergence = saw_convergence or std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type);
    }
    try std.testing.expect(saw_wait and saw_group_finished and saw_convergence);
}

test "model tasks execute one provider turn without tools and enforce the requested output shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "model-schema");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = SchemaTransport{};
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = SchemaTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "schema parent");
    defer parent.deinit(std.testing.allocator);
    const schema = "{\"type\":\"object\",\"required\":[\"findings\"],\"properties\":{\"findings\":{\"type\":\"array\"}}}";
    const valid_tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{.{
        .agent_id = "reviewer",
        .task = "Return valid findings.",
        .output_schema_json = schema,
    }};
    const valid_launch = try service.handle().launchBatch(std.testing.allocator, parent.id, "valid schema", valid_tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = 1,
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(valid_launch);
    const valid_group = try groupIdFromJson(std.testing.allocator, valid_launch);
    defer std.testing.allocator.free(valid_group);
    _ = try waitForParent(service.handle(), parent.id);
    const valid_snapshot = try service.supervisor.waitGroup(valid_group, 0);
    try std.testing.expectEqual(@as(usize, 1), valid_snapshot.completed);

    const invalid_tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{.{
        .agent_id = "reviewer",
        .task = "Return invalid findings.",
        .output_schema_json = schema,
    }};
    const invalid_launch = try service.handle().launchBatch(std.testing.allocator, parent.id, "invalid schema", invalid_tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = 1,
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(invalid_launch);
    const invalid_group = try groupIdFromJson(std.testing.allocator, invalid_launch);
    defer std.testing.allocator.free(invalid_group);
    _ = try waitForParent(service.handle(), parent.id);
    const invalid_snapshot = try service.supervisor.waitGroup(invalid_group, 0);
    try std.testing.expectEqual(@as(usize, 1), invalid_snapshot.failed);
    try std.testing.expectEqual(@as(usize, 2), transport_state.calls);
}

test "group cancellation reaches queued and running children and terminates the group" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "cancel");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = ScaleTransport{ .delay_ms = 50 };
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = ScaleTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "cancel parent");
    defer parent.deinit(std.testing.allocator);
    const tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{
        .{ .agent_id = "planner", .task = "cancel fixture 1" },
        .{ .agent_id = "planner", .task = "cancel fixture 2" },
        .{ .agent_id = "planner", .task = "cancel fixture 3" },
        .{ .agent_id = "planner", .task = "cancel fixture 4" },
        .{ .agent_id = "planner", .task = "cancel fixture 5" },
        .{ .agent_id = "planner", .task = "cancel fixture 6" },
        .{ .agent_id = "planner", .task = "cancel fixture 7" },
        .{ .agent_id = "planner", .task = "cancel fixture 8" },
    };
    const handle = service.handle();
    const launched = try handle.launchBatch(std.testing.allocator, parent.id, "cancel all", tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = tasks.len,
        .escalation_reason = "cancellation acceptance probe",
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(launched);
    const group_id = try groupIdFromJson(std.testing.allocator, launched);
    defer std.testing.allocator.free(group_id);
    const cancellation_count = try handle.cancelGroup(group_id, "test cancellation");
    try std.testing.expect(cancellation_count > 0);
    const snapshot = try waitForParent(handle, parent.id);
    try std.testing.expect(snapshot.terminal);
    try std.testing.expect(snapshot.cancelled > 0);
    try std.testing.expectEqual(@as(usize, 0), snapshot.queued + snapshot.running);

    const records = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, records);
    var terminal_receipts: usize = 0;
    for (records) |record| {
        const receipt = record.execution_receipt orelse continue;
        if (!std.mem.eql(u8, receipt.group_id, group_id)) continue;
        try std.testing.expect(record.status == .completed or record.status == .failed or record.status == .cancelled);
        terminal_receipts += 1;
    }
    try std.testing.expectEqual(tasks.len, terminal_receipts);
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var child_finished: usize = 0;
    var group_finished = false;
    for (events) |event| {
        if (std.mem.indexOf(u8, event.message, group_id) == null) continue;
        if (std.mem.eql(u8, event.event_type, "child_finished")) child_finished += 1;
        if (std.mem.eql(u8, event.event_type, "child_group_finished")) group_finished = true;
    }
    try std.testing.expectEqual(tasks.len, child_finished);
    try std.testing.expect(group_finished);
}

test "overlapping groups cancel and converge independently without cross consumption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "overlap");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var transport_state = ScaleTransport{ .delay_ms = 250 };
    var service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &transport_state,
        .sendFn = ScaleTransport.send,
    });
    defer service.deinit();
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "overlap parent");
    defer parent.deinit(std.testing.allocator);
    const first_tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{
        .{ .agent_id = "planner", .task = "first one" },
        .{ .agent_id = "planner", .task = "first two" },
        .{ .agent_id = "planner", .task = "first three" },
        .{ .agent_id = "planner", .task = "first four" },
        .{ .agent_id = "planner", .task = "first five" },
        .{ .agent_id = "planner", .task = "first six" },
        .{ .agent_id = "planner", .task = "first seven" },
        .{ .agent_id = "planner", .task = "first eight" },
    };
    const second_tasks = [_]VAR1.core.tool_runtime.AgentTaskRequest{
        .{ .agent_id = "planner", .task = "second one" },
        .{ .agent_id = "planner", .task = "second two" },
    };
    const handle = service.handle();
    const first_launch = try handle.launchBatch(std.testing.allocator, parent.id, "first group", first_tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = first_tasks.len,
        .escalation_reason = "overlap cancellation pressure",
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(first_launch);
    const first_group_id = try groupIdFromJson(std.testing.allocator, first_launch);
    defer std.testing.allocator.free(first_group_id);
    const second_launch = try handle.launchBatch(std.testing.allocator, parent.id, "second group", second_tasks[0..], .{
        .scope_depth = 1,
        .contact_budget = second_tasks.len,
        .escalation_reason = "overlap completion pressure",
        .parent_capability_profile = "root",
    });
    defer std.testing.allocator.free(second_launch);
    const second_group_id = try groupIdFromJson(std.testing.allocator, second_launch);
    defer std.testing.allocator.free(second_group_id);
    try std.testing.expect(!std.mem.eql(u8, first_group_id, second_group_id));
    try std.testing.expect(try handle.cancelGroup(first_group_id, "cancel first group only") > 0);
    _ = try waitForParent(handle, parent.id);

    const first_snapshot = try service.supervisor.waitGroup(first_group_id, 0);
    const second_snapshot = try service.supervisor.waitGroup(second_group_id, 0);
    try std.testing.expect(first_snapshot.cancelled > 0);
    try std.testing.expectEqual(second_tasks.len, second_snapshot.completed);
    try std.testing.expectEqual(@as(usize, 0), second_snapshot.failed + second_snapshot.cancelled);
    try handle.converge(std.testing.allocator, parent.id);
    try handle.converge(std.testing.allocator, parent.id);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var first_convergence: usize = 0;
    var second_convergence: usize = 0;
    for (events) |event| {
        if (!std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type)) continue;
        if (std.mem.indexOf(u8, event.message, first_group_id) != null) first_convergence += 1;
        if (std.mem.indexOf(u8, event.message, second_group_id) != null) second_convergence += 1;
    }
    try std.testing.expectEqual(first_tasks.len, first_convergence);
    try std.testing.expectEqual(second_tasks.len, second_convergence);
}

test "cold start rebuilds receipt groups and reconciles stale owners once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp, "cold-recovery");
    defer std.testing.allocator.free(workspace_root);
    const config = try makeConfig(std.testing.allocator, workspace_root);
    defer config.deinit(std.testing.allocator);
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "recover parent");
    defer parent.deinit(std.testing.allocator);
    try VAR1.core.session_store.setSessionStatus(std.testing.allocator, workspace_root, &parent, .running);

    const Receipt = VAR1.shared.types.ExecutionReceiptView;
    const receipt_one = Receipt{
        .execution_kind = "model_task",
        .agent_spec_id = "planner",
        .route_role = "planning",
        .provider_id = "active",
        .model = "scale-model",
        .wire_api = "chat_completions",
        .thinking_mode = "",
        .capability_profile_id = "model_task",
        .capability_hash = "cap-one",
        .parent_session_id = parent.id,
        .parent_checkpoint_id = "parent-root",
        .group_id = "group-recovery",
        .task_id = "task-1",
        .branch_seq = 1,
        .budget = .{ .max_steps = 1, .max_tool_calls = 0, .max_children = 0 },
        .output_schema_hash = "schema-one",
        .created_at_ms = std.time.milliTimestamp(),
    };
    const receipt_two = Receipt{
        .execution_kind = "model_task",
        .agent_spec_id = "planner",
        .route_role = "planning",
        .provider_id = "active",
        .model = "scale-model",
        .wire_api = "chat_completions",
        .thinking_mode = "",
        .capability_profile_id = "model_task",
        .capability_hash = "cap-two",
        .parent_session_id = parent.id,
        .parent_checkpoint_id = "parent-root",
        .group_id = "group-recovery",
        .task_id = "task-2",
        .branch_seq = 2,
        .budget = .{ .max_steps = 1, .max_tool_calls = 0, .max_children = 0 },
        .output_schema_hash = "schema-two",
        .created_at_ms = std.time.milliTimestamp(),
    };
    var stale_child = try VAR1.core.session_store.initSessionWithExecutionReceipt(std.testing.allocator, workspace_root, "stale child", .{
        .status = .running,
        .parent_session_id = parent.id,
        .display_name = "stale-plan",
        .agent_profile = "model_task",
    }, &receipt_one);
    defer stale_child.deinit(std.testing.allocator);
    var completed_child = try VAR1.core.session_store.initSessionWithExecutionReceipt(std.testing.allocator, workspace_root, "completed child", .{
        .status = .completed,
        .parent_session_id = parent.id,
        .display_name = "finished-plan",
        .agent_profile = "model_task",
    }, &receipt_two);
    defer completed_child.deinit(std.testing.allocator);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, completed_child.id, "durable completed result");
    try VAR1.core.session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, parent.id, "parent-root", 1, .open, "stale branch");
    try VAR1.core.session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, parent.id, "parent-root", 2, .open, "completed branch");

    {
        var recovered = VAR1.core.agent_runtime.Service.init(&config);
        defer recovered.deinit();
        const handle = recovered.handle();
        try std.testing.expectEqual(@as(usize, 1), try handle.reconcile(std.testing.allocator, parent.id));
        try std.testing.expectEqual(@as(usize, 0), try handle.reconcile(std.testing.allocator, parent.id));
        const snapshot = try handle.waitParent(parent.id, 0);
        try std.testing.expect(snapshot.terminal);
        try std.testing.expectEqual(@as(usize, 1), snapshot.completed);
        try std.testing.expectEqual(@as(usize, 1), snapshot.failed);
        try std.testing.expectEqual(@as(usize, 1), recovered.supervisor.coldStartDirectoryScanCount());
        try handle.converge(std.testing.allocator, parent.id);
        try handle.converge(std.testing.allocator, parent.id);
    }

    var stale_after = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, stale_child.id);
    defer stale_after.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, stale_after.status);
    try std.testing.expectEqualStrings("StaleAgentOwner", stale_after.failure_reason.?);
    try std.testing.expect(stale_after.execution_receipt != null);
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var convergence_count: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, VAR1.core.agent_mailbox.received_event_type)) convergence_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), convergence_count);

    var replayed = VAR1.core.agent_runtime.Service.init(&config);
    defer replayed.deinit();
    const replay_handle = replayed.handle();
    try std.testing.expectEqual(@as(usize, 0), try replay_handle.reconcile(std.testing.allocator, parent.id));
    const replay_snapshot = try replay_handle.waitParent(parent.id, 0);
    try std.testing.expect(replay_snapshot.terminal);
    const listing = try replay_handle.list(std.testing.allocator, parent.id);
    defer std.testing.allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"converged\":true") != null);

    var resume_transport_state = ScaleTransport{};
    var resume_service = VAR1.core.agent_runtime.Service.initWithTransport(&config, .{
        .context = &resume_transport_state,
        .sendFn = ScaleTransport.send,
    });
    defer resume_service.deinit();
    const resumed = try VAR1.core.executor.runPromptWithOptions(std.testing.allocator, config, "", .{
        .transport = .{ .context = &resume_transport_state, .sendFn = ScaleTransport.send },
        .execution_context = .{ .workspace_root = workspace_root, .agent_service = resume_service.handle() },
        .session_id = parent.id,
    });
    defer resumed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bounded child result", resumed.output);
    try std.testing.expectEqual(@as(usize, 1), resume_transport_state.calls);
}
