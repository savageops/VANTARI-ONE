const std = @import("std");
const builtin = @import("builtin");
const module = @import("module.zig");
const registry = @import("registry.zig");
const profile_contract = @import("../agents/profile.zig");
pub const review = @import("review.zig");
const workspace_state_tools = @import("workspace_runtime.zig");
const types = @import("../../shared/types.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const shell_exec = @import("builtin/shell_exec.zig");
const schedule_job = @import("builtin/schedule_job.zig");
const memory = @import("builtin/memory.zig");
pub const skills = @import("builtin/skills.zig");
const agents = @import("builtin/agents.zig");

pub const max_error_arguments_json_echo_bytes: usize = 4096;

pub const Error = module.Error;
pub const CommandOutput = module.CommandOutput;
pub const CommandRunner = module.CommandRunner;
pub const CommandProbe = module.CommandProbe;
pub const CommandOutputStream = module.CommandOutputStream;
pub const CommandLimits = module.CommandLimits;
pub const AgentService = module.AgentService;
pub const AgentTaskRequest = module.AgentTaskRequest;
pub const AgentGroupSnapshot = module.AgentGroupSnapshot;
pub const AgentEventSink = module.AgentEventSink;
pub const ToolEventSink = module.ToolEventSink;
pub const ExecutionContext = module.ExecutionContext;
pub const FileInspectionLedger = module.FileInspectionLedger;
pub const AgentDiscoveryLedger = module.AgentDiscoveryLedger;
pub const DelegationScope = module.DelegationScope;

const agent_tool_definitions = agents.definitions;

const workspace_state_tool_definitions = workspace_state_tools.definitions;
const file_plus_workspace_state_tool_definitions = registry.file_tool_definitions ++ workspace_state_tool_definitions;
const file_plus_agent_tool_definitions = registry.file_tool_definitions ++ agent_tool_definitions;
const all_tool_definitions = file_plus_workspace_state_tool_definitions ++ agent_tool_definitions;
const read_tool_definitions = [_]types.ToolDefinition{
    list_files.definition,
    search_files.definition,
    read_file.definition,
    skills.definition,
    memory.definitions[0],
};
const write_tool_definitions = read_tool_definitions ++ [_]types.ToolDefinition{
    write_file.definition,
    append_file.definition,
    replace_in_file.definition,
    shell_exec.definition,
    memory.definitions[1],
};
const subagent_tool_definitions = write_tool_definitions ++ agent_tool_definitions;
const no_tool_definitions = [_]types.ToolDefinition{};

fn toolDefinitionByName(tool_name: []const u8) ?types.ToolDefinition {
    for (all_tool_definitions) |tool_definition| {
        if (std.mem.eql(u8, tool_definition.name, tool_name)) return tool_definition;
    }

    return null;
}

pub fn workspaceStateRelevant(prompt: []const u8) bool {
    const keywords = [_][]const u8{
        ".var",
        "init_workspace",
        "workspace state",
        "todo slice",
        "session record",
        "changelog",
        "worktree",
        "backup",
        "instruction ingestion",
        "AGENTS.md",
        "tool contracts",
    };

    for (keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(prompt, keyword) != null) return true;
    }

    return false;
}

pub fn builtinDefinitions(include_agent_tools: bool) []const types.ToolDefinition {
    return if (include_agent_tools) file_plus_agent_tool_definitions[0..] else registry.fileDefinitions();
}

pub fn builtinDefinitionsForContext(execution_context: ExecutionContext) []const types.ToolDefinition {
    if (execution_context.orchestrator_only) {
        return if (execution_context.agent_service != null and execution_context.delegation_depth_remaining > 0)
            agent_tool_definitions[0..]
        else
            no_tool_definitions[0..];
    }
    if (execution_context.capability_profile_id) |profile_id| {
        const profile = profile_contract.resolveProfile(profile_id) catch return no_tool_definitions[0..];
        if (std.mem.eql(u8, profile.id, "model_task")) return no_tool_definitions[0..];
        if (std.mem.eql(u8, profile.id, "recon")) return read_tool_definitions[0..];
        if (std.mem.eql(u8, profile.id, "write")) return write_tool_definitions[0..];
        if (std.mem.eql(u8, profile.id, "subagent")) {
            return if (execution_context.agent_service != null and execution_context.delegation_depth_remaining > 0)
                subagent_tool_definitions[0..]
            else
                write_tool_definitions[0..];
        }
        if (!std.mem.eql(u8, profile.id, "root")) return no_tool_definitions[0..];
    }

    if (execution_context.workspace_state_enabled) {
        return if (execution_context.agent_service != null) all_tool_definitions[0..] else file_plus_workspace_state_tool_definitions[0..];
    }

    return builtinDefinitions(execution_context.agent_service != null);
}

