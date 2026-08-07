const std = @import("std");
const config_file = @import("../config/file.zig");
const fsutil = @import("../../shared/fsutil.zig");
const profile_contract = @import("profile.zig");
const routes = @import("../providers/routes.zig");

pub const Error = error{
    EmptyAgentRegistry,
    InvalidAgentDefinition,
    UnknownAgentSpec,
    UnknownAgentBase,
};

pub const AgentSpec = struct {
    id: []const u8,
    description: []const u8,
    when_to_use: []const u8,
    instruction_capsule: []const u8,
    route_role: routes.RouteRole,
    execution_kind: routes.ExecutionKind,
    capability_profile_id: []const u8,
    max_steps: usize,
    max_tool_calls: usize,
    max_children: usize,
    output_contract: []const u8,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    specs: []AgentSpec,

    pub fn deinit(self: Registry) void {
        for (self.specs) |spec| deinitOwnedSpec(self.allocator, spec);
        self.allocator.free(self.specs);
    }

    pub fn all(self: Registry) []const AgentSpec {
        return self.specs;
    }

    pub fn resolve(self: Registry, spec_id: []const u8) Error!AgentSpec {
        for (self.specs) |spec| {
            if (std.mem.eql(u8, spec.id, spec_id)) return spec;
        }
        return Error.UnknownAgentSpec;
    }
};

