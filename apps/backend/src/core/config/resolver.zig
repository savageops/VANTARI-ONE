const std = @import("std");
const auth_resolver = @import("../auth/resolver.zig");
const config_file = @import("file.zig");
const fsutil = @import("../../shared/fsutil.zig");
const models = @import("../providers/models.zig");
const provider = @import("../providers/openai_compatible.zig");
const settings = @import("settings.zig");
const types = @import("../../shared/types.zig");

pub const local_settings = settings;
pub const default_max_steps: usize = 4096;

pub const Error = error{
    MissingKey,
    InvalidValue,
};

pub fn loadFromEnvFile(allocator: std.mem.Allocator, env_path: []const u8) !types.Config {
    const content = try std.fs.cwd().readFileAlloc(allocator, env_path, 1024 * 1024);
    defer allocator.free(content);

    var openai_base_url: ?[]u8 = null;
    var openai_api_key: ?[]u8 = null;
    var openai_model: ?[]u8 = null;
    var workspace_root: ?[]u8 = null;
    var max_steps: usize = default_max_steps;
    var max_tool_calls_per_turn: usize = 16;
    var max_tool_calls_per_session: usize = 96;

    errdefer if (openai_base_url) |value| allocator.free(value);
    errdefer if (openai_api_key) |value| allocator.free(value);
    errdefer if (openai_model) |value| allocator.free(value);
    errdefer if (workspace_root) |value| allocator.free(value);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        var value = std.mem.trim(u8, line[separator_index + 1 ..], " \t");
        value = trimQuotes(value);

        if (std.mem.eql(u8, key, "BASE_URL")) {
            openai_base_url = try dupeReplacing(allocator, openai_base_url, value);
        } else if (std.mem.eql(u8, key, "API_KEY")) {
            openai_api_key = try dupeReplacing(allocator, openai_api_key, value);
        } else if (std.mem.eql(u8, key, "MODEL")) {
            openai_model = try dupeReplacing(allocator, openai_model, value);
        } else if (std.mem.eql(u8, key, "WORKSPACE")) {
            workspace_root = try dupeReplacing(allocator, workspace_root, value);
        } else if (std.mem.eql(u8, key, "MAX_STEPS")) {
            max_steps = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidValue;
        } else if (std.mem.eql(u8, key, "MAX_TOOL_CALLS_PER_TURN")) {
            max_tool_calls_per_turn = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidValue;
        } else if (std.mem.eql(u8, key, "MAX_TOOL_CALLS_PER_SESSION")) {
            max_tool_calls_per_session = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidValue;
        }
    }

    const resolved_base_url = openai_base_url orelse return Error.MissingKey;
    const resolved_api_key = openai_api_key orelse return Error.MissingKey;
    const resolved_model = openai_model orelse return Error.MissingKey;
    const provider_id = inferProviderId(resolved_base_url, resolved_model);

    return .{
        .openai_base_url = resolved_base_url,
        .openai_api_key = resolved_api_key,
        .openai_model = resolved_model,
        .auth_provider = try allocator.dupe(u8, provider_id),
        .subscription_plan_label = if (isZaiProvider(provider_id)) try allocator.dupe(u8, resolved_model) else null,
        .subscription_status = if (isZaiProvider(provider_id)) try allocator.dupe(u8, "active") else null,
        .max_steps = max_steps,
        .max_tool_calls_per_turn = max_tool_calls_per_turn,
        .max_tool_calls_per_session = max_tool_calls_per_session,
        .workspace_root = workspace_root orelse try allocator.dupe(u8, "."),
    };
}

pub fn loadDefault(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    return loadDefaultWithOptions(allocator, workspace_root, .{});
}

/// Compile configuration inside an explicitly selected workspace. Provider and
/// runtime settings still load normally, but WORKSPACE/VANTARI_WORKSPACE cannot
/// redirect state after the caller has selected the owner boundary.
pub fn loadDefaultForExplicitWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    return loadDefaultWithOptions(allocator, workspace_root, .{ .allow_workspace_override = false });
}

const LoadOptions = struct {
    allow_workspace_override: bool = true,
};

