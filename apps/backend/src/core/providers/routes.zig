const std = @import("std");
const auth_store = @import("../auth/store.zig");
const config_file = @import("../config/file.zig");
const profile_contract = @import("../agents/profile.zig");
const provider_profile = @import("profile.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidRoute,
    UnsupportedExecutionKind,
    UnsupportedRouteRole,
};

pub const ExecutionKind = enum {
    kernel,
    model_task,
    agent_session,

    pub fn label(self: ExecutionKind) []const u8 {
        return switch (self) {
            .kernel => "kernel",
            .model_task => "model_task",
            .agent_session => "agent_session",
        };
    }

    pub fn parse(value: []const u8) Error!ExecutionKind {
        if (std.mem.eql(u8, value, "kernel")) return .kernel;
        if (std.mem.eql(u8, value, "model_task")) return .model_task;
        if (std.mem.eql(u8, value, "agent_session")) return .agent_session;
        return Error.UnsupportedExecutionKind;
    }
};

pub const RouteRole = enum {
    general,
    recon,
    planning,
    compaction,
    implementation,
    review,
    validation,

    pub fn label(self: RouteRole) []const u8 {
        return @tagName(self);
    }

    pub fn parse(value: []const u8) Error!RouteRole {
        inline for (std.meta.fields(RouteRole)) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return Error.UnsupportedRouteRole;
    }
};

pub const RouteDefaults = struct {
    execution_kind: ExecutionKind,
    capability_profile_id: []const u8,
};

/// Return the compiled floor for a role; config may narrow or remap it.
pub fn defaultsForRole(role: RouteRole) RouteDefaults {
    return switch (role) {
        .general => .{ .execution_kind = .agent_session, .capability_profile_id = "subagent" },
        .recon => .{ .execution_kind = .agent_session, .capability_profile_id = "recon" },
        .planning => .{ .execution_kind = .model_task, .capability_profile_id = "model_task" },
        .compaction => .{ .execution_kind = .model_task, .capability_profile_id = "model_task" },
        .implementation => .{ .execution_kind = .agent_session, .capability_profile_id = "write" },
        .review => .{ .execution_kind = .model_task, .capability_profile_id = "model_task" },
        .validation => .{ .execution_kind = .agent_session, .capability_profile_id = "recon" },
    };
}

pub const ResolveBudget = struct {
    max_steps: usize,
    max_tool_calls: usize,
    execution_kind: ?ExecutionKind = null,
    capability_profile_id: ?[]const u8 = null,
};

