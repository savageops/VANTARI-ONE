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

    pub fn deinit(self: RuntimePolicy, allocator: std.mem.Allocator) void {
        if (self.workspace) |value| allocator.free(value);
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

pub fn loadWireApi(allocator: std.mem.Allocator, workspace_root: []const u8) !?types.WireApi {
    var parsed = try parseDocument(allocator, workspace_root);
    defer parsed.deinit();
    const provider = objectField(parsed.value.object, "provider") orelse return null;
    const value = provider.get("wire_api") orelse return null;
    if (value != .string) return Error.InvalidConfig;
    return types.WireApi.fromString(value.string) orelse Error.InvalidConfig;
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
    policy.compact_at_ratio_milli = try optionalU16(context, "compact_at_ratio_milli", policy.compact_at_ratio_milli);
    policy.reserve_output_tokens = try optionalU64(context, "reserve_output_tokens", policy.reserve_output_tokens);
    policy.keep_recent_messages = try optionalUsize(context, "keep_recent_messages", policy.keep_recent_messages);
    policy.max_entries_per_checkpoint = try optionalUsize(context, "max_entries_per_checkpoint", policy.max_entries_per_checkpoint);
    policy.aggressiveness_milli = try optionalU16(context, "aggressiveness_milli", policy.aggressiveness_milli);
    policy.retry_on_provider_overflow = try optionalBool(context, "retry_on_provider_overflow", policy.retry_on_provider_overflow);

    if (policy.context_window_tokens == 0 or
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

fn parseDocument(allocator: std.mem.Allocator, workspace_root: []const u8) !std.json.Parsed(std.json.Value) {
    const config_path = try ensure(allocator, workspace_root);
    defer allocator.free(config_path);
    const content = try fsutil.readTextAlloc(allocator, config_path);
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripUtf8Bom(content), .{}) catch return Error.InvalidConfig;
    errdefer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidConfig;
    const version = parsed.value.object.get("version") orelse return Error.InvalidConfig;
    if (version != .integer or version.integer != 1) return Error.UnsupportedVersion;
    try validateDocumentShape(parsed.value.object);
    return parsed;
}

fn validateDocumentShape(root: std.json.ObjectMap) !void {
    try rejectUnknownKeys(root, &.{ "_about", "_help", "version", "runtime", "provider", "context", "prompts", "memory", "environment" });
    try validateAbout(root);
    try validateHelp(root, &.{"version"});
    if (try validatedObjectField(root, "runtime")) |value| {
        const keys = &.{ "workspace", "max_steps", "max_tool_calls_per_turn", "max_tool_calls_per_session" };
        try rejectUnknownKeys(value, &.{ "_help", "workspace", "max_steps", "max_tool_calls_per_turn", "max_tool_calls_per_session" });
        try validateHelp(value, keys);
    }
    if (try validatedObjectField(root, "provider")) |value| {
        try rejectUnknownKeys(value, &.{ "_help", "wire_api" });
        try validateHelp(value, &.{"wire_api"});
    }
    if (try validatedObjectField(root, "context")) |value| {
        const keys = &.{
            "auto_compaction",
            "manual_compaction",
            "context_window_tokens",
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
        const keys = &.{ "system_prompt_file", "developer_prompt_file" };
        try rejectUnknownKeys(value, &.{ "_help", "system_prompt_file", "developer_prompt_file" });
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
/// configuration surface. When `_help` is present, every sibling value must
/// have one non-empty explanation and no undocumented help keys may drift in.
fn validateHelp(owner: std.json.ObjectMap, configurable_keys: []const []const u8) !void {
    const help_value = owner.get("_help") orelse return;
    if (help_value != .object) return Error.InvalidConfig;
    try rejectUnknownKeys(help_value.object, configurable_keys);
    for (configurable_keys) |key| {
        if (owner.get(key) == null) continue;
        const explanation = help_value.object.get(key) orelse return Error.InvalidConfig;
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
    };
}

test "default config documents every persistent value" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, default_document, .{});
    defer parsed.deinit();
    try validateDocumentShape(parsed.value.object);

    const sections = [_][]const u8{ "runtime", "provider", "context", "prompts", "memory", "environment" };
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
}

test "config file is created beside runtime state and loads typed defaults" {
    if (std.process.hasEnvVarConstant("VANTARI_HOME")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var policy = try loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4096), policy.max_steps);
    try std.testing.expectEqual(@as(usize, 16), policy.max_tool_calls_per_turn);

    const config_path = try path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try std.testing.expect(fsutil.fileExists(config_path));
    try std.testing.expect(std.mem.endsWith(u8, config_path, ".var\\config.json") or std.mem.endsWith(u8, config_path, ".var/config.json"));
}

test "config environment values override runtime defaults and wire api is typed" {
    if (std.process.hasEnvVarConstant("VANTARI_HOME")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try fsutil.writeText(config_path,
        \\{"version":1,
        \\ "runtime":{"max_steps":100,"max_tool_calls_per_turn":4,"max_tool_calls_per_session":20},
        \\ "provider":{"wire_api":"responses"},
        \\ "environment":{"MAX_STEPS":"250"}}
    );

    var policy = try loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 250), policy.max_steps);
    try std.testing.expectEqual(@as(usize, 4), policy.max_tool_calls_per_turn);
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