fn loadDefaultWithOptions(allocator: std.mem.Allocator, workspace_root: []const u8, options: LoadOptions) !types.Config {
    const env_path = try std.fs.path.join(allocator, &.{ workspace_root, ".env" });
    defer allocator.free(env_path);

    var config = loadFromEnvFile(allocator, env_path) catch |err| switch (err) {
        error.FileNotFound, Error.MissingKey => try loadDefaultFromAuthOnly(allocator, workspace_root, options),
        else => return err,
    };
    errdefer config.deinit(allocator);

    var runtime_policy = try config_file.loadRuntimePolicy(allocator, workspace_root);
    defer runtime_policy.deinit(allocator);
    try applyRuntimePolicy(allocator, &config, runtime_policy, options.allow_workspace_override);

    const canonical_workspace_root = try canonicalizeWorkspaceRoot(
        allocator,
        workspace_root,
        if (options.allow_workspace_override) config.workspace_root else ".",
    );
    allocator.free(config.workspace_root);
    config.workspace_root = canonical_workspace_root;

    var resolved_auth = try auth_resolver.resolveProviderAuth(allocator, config.workspace_root, .{
        .provider_id = config.auth_provider orelse inferProviderId(config.openai_base_url, config.openai_model),
        .base_url = config.openai_base_url,
        .api_key = config.openai_api_key,
        .model = config.openai_model,
        .subscription_plan_id = if (isZaiProvider(config.auth_provider orelse "")) "zai-coding-plan" else null,
        .subscription_plan_label = config.subscription_plan_label,
        .subscription_status = config.subscription_status,
        .subscription_source = "manual",
    });
    defer resolved_auth.deinit(allocator);

    try applyResolvedAuth(allocator, &config, resolved_auth);
    config.context_policy = try settings.loadContextPolicy(allocator, config.workspace_root, config.context_policy);
    config.prompt_policy = try settings.loadPromptPolicy(allocator, config.workspace_root, config.prompt_policy);
    config.memory_policy = try config_file.loadMemoryPolicy(allocator, config.workspace_root, config.memory_policy);
    config.wire_api = (try config_file.loadWireApi(allocator, config.workspace_root)) orelse config.wire_api;
    try applyLocalContextDetection(allocator, &config);
    return config;
}

fn loadDefaultFromAuthOnly(allocator: std.mem.Allocator, workspace_root: []const u8, options: LoadOptions) !types.Config {
    const canonical_workspace_root = try canonicalizeWorkspaceRoot(allocator, workspace_root, ".");
    var root_owned = true;
    errdefer if (root_owned) allocator.free(canonical_workspace_root);

    var resolved_auth = try auth_resolver.resolveProviderAuth(allocator, canonical_workspace_root, null);
    defer resolved_auth.deinit(allocator);

    var config = types.Config{
        .openai_base_url = try allocator.dupe(u8, resolved_auth.base_url),
        .openai_api_key = try allocator.dupe(u8, resolved_auth.api_key),
        .openai_model = try allocator.dupe(u8, resolved_auth.model),
        .auth_provider = try allocator.dupe(u8, resolved_auth.provider_id),
        .subscription_plan_label = if (resolved_auth.subscription_plan_label) |value| try allocator.dupe(u8, value) else null,
        .subscription_status = if (resolved_auth.subscription_status) |value| try allocator.dupe(u8, value) else null,
        .max_steps = default_max_steps,
        .workspace_root = canonical_workspace_root,
    };
    root_owned = false;
    errdefer config.deinit(allocator);

    var runtime_policy = try config_file.loadRuntimePolicy(allocator, workspace_root);
    defer runtime_policy.deinit(allocator);
    try applyRuntimePolicy(allocator, &config, runtime_policy, options.allow_workspace_override);

    if (options.allow_workspace_override) if (runtime_policy.workspace) |configured_workspace| {
        const canonical_workspace = try canonicalizeWorkspaceRoot(allocator, workspace_root, configured_workspace);
        allocator.free(config.workspace_root);
        config.workspace_root = canonical_workspace;
    };

    config.context_policy = try settings.loadContextPolicy(allocator, config.workspace_root, config.context_policy);
    config.prompt_policy = try settings.loadPromptPolicy(allocator, config.workspace_root, config.prompt_policy);
    config.memory_policy = try config_file.loadMemoryPolicy(allocator, config.workspace_root, config.memory_policy);
    config.wire_api = (try config_file.loadWireApi(allocator, config.workspace_root)) orelse config.wire_api;
    try applyLocalContextDetection(allocator, &config);
    return config;
}

/// Apply non-secret runtime limits from config.json. Workspace is canonicalized
/// by the caller because it depends on the invocation root.
fn applyRuntimePolicy(
    allocator: std.mem.Allocator,
    config: *types.Config,
    policy: config_file.RuntimePolicy,
    allow_workspace_override: bool,
) !void {
    config.max_steps = policy.max_steps;
    config.max_tool_calls_per_turn = policy.max_tool_calls_per_turn;
    config.max_tool_calls_per_session = policy.max_tool_calls_per_session;
    config.full_access_mode = policy.full_access_mode;
    if (allow_workspace_override) if (policy.workspace) |workspace| {
        const replacement = try allocator.dupe(u8, workspace);
        allocator.free(config.workspace_root);
        config.workspace_root = replacement;
    };
    if (policy.effort) |effort| {
        const owned = try allocator.dupe(u8, effort);
        if (config.effort_owned) |previous| allocator.free(previous);
        config.effort_owned = owned;
        config.effort = owned;
    }
    if (policy.temperature) |temp| {
        config.temperature = temp;
    }
}