pub const DefinitionPatch = struct {
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

pub const MutationEvidence = struct {
    config_path: []u8,
    action: []const u8,
    agent_id: []u8,
    before_bytes: usize,
    after_bytes: usize,
    before_sha256: [64]u8,
    after_sha256: [64]u8,

    pub fn deinit(self: MutationEvidence, allocator: std.mem.Allocator) void {
        allocator.free(self.config_path);
        allocator.free(self.agent_id);
    }
};

var config_mutation_mutex: std.Thread.Mutex = .{};

const built_in_specs = [_]AgentSpec{
    .{
        .id = "general",
        .description = "Bounded general-purpose VAR1 child session.",
        .when_to_use = "Use when no narrower specialist owns the task.",
        .instruction_capsule = "Return a concise SITREP with findings, evidence, uncertainty, blockers, and residual risk.",
        .route_role = .general,
        .execution_kind = .agent_session,
        .capability_profile_id = "subagent",
        .max_steps = 96,
        .max_tool_calls = 64,
        .max_children = 2,
        .output_contract = "var1.sitrep.v1",
    },
    .{
        .id = "recon",
        .description = "Read-only repository or evidence reconnaissance.",
        .when_to_use = "Use when ownership, architecture, dependencies, or exact source evidence must be mapped before a decision.",
        .instruction_capsule = "Inspect only. Return findings with exact paths, commands, uncertainty, blockers, and residual risk.",
        .route_role = .recon,
        .execution_kind = .agent_session,
        .capability_profile_id = "recon",
        .max_steps = 64,
        .max_tool_calls = 48,
        .max_children = 0,
        .output_contract = "var1.recon_sitrep.v1",
    },
    .{
        .id = "planner",
        .description = "One-turn plan synthesis from supplied evidence.",
        .when_to_use = "Use after reconnaissance when supplied evidence must become an ordered implementation contract.",
        .instruction_capsule = "Use only supplied context. Return an ordered implementation plan with invariants, proof gates, blockers, and stop conditions.",
        .route_role = .planning,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.plan.v1",
    },
    .{
        .id = "compactor",
        .description = "One-turn dense summary wording over supplied artifacts.",
        .when_to_use = "Use when supplied evidence must be compressed without losing decisions, owners, or unresolved state.",
        .instruction_capsule = "Preserve decisions, evidence, active state, unresolved risks, and exact owner paths. Do not invent facts.",
        .route_role = .compaction,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.compaction_summary.v1",
    },
    .{
        .id = "implementer",
        .description = "Bounded implementation branch with read, write, and command capability.",
        .when_to_use = "Use when one isolated file or module slice can be implemented and validated independently.",
        .instruction_capsule = "Own only the assigned files. Preserve concurrent work. Implement, test, and return a diff-grounded SITREP.",
        .route_role = .implementation,
        .execution_kind = .agent_session,
        .capability_profile_id = "write",
        .max_steps = 128,
        .max_tool_calls = 96,
        .max_children = 0,
        .output_contract = "var1.implementation_sitrep.v1",
    },
    .{
        .id = "reviewer",
        .description = "One-turn supplied-artifact review.",
        .when_to_use = "Use when a bounded artifact set needs an independent findings-first review without tool access.",
        .instruction_capsule = "Review only supplied evidence. Return severity-ordered findings with exact referents and falsification notes.",
        .route_role = .review,
        .execution_kind = .model_task,
        .capability_profile_id = "model_task",
        .max_steps = 1,
        .max_tool_calls = 0,
        .max_children = 0,
        .output_contract = "var1.review.v1",
    },
    .{
        .id = "validator",
        .description = "Read-only validation branch for independent proof.",
        .when_to_use = "Use when commands or source checks can independently falsify an implementation claim without mutation.",
        .instruction_capsule = "Run bounded validation probes without mutation. Return commands, observed outputs, failures, and residual risk.",
        .route_role = .validation,
        .execution_kind = .agent_session,
        .capability_profile_id = "recon",
        .max_steps = 64,
        .max_tool_calls = 48,
        .max_children = 0,
        .output_contract = "var1.validation_sitrep.v1",
    },
};

/// Compiled floors remain available for receipt compatibility and legacy
/// callers. Live discovery and launch must use loadRegistry instead.
pub fn all() []const AgentSpec {
    return built_in_specs[0..];
}

pub fn resolve(spec_id: []const u8) Error!AgentSpec {
    return findBuiltIn(spec_id) orelse Error.UnknownAgentSpec;
}

/// Parse the canonical config on every call. No process-local cache exists:
/// external edits and configure_agent mutations become visible on the next
/// catalog read or launch admission.
pub fn loadRegistry(allocator: std.mem.Allocator, workspace_root: []const u8) !Registry {
    var parsed = try config_file.readValidatedDocument(allocator, workspace_root);
    defer parsed.deinit();
    return loadRegistryFromValue(allocator, parsed.value);
}

pub fn loadRegistryFromValue(allocator: std.mem.Allocator, document: std.json.Value) !Registry {
    try config_file.validateDocumentValue(document);
    const root = document.object;
    const definitions = if (root.get("agents")) |agents_value|
        if (agents_value.object.get("definitions")) |definitions_value| definitions_value.object else null
    else
        null;

    var effective = std.array_list.Managed(AgentSpec).init(allocator);
    errdefer {
        for (effective.items) |spec| deinitOwnedSpec(allocator, spec);
        effective.deinit();
    }

    for (built_in_specs) |base| {
        const override = if (definitions) |items|
            if (items.get(base.id)) |value| value.object else null
        else
            null;
        if (override) |object| {
            if (object.get("extends")) |extends_value| {
                if (extends_value != .null) return Error.InvalidAgentDefinition;
            }
            if (!optionalBool(object, "enabled", true)) continue;
        }
        try appendEffective(&effective, base.id, base, override);
    }

    if (definitions) |items| {
        var iterator = items.iterator();
        while (iterator.next()) |entry| {
            if (findBuiltIn(entry.key_ptr.*) != null) continue;
            const definition = entry.value_ptr.object;
            const extends_value = definition.get("extends") orelse return Error.UnknownAgentBase;
            if (extends_value != .string) return Error.UnknownAgentBase;
            const base = findBuiltIn(extends_value.string) orelse return Error.UnknownAgentBase;
            if (!optionalBool(definition, "enabled", true)) continue;
            try appendEffective(&effective, entry.key_ptr.*, base, definition);
        }
    }

    if (effective.items.len == 0) return Error.EmptyAgentRegistry;
    return .{
        .allocator = allocator,
        .specs = try effective.toOwnedSlice(),
    };
}

/// Compact model-facing selection data. Private instruction capsules stay out
/// of the parent context and are injected only into the selected child prompt.
pub fn renderCatalog(allocator: std.mem.Allocator, registry: Registry) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();
    try writer.writeAll("{\"schema\":\"var1.agent_catalog.v1\",\"hotloaded\":true,\"agents\":[");
    for (registry.specs, 0..) |spec, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{f},\"description\":{f},\"when_to_use\":{f},\"kind\":{f},\"route_role\":{f},\"capability_profile\":{f},\"output_contract\":{f}}}", .{
            std.json.fmt(spec.id, .{}),
            std.json.fmt(spec.description, .{}),
            std.json.fmt(spec.when_to_use, .{}),
            std.json.fmt(spec.execution_kind.label(), .{}),
            std.json.fmt(spec.route_role.label(), .{}),
            std.json.fmt(spec.capability_profile_id, .{}),
            std.json.fmt(spec.output_contract, .{}),
        });
    }
    try writer.writeAll("]}");
    return output.toOwnedSlice();
}