pub fn renderCatalog(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().print(
        \\VAR1 built-in tools
        \\Workspace root: {s}
        \\Call contract: pass one JSON object; use only declared fields; inspect ok:false and tool_error_hint before retrying.
        \\
    , .{execution_context.workspace_root});

    for (builtinDefinitionsForContext(execution_context)) |tool_definition| {
        try output.writer().print("- {s}: {s}\n", .{
            tool_definition.name,
            tool_definition.description,
        });
        try output.writer().print("  Review risk: {s}\n", .{review.riskLabel(tool_definition.review_risk)});
        const availability = try registry.resolveAvailability(allocator, execution_context.command_probe, tool_definition.name);
        try output.writer().print("  Availability: {s}\n", .{registry.statusLabel(availability.status)});
        if (availability.dependency) |dependency| {
            try output.writer().print("  Dependency: {s} {s}", .{
                registry.dependencyKindLabel(dependency.kind),
                dependency.name,
            });
            if (availability.dependency_available) |available| {
                try output.writer().print(" ({s})", .{if (available) "available" else "unavailable"});
            }
            try output.writer().writeByte('\n');
        }
        if (tool_definition.example_json) |example_json| {
            try output.writer().print("  Example JSON: {s}\n", .{example_json});
        }
        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().print("  Guidance: {s}\n", .{usage_hint});
        }
    }

    return output.toOwnedSlice();
}

pub fn renderCatalogJson(allocator: std.mem.Allocator, execution_context: ExecutionContext) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"workspace_root\":");
    try output.writer().print("{f}", .{std.json.fmt(execution_context.workspace_root, .{})});
    try output.writer().writeAll(",\"tools\":[");

    const definitions = builtinDefinitionsForContext(execution_context);
    for (definitions, 0..) |tool_definition, index| {
        if (index > 0) try output.writer().writeAll(",");

        try output.writer().writeAll("{\"name\":");
        try output.writer().print("{f}", .{std.json.fmt(tool_definition.name, .{})});
        try output.writer().writeAll(",\"description\":");
        try output.writer().print("{f}", .{std.json.fmt(tool_definition.description, .{})});
        try output.writer().writeAll(",\"parameters_schema\":");
        try output.writer().writeAll(tool_definition.parameters_json);
        try output.writer().writeAll(",\"review_risk\":");
        try output.writer().print("{f}", .{std.json.fmt(review.riskLabel(tool_definition.review_risk), .{})});

        if (tool_definition.example_json) |example_json| {
            try output.writer().writeAll(",\"contract_example\":");
            try output.writer().writeAll(example_json);
        }

        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().writeAll(",\"usage_hint\":");
            try output.writer().print("{f}", .{std.json.fmt(usage_hint, .{})});
        }

        try output.writer().writeAll(",\"availability\":");
        try registry.renderAvailabilityJson(output.writer(), allocator, execution_context.command_probe, tool_definition.name);

        try output.writer().writeAll("}");
    }

    try output.writer().writeAll("]}");
    return output.toOwnedSlice();
}

