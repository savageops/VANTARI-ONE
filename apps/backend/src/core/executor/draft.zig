/// Draft compilation module — when draft.enabled is true, a lightweight model
/// (e.g. glm-5-turbo) restructures the user's raw input into a compiled prompt
/// before the heavyweight model's first turn. Root sessions only.
///
/// The draft call is synchronous and non-streaming (empty hooks). Failures
/// fall back gracefully — runDraft returns null and the heavyweight uses the
/// raw prompt unchanged.
const std = @import("std");

const auth_store = @import("../auth/store.zig");
const config_file = @import("../config/file.zig");
const dispatch = @import("../providers/dispatch.zig");
const provider = @import("../providers/openai_compatible.zig");
const types = @import("../../shared/types.zig");

pub const DraftPolicy = struct {
    enabled: bool = false,
    model: ?[]u8 = null,
    provider_id: ?[]u8 = null,
    effort: ?[]u8 = null,
    temperature: ?f64 = null,

    pub fn deinit(self: DraftPolicy, allocator: std.mem.Allocator) void {
        if (self.model) |value| allocator.free(value);
        if (self.provider_id) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
    }
};

const draft_compilation_prompt =
    \\You are a prompt compiler. Restructure the user's input into a clear, structured prompt for a heavyweight coding agent. Extract intent, scope, and any implied context pointers. Keep the original meaning — do not add assumptions. Output only the compiled prompt, no meta-commentary.
;

/// Load draft policy from the config.json draft section. Returns a default
/// (disabled) policy if the section is absent or cannot be read.
pub fn loadDraftPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) DraftPolicy {
    var parsed = config_file.readValidatedDocument(allocator, workspace_root) catch return .{};
    defer parsed.deinit();

    const root = parsed.value.object;
    const draft = root.get("draft") orelse return .{};
    if (draft != .object) return .{};
    const obj = draft.object;

    var policy = DraftPolicy{};
    policy.enabled = if (obj.get("enabled")) |v| (v == .bool and v.bool) else false;
    if (obj.get("model")) |v| {
        if (v == .string and v.string.len > 0) policy.model = allocator.dupe(u8, v.string) catch null;
    }
    if (obj.get("provider_id")) |v| {
        if (v == .string and v.string.len > 0) policy.provider_id = allocator.dupe(u8, v.string) catch null;
    }
    if (obj.get("effort")) |v| {
        if (v == .string and v.string.len > 0) policy.effort = allocator.dupe(u8, v.string) catch null;
    }
    if (obj.get("temperature")) |v| {
        if (v == .float) policy.temperature = v.float;
        if (v == .integer) policy.temperature = @floatFromInt(v.integer);
    }
    return policy;
}

/// Run the draft model on the user's prompt and return the compiled result.
/// Returns null on any failure — the caller falls back to the raw prompt.
/// Never returns an error — draft failures must not block the heavyweight.
pub fn runDraft(
    allocator: std.mem.Allocator,
    parent_config: types.Config,
    policy: DraftPolicy,
    user_prompt: []const u8,
    transport: provider.Transport,
) ?[]u8 {
    if (!policy.enabled) return null;
    if (policy.model == null) return null;
    if (user_prompt.len == 0) return null;

    // Resolve credentials: use the draft provider_id if set, otherwise
    // clone from the parent config (same provider, different model).
    var draft_config = buildDraftConfig(allocator, parent_config, policy) catch return null;
    defer draft_config.deinit(allocator);

    const system_msg = types.ChatMessage{
        .role = .system,
        .content = @constCast(draft_compilation_prompt),
    };
    const user_msg = types.ChatMessage{
        .role = .user,
        .content = @constCast(user_prompt),
    };
    const messages = [_]types.ChatMessage{ system_msg, user_msg };

    var completion = dispatch.completeWithTransportAndHooks(
        allocator,
        draft_config,
        .{ .messages = messages[0..], .tool_definitions = &.{} },
        transport,
        .{}, // no hooks → non-streaming, full response
    ) catch return null;
    defer completion.deinit(allocator);

    const content = completion.content orelse return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Don't use the draft output if it's suspiciously short or just echoes the input.
    if (trimmed.len < 10) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

fn buildDraftConfig(
    allocator: std.mem.Allocator,
    parent: types.Config,
    policy: DraftPolicy,
) !types.Config {
    // If provider_id is set, resolve from auth.json. Otherwise clone parent.
    if (policy.provider_id) |pid| {
        var resolved = auth_store.readProviderById(allocator, parent.workspace_root, pid) catch return buildFromParent(allocator, parent, policy);
        defer resolved.deinit(allocator);

        return types.Config{
            .openai_base_url = try allocator.dupe(u8, resolved.base_url),
            .openai_api_key = try allocator.dupe(u8, resolved.api_key),
            .openai_model = try allocator.dupe(u8, policy.model.?),
            .max_steps = 1,
            .max_tool_calls_per_turn = 0,
            .max_tool_calls_per_session = 0,
            .workspace_root = try allocator.dupe(u8, parent.workspace_root),
            .full_access_mode = parent.full_access_mode,
            .wire_api = parent.wire_api,
            .effort = if (policy.effort) |e| e else parent.effort,
            .temperature = if (policy.temperature) |t| t else parent.temperature,
        };
    }
    return buildFromParent(allocator, parent, policy);
}

fn buildFromParent(
    allocator: std.mem.Allocator,
    parent: types.Config,
    policy: DraftPolicy,
) !types.Config {
    return types.Config{
        .openai_base_url = try allocator.dupe(u8, parent.openai_base_url),
        .openai_api_key = try allocator.dupe(u8, parent.openai_api_key),
        .openai_model = try allocator.dupe(u8, policy.model.?),
        .max_steps = 1,
        .max_tool_calls_per_turn = 0,
        .max_tool_calls_per_session = 0,
        .workspace_root = try allocator.dupe(u8, parent.workspace_root),
        .full_access_mode = parent.full_access_mode,
        .wire_api = parent.wire_api,
        .effort = if (policy.effort) |e| e else parent.effort,
        .temperature = if (policy.temperature) |t| t else parent.temperature,
    };
}