pub const ResolvedRoute = struct {
    role: RouteRole,
    execution_kind: ExecutionKind,
    capability_profile_id: []u8,
    config: types.Config,
    thinking_mode_owned: []u8,
    effort_owned: []u8,

    pub fn deinit(self: ResolvedRoute, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        allocator.free(self.capability_profile_id);
        allocator.free(self.thinking_mode_owned);
        if (self.effort_owned.len > 0) allocator.free(self.effort_owned);
    }

    pub fn providerId(self: ResolvedRoute) []const u8 {
        return self.config.auth_provider orelse "active";
    }

    pub fn clone(self: ResolvedRoute, allocator: std.mem.Allocator) !ResolvedRoute {
        const thinking_mode_owned = try allocator.dupe(u8, self.thinking_mode_owned);
        errdefer allocator.free(thinking_mode_owned);
        const effort_owned: []u8 = if (self.effort_owned.len > 0) try allocator.dupe(u8, self.effort_owned) else @constCast("");
        errdefer if (self.effort_owned.len > 0) allocator.free(effort_owned);
        const capability_profile_id = try allocator.dupe(u8, self.capability_profile_id);
        errdefer allocator.free(capability_profile_id);
        var context_policy = self.config.context_policy;
        context_policy.embedding_provider = if (self.config.context_policy.embedding_provider) |value| try allocator.dupe(u8, value) else null;
        errdefer context_policy.deinit(allocator);
        const prompt_policy = types.PromptPolicy{
            .system_prompt_file = if (self.config.prompt_policy.system_prompt_file) |value| try allocator.dupe(u8, value) else null,
            .developer_prompt_file = if (self.config.prompt_policy.developer_prompt_file) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer prompt_policy.deinit(allocator);
        const config = types.Config{
            .openai_base_url = try allocator.dupe(u8, self.config.openai_base_url),
            .openai_api_key = try allocator.dupe(u8, self.config.openai_api_key),
            .openai_model = try allocator.dupe(u8, self.config.openai_model),
            .auth_provider = if (self.config.auth_provider) |value| try allocator.dupe(u8, value) else null,
            .auth_type = self.config.auth_type,
            .auth_scheme = self.config.auth_scheme,
            .auth_account_id = if (self.config.auth_account_id) |value| try allocator.dupe(u8, value) else null,
            .auth_expires_at_ms = self.config.auth_expires_at_ms,
            .subscription_plan_label = if (self.config.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
            .subscription_status = if (self.config.subscription_status) |value| try allocator.dupe(u8, value) else null,
            .max_steps = self.config.max_steps,
            .max_tool_calls_per_turn = self.config.max_tool_calls_per_turn,
            .max_tool_calls_per_session = self.config.max_tool_calls_per_session,
            .workspace_root = try allocator.dupe(u8, self.config.workspace_root),
            .full_access_mode = self.config.full_access_mode,
            .context_policy = context_policy,
            .prompt_policy = prompt_policy,
            .memory_policy = self.config.memory_policy,
            .wire_api = self.config.wire_api,
            .thinking_mode = thinking_mode_owned,
            .effort = effort_owned,
            .temperature = self.config.temperature,
        };
        return .{
            .role = self.role,
            .execution_kind = self.execution_kind,
            .capability_profile_id = capability_profile_id,
            .config = config,
            .thinking_mode_owned = thinking_mode_owned,
            .effort_owned = effort_owned,
        };
    }
};

/// Resolve one secret-bearing runtime config and one secret-free route identity.
pub fn resolve(
    allocator: std.mem.Allocator,
    parent: types.Config,
    role: RouteRole,
    budget: ResolveBudget,
) !ResolvedRoute {
    if (budget.max_steps == 0) return Error.InvalidRoute;

    var override = try config_file.loadAgentRouteOverride(allocator, parent.workspace_root, role.label());
    defer override.deinit(allocator);
    const defaults = defaultsForRole(role);
    const execution_kind = budget.execution_kind orelse defaults.execution_kind;
    if (execution_kind == .kernel) return Error.UnsupportedExecutionKind;
    if (execution_kind == .model_task) {
        if (budget.max_tool_calls != 0) return Error.InvalidRoute;
    } else if (budget.max_tool_calls == 0) {
        return Error.InvalidRoute;
    }
    const capability_profile_id = budget.capability_profile_id orelse defaults.capability_profile_id;
    _ = try profile_contract.resolveProfile(capability_profile_id);

    var selected_auth: ?auth_store.ResolvedAuth = null;
    defer if (selected_auth) |value| value.deinit(allocator);
    var selected_provider_id: ?[]const u8 = if (override.provider_id) |provider_id| blk: {
        if (!hasText(provider_id)) return Error.InvalidRoute;
        break :blk provider_profile.canonicalProviderId(provider_id);
    } else null;
    var model_override: ?[]const u8 = override.model;
    if (model_override) |model_ref| {
        const selection = provider_profile.resolveModelSelection(model_ref, selected_provider_id);
        selected_provider_id = selection.provider_id orelse selected_provider_id;
        model_override = selection.model_id;
    }
    if (selected_provider_id) |provider_id| {
        selected_auth = try auth_store.readProviderById(allocator, parent.workspace_root, provider_id);
    }

    const base_url = if (selected_auth) |value| value.base_url else parent.openai_base_url;
    const api_key = if (selected_auth) |value| value.api_key else parent.openai_api_key;
    const provider_id = if (selected_auth) |value| value.provider_id else parent.auth_provider orelse "active";
    const provider_model = if (selected_auth) |value| value.model else parent.openai_model;
    const auth_type = if (selected_auth) |value| value.auth_type else parent.auth_type;
    const auth_scheme = if (selected_auth) |value| value.auth_scheme else parent.auth_scheme;
    const auth_account_id = if (selected_auth) |value| value.account_id else parent.auth_account_id;
    const auth_expires_at_ms = if (selected_auth) |value| value.expires_at_ms else parent.auth_expires_at_ms;
    const wire_api = if (selected_auth) |value| value.wire_api else parent.wire_api;
    const model = model_override orelse provider_model;
    const thinking_mode = override.thinking_mode orelse parent.thinking_mode;
    const effort = if (override.effort) |e| e else parent.effort;
    const temperature = if (override.temperature) |t| t else parent.temperature;
    if (!hasText(base_url) or !hasText(model) or !hasText(provider_id)) return Error.InvalidRoute;

    const thinking_owned = try allocator.dupe(u8, thinking_mode);
    errdefer allocator.free(thinking_owned);
    const effort_owned: []u8 = if (effort.len > 0) try allocator.dupe(u8, effort) else @constCast("");
    errdefer if (effort.len > 0) allocator.free(effort_owned);
    const profile_owned = try allocator.dupe(u8, capability_profile_id);
    errdefer allocator.free(profile_owned);

    var context_policy = parent.context_policy;
    context_policy.embedding_provider = if (parent.context_policy.embedding_provider) |value| try allocator.dupe(u8, value) else null;
    errdefer context_policy.deinit(allocator);
    if (override.context_window_tokens) |value| context_policy.context_window_tokens = value;
    if (override.reserve_output_tokens) |value| context_policy.reserve_output_tokens = value;
    if (context_policy.reserve_output_tokens >= context_policy.context_window_tokens) return Error.InvalidRoute;

    const prompt_policy = types.PromptPolicy{
        .system_prompt_file = if (parent.prompt_policy.system_prompt_file) |value| try allocator.dupe(u8, value) else null,
        .developer_prompt_file = if (parent.prompt_policy.developer_prompt_file) |value| try allocator.dupe(u8, value) else null,
    };
    errdefer prompt_policy.deinit(allocator);

    const config = types.Config{
        .openai_base_url = try allocator.dupe(u8, base_url),
        .openai_api_key = try allocator.dupe(u8, api_key),
        .openai_model = try allocator.dupe(u8, model),
        .auth_provider = try allocator.dupe(u8, provider_id),
        .auth_type = auth_type,
        .auth_scheme = auth_scheme,
        .auth_account_id = if (auth_account_id) |value| try allocator.dupe(u8, value) else null,
        .auth_expires_at_ms = auth_expires_at_ms,
        .subscription_plan_label = if (selected_auth) |value|
            if (value.subscription_plan_label) |label| try allocator.dupe(u8, label) else null
        else if (parent.subscription_plan_label) |label|
            try allocator.dupe(u8, label)
        else
            null,
        .subscription_status = if (selected_auth) |value|
            if (value.subscription_status) |status| try allocator.dupe(u8, status) else null
        else if (parent.subscription_status) |status|
            try allocator.dupe(u8, status)
        else
            null,
        .max_steps = if (execution_kind == .model_task) 1 else budget.max_steps,
        .max_tool_calls_per_turn = if (execution_kind == .model_task) 0 else @min(parent.max_tool_calls_per_turn, budget.max_tool_calls),
        .max_tool_calls_per_session = if (execution_kind == .model_task) 0 else @min(parent.max_tool_calls_per_session, budget.max_tool_calls),
        .workspace_root = try allocator.dupe(u8, parent.workspace_root),
        .full_access_mode = parent.full_access_mode,
        .context_policy = context_policy,
        .prompt_policy = prompt_policy,
        .memory_policy = parent.memory_policy,
        .wire_api = override.wire_api orelse wire_api,
        .thinking_mode = thinking_owned,
        .effort = effort_owned,
        .temperature = temperature,
    };

    return .{
        .role = role,
        .execution_kind = execution_kind,
        .capability_profile_id = profile_owned,
        .config = config,
        .thinking_mode_owned = thinking_owned,
        .effort_owned = effort_owned,
    };
}

fn hasText(value: []const u8) bool {
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

test "route roles have stable labels and compiled execution floors" {
    try std.testing.expectEqual(RouteRole.recon, try RouteRole.parse("recon"));
    try std.testing.expectEqualStrings("implementation", RouteRole.implementation.label());
    try std.testing.expectEqual(ExecutionKind.agent_session, defaultsForRole(.recon).execution_kind);
    try std.testing.expectEqual(ExecutionKind.model_task, defaultsForRole(.planning).execution_kind);
    try std.testing.expectEqualStrings("write", defaultsForRole(.implementation).capability_profile_id);
    try std.testing.expectError(Error.UnsupportedRouteRole, RouteRole.parse("invented"));
    try std.testing.expectError(Error.UnsupportedExecutionKind, ExecutionKind.parse("process"));
}
