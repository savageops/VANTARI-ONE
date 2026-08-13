const std = @import("std");

/// Wire-protocol selector for the provider endpoint. Harvested from Codex's
/// `model_providers.wire_api` config shape and pi-mono's `Api` enum. Determines
/// which HTTP endpoint and request/response shape the provider adapter uses.
///
/// - `chat_completions` — POST /v1/chat/completions (default; LM Studio, z.ai,
///   OpenAI-compat). The existing openai_compatible.zig adapter.
/// - `responses` — POST /v1/responses (OpenAI Responses API; LM Studio 0.3.29+).
///   Stateful input items, reasoning support.
/// - `anthropic_messages` — POST /v1/messages (Anthropic Messages API; LM Studio
///   0.4.1+). Different tool schema (input_schema vs parameters), max_tokens
///   required, system as top-level field.
pub const WireApi = enum {
    chat_completions,
    responses,
    anthropic_messages,
    /// Config default: resolve at dispatch time from the provider base_url
    /// (compat.detectWireApi). Explicit values always beat detection.
    auto,

    pub fn fromString(value: []const u8) ?WireApi {
        if (std.mem.eql(u8, value, "chat_completions")) return .chat_completions;
        if (std.mem.eql(u8, value, "chat")) return .chat_completions;
        if (std.mem.eql(u8, value, "responses")) return .responses;
        if (std.mem.eql(u8, value, "anthropic_messages")) return .anthropic_messages;
        if (std.mem.eql(u8, value, "anthropic")) return .anthropic_messages;
        if (std.mem.eql(u8, value, "auto")) return .auto;
        return null;
    }

    pub fn label(self: WireApi) []const u8 {
        return switch (self) {
            .chat_completions => "chat_completions",
            .responses => "responses",
            .anthropic_messages => "anthropic_messages",
            .auto => "auto",
        };
    }
};

/// Header authentication scheme for API-key provider records. OAuth records
/// keep `AuthType.oauth`; the scheme only selects the request header used by
/// the shared HTTP transport.
pub const AuthScheme = enum {
    bearer,
    api_key,
    none,

    /// Parse the persisted provider header scheme without accepting aliases
    /// that could silently change which secret header is emitted.
    pub fn fromString(value: []const u8) ?AuthScheme {
        if (std.mem.eql(u8, value, "bearer")) return .bearer;
        if (std.mem.eql(u8, value, "api_key")) return .api_key;
        if (std.mem.eql(u8, value, "none")) return .none;
        return null;
    }

    /// Return the stable auth-scheme label used in receipts and diagnostics.
    pub fn label(self: AuthScheme) []const u8 {
        return @tagName(self);
    }
};

pub const Config = struct {
    openai_base_url: []u8,
    openai_api_key: []u8,
    openai_model: []u8,
    auth_provider: ?[]u8 = null,
    auth_type: AuthType = .api_key,
    auth_scheme: AuthScheme = .bearer,
    auth_account_id: ?[]u8 = null,
    auth_expires_at_ms: ?i64 = null,
    subscription_plan_label: ?[]u8 = null,
    subscription_status: ?[]u8 = null,
    max_steps: usize,
    max_tool_calls_per_turn: usize = 16,
    max_tool_calls_per_session: usize = 96,
    workspace_root: []u8,
    /// Agent-facing file/process access boundary. False keeps operations
    /// inside workspace_root; true enables explicit cross-directory access.
    full_access_mode: bool = false,
    context_policy: ContextPolicy = .{},
    prompt_policy: PromptPolicy = .{},
    memory_policy: MemoryPolicy = .{},
    /// Wire-protocol selector for the provider endpoint. Defaults to
    /// chat_completions (the existing /v1/chat/completions adapter). Set via
    /// config.json provider.wire_api = "responses" | "anthropic_messages".
    wire_api: WireApi = .chat_completions,
    /// Controls the model's thinking/reasoning mode for GLM-5.x models.
    /// "disabled" = fast responses, no reasoning tokens (default for speed).
    /// "enabled" = reasoning tokens streamed (slower but more thorough).
    /// Sent as the "thinking" parameter in the OpenAI-compatible request body.
    thinking_mode: []const u8 = "",
    /// Provider effort/reasoning level: "low", "medium", "high", "max".
    /// Empty string omits the field (provider default). Controls reasoning
    /// depth on GLM-5.x and other models that accept the "effort" parameter.
    effort: []const u8 = "",
    /// Owned runtime-policy effort storage when the value came from config.json.
    /// Literal/test-config effort values leave this null.
    effort_owned: ?[]u8 = null,
    /// Provider sampling temperature. Negative value omits the field
    /// (provider default). Range 0.0–2.0; lower = more deterministic.
    temperature: f64 = -1.0,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.openai_base_url);
        allocator.free(self.openai_api_key);
        allocator.free(self.openai_model);
        if (self.auth_provider) |value| allocator.free(value);
        if (self.auth_account_id) |value| allocator.free(value);
        if (self.subscription_plan_label) |value| allocator.free(value);
        if (self.subscription_status) |value| allocator.free(value);
        allocator.free(self.workspace_root);
        if (self.effort_owned) |value| allocator.free(value);
        self.prompt_policy.deinit(allocator);
        var cp = self.context_policy;
        cp.deinit(allocator);
    }
};

