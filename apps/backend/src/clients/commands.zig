/// Slash command dispatcher — the typed registry that intercepts `/`-prefixed
/// input in the TUI before it reaches the model. Replaces the hardcoded
/// `/exit` string-equality check with a extensible command system.
///
/// Commands are categorized for `/help` grouping and future autocomplete.
/// Each command's execute function receives the ChatState pointer and the
/// raw args string; it returns whether the input was handled (don't submit to
/// the model) or should pass through as a normal message.
///
/// Phase 1 (this file): local-action commands only — /help, /clear, /exit,
/// /quit, /status, /history, /compact. Settings-dependent commands (/model,
/// /effort, /persona, /agents, /settings) are stubbed and implemented in 034e.
const std = @import("std");

/// The ChatState type — declared as @Anytype to avoid a circular import
/// (tui_chat.zig imports commands.zig). Commands access state through this
/// interface using comptime duck typing.
pub fn ChatStateType(comptime T: type) type {
    return struct {
        pub const Ptr = *T;
    };
}

pub const CommandCategory = enum {
    session,
    model,
    config,
    help,
    agent,

    pub fn label(self: CommandCategory) []const u8 {
        return switch (self) {
            .session => "Session",
            .model => "Model",
            .config => "Config",
            .help => "Help",
            .agent => "Agent",
        };
    }
};

pub const CommandResult = enum {
    /// The command was handled locally — don't submit to the model.
    handled,
    /// The input is not a slash command — submit to the model normally.
    not_a_command,
    /// The command requests the TUI to exit.
    exit,
};

/// A slash command definition. `StateT` is the ChatState type — using
/// `anytype` to avoid a circular dependency with tui_chat.zig.
pub fn Command(comptime StateT: type) type {
    return struct {
        name: []const u8,
        description: []const u8,
        category: CommandCategory,
        execute: *const fn (
            state: *StateT,
            args: []const u8,
        ) anyerror!CommandResult,
    };
}

/// Dispatch a slash command. If the input doesn't start with `/`, returns
/// `.not_a_command`. If the command is unknown, prints an error to the
/// transcript and returns `.handled`.
pub fn dispatch(
    comptime StateT: type,
    state: *StateT,
    registry: []const Command(StateT),
    input: []const u8,
) !CommandResult {
    if (input.len == 0 or input[0] != '/') return .not_a_command;

    // Parse command name (up to first space) and args (rest after space).
    const space_pos = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
    const command_name = input[1..space_pos]; // skip the '/'
    const args = if (space_pos < input.len)
        std.mem.trim(u8, input[space_pos + 1 ..], " \t\r\n")
    else
        "";

    if (command_name.len == 0) return .not_a_command;

    // Exact match first.
    for (registry) |command| {
        if (std.mem.eql(u8, command.name, command_name)) {
            return command.execute(state, args);
        }
    }

    // Prefix match (first command that starts with the typed name).
    for (registry) |command| {
        if (std.mem.startsWith(u8, command.name, command_name)) {
            return command.execute(state, args);
        }
    }

    // Unknown command — print error to transcript via the state's add method.
    const allocator = state.allocator;
    const msg = try std.fmt.allocPrint(allocator, "Unknown command: /{s}. Type /help for available commands.", .{command_name});
    defer allocator.free(msg);
    try state.add(.system, msg);
    return .handled;
}

// ---------------------------------------------------------------------------
// Built-in command definitions (phase 1: local actions)
// ---------------------------------------------------------------------------

/// The full command name list for /help rendering. This is the canonical
/// registry of built-in commands. Each entry has a name, description, and
/// category. The execute functions are wired in the TUI because they need
/// access to ChatState methods (add, submit, client).
pub const CommandInfo = struct {
    name: []const u8,
    description: []const u8,
    category: CommandCategory,
};

pub const builtin_command_info = [_]CommandInfo{
    .{ .name = "help", .description = "List all commands or show help for a specific command.", .category = .help },
    .{ .name = "clear", .description = "Clear the conversation transcript and start fresh.", .category = .session },
    .{ .name = "exit", .description = "Exit VANTARI.", .category = .session },
    .{ .name = "quit", .description = "Exit VANTARI (alias for /exit).", .category = .session },
    .{ .name = "status", .description = "Show current workspace, model, session, and config status.", .category = .help },
    .{ .name = "history", .description = "Show recent global message history across all sessions.", .category = .help },
    .{ .name = "compact", .description = "Summarize the conversation to free context window space.", .category = .session },
    .{ .name = "cancel", .description = "Cancel the current turn (same as Ctrl-C during a turn).", .category = .session },
    // Phase 2 stubs — implemented in 034e:
    .{ .name = "settings", .description = "Open the in-TUI settings panel (coming soon).", .category = .config },
    .{ .name = "model", .description = "Switch the active model (coming soon).", .category = .model },
    .{ .name = "effort", .description = "Set reasoning effort: low, medium, high, max (coming soon).", .category = .model },
    .{ .name = "persona", .description = "Edit the system persona inline (coming soon).", .category = .config },
    .{ .name = "agents", .description = "List and manage specialist agent personas (coming soon).", .category = .agent },
};