pub fn toolErrorHint(tool_name: []const u8, error_name: []const u8) ?[]const u8 {
    const is_schema_error = std.mem.eql(u8, error_name, "InvalidArguments") or
        std.mem.eql(u8, error_name, "MissingField") or
        std.mem.eql(u8, error_name, "UnknownField") or
        std.mem.eql(u8, error_name, "DuplicateField") or
        std.mem.eql(u8, error_name, "UnexpectedToken");

    if (is_schema_error) {
        if (std.mem.eql(u8, tool_name, "todo_slice")) {
            return "Use valid JSON. todo_slice upsert requires category, todo_name, status, and objective. The current run already has a runtime-managed todo slice, so skip todo_slice unless you need a separate repo-level execution slice.";
        }

        if (std.mem.eql(u8, tool_name, "session_record")) {
            return "Use valid JSON. session_record upsert requires session_name, status, and objective.";
        }

        if (std.mem.eql(u8, tool_name, "shell_exec")) {
            return "Use mode=argv with argv only, or mode=powershell/shell/bash with command only. On Windows, use PowerShell-native commands such as Select-String and Get-ChildItem for compound queries; do not pipe cmd find/findstr patterns through PowerShell.";
        }

        return "Arguments did not match the tool schema. Repair the JSON object and retry with only the declared fields.";
    }

    if (std.mem.eql(u8, error_name, "PathOutsideWorkspace")) {
        return "The requested path escaped the workspace root. Retry with a workspace-relative path only and never use .. or an absolute path.";
    }

    if (std.mem.eql(u8, error_name, "FileNotInspected")) {
        if (std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "append_file") or std.mem.eql(u8, tool_name, "replace_in_file")) {
            return "Read the exact target with read_file before using write_file, append_file, or replace_in_file. For a new file, call read_file first and use its FileNotFound result as absence proof.";
        }
        return "The target was not inspected through the read ledger before this side effect. Inspect the exact workspace-relative target and retry.";
    }

    if (std.mem.eql(u8, error_name, "ToolPayloadExceeded")) {
        if (std.mem.eql(u8, tool_name, "shell_exec")) {
            return "shell_exec exceeded the stdout/stderr capture budget. Retry with max_output_bytes large enough for the bounded result, or narrow the command output.";
        }
        if (std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "append_file") or std.mem.eql(u8, tool_name, "replace_in_file")) {
            return "The tool payload exceeded the transport reliability budget. Retry with a small write_file seed followed by append_file chunks split on record, syntax, or newline boundaries.";
        }
        return "The tool payload exceeded the reliability budget. Retry with a narrower request or a tool-specific bounded output setting.";
    }

    if (std.mem.eql(u8, error_name, "FileNotFound")) {
        if (std.mem.eql(u8, tool_name, "search_files")) {
            return "The search path or the iex executable was not found. Re-check the workspace-relative path with list_files, or switch to read_file if you already know the target file.";
        }
        if (std.mem.eql(u8, tool_name, "list_files")) {
            return "The requested path was not found. Omit path or use . for the workspace root, then retry with an existing workspace-relative path.";
        }
        if (std.mem.eql(u8, tool_name, "read_file")) {
            return "The requested file was not found. Use list_files or search_files to confirm the workspace-relative path before retrying.";
        }
        if (std.mem.eql(u8, tool_name, "replace_in_file")) {
            return "The requested file was not found. Confirm the existing workspace-relative file path with list_files or read_file before retrying.";
        }
        if (std.mem.eql(u8, tool_name, "shell_exec")) {
            return "shell_exec could not resolve argv[0] or the requested shell executable. Retry with argv mode and an installed executable, or use powershell mode on Windows.";
        }

        return "The requested workspace path or file was not found. Re-check the workspace-relative path before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandTimedOut") and std.mem.eql(u8, tool_name, "shell_exec")) {
        return "shell_exec reached timeout_ms and terminated the process. Retry only with a smaller command scope or an explicitly larger timeout_ms within the declared maximum.";
    }

    if (std.mem.eql(u8, tool_name, "schedule_job") and std.mem.eql(u8, error_name, "ScheduleNotFound")) {
        return "schedule_job could not find an active schedule for job_id. Use action=list or include_deleted=true to inspect durable scheduler state before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandFailed") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files failed. Confirm the search path with list_files and retry with a smaller, valid workspace-relative target, or switch to read_file if you already know the file.";
    }

    if (std.mem.eql(u8, error_name, "ToolUnavailable") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files is unavailable because its required iex executable dependency is not resolvable. Use list_files and read_file until capability availability reports search_files as available.";
    }

    if (std.mem.eql(u8, error_name, "AgentCatalogRequired")) {
        return "Call agents with an empty JSON object first. Select only an id returned by that hot-loaded compact catalog, then call launch_agent or configure_agent.";
    }

    if (std.mem.eql(u8, tool_name, "launch_agent") and std.mem.eql(u8, error_name, "UnsupportedDelegationScope")) {
        return "launch_agent rejected the delegation scope. Use positive scope_depth/contact_budget values; include escalation_reason when either value expands beyond the default bounded child scope.";
    }

    if (std.mem.eql(u8, tool_name, "launch_agent") and std.mem.eql(u8, error_name, "UnsupportedCapabilityProfile")) {
        return "launch_agent rejected an unknown capability profile. Use the current canonical profiles only: root or subagent.";
    }

    return null;
}

