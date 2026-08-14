const std = @import("std");
const agents = @import("../core/agents/service.zig");
const cli_auth = @import("cli_auth.zig");
const auth_store = @import("../core/auth/store.zig");
const openai_codex = @import("../core/auth/openai_codex.zig");
const config = @import("../core/config/resolver.zig");
const config_file = @import("../core/config/file.zig");
const workspace = @import("../core/config/workspace.zig");
const session_store = @import("../core/sessions/store.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const stdio_rpc = @import("../host/stdio_rpc.zig");
const fsutil = @import("../shared/fsutil.zig");
const shared_types = @import("../shared/types.zig");
const provider_profile = @import("../core/providers/profile.zig");
const prompt_modes = @import("../core/prompts/index.zig");
const owner_state = @import("../host/owner_state.zig");
const web = @import("../host/http_bridge.zig");

const resolveWorkspaceRoot = workspace.resolve;
const installedWorkspaceFilePath = workspace.installedFilePath;

const RunCliOptions = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    json_output: bool = false,
    enable_agent_tools: bool = true,
    prompt_mode: prompt_modes.PromptMode = .orchestrate,
    /// Per-invocation model override (not persisted). Swaps the active
    /// provider model for this run only.
    model_override: ?[]const u8 = null,
    /// Per-invocation provider override (not persisted). Resolves one named
    /// auth-ledger record for this run only.
    provider_override: ?[]const u8 = null,
    /// Per-invocation context window override (token count). Adjusts the
    /// compaction threshold for models with smaller windows.
    context_window_override: ?u64 = null,
    /// Per-invocation max output token budget override.
    max_output_tokens: ?u64 = null,
};

const ServeCliOptions = struct {
    port: u16 = 4310,
};

const ToolsCliOptions = struct {
    json_output: bool = false,
};

const ModelsCliOptions = struct {
    json_output: bool = false,
    provider: ?[]const u8 = null,
};

const ProvidersCliOptions = struct {
    json_output: bool = false,
};

const ScheduleCliOptions = struct {
    json_output: bool = false,
    include_deleted: bool = false,
    job_id: ?[]const u8 = null,
};

const WorkspaceCliAction = union(enum) {
    show,
    set: []const u8,
    clear,
};

const SessionsCliOptions = struct {
    json_output: bool = false,
    limit: usize = 12,
};

const HealthCliOptions = struct {
    json_output: bool = false,
};

const TurnStatusMode = enum {
    silent,
    stderr,
};

/// Per-invocation provider overrides forwarded through the kernel run
/// protocol. All optional; when null the server config value is used.
const TurnOverrides = struct {
    model_override: ?[]const u8 = null,
    provider_override: ?[]const u8 = null,
    context_window_override: ?u64 = null,
    max_output_tokens: ?u64 = null,
    prompt_mode: prompt_modes.PromptMode = .orchestrate,
};

const ParsedRunArguments = struct {
    options: RunCliOptions = .{},
    help_requested: bool = false,
};

const ParsedServeArguments = struct {
    options: ServeCliOptions = .{},
    help_requested: bool = false,
};

const ParsedToolsArguments = struct {
    options: ToolsCliOptions = .{},
    help_requested: bool = false,
};

const ParsedModelsArguments = struct {
    options: ModelsCliOptions = .{},
    help_requested: bool = false,
};

const ParsedProvidersArguments = struct {
    options: ProvidersCliOptions = .{},
    help_requested: bool = false,
};

const ParsedScheduleArguments = struct {
    options: ScheduleCliOptions = .{},
    help_requested: bool = false,
};

const ParsedWorkspaceArguments = struct {
    action: WorkspaceCliAction = .show,
    help_requested: bool = false,
};

const ParsedSessionsArguments = struct {
    options: SessionsCliOptions = .{},
    help_requested: bool = false,
};

const ParsedHealthArguments = struct {
    options: HealthCliOptions = .{},
    help_requested: bool = false,
};

const ParsedSessionSummary = struct {
    session_id: []const u8,
    status: []const u8,
    prompt: []const u8,
    output: ?[]const u8 = null,
    parent_session_id: ?[]const u8 = null,
    continued_from_session_id: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    agent_profile: ?[]const u8 = null,
    execution_receipt: ?shared_types.ExecutionReceiptView = null,
    failure_reason: ?[]const u8 = null,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
};

const ParsedSessionCreateResult = struct {
    session: ParsedSessionSummary,
};

const ParsedSessionSendResult = struct {
    session: ParsedSessionSummary,
};

const SessionListProjection = struct {
    summaries: []protocol_types.SessionSummary,
    outputs: []?[]u8,

    fn deinit(self: SessionListProjection, allocator: std.mem.Allocator) void {
        for (self.outputs) |maybe_output| {
            if (maybe_output) |output| allocator.free(output);
        }
        allocator.free(self.outputs);
        allocator.free(self.summaries);
    }
};

const ParsedHealthResult = struct {
    ok: bool,
    model: []const u8,
    workspace_root: []const u8,
    base_url: []const u8,
    auth_provider: ?[]const u8 = null,
    subscription_plan_label: ?[]const u8 = null,
    subscription_status: ?[]const u8 = null,
    scheduler_supervisor: bool = false,
    effort: []const u8 = "",
    thinking_mode: []const u8 = "",
    context_window_tokens: u64 = 0,
    reserve_output_tokens: u64 = 0,
    /// Additive operator telemetry projected by the canonical health RPC.
    /// Defaults keep installed clients compatible with older kernels.
    agent_pool_healthy: bool = false,
    agent_pool_max: usize = 0,
    agent_pool_queued: usize = 0,
    agent_pool_running: usize = 0,
    agent_pool_idle: usize = 0,
    agent_pool_available: usize = 0,
    tickets_unassigned: usize = 0,
    tickets_assigned: usize = 0,
    tickets_in_progress: usize = 0,
    tickets_blocked: usize = 0,
    tickets_completed: usize = 0,
    tickets_closed: usize = 0,
    ticket_ledger_healthy: bool = true,
};

const ParsedToolsListResult = struct {
    format: []const u8,
    output: []const u8,
};

const ParsedModelEntry = struct {
    id: []const u8,
    owned_by: ?[]const u8 = null,
    context_length: ?u64 = null,
};

const ParsedModelsListResult = struct {
    schema: []const u8 = "var1.models.v1",
    provider: []const u8,
    base_url: []const u8,
    models: []ParsedModelEntry = &.{},
    context_from_native_surface: bool = false,
    status: []const u8 = "ok",
    error_message: ?[]const u8 = null,
};

const ParsedProviderEntry = struct {
    provider_id: []const u8,
    auth_type: shared_types.AuthType,
    wire_api: shared_types.WireApi,
    auth_scheme: shared_types.AuthScheme,
    model: []const u8,
    base_url: []const u8,
    active: bool,
    expires_at_ms: ?i64 = null,
    subscription_status: ?[]const u8 = null,
};

const ParsedProvidersListResult = struct {
    schema: []const u8 = "var1.providers.v1",
    active_provider: []const u8,
    providers: []ParsedProviderEntry = &.{},
    status: []const u8 = "ok",
    error_message: ?[]const u8 = null,
};

const ParsedScheduleListResult = struct {
    schedules: []protocol_types.ScheduleSummary = &.{},
};

const ParsedScheduleGetResult = struct {
    schedule: protocol_types.ScheduleSummary,
};

pub const root_help_text =
    \\VAR1 Zig Kernel
    \\
    \\Usage:
    \\  vantari
    \\  vantari -c
    \\  vantari <command> [flags]
    \\  var <command> [flags]
    \\  VAR1 <command> [flags]
    \\
    \\Commands:
    \\  run      Execute a prompt or resume a canonical session through the kernel protocol.
    \\  c        Show recent canonical sessions for this workspace.
    \\  continue Alias for c.
    \\  health   Report local runtime readiness through the kernel protocol.
    \\  schedule List or inspect durable scheduler jobs through the kernel protocol.
    \\  config   Locate, materialize, inspect, or validate ~/.vantari/config.json.
    \\  auth     Login, logout, or inspect the active provider without printing secrets.
    \\  providers List configured provider identities and selected models.
    \\  workspace Show or set an explicit installed-client workspace override.
    \\  serve    Start the HTTP bridge for /rpc, /events, and /api/health.
    \\  tools    Print the built-in tool catalog and schemas through the kernel protocol.
    \\  models   Discover available models from the selected provider.
    \\  help     Print help for a command.
    \\
    \\Examples:
    \\  vantari
    \\  vantari -c
    \\  vantari "List the files under src."
    \\  vantari c
    \\  vantari workspace show
    \\  vantari config validate
    \\  vantari workspace set E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend
    \\  var c
    \\  VAR1 run --prompt "Summarize src/cli.zig."
    \\  VAR1 run --prompt-file .\prompt.txt --json
    \\  VAR1 run --session-id session-1776778021956-42e781c4c8b4efb8
    \\  VAR1 health
    \\  VAR1 auth status --json
    \\  VAR1 providers --json
    \\  VAR1 schedule list
    \\  VAR1 serve --port 4310
    \\  VAR1 tools --json
    \\
    \\Notes:
    \\  zig build run -- <command> ... accepts the same command and flag surface.
    \\  PowerShell reserves bare var; use vantari or var.exe there.
    \\  VAR1 reads .env from the current workspace for run, health, serve, and tools execution.
    \\  Workspace resolution checks VANTARI_WORKSPACE, current directory ancestors, then explicit installed override.
    \\  vantari -c opens the TUI on the most recently updated session in the current workspace.
    \\  Use VAR1 help <command> or VAR1 <command> --help for command-specific details.
    \\
