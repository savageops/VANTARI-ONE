const builtin = @import("builtin");
const std = @import("std");

const module = @import("module.zig");
const types = @import("../../shared/types.zig");
const list_files = @import("builtin/list_files.zig");
const search_files = @import("builtin/search_files.zig");
const read_file = @import("builtin/read_file.zig");
const write_file = @import("builtin/write_file.zig");
const append_file = @import("builtin/append_file.zig");
const replace_in_file = @import("builtin/replace_in_file.zig");
const shell_exec = @import("builtin/shell_exec.zig");
const schedule_job = @import("builtin/schedule_job.zig");
const log_ticket = @import("builtin/log_ticket.zig");
const list_processes = @import("builtin/list_processes.zig");
const session_summaries = @import("builtin/session_summaries.zig");
const update_session_summary = @import("builtin/update_session_summary.zig");
const memory = @import("builtin/memory.zig");
const skills = @import("builtin/skills.zig");
const agents = @import("builtin/agents.zig");

pub const AvailabilityStatus = enum {
    available,
    unavailable,
};

pub const ResolvedAvailability = struct {
    status: AvailabilityStatus,
    dependency: ?module.Dependency = null,
    dependency_available: ?bool = null,
    reason: ?[]const u8 = null,
};

const AvailabilityEntry = struct {
    name: []const u8,
    spec: module.AvailabilitySpec,
};

pub const file_tool_definitions = [_]types.ToolDefinition{
    list_files.definition,
    search_files.definition,
    read_file.definition,
    write_file.definition,
    append_file.definition,
    replace_in_file.definition,
    shell_exec.definition,
    schedule_job.definition,
    log_ticket.definition,
    list_processes.definition,
    session_summaries.definition,
    update_session_summary.definition,
    skills.definition,
    memory.definitions[0],
    memory.definitions[1],
};

pub fn fileDefinitions() []const types.ToolDefinition {
    return file_tool_definitions[0..];
}

const availability_entries = [_]AvailabilityEntry{
    .{ .name = list_files.definition.name, .spec = list_files.availability },
    .{ .name = search_files.definition.name, .spec = search_files.availability },
    .{ .name = read_file.definition.name, .spec = read_file.availability },
    .{ .name = write_file.definition.name, .spec = write_file.availability },
    .{ .name = append_file.definition.name, .spec = append_file.availability },
    .{ .name = replace_in_file.definition.name, .spec = replace_in_file.availability },
    .{ .name = shell_exec.definition.name, .spec = shell_exec.availability },
    .{ .name = schedule_job.definition.name, .spec = schedule_job.availability },
    .{ .name = log_ticket.definition.name, .spec = log_ticket.availability },
    .{ .name = list_processes.definition.name, .spec = list_processes.availability },
    .{ .name = session_summaries.definition.name, .spec = session_summaries.availability },
    .{ .name = update_session_summary.definition.name, .spec = update_session_summary.availability },
    .{ .name = skills.definition.name, .spec = skills.availability },
    .{ .name = memory.definitions[0].name, .spec = .{} },
    .{ .name = memory.definitions[1].name, .spec = .{} },
};

pub fn availabilitySpec(tool_name: []const u8) ?module.AvailabilitySpec {
    for (availability_entries) |entry| {
        if (std.mem.eql(u8, tool_name, entry.name)) return entry.spec;
    }
    if (agents.availabilitySpec(tool_name)) |spec| return spec;
    return null;
}