pub fn renderToolCallSummary(allocator: std.mem.Allocator, tool_calls: []const types.ToolCall) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    for (tool_calls, 0..) |tool_call, index| {
        if (index > 0) try output.writer().writeAll(", ");
        try output.writer().writeAll(toolCallLogLabel(tool_call.name));
    }

    return output.toOwnedSlice();
}

pub fn toolCallLogLabel(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "agents")) return "agent_catalog_discovery";
    if (std.mem.eql(u8, tool_name, "configure_agent")) return "agent_registry_mutation";
    if (std.mem.eql(u8, tool_name, "launch_agent")) return "child_run_dispatch";
    if (std.mem.eql(u8, tool_name, "agent_status")) return "child_run_status_check";
    if (std.mem.eql(u8, tool_name, "wait_agent")) return "child_run_wait";
    if (std.mem.eql(u8, tool_name, "list_agents")) return "child_run_inventory";
    return tool_name;
}

pub fn renderExecutionError(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    error_name: []const u8,
    arguments_json: []const u8,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"ok\":false,\"tool\":");
    try output.writer().print("{f}", .{std.json.fmt(tool_name, .{})});
    try output.writer().writeAll(",\"error\":");
    try output.writer().print("{f}", .{std.json.fmt(error_name, .{})});
    try writeErrorArgumentsJson(output.writer(), arguments_json);

    if (toolDefinitionByName(tool_name)) |tool_definition| {
        try output.writer().writeAll(",\"parameters_schema\":");
        try output.writer().writeAll(tool_definition.parameters_json);

        if (tool_definition.example_json) |example_json| {
            try output.writer().writeAll(",\"contract_example\":");
            try output.writer().print("{f}", .{std.json.fmt(example_json, .{})});
        }

        if (tool_definition.usage_hint) |usage_hint| {
            try output.writer().writeAll(",\"usage_hint\":");
            try output.writer().print("{f}", .{std.json.fmt(usage_hint, .{})});
        }
    }

    if (toolErrorHint(tool_name, error_name)) |hint| {
        try output.writer().writeAll(",\"hint\":");
        try output.writer().print("{f}", .{std.json.fmt(hint, .{})});
    }

    try output.writer().writeAll("}");
    return output.toOwnedSlice();
}

fn writeErrorArgumentsJson(writer: anytype, arguments_json: []const u8) !void {
    if (arguments_json.len <= max_error_arguments_json_echo_bytes) {
        try writer.writeAll(",\"arguments_json\":");
        try writer.print("{f}", .{std.json.fmt(arguments_json, .{})});
        return;
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(arguments_json, &digest, .{});
    var hex: [digest.len * 2]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[index * 2 + 1] = hex_chars[@as(usize, byte & 0x0f)];
    }

    try writer.writeAll(",\"arguments_json\":");
    try writer.print("{f}", .{std.json.fmt("<omitted oversized tool arguments>", .{})});
    try writer.writeAll(",\"arguments_json_omitted\":true");
    try writer.print(",\"arguments_json_bytes\":{d}", .{arguments_json.len});
    try writer.writeAll(",\"arguments_json_sha256\":");
    try writer.print("{f}", .{std.json.fmt(hex[0..], .{})});
}

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
) ![]u8 {
    return executeWithRunner(allocator, execution_context, tool_call, .{
        .context = null,
        .runFn = runCommand,
        .runWithLimitsFn = runCommandWithLimits,
    });
}