pub const ContextPolicy = struct {
    auto_compaction: bool = true,
    manual_compaction: bool = true,
    context_window_tokens: u64 = 128_000,
    compact_at_ratio_milli: u16 = 850,
    reserve_output_tokens: u64 = 8_192,
    keep_recent_messages: usize = 8,
    max_entries_per_checkpoint: usize = 0,
    aggressiveness_milli: u16 = 350,
    retry_on_provider_overflow: bool = true,
    /// Enable semantic compaction: score messages by embedding/TF-IDF
    /// similarity to the session purpose before dropping. When false, the
    /// compactor uses syntactic value-weighting only.
    semantic_compaction: bool = false,
    /// Enable agent summarization: after value-weighted selection, make a
    /// provider call to produce a dense summary preserving completed work,
    /// in-progress state, learnings, workspace context, and TODOs.
    compaction_summary_provider_call: bool = false,
    /// Provider id in auth.json for embeddings (e.g. "embeddings"). When
    /// null, falls back to the active provider, then to TF-IDF.
    embedding_provider: ?[]u8 = null,

    pub fn deinit(self: *ContextPolicy, allocator: std.mem.Allocator) void {
        if (self.embedding_provider) |value| allocator.free(value);
    }
};

pub const PromptPolicy = struct {
    system_prompt_file: ?[]u8 = null,
    developer_prompt_file: ?[]u8 = null,
    persona: ?[]u8 = null,
    guardrails: ?[]u8 = null,
    user_context: ?[]u8 = null,

    pub fn deinit(self: PromptPolicy, allocator: std.mem.Allocator) void {
        if (self.system_prompt_file) |value| allocator.free(value);
        if (self.developer_prompt_file) |value| allocator.free(value);
        if (self.persona) |value| allocator.free(value);
        if (self.guardrails) |value| allocator.free(value);
        if (self.user_context) |value| allocator.free(value);
    }
};

pub const MemoryPolicy = struct {
    enabled: bool = true,
    agent_writes_enabled: bool = true,
    max_entry_bytes: usize = 2048,
    max_session_context_bytes: usize = 8192,
    max_global_context_bytes: usize = 4096,
    max_context_entries: usize = 32,
};

pub const AuthType = enum {
    api_key,
    oauth,
};

pub const SubscriptionSource = enum {
    manual,
    provider,
    inferred,
};

pub const SessionStatus = enum {
    initialized,
    running,
    completed,
    failed,
    cancelled,
};

pub const ExecutionBudget = struct {
    max_steps: usize,
    max_tool_calls: usize,
    max_children: usize,
};

pub const ExecutionReceiptView = struct {
    schema_version: u16 = 1,
    execution_kind: []const u8,
    agent_spec_id: []const u8,
    route_role: []const u8,
    provider_id: []const u8,
    model: []const u8,
    wire_api: []const u8,
    thinking_mode: []const u8,
    capability_profile_id: []const u8,
    capability_hash: []const u8,
    parent_session_id: []const u8,
    parent_checkpoint_id: []const u8,
    group_id: []const u8,
    task_id: []const u8,
    branch_seq: u64,
    budget: ExecutionBudget,
    output_schema_hash: []const u8,
    created_at_ms: i64,
};

