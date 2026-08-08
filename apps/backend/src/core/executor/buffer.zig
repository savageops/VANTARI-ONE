/// Buffer speculation service — a lightweight model (e.g. glm-5-turbo) runs
/// concurrently with the heavyweight model, producing navigation previews
/// (next steps, directions, insights) that populate the TUI reasoning dock
/// when idle and are injected as advisory context into the next turn.
///
/// Root sessions only. Failures are silent — never blocks the heavyweight.
/// Mirrors the scheduler service pattern (background thread + tick loop).
const std = @import("std");

const auth_store = @import("../auth/store.zig");
const config_file = @import("../config/file.zig");
const dispatch = @import("../providers/dispatch.zig");
const provider = @import("../providers/openai_compatible.zig");
const summaries = @import("../sessions/summaries.zig");
const types = @import("../../shared/types.zig");

pub const BufferPolicy = struct {
    enabled: bool = false,
    model: ?[]u8 = null,
    provider_id: ?[]u8 = null,
    effort: ?[]u8 = null,
    temperature: ?f64 = null,
    interval_ms: usize = 5000,

    pub fn deinit(self: BufferPolicy, allocator: std.mem.Allocator) void {
        if (self.model) |value| allocator.free(value);
        if (self.provider_id) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
    }
};

/// Callback invoked when the buffer model produces a preview. The callee
/// owns the preview slice and must free it.
pub const PreviewSink = struct {
    context: ?*anyopaque,
    onPreviewFn: *const fn (ctx: ?*anyopaque, preview: []const u8) void,
};

const buffer_prompt_template =
    \\You are a navigation preview engine for a coding agent orchestrator. You receive the user's original request plus the session's durable summary — the orchestrator's own record of the objective, key decisions, completed work, and open threads.
    \\
    \\Context format: the user's original request, followed by RECENT WORK STATE (the session summary from the durable summary ledger, maintained by the orchestrator before each turn ends).
    \\
    \\Output format (exactly these 3 lines, nothing else):
    \\NEXT_STEPS: <3 highest-value next actions based on the work state>
    \\DIRECTION: <where this is heading, one sentence>
    \\RISK: <one thing to watch for>
    \\
    \\Rules: Be specific to the actual work. Reference real files, tools, or tasks from the context. Never give generic advice. If the context is about agents, mention agents. If about files, mention files.
;

pub const Service = struct {
    allocator: std.mem.Allocator,
    parent_config: types.Config,
    transport: provider.Transport,
    sink: PreviewSink,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_tick_ms: i64 = 0,
    /// Set by the host when a root session is active; null when idle.
    active_prompt: ?[]const u8 = null,
    /// The active root session id — the buffer reads its durable summary row
    /// from the summary ledger each tick for work-state awareness.
    active_session_id: ?[]const u8 = null,
    /// Latest summary text read from the ledger (owned by the service).
    context_text: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        parent_config: types.Config,
        transport: provider.Transport,
        sink: PreviewSink,
    ) Service {
        return .{
            .allocator = allocator,
            .parent_config = parent_config,
            .transport = transport,
            .sink = sink,
        };
    }

    pub fn requestStop(self: *Service) void {
        self.stop_requested.store(true, .release);
    }

    pub fn setActivePrompt(self: *Service, prompt: ?[]const u8) void {
        self.active_prompt = prompt;
    }

    pub fn setSessionId(self: *Service, session_id: ?[]const u8) void {
        self.active_session_id = session_id;
    }

    pub fn run(self: *Service) void {
        while (!self.stop_requested.load(.acquire)) {
            self.tick() catch {};
            std.Thread.sleep(1000 * std.time.ns_per_ms); // 1s poll cadence
        }
    }

    fn tick(self: *Service) !void {
        const now_ms = std.time.milliTimestamp();
        const policy = loadBufferPolicy(self.allocator, self.parent_config.workspace_root);
        defer policy.deinit(self.allocator);

        if (!policy.enabled) return;
        if (self.active_prompt == null) return;
        if (now_ms - self.last_tick_ms < @as(i64, @intCast(policy.interval_ms))) return;

        self.last_tick_ms = now_ms;

        // Work-state context comes from the durable session summary ledger —
        // the orchestrator's mandatory pre-turn-end update — never a raw
        // transcript tail. Refreshed per tick so the preview tracks the
        // latest summary without host plumbing.
        if (self.active_session_id) |sid| {
            var maybe_row = summaries.readSummary(self.allocator, self.parent_config.workspace_root, sid) catch null;
            if (maybe_row) |*row| {
                defer row.deinit(self.allocator);
                const fresh = if (self.context_text) |cur| !std.mem.eql(u8, cur, row.summary) else true;
                if (fresh) {
                    if (self.context_text) |old| self.allocator.free(@constCast(old));
                    self.context_text = self.allocator.dupe(u8, row.summary) catch null;
                }
            }
        }

        // Build combined context: prompt + session summary (RECENT WORK STATE)
        const combined = if (self.context_text) |ctx|
            std.fmt.allocPrint(self.allocator, "USER REQUEST:\n{s}\n\nRECENT WORK STATE:\n{s}", .{ self.active_prompt.?, ctx }) catch return
        else
            std.fmt.allocPrint(self.allocator, "USER REQUEST:\n{s}", .{self.active_prompt.?}) catch return;
        defer self.allocator.free(combined);

        if (runBufferModel(self.allocator, self.parent_config, policy, combined, self.transport)) |text| {
            defer self.allocator.free(text);
            self.sink.onPreviewFn(self.sink.context, text);
        }
    }
};