pub fn executeWithRunner(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
    runner: CommandRunner,
) ![]u8 {
    try ensureToolAllowed(execution_context, tool_call.name);

    if (std.mem.eql(u8, tool_call.name, "list_files")) {
        return list_files.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "search_files")) {
        return search_files.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return read_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return write_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "append_file")) {
        return append_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "replace_in_file")) {
        return replace_in_file.execute(allocator, execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "shell_exec")) {
        return shell_exec.executeToolCall(allocator, execution_context, tool_call.arguments_json, runner, tool_call.id);
    }
    if (std.mem.eql(u8, tool_call.name, "schedule_job")) {
        return schedule_job.execute(allocator, execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "skill_info")) {
        return skills.execute(allocator, tool_call.arguments_json);
    }
    if (memory.handles(tool_call.name)) {
        return memory.execute(allocator, execution_context, tool_call.name, tool_call.arguments_json);
    }
    if (workspace_state_tools.handles(tool_call.name)) {
        return workspace_state_tools.execute(allocator, execution_context.workspace_root, tool_call.name, tool_call.arguments_json, runner);
    }
    if (agents.handles(tool_call.name)) {
        return agents.execute(allocator, execution_context, tool_call.name, tool_call.arguments_json);
    }

    return Error.UnknownTool;
}

/// Enforce the same resolved profile used to construct the provider catalog.
fn ensureToolAllowed(execution_context: ExecutionContext, tool_name: []const u8) !void {
    if (execution_context.orchestrator_only) {
        if (!agents.handles(tool_name)) return Error.CapabilityDenied;
        if (!std.mem.eql(u8, tool_name, "agents")) {
            const ledger = execution_context.agent_discovery_ledger orelse return Error.AgentCatalogRequired;
            if (!ledger.hasDiscovered()) return Error.AgentCatalogRequired;
        }
    }
    const profile_id = execution_context.capability_profile_id orelse return;
    const profile = profile_contract.resolveProfile(profile_id) catch return Error.CapabilityDenied;
    const tool_class = toolClassForName(tool_name) orelse return Error.UnknownTool;
    profile_contract.ensureToolClass(profile, tool_class) catch return Error.CapabilityDenied;
    if (tool_class == .delegation and execution_context.delegation_depth_remaining == 0) {
        return Error.CapabilityDenied;
    }
}

pub fn toolClassForName(tool_name: []const u8) ?profile_contract.ToolClass {
    if (std.mem.eql(u8, tool_name, "list_files") or
        std.mem.eql(u8, tool_name, "search_files") or
        std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "skill_info") or
        std.mem.eql(u8, tool_name, "memory_read")) return .file_read;
    if (std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "append_file") or
        std.mem.eql(u8, tool_name, "replace_in_file") or
        std.mem.eql(u8, tool_name, "memory_write")) return .file_write;
    if (std.mem.eql(u8, tool_name, "shell_exec")) return .command;
    if (std.mem.eql(u8, tool_name, "schedule_job")) return .scheduling;
    if (agents.handles(tool_name)) return .delegation;
    if (workspace_state_tools.handles(tool_name)) return .workspace_state;
    return null;
}

fn runCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) anyerror!CommandOutput {
    return runCommandWithLimits(null, allocator, cwd, argv, .{});
}