;

pub const config_help_text =
    \\Usage:
    \\  vantari config path
    \\  vantari config show
    \\  vantari config init
    \\  vantari config validate
    \\
    \\Behavior:
    \\  config.json owns non-secret runtime, provider-wire, context, prompt, and
    \\  environment-style overrides. auth.json remains the credential owner.
    \\  init creates the default file only when it is absent. Existing files are
    \\  never rewritten implicitly.
    \\
;

pub const schedule_help_text =
    \\Usage:
    \\  VAR1 schedule list [--json] [--include-deleted]
    \\  VAR1 schedule get <job-id> [--json]
    \\
    \\Flags:
    \\  --json                    Emit the canonical schedule/get or schedule/list result.
    \\  --include-deleted         Include soft-deleted jobs in list output.
    \\  -h, --help                Print help for the schedule command.
    \\
    \\Behavior:
    \\  schedule is a protocol-backed read model over .var/schedules. Mutations remain agent/tool-owned through schedule_job.
    \\
;

pub const workspace_help_text =
    \\Usage:
    \\  vantari workspace show
    \\  vantari workspace set <path>
    \\  vantari workspace clear
    \\
    \\Behavior:
    \\  The default workspace is the terminal's current directory, resolved upward to a Ventari marker.
    \\  Use set only for an explicit installed-client override. VANTARI_WORKSPACE has highest precedence.
    \\
;

pub const sessions_help_text =
    \\Usage:
    \\  var c [--limit <count>] [--json]
    \\  var continue [--limit <count>] [--json]
    \\
    \\Flags:
    \\  --limit <count>           Maximum sessions to show. Default: 12
    \\  --json                    Emit the canonical session/list result.
    \\  -h, --help                Print help for the recent-session command.
    \\
    \\Behavior:
    \\  c is a canonical recent-session selector seed. It reads only the current workspace
    \\  .var/sessions store and does not inspect legacy or global runtime roots.
    \\
    \\Examples:
    \\  var c
    \\  var c --limit 5
    \\  var continue --json
    \\
;

pub const run_help_text =
    \\Usage:
    \\  var run --prompt <text> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\  var run --prompt-file <path> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\  var run --session-id <session-id> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\  VAR1 run --prompt <text> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\  VAR1 run --prompt-file <path> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\  VAR1 run --session-id <session-id> [--prompt-mode <mode>] [--json] [--no-agent-tools]
    \\
    \\Flags:
    \\  --prompt <text>           Execute an inline prompt as a new session.
    \\  --prompt-file <path>      Read the prompt from a file and trim trailing newlines.
    \\  --session-id <session-id> Resume an existing canonical session and reuse its stored prompt.
    \\  --provider <id>           Select an auth-ledger provider for this run only (not persisted).
    \\  --model <id|provider/id>  Override the selected model; a known provider/id selects that provider for this run.
    \\  --context-window <tokens> Override the context-window size for compaction thresholds this run only.
    \\  --max-output-tokens <n>   Override the reserved output token budget this run only.
    \\  --prompt-mode <mode>      Select orchestrate, build, align, or plan; default: orchestrate.
    \\  --json                    Emit {"session_id","output"} instead of plain text.
    \\  --no-agent-tools          Hide launch_agent, agent_status, wait_agent, and list_agents from the model.
    \\  -h, --help                Print help for the run command.
    \\
    \\Rules:
    \\  Exactly one prompt source is allowed: --prompt, --prompt-file, or --session-id.
    \\  When --session-id is provided, VAR1 resumes the stored session prompt and does not accept a new prompt source.
    \\  orchestrate is the default root posture; build, align, and plan retain the normal root tool catalog.
    \\
    \\Examples:
    \\  VAR1 run --prompt "List the files under src."
    \\  VAR1 run --prompt-file .\delegated-prompt.txt --json
    \\  VAR1 run --session-id session-1776778021956-42e781c4c8b4efb8
    \\
;

pub const health_help_text =
    \\Usage:
    \\  VAR1 health [--json]
    \\
    \\Flags:
    \\  --json                    Emit readiness, model/context, pool capacity, and ticket pressure as JSON.
    \\  -h, --help                Print help for the health command.
    \\
    \\Behavior:
    \\  health is a thin protocol-backed readiness check and does not send a model completion request.
    \\
    \\Examples:
    \\  VAR1 health
    \\  VAR1 health --json
    \\
;

pub const serve_help_text =
    \\Usage:
    \\  VAR1 serve [--port <port>]
    \\
    \\Flags:
    \\  --port <port>             Bind port for the local bridge. Default: 4310
    \\  -h, --help                Print help for the serve command.
    \\
    \\Routes:
    \\  POST /rpc                 JSON-RPC bridge to the hidden kernel stdio host
    \\  GET  /events              Server-sent events for session notifications
    \\  GET  /api/health          Thin readiness alias for scripts and operators
    \\
    \\Example:
    \\  VAR1 serve --port 4310
    \\
;

pub const tools_help_text =
    \\Usage:
    \\  VAR1 tools [--json]
    \\
    \\Flags:
    \\  --json                    Emit machine-readable tool contracts for the current default catalog.
    \\  -h, --help                Print help for the tools command.
    \\
    \\JSON output shape:
    \\  {
    \\    "workspace_root": "<absolute-path>",
    \\    "tools": [
    \\      {
    \\        "name": "...",
    \\        "description": "...",
    \\        "parameters_schema": { ... },
    \\        "contract_example": { ... },
    \\        "usage_hint": "...",
    \\        "availability": {
    \\          "status": "available|unavailable",
    \\          "dependencies": [{ "kind": "external_command", "name": "iex", "available": true }]
    \\        }
    \\      }
    \\    ]
    \\  }
    \\
    \\Notes:
    \\  The default tools catalog shows the same file and agent tools exposed for ordinary coding prompts.
    \\  Workspace-state tools remain relevance-gated and are enabled only for explicitly .var-state-related requests.
    \\
    \\Examples:
    \\  VAR1 tools
    \\  VAR1 tools --json
    \\
;

pub const models_help_text =
    \\Usage:
    \\  VAR1 models [--json] [--provider <id>]
    \\
    \\Description:
    \\  Discover available models from the active OpenAI-compatible provider
    \\  (LM Studio, llama.cpp, vLLM, Ollama, OpenRouter, z.ai, ...).
    \\
    \\Flags:
    \\  --json              Emit the var1.models.v1 schema payload.
    \\  --provider <id>     Resolve a non-active provider.
    \\  -h, --help          Print help for the models command.
    \\
    \\Examples:
    \\  VAR1 models
    \\  VAR1 models --json
    \\
;

pub const providers_help_text =
    \\Usage:
    \\  VAR1 providers [--json]
    \\
    \\Description:
    \\  List configured provider identities, selected models, wire APIs, and
    \\  secret-free availability metadata. Use `auth use` to persist selection
    \\  or `run --provider` for one turn.
    \\
    \\Flags:
    \\  --json              Emit the var1.providers.v1 schema payload.
    \\  -h, --help          Print help for the providers command.
    \\
;

