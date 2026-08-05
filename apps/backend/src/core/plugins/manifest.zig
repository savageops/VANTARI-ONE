const std = @import("std");
const tool_sockets = @import("../tools/sockets.zig");
const types = @import("../../shared/types.zig");

pub const Error = error{
    MissingPluginId,
    InvalidPluginId,
    MissingPluginVersion,
    MissingSocketName,
    MissingSocketEntry,
    UnsupportedSocketKind,
    InvalidSocketName,
    InvalidReviewRisk,
    DuplicateSocketName,
};

pub const PluginSocketKind = enum {
    tool,
    provider,
    context,
    event,
};

pub const PluginSocket = struct {
    kind: PluginSocketKind,
    name: []const u8,
    entry: []const u8,
    /// Required for tool sockets: the review risk class that gates this tool.
    /// Must be a valid `ReviewRisk` label. Ignored for non-tool sockets.
    review_risk: ?[]const u8 = null,
};

pub const PluginManifest = struct {
    id: []const u8,
    version: []const u8,
    sockets: []const PluginSocket = &.{},
};

/// Supported socket kinds for the current runtime. Provider/context/event
/// sockets are declared for forward compatibility but only `tool` sockets
/// are mountable today. Attempting to mount an unsupported kind fails closed
/// before any tool is advertised (AGENTS.md §V, roadmap P1-21).
pub fn isSocketKindMountable(kind: PluginSocketKind) bool {
    return kind == .tool;
}

/// Validate a plugin manifest at mount time. Refuses unsupported contracts
/// before advertising tools to the model (roadmap P1-21).
pub fn validateManifest(manifest: PluginManifest) !void {
    try validatePluginId(manifest.id);
    if (std.mem.trim(u8, manifest.version, " \t\r\n").len == 0) return Error.MissingPluginVersion;

    // Track socket names to detect duplicates.
    var seen_names = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer seen_names.deinit();

    for (manifest.sockets) |socket| {
        if (std.mem.trim(u8, socket.name, " \t\r\n").len == 0) return Error.MissingSocketName;
        if (std.mem.trim(u8, socket.entry, " \t\r\n").len == 0) return Error.MissingSocketEntry;

        // Only tool sockets are mountable today.
        if (!isSocketKindMountable(socket.kind)) return Error.UnsupportedSocketKind;

        // Tool sockets must have valid lowercase snake_case names.
        if (socket.kind == .tool) {
            tool_sockets.validateName(socket.name) catch return Error.InvalidSocketName;
        }

        // Tool sockets must declare a valid review risk class.
        if (socket.kind == .tool) {
            const risk = socket.review_risk orelse return Error.InvalidReviewRisk;
            if (types.parseReviewRiskLabel(risk) == null) return Error.InvalidReviewRisk;
        }

        // Check for duplicate socket names.
        for (seen_names.items) |seen| {
            if (std.mem.eql(u8, seen, socket.name)) return Error.DuplicateSocketName;
        }
        try seen_names.append(socket.name);
    }
}

pub fn validatePluginId(id: []const u8) !void {
    if (id.len == 0) return Error.MissingPluginId;

    for (id) |char| {
        const ok = (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9') or
            char == '-' or
            char == '_';
        if (!ok) return Error.InvalidPluginId;
    }
}

/// Mount result: the validated manifest or the rejection reason.
pub const MountResult = union(enum) {
    accepted: PluginManifest,
    rejected: Error,
};

/// Mount a plugin manifest: validate and return the result. The caller must
/// check the result before advertising any tool to the model.
pub fn mountPlugin(manifest: PluginManifest) MountResult {
    validateManifest(manifest) catch |err| return .{ .rejected = err };
    return .{ .accepted = manifest };
}

test "plugin manifest validates ids and declared sockets" {
    const sockets = [_]PluginSocket{.{
        .kind = .tool,
        .name = "lookup_ticket",
        .entry = "tools/lookup_ticket",
        .review_risk = "read_only",
    }};

    try validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = sockets[0..],
    });

    try std.testing.expectError(Error.InvalidPluginId, validateManifest(.{
        .id = "Tickets",
        .version = "0.1.0",
    }));

    try std.testing.expectError(Error.InvalidSocketName, validateManifest(.{
        .id = "tickets",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .tool,
            .name = "lookup-ticket",
            .entry = "tools/lookup_ticket",
            .review_risk = "read_only",
        }},
    }));
}

test "plugin manifest rejects tool sockets without review risk" {
    try std.testing.expectError(Error.InvalidReviewRisk, validateManifest(.{
        .id = "test",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .tool,
            .name = "my_tool",
            .entry = "tools/my_tool",
        }},
    }));
}

test "plugin manifest rejects unsupported socket kinds" {
    try std.testing.expectError(Error.UnsupportedSocketKind, validateManifest(.{
        .id = "test",
        .version = "0.1.0",
        .sockets = &.{.{
            .kind = .provider,
            .name = "custom_provider",
            .entry = "providers/custom",
        }},
    }));
}

test "plugin manifest rejects duplicate socket names" {
    try std.testing.expectError(Error.DuplicateSocketName, validateManifest(.{
        .id = "test",
        .version = "0.1.0",
        .sockets = &.{
            .{ .kind = .tool, .name = "my_tool", .entry = "tools/a", .review_risk = "read_only" },
            .{ .kind = .tool, .name = "my_tool", .entry = "tools/b", .review_risk = "read_only" },
        },
    }));
}

test "mountPlugin accepts valid manifest and rejects invalid" {
    const valid = PluginManifest{
        .id = "my-plugin",
        .version = "1.0.0",
        .sockets = &.{.{ .kind = .tool, .name = "do_thing", .entry = "tools/do", .review_risk = "write_capable" }},
    };
    const result = mountPlugin(valid);
    try std.testing.expect(result == .accepted);

    const invalid = PluginManifest{
        .id = "My Plugin",
        .version = "1.0.0",
    };
    const result2 = mountPlugin(invalid);
    try std.testing.expect(result2 == .rejected);
}
