const std = @import("std");
const module = @import("module.zig");
const registry = @import("registry.zig");
pub const review = @import("review.zig");
const workspace_state_tools = @import("workspace_runtime.zig");
const types = @import("../../shared/types.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const agents = @import("builtin/agents.zig");

pub const Error = module.Error;
pub const CommandOutput = module.CommandOutput;
pub const CommandRunner = module.CommandRunner;
pub const CommandProbe = module.CommandProbe;
pub const AgentService = module.AgentService;
pub const ExecutionContext = module.ExecutionContext;
pub const DelegationScope = module.DelegationScope;

const agent_tool_definitions = agents.definitions;

const workspace_state_tool_definitions = workspace_state_tools.definitions;
const file_plus_workspace_state_tool_definitions = registry.file_tool_definitions ++ workspace_state_tool_definitions;
const file_plus_agent_tool_definitions = registry.file_tool_definitions ++ agent_tool_definitions;
const all_tool_definitions = file_plus_workspace_state_tool_definitions ++ agent_tool_definitions;

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
        "memories.md",
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

        return "Arguments did not match the tool schema. Repair the JSON object and retry with only the declared fields.";
    }

    if (std.mem.eql(u8, error_name, "PathOutsideWorkspace")) {
        return "The requested path escaped the workspace root. Retry with a workspace-relative path only and never use .. or an absolute path.";
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

        return "The requested workspace path or file was not found. Re-check the workspace-relative path before retrying.";
    }

    if (std.mem.eql(u8, error_name, "CommandFailed") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files failed. Confirm the search path with list_files and retry with a smaller, valid workspace-relative target, or switch to read_file if you already know the file.";
    }

    if (std.mem.eql(u8, error_name, "ToolUnavailable") and std.mem.eql(u8, tool_name, "search_files")) {
        return "search_files is unavailable because its required iex executable dependency is not resolvable. Use list_files and read_file until capability availability reports search_files as available.";
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
    try output.writer().writeAll(",\"arguments_json\":");
    try output.writer().print("{f}", .{std.json.fmt(arguments_json, .{})});

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

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
) ![]u8 {
    return executeWithRunner(allocator, execution_context, tool_call, .{
        .context = null,
        .runFn = runCommand,
    });
}

pub fn executeWithRunner(
    allocator: std.mem.Allocator,
    execution_context: ExecutionContext,
    tool_call: types.ToolCall,
    runner: CommandRunner,
) ![]u8 {
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
    if (workspace_state_tools.handles(tool_call.name)) {
        return workspace_state_tools.execute(allocator, execution_context.workspace_root, tool_call.name, tool_call.arguments_json, runner);
    }
    if (agents.handles(tool_call.name)) {
        return agents.execute(allocator, execution_context, tool_call.name, tool_call.arguments_json);
    }

    return Error.UnknownTool;
}

fn runCommand(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
) anyerror!CommandOutput {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });

    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => return Error.CommandTerminated,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
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
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Example JSON: {\"pattern\":\"read_file\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_results\":20}") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "todo_slice") == null);
}