fn runCommandWithLimits(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!CommandOutput {
    if (builtin.os.tag == .windows) {
        return runCommandWithLimitsWindows(allocator, cwd, argv, limits);
    }

    return runCommandWithLimitsPortable(allocator, cwd, argv, limits);
}

fn runCommandWithLimitsPortable(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!CommandOutput {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    var spawned = true;
    errdefer if (spawned) {
        _ = child.kill() catch {};
    };
    try child.waitForSpawn();

    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;
    child.stderr = null;

    var stdout_collector = PipeCollector{
        .allocator = allocator,
        .file = stdout_file,
        .stream = .stdout,
        .output = &stdout,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    var stderr_collector = PipeCollector{
        .allocator = allocator,
        .file = stderr_file,
        .stream = .stderr,
        .output = &stderr,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    const stdout_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stdout_collector});
    const stderr_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stderr_collector});

    const timeout_ns = @as(u64, @intCast(limits.timeout_ms)) * std.time.ns_per_ms;
    const start_ns = std.time.nanoTimestamp();
    var timed_out = false;
    var term: std.process.Child.Term = undefined;
    while (true) {
        const wait_result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_result.pid == child.id) {
            term = posixStatusToTerm(wait_result.status);
            child.id = undefined;
            spawned = false;
            break;
        }

        const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
        if (elapsed_ns >= timeout_ns) {
            timed_out = true;
            term = try child.kill();
            spawned = false;
            break;
        }

        std.Thread.sleep(@min(timeout_ns - elapsed_ns, 10 * std.time.ns_per_ms));
    }

    stdout_thread.join();
    stderr_thread.join();

    if (stdout_collector.err) |err| return err;
    if (stderr_collector.err) |err| return err;

    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        else => if (timed_out) 1 else return Error.CommandTerminated,
    };

    return .{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .timed_out = timed_out,
        .truncated = stdout_collector.cap_reached or stderr_collector.cap_reached,
    };
}

fn posixStatusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

const PipeCollector = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    stream: module.CommandOutputStream,
    output: *std.ArrayList(u8),
    max_output_bytes: usize,
    callback: module.CommandOutputCallback,
    err: ?anyerror = null,
    cap_reached: bool = false,

    fn run(self: *PipeCollector) void {
        defer self.file.close();
        self.readLoop() catch |err| {
            self.err = err;
        };
    }

    fn readLoop(self: *PipeCollector) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try self.file.read(&buffer);
            if (n == 0) break;
            if (self.output.items.len >= self.max_output_bytes) {
                if (!self.cap_reached) {
                    self.cap_reached = true;
                    try self.callback.onOutput(self.stream, "", true);
                }
                continue;
            }

            const remaining = self.max_output_bytes - self.output.items.len;
            const kept_len = @min(remaining, n);
            const kept = buffer[0..kept_len];
            try self.output.appendSlice(self.allocator, kept);
            const cap_reached = kept_len < n or self.output.items.len >= self.max_output_bytes;
            if (cap_reached) self.cap_reached = true;
            try self.callback.onOutput(self.stream, kept, cap_reached);
        }
    }
};

// =============================================================================
// Windows Job Object process-tree termination (P0-13a)
// =============================================================================
// On Windows, TerminateProcess kills only the direct child. When shell_exec
// runs `cmd /c ...` or `powershell -c ...`, the actual command is a grandchild
// that survives the kill. A Job Object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
// assigns the child at spawn; closing the handle kills the entire tree
// atomically via one kernel operation. This matches the pattern used by
// GitLab Runner and dotnet/runtime for the same reason.

const win = std.os.windows;

extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*win.SECURITY_ATTRIBUTES, lpName: ?win.LPCWSTR) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    hJob: win.HANDLE,
    JobObjectInfoClass: win.DWORD,
    lpJobObjectInfo: *anyopaque,
    cbJobObjectInfoLength: win.DWORD,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn AssignProcessToJobObject(hJob: win.HANDLE, hProcess: win.HANDLE) callconv(.winapi) win.BOOL;

const JobObjectExtendedLimitInformation: win.DWORD = 9;

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: win.DWORD = 0x2000;

const IO_COUNTERS = extern struct {
    ReadOperationCount: win.ULONGLONG,
    WriteOperationCount: win.ULONGLONG,
    OtherOperationCount: win.ULONGLONG,
    ReadTransferCount: win.ULONGLONG,
    WriteTransferCount: win.ULONGLONG,
    OtherTransferCount: win.ULONGLONG,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: win.LARGE_INTEGER,
    PerJobUserTimeLimit: win.LARGE_INTEGER,
    LimitFlags: win.DWORD,
    MinimumWorkingSetSize: win.SIZE_T,
    MaximumWorkingSetSize: win.SIZE_T,
    ActiveProcessLimit: win.DWORD,
    Affinity: win.ULONG_PTR,
    PriorityClass: win.DWORD,
    SchedulingClass: win.DWORD,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: win.SIZE_T,
    JobMemoryLimit: win.SIZE_T,
    PeakProcessMemoryUsed: win.SIZE_T,
    PeakJobMemoryUsed: win.SIZE_T,
};

