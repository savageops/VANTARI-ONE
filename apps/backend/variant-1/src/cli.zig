const std = @import("std");
const agents = @import("agents.zig");
const config = @import("config.zig");
const protocol_types = @import("protocol_types.zig");
const provider = @import("provider.zig");
const stdio_rpc = @import("stdio_rpc.zig");
const web = @import("web.zig");

// TODO: Keep the CLI small and operator-focused.

const RunCliOptions = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
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

const HealthCliOptions = struct {
    json_output: bool = false,
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

const ParsedHealthArguments = struct {
    options: HealthCliOptions = .{},
    help_requested: bool = false,
};

const ParsedSessionCreateResult = struct {
    session_id: []const u8,
    state: []const u8,
};

const ParsedSessionSendResult = struct {
    session_id: []const u8,
    task_id: []const u8,
    state: []const u8,
    answer: []const u8,
};

const ParsedHealthResult = struct {
    ok: bool,
    model: []const u8,
    workspace_root: []const u8,
    openai_base_url: []const u8,
};

const ParsedToolsListResult = struct {
    format: []const u8,
    output: []const u8,
};

pub const root_help_text =
    \\VAR1 Zig Harness
    \\
    \\Usage:
    \\  VAR1 <command> [flags]
    \\
    \\Commands:
    \\  run      Execute a prompt or resume a canonical task.
    \\  health   Report local runtime configuration and readiness metadata.
    \\  serve    Start the local workbench HTTP server.
    \\  tools    Print the built-in tool catalog and tool schemas.
    \\  help     Print help for a command.
    \\
    \\Examples:
    \\  VAR1 run --prompt "Summarize src/cli.zig."
    \\  VAR1 run --prompt-file .\prompt.txt --json
    \\  VAR1 run --task-id task-1234567890abcdef
    \\  VAR1 health
    \\  VAR1 serve --host 127.0.0.1 --port 4310
    \\  VAR1 tools --json
    \\
    \\Notes:
    \\  zig build run -- <command> ... accepts the same command and flag surface.
    \\  VAR1 reads .env from the current workspace for run, health, serve, and tools execution.
    \\  Use VAR1 help <command> or VAR1 <command> --help for command-specific details.
    \\
;

pub const run_help_text =
    \\Usage:
    \\  VAR1 run --prompt <text> [--json] [--no-agent-tools]
    \\  VAR1 run --prompt-file <path> [--json] [--no-agent-tools]
    \\  VAR1 run --task-id <task-id> [--json] [--no-agent-tools]
    \\
    \\Flags:
    \\  --prompt <text>         Execute an inline prompt.
    \\  --prompt-file <path>    Read the prompt from a file and trim trailing newlines.
    \\  --task-id <task-id>     Resume an existing canonical task and reuse its stored prompt.
    \\  --json                  Emit {"task_id","answer"} instead of plain text.
    \\  --no-agent-tools        Hide launch_agent, agent_status, wait_agent, and list_agents from the model.
    \\  -h, --help              Print help for the run command.
    \\
    \\Rules:
    \\  Exactly one prompt source is allowed: --prompt, --prompt-file, or --task-id.
    \\  When --task-id is provided, VAR1 resumes the stored task prompt and does not accept a new prompt source.
    \\
    \\Examples:
    \\  VAR1 run --prompt "List the files under src."
    \\  VAR1 run --prompt-file .\delegated-prompt.txt --json
    \\  VAR1 run --task-id task-1776778021956-42e781c4c8b4efb8
    \\
;

pub const health_help_text =
    \\Usage:
    \\  VAR1 health [--json]
    \\
    \\Flags:
    \\  --json                  Emit {"ok","model","workspace_root","openai_base_url"} instead of plain text.
    \\  -h, --help              Print help for the health command.
    \\
    \\Behavior:
    \\  health reports the loaded local runtime configuration without sending a model request.
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
    \\  --host <host>           Bind address for the local workbench HTTP server. Default: 127.0.0.1
    \\  --port <port>           Bind port for the local workbench HTTP server. Default: 4310
    \\  -h, --help              Print help for the serve command.
    \\
    \\Routes:
    \\  GET  /                      Embedded workbench HTML
    \\  GET  /api/health            Active model and workspace root
    \\  GET  /api/tasks             Canonical task list
    \\  POST /api/tasks             Create and launch a canonical task
    \\  GET  /api/tasks/:id         Canonical task detail
    \\  GET  /api/tasks/:id/turns   Canonical transcript turns for the task id
    \\  GET  /api/tasks/:id/journal Canonical journal history
    \\  POST /api/tasks/:id/messages Append a new user message onto the same completed task id
    \\  POST /api/tasks/:id/resume  Resume the same task id when it is not running
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
    \\  --json                  Emit machine-readable tool contracts for the current default catalog.
    \\  -h, --help              Print help for the tools command.
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
    \\        "usage_hint": "..."
    \\      }
    \\    ]
    \\  }
    \\
    \\Notes:
    \\  The default tools catalog shows the same file and agent tools exposed for ordinary coding prompts.
    \\  Harness-domain tools remain relevance-gated and are enabled only for explicitly harness-related tasks.
    \\
    \\Examples:
    \\  VAR1 tools
    \\  VAR1 tools --json
    \\
