const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidConfig,
    UnsupportedVersion,
};

pub const RuntimePolicy = struct {
    workspace: ?[]u8 = null,
    max_steps: usize = 4096,
    max_tool_calls_per_turn: usize = 16,
    max_tool_calls_per_session: usize = 96,
    /// Permit agent-facing file and process paths outside the active workspace.
    /// Restricted mode remains the default safety boundary.
    full_access_mode: bool = false,
    log_level: types.LogLevel = .silent,
    effort: ?[]u8 = null,
    temperature: ?f64 = null,

    pub fn deinit(self: RuntimePolicy, allocator: std.mem.Allocator) void {
        if (self.workspace) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
    }
};

pub const TuiTheme = enum {
    vantari,
    midnight,
    high_contrast,
    amber,

    pub fn label(self: TuiTheme) []const u8 {
        return switch (self) {
            .vantari => "vantari",
            .midnight => "midnight",
            .high_contrast => "high_contrast",
            .amber => "amber",
        };
    }

    pub fn fromString(value: []const u8) ?TuiTheme {
        if (std.mem.eql(u8, value, "vantari")) return .vantari;
        if (std.mem.eql(u8, value, "midnight")) return .midnight;
        if (std.mem.eql(u8, value, "high_contrast")) return .high_contrast;
        if (std.mem.eql(u8, value, "amber")) return .amber;
        return null;
    }

    pub fn next(self: TuiTheme) TuiTheme {
        return switch (self) {
            .vantari => .midnight,
            .midnight => .high_contrast,
            .high_contrast => .amber,
            .amber => .vantari,
        };
    }
};

pub const StatusBarPosition = enum {
    bottom,
    top,

    pub fn label(self: StatusBarPosition) []const u8 {
        return switch (self) {
            .bottom => "bottom",
            .top => "top",
        };
    }

    pub fn fromString(value: []const u8) ?StatusBarPosition {
        if (std.mem.eql(u8, value, "bottom")) return .bottom;
        if (std.mem.eql(u8, value, "top")) return .top;
        return null;
    }

    pub fn next(self: StatusBarPosition) StatusBarPosition {
        return switch (self) {
            .bottom => .top,
            .top => .bottom,
        };
    }
};

pub const TuiPolicy = struct {
    theme: TuiTheme = .vantari,
    status_bar_position: StatusBarPosition = .bottom,
};

pub const AgentRouteOverride = struct {
    provider_id: ?[]u8 = null,
    model: ?[]u8 = null,
    wire_api: ?types.WireApi = null,
    thinking_mode: ?[]u8 = null,
    context_window_tokens: ?u64 = null,
    reserve_output_tokens: ?u64 = null,
    effort: ?[]u8 = null,
    temperature: ?f64 = null,

    pub fn deinit(self: AgentRouteOverride, allocator: std.mem.Allocator) void {
        if (self.provider_id) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.thinking_mode) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
    }
};

pub const default_document = @embedFile("default.json");

pub fn path(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    return fsutil.join(allocator, &.{ root, "config.json" });
}

/// Ensure the canonical non-secret runtime configuration exists before any
/// loader reads policy. Existing files are never rewritten implicitly.
pub fn ensure(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const config_path = try path(allocator, workspace_root);
    errdefer allocator.free(config_path);
    if (!fsutil.fileExists(config_path)) try fsutil.writeText(config_path, default_document);
    return config_path;
}

/// Atomically set one config key under a section. Reads the current document,
/// mutates the key, re-validates the entire document, and writes atomically.
/// Returns Error.InvalidConfig if validation fails — the file is NOT modified
/// on validation failure. This is the primitive the TUI settings panel and
/// self-tuning protocol use to mutate config without a text editor.
pub fn writeConfigKey(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    section: []const u8,
    key: []const u8,
    value: std.json.Value,
) !void {
    const config_path = try ensure(allocator, workspace_root);
    defer allocator.free(config_path);
    const content = try fsutil.readTextAlloc(allocator, config_path);
    defer allocator.free(content);

    // Parse the current document.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidConfig;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.InvalidConfig;
    const root = parsed.value.object;

    // Navigate to the section.
    const section_obj = root.getPtr(section) orelse return Error.InvalidConfig;
    if (section_obj.* != .object) return Error.InvalidConfig;

    // Mutate the key within the section. The ObjectMap uses the parsed
    // arena's managed allocator internally.
    try section_obj.*.object.put(key, value);

    // Re-validate the ENTIRE document after mutation. If validation fails,
    // the file is NOT written — the caller gets Error.InvalidConfig and the
    // on-disk file remains in its previous valid state.
    try validateDocumentValue(parsed.value);

    // Serialize the validated document and write atomically. Use std.json.fmt
    // which produces a Formatter compatible with allocPrint.
    const formatted = try std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(parsed.value, .{ .whitespace = .indent_2 }),
    });
    defer allocator.free(formatted);
    try fsutil.writeText(config_path, formatted);
}