/// Create a Job Object that kills all assigned processes when its handle is
/// closed. The caller owns the returned handle and must close it (or rely on
/// process exit to close it automatically).
fn createKillOnCloseJob() !win.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return error.JobObjectCreateFailed;

    var info = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    const ok = SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        @ptrCast(&info),
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    );
    if (ok == 0) {
        _ = win.CloseHandle(job);
        return error.JobObjectSetInfoFailed;
    }

    return job;
}

/// Assign a process handle to a Job Object so it (and all its children) are
/// killed when the Job Object handle is closed.
fn assignProcessToJob(job: win.HANDLE, process_handle: win.HANDLE) !void {
    const ok = AssignProcessToJobObject(job, process_handle);
    if (ok == 0) return error.JobObjectAssignFailed;
}

fn runCommandWithLimitsWindows(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!CommandOutput {
    const windows = std.os.windows;

    // Create a Job Object with kill-on-close before spawning the child.
    // This ensures that when we kill the child on timeout, the entire process
    // tree dies — not just the direct child. Grandchildren (the actual command
    // under cmd/powershell/bash) are reaped atomically by the kernel.
    var job_handle: ?win.HANDLE = null;
    if (createKillOnCloseJob()) |job| {
        job_handle = job;
    } else |_| {
        // Job Object creation is best-effort: if it fails (e.g. already in a
        // job group on some Windows versions), fall back to the old single-
        // process TerminateProcess path.
    }
    defer {
        if (job_handle) |job| {
            _ = win.CloseHandle(job);
        }
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    child.create_no_window = true;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    var spawned = true;
    errdefer if (spawned) {
        _ = child.kill() catch {};
    };

    // Assign the child to the Job Object so the entire tree is killable.
    if (job_handle) |job| {
        assignProcessToJob(job, child.id) catch {
            // Assignment can fail if the process is already in another job.
            // The kill-on-close handle close will still terminate what it can.
        };
    }

    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;
    child.stderr = null;

    var stdout_collector = PipeCollector{
        .allocator = allocator,
        .file = stdout_file,
        .stream = .stdout,
        .output = &stdout,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    var stderr_collector = PipeCollector{
        .allocator = allocator,
        .file = stderr_file,
        .stream = .stderr,
        .output = &stderr,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    const stdout_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stdout_collector});
    const stderr_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stderr_collector});

    const timeout_ms: windows.DWORD = @intCast(@min(limits.timeout_ms, std.math.maxInt(windows.DWORD)));
    var timed_out = false;
    windows.WaitForSingleObjectEx(child.id, timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            timed_out = true;
            // Terminate the direct child. If the Job Object is assigned, closing
            // the job handle (in the defer above) will also kill grandchildren.
            // We still TerminateProcess for immediate effect.
            windows.TerminateProcess(child.id, 1) catch {};
            windows.WaitForSingleObjectEx(child.id, windows.INFINITE, false) catch {};
        },
        else => return err,
    };

    stdout_thread.join();
    stderr_thread.join();

    if (stdout_collector.err) |err| return err;
    if (stderr_collector.err) |err| return err;

    const term = try child.wait();
    spawned = false;

    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        else => return Error.CommandTerminated,
    };

    return .{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .timed_out = timed_out,
        .truncated = stdout_collector.cap_reached or stderr_collector.cap_reached,
    };
}

test "tool catalog includes the built-in coding tools" {
    const catalog = try renderCatalog(std.testing.allocator, .{
        .workspace_root = ".",
    });
    defer std.testing.allocator.free(catalog);

    try std.testing.expect(std.mem.indexOf(u8, catalog, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "search_files") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "replace_in_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "shell_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") == null);
}