/// Atomically upsert one editable definition, then validate the complete
/// effective registry before the config file becomes visible to readers.
pub fn upsertConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    patch: DefinitionPatch,
) !MutationEvidence {
    config_mutation_mutex.lock();
    defer config_mutation_mutex.unlock();
    return mutateConfiguredAgent(allocator, workspace_root, .upsert, patch);
}

/// Reset removes the configured row. Built-in ids fall back to their compiled
/// floor; custom ids disappear from the next hot-loaded catalog.
pub fn resetConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    agent_id: []const u8,
) !MutationEvidence {
    config_mutation_mutex.lock();
    defer config_mutation_mutex.unlock();
    return mutateConfiguredAgent(allocator, workspace_root, .reset, .{ .id = agent_id });
}

/// Hash the effective capability surface and execution ceilings for receipts.
pub fn capabilityHash(spec: AgentSpec, capability_profile_id: []const u8) ![64]u8 {
    const profile = try profile_contract.resolveProfile(capability_profile_id);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(spec.id);
    hasher.update("\x00");
    hasher.update(spec.execution_kind.label());
    hasher.update("\x00");
    hasher.update(spec.route_role.label());
    hasher.update("\x00");
    hasher.update(capability_profile_id);
    for (profile.allowed_tool_classes) |tool_class| {
        hasher.update("\x00");
        hasher.update(profile_contract.toolClassLabel(tool_class));
    }
    var budget_buffer: [96]u8 = undefined;
    const budget = try std.fmt.bufPrint(&budget_buffer, "{d}:{d}:{d}", .{ spec.max_steps, spec.max_tool_calls, spec.max_children });
    hasher.update(budget);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return hexDigest(digest);
}

pub fn contentHash(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    return hexDigest(digest);
}

fn appendEffective(
    list: *std.array_list.Managed(AgentSpec),
    id: []const u8,
    base: AgentSpec,
    override: ?std.json.ObjectMap,
) !void {
    const spec = try cloneEffective(list.allocator, id, base, override);
    errdefer deinitOwnedSpec(list.allocator, spec);
    try list.append(spec);
}

const MutationAction = enum { upsert, reset };

fn mutateConfiguredAgent(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    action: MutationAction,
    patch: DefinitionPatch,
) !MutationEvidence {
    if (!isValidAgentId(patch.id)) return Error.InvalidAgentDefinition;
    const config_path = try config_file.ensure(allocator, workspace_root);
    errdefer allocator.free(config_path);
    const before = try fsutil.readTextAlloc(allocator, config_path);
    defer allocator.free(before);
    var parsed = try config_file.readValidatedDocument(allocator, workspace_root);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const agents = try ensureObjectField(arena, root, "agents");
    const definitions = try ensureObjectField(arena, agents, "definitions");

    switch (action) {
        .reset => _ = definitions.orderedRemove(patch.id),
        .upsert => {
            const definition = try ensureObjectField(arena, definitions, patch.id);
            if (patch.extends) |value| try putString(arena, definition, "extends", value);
            if (patch.enabled) |value| try putValue(arena, definition, "enabled", .{ .bool = value });
            if (patch.description) |value| try putString(arena, definition, "description", value);
            if (patch.when_to_use) |value| try putString(arena, definition, "when_to_use", value);
            if (patch.instruction) |value| try putString(arena, definition, "instruction", value);
            if (patch.route_role) |value| try putString(arena, definition, "route_role", value);
            if (patch.max_steps) |value| try putInteger(arena, definition, "max_steps", value);
            if (patch.max_tool_calls) |value| try putInteger(arena, definition, "max_tool_calls", value);
            if (patch.max_children) |value| try putInteger(arena, definition, "max_children", value);
            if (patch.output_contract) |value| try putString(arena, definition, "output_contract", value);
        },
    }

    var effective = try loadRegistryFromValue(allocator, parsed.value);
    effective.deinit();
    const after = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    defer allocator.free(after);
    try fsutil.writeText(config_path, after);

    return .{
        .config_path = config_path,
        .action = @tagName(action),
        .agent_id = try allocator.dupe(u8, patch.id),
        .before_bytes = before.len,
        .after_bytes = after.len,
        .before_sha256 = contentHash(before),
        .after_sha256 = contentHash(after),
    };
}