pub const ExecutionReceipt = struct {
    schema_version: u16 = 1,
    execution_kind: []u8,
    agent_spec_id: []u8,
    route_role: []u8,
    provider_id: []u8,
    model: []u8,
    wire_api: []u8,
    thinking_mode: []u8,
    capability_profile_id: []u8,
    capability_hash: []u8,
    parent_session_id: []u8,
    parent_checkpoint_id: []u8,
    group_id: []u8,
    task_id: []u8,
    branch_seq: u64,
    budget: ExecutionBudget,
    output_schema_hash: []u8,
    created_at_ms: i64,

    pub fn deinit(self: ExecutionReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.execution_kind);
        allocator.free(self.agent_spec_id);
        allocator.free(self.route_role);
        allocator.free(self.provider_id);
        allocator.free(self.model);
        allocator.free(self.wire_api);
        allocator.free(self.thinking_mode);
        allocator.free(self.capability_profile_id);
        allocator.free(self.capability_hash);
        allocator.free(self.parent_session_id);
        allocator.free(self.parent_checkpoint_id);
        allocator.free(self.group_id);
        allocator.free(self.task_id);
        allocator.free(self.output_schema_hash);
    }

    pub fn view(self: ExecutionReceipt) ExecutionReceiptView {
        return .{
            .schema_version = self.schema_version,
            .execution_kind = self.execution_kind,
            .agent_spec_id = self.agent_spec_id,
            .route_role = self.route_role,
            .provider_id = self.provider_id,
            .model = self.model,
            .wire_api = self.wire_api,
            .thinking_mode = self.thinking_mode,
            .capability_profile_id = self.capability_profile_id,
            .capability_hash = self.capability_hash,
            .parent_session_id = self.parent_session_id,
            .parent_checkpoint_id = self.parent_checkpoint_id,
            .group_id = self.group_id,
            .task_id = self.task_id,
            .branch_seq = self.branch_seq,
            .budget = self.budget,
            .output_schema_hash = self.output_schema_hash,
            .created_at_ms = self.created_at_ms,
        };
    }
};

pub const SessionRecord = struct {
    id: []u8,
    prompt: []u8,
    status: SessionStatus,
    parent_session_id: ?[]u8 = null,
    continued_from_session_id: ?[]u8 = null,
    display_name: ?[]u8 = null,
    agent_profile: ?[]u8 = null,
    /// Immutable access scope selected when this session was admitted. Legacy
    /// records omit the field and remain workspace-contained by default.
    full_access_mode: bool = false,
    /// Heap-owned because the large optional-by-value shape miscompiled under
    /// clean Zig 0.15.1 ReleaseFast builds. Pointer presence is the stable
    /// discriminant; the receipt itself remains immutable session state.
    execution_receipt: ?*ExecutionReceipt = null,
    failure_reason: ?[]u8 = null,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn deinit(self: SessionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.prompt);
        if (self.parent_session_id) |value| allocator.free(value);
        if (self.continued_from_session_id) |value| allocator.free(value);
        if (self.display_name) |value| allocator.free(value);
        if (self.agent_profile) |value| allocator.free(value);
        if (self.execution_receipt) |value| {
            value.deinit(allocator);
            allocator.destroy(value);
        }
        if (self.failure_reason) |value| allocator.free(value);
    }
};

pub const ProgressSnapshot = struct {
    session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    output: []const u8,
    updated_at_ms: i64,
};

pub const SessionEvent = struct {
    event_type: []const u8,
    message: []const u8,
    timestamp_ms: i64,
    /// Monotonic ledger position in events.jsonl. Assigned by `appendEvent`;
    /// 0 for legacy rows written before seq existed or for in-memory events
    /// that have not yet been persisted.
    seq: u64 = 0,

    pub fn deinit(self: SessionEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.event_type);
        allocator.free(self.message);
    }
};

pub fn deinitSessionRecords(allocator: std.mem.Allocator, sessions: []SessionRecord) void {
    for (sessions) |session| session.deinit(allocator);
    allocator.free(sessions);
}

pub fn deinitSessionEvents(allocator: std.mem.Allocator, events: []SessionEvent) void {
    for (events) |event| event.deinit(allocator);
    allocator.free(events);
}

pub const MessageRole = enum {
    system,
    user,
    assistant,
    tool,
};

pub const SessionMessageRole = enum {
    user,
    assistant,
    tool,
};

pub const SessionMessage = struct {
    id: []u8,
    seq: u64,
    role: SessionMessageRole,
    content: []u8,
    tool_call_id: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    timestamp_ms: i64,
    /// Model reasoning trace (reasoning_content from GLM-5.x / DeepSeek / etc.).
    /// Null for messages from providers that don't emit reasoning, or for
    /// user/tool messages. When present, this is the model's thinking trace
    /// that anchors context across compaction boundaries.
    reasoning: ?[]u8 = null,

    pub fn deinit(self: SessionMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.content);
        if (self.tool_call_id) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
        if (self.reasoning) |value| allocator.free(value);
    }
};

