const std = @import("std");
const module = @import("module.zig");
const registry = @import("registry.zig");
const profile_contract = @import("../agents/profile.zig");
pub const review = @import("review.zig");
const workspace_state_tools = @import("workspace_runtime.zig");
const process = @import("process.zig");
const types = @import("../../shared/types.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const repair_candidate = @import("builtin/repair_candidate.zig");
const shell_exec = @import("builtin/shell_exec.zig");
const schedule_job = @import("builtin/schedule_job.zig");
const log_ticket = @import("builtin/log_ticket.zig");
const list_processes = @import("builtin/list_processes.zig");
const session_summaries = @import("builtin/session_summaries.zig");
const update_session_summary = @import("builtin/update_session_summary.zig");
const memory = @import("builtin/memory.zig");
const eval_tool = @import("builtin/eval.zig");
pub const dap_tool = @import("builtin/dap.zig");
pub const skills = @import("builtin/skills.zig");
const agents = @import("builtin/agents.zig");
const agent_message = @import("builtin/agent_message.zig");
const ask_user = @import("builtin/ask_user.zig");

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
pub const AgentCapacitySnapshot = module.AgentCapacitySnapshot;
pub const TicketTaskRequest = module.TicketTaskRequest;
pub const ResumeTicketRequest = module.ResumeTicketRequest;
pub const TicketLaunchReceipt = module.TicketLaunchReceipt;
pub const AgentEventSink = module.AgentEventSink;
pub const ToolEventSink = module.ToolEventSink;
pub const ExecutionContext = module.ExecutionContext;
pub const FileInspectionLedger = module.FileInspectionLedger;
pub const AgentEligibilityLedger = module.AgentEligibilityLedger;
pub const DelegationScope = module.DelegationScope;

const agent_tool_definitions = agents.definitions;
const collaboration_tool_definitions = agent_message.definitions;
const interactive_tool_definitions = ask_user.definitions;
const agent_and_collaboration_tool_definitions = agent_tool_definitions ++ collaboration_tool_definitions;
const agent_collaboration_interactive_tool_definitions = agent_and_collaboration_tool_definitions ++ interactive_tool_definitions;
const collaboration_interactive_tool_definitions = collaboration_tool_definitions ++ interactive_tool_definitions;

const workspace_state_tool_definitions = workspace_state_tools.definitions;
const base_tool_definitions = registry.file_tool_definitions ++ dap_tool.definitions ++ [_]types.ToolDefinition{eval_tool.definition};
const file_plus_collaboration_tool_definitions = base_tool_definitions ++ collaboration_tool_definitions;
const file_plus_interactive_tool_definitions = file_plus_collaboration_tool_definitions ++ interactive_tool_definitions;
const file_plus_workspace_state_tool_definitions = file_plus_interactive_tool_definitions ++ workspace_state_tool_definitions;
// Root turns may pause for one bounded operator decision. Keep that capability
// in the normal catalog and in orchestrator-only mode; it does not grant file,
// command, or delegation authority.
const file_plus_agent_tool_definitions = file_plus_interactive_tool_definitions ++ agent_tool_definitions;
const all_tool_definitions = file_plus_workspace_state_tool_definitions ++ agent_tool_definitions;
const read_tool_definitions = [_]types.ToolDefinition{
    list_files.definition,
    search_files.definition,
    read_file.definition,
    skills.definition,
    memory.definitions[0],
    list_processes.definition,
} ++ collaboration_tool_definitions;
const write_tool_definitions = read_tool_definitions ++ [_]types.ToolDefinition{
    write_file.definition,
    append_file.definition,
    replace_in_file.definition,
    repair_candidate.definition,
    shell_exec.definition,
    log_ticket.definition,
    memory.definitions[1],
    eval_tool.definition,
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
    return if (include_agent_tools) file_plus_agent_tool_definitions[0..] else file_plus_interactive_tool_definitions[0..];
}

pub fn builtinDefinitionsForContext(execution_context: ExecutionContext) []const types.ToolDefinition {
    if (execution_context.orchestrator_only) {
        return if (execution_context.agent_service != null and execution_context.delegation_depth_remaining > 0)
            agent_collaboration_interactive_tool_definitions[0..]
        else
            collaboration_interactive_tool_definitions[0..];
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
        const availability = try registry.resolveAvailability(allocator, execution_context.command_probe, tool_definition);
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
        try registry.renderAvailabilityJson(output.writer(), allocator, execution_context.command_probe, tool_definition);

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
        if (std.mem.eql(u8, tool_name, "shell_exec")) {
            return "Use mode=argv with argv only, or mode=powershell/shell/bash with command only. On Windows, use PowerShell-native commands such as Select-String and Get-ChildItem for compound queries; do not pipe cmd find/findstr patterns through PowerShell.";
        }

        return "Arguments did not match the tool schema. Repair the JSON object and retry with only the declared fields.";
    }

    if (std.mem.eql(u8, error_name, "PathOutsideWorkspace")) {
        return "The requested path escaped the workspace root. Retry with a workspace-relative path, or set runtime.full_access_mode=true when the operator explicitly intends an external directory.";
    }

    if (std.mem.eql(u8, error_name, "FileNotInspected")) {
        if (std.mem.eql(u8, tool_name, "write_file") or std.mem.eql(u8, tool_name, "append_file") or std.mem.eql(u8, tool_name, "replace_in_file") or std.mem.eql(u8, tool_name, "repair_candidate")) {
            return "Read the exact target with read_file before using write_file, append_file, or replace_in_file. For a new file, call read_file first and use its FileNotFound result as absence proof.";
        }
        return "The target was not inspected through the read ledger before this side effect. Inspect the exact target and retry.";
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

    if (std.mem.eql(u8, error_name, "RepairBaselineConflict")) {
        return "The repair candidate was recorded but the source baseline changed. Do not apply it; re-read the failure evidence and generate a new candidate against the current baseline.";
    }

    if (std.mem.eql(u8, error_name, "InvalidRepairCandidate")) {
        return "A repair candidate requires a session, failure id, candidate id, existing inspected target, replace_in_file operation, patch body, and expected source baseline.";
    }

    if (std.mem.eql(u8, error_name, "FileNotFound")) {
        if (std.mem.eql(u8, tool_name, "search_files")) {
            return "The search path or the ix executable was not found. Re-check the path with list_files, or switch to read_file if you already know the target file.";
        }
        if (std.mem.eql(u8, tool_name, "list_files")) {
            return "The requested path was not found. Omit path or use . for the workspace root, then retry with an existing path.";
        }
        if (std.mem.eql(u8, tool_name, "read_file")) {
            return "The requested file was not found. Use list_files or search_files to confirm the path before retrying.";
        }
        if (std.mem.eql(u8, tool_name, "replace_in_file")) {
            return "The requested file was not found. Confirm the existing file path with list_files or read_file before retrying.";
        }
        if (std.mem.eql(u8, tool_name, "shell_exec")) {
            return "shell_exec could not resolve argv[0] or the requested shell executable. Retry with argv mode and an installed executable, or use powershell mode on Windows.";
        }

        return "The requested path or file was not found. Re-check the path before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandTimedOut") and std.mem.eql(u8, tool_name, "shell_exec")) {
        return "shell_exec reached timeout_ms and terminated the process. Retry only with a smaller command scope or an explicitly larger timeout_ms within the declared maximum.";
    }

    if (std.mem.eql(u8, tool_name, "schedule_job") and std.mem.eql(u8, error_name, "ScheduleNotFound")) {
        return "schedule_job could not find an active schedule for job_id. Use action=list or include_deleted=true to inspect durable scheduler state before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandFailed") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files failed. Confirm the search path with list_files and retry with a smaller, valid target, or switch to read_file if you already know the file.";
    }

    if (std.mem.eql(u8, error_name, "ToolUnavailable") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files is unavailable because its required ix executable dependency is not resolvable. Use list_files and read_file until capability availability reports search_files as available.";
    }

    if (std.mem.eql(u8, error_name, "CapabilityDenied") and std.mem.eql(u8, tool_name, "eval")) {
        return "eval is trusted code execution and is gated until runtime.full_access_mode=true. Use the bounded file and shell tools in restricted workspace mode, or have the operator explicitly enable full access.";
    }

    if (std.mem.eql(u8, error_name, "SessionRequired") and std.mem.eql(u8, tool_name, "eval")) {
        return "eval requires a canonical session-owned execution context; retry through session/send rather than a detached tool call.";
    }

    if (std.mem.eql(u8, error_name, "AgentEligibilityRequired")) {
        return "Call agents with an empty JSON object first. Select only a route-eligible id from that current specialist/team snapshot, then call launch_agent or configure_agent.";
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
    if (std.mem.eql(u8, tool_name, "agents")) return "agent_eligibility_snapshot";
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
    var tool_execution_context = execution_context;
    tool_execution_context.tool_call_id = tool_call.id;
    try ensureToolAllowed(tool_execution_context, tool_call.name);

    if (std.mem.eql(u8, tool_call.name, "list_files")) {
        return list_files.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "search_files")) {
        return search_files.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "read_file")) {
        return read_file.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "write_file")) {
        return write_file.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "append_file")) {
        return append_file.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "replace_in_file")) {
        return replace_in_file.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "repair_candidate")) {
        return repair_candidate.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "shell_exec")) {
        return shell_exec.executeToolCall(allocator, tool_execution_context, tool_call.arguments_json, runner, tool_call.id);
    }
    if (std.mem.eql(u8, tool_call.name, "eval")) {
        return eval_tool.execute(allocator, tool_execution_context, tool_call.arguments_json, runner);
    }
    if (std.mem.eql(u8, tool_call.name, "schedule_job")) {
        return schedule_job.execute(allocator, tool_execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "log_ticket")) {
        return log_ticket.execute(allocator, tool_execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "list_processes")) {
        return list_processes.execute(allocator, tool_execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "session_summaries")) {
        return session_summaries.execute(allocator, tool_execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "update_session_summary")) {
        return update_session_summary.execute(allocator, tool_execution_context, tool_call.arguments_json);
    }
    if (std.mem.eql(u8, tool_call.name, "skill_info")) {
        return skills.execute(allocator, tool_call.arguments_json);
    }
    if (memory.handles(tool_call.name)) {
        return memory.execute(allocator, tool_execution_context, tool_call.name, tool_call.arguments_json);
    }
    if (agent_message.handles(tool_call.name)) {
        return agent_message.execute(allocator, tool_execution_context, tool_call.arguments_json, tool_call.id);
    }
    if (ask_user.handles(tool_call.name)) {
        return ask_user.execute(allocator, tool_execution_context, tool_call.arguments_json, tool_call.id);
    }
    if (dap_tool.handles(tool_call.name)) {
        return dap_tool.execute(allocator, tool_execution_context, tool_call.name, tool_call.arguments_json, runner);
    }
    if (workspace_state_tools.handles(tool_call.name)) {
        return workspace_state_tools.execute(allocator, tool_execution_context.workspace_root, tool_call.name, tool_call.arguments_json, runner);
    }
    if (agents.handles(tool_call.name)) {
        return agents.execute(allocator, tool_execution_context, tool_call.name, tool_call.arguments_json);
    }

    return Error.UnknownTool;
}

