const std = @import("std");
const types = @import("../../../shared/types.zig");
const agent_spec = @import("../../agents/spec.zig");
const profile_contract = @import("../../agents/profile.zig");
const scope_contract = @import("../../agents/scope.zig");
const module = @import("../module.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "agents",
        .description = "Hot-load the compact available-agent catalog from config.json. Call this before selecting, launching, or changing a specialist.",
        .review_risk = .read_only,
        .parameters_json =
        \\{"type":"object","properties":{},"additionalProperties":false}
        ,
        .example_json = "{}",
        .usage_hint = "This is specialist discovery, not launched-run status. Match the task to when_to_use, then pass the returned id to launch_agent. Private child instructions are intentionally omitted.",
    },
    .{
        .name = "launch_agent",
        .description = "Launch one parent-owned VAR1 child group. Each task selects an id returned by the latest agents call; provider, model, and private child instructions remain kernel-owned.",
        .review_risk = .delegating,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "context": { "type": "string", "description": "Shared bounded background supplied to every task in this group." },
        \\    "tasks": {
        \\      "type": "array", "minItems": 1, "maxItems": 100,
        \\      "items": {
        \\        "type": "object",
        \\        "properties": {
        \\          "name": { "type": "string", "description": "Optional stable row label within this group." },
        \\          "agent": { "type": "string", "description": "Hot-loaded specialist id returned by agents." },
        \\          "task": { "type": "string", "description": "Finite self-contained task owned by this child." },
        \\          "output_schema": { "type": "object", "description": "Optional JSON result shape recorded in the execution receipt." }
        \\        },
        \\        "required": ["agent","task"],
        \\        "additionalProperties": false
        \\      }
        \\    },
        \\    "scope_depth": { "type": "integer", "minimum": 1, "description": "Delegation depth requested for this child. Defaults to 1." },
        \\    "contact_budget": { "type": "integer", "minimum": 1, "description": "Maximum admitted tasks in this group. Defaults to tasks.length." },
        \\    "background": { "type": "boolean", "description": "False parks on the first ready child after launch. True gives the parent another turn for independent orchestration work. Defaults to false." },
        \\    "validation_status": { "type": "string", "enum": ["unverified","self_checked","validated"], "description": "How much validation the parent has already performed. Defaults to unverified." },
        \\    "escalation_reason": { "type": "string", "description": "Required when scope_depth or contact_budget expands beyond the parent profile default." }
        \\  },
        \\  "required": ["context","tasks"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"context\":\"Inspect only src/core/tools.\",\"tasks\":[{\"name\":\"search-audit\",\"agent\":\"recon\",\"task\":\"Trace search_files ownership and return exact evidence.\",\"output_schema\":{}}],\"scope_depth\":1,\"contact_budget\":1,\"background\":false,\"validation_status\":\"unverified\"}",
        .usage_hint = "Call agents first. Put branchable work and only explicit bounded shared background in context; child sessions do not inherit the parent transcript. Each child returns its configured compact SITREP or output contract. Each ready result wakes and resumes the parent exactly once while unfinished siblings may continue.",
    },
    .{
        .name = "agent_status",
        .description = "Inspect one child group without blocking. Arguments require group_id returned by launch_agent.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "group_id": { "type": "string", "description": "Required child group id returned by launch_agent." }
        \\  },
        \\  "required": ["group_id"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"group_id\":\"group-...\"}",
        .usage_hint = "Use agent_status for non-blocking supervision when you only need the current child snapshot.",
    },
    .{
        .name = "wait_agent",
        .description = "Wait bounded time on one child group signal. Timeout returns the current typed snapshot without directory polling.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "group_id": { "type": "string", "description": "Required child group id returned by launch_agent." },
        \\    "timeout_ms": { "type": "integer", "minimum": 1, "description": "Optional timeout in milliseconds. Defaults to 30000." }
        \\  },
        \\  "required": ["group_id"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"group_id\":\"group-...\",\"timeout_ms\":60000}",
        .usage_hint = "Use wait_agent only when you are ready to spend bounded time collecting a result or current snapshot. Set timeout_ms explicitly for long child work; use longer waits instead of repeated short polling when the child is expected to keep running.",
    },
    .{
        .name = "list_agents",
        .description = "List the child agents launched by the current parent session, including their names and statuses. JSON arguments must be an empty object.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{}",
        .usage_hint = "Do not invent arguments for list_agents. Call it with an empty JSON object only.",
    },
    .{
        .name = "cancel_agents",
        .description = "Request cancellation for every non-terminal member of one child group and reconcile queued members immediately.",
        .review_risk = .delegating,
        .parameters_json =
        \\{"type":"object","properties":{"group_id":{"type":"string"},"reason":{"type":"string"}},"required":["group_id"],"additionalProperties":false}
        ,
        .example_json = "{\"group_id\":\"group-...\",\"reason\":\"Parent objective changed.\"}",
        .usage_hint = "Use the exact group_id. Cancellation is group-scoped and appends terminal evidence for queued members.",
    },
    .{
        .name = "configure_agent",
        .description = "Atomically upsert, disable, or reset one config.json agent definition. New ids inherit a compiled capability floor through extends; this tool cannot add arbitrary tools, code, credentials, or provider endpoints.",
        .review_risk = .write_capable,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "action": { "type": "string", "enum": ["upsert","reset"] },
        \\    "id": { "type": "string", "description": "Lowercase snake_case specialist id." },
        \\    "extends": { "type": "string", "description": "Required on first creation of a custom id; must name one built-in agent." },
        \\    "enabled": { "type": "boolean", "description": "False removes the id from discovery without deleting its definition." },
        \\    "description": { "type": "string" },
        \\    "when_to_use": { "type": "string" },
        \\    "instruction": { "type": "string", "description": "Private child-only persona capsule; omitted from agents output." },
        \\    "route_role": { "type": "string", "enum": ["general","recon","planning","compaction","implementation","review","validation"] },
        \\    "max_steps": { "type": "integer", "minimum": 1, "maximum": 4096 },
        \\    "max_tool_calls": { "type": "integer", "minimum": 0, "maximum": 4096 },
        \\    "max_children": { "type": "integer", "minimum": 0, "maximum": 64 },
        \\    "output_contract": { "type": "string" }
        \\  },
        \\  "required": ["action","id"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"action\":\"upsert\",\"id\":\"frontend_recon\",\"extends\":\"recon\",\"description\":\"Frontend ownership recon.\",\"when_to_use\":\"Use for frontend architecture work.\",\"instruction\":\"Inspect frontend only and return exact evidence.\"}",
        .usage_hint = "Use reset to remove a custom id or return a built-in id to its compiled floor. Call agents again after mutation to observe the hot-loaded effective catalog.",
    },
};