/// Set a config key to a string value — convenience wrapper for the common
/// case (effort, model, persona text, etc.).
pub fn writeConfigString(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    section: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const json_value = std.json.Value{ .string = try arena_alloc.dupe(u8, value) };
    try writeConfigKey(allocator, workspace_root, section, key, json_value);
}

/// Set a config key to null (disable it). Used for guardrails/persona toggles.
pub fn writeConfigNull(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    section: []const u8,
    key: []const u8,
) !void {
    try writeConfigKey(allocator, workspace_root, section, key, .null);
}

pub fn loadRuntimePolicy(allocator: std.mem.Allocator, workspace_root: []const u8) !RuntimePolicy {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const root = parsed.value.object;

    var result = RuntimePolicy{};
    errdefer result.deinit(allocator);

    if (objectField(root, "runtime")) |runtime| {
        result.workspace = try optionalStringClone(allocator, runtime, "workspace");
        result.max_steps = try optionalUsize(runtime, "max_steps", result.max_steps);
        result.max_tool_calls_per_turn = try optionalUsize(runtime, "max_tool_calls_per_turn", result.max_tool_calls_per_turn);
        result.max_tool_calls_per_session = try optionalUsize(runtime, "max_tool_calls_per_session", result.max_tool_calls_per_session);
        result.full_access_mode = try optionalBool(runtime, "full_access_mode", result.full_access_mode);
        if (runtime.get("log_level")) |value| {
            if (value != .string) return Error.InvalidConfig;
            result.log_level = types.LogLevel.fromString(value.string) orelse return Error.InvalidConfig;
        }
        result.effort = try optionalStringClone(allocator, runtime, "effort");
        result.temperature = try optionalFloat(runtime, "temperature");
    }

    if (objectField(root, "environment")) |environment| {
        try applyEnvironmentObject(allocator, &result, environment);
    }
    try applyProcessEnvironment(allocator, &result);
    if (result.max_steps == 0 or
        result.max_tool_calls_per_turn == 0 or
        result.max_tool_calls_per_session < result.max_tool_calls_per_turn) return Error.InvalidConfig;
    return result;
}

pub fn loadTuiPolicy(allocator: std.mem.Allocator, workspace_root: []const u8) !TuiPolicy {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const owner = objectField(parsed.value.object, "tui") orelse return .{};
    var result = TuiPolicy{};
    if (owner.get("theme")) |value| {
        if (value != .string) return Error.InvalidConfig;
        result.theme = TuiTheme.fromString(value.string) orelse return Error.InvalidConfig;
    }
    if (owner.get("status_bar_position")) |value| {
        if (value != .string) return Error.InvalidConfig;
        result.status_bar_position = StatusBarPosition.fromString(value.string) orelse return Error.InvalidConfig;
    }
    return result;
}

pub fn loadWireApi(allocator: std.mem.Allocator, workspace_root: []const u8) !?types.WireApi {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const provider = objectField(parsed.value.object, "provider") orelse return null;
    const value = provider.get("wire_api") orelse return null;
    if (value != .string) return Error.InvalidConfig;
    return types.WireApi.fromString(value.string) orelse Error.InvalidConfig;
}

/// Load the fixed worker-pool ceiling from the canonical config owner.
pub fn loadAgentMaxConcurrency(allocator: std.mem.Allocator, workspace_root: []const u8) !usize {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const routes = objectField(parsed.value.object, "agent_routes") orelse return 6;
    const value = try optionalUsize(routes, "max_concurrency", 6);
    if (value == 0 or value > 64) return Error.InvalidConfig;
    return value;
}

/// Load one role override without turning config.json into a credential store.
pub fn loadAgentRouteOverride(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    role_id: []const u8,
) !AgentRouteOverride {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const routes = objectField(parsed.value.object, "agent_routes") orelse return .{};
    const roles = objectField(routes, "roles") orelse return .{};
    const role = objectField(roles, role_id) orelse return .{};

    return try loadAgentRouteOverrideValue(allocator, role);
}

/// Load the optional model/provider route attached to one prompt mode. Mode
/// routing shares the existing route override shape; it changes only the
/// provider identity and turn budgets, never tools, capability, or executor
/// behavior.
pub fn loadPromptModeOverride(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    mode_id: []const u8,
) !AgentRouteOverride {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const routes = objectField(parsed.value.object, "agent_routes") orelse return .{};
    const prompt_modes = objectField(routes, "prompt_modes") orelse return .{};
    const mode = objectField(prompt_modes, mode_id) orelse return .{};

    return try loadAgentRouteOverrideValue(allocator, mode);
}

fn loadAgentRouteOverrideValue(allocator: std.mem.Allocator, role: std.json.ObjectMap) !AgentRouteOverride {
    var result = AgentRouteOverride{};
    errdefer result.deinit(allocator);
    result.provider_id = try optionalStringClone(allocator, role, "provider_id");
    result.model = try optionalStringClone(allocator, role, "model");
    result.thinking_mode = try optionalStringClone(allocator, role, "thinking_mode");
    result.effort = try optionalStringClone(allocator, role, "effort");
    result.temperature = try optionalFloat(role, "temperature");
    result.context_window_tokens = try optionalOptionalU64(role, "context_window_tokens");
    result.reserve_output_tokens = try optionalOptionalU64(role, "reserve_output_tokens");
    if (role.get("wire_api")) |value| {
        if (value != .null) {
            if (value != .string) return Error.InvalidConfig;
            result.wire_api = types.WireApi.fromString(value.string) orelse return Error.InvalidConfig;
        }
    }
    return result;
}