pub fn resolveAvailability(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !ResolvedAvailability {
    const spec = availabilitySpec(tool_name) orelse module.AvailabilitySpec{};
    const dependency = spec.dependency orelse return .{ .status = .available };

    const dependency_available = switch (dependency.kind) {
        .none => true,
        .external_command => try commandDependencyAvailable(allocator, probe, tool_name, dependency),
    };

    return .{
        .status = if (dependency_available) .available else .unavailable,
        .dependency = dependency,
        .dependency_available = dependency_available,
        .reason = if (dependency_available) null else "required dependency is unavailable",
    };
}

pub fn ensureAvailable(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !void {
    const resolved = try resolveAvailability(allocator, probe, tool_name);
    if (resolved.status == .unavailable) return error.ToolUnavailable;
}

pub fn renderAvailabilityJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
) !void {
    const resolved = try resolveAvailability(allocator, probe, tool_name);
    try writer.writeAll("{\"status\":");
    try writer.print("{f}", .{std.json.fmt(statusLabel(resolved.status), .{})});

    if (resolved.reason) |reason| {
        try writer.writeAll(",\"reason\":");
        try writer.print("{f}", .{std.json.fmt(reason, .{})});
    }

    try writer.writeAll(",\"dependencies\":[");
    if (resolved.dependency) |dependency| {
        try writer.writeAll("{\"kind\":");
        try writer.print("{f}", .{std.json.fmt(dependencyKindLabel(dependency.kind), .{})});
        try writer.writeAll(",\"name\":");
        try writer.print("{f}", .{std.json.fmt(dependency.name, .{})});
        if (resolved.dependency_available) |available| {
            try writer.writeAll(",\"available\":");
            try writer.writeAll(if (available) "true" else "false");
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]}");
}

fn commandDependencyAvailable(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    tool_name: []const u8,
    dependency: module.Dependency,
) !bool {
    if (isIxSearchDependency(tool_name, dependency)) {
        return ixSearchCommandAvailable(allocator, probe, dependency.name);
    }

    if (probe) |value| return value.commandExists(allocator, dependency.name);
    return defaultCommandExists(allocator, dependency.name);
}

fn isIxSearchDependency(tool_name: []const u8, dependency: module.Dependency) bool {
    return dependency.kind == .external_command and
        std.mem.eql(u8, tool_name, search_files.definition.name) and
        std.mem.eql(u8, dependency.name, search_files.command_name);
}

fn ixSearchCommandAvailable(
    allocator: std.mem.Allocator,
    probe: ?module.CommandProbe,
    command_name: []const u8,
) !bool {
    const argv = &[_][]const u8{ command_name, "search", "--help" };
    const stdout_needles = &[_][]const u8{
        "Usage:",
        "search [OPTIONS] <EXPR>",
        "--json",
    };

    if (probe) |value| return value.commandMatches(allocator, command_name, argv, stdout_needles);
    return defaultCommandMatches(allocator, argv, stdout_needles);
}

fn defaultCommandExists(allocator: std.mem.Allocator, command_name: []const u8) !bool {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "where.exe", command_name }
    else
        &[_][]const u8{ "which", command_name };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn defaultCommandMatches(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout_needles: []const []const u8,
) !bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exited_zero = switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!exited_zero) return false;

    for (stdout_needles) |needle| {
        if (std.mem.indexOf(u8, result.stdout, needle) == null and
            std.mem.indexOf(u8, result.stderr, needle) == null) return false;
    }

    return true;
}

pub fn statusLabel(status: AvailabilityStatus) []const u8 {
    return switch (status) {
        .available => "available",
        .unavailable => "unavailable",
    };
}

pub fn dependencyKindLabel(kind: module.DependencyKind) []const u8 {
    return switch (kind) {
        .none => "none",
        .external_command => "external_command",
    };
}

test "availability registry is derived from builtin module definitions" {
    try std.testing.expectEqual(file_tool_definitions.len, availability_entries.len);

    for (file_tool_definitions, availability_entries) |definition, entry| {
        try std.testing.expectEqualStrings(definition.name, entry.name);
    }

    const search_spec = availabilitySpec(search_files.definition.name).?;
    try std.testing.expect(search_spec.dependency != null);
    try std.testing.expectEqual(module.DependencyKind.external_command, search_spec.dependency.?.kind);
    try std.testing.expectEqualStrings(search_files.command_name, search_spec.dependency.?.name);

    for (agents.definitions) |definition| {
        const agent_spec = availabilitySpec(definition.name);
        try std.testing.expect(agent_spec != null);
        try std.testing.expect(agent_spec.?.dependency == null);
    }
    try std.testing.expect(availabilitySpec("missing_tool") == null);
}
