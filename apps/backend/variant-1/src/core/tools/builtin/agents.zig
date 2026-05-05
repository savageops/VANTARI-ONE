const std = @import("std");
const types = @import("../../../shared/types.zig");
const profile_contract = @import("../../agents/profile.zig");
const scope_contract = @import("../../agents/scope.zig");
const module = @import("../module.zig");

pub const definitions = [_]types.ToolDefinition{
    .{
        .name = "launch_agent",
        .description = "Launch a bounded child VAR1 agent. Arguments require prompt and optionally accept name plus an explicit delegation scope. Use only when the child can make independent progress from a self-contained task statement.",
        .review_risk = .delegating,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "prompt": { "type": "string", "description": "Required exact prompt for the child VAR1 agent to execute." },
        \\    "name": { "type": "string", "description": "Optional short display name for the child agent. Defaults to an auto-generated name." },
        \\    "scope_depth": { "type": "integer", "minimum": 1, "description": "Delegation depth requested for this child. Defaults to 1." },
        \\    "contact_budget": { "type": "integer", "minimum": 1, "description": "Maximum child contact/supervision budget. Defaults to 1." },
        \\    "validation_status": { "type": "string", "enum": ["unverified","self_checked","validated"], "description": "How much validation the parent has already performed. Defaults to unverified." },
        \\    "escalation_reason": { "type": "string", "description": "Required when scope_depth or contact_budget expands beyond the default bounded child scope." },
        \\    "parent_capability_profile": { "type": "string", "enum": ["root","subagent"], "description": "Optional known profile id for the delegating parent." }
        \\  },
        \\  "required": ["prompt"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"prompt\":\"Inspect src/core/tools/runtime.zig and summarize search_files.\",\"name\":\"search-audit\",\"scope_depth\":1,\"contact_budget\":1,\"validation_status\":\"unverified\"}",
        .usage_hint = "Keep the child prompt concrete, finite, and self-contained. Expanding scope_depth or contact_budget requires escalation_reason and remains bounded by the kernel capability profile.",
    },
    .{
        .name = "agent_status",
        .description = "Inspect a named child agent without blocking. Arguments require name returned by launch_agent and return journal-backed status/progress metadata.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Required child agent name returned by launch_agent." }
        \\  },
        \\  "required": ["name"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"name\":\"search-audit\"}",
        .usage_hint = "Use agent_status for non-blocking supervision when you only need the current child snapshot.",
    },
    .{
        .name = "wait_agent",
        .description = "Wait bounded time for a named child agent. Arguments require name and optionally accept timeout_ms. Timeout returns the current snapshot instead of failing.",
        .review_risk = .read_only,
        .parameters_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": "string", "description": "Required child agent name returned by launch_agent." },
        \\    "timeout_ms": { "type": "integer", "minimum": 1, "description": "Optional timeout in milliseconds. Defaults to 30000." }
        \\  },
        \\  "required": ["name"],
        \\  "additionalProperties": false
        \\}
        ,
        .example_json = "{\"name\":\"search-audit\",\"timeout_ms\":30000}",
        .usage_hint = "Use wait_agent only when you are ready to spend bounded time collecting a result or current snapshot.",
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

    return module.Error.UnknownTool;
}

fn executeLaunchAgent(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const service = execution_context.agent_service orelse return module.Error.AgentServiceUnavailable;
    const parent_session_id = execution_context.parent_session_id orelse return module.Error.MissingParentSession;

    const Args = struct {
        prompt: []const u8,
        name: ?[]const u8 = null,
        scope_depth: usize = 1,
        contact_budget: usize = 1,
        validation_status: []const u8 = "unverified",
        escalation_reason: ?[]const u8 = null,
        parent_capability_profile: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const delegation_scope: module.DelegationScope = .{
        .scope_depth = parsed.value.scope_depth,
        .contact_budget = parsed.value.contact_budget,
        .validation_status = try scope_contract.parseValidationStatus(parsed.value.validation_status),
        .escalation_reason = parsed.value.escalation_reason,
        .parent_capability_profile = parsed.value.parent_capability_profile,
    };
    try scope_contract.validateDelegationScope(delegation_scope, profile_contract.defaultSubagentProfile());

    const content = try service.launch(
        allocator,
        parent_session_id,
        parsed.value.prompt,
        parsed.value.name,
        delegation_scope,
    );
    defer allocator.free(content);

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
        name: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const content = try service.status(allocator, parent_session_id, parsed.value.name);
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
        name: []const u8,
        timeout_ms: usize = 30_000,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const content = try service.wait(
        allocator,
        parent_session_id,
        parsed.value.name,
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