pub fn deinitSessionMessages(allocator: std.mem.Allocator, messages: []SessionMessage) void {
    for (messages) |message| message.deinit(allocator);
    allocator.free(messages);
}

pub const ContextCheckpoint = struct {
    id: []u8,
    entry_type: []u8,
    created_at_ms: i64,
    source_seq_start: u64,
    source_seq_end: u64,
    first_kept_seq: u64,
    tokens_before_estimate: u64,
    tokens_after_estimate: u64,
    aggressiveness_milli: u16 = 350,
    compacted_entry_count: u32 = 0,
    trigger: []u8,
    summary: []u8,
    /// Parent checkpoint id for shard entries (null for summary checkpoints).
    /// When present, this checkpoint represents a branch shard whose context
    /// window is derived from the parent checkpoint + this branch's transcript.
    parent_checkpoint_id: ?[]u8 = null,
    /// Branch sequence number within the parent's branch space.
    branch_seq: u64 = 0,
    /// Branch lifecycle status for shard entries: "open", "converged", or
    /// "abandoned". Null for summary checkpoints.
    branch_status: ?ShardStatus = null,

    pub fn deinit(self: ContextCheckpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.entry_type);
        allocator.free(self.trigger);
        allocator.free(self.summary);
        if (self.parent_checkpoint_id) |value| allocator.free(value);
    }
};

/// Branch lifecycle status for shard checkpoints (roadmap P0-1).
pub const ShardStatus = enum {
    open,
    converged,
    abandoned,

    pub fn label(self: ShardStatus) []const u8 {
        return switch (self) {
            .open => "open",
            .converged => "converged",
            .abandoned => "abandoned",
        };
    }

    pub fn parse(text: []const u8) ?ShardStatus {
        if (std.mem.eql(u8, text, "open")) return .open;
        if (std.mem.eql(u8, text, "converged")) return .converged;
        if (std.mem.eql(u8, text, "abandoned")) return .abandoned;
        return null;
    }
};

pub fn deinitContextCheckpoints(allocator: std.mem.Allocator, checkpoints: []ContextCheckpoint) void {
    for (checkpoints) |checkpoint| checkpoint.deinit(allocator);
    allocator.free(checkpoints);
}

pub const ToolRiskClass = enum {
    read_only,
    interactive,
    write_capable,
    command_execution,
    delegating,
    unknown_high_impact,
};

/// Parse a risk class label string into the enum, or null if invalid.
pub fn parseReviewRiskLabel(text: []const u8) ?ToolRiskClass {
    if (std.mem.eql(u8, text, "read_only")) return .read_only;
    if (std.mem.eql(u8, text, "interactive")) return .interactive;
    if (std.mem.eql(u8, text, "write_capable")) return .write_capable;
    if (std.mem.eql(u8, text, "command_execution")) return .command_execution;
    if (std.mem.eql(u8, text, "delegating")) return .delegating;
    if (std.mem.eql(u8, text, "unknown_high_impact")) return .unknown_high_impact;
    return null;
}

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    review_risk: ToolRiskClass,
    example_json: ?[]const u8 = null,
    usage_hint: ?[]const u8 = null,
};

pub const ToolCall = struct {
    id: []u8,
    name: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.arguments_json);
    }
};

pub const ChatMessage = struct {
    role: MessageRole,
    content: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    /// Model reasoning trace forwarded to the provider so the model sees
    /// its prior thinking in the context window.
    reasoning: ?[]u8 = null,

    pub fn deinit(self: ChatMessage, allocator: std.mem.Allocator) void {
        if (self.content) |value| allocator.free(value);
        if (self.tool_call_id) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
        if (self.reasoning) |value| allocator.free(value);
    }
};

pub const CompletionRequest = struct {
    messages: []const ChatMessage,
    tool_definitions: []const ToolDefinition = &.{},
};