/// Proactively detect the context window for local OpenAI-compatible servers
/// (LM Studio, llama.cpp, vLLM, Ollama). Remote providers keep their
/// configured/default window — probing them adds latency and is unreliable.
///
/// Precedence: explicit config.json `context.context_window_tokens` always wins.
/// When config.json leaves the field null, and the provider is
/// local, we probe GET /v1/models to recover the runtime context length for
/// the configured model. This prevents late compaction on small local models
/// whose default 128K assumption is wrong.
fn applyLocalContextDetection(allocator: std.mem.Allocator, config: *types.Config) !void {
    if (!provider.isLocalHostUrl(config.openai_base_url)) return;
    if (settingsHasExplicitContextWindow(allocator, config.workspace_root)) return;

    var discovered = models.listModels(
        allocator,
        config.openai_base_url,
        config.openai_api_key,
        null,
        config.auth_provider orelse "local",
    ) catch return;
    defer discovered.deinit(allocator);

    const detected = models.detectContextWindowForModel(discovered, config.openai_model) orelse return;
    if (detected > 0) {
        config.context_policy.context_window_tokens = detected;
        std.log.info("config: auto-detected context window {d} for local model {s}", .{ detected, config.openai_model });
    }
}

/// Returns true when canonical config.json contains an explicit positive
/// context-window value.
fn settingsHasExplicitContextWindow(allocator: std.mem.Allocator, workspace_root: []const u8) bool {
    return config_file.hasExplicitContextWindow(allocator, workspace_root);
}

fn applyResolvedAuth(allocator: std.mem.Allocator, config: *types.Config, resolved_auth: auth_resolver.ResolvedAuth) !void {
    const next_base_url = try allocator.dupe(u8, resolved_auth.base_url);
    errdefer allocator.free(next_base_url);
    const next_api_key = try allocator.dupe(u8, resolved_auth.api_key);
    errdefer allocator.free(next_api_key);
    const next_model = try allocator.dupe(u8, resolved_auth.model);
    errdefer allocator.free(next_model);
    const next_auth_provider = try allocator.dupe(u8, resolved_auth.provider_id);
    errdefer allocator.free(next_auth_provider);
    const next_subscription_plan_label = if (resolved_auth.subscription_plan_label) |value| try allocator.dupe(u8, value) else null;
    errdefer if (next_subscription_plan_label) |value| allocator.free(value);
    const next_subscription_status = if (resolved_auth.subscription_status) |value| try allocator.dupe(u8, value) else null;
    errdefer if (next_subscription_status) |value| allocator.free(value);

    allocator.free(config.openai_base_url);
    allocator.free(config.openai_api_key);
    allocator.free(config.openai_model);
    if (config.auth_provider) |value| allocator.free(value);
    if (config.subscription_plan_label) |value| allocator.free(value);
    if (config.subscription_status) |value| allocator.free(value);

    config.openai_base_url = next_base_url;
    config.openai_api_key = next_api_key;
    config.openai_model = next_model;
    config.auth_provider = next_auth_provider;
    config.subscription_plan_label = next_subscription_plan_label;
    config.subscription_status = next_subscription_status;
}

fn canonicalizeWorkspaceRoot(
    allocator: std.mem.Allocator,
    invocation_root: []const u8,
    configured_root: []const u8,
) ![]u8 {
    const invocation_abs = try fsutil.resolveAbsolute(allocator, invocation_root);
    defer allocator.free(invocation_abs);

    const anchored_root = if (std.fs.path.isAbsolute(configured_root))
        try allocator.dupe(u8, configured_root)
    else
        try std.fs.path.resolve(allocator, &.{ invocation_abs, configured_root });
    defer allocator.free(anchored_root);

    return std.fs.realpathAlloc(allocator, anchored_root);
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn dupeReplacing(allocator: std.mem.Allocator, existing: ?[]u8, value: []const u8) ![]u8 {
    if (existing) |previous| allocator.free(previous);
    return allocator.dupe(u8, value);
}

fn inferProviderId(base_url: []const u8, model: []const u8) []const u8 {
    if (std.mem.indexOf(u8, base_url, "z.ai") != null) return "zai";
    if (std.mem.indexOf(u8, model, "GLM") != null or std.mem.indexOf(u8, model, "glm") != null) return "zai";
    return "openai-compatible";
}

fn isZaiProvider(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "zai");
}