/// Enforce the same resolved profile used to construct the provider catalog.
fn ensureToolAllowed(execution_context: ExecutionContext, tool_name: []const u8) !void {
    if (std.mem.eql(u8, tool_name, "eval") and !execution_context.full_access_mode) {
        return Error.CapabilityDenied;
    }
    if (execution_context.orchestrator_only) {
        if (!agents.handles(tool_name) and !agent_message.handles(tool_name) and !ask_user.handles(tool_name)) return Error.CapabilityDenied;
        if (agents.handles(tool_name) and !std.mem.eql(u8, tool_name, "agents")) {
            const ledger = execution_context.agent_eligibility_ledger orelse return Error.AgentEligibilityRequired;
            if (!ledger.hasCurrent()) return Error.AgentEligibilityRequired;
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
        std.mem.eql(u8, tool_name, "memory_read") or
        std.mem.eql(u8, tool_name, "list_processes") or
        std.mem.eql(u8, tool_name, "session_summaries")) return .file_read;
    if (std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "append_file") or
        std.mem.eql(u8, tool_name, "replace_in_file") or
        std.mem.eql(u8, tool_name, "repair_candidate") or
        std.mem.eql(u8, tool_name, "memory_write") or
        std.mem.eql(u8, tool_name, "log_ticket") or
        std.mem.eql(u8, tool_name, "update_session_summary")) return .file_write;
    if (std.mem.eql(u8, tool_name, "shell_exec") or std.mem.eql(u8, tool_name, "eval") or dap_tool.handles(tool_name)) return .command;
    if (std.mem.eql(u8, tool_name, "schedule_job")) return .scheduling;
    if (ask_user.handles(tool_name)) return .interaction;
    if (agent_message.handles(tool_name)) return .collaboration;
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
    return process.runWithLimits(allocator, cwd, argv, limits);
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
    try std.testing.expect(std.mem.indexOf(u8, catalog, "dap_attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "dap_detach") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") == null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "session_record") == null);
}