/// Provider-reported token accounting (measured, not estimated). All integer
/// value type — no allocation, no deinit. Mirrors prime-agent's `Usage`
/// (packages/ai/src/types.ts:201-214) flattened to the buckets VANTARI prices:
/// prompt, completion, and cached (prompt cache read) tokens.
/// Why: the event spine's token telemetry must come from the provider's usage
/// block, not a compile-time estimate. Preserves: per-turn measured evidence.
/// Evidence: filled by all three provider adapters (035a/035c); priced by
/// pricing.calculateCost; emitted in completed turn_terminal events.
pub const Usage = struct {
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    total_tokens: u64 = 0,

    /// Recompute total from the measured buckets when the provider omits
    /// total_tokens (some OpenAI-compat endpoints do on stream tails).
    /// Keeps the provider total when present.
    pub fn reconcile(self: *Usage) void {
        if (self.total_tokens == 0) {
            self.total_tokens = self.prompt_tokens + self.completion_tokens + self.cached_tokens;
        }
    }
};

pub const CompletionResponse = struct {
    model: []u8,
    content: ?[]u8 = null,
    tool_calls: []ToolCall = &.{},
    /// Model reasoning trace captured from the provider response.
    reasoning: ?[]u8 = null,
    /// Provider-reported token accounting; zeros when the endpoint omits
    /// usage (never an error — token evidence is best-effort per wire protocol).
    usage: Usage = .{},

    pub fn deinit(self: CompletionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.model);
        if (self.content) |value| allocator.free(value);
        for (self.tool_calls) |tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
        if (self.reasoning) |value| allocator.free(value);
    }

    pub fn hasToolCalls(self: CompletionResponse) bool {
        return self.tool_calls.len > 0;
    }
};

pub const SessionRunResult = struct {
    session_id: []u8,
    output: []u8,

    pub fn deinit(self: SessionRunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.output);
    }
};

pub fn statusLabel(status: SessionStatus) []const u8 {
    return switch (status) {
        .initialized => "initialized",
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}

pub fn parseStatusLabel(label: []const u8) !SessionStatus {
    if (std.mem.eql(u8, label, "initialized")) return .initialized;
    if (std.mem.eql(u8, label, "pending")) return .initialized;
    if (std.mem.eql(u8, label, "running")) return .running;
    if (std.mem.eql(u8, label, "completed")) return .completed;
    if (std.mem.eql(u8, label, "failed")) return .failed;
    if (std.mem.eql(u8, label, "cancelled")) return .cancelled;
    return error.InvalidStatus;
}

pub fn roleLabel(role: MessageRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn sessionMessageRoleLabel(role: SessionMessageRole) []const u8 {
    return switch (role) {
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

pub fn parseSessionMessageRole(label: []const u8) !SessionMessageRole {
    if (std.mem.eql(u8, label, "user")) return .user;
    if (std.mem.eql(u8, label, "assistant")) return .assistant;
    if (std.mem.eql(u8, label, "tool")) return .tool;
    return error.InvalidSessionMessageRole;
}

pub fn initTextMessage(
    allocator: std.mem.Allocator,
    role: MessageRole,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = role,
        .content = try allocator.dupe(u8, text),
    };
}

pub fn initToolMessage(
    allocator: std.mem.Allocator,
    tool_call_id: []const u8,
    text: []const u8,
) !ChatMessage {
    return .{
        .role = .tool,
        .content = try allocator.dupe(u8, text),
        .tool_call_id = try allocator.dupe(u8, tool_call_id),
    };
}

pub fn initAssistantToolCallMessage(
    allocator: std.mem.Allocator,
    content: ?[]const u8,
    tool_calls: []const ToolCall,
) !ChatMessage {
    return .{
        .role = .assistant,
        .content = if (content) |value| try allocator.dupe(u8, value) else null,
        .tool_calls = try cloneToolCalls(allocator, tool_calls),
    };
}

/// Initialize an assistant text message with an optional reasoning trace.
/// The reasoning is forwarded to the provider so the model sees its prior
/// thinking in the context window.
pub fn initAssistantMessageWithReasoning(
    allocator: std.mem.Allocator,
    content: []const u8,
    reasoning: ?[]const u8,
) !ChatMessage {
    return .{
        .role = .assistant,
        .content = try allocator.dupe(u8, content),
        .reasoning = if (reasoning) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn cloneToolCalls(allocator: std.mem.Allocator, tool_calls: []const ToolCall) ![]ToolCall {
    if (tool_calls.len == 0) return &.{};

    var owned_calls = try allocator.alloc(ToolCall, tool_calls.len);
    errdefer allocator.free(owned_calls);

    for (tool_calls, 0..) |tool_call, index| {
        owned_calls[index] = .{
            .id = try allocator.dupe(u8, tool_call.id),
            .name = try allocator.dupe(u8, tool_call.name),
            .arguments_json = try allocator.dupe(u8, tool_call.arguments_json),
        };
    }

    return owned_calls;
}