fn ensureObjectField(
    allocator: std.mem.Allocator,
    owner: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    if (owner.getPtr(key)) |value| {
        if (value.* != .object) return Error.InvalidAgentDefinition;
        return &value.object;
    }
    const object = std.json.ObjectMap.init(allocator);
    try owner.put(try allocator.dupe(u8, key), .{ .object = object });
    return &owner.getPtr(key).?.object;
}

fn putString(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: []const u8) !void {
    try putValue(allocator, owner, key, .{ .string = try allocator.dupe(u8, value) });
}

fn putInteger(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: usize) !void {
    const integer = std.math.cast(i64, value) orelse return Error.InvalidAgentDefinition;
    try putValue(allocator, owner, key, .{ .integer = integer });
}

fn putValue(allocator: std.mem.Allocator, owner: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    try owner.put(try allocator.dupe(u8, key), value);
}

fn cloneEffective(
    allocator: std.mem.Allocator,
    id: []const u8,
    base: AgentSpec,
    override: ?std.json.ObjectMap,
) !AgentSpec {
    const object = override;
    const description = if (object) |value| optionalString(value, "description", base.description) else base.description;
    const when_to_use = if (object) |value| optionalString(value, "when_to_use", base.when_to_use) else base.when_to_use;
    const instruction = if (object) |value| optionalString(value, "instruction", base.instruction_capsule) else base.instruction_capsule;
    const role_text = if (object) |value| optionalString(value, "route_role", base.route_role.label()) else base.route_role.label();
    const route_role = routes.RouteRole.parse(role_text) catch return Error.InvalidAgentDefinition;
    const max_steps = if (object) |value| optionalUsize(value, "max_steps", base.max_steps) else base.max_steps;
    const max_tool_calls = if (object) |value| optionalUsize(value, "max_tool_calls", base.max_tool_calls) else base.max_tool_calls;
    const max_children = if (object) |value| optionalUsize(value, "max_children", base.max_children) else base.max_children;
    const output_contract = if (object) |value| optionalString(value, "output_contract", base.output_contract) else base.output_contract;

    try validateEffective(base, max_steps, max_tool_calls, max_children);
    _ = try profile_contract.resolveProfile(base.capability_profile_id);

    const id_owned = try allocator.dupe(u8, id);
    errdefer allocator.free(id_owned);
    const description_owned = try allocator.dupe(u8, description);
    errdefer allocator.free(description_owned);
    const when_owned = try allocator.dupe(u8, when_to_use);
    errdefer allocator.free(when_owned);
    const instruction_owned = try allocator.dupe(u8, instruction);
    errdefer allocator.free(instruction_owned);
    const profile_owned = try allocator.dupe(u8, base.capability_profile_id);
    errdefer allocator.free(profile_owned);
    const contract_owned = try allocator.dupe(u8, output_contract);
    errdefer allocator.free(contract_owned);

    return .{
        .id = id_owned,
        .description = description_owned,
        .when_to_use = when_owned,
        .instruction_capsule = instruction_owned,
        .route_role = route_role,
        .execution_kind = base.execution_kind,
        .capability_profile_id = profile_owned,
        .max_steps = max_steps,
        .max_tool_calls = max_tool_calls,
        .max_children = max_children,
        .output_contract = contract_owned,
    };
}

fn validateEffective(base: AgentSpec, max_steps: usize, max_tool_calls: usize, max_children: usize) !void {
    if (max_steps == 0 or max_steps > 4096 or max_tool_calls > 4096 or max_children > 64) return Error.InvalidAgentDefinition;
    if (base.execution_kind == .model_task) {
        if (max_steps != 1 or max_tool_calls != 0 or max_children != 0) return Error.InvalidAgentDefinition;
        return;
    }
    if (max_tool_calls == 0) return Error.InvalidAgentDefinition;
    const profile = try profile_contract.resolveProfile(base.capability_profile_id);
    if (!profile.delegation_policy.allow_child_launch and max_children != 0) return Error.InvalidAgentDefinition;
}