pub const availability = module.AvailabilitySpec{};

pub fn availabilitySpec(tool_name: []const u8) ?module.AvailabilitySpec {
    if (!handles(tool_name)) return null;
    return availability;
}

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
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "agents")) {
        return executeAgentCatalog(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "launch_agent")) {
        return executeLaunchAgent(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "agent_status")) {
        return executeAgentStatus(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "wait_agent")) {
        return executeWaitAgent(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "list_agents")) {
        return executeListAgents(allocator, execution_context);
    }
    if (std.mem.eql(u8, tool_name, "cancel_agents")) {
        return executeCancelAgents(allocator, execution_context, arguments_json);
    }
    if (std.mem.eql(u8, tool_name, "configure_agent")) {
        return executeConfigureAgent(allocator, execution_context, arguments_json);
    }

    return module.Error.UnknownTool;
}

fn executeLaunchAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const TaskArgs = struct {
        name: ?[]const u8 = null,
        agent: []const u8,
        task: []const u8,
        output_schema: ?std.json.Value = null,
    };
    const Args = struct {
        context: []const u8 = "",
        tasks: ?[]TaskArgs = null,
        prompt: ?[]const u8 = null,
        name: ?[]const u8 = null,
        scope_depth: usize = 1,
        contact_budget: ?usize = null,
        background: bool = false,
        validation_status: []const u8 = "unverified",
        escalation_reason: ?[]const u8 = null,
        parent_capability_profile: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var requests = std.array_list.Managed(module.AgentTaskRequest).init(allocator);
    defer requests.deinit();
    var owned_schemas = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (owned_schemas.items) |schema| allocator.free(schema);
        owned_schemas.deinit();
    }
    if (parsed.value.tasks) |task_args| {
        for (task_args) |task| {
            const schema = if (task.output_schema) |value|
                try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})})
            else
                try allocator.dupe(u8, "{}");
            try owned_schemas.append(schema);
            try requests.append(.{
                .name = task.name,
                .agent_id = task.agent,
                .task = task.task,
                .output_schema_json = schema,
            });
        }
    } else if (parsed.value.prompt) |legacy_prompt| {
        try requests.append(.{
            .name = parsed.value.name,
            .agent_id = "general",
            .task = legacy_prompt,
        });
    } else {
        return module.Error.InvalidArguments;
    }

    const parent_profile_id = execution_context.capability_profile_id orelse "root";
    if (parsed.value.scope_depth > execution_context.delegation_depth_remaining) return module.Error.CapabilityDenied;
    const delegation_scope: module.DelegationScope = .{
        .scope_depth = parsed.value.scope_depth,
        .contact_budget = parsed.value.contact_budget orelse requests.items.len,
        .validation_status = try scope_contract.parseValidationStatus(parsed.value.validation_status),
        .escalation_reason = parsed.value.escalation_reason,
        .parent_capability_profile = parent_profile_id,
    };
    try scope_contract.validateDelegationScope(delegation_scope, try profile_contract.resolveProfile(parent_profile_id));

    const content = try service.launchBatch(
        allocator,
        parent_session_id,
        parsed.value.context,
        requests.items,
        delegation_scope,
    );
    defer allocator.free(content);
    if (execution_context.agent_discovery_ledger) |ledger| ledger.noteLaunch(parsed.value.background);

    return module.okEnvelope(allocator, "launch_agent", content);
}