pub fn main(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter.next();
    const command = iter.next() orelse {
        try executeInteractive(allocator);
        return;
    };

    if (isHelpFlag(command)) {
        try writeStdout(root_help_text);
        return;
    }

    if (std.mem.eql(u8, command, "help")) {
        const requested_topic = iter.next();
        if (requested_topic) |topic| {
            if (iter.next() != null) {
                try printInvalidArguments("help", root_help_text);
                return error.InvalidArgs;
            }

            const text = helpText(topic) orelse {
                try printUnknownCommand(topic);
                return error.InvalidArgs;
            };
            try writeStdout(text);
            return;
        }

        try writeStdout(root_help_text);
        return;
    }

    if (std.mem.eql(u8, command, "run")) {
        const parsed = parseRunArguments(iter) catch |err| {
            try printInvalidArguments("run", run_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(run_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeRunViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "c") or std.mem.eql(u8, command, "continue") or std.mem.eql(u8, command, "sessions")) {
        const parsed = parseSessionsArguments(iter) catch |err| {
            try printInvalidArguments("c", sessions_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(sessions_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try executeSessionsFromStore(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "workspace")) {
        const parsed = parseWorkspaceArguments(iter) catch |err| {
            try printInvalidArguments("workspace", workspace_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(workspace_help_text);
            return;
        }
        try executeWorkspaceCommand(allocator, parsed.action);
        return;
    }

    if (std.mem.eql(u8, command, "config")) {
        const action = iter.next() orelse "show";
        if (isHelpFlag(action)) {
            if (iter.next() != null) return error.InvalidArgs;
            try writeStdout(config_help_text);
            return;
        }
        if (iter.next() != null) {
            try printInvalidArguments("config", config_help_text);
            return error.InvalidArgs;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try executeConfigCommand(allocator, workspace_root, action);
        return;
    }

    if (std.mem.eql(u8, command, "auth")) {
        const parsed = cli_auth.parseArguments(iter) catch |err| {
            try printInvalidArguments("auth", cli_auth.help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(cli_auth.help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try executeAuthCommand(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "providers")) {
        const parsed = parseProvidersArguments(iter) catch |err| {
            try printInvalidArguments("providers", providers_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(providers_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeProvidersViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "health")) {
        const parsed = parseHealthArguments(iter) catch |err| {
            try printInvalidArguments("health", health_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(health_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try executeHealthViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "schedule")) {
        const parsed = parseScheduleArguments(iter) catch |err| {
            try printInvalidArguments("schedule", schedule_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(schedule_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeScheduleViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    // Internal entry point for the project-local execution owner.
    // Presentation clients start this process; it is intentionally absent from
    // user help and owns no second pool or scheduler.
    if (std.mem.eql(u8, command, "execution-owner")) {
        const workspace_arg = if (iter.next()) |flag| blk: {
            if (!std.mem.eql(u8, flag, "--workspace")) return error.InvalidArgs;
            break :blk iter.next() orelse return error.InvalidArgs;
        } else null;
        if (iter.next() != null) return error.InvalidArgs;
        const workspace_root = if (workspace_arg) |explicit|
            try std.fs.cwd().realpathAlloc(allocator, explicit)
        else
            try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        var owner_lease = try owner_state.acquireOwnerLease(allocator, workspace_root, 0);
        defer owner_lease.deinit();
        const loaded_config = config.loadDefaultForExplicitWorkspace(allocator, workspace_root) catch |err| {
            try writeConfigLoadErrorEnvelope(err, workspace_root);
            std.process.exit(1);
        };
        defer loaded_config.deinit(allocator);
        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
            .sendWithHeadersFn = provider.httpSendWithHeaders,
            .streamWithHeadersFn = provider.httpSendStreamingWithHeaders,
        };
        try web.serve(allocator, loaded_config, .{
            .host = "127.0.0.1",
            .port = 0,
            .transport = transport,
            .publish_owner = true,
            .announce_listener = false,
        });
        return;
    }

    if (std.mem.eql(u8, command, "serve")) {
        const parsed = parseServeArguments(iter) catch |err| {
            try printInvalidArguments("serve", serve_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(serve_help_text);
            return;
        }

        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        var owner_lease = owner_state.acquireOwnerLease(allocator, workspace_root, 0) catch |err| switch (err) {
            error.OwnerLockUnavailable => {
                try writeStderr("VAR1_ERROR category=execution_owner code=AlreadyRunning message=\"an execution owner already holds this workspace lease\"\n");
                return error.InvalidArgs;
            },
            else => return err,
        };
        defer owner_lease.deinit();
        const loaded_config = config.loadDefault(allocator, workspace_root) catch |err| {
            try writeConfigLoadErrorEnvelope(err, workspace_root);
            std.process.exit(1);
        };
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
            .sendWithHeadersFn = provider.httpSendWithHeaders,
            .streamWithHeadersFn = provider.httpSendStreamingWithHeaders,
        };
        try web.serve(allocator, loaded_config, .{
            .host = "127.0.0.1",
            .port = parsed.options.port,
            .transport = transport,
            .publish_owner = true,
        });
        return;
    }

    if (std.mem.eql(u8, command, "kernel-stdio")) {
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        const loaded_config = config.loadDefault(allocator, workspace_root) catch |err| {
            try writeConfigLoadErrorEnvelope(err, workspace_root);
            std.process.exit(1);
        };
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
            .sendWithHeadersFn = provider.httpSendWithHeaders,
            .streamWithHeadersFn = provider.httpSendStreamingWithHeaders,
        };
        var agent_service = agents.Service.initWithTransport(&loaded_config, transport);
        defer agent_service.deinit();
        try stdio_rpc.serveKernel(allocator, &loaded_config, transport, agent_service.handle());
        return;
    }

    if (std.mem.eql(u8, command, "tools")) {
        const parsed = parseToolsArguments(iter) catch |err| {
            try printInvalidArguments("tools", tools_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(tools_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeToolsViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "models")) {
        const parsed = parseModelsArguments(iter) catch |err| {
            try printInvalidArguments("models", models_help_text);
            return err;
        };
        if (parsed.help_requested) {
            try writeStdout(models_help_text);
            return;
        }
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeModelsViaKernel(allocator, workspace_root, parsed.options);
        return;
    }

    if (std.mem.eql(u8, command, "stats")) {
        // Retired Move 84 surface: keep the old token from falling through as
        // a provider prompt until a measured counter owner exists.
        try printUnknownCommand(command);
        return error.InvalidArgs;
    }

    if (!std.mem.startsWith(u8, command, "-")) {
        const prompt = try collectPromptArguments(allocator, command, iter);
        defer allocator.free(prompt);
        const workspace_root = try resolveWorkspaceRoot(allocator);
        defer allocator.free(workspace_root);
        try ensureKernelConfigAvailable(allocator, workspace_root);
        try executeRunViaKernel(allocator, workspace_root, .{ .prompt = prompt });
        return;
    }

    try printUnknownCommand(command);
    return error.InvalidArgs;
}

fn executeInteractive(allocator: std.mem.Allocator) !void {
    const workspace_root = try resolveWorkspaceRoot(allocator);
    defer allocator.free(workspace_root);
    try ensureKernelConfigAvailable(allocator, workspace_root);

    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const initialize = try callKernelOrExit(allocator, &client, protocol_types.methods.initialize, "{}");
    defer initialize.deinit(allocator);
    const initialize_result = try expectKernelResult(allocator, initialize);
    defer allocator.free(initialize_result);

    try writeStdout("Vantari interactive\n");
    try writeStdout("workspace: ");
    try writeStdout(workspace_root);
    try writeStdout("\nType /exit to close the session.\n\n");

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    var active_session_id: ?[]u8 = null;
    defer if (active_session_id) |value| allocator.free(value);

    while (true) {
        try writeStdout("vantari> ");
        const raw_line = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.StreamTooLong => {
                try writeStderr("VAR1_ERROR category=cli code=InputTooLong message=\"interactive input line exceeded 8192 bytes\"\n");
                continue;
            },
            else => return err,
        };
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/exit") or std.mem.eql(u8, line, "/quit")) return;

        const prompt = try allocator.dupe(u8, line);
        defer allocator.free(prompt);
        const turn = try executePromptTurn(allocator, &client, active_session_id, prompt, true, .stderr, .{});
        defer if (turn.output) |output| allocator.free(output);
        defer if (turn.failure_reason) |reason| allocator.free(reason);

        if (turn.failure_reason) |reason| {
            try writeSessionFailureEnvelope(allocator, turn.session_id, reason);
            if (active_session_id) |value| {
                allocator.free(value);
                active_session_id = null;
            }
            allocator.free(turn.session_id);
            continue;
        }

        if (active_session_id == null) {
            active_session_id = turn.session_id;
        } else {
            allocator.free(turn.session_id);
        }
        if (turn.output) |output| {
            try writeStdout(output);
            try writeStdout("\n");
        }
    }
}

fn executeRunViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, run_options: RunCliOptions) !void {
    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const turn_overrides = resolveTurnOverrides(run_options);

    const initialize = try callKernelOrExit(allocator, &client, protocol_types.methods.initialize, "{}");
    defer initialize.deinit(allocator);
    const initialize_result = try expectKernelResult(allocator, initialize);
    defer allocator.free(initialize_result);

    const prompt = if (run_options.session_id == null)
        try resolvePromptInput(allocator, run_options.prompt, run_options.prompt_file)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(prompt);

    const turn = try executePromptTurn(
        allocator,
        &client,
        run_options.session_id,
        prompt,
        run_options.enable_agent_tools,
        if (run_options.json_output) .silent else .stderr,
        .{
            .provider_override = turn_overrides.provider_override,
            .model_override = turn_overrides.model_override,
            .context_window_override = run_options.context_window_override,
            .max_output_tokens = run_options.max_output_tokens,
            .prompt_mode = run_options.prompt_mode,
        },
    );
    defer allocator.free(turn.session_id);
    defer if (turn.output) |output| allocator.free(output);
    defer if (turn.failure_reason) |reason| allocator.free(reason);

    if (turn.failure_reason) |reason| {
        try writeSessionFailureEnvelope(allocator, turn.session_id, reason);
        std.process.exit(1);
    }

    const output = turn.output orelse "";
    const json_payload = try renderRunResultJson(allocator, turn.session_id, output);
    defer allocator.free(json_payload);

    if (run_options.json_output) {
        try writeStdout(json_payload);
        return;
    }

    try writeStdout(output);
    try writeStdout("\n");
}

/// Resolve the user-facing provider/model identity before it crosses the
/// protocol boundary. The kernel still receives separate fields, which keeps
/// its wire contract stable, while CLI selection gains the unambiguous
/// `provider/model-id` form used by the strongest reference harnesses.
fn resolveTurnOverrides(options: RunCliOptions) TurnOverrides {
    var resolved = TurnOverrides{
        .provider_override = options.provider_override,
        .model_override = options.model_override,
        .context_window_override = options.context_window_override,
        .max_output_tokens = options.max_output_tokens,
        .prompt_mode = options.prompt_mode,
    };

    if (resolved.provider_override) |provider_id| {
        resolved.provider_override = provider_profile.canonicalProviderId(provider_id);
    }
    if (resolved.model_override) |model_ref| {
        const selection = provider_profile.resolveModelSelection(model_ref, resolved.provider_override);
        resolved.provider_override = selection.provider_id orelse resolved.provider_override;
        resolved.model_override = selection.model_id;
    }

    return resolved;
}

const PromptTurn = struct {
    session_id: []u8,
    output: ?[]u8 = null,
    failure_reason: ?[]u8 = null,
};

fn executePromptTurn(
    allocator: std.mem.Allocator,
    client: *stdio_rpc.LocalClient,
    existing_session_id: ?[]const u8,
    prompt: []const u8,
    enable_agent_tools: bool,
    status_mode: TurnStatusMode,
    overrides: TurnOverrides,
) !PromptTurn {
    const session_id = if (existing_session_id) |value|
        try allocator.dupe(u8, value)
    else blk: {
        const create_params = try renderJsonAlloc(allocator, .{
            .prompt = prompt,
            .enable_agent_tools = enable_agent_tools,
        });
        defer allocator.free(create_params);

        const create_call = try callKernelOrExit(allocator, client, protocol_types.methods.session_create, create_params);
        defer create_call.deinit(allocator);
        const create_result_json = try expectKernelResult(allocator, create_call);
        defer allocator.free(create_result_json);

        var parsed_create = try std.json.parseFromSlice(ParsedSessionCreateResult, allocator, create_result_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed_create.deinit();

        break :blk try allocator.dupe(u8, parsed_create.value.session.session_id);
    };
    errdefer allocator.free(session_id);

    if (status_mode == .stderr) {
        try writeSessionRunningEnvelope(allocator, session_id);
    }

    const send_params = if (existing_session_id != null and prompt.len > 0)
        try renderJsonAlloc(allocator, .{
            .session_id = session_id,
            .prompt = prompt,
            .enable_agent_tools = enable_agent_tools,
            .provider_id = overrides.provider_override,
            .model_override = overrides.model_override,
            .context_window_override = overrides.context_window_override,
            .max_output_tokens = overrides.max_output_tokens,
            .prompt_mode = overrides.prompt_mode.label(),
        })
    else
        try renderJsonAlloc(allocator, .{
            .session_id = session_id,
            .enable_agent_tools = enable_agent_tools,
            .provider_id = overrides.provider_override,
            .model_override = overrides.model_override,
            .context_window_override = overrides.context_window_override,
            .max_output_tokens = overrides.max_output_tokens,
            .prompt_mode = overrides.prompt_mode.label(),
        });
    defer allocator.free(send_params);

    const send_call = try callKernelOrExit(allocator, client, protocol_types.methods.session_send, send_params);
    defer send_call.deinit(allocator);
    const send_result_json = try expectKernelResult(allocator, send_call);
    defer allocator.free(send_result_json);

    var parsed_send = try std.json.parseFromSlice(ParsedSessionSendResult, allocator, send_result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_send.deinit();

    return .{
        .session_id = session_id,
        .output = if (parsed_send.value.session.output) |value| try allocator.dupe(u8, value) else null,
        .failure_reason = if (parsed_send.value.session.failure_reason) |value| try allocator.dupe(u8, value) else null,
    };
}

fn executeHealthViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, options: HealthCliOptions) !void {
    try ensureKernelConfigAvailable(allocator, workspace_root);

    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const call = try callKernelOrExit(allocator, &client, protocol_types.methods.health_get, "{}");
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedHealthResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (options.json_output) {
        const json_payload = try std.fmt.allocPrint(allocator, "{f}\n", .{
            std.json.fmt(parsed.value, .{ .whitespace = .indent_2 }),
        });
        defer allocator.free(json_payload);
        try writeStdout(json_payload);
        return;
    }

    const text_payload = try formatHealthText(allocator, parsed.value);
    defer allocator.free(text_payload);
    try writeStdout(text_payload);
}

/// CLI health rendering / Preserve the kernel's distinct active, idle, queued,
/// and admission counts in stable text output. Why: collapsing idle into
/// available hides queued pressure. Preserves: JSON remains additive and older
/// kernels parse with zero defaults. Evidence: Move 28 CLI projection test.
fn formatHealthText(allocator: std.mem.Allocator, health: ParsedHealthResult) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "VAR1 health\nstatus: {s}\nmodel: {s}\neffort: {s}\nthinking_mode: {s}\ncontext_window_tokens: {d}\nreserve_output_tokens: {d}\nworkspace_root: {s}\nbase_url: {s}\nauth_provider: {s}\nsubscription_plan: {s}\nsubscription_status: {s}\nscheduler_supervisor: {s}\nagent_pool: {d}/{d} running, {d} idle, {d} available, {d} queued, status={s}\ntickets: {d} assigned, {d} in_progress, {d} blocked\nticket_ledger: {s}\n",
        .{
            if (health.ok) "ready" else "unhealthy",
            health.model,
            if (health.effort.len > 0) health.effort else "default",
            if (health.thinking_mode.len > 0) health.thinking_mode else "disabled",
            health.context_window_tokens,
            health.reserve_output_tokens,
            health.workspace_root,
            health.base_url,
            health.auth_provider orelse "unknown",
            health.subscription_plan_label orelse "unknown",
            health.subscription_status orelse "unknown",
            if (health.scheduler_supervisor) "running" else "unavailable",
            health.agent_pool_running,
            health.agent_pool_max,
            health.agent_pool_idle,
            health.agent_pool_available,
            health.agent_pool_queued,
            if (health.agent_pool_healthy) "healthy" else "unavailable",
            health.tickets_assigned,
            health.tickets_in_progress,
            health.tickets_blocked,
            if (health.ticket_ledger_healthy) "healthy" else "unhealthy",
        },
    );
}

fn executeToolsViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, options: ToolsCliOptions) !void {
    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const params_json = try renderJsonAlloc(allocator, .{
        .format = if (options.json_output) "json" else "text",
    });
    defer allocator.free(params_json);

    const call = try callKernelOrExit(allocator, &client, protocol_types.methods.tools_list, params_json);
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedToolsListResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try writeStdout(parsed.value.output);
    if (options.json_output) try writeStdout("\n");
}

fn executeModelsViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, options: ModelsCliOptions) !void {
    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const params = try renderJsonAlloc(allocator, .{
        .provider_id = options.provider,
    });
    defer allocator.free(params);

    const call = try callKernelOrExit(allocator, &client, protocol_types.methods.models_list, params);
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedModelsListResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (options.json_output) {
        const json_payload = try std.fmt.allocPrint(allocator, "{f}\n", .{
            std.json.fmt(parsed.value, .{ .whitespace = .indent_2 }),
        });
        defer allocator.free(json_payload);
        try writeStdout(json_payload);
        return;
    }

    if (!std.mem.eql(u8, parsed.value.status, "ok")) {
        const failure = try std.fmt.allocPrint(
            allocator,
            "model discovery failed\nprovider: {s}\nbase_url: {s}\nstatus: {s}\nerror: {s}\n",
            .{
                parsed.value.provider,
                parsed.value.base_url,
                parsed.value.status,
                parsed.value.error_message orelse "no detail available",
            },
        );
        defer allocator.free(failure);
        try writeStdout(failure);
        return;
    }

    const native_note = if (parsed.value.context_from_native_surface)
        " (context length from provider native surface)"
    else
        "";
    const header = try std.fmt.allocPrint(
        allocator,
        "Available models\nprovider: {s}\nbase_url: {s}{s}\n\n",
        .{ parsed.value.provider, parsed.value.base_url, native_note },
    );
    defer allocator.free(header);
    try writeStdout(header);

    if (parsed.value.models.len == 0) {
        try writeStdout("no models reported by provider\n");
        return;
    }

    for (parsed.value.models) |model| {
        var context_buf: [24]u8 = undefined;
        const context_str: []const u8 = if (model.context_length) |length|
            std.fmt.bufPrint(&context_buf, "{d}", .{length}) catch "unknown"
        else
            "unknown";
        const owned = model.owned_by orelse "-";
        const line = try std.fmt.allocPrint(allocator, "  {s}  (context: {s}, owned_by: {s})\n", .{ model.id, context_str, owned });
        defer allocator.free(line);
        try writeStdout(line);
    }
    try writeStdout("\n");
}

fn executeProvidersViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, options: ProvidersCliOptions) !void {
    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    const call = try callKernelOrExit(allocator, &client, protocol_types.methods.providers_list, "{}");
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedProvidersListResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (options.json_output) {
        const json_payload = try std.fmt.allocPrint(allocator, "{f}\n", .{
            std.json.fmt(parsed.value, .{ .whitespace = .indent_2 }),
        });
        defer allocator.free(json_payload);
        try writeStdout(json_payload);
        return;
    }

    if (!std.mem.eql(u8, parsed.value.status, "ok")) {
        const failure = try std.fmt.allocPrint(
            allocator,
            "provider discovery failed\nactive_provider: {s}\nstatus: {s}\nerror: {s}\n",
            .{
                parsed.value.active_provider,
                parsed.value.status,
                parsed.value.error_message orelse "no detail available",
            },
        );
        defer allocator.free(failure);
        try writeStdout(failure);
        return;
    }

    try writeStdout("Configured providers\nactive: ");
    try writeStdout(parsed.value.active_provider);
    try writeStdout("\n\n");
    for (parsed.value.providers) |provider_entry| {
        const marker = if (provider_entry.active) "*" else " ";
        const expiry = if (provider_entry.expires_at_ms) |value|
            try std.fmt.allocPrint(allocator, " expires_at_ms={d}", .{value})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(expiry);
        const status = provider_entry.subscription_status orelse "";
        const line = try std.fmt.allocPrint(
            allocator,
            "{s} {s}  model={s}  wire={s}  auth={s}  base={s}{s}{s}{s}\n",
            .{
                marker,
                provider_entry.provider_id,
                provider_entry.model,
                provider_entry.wire_api.label(),
                provider_entry.auth_scheme.label(),
                provider_entry.base_url,
                if (status.len > 0) " status=" else "",
                status,
                expiry,
            },
        );
        defer allocator.free(line);
        try writeStdout(line);
    }
}

fn executeScheduleViaKernel(allocator: std.mem.Allocator, workspace_root: []const u8, options: ScheduleCliOptions) !void {
    var client = try stdio_rpc.LocalClient.initInWorkspace(allocator, workspace_root);
    defer client.deinit();

    if (options.job_id) |job_id| {
        const params_json = try renderJsonAlloc(allocator, .{ .job_id = job_id });
        defer allocator.free(params_json);
        const call = try callKernelOrExit(allocator, &client, protocol_types.methods.schedule_get, params_json);
        defer call.deinit(allocator);
        const result_json = try expectKernelResult(allocator, call);
        defer allocator.free(result_json);
        if (options.json_output) {
            try writeStdout(result_json);
            try writeStdout("\n");
            return;
        }
        var parsed = try std.json.parseFromSlice(ParsedScheduleGetResult, allocator, result_json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try writeScheduleSummary(parsed.value.schedule);
        return;
    }

    const params_json = try renderJsonAlloc(allocator, .{ .include_deleted = options.include_deleted });
    defer allocator.free(params_json);
    const call = try callKernelOrExit(allocator, &client, protocol_types.methods.schedule_list, params_json);
    defer call.deinit(allocator);
    const result_json = try expectKernelResult(allocator, call);
    defer allocator.free(result_json);
    if (options.json_output) {
        try writeStdout(result_json);
        try writeStdout("\n");
        return;
    }
    var parsed = try std.json.parseFromSlice(ParsedScheduleListResult, allocator, result_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try writeStdout("VAR1 schedules\n");
    for (parsed.value.schedules) |schedule| try writeScheduleSummary(schedule);
}

fn writeScheduleSummary(schedule: protocol_types.ScheduleSummary) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print("{s}  {s}  {s}  next_due_ms={d}  rev={d}\n", .{
        schedule.id,
        schedule.status,
        schedule.schedule_kind,
        schedule.next_due_at_ms,
        schedule.revision,
    });
    try writer.writeAll("   ");
    try writeTruncated(writer, schedule.title, 96);
    try writer.writeAll("\n");
    try writer.flush();
}

/// Pre-flight the workspace config before any kernel or owner process starts.
/// On failure, print the typed config envelope and exit, so clients observe
/// the real cause (e.g. MissingAuth) instead of a spawned owner dying silently.
pub fn ensureKernelConfigAvailable(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
    const loaded_config = config.loadDefault(allocator, workspace_root) catch |err| {
        try writeConfigLoadErrorEnvelope(err, workspace_root);
        std.process.exit(1);
    };
    loaded_config.deinit(allocator);
}

fn callKernelOrExit(
    allocator: std.mem.Allocator,
    client: *stdio_rpc.LocalClient,
    method: []const u8,
    params_json: []const u8,
) !stdio_rpc.RpcCallResult {
    return client.call(method, params_json) catch |err| {
        try writeKernelTransportErrorEnvelope(allocator, err);
        std.process.exit(1);
    };
}

fn writeSmallFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
}

fn executeSessionsFromStore(allocator: std.mem.Allocator, workspace_root: []const u8, options: SessionsCliOptions) !void {
    const sessions = try session_store.listSessionRecords(allocator, workspace_root);
    defer shared_types.deinitSessionRecords(allocator, sessions);

    const projection = try buildSessionListProjection(allocator, workspace_root, sessions);
    defer projection.deinit(allocator);

    if (options.json_output) {
        const result_json = try renderSessionListJsonFromProjection(allocator, projection);
        defer allocator.free(result_json);
        try writeStdout(result_json);
        try writeStdout("\n");
        return;
    }

    if (projection.summaries.len == 0) {
        try writeStdout("No VAR1 sessions in this workspace.\n");
        return;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll("Recent VAR1 sessions\n");
    const visible_count = @min(options.limit, projection.summaries.len);
    for (projection.summaries[0..visible_count], 0..) |session, index| {
        try writeSessionSummaryLine(writer, index + 1, session);
    }
    if (visible_count < projection.summaries.len) {
        try writer.print("... {d} more session(s). Use var c --limit {d}.\n", .{
            projection.summaries.len - visible_count,
            projection.summaries.len,
        });
    }
    try writer.writeAll("Resume explicitly with: var run --session-id <session-id>\n");
    try writer.flush();
}

pub fn renderSessionListJson(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const sessions = try session_store.listSessionRecords(allocator, workspace_root);
    defer shared_types.deinitSessionRecords(allocator, sessions);

    const projection = try buildSessionListProjection(allocator, workspace_root, sessions);
    defer projection.deinit(allocator);

    return renderSessionListJsonFromProjection(allocator, projection);
}

fn renderSessionListJsonFromProjection(allocator: std.mem.Allocator, projection: SessionListProjection) ![]u8 {
    return renderJsonAlloc(allocator, protocol_types.SessionListResult{
        .sessions = projection.summaries,
    });
}

fn buildSessionListProjection(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    sessions: []const shared_types.SessionRecord,
) !SessionListProjection {
    var summaries = try allocator.alloc(protocol_types.SessionSummary, sessions.len);
    errdefer allocator.free(summaries);

    var outputs = try allocator.alloc(?[]u8, sessions.len);
    errdefer allocator.free(outputs);
    @memset(outputs, null);

    errdefer {
        for (outputs) |maybe_output| {
            if (maybe_output) |output| allocator.free(output);
        }
    }

    for (sessions, 0..) |session, index| {
        outputs[index] = try session_store.readOutput(allocator, workspace_root, session.id);
        summaries[index] = makeCliSessionSummary(session, outputs[index]);
    }

    return .{
        .summaries = summaries,
        .outputs = outputs,
    };
}

fn executeWorkspaceCommand(allocator: std.mem.Allocator, action: WorkspaceCliAction) !void {
    switch (action) {
        .show => {
            const workspace_root = try resolveWorkspaceRoot(allocator);
            defer allocator.free(workspace_root);
            try writeStdout("workspace: ");
            try writeStdout(workspace_root);
            try writeStdout("\n");
        },
        .set => |path| {
            const resolved = try std.fs.cwd().realpathAlloc(allocator, path);
            defer allocator.free(resolved);
            const workspace_file = try installedWorkspaceFilePath(allocator);
            defer allocator.free(workspace_file);
            const parent = std.fs.path.dirname(workspace_file) orelse return error.InvalidArgs;
            std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            try writeSmallFile(workspace_file, resolved);
            try writeStdout("workspace override set: ");
            try writeStdout(resolved);
            try writeStdout("\n");
        },
        .clear => {
            const workspace_file = try installedWorkspaceFilePath(allocator);
            defer allocator.free(workspace_file);
            std.fs.deleteFileAbsolute(workspace_file) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try writeStdout("workspace override cleared\n");
        },
    }
}

/// Operate the single non-secret config owner without mutating auth.json.
fn executeConfigCommand(allocator: std.mem.Allocator, workspace_root: []const u8, action: []const u8) !void {
    if (std.mem.eql(u8, action, "path")) {
        const config_path = try config_file.path(allocator, workspace_root);
        defer allocator.free(config_path);
        try writeStdout(config_path);
        try writeStdout("\n");
        return;
    }

    const config_path = try config_file.ensure(allocator, workspace_root);
    defer allocator.free(config_path);
    if (std.mem.eql(u8, action, "init")) {
        try writeStdout("config: ");
        try writeStdout(config_path);
        try writeStdout("\n");
        return;
    }
    if (std.mem.eql(u8, action, "show")) {
        const content = try fsutil.readTextAlloc(allocator, config_path);
        defer allocator.free(content);
        try writeStdout(content);
        if (content.len == 0 or content[content.len - 1] != '\n') try writeStdout("\n");
        return;
    }
    if (std.mem.eql(u8, action, "validate")) {
        var runtime_policy = try config_file.loadRuntimePolicy(allocator, workspace_root);
        defer runtime_policy.deinit(allocator);
        _ = try config_file.loadContextPolicy(allocator, workspace_root, .{});
        var prompt_policy = try config_file.loadPromptPolicy(allocator, workspace_root, .{});
        defer prompt_policy.deinit(allocator);
        _ = try config_file.loadWireApi(allocator, workspace_root);
        try writeStdout("config valid: ");
        try writeStdout(config_path);
        try writeStdout("\n");
        return;
    }
    try printInvalidArguments("config", config_help_text);
    return error.InvalidArgs;
}

fn executeAuthCommand(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    options: cli_auth.AuthCliOptions,
) !void {
    switch (options.action) {
        .status => {
            var status = try auth_store.readAuthStatus(allocator, workspace_root);
            defer status.deinit(allocator);
            const rendered = try cli_auth.renderAuthStatus(allocator, status, options.json_output);
            defer allocator.free(rendered);
            try writeStdout(rendered);
            try writeStdout("\n");
        },
        .logout => |provider_id| {
            try auth_store.removeProvider(allocator, workspace_root, provider_id);
            if (options.json_output) {
                const rendered = try renderJsonAlloc(allocator, .{
                    .status = "logged_out",
                    .provider_id = provider_id,
                });
                defer allocator.free(rendered);
                try writeStdout(rendered);
                try writeStdout("\n");
            } else {
                try writeStdout("logged out provider: ");
                try writeStdout(provider_id);
                try writeStdout("\n");
            }
        },
        .use => |provider_id| {
            try auth_store.selectProvider(allocator, workspace_root, provider_id);
            if (options.json_output) {
                const rendered = try renderJsonAlloc(allocator, .{
                    .status = "active_provider_changed",
                    .provider_id = provider_id,
                });
                defer allocator.free(rendered);
                try writeStdout(rendered);
                try writeStdout("\n");
            } else {
                try writeStdout("active provider: ");
                try writeStdout(provider_id);
                try writeStdout("\n");
            }
        },
        .login => |login| {
            if (std.mem.eql(u8, login.provider_id, openai_codex.descriptor.provider_id) and
                !login.api_key_stdin and login.api_key_env == null)
            {
                try executeCodexLogin(allocator, workspace_root, options.json_output);
            } else {
                try executeApiKeyLogin(allocator, workspace_root, login, options.json_output);
            }
        },
    }
}

fn executeApiKeyLogin(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    login: cli_auth.LoginOptions,
    json_output: bool,
) !void {
    const base_url = login.base_url orelse provider_profile.defaultBaseUrl(login.provider_id) orelse return error.InvalidArgs;
    const model = login.model orelse return error.InvalidArgs;
    const profile_defaults = provider_profile.defaults(login.provider_id, base_url);
    const effective_auth_scheme = login.auth_scheme orelse profile_defaults.auth_scheme;
    const api_key = if (effective_auth_scheme == .none and login.api_key_env == null and !login.api_key_stdin)
        try allocator.dupe(u8, "")
    else if (login.api_key_env) |name|
        std.process.getEnvVarOwned(allocator, name) catch return error.InvalidArgs
    else
        try readApiKeyFromStdin(allocator);
    defer allocator.free(api_key);

    try auth_store.upsertApiKeyProvider(allocator, workspace_root, .{
        .provider_id = login.provider_id,
        .base_url = base_url,
        .model = model,
        .api_key = api_key,
        .wire_api = login.wire_api orelse profile_defaults.wire_api,
        .auth_scheme = effective_auth_scheme,
    });

    const auth_path = try auth_store.authFilePath(allocator, workspace_root);
    defer allocator.free(auth_path);
    if (json_output) {
        const rendered = try renderJsonAlloc(allocator, .{
            .status = "logged_in",
            .provider_id = login.provider_id,
            .auth_type = "api_key",
            .wire_api = (login.wire_api orelse profile_defaults.wire_api).label(),
            .auth_scheme = effective_auth_scheme.label(),
            .model = model,
            .auth_file = auth_path,
        });
        defer allocator.free(rendered);
        try writeStdout(rendered);
        try writeStdout("\n");
    } else {
        try writeStdout("saved auth provider ");
        try writeStdout(login.provider_id);
        try writeStdout(" model ");
        try writeStdout(model);
        try writeStdout(" to ");
        try writeStdout(auth_path);
        try writeStdout("\n");
    }
}

/// Read exactly one API key line without ever echoing or storing it in a
/// command argument. The caller owns the returned trimmed bytes.
fn readApiKeyFromStdin(allocator: std.mem.Allocator) ![]u8 {
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const raw_line = stdin_reader.interface.takeDelimiterExclusive('\n') catch return error.InvalidArgs;
    const line = std.mem.trim(u8, raw_line, " \t\r\n");
    if (line.len == 0) return error.InvalidArgs;
    return allocator.dupe(u8, line);
}

fn executeCodexLogin(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    json_output: bool,
) !void {
    var flow = try openai_codex.generatePkce(allocator);
    defer flow.deinit(allocator);

    const url = try openai_codex.authorizationUrl(allocator, flow);
    defer allocator.free(url);

    try writeStdout("Open this URL to authenticate VANTARI:\n");
    try writeStdout(url);
    try writeStdout("\n");

    const callback_server = openai_codex.CallbackServer.start(allocator, flow.state) catch null;
    defer if (callback_server) |server| server.deinit();

    if (callback_server != null) {
        try writeStdout("After approval, press Enter here; the localhost callback will be collected automatically.\n");
    } else {
        try writeStdout("Paste the redirect URL (or code#state) here, then press Enter:\n");
    }

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const raw_line = stdin_reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return openai_codex.Error.InvalidAuthorizationInput,
        error.StreamTooLong => return openai_codex.Error.InvalidAuthorizationInput,
        else => return err,
    };
    const line = std.mem.trim(u8, raw_line, " \t\r\n");

    var input = if (line.len > 0)
        try openai_codex.parseAuthorizationInput(allocator, line)
    else if (callback_server) |server|
        server.takeResult() orelse return openai_codex.Error.InvalidAuthorizationInput
    else
        return openai_codex.Error.InvalidAuthorizationInput;
    defer input.deinit(allocator);

    if (input.state == null or !std.mem.eql(u8, input.state.?, flow.state)) {
        return openai_codex.Error.InvalidAuthorizationInput;
    }

    const now_ms = std.time.milliTimestamp();
    var tokens = try openai_codex.exchangeAuthorizationCode(
        allocator,
        .{ .context = null, .postFn = openai_codex.postTokenForm },
        input.code,
        flow.verifier,
        now_ms,
    );
    defer tokens.deinit(allocator);

    const id_token = tokens.id_token orelse return openai_codex.Error.InvalidTokenResponse;
    var claims = try openai_codex.extractClaims(allocator, id_token);
    defer claims.deinit(allocator);

    try auth_store.upsertOAuthProvider(allocator, workspace_root, .{
        .provider_id = openai_codex.descriptor.provider_id,
        .base_url = openai_codex.descriptor.base_url,
        .model = openai_codex.descriptor.model,
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .id_token = tokens.id_token,
        .expires_at_ms = tokens.expires_at_ms,
        .account_id = claims.account_id,
        .user_id = claims.user_id,
        .email = claims.email,
        .plan_type = claims.plan_type,
        .subscription_plan_label = claims.plan_type,
        .subscription_status = "active",
        .subscription_source = openai_codex.descriptor.subscription_source,
        .last_verified_at_ms = now_ms,
    });

    const auth_path = try auth_store.authFilePath(allocator, workspace_root);
    defer allocator.free(auth_path);
    if (json_output) {
        const rendered = try renderJsonAlloc(allocator, .{
            .status = "logged_in",
            .provider_id = openai_codex.descriptor.provider_id,
            .auth_type = "oauth",
            .auth_file = auth_path,
        });
        defer allocator.free(rendered);
        try writeStdout(rendered);
        try writeStdout("\n");
    } else {
        try writeStdout("saved auth provider ");
        try writeStdout(openai_codex.descriptor.provider_id);
        try writeStdout(" to ");
        try writeStdout(auth_path);
        try writeStdout("\n");
    }
}

fn makeCliSessionSummary(session: shared_types.SessionRecord, output: ?[]const u8) protocol_types.SessionSummary {
    return .{
        .session_id = session.id,
        .status = shared_types.statusLabel(session.status),
        .prompt = session.prompt,
        .output = output,
        .parent_session_id = session.parent_session_id,
        .continued_from_session_id = session.continued_from_session_id,
        .display_name = session.display_name,
        .agent_profile = session.agent_profile,
        .execution_receipt = if (session.execution_receipt) |receipt| receipt.*.view() else null,
        .failure_reason = session.failure_reason,
        .created_at_ms = session.created_at_ms,
        .updated_at_ms = session.updated_at_ms,
    };
}

fn writeSessionSummaryLine(writer: anytype, index: usize, session: protocol_types.SessionSummary) !void {
    try writer.print("{d}. {s}  {s}  updated_ms={d}\n", .{
        index,
        session.session_id,
        session.status,
        session.updated_at_ms,
    });

    const title = session.display_name orelse firstLine(session.prompt);
    try writer.writeAll("   ");
    try writeTruncated(writer, title, 96);
    try writer.writeAll("\n");

    if (session.failure_reason) |reason| {
        try writer.writeAll("   failure: ");
        try writeTruncated(writer, firstLine(reason), 96);
        try writer.writeAll("\n");
    }
}

fn firstLine(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len;
    return trimmed[0..end];
}

fn writeTruncated(writer: anytype, value: []const u8, max_bytes: usize) !void {
    if (value.len <= max_bytes) {
        try writer.writeAll(value);
        return;
    }

    const suffix = "...";
    if (max_bytes <= suffix.len) {
        try writer.writeAll(value[0..max_bytes]);
        return;
    }

    try writer.writeAll(value[0 .. max_bytes - suffix.len]);
    try writer.writeAll(suffix);
}

pub fn helpText(command: ?[]const u8) ?[]const u8 {
    const name = command orelse return root_help_text;
    if (std.mem.eql(u8, name, "run")) return run_help_text;
    if (std.mem.eql(u8, name, "c")) return sessions_help_text;
    if (std.mem.eql(u8, name, "continue")) return sessions_help_text;
    if (std.mem.eql(u8, name, "sessions")) return sessions_help_text;
    if (std.mem.eql(u8, name, "workspace")) return workspace_help_text;
    if (std.mem.eql(u8, name, "config")) return config_help_text;
    if (std.mem.eql(u8, name, "auth")) return cli_auth.help_text;
    if (std.mem.eql(u8, name, "providers")) return providers_help_text;
    if (std.mem.eql(u8, name, "health")) return health_help_text;
    if (std.mem.eql(u8, name, "schedule")) return schedule_help_text;
    if (std.mem.eql(u8, name, "serve")) return serve_help_text;
    if (std.mem.eql(u8, name, "tools")) return tools_help_text;
    if (std.mem.eql(u8, name, "models")) return models_help_text;
    if (std.mem.eql(u8, name, "help")) return root_help_text;
    return null;
}

fn parseRunArguments(iter: *std.process.ArgIterator) !ParsedRunArguments {
    var parsed = ParsedRunArguments{};
    var prompt_source_count: u8 = 0;

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt")) {
            parsed.options.prompt = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt-file")) {
            parsed.options.prompt_file = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session-id")) {
            parsed.options.session_id = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-agent-tools")) {
            parsed.options.enable_agent_tools = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt-mode")) {
            const label = iter.next() orelse return error.InvalidArgs;
            parsed.options.prompt_mode = prompt_modes.PromptMode.fromString(label) orelse return error.InvalidArgs;
            continue;
        }
        if (std.mem.eql(u8, arg, "--model")) {
            parsed.options.model_override = iter.next() orelse return error.InvalidArgs;
            continue;
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            parsed.options.provider_override = iter.next() orelse return error.InvalidArgs;
            continue;
        }
        if (std.mem.eql(u8, arg, "--context-window")) {
            const value = iter.next() orelse return error.InvalidArgs;
            parsed.options.context_window_override = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidArgs;
            continue;
        }
        if (std.mem.eql(u8, arg, "--max-output-tokens")) {
            const value = iter.next() orelse return error.InvalidArgs;
            parsed.options.max_output_tokens = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidArgs;
            continue;
        }
        return error.InvalidArgs;
    }

    if (parsed.help_requested) return parsed;
    if (prompt_source_count != 1) return error.InvalidArgs;
    return parsed;
}

fn parseSessionsArguments(iter: *std.process.ArgIterator) !ParsedSessionsArguments {
    var parsed = ParsedSessionsArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--limit")) {
            const limit_text = iter.next() orelse return error.InvalidArgs;
            const limit = std.fmt.parseInt(usize, limit_text, 10) catch return error.InvalidArgs;
            if (limit == 0 or limit > 100) return error.InvalidArgs;
            parsed.options.limit = limit;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseWorkspaceArguments(iter: *std.process.ArgIterator) !ParsedWorkspaceArguments {
    var parsed = ParsedWorkspaceArguments{};
    const action = iter.next() orelse return parsed;
    if (isHelpFlag(action)) {
        parsed.help_requested = true;
        return parsed;
    }
    if (std.mem.eql(u8, action, "show")) {
        if (iter.next() != null) return error.InvalidArgs;
        parsed.action = .show;
        return parsed;
    }
    if (std.mem.eql(u8, action, "set")) {
        const path = iter.next() orelse return error.InvalidArgs;
        if (iter.next() != null) return error.InvalidArgs;
        parsed.action = .{ .set = path };
        return parsed;
    }
    if (std.mem.eql(u8, action, "clear")) {
        if (iter.next() != null) return error.InvalidArgs;
        parsed.action = .clear;
        return parsed;
    }
    return error.InvalidArgs;
}

fn parseHealthArguments(iter: *std.process.ArgIterator) !ParsedHealthArguments {
    var parsed = ParsedHealthArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseServeArguments(iter: *std.process.ArgIterator) !ParsedServeArguments {
    var parsed = ParsedServeArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--port")) {
            const port_text = iter.next() orelse return error.InvalidArgs;
            parsed.options.port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidArgs;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseScheduleArguments(iter: *std.process.ArgIterator) !ParsedScheduleArguments {
    var parsed = ParsedScheduleArguments{};
    const action = iter.next() orelse return error.InvalidArgs;
    if (isHelpFlag(action)) {
        parsed.help_requested = true;
        return parsed;
    }
    if (std.mem.eql(u8, action, "list")) {
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                parsed.options.json_output = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--include-deleted")) {
                parsed.options.include_deleted = true;
                continue;
            }
            return error.InvalidArgs;
        }
        return parsed;
    }
    if (std.mem.eql(u8, action, "get")) {
        parsed.options.job_id = iter.next() orelse return error.InvalidArgs;
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--json")) {
                parsed.options.json_output = true;
                continue;
            }
            return error.InvalidArgs;
        }
        return parsed;
    }
    return error.InvalidArgs;
}

fn parseToolsArguments(iter: *std.process.ArgIterator) !ParsedToolsArguments {
    var parsed = ParsedToolsArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseModelsArguments(iter: *std.process.ArgIterator) !ParsedModelsArguments {
    var parsed = ParsedModelsArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--provider")) {
            parsed.options.provider = iter.next() orelse return error.InvalidArgs;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn parseProvidersArguments(iter: *std.process.ArgIterator) !ParsedProvidersArguments {
    var parsed = ParsedProvidersArguments{};

    while (iter.next()) |arg| {
        if (parsed.help_requested) continue;
        if (isHelpFlag(arg)) {
            parsed.help_requested = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return parsed;
}

fn collectPromptArguments(
    allocator: std.mem.Allocator,
    first: []const u8,
    iter: *std.process.ArgIterator,
) ![]u8 {
    var parts = std.array_list.Managed([]const u8).init(allocator);
    defer parts.deinit();
    try parts.append(first);
    while (iter.next()) |arg| try parts.append(arg);
    return std.mem.join(allocator, " ", parts.items);
}

pub fn resolvePromptInput(
    allocator: std.mem.Allocator,
    prompt: ?[]const u8,
    prompt_file: ?[]const u8,
) ![]u8 {
    if (prompt) |value| return allocator.dupe(u8, value);

    if (prompt_file) |path| {
        const file_text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        errdefer allocator.free(file_text);

        const trimmed = std.mem.trimRight(u8, file_text, "\r\n");
        if (trimmed.len == file_text.len) return file_text;

        const owned = try allocator.dupe(u8, trimmed);
        allocator.free(file_text);
        return owned;
    }

    return allocator.dupe(u8, "");
}

fn expectKernelResult(allocator: std.mem.Allocator, call: stdio_rpc.RpcCallResult) ![]u8 {
    if (call.error_json) |error_json| {
        try writeKernelErrorEnvelope(allocator, error_json);
        std.process.exit(1);
    }

    if (call.result_json) |result_json| return allocator.dupe(u8, result_json);

    try writeStderr("VAR1_ERROR category=kernel_rpc code=MissingResult message=\"kernel response did not include result\"\n");
    std.process.exit(1);
}

fn writeKernelErrorEnvelope(allocator: std.mem.Allocator, error_json: []const u8) !void {
    const envelope = try renderKernelErrorEnvelope(allocator, error_json);
    defer allocator.free(envelope);
    try writeStderr(envelope);
}

fn writeSessionFailureEnvelope(allocator: std.mem.Allocator, session_id: []const u8, failure_reason: []const u8) !void {
    const envelope = try renderSessionFailureEnvelope(allocator, session_id, failure_reason);
    defer allocator.free(envelope);
    try writeStderr(envelope);
}

fn writeSessionRunningEnvelope(allocator: std.mem.Allocator, session_id: []const u8) !void {
    const envelope = try renderSessionRunningEnvelope(allocator, session_id);
    defer allocator.free(envelope);
    try writeStderr(envelope);
}

pub fn renderSessionRunningEnvelope(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "VAR1_STATUS category=session code=Running message=\"provider execution started\" session_id={f}\n",
        .{std.json.fmt(session_id, .{})},
    );
}

pub fn renderSessionFailureEnvelope(allocator: std.mem.Allocator, session_id: []const u8, failure_reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "VAR1_ERROR category=session code={s} message=\"session failed\" session_id={f}\n",
        .{ failure_reason, std.json.fmt(session_id, .{}) },
    );
}

pub fn renderKernelErrorEnvelope(allocator: std.mem.Allocator, error_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, error_json, .{}) catch return std.fmt.allocPrint(
        allocator,
        "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned an unparsable error envelope\"\n",
        .{},
    );
    defer parsed.deinit();

    if (parsed.value != .object) {
        return std.fmt.allocPrint(
            allocator,
            "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned a non-object error envelope\"\n",
            .{},
        );
    }

    const object = parsed.value.object;
    const message = if (object.get("message")) |value|
        if (value == .string) value.string else "kernel returned a remote error"
    else
        "kernel returned a remote error";

    if (object.get("code")) |value| {
        switch (value) {
            .integer => |code| return std.fmt.allocPrint(
                allocator,
                "VAR1_ERROR category=kernel_rpc code={d} message={f}\n",
                .{ code, std.json.fmt(message, .{}) },
            ),
            else => return std.fmt.allocPrint(
                allocator,
                "VAR1_ERROR category=kernel_rpc code=RemoteError message={f}\n",
                .{std.json.fmt(message, .{})},
            ),
        }
    }

    return std.fmt.allocPrint(
        allocator,
        "VAR1_ERROR category=kernel_rpc code=RemoteError message={f}\n",
        .{std.json.fmt(message, .{})},
    );
}

fn writeKernelTransportErrorEnvelope(allocator: std.mem.Allocator, err: anyerror) !void {
    const envelope = try renderKernelTransportErrorEnvelope(allocator, err);
    defer allocator.free(envelope);
    try writeStderr(envelope);
}

pub fn renderKernelTransportErrorEnvelope(allocator: std.mem.Allocator, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "VAR1_ERROR category=kernel_transport code={s} message=\"kernel stdio host closed before returning a valid JSON-RPC response\"\n",
        .{@errorName(err)},
    );
}

fn writeConfigLoadErrorEnvelope(err: anyerror, workspace_root: []const u8) !void {
    try writeStderrFmt(
        "VAR1_ERROR category=config code={s} message=\"workspace is not configured for provider execution\" workspace={f}\n",
        .{ @errorName(err), std.json.fmt(workspace_root, .{}) },
    );
}

fn renderRunResultJson(
    allocator: std.mem.Allocator,
    session_id: []const u8,
    output: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(.{
            .session_id = session_id,
            .output = output,
        }, .{ .whitespace = .indent_2 }),
    });
}

fn renderJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{
        std.json.fmt(value, .{}),
    });
}

test "cli session list projection keeps output slices alive through JSON render" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var session = try session_store.initSession(std.testing.allocator, workspace_root, "resume this session");
    defer session.deinit(std.testing.allocator);
    try session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "assistant output survives projection");

    const sessions = try session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer shared_types.deinitSessionRecords(std.testing.allocator, sessions);

    const projection = try buildSessionListProjection(std.testing.allocator, workspace_root, sessions);
    defer projection.deinit(std.testing.allocator);

    const rendered = try renderJsonAlloc(std.testing.allocator, protocol_types.SessionListResult{
        .sessions = projection.summaries,
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant output survives projection") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, session.id) != null);
}

test "cli health projection preserves pool and ticket pressure for installed consumers" {
    const health = ParsedHealthResult{
        .ok = true,
        .model = "Qwen3.6 35B-A3B",
        .workspace_root = "E:\\VANTARI-ONE",
        .base_url = "http://127.0.0.1:1234/v1",
        .effort = "high",
        .thinking_mode = "enabled",
        .context_window_tokens = 200_000,
        .reserve_output_tokens = 16_000,
        .agent_pool_healthy = true,
        .agent_pool_max = 6,
        .agent_pool_queued = 2,
        .agent_pool_running = 3,
        .agent_pool_idle = 3,
        .agent_pool_available = 1,
        .tickets_unassigned = 4,
        .tickets_assigned = 2,
        .tickets_in_progress = 3,
        .tickets_blocked = 1,
        .tickets_completed = 5,
        .tickets_closed = 2,
        .ticket_ledger_healthy = true,
    };

    const rendered = try renderJsonAlloc(std.testing.allocator, health);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "agent_pool_idle") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "agent_pool_available") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "tickets_blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "ticket_ledger_healthy") != null);

    const text = try formatHealthText(std.testing.allocator, health);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "agent_pool: 3/6 running, 3 idle, 1 available, 2 queued, status=healthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tickets: 2 assigned, 3 in_progress, 1 blocked") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ticket_ledger: healthy") != null);
}

test "cli model selector resolves a known provider and nested gateway model" {
    const resolved = resolveTurnOverrides(.{ .model_override = "openrouter/anthropic/claude-sonnet" });
    try std.testing.expectEqualStrings("openrouter", resolved.provider_override.?);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", resolved.model_override.?);
}

test "cli explicit provider preserves a namespaced model id" {
    const resolved = resolveTurnOverrides(.{
        .provider_override = "openrouter",
        .model_override = "anthropic/claude-sonnet",
    });
    try std.testing.expectEqualStrings("openrouter", resolved.provider_override.?);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", resolved.model_override.?);
}

test "cli explicit provider strips only its own model prefix" {
    const resolved = resolveTurnOverrides(.{
        .provider_override = "ANTHROPIC",
        .model_override = "anthropic/claude-sonnet",
    });
    try std.testing.expectEqualStrings("anthropic", resolved.provider_override.?);
    try std.testing.expectEqualStrings("claude-sonnet", resolved.model_override.?);
}

fn writeStdout(text: []const u8) !void {
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try stdout_writer.interface.writeAll(text);
    try stdout_writer.interface.flush();
}

fn writeStderr(text: []const u8) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.writeAll(text);
    try stderr_writer.interface.flush();
}

fn writeStderrFmt(comptime fmt: []const u8, args: anytype) !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    try stderr_writer.interface.print(fmt, args);
    try stderr_writer.interface.flush();
}

fn printInvalidArguments(command: []const u8, help_text: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "error: invalid arguments for '{s}'.\n\n{s}", .{ command, help_text });
    try writeStderr(message);
}

fn printUnknownCommand(command: []const u8) !void {
    var buffer: [8192]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "error: unknown command '{s}'.\n\n{s}", .{ command, root_help_text });
    try writeStderr(message);
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

pub const testing_hooks = struct {
    pub fn resolveWorkspaceRootForCwd(
        allocator: std.mem.Allocator,
        cwd_abs: []const u8,
        installed_workspace_root: ?[]const u8,
    ) ![]u8 {
        return workspace.resolveFromCwd(allocator, cwd_abs, installed_workspace_root);
    }

    pub fn acceptsConfigMarkerCandidate(is_invocation_root: bool, has_project_marker: bool, has_config_marker: bool) bool {
        return workspace.acceptsConfigMarkerCandidate(is_invocation_root, has_project_marker, has_config_marker);
    }

    pub fn acceptsSessionsCandidate(is_invocation_root: bool, has_project_marker: bool) bool {
        return workspace.acceptsSessionsCandidate(is_invocation_root, has_project_marker);
    }
};
