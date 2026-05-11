const std = @import("std");
const agents = @import("../core/agents/service.zig");
const config = @import("../core/config/resolver.zig");
const session_store = @import("../core/sessions/store.zig");
const protocol_types = @import("../shared/protocol/types.zig");
const provider = @import("../core/providers/openai_compatible.zig");
const stdio_rpc = @import("../host/stdio_rpc.zig");
const shared_types = @import("../shared/types.zig");
const web = @import("../host/http_bridge.zig");

const RunCliOptions = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    json_output: bool = false,
    enable_agent_tools: bool = true,
};

const ServeCliOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4310,
};

const ToolsCliOptions = struct {
    json_output: bool = false,
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
};

const ParsedToolsListResult = struct {
    format: []const u8,
    output: []const u8,
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
    \\  workspace Show or set an explicit installed-client workspace override.
    \\  serve    Start the HTTP bridge for /rpc, /events, and /api/health.
    \\  tools    Print the built-in tool catalog and schemas through the kernel protocol.
    \\  help     Print help for a command.
    \\
    \\Examples:
    \\  vantari
    \\  vantari -c
    \\  vantari "List the files under src."
    \\  vantari c
    \\  vantari workspace show
    \\  vantari workspace set E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend
    \\  var c
    \\  VAR1 run --prompt "Summarize src/cli.zig."
    \\  VAR1 run --prompt-file .\prompt.txt --json
    \\  VAR1 run --session-id session-1776778021956-42e781c4c8b4efb8
    \\  VAR1 health
    \\  VAR1 serve --host 127.0.0.1 --port 4310
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
    \\  var run --prompt <text> [--json] [--no-agent-tools]
    \\  var run --prompt-file <path> [--json] [--no-agent-tools]
    \\  var run --session-id <session-id> [--json] [--no-agent-tools]
    \\  VAR1 run --prompt <text> [--json] [--no-agent-tools]
    \\  VAR1 run --prompt-file <path> [--json] [--no-agent-tools]
    \\  VAR1 run --session-id <session-id> [--json] [--no-agent-tools]
    \\
    \\Flags:
    \\  --prompt <text>           Execute an inline prompt as a new session.
    \\  --prompt-file <path>      Read the prompt from a file and trim trailing newlines.
    \\  --session-id <session-id> Resume an existing canonical session and reuse its stored prompt.
    \\  --json                    Emit {"session_id","output"} instead of plain text.
    \\  --no-agent-tools          Hide launch_agent, agent_status, wait_agent, and list_agents from the model.
    \\  -h, --help                Print help for the run command.
    \\
    \\Rules:
    \\  Exactly one prompt source is allowed: --prompt, --prompt-file, or --session-id.
    \\  When --session-id is provided, VAR1 resumes the stored session prompt and does not accept a new prompt source.
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
    \\  --json                    Emit {"ok","model","workspace_root","base_url","auth_provider"} instead of plain text.
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
    \\  VAR1 serve [--host <host>] [--port <port>]
    \\
    \\Flags:
    \\  --host <host>             Bind address for the local bridge. Default: 127.0.0.1
    \\  --port <port>             Bind port for the local bridge. Default: 4310
    \\  -h, --help                Print help for the serve command.
    \\
    \\Routes:
    \\  POST /rpc                 JSON-RPC bridge to the hidden kernel stdio host
    \\  GET  /events              Server-sent events for session notifications
    \\  GET  /api/health          Thin readiness alias for scripts and operators
    \\
    \\Example:
    \\  VAR1 serve --host 127.0.0.1 --port 4310
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
        const loaded_config = config.loadDefault(allocator, workspace_root) catch |err| {
            try writeConfigLoadErrorEnvelope(err, workspace_root);
            std.process.exit(1);
        };
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
            .streamFn = provider.httpSendStreaming,
        };
        try web.serve(allocator, loaded_config, .{
            .host = parsed.options.host,
            .port = parsed.options.port,
            .transport = transport,
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
        };
        var agent_service = agents.Service.init(&loaded_config);
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
        const turn = try executePromptTurn(allocator, &client, active_session_id, prompt, true, .stderr);
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
        })
    else
        try renderJsonAlloc(allocator, .{
            .session_id = session_id,
            .enable_agent_tools = enable_agent_tools,
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

    const text_payload = try std.fmt.allocPrint(
        allocator,
        "VAR1 health\nstatus: ready\nmodel: {s}\nworkspace_root: {s}\nbase_url: {s}\nauth_provider: {s}\nsubscription_plan: {s}\nsubscription_status: {s}\n",
        .{
            parsed.value.model,
            parsed.value.workspace_root,
            parsed.value.base_url,
            parsed.value.auth_provider orelse "unknown",
            parsed.value.subscription_plan_label orelse "unknown",
            parsed.value.subscription_status orelse "unknown",
        },
    );
    defer allocator.free(text_payload);
    try writeStdout(text_payload);
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

fn ensureKernelConfigAvailable(allocator: std.mem.Allocator, workspace_root: []const u8) !void {
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

fn resolveWorkspaceRoot(allocator: std.mem.Allocator) ![]u8 {
    const env_workspace_maybe = std.process.getEnvVarOwned(allocator, "VANTARI_WORKSPACE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_workspace_maybe) |env_workspace| {
        defer allocator.free(env_workspace);
        const resolved = try std.fs.cwd().realpathAlloc(allocator, env_workspace);
        return resolved;
    }

    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_abs);

    const installed_workspace_root = try readInstalledWorkspaceRoot(allocator);
    defer if (installed_workspace_root) |value| allocator.free(value);

    return resolveWorkspaceRootFromCwd(allocator, cwd_abs, installed_workspace_root);
}

fn resolveWorkspaceRootFromCwd(
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    installed_workspace_root: ?[]const u8,
) ![]u8 {
    var fallback_sessions_root: ?[]u8 = null;
    errdefer if (fallback_sessions_root) |value| allocator.free(value);

    var current = try allocator.dupe(u8, cwd_abs);
    defer allocator.free(current);

    while (true) {
        const is_invocation_root = std.mem.eql(u8, current, cwd_abs);
        const has_project_marker = try workspaceHasProjectMarker(allocator, current);
        const has_config_marker = try workspaceHasConfigMarker(allocator, current);
        if (shouldUseConfigMarkerForCandidate(is_invocation_root, has_project_marker, has_config_marker)) {
            return allocator.dupe(u8, current);
        }
        if (fallback_sessions_root == null and shouldUseSessionsForCandidate(is_invocation_root, has_project_marker) and try workspaceHasSessions(allocator, current)) {
            fallback_sessions_root = try allocator.dupe(u8, current);
        }
        if (has_project_marker) return allocator.dupe(u8, current);

        const backend_candidate = try std.fs.path.join(allocator, &.{ current, "apps", "backend" });
        defer allocator.free(backend_candidate);
        if (try workspaceHasConfigMarker(allocator, backend_candidate)) return allocator.dupe(u8, backend_candidate);
        if (fallback_sessions_root == null and try workspaceHasSessions(allocator, backend_candidate)) {
            fallback_sessions_root = try allocator.dupe(u8, backend_candidate);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    if (fallback_sessions_root) |value| {
        fallback_sessions_root = null;
        return value;
    }

    if (installed_workspace_root) |installed_workspace| return allocator.dupe(u8, installed_workspace);

    return allocator.dupe(u8, cwd_abs);
}

fn shouldUseConfigMarkerForCandidate(
    is_invocation_root: bool,
    has_project_marker: bool,
    has_config_marker: bool,
) bool {
    return has_config_marker and (is_invocation_root or has_project_marker);
}

fn shouldUseSessionsForCandidate(is_invocation_root: bool, has_project_marker: bool) bool {
    return is_invocation_root or has_project_marker;
}

fn workspaceHasConfigMarker(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const env_path = try std.fs.path.join(allocator, &.{ workspace_root, ".env" });
    defer allocator.free(env_path);
    if (fileExistsAbsolute(env_path)) return true;

    const auth_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "auth", "auth.json" });
    defer allocator.free(auth_path);
    return fileExistsAbsolute(auth_path);
}

fn workspaceHasSessions(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const sessions_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "sessions" });
    defer allocator.free(sessions_path);
    if (!fileExistsAbsolute(sessions_path)) return false;

    var dir = std.fs.openDirAbsolute(sessions_path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) return true;
    }
    return false;
}