pub fn loadContextPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    defaults: types.ContextPolicy,
) !types.ContextPolicy {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const context = objectField(parsed.value.object, "context") orelse return defaults;

    var policy = defaults;
    policy.auto_compaction = try optionalBool(context, "auto_compaction", policy.auto_compaction);
    policy.manual_compaction = try optionalBool(context, "manual_compaction", policy.manual_compaction);
    policy.context_window_tokens = try optionalU64(context, "context_window_tokens", policy.context_window_tokens);
    policy.prompt_budget_tokens = try optionalU64(context, "prompt_budget_tokens", policy.prompt_budget_tokens);
    policy.compact_at_ratio_milli = try optionalU16(context, "compact_at_ratio_milli", policy.compact_at_ratio_milli);
    policy.reserve_output_tokens = try optionalU64(context, "reserve_output_tokens", policy.reserve_output_tokens);
    policy.keep_recent_messages = try optionalUsize(context, "keep_recent_messages", policy.keep_recent_messages);
    policy.max_entries_per_checkpoint = try optionalUsize(context, "max_entries_per_checkpoint", policy.max_entries_per_checkpoint);
    policy.aggressiveness_milli = try optionalU16(context, "aggressiveness_milli", policy.aggressiveness_milli);
    policy.retry_on_provider_overflow = try optionalBool(context, "retry_on_provider_overflow", policy.retry_on_provider_overflow);

    if (policy.context_window_tokens == 0 or
        policy.prompt_budget_tokens == 0 or
        policy.compact_at_ratio_milli == 0 or
        policy.compact_at_ratio_milli > 1000 or
        policy.reserve_output_tokens >= policy.context_window_tokens or
        policy.keep_recent_messages == 0 or
        policy.aggressiveness_milli > 1000) return Error.InvalidConfig;
    return policy;
}

pub fn hasExplicitContextWindow(allocator: std.mem.Allocator, workspace_root: []const u8) bool {
    var parsed = parseDocument(allocator, workspace_root) catch return false;
    defer parsed.deinit();
    const context = objectField(parsed.value.object, "context") orelse return false;
    const value = context.get("context_window_tokens") orelse return false;
    return value == .integer and value.integer > 0;
}

pub fn loadPromptPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    defaults: types.PromptPolicy,
) !types.PromptPolicy {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const prompts = objectField(parsed.value.object, "prompts") orelse return clonePromptPolicy(allocator, defaults);

    var policy = try clonePromptPolicy(allocator, defaults);
    errdefer policy.deinit(allocator);
    if (try optionalStringClone(allocator, prompts, "system_prompt_file")) |value| {
        if (std.fs.path.isAbsolute(value)) return Error.InvalidConfig;
        if (policy.system_prompt_file) |old| allocator.free(old);
        policy.system_prompt_file = value;
    }
    if (try optionalStringClone(allocator, prompts, "developer_prompt_file")) |value| {
        if (std.fs.path.isAbsolute(value)) return Error.InvalidConfig;
        if (policy.developer_prompt_file) |old| allocator.free(old);
        policy.developer_prompt_file = value;
    }
    if (try optionalStringClone(allocator, prompts, "persona")) |value| {
        if (policy.persona) |old| allocator.free(old);
        policy.persona = value;
    }
    if (try optionalStringClone(allocator, prompts, "guardrails")) |value| {
        if (policy.guardrails) |old| allocator.free(old);
        policy.guardrails = value;
    }
    if (try optionalStringClone(allocator, prompts, "user_context")) |value| {
        if (policy.user_context) |old| allocator.free(old);
        policy.user_context = value;
    }
    return policy;
}

pub fn loadMemoryPolicy(allocator: std.mem.Allocator, workspace_root: []const u8, defaults: types.MemoryPolicy) !types.MemoryPolicy {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const owner = objectField(parsed.value.object, "memory") orelse return defaults;
    var policy = defaults;
    policy.enabled = try optionalBool(owner, "enabled", policy.enabled);
    policy.agent_writes_enabled = try optionalBool(owner, "agent_writes_enabled", policy.agent_writes_enabled);
    policy.max_entry_bytes = try optionalUsize(owner, "max_entry_bytes", policy.max_entry_bytes);
    policy.max_session_context_bytes = try optionalUsize(owner, "max_session_context_bytes", policy.max_session_context_bytes);
    policy.max_global_context_bytes = try optionalUsize(owner, "max_global_context_bytes", policy.max_global_context_bytes);
    policy.max_context_entries = try optionalUsize(owner, "max_context_entries", policy.max_context_entries);
    if (policy.max_entry_bytes == 0 or policy.max_entry_bytes > 64 * 1024 or
        policy.max_context_entries == 0 or policy.max_context_entries > 1024 or
        policy.max_session_context_bytes > 1024 * 1024 or policy.max_global_context_bytes > 1024 * 1024) return Error.InvalidConfig;
    return policy;
}