;

pub fn main(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    _ = iter.next();
    const command = iter.next() orelse {
        try writeStdout(root_help_text);
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
            if (isHelpFlag(topic)) {
                try writeStdout(root_help_text);
                return;
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
        try executeRunViaKernel(allocator, parsed.options);
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
        try executeHealthViaKernel(allocator, parsed.options);
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

        const loaded_config = try config.loadDefault(allocator, ".");
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
        };
        try web.serve(allocator, loaded_config, .{
            .host = parsed.options.host,
            .port = parsed.options.port,
            .transport = transport,
        });
        return;
    }

    if (std.mem.eql(u8, command, "kernel-stdio")) {
        const loaded_config = try config.loadDefault(allocator, ".");
        defer loaded_config.deinit(allocator);

        const transport = provider.Transport{
            .context = null,
            .sendFn = provider.httpSend,
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
        try executeToolsViaKernel(allocator, parsed.options);
        return;
    }

    try printUnknownCommand(command);
    return error.InvalidArgs;
}

fn executeRunViaKernel(allocator: std.mem.Allocator, run_options: RunCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const initialize_result_json = try client.call(protocol_types.methods.initialize, "{}");
    defer allocator.free(initialize_result_json);

    const prompt = if (run_options.task_id == null)
        try resolvePromptInput(allocator, run_options.prompt, run_options.prompt_file)
    else
        null;
    defer if (prompt) |value| allocator.free(value);

    const create_params = try std.json.stringifyAlloc(allocator, .{
        .prompt = prompt,
        .task_id = run_options.task_id,
        .enable_agent_tools = run_options.enable_agent_tools,
    }, .{});
    defer allocator.free(create_params);

    const create_result_json = try client.call(protocol_types.methods.session_create, create_params);
    defer allocator.free(create_result_json);

    var parsed_create = try std.json.parseFromSlice(ParsedSessionCreateResult, allocator, create_result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_create.deinit();
    _ = parsed_create.value.state;

    const send_params = try std.json.stringifyAlloc(allocator, .{
        .session_id = parsed_create.value.session_id,
    }, .{});
    defer allocator.free(send_params);

    const send_result_json = try client.call(protocol_types.methods.session_send, send_params);
    defer allocator.free(send_result_json);

    var parsed_send = try std.json.parseFromSlice(ParsedSessionSendResult, allocator, send_result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed_send.deinit();
    _ = parsed_send.value.session_id;
    _ = parsed_send.value.state;

    const json_payload = try renderRunResultJson(allocator, .{
        .task_id = parsed_send.value.task_id,
        .answer = parsed_send.value.answer,
    });
    defer allocator.free(json_payload);

    if (run_options.json_output) {
        try writeStdout(json_payload);
        try writeStdout("\n");
        return;
    }

    try writeStdout(parsed_send.value.answer);
    try writeStdout("\n");
}

fn executeHealthViaKernel(allocator: std.mem.Allocator, options: HealthCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const result_json = try client.call(protocol_types.methods.health_get, "{}");
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedHealthResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    _ = parsed.value.ok;

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
        "VAR1 health\nstatus: ready\nmodel: {s}\nworkspace_root: {s}\nopenai_base_url: {s}\n",
        .{
            parsed.value.model,
            parsed.value.workspace_root,
            parsed.value.openai_base_url,
        },
    );
    defer allocator.free(text_payload);
    try writeStdout(text_payload);
}

fn executeToolsViaKernel(allocator: std.mem.Allocator, options: ToolsCliOptions) !void {
    var client = try stdio_rpc.LocalClient.init(allocator);
    defer client.deinit();

    const format = if (options.json_output) "json" else "text";
    const params_json = try std.json.stringifyAlloc(allocator, .{
        .format = format,
    }, .{});
    defer allocator.free(params_json);

    const result_json = try client.call(protocol_types.methods.tools_list, params_json);
    defer allocator.free(result_json);

    var parsed = try std.json.parseFromSlice(ParsedToolsListResult, allocator, result_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    _ = parsed.value.format;

    try writeStdout(parsed.value.output);
    if (options.json_output) try writeStdout("\n");
}

pub fn helpText(command: ?[]const u8) ?[]const u8 {
    const name = command orelse return root_help_text;
    if (std.mem.eql(u8, name, "run")) return run_help_text;
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
        if (std.mem.eql(u8, arg, "--json")) {
            parsed.options.json_output = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-agent-tools")) {
            parsed.options.enable_agent_tools = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "--task-id")) {
            parsed.options.task_id = iter.next() orelse return error.InvalidArgs;
            prompt_source_count += 1;
            continue;
        }
        return error.InvalidArgs;
    }

    if (parsed.help_requested) return parsed;
    if (prompt_source_count != 1) return error.InvalidArgs;
    return parsed;
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

fn renderRunResultJson(allocator: std.mem.Allocator, result: anytype) ![]u8 {
    const payload = .{
        .task_id = result.task_id,
        .answer = result.answer,
    };

    return std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(payload, .{ .whitespace = .indent_2 }),
    });
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