/// Load buffer policy from config.json. Returns default (disabled) on error.
pub fn loadBufferPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
) BufferPolicy {
    var parsed = config_file.readValidatedDocument(allocator, workspace_root) catch return .{};
    defer parsed.deinit();

    const root = parsed.value.object;
    const buf = root.get("buffer") orelse return .{};
    if (buf != .object) return .{};
    const obj = buf.object;

    var policy = BufferPolicy{};
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
    if (obj.get("interval_ms")) |v| {
        if (v == .integer) policy.interval_ms = @intCast(v.integer);
    }
    return policy;
}

/// Call the buffer model and return the preview text. Returns null on any failure.
fn runBufferModel(
    allocator: std.mem.Allocator,
    parent_config: types.Config,
    policy: BufferPolicy,
    current_prompt: []const u8,
    transport: provider.Transport,
) ?[]u8 {
    if (policy.model == null) return null;

    var buf_config = buildBufferConfig(allocator, parent_config, policy) catch return null;
    defer buf_config.deinit(allocator);

    const system_msg = types.ChatMessage{
        .role = .system,
        .content = @constCast(buffer_prompt_template),
    };
    const user_msg = types.ChatMessage{
        .role = .user,
        .content = @constCast(current_prompt),
    };
    const messages = [_]types.ChatMessage{ system_msg, user_msg };

    var completion = dispatch.completeWithTransportAndHooks(
        allocator,
        buf_config,
        .{ .messages = messages[0..], .tool_definitions = &.{} },
        transport,
        .{},
    ) catch return null;
    defer completion.deinit(allocator);

    const content = completion.content orelse return null;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len < 5) return null;

    return allocator.dupe(u8, trimmed) catch null;
}

fn buildBufferConfig(
    allocator: std.mem.Allocator,
    parent: types.Config,
    policy: BufferPolicy,
) !types.Config {
    if (policy.provider_id) |pid| {
        var resolved = auth_store.readProviderById(allocator, parent.workspace_root, pid) catch return buildFromParentBuffer(allocator, parent, policy);
        defer resolved.deinit(allocator);

        return types.Config{
            .openai_base_url = try allocator.dupe(u8, resolved.base_url),
            .openai_api_key = try allocator.dupe(u8, resolved.api_key),
            .openai_model = try allocator.dupe(u8, policy.model.?),
            .max_steps = 1,
            .max_tool_calls_per_turn = 0,
            .max_tool_calls_per_session = 0,
            .workspace_root = try allocator.dupe(u8, parent.workspace_root),
            .wire_api = parent.wire_api,
            .effort = if (policy.effort) |e| e else parent.effort,
            .temperature = if (policy.temperature) |t| t else parent.temperature,
        };
    }
    return buildFromParentBuffer(allocator, parent, policy);
}

fn buildFromParentBuffer(
    allocator: std.mem.Allocator,
    parent: types.Config,
    policy: BufferPolicy,
) !types.Config {
    return types.Config{
        .openai_base_url = try allocator.dupe(u8, parent.openai_base_url),
        .openai_api_key = try allocator.dupe(u8, parent.openai_api_key),
        .openai_model = try allocator.dupe(u8, policy.model.?),
        .max_steps = 1,
        .max_tool_calls_per_turn = 0,
        .max_tool_calls_per_session = 0,
        .workspace_root = try allocator.dupe(u8, parent.workspace_root),
        .wire_api = parent.wire_api,
        .effort = if (policy.effort) |e| e else parent.effort,
        .temperature = if (policy.temperature) |t| t else parent.temperature,
    };
}