pub fn readValidatedDocument(allocator: std.mem.Allocator, workspace_root: []const u8) !std.json.Parsed(std.json.Value) {
    return parseDocument(allocator, workspace_root);
}

pub fn validateDocumentValue(value: std.json.Value) !void {
    if (value != .object) return Error.InvalidConfig;
    const version = value.object.get("version") orelse return Error.InvalidConfig;
    if (version != .integer or version.integer != 1) return Error.UnsupportedVersion;
    try validateDocumentShape(value.object);
}

fn parseDocument(allocator: std.mem.Allocator, workspace_root: []const u8) !std.json.Parsed(std.json.Value) {
    const config_path = try ensure(allocator, workspace_root);
    defer allocator.free(config_path);
    const content = try fsutil.readTextAlloc(allocator, config_path);
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidConfig;
    errdefer parsed.deinit();
    try validateDocumentValue(parsed.value);
    return parsed;
}

fn validateDocumentShape(root: std.json.ObjectMap) !void {
    try rejectUnknownKeys(root, &.{ "_about", "_help", "version", "runtime", "tui", "provider", "agent_routes", "agents", "context", "prompts", "draft", "buffer", "memory", "environment" });
    try validateAbout(root);
    try validateHelp(root, &.{"version"});
    if (try validatedObjectField(root, "runtime")) |value| {
        const keys = &.{ "workspace", "max_steps", "max_tool_calls_per_turn", "max_tool_calls_per_session", "full_access_mode", "log_level", "effort", "temperature" };
        try rejectUnknownKeys(value, &.{ "_help", "workspace", "max_steps", "max_tool_calls_per_turn", "max_tool_calls_per_session", "full_access_mode", "log_level", "effort", "temperature" });
        try validateHelp(value, keys);
        _ = try optionalBool(value, "full_access_mode", false);
        if (value.get("log_level")) |log_level| {
            if (log_level != .string or types.LogLevel.fromString(log_level.string) == null) return Error.InvalidConfig;
        }
    }
    if (try validatedObjectField(root, "tui")) |value| {
        const keys = &.{ "theme", "status_bar_position" };
        try rejectUnknownKeys(value, &.{ "_help", "theme", "status_bar_position" });
        try validateHelp(value, keys);
        if (value.get("theme")) |theme| {
            if (theme != .string or TuiTheme.fromString(theme.string) == null) return Error.InvalidConfig;
        }
        if (value.get("status_bar_position")) |position| {
            if (position != .string or StatusBarPosition.fromString(position.string) == null) return Error.InvalidConfig;
        }
    }
    if (try validatedObjectField(root, "provider")) |value| {
        try rejectUnknownKeys(value, &.{ "_help", "wire_api" });
        try validateHelp(value, &.{"wire_api"});
        // Validate the wire_api VALUE at document-shape time so config/set
        // (validation-before-write) and every load path reject invented
        // values before any mutation or runtime fallback.
        if (value.get("wire_api")) |wire_api| {
            if (wire_api != .string or types.WireApi.fromString(wire_api.string) == null) return Error.InvalidConfig;
        }
    }
    if (try validatedObjectField(root, "agent_routes")) |value| {
        try rejectUnknownKeys(value, &.{ "_help", "max_concurrency", "roles", "prompt_modes" });
        try validateHelp(value, &.{ "max_concurrency", "roles", "prompt_modes" });
        const max_concurrency = try optionalUsize(value, "max_concurrency", 6);
        if (max_concurrency == 0 or max_concurrency > 64) return Error.InvalidConfig;
        if (try validatedObjectField(value, "roles")) |roles| {
            var iterator = roles.iterator();
            while (iterator.next()) |entry| {
                if (!isKnownAgentRouteRole(entry.key_ptr.*)) return Error.InvalidConfig;
                if (entry.value_ptr.* != .object) return Error.InvalidConfig;
                try rejectUnknownKeys(entry.value_ptr.object, &.{
                    "provider_id",
                    "model",
                    "wire_api",
                    "thinking_mode",
                    "context_window_tokens",
                    "reserve_output_tokens",
                });
                try validateAgentRoute(entry.value_ptr.object);
            }
        }
        if (try validatedObjectField(value, "prompt_modes")) |prompt_modes| {
            var iterator = prompt_modes.iterator();
            while (iterator.next()) |entry| {
                if (!isKnownPromptMode(entry.key_ptr.*)) return Error.InvalidConfig;
                if (entry.value_ptr.* != .object) return Error.InvalidConfig;
                try rejectUnknownKeys(entry.value_ptr.object, &.{
                    "provider_id",
                    "model",
                    "wire_api",
                    "thinking_mode",
                    "context_window_tokens",
                    "reserve_output_tokens",
                });
                try validateAgentRoute(entry.value_ptr.object);
            }
        }
    }
    if (try validatedObjectField(root, "agents")) |value| {
        // Keep the retired key readable for existing config files, but never
        // load or apply it. PromptMode.orchestrate is the only live owner of
        // the root orchestration posture.
        try rejectUnknownKeys(value, &.{ "_help", "orchestrator_only", "definitions" });
        try validateHelp(value, &.{ "orchestrator_only", "definitions" });
        if (value.get("orchestrator_only")) |legacy| {
            if (legacy != .bool) return Error.InvalidConfig;
        }
        if (try validatedObjectField(value, "definitions")) |definitions| {
            var iterator = definitions.iterator();
            while (iterator.next()) |entry| {
                if (!isValidAgentId(entry.key_ptr.*)) return Error.InvalidConfig;
                if (entry.value_ptr.* != .object) return Error.InvalidConfig;
                const definition = entry.value_ptr.object;
                try rejectUnknownKeys(definition, &.{
                    "extends",
                    "enabled",
                    "description",
                    "when_to_use",
                    "instruction",
                    "route_role",
                    "max_steps",
                    "max_tool_calls",
                    "max_children",
                    "output_contract",
                    "doctrine_tags",
                    "ticket_ownership",
                    "checkpoint_contract",
                    "autonomy",
                    "effort",
                    "temperature",
                });
                try validateOptionalAgentString(definition, "extends", 64);
                try validateOptionalAgentString(definition, "description", 512);
                try validateOptionalAgentString(definition, "when_to_use", 512);
                try validateOptionalAgentString(definition, "instruction", 16 * 1024);
                try validateOptionalAgentString(definition, "output_contract", 256);
                try validateOptionalAgentString(definition, "doctrine_tags", 1024);
                try validateOptionalAgentString(definition, "checkpoint_contract", 256);
                try validateOptionalAgentString(definition, "effort", 64);
                _ = try optionalBool(definition, "enabled", true);
                _ = try optionalBool(definition, "ticket_ownership", true);
                if (definition.get("autonomy")) |autonomy| {
                    if (autonomy != .null and (autonomy != .string or !isValidAutonomyValue(autonomy.string))) return Error.InvalidConfig;
                }
                if (definition.get("temperature")) |temperature| {
                    if (temperature != .null) {
                        if (temperature != .float and temperature != .integer) return Error.InvalidConfig;
                        const temperature_value: f64 = if (temperature == .float) temperature.float else @floatFromInt(temperature.integer);
                        if (temperature_value != -1 and (temperature_value < 0 or temperature_value > 2)) return Error.InvalidConfig;
                    }
                }
                if (definition.get("route_role")) |role| {
                    if (role != .null and (role != .string or !isKnownAgentRouteRole(role.string))) return Error.InvalidConfig;
                }
                const max_steps = try optionalUsize(definition, "max_steps", 1);
                const max_tool_calls = try optionalUsize(definition, "max_tool_calls", 0);
                const max_children = try optionalUsize(definition, "max_children", 0);
                if (max_steps == 0 or max_steps > 4096 or max_tool_calls > 4096 or max_children > 64) return Error.InvalidConfig;
            }
        }
    }
    if (try validatedObjectField(root, "context")) |value| {
        const keys = &.{
            "auto_compaction",
            "manual_compaction",
            "context_window_tokens",
            "prompt_budget_tokens",
            "compact_at_ratio_milli",
            "reserve_output_tokens",
            "keep_recent_messages",
            "max_entries_per_checkpoint",
            "aggressiveness_milli",
            "retry_on_provider_overflow",
        };
        try rejectUnknownKeys(value, &.{
            "_help",
            "auto_compaction",
            "manual_compaction",
            "context_window_tokens",
            "prompt_budget_tokens",
            "compact_at_ratio_milli",
            "reserve_output_tokens",
            "keep_recent_messages",
            "max_entries_per_checkpoint",
            "aggressiveness_milli",
            "retry_on_provider_overflow",
        });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "prompts")) |value| {
        const keys = &.{ "system_prompt_file", "developer_prompt_file", "persona", "guardrails", "user_context" };
        try rejectUnknownKeys(value, &.{ "_help", "system_prompt_file", "developer_prompt_file", "persona", "guardrails", "user_context" });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "draft")) |value| {
        const keys = &.{ "enabled", "model", "provider_id", "effort", "temperature" };
        try rejectUnknownKeys(value, &.{ "_help", "enabled", "model", "provider_id", "effort", "temperature" });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "buffer")) |value| {
        const keys = &.{ "enabled", "model", "provider_id", "effort", "temperature", "interval_ms" };
        try rejectUnknownKeys(value, &.{ "_help", "enabled", "model", "provider_id", "effort", "temperature", "interval_ms" });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "memory")) |value| {
        const keys = &.{ "enabled", "agent_writes_enabled", "max_entry_bytes", "max_session_context_bytes", "max_global_context_bytes", "max_context_entries" };
        try rejectUnknownKeys(value, &.{ "_help", "enabled", "agent_writes_enabled", "max_entry_bytes", "max_session_context_bytes", "max_global_context_bytes", "max_context_entries" });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "environment")) |value| {
        const keys = &.{ "VANTARI_WORKSPACE", "MAX_STEPS", "MAX_TOOL_CALLS_PER_TURN", "MAX_TOOL_CALLS_PER_SESSION" };
        try rejectUnknownKeys(value, &.{ "_help", "VANTARI_WORKSPACE", "MAX_STEPS", "MAX_TOOL_CALLS_PER_TURN", "MAX_TOOL_CALLS_PER_SESSION" });
        try validateHelp(value, keys);
    }
}