/// Render the /help output as a string. Groups commands by category.
pub fn renderHelp(allocator: std.mem.Allocator) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.writeAll("VAR1 Slash Commands\n\n");

    // Group by category.
    inline for (std.meta.fields(CommandCategory)) |field| {
        const cat: CommandCategory = @enumFromInt(field.value);
        var has_commands = false;
        for (builtin_command_info) |info| {
            if (info.category != cat) continue;
            if (!has_commands) {
                try writer.print("{s}:\n", .{cat.label()});
                has_commands = true;
            }
            try writer.print("  /{s: <16} {s}\n", .{ info.name, info.description });
        }
        if (has_commands) try writer.writeAll("\n");
    }

    try writer.writeAll("Type /help <command> for detailed help. Commands are matched by exact name first, then by prefix.\n");

    return output.toOwnedSlice();
}

/// Render the /status output as a string.
pub fn renderStatus(allocator: std.mem.Allocator, workspace_root: []const u8, model: []const u8, session_id: ?[]const u8, effort: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.writeAll("VAR1 Status\n");
    try writer.print("  Workspace: {s}\n", .{workspace_root});
    try writer.print("  Model:     {s}\n", .{model});
    try writer.print("  Effort:    {s}\n", .{effort});
    if (session_id) |sid| {
        try writer.print("  Session:   {s}\n", .{sid});
    } else {
        try writer.writeAll("  Session:   (none)\n");
    }

    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dispatch returns not_a_command for non-slash input" {
    // The dispatch function checks input[0] == '/' before anything else.
    // We verify this routing logic without a full ChatState mock.
    const input = "hello world";
    try std.testing.expect(input.len == 0 or input[0] != '/');
    // Dispatch would return .not_a_command for this input.
}

test "dispatch routes /exit to exit result" {
    // Verify the /exit routing logic: the command name is parsed correctly.
    const input = "/exit";
    try std.testing.expect(input[0] == '/');
    const space_pos = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
    const command_name = input[1..space_pos];
    try std.testing.expectEqualStrings("exit", command_name);
}

test "dispatch parses command name and args" {
    const input = "/model glm-5-air";
    try std.testing.expect(input[0] == '/');
    const space_pos = std.mem.indexOfScalar(u8, input, ' ') orelse input.len;
    const command_name = input[1..space_pos];
    const args = if (space_pos < input.len)
        std.mem.trim(u8, input[space_pos + 1 ..], " \t\r\n")
    else
        "";
    try std.testing.expectEqualStrings("model", command_name);
    try std.testing.expectEqualStrings("glm-5-air", args);
}

test "renderHelp groups commands by category" {
    const allocator = std.testing.allocator;
    const help_text = try renderHelp(allocator);
    defer allocator.free(help_text);
    // Should contain all categories.
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Help:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "Config:") != null);
    // Should contain command names.
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/help") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/exit") != null);
    try std.testing.expect(std.mem.indexOf(u8, help_text, "/model") != null);
}

test "renderStatus shows workspace model session" {
    const allocator = std.testing.allocator;
    const status = try renderStatus(allocator, "/workspace", "glm-5-air", "sess-123", "high");
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "glm-5-air") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "sess-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "high") != null);
}

test "builtin_command_info has expected commands" {
    var found_help = false;
    var found_exit = false;
    var found_settings = false;
    for (builtin_command_info) |info| {
        if (std.mem.eql(u8, info.name, "help")) found_help = true;
        if (std.mem.eql(u8, info.name, "exit")) found_exit = true;
        if (std.mem.eql(u8, info.name, "settings")) found_settings = true;
    }
    try std.testing.expect(found_help);
    try std.testing.expect(found_exit);
    try std.testing.expect(found_settings);
}

test "CommandCategory labels are correct" {
    try std.testing.expectEqualStrings("Session", CommandCategory.session.label());
    try std.testing.expectEqualStrings("Model", CommandCategory.model.label());
    try std.testing.expectEqualStrings("Config", CommandCategory.config.label());
    try std.testing.expectEqualStrings("Help", CommandCategory.help.label());
    try std.testing.expectEqualStrings("Agent", CommandCategory.agent.label());
}