test "root catalogs and orchestrator policy retain bounded operator questions" {
    const normal = builtinDefinitions(false);
    const with_agents = builtinDefinitions(true);
    const orchestrator = builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .orchestrator_only = true,
    });

    for ([_][]const types.ToolDefinition{ normal, with_agents, orchestrator }) |definitions| {
        var found = false;
        for (definitions) |definition| {
            if (std.mem.eql(u8, definition.name, "ask_user")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "orchestrator can execute ask_user without gaining artifact tools" {
    const Input = struct {
        fn respond(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: []const u8,
            _: []const u8,
            _: []const u8,
        ) ![]u8 {
            return allocator.dupe(u8, "{\"schema\":\"var1.input_response.v1\",\"request_id\":\"call-root-question\",\"answers\":[]}");
        }
    };

    var call = types.ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call-root-question"),
        .name = try std.testing.allocator.dupe(u8, "ask_user"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"questions\":[{\"prompt\":\"Choose\",\"options\":[{\"label\":\"One\"},{\"label\":\"Two\"}]}]}"),
    };
    defer call.deinit(std.testing.allocator);

    const output = try execute(std.testing.allocator, .{
        .workspace_root = ".",
        .session_id = "root-question",
        .orchestrator_only = true,
        .input_service = .{
            .requestFn = Input.respond,
        },
    }, call);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "var1.input_response.v1") != null);
    var denied_call = types.ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call-read"),
        .name = try std.testing.allocator.dupe(u8, "read_file"),
        .arguments_json = try std.testing.allocator.dupe(u8, "{\"path\":\"README.md\"}"),
    };
    defer denied_call.deinit(std.testing.allocator);
    try std.testing.expectError(Error.CapabilityDenied, execute(std.testing.allocator, .{
        .workspace_root = ".",
        .orchestrator_only = true,
    }, denied_call));
}

test "DAP stays out of read-only recon profiles" {
    const definitions = builtinDefinitionsForContext(.{
        .workspace_root = ".",
        .capability_profile_id = "recon",
    });
    for (definitions) |definition| {
        try std.testing.expect(!std.mem.startsWith(u8, definition.name, "dap_"));
    }
    try std.testing.expectEqual(profile_contract.ToolClass.command, toolClassForName("dap_attach").?);
}