/// Distinguish an absent optional section from a present section with the
/// wrong JSON type so malformed policy cannot silently collapse to defaults.
fn validatedObjectField(root: std.json.ObjectMap, key: []const u8) !?std.json.ObjectMap {
    const value = root.get(key) orelse return null;
    if (value != .object) return Error.InvalidConfig;
    return value.object;
}

/// Validate human-facing metadata without allowing it to become a second
/// configuration surface. Help entries are additive metadata: an older
/// config may omit the explanation for a newer known key, but it may not add
/// undocumented help keys or malformed explanations. The canonical template
/// supplies the fallback text for settings consumers.
fn validateHelp(owner: std.json.ObjectMap, configurable_keys: []const []const u8) !void {
    const help_value = owner.get("_help") orelse return;
    if (help_value != .object) return Error.InvalidConfig;
    try rejectUnknownKeys(help_value.object, configurable_keys);
    for (configurable_keys) |key| {
        if (owner.get(key) == null) continue;
        const explanation = help_value.object.get(key) orelse continue;
        if (explanation != .string or std.mem.trim(u8, explanation.string, " \t\r\n").len == 0) return Error.InvalidConfig;
    }
}

/// `_about` documents ownership and precedence only; it cannot carry values
/// consumed by the runtime.
fn validateAbout(root: std.json.ObjectMap) !void {
    const about = root.get("_about") orelse return;
    if (about != .array or about.array.items.len == 0) return Error.InvalidConfig;
    for (about.array.items) |entry| {
        if (entry != .string or std.mem.trim(u8, entry.string, " \t\r\n").len == 0) return Error.InvalidConfig;
    }
}