fn findBuiltIn(spec_id: []const u8) ?AgentSpec {
    for (built_in_specs) |spec| {
        if (std.mem.eql(u8, spec.id, spec_id)) return spec;
    }
    return null;
}

fn isValidAgentId(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or value[0] < 'a' or value[0] > 'z') return false;
    for (value[1..]) |character| {
        if ((character >= 'a' and character <= 'z') or
            (character >= '0' and character <= '9') or
            character == '_') continue;
        return false;
    }
    return true;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8, default: []const u8) []const u8 {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return value.string;
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) bool {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return value.bool;
}

fn optionalUsize(object: std.json.ObjectMap, key: []const u8, default: usize) usize {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    return std.math.cast(usize, value.integer) orelse default;
}

fn deinitOwnedSpec(allocator: std.mem.Allocator, spec: AgentSpec) void {
    allocator.free(spec.id);
    allocator.free(spec.description);
    allocator.free(spec.when_to_use);
    allocator.free(spec.instruction_capsule);
    allocator.free(spec.capability_profile_id);
    allocator.free(spec.output_contract);
}

fn hexDigest(digest: [32]u8) [64]u8 {
    const chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (digest, 0..) |byte, index| {
        result[index * 2] = chars[byte >> 4];
        result[index * 2 + 1] = chars[byte & 0x0f];
    }
    return result;
}

test "agent specs map specialist identity to route and bounded execution" {
    const recon = try resolve("recon");
    try std.testing.expectEqual(routes.RouteRole.recon, recon.route_role);
    try std.testing.expectEqual(@as(usize, 0), recon.max_children);
    const planner = try resolve("planner");
    try std.testing.expectEqual(routes.RouteRole.planning, planner.route_role);
    try std.testing.expectEqual(routes.ExecutionKind.model_task, planner.execution_kind);
    try std.testing.expectEqualStrings("model_task", planner.capability_profile_id);
    try std.testing.expectEqual(@as(usize, 1), planner.max_steps);
    try std.testing.expectEqual(@as(usize, 0), planner.max_tool_calls);
    try std.testing.expectError(Error.UnknownAgentSpec, resolve("agent_for_everything"));
}

test "capability and content hashes are deterministic and domain separated" {
    const recon = try resolve("recon");
    const first = try capabilityHash(recon, "recon");
    const second = try capabilityHash(recon, "recon");
    try std.testing.expectEqualStrings(first[0..], second[0..]);
    try std.testing.expect(!std.mem.eql(u8, first[0..], contentHash("recon")[0..]));
}

test "custom personas inherit fixed capability floors" {
    const document =
        \\{"version":1,"agents":{"orchestrator_only":true,"definitions":{"frontend_recon":{"extends":"recon","description":"Frontend ownership recon.","when_to_use":"Use for frontend ownership.","instruction":"Inspect frontend only.","route_role":"validation","max_steps":20,"max_tool_calls":10,"max_children":0,"output_contract":"var1.frontend_recon.v1"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    var registry = try loadRegistryFromValue(std.testing.allocator, parsed.value);
    defer registry.deinit();
    const custom = try registry.resolve("frontend_recon");
    try std.testing.expectEqual(routes.ExecutionKind.agent_session, custom.execution_kind);
    try std.testing.expectEqualStrings("recon", custom.capability_profile_id);
    try std.testing.expectEqual(routes.RouteRole.validation, custom.route_role);
    try std.testing.expectEqual(@as(usize, 10), custom.max_tool_calls);
}

test "custom personas cannot escalate inherited model task capability" {
    const document =
        \\{"version":1,"agents":{"definitions":{"unsafe_planner":{"extends":"planner","max_steps":2,"max_tool_calls":1}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidAgentDefinition, loadRegistryFromValue(std.testing.allocator, parsed.value));
}

test "compact catalog omits private instruction capsules" {
    const document = "{\"version\":1}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    var registry = try loadRegistryFromValue(std.testing.allocator, parsed.value);
    defer registry.deinit();
    const catalog = try renderCatalog(std.testing.allocator, registry);
    defer std.testing.allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "when_to_use") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "instruction_capsule") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Inspect only. Return findings") == null);
}