fn executeAgentStatus(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const Args = struct {
        group_id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const content = try service.status(allocator, parent_session_id, parsed.value.group_id orelse parsed.value.name orelse return module.Error.InvalidArguments);
    defer allocator.free(content);

    return module.okEnvelope(allocator, "agent_status", content);
}

fn executeWaitAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const Args = struct {
        group_id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        timeout_ms: usize = 30_000,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const content = try service.wait(
        allocator,
        parent_session_id,
        parsed.value.group_id orelse parsed.value.name orelse return module.Error.InvalidArguments,
        parsed.value.timeout_ms,
    );
    defer allocator.free(content);

    return module.okEnvelope(allocator, "wait_agent", content);
}

fn executeListAgents(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const content = try service.list(allocator, parent_session_id);
    defer allocator.free(content);

    return module.okEnvelope(allocator, "list_agents", content);
}

fn executeAgentCatalog(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const EmptyArgs = struct {};
    var parsed = try std.json.parseFromSlice(EmptyArgs, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    var registry = try agent_spec.loadRegistry(allocator, execution_context.workspace_root);
    defer registry.deinit();
    const content = try agent_spec.renderCatalog(allocator, registry);
    defer allocator.free(content);
    if (execution_context.agent_discovery_ledger) |ledger| ledger.mark();
    return module.okEnvelope(allocator, "agents", content);
}

fn executeCancelAgents(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const Args = struct {
        group_id: []const u8,
        reason: []const u8 = "Cancellation requested by parent.",
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const cancelled = try service.cancelGroup(parsed.value.group_id, parsed.value.reason);
    const content = try std.fmt.allocPrint(allocator, "{{\"schema\":\"var1.child_cancel.v1\",\"group_id\":{f},\"cancelled\":{d}}}", .{
        std.json.fmt(parsed.value.group_id, .{}),
        cancelled,
    });
    defer allocator.free(content);
    return module.okEnvelope(allocator, "cancel_agents", content);
}

fn executeConfigureAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        id: []const u8,
        extends: ?[]const u8 = null,
        enabled: ?bool = null,
        description: ?[]const u8 = null,
        when_to_use: ?[]const u8 = null,
        instruction: ?[]const u8 = null,
        route_role: ?[]const u8 = null,
        max_steps: ?usize = null,
        max_tool_calls: ?usize = null,
        max_children: ?usize = null,
        output_contract: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const evidence = if (std.mem.eql(u8, parsed.value.action, "upsert"))
        try agent_spec.upsertConfiguredAgent(allocator, execution_context.workspace_root, .{
            .id = parsed.value.id,
            .extends = parsed.value.extends,
            .enabled = parsed.value.enabled,
            .description = parsed.value.description,
            .when_to_use = parsed.value.when_to_use,
            .instruction = parsed.value.instruction,
            .route_role = parsed.value.route_role,
            .max_steps = parsed.value.max_steps,
            .max_tool_calls = parsed.value.max_tool_calls,
            .max_children = parsed.value.max_children,
            .output_contract = parsed.value.output_contract,
        })
    else if (std.mem.eql(u8, parsed.value.action, "reset"))
        try agent_spec.resetConfiguredAgent(allocator, execution_context.workspace_root, parsed.value.id)
    else
        return module.Error.InvalidArguments;
    defer evidence.deinit(allocator);

    const content = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.agent_config_effect.v1\",\"action\":{f},\"agent_id\":{f},\"config_path\":{f},\"before_bytes\":{d},\"after_bytes\":{d},\"before_sha256\":{f},\"after_sha256\":{f},\"hotload\":\"next agents or launch_agent call\"}}",
        .{
            std.json.fmt(evidence.action, .{}),
            std.json.fmt(evidence.agent_id, .{}),
            std.json.fmt(evidence.config_path, .{}),
            evidence.before_bytes,
            evidence.after_bytes,
            std.json.fmt(evidence.before_sha256[0..], .{}),
            std.json.fmt(evidence.after_sha256[0..], .{}),
        },
    );
    defer allocator.free(content);
    return module.okEnvelope(allocator, "configure_agent", content);
}