fn rejectUnknownKeys(object: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var recognized = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                recognized = true;
                break;
            }
        }
        if (!recognized) return Error.InvalidConfig;
    }
}

fn stripUtf8Bom(content: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, content, bom)) return content[bom.len..];
    return content;
}

fn objectField(root: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = root.get(key) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn optionalStringClone(allocator: std.mem.Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return Error.InvalidConfig;
    return try allocator.dupe(u8, value.string);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value != .bool) return Error.InvalidConfig;
    return value.bool;
}

fn optionalUsize(object: std.json.ObjectMap, key: []const u8, default: usize) !usize {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value != .integer or value.integer < 0) return Error.InvalidConfig;
    return std.math.cast(usize, value.integer) orelse Error.InvalidConfig;
}

fn optionalU64(object: std.json.ObjectMap, key: []const u8, default: u64) !u64 {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value != .integer or value.integer < 0) return Error.InvalidConfig;
    return std.math.cast(u64, value.integer) orelse Error.InvalidConfig;
}

fn optionalFloat(object: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value == .float) return value.float;
    if (value == .integer) return @floatFromInt(value.integer);
    return Error.InvalidConfig;
}

fn validateAgentRoute(route: std.json.ObjectMap) !void {
    for (&[_][]const u8{ "provider_id", "model", "thinking_mode", "effort" }) |key| {
        const value = route.get(key) orelse continue;
        if (value == .null) continue;
        if (value != .string or std.mem.trim(u8, value.string, " \t\r\n").len == 0) return Error.InvalidConfig;
    }
    if (route.get("wire_api")) |value| {
        if (value != .null and (value != .string or types.WireApi.fromString(value.string) == null)) return Error.InvalidConfig;
    }
    const context_window = try optionalOptionalU64(route, "context_window_tokens");
    const output_reserve = try optionalOptionalU64(route, "reserve_output_tokens");
    if (context_window != null and output_reserve != null and output_reserve.? >= context_window.?) return Error.InvalidConfig;
}

fn validateOptionalAgentString(object: std.json.ObjectMap, key: []const u8, max_len: usize) !void {
    const value = object.get(key) orelse return;
    if (value == .null) return;
    if (value != .string) return Error.InvalidConfig;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0 or value.string.len > max_len) return Error.InvalidConfig;
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

fn optionalOptionalU64(object: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .integer or value.integer <= 0) return Error.InvalidConfig;
    return std.math.cast(u64, value.integer) orelse Error.InvalidConfig;
}

fn isKnownAgentRouteRole(value: []const u8) bool {
    const roles = [_][]const u8{
        "general",
        "recon",
        "planning",
        "compaction",
        "implementation",
        "review",
        "validation",
    };
    for (roles) |role| {
        if (std.mem.eql(u8, role, value)) return true;
    }
    return false;
}

fn isKnownPromptMode(value: []const u8) bool {
    return std.mem.eql(u8, value, "orchestrate") or
        std.mem.eql(u8, value, "build") or
        std.mem.eql(u8, value, "align") or
        std.mem.eql(u8, value, "plan");
}