fn workspaceHasProjectMarker(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const agents_path = try std.fs.path.join(allocator, &.{ workspace_root, "AGENTS.md" });
    defer allocator.free(agents_path);
    if (fileExistsAbsolute(agents_path)) return true;

    const git_path = try std.fs.path.join(allocator, &.{ workspace_root, ".git" });
    defer allocator.free(git_path);
    return fileExistsAbsolute(git_path);
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn readInstalledWorkspaceRoot(allocator: std.mem.Allocator) !?[]u8 {
    const workspace_file = try installedWorkspaceFilePath(allocator);
    defer allocator.free(workspace_file);
    if (!fileExistsAbsolute(workspace_file)) return null;

    const raw = std.fs.openFileAbsolute(workspace_file, .{}) catch return null;
    defer raw.close();
    const content = try raw.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);
    const workspace_root = std.mem.trim(u8, content, " \t\r\n");
    if (workspace_root.len == 0) return null;
    if (try workspaceHasConfigMarker(allocator, workspace_root)) {
        const resolved = try allocator.dupe(u8, workspace_root);
        return resolved;
    }
    if (try workspaceHasSessions(allocator, workspace_root)) {
        const resolved = try allocator.dupe(u8, workspace_root);
        return resolved;
    }
    return null;
}

fn installedWorkspaceFilePath(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidArgs;
    return std.fs.path.join(allocator, &.{ exe_dir, "workspace.txt" });
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
    if (std.mem.eql(u8, name, "health")) return health_help_text;
    if (std.mem.eql(u8, name, "serve")) return serve_help_text;
    if (std.mem.eql(u8, name, "tools")) return tools_help_text;
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
        if (std.mem.eql(u8, arg, "--host")) {
            parsed.options.host = iter.next() orelse return error.InvalidArgs;
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
        return resolveWorkspaceRootFromCwd(allocator, cwd_abs, installed_workspace_root);
    }

    pub fn acceptsConfigMarkerCandidate(is_invocation_root: bool, has_project_marker: bool, has_config_marker: bool) bool {
        return shouldUseConfigMarkerForCandidate(is_invocation_root, has_project_marker, has_config_marker);
    }

    pub fn acceptsSessionsCandidate(is_invocation_root: bool, has_project_marker: bool) bool {
        return shouldUseSessionsForCandidate(is_invocation_root, has_project_marker);
    }
};