/// Autonomy vocabulary is closed (mirrors spec.zig): directed / bounded /
/// self_directed. Anything else is a schema violation, not a fallback.
fn isValidAutonomyValue(value: []const u8) bool {
    return std.mem.eql(u8, value, "directed") or
        std.mem.eql(u8, value, "bounded") or
        std.mem.eql(u8, value, "self_directed");
}

fn optionalU16(object: std.json.ObjectMap, key: []const u8, default: u16) !u16 {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value != .integer or value.integer < 0) return Error.InvalidConfig;
    return std.math.cast(u16, value.integer) orelse Error.InvalidConfig;
}

fn applyEnvironmentObject(allocator: std.mem.Allocator, result: *RuntimePolicy, environment: std.json.ObjectMap) !void {
    if (try optionalStringClone(allocator, environment, "VANTARI_WORKSPACE")) |value| {
        if (result.workspace) |old| allocator.free(old);
        result.workspace = value;
    }
    result.max_steps = try optionalEnvUsize(environment, "MAX_STEPS", result.max_steps);
    result.max_tool_calls_per_turn = try optionalEnvUsize(environment, "MAX_TOOL_CALLS_PER_TURN", result.max_tool_calls_per_turn);
    result.max_tool_calls_per_session = try optionalEnvUsize(environment, "MAX_TOOL_CALLS_PER_SESSION", result.max_tool_calls_per_session);
}

fn optionalEnvUsize(object: std.json.ObjectMap, key: []const u8, default: usize) !usize {
    const value = object.get(key) orelse return default;
    if (value == .null) return default;
    if (value == .integer) {
        if (value.integer < 0) return Error.InvalidConfig;
        return std.math.cast(usize, value.integer) orelse Error.InvalidConfig;
    }
    if (value != .string) return Error.InvalidConfig;
    return std.fmt.parseUnsigned(usize, value.string, 10) catch Error.InvalidConfig;
}

fn applyProcessEnvironment(allocator: std.mem.Allocator, result: *RuntimePolicy) !void {
    if (std.process.getEnvVarOwned(allocator, "VANTARI_WORKSPACE")) |value| {
        if (result.workspace) |old| allocator.free(old);
        result.workspace = value;
    } else |_| {}
    result.max_steps = try processEnvUsize(allocator, "MAX_STEPS", result.max_steps);
    result.max_tool_calls_per_turn = try processEnvUsize(allocator, "MAX_TOOL_CALLS_PER_TURN", result.max_tool_calls_per_turn);
    result.max_tool_calls_per_session = try processEnvUsize(allocator, "MAX_TOOL_CALLS_PER_SESSION", result.max_tool_calls_per_session);
}

fn processEnvUsize(allocator: std.mem.Allocator, key: []const u8, default: usize) !usize {
    const value = std.process.getEnvVarOwned(allocator, key) catch return default;
    defer allocator.free(value);
    return std.fmt.parseUnsigned(usize, value, 10) catch Error.InvalidConfig;
}

fn clonePromptPolicy(allocator: std.mem.Allocator, defaults: types.PromptPolicy) !types.PromptPolicy {
    return .{
        .system_prompt_file = if (defaults.system_prompt_file) |value| try allocator.dupe(u8, value) else null,
        .developer_prompt_file = if (defaults.developer_prompt_file) |value| try allocator.dupe(u8, value) else null,
        .persona = if (defaults.persona) |value| try allocator.dupe(u8, value) else null,
        .guardrails = if (defaults.guardrails) |value| try allocator.dupe(u8, value) else null,
        .user_context = if (defaults.user_context) |value| try allocator.dupe(u8, value) else null,
    };
}

test "default config documents every persistent value" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, default_document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);

    const sections = [_][]const u8{ "runtime", "tui", "provider", "agent_routes", "agents", "context", "prompts", "memory", "environment" };
    for (&sections) |section_name| {
        const section = objectField(parsed.value.object, section_name).?;
        const help = objectField(section, "_help").?;
        var iterator = section.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "_help")) continue;
            try std.testing.expect(help.get(entry.key_ptr.*) != null);
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, default_document, "VANTARI_HOME is intentionally not configurable here") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_document, "belong in the sibling auth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_document, "orchestrator_only") == null);
}

test "legacy orchestrator config is accepted but has no runtime owner" {
    const document =
        \\{"version":1,"agents":{"_help":{"orchestrator_only":"Legacy ignored setting."},"orchestrator_only":false,"definitions":{}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);
}

test "ticket execution policy is not a config surface" {
    const document =
        \\{"version":1,"tickets":{"auto_assign":true,"proactive_workpool":true,"close_authority":"kernel","reopen_with_reasoning":true}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed.value.object));

    const capacity_document =
        \\{"version":1,"agent_routes":{"max_concurrency":3}}
    ;
    var capacity_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, capacity_document, .{});
    defer capacity_parsed.deinit();
    try validateDocumentShape(capacity_parsed.value.object);
}

test "config file is created beside runtime state and loads typed defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var policy = try loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4096), policy.max_steps);
    try std.testing.expectEqual(@as(usize, 16), policy.max_tool_calls_per_turn);
    try std.testing.expect(!policy.full_access_mode);
    try std.testing.expectEqual(types.LogLevel.silent, policy.log_level);

    const config_path = try path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try std.testing.expect(fsutil.fileExists(config_path));
    try std.testing.expect(std.mem.endsWith(u8, config_path, ".var\\config.json") or std.mem.endsWith(u8, config_path, ".var/config.json"));
}

test "config set persists a typed boolean through the canonical file owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    const config_path = try ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try writeConfigKey(std.testing.allocator, workspace, "runtime", "full_access_mode", .{ .bool = true });

    var policy = try loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expect(policy.full_access_mode);
}

test "config environment values override runtime defaults and wire api is typed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try fsutil.writeText(config_path,
        \\{"version":1,
        \\ "runtime":{"max_steps":100,"max_tool_calls_per_turn":4,"max_tool_calls_per_session":20,"full_access_mode":true},
        \\ "provider":{"wire_api":"responses"},
        \\ "environment":{"MAX_STEPS":"250"}}
    );

    var policy = try loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 250), policy.max_steps);
    try std.testing.expectEqual(@as(usize, 4), policy.max_tool_calls_per_turn);
    try std.testing.expect(policy.full_access_mode);
    try std.testing.expectEqual(types.WireApi.responses, (try loadWireApi(std.testing.allocator, workspace)).?);
}

test "comment metadata cannot drift from configurable values" {
    const document =
        \\{"version":1,"runtime":{"_help":{"max_steps":""},"max_steps":2}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed.value.object));
}

test "new config values remain valid when older help metadata omits them" {
    const document =
        \\{"version":1,"runtime":{"_help":{"max_steps":"Maximum steps."},"max_steps":2,"full_access_mode":true}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);
}

test "runtime log level accepts the three canonical postures and rejects noise" {
    const valid = [_][]const u8{ "silent", "normal", "full" };
    for (valid) |value| {
        const document = try std.fmt.allocPrint(std.testing.allocator, "{{\"version\":1,\"runtime\":{{\"log_level\":\"{s}\"}}}}", .{value});
        defer std.testing.allocator.free(document);
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
        defer parsed.deinit();
        try validateDocumentShape(parsed.value.object);
    }

    const invalid =
        \\{"version":1,"runtime":{"log_level":"verbose"}}
    ;
    var parsed_invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid, .{});
    defer parsed_invalid.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed_invalid.value.object));
}

test "tui policy validates, loads, and rejects invented values" {
    const document =
        \\{"version":1,"tui":{"theme":"midnight","status_bar_position":"top"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try fsutil.writeText(config_path, document);

    const policy = try loadTuiPolicy(std.testing.allocator, workspace);
    try std.testing.expectEqual(TuiTheme.midnight, policy.theme);
    try std.testing.expectEqual(StatusBarPosition.top, policy.status_bar_position);

    const invalid =
        \\{"version":1,"tui":{"theme":"neon"}}
    ;
    var parsed_invalid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid, .{});
    defer parsed_invalid.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed_invalid.value.object));
}

test "prompt mode route overrides validate and load through the shared route shape" {
    const document =
        \\{"version":1,"agent_routes":{"prompt_modes":{"build":{"provider_id":"anthropic","model":"claude-sonnet"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try ensure(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try fsutil.writeText(config_path, document);

    var override = try loadPromptModeOverride(std.testing.allocator, workspace, "build");
    defer override.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("anthropic", override.provider_id.?);
    try std.testing.expectEqualStrings("claude-sonnet", override.model.?);
}

test "prompt mode route overrides reject invented mode ids" {
    const document =
        \\{"version":1,"agent_routes":{"prompt_modes":{"turbo":{"model":"fast"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed.value.object));
}

test "wire api auto is a valid provider floor value" {
    const document =
        \\{"version":1,"provider":{"wire_api":"auto"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);
    const provider_value = objectField(parsed.value.object, "provider").?;
    try std.testing.expectEqual(types.WireApi.auto, types.WireApi.fromString(provider_value.get("wire_api").?.string).?);
}

test "wire api auto validates inside agent route overrides" {
    const document =
        \\{"version":1,"agent_routes":{"roles":{"recon":{"wire_api":"auto"}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);
}

test "wire api rejects invented values at every validation path" {
    const document =
        \\{"version":1,"provider":{"wire_api":"telepathy"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(parsed.value.object));
}

test "agent routes remap providers but cannot redefine specialist capability" {
    const forbidden =
        \\{"version":1,"agent_routes":{"roles":{"recon":{"capability_profile_id":"root"}}}}
    ;
    var forbidden_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, forbidden, .{});
    defer forbidden_parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(forbidden_parsed.value.object));

    const invalid_budget =
        \\{"version":1,"agent_routes":{"roles":{"recon":{"context_window_tokens":100,"reserve_output_tokens":100}}}}
    ;
    var budget_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, invalid_budget, .{});
    defer budget_parsed.deinit();
    try std.testing.expectError(Error.InvalidConfig, validateDocumentShape(budget_parsed.value.object));
}
