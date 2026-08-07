/// manage_plugin — discover, inspect, enable, or disable VANTARI plugins.
///
/// Plugins live under .var/plugins/<id>/plugin.json. Each manifest declares
/// tool sockets that extend VANTARI's capability surface. This tool is the
/// operator-facing management surface; actual tool dispatch is a separate
/// runtime integration (PLUG- chain).
const std = @import("std");

const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "manage_plugin",
    .description = "List, inspect, enable, or disable VANTARI plugins from .var/plugins/. Plugins extend the capability surface with tool sockets declared in plugin.json manifests.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": { "type": "string", "enum": ["list", "info", "enable", "disable"] },
    \\    "plugin_id": { "type": "string", "description": "Plugin id for info/enable/disable actions." }
    \\  },
    \\  "required": ["action"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"action\":\"list\"}",
    .usage_hint = "Use list to discover installed plugins, info to inspect a plugin's manifest and sockets, enable/disable to control whether a plugin's tools appear in the catalog.",
};

pub const availability = module.AvailabilitySpec{};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        action: []const u8,
        plugin_id: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "list")) {
        return executeList(allocator, execution_context);
    }

    if (std.mem.eql(u8, args.action, "info")) {
        const plugin_id = args.plugin_id orelse return module.Error.InvalidArguments;
        return executeInfo(allocator, execution_context, plugin_id);
    }

    if (std.mem.eql(u8, args.action, "enable") or std.mem.eql(u8, args.action, "disable")) {
        const plugin_id = args.plugin_id orelse return module.Error.InvalidArguments;
        const enabled = std.mem.eql(u8, args.action, "enable");
        return executeToggle(allocator, execution_context, plugin_id, enabled);
    }

    return module.Error.InvalidArguments;
}

fn pluginsRoot(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "plugins" });
}

fn executeList(allocator: std.mem.Allocator, execution_context: module.ExecutionContext) ![]u8 {
    const plugins_dir = try pluginsRoot(allocator, execution_context.workspace_root);
    defer allocator.free(plugins_dir);

    var dir = std.fs.cwd().openDir(plugins_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return module.okEnvelope(allocator, "manage_plugin", "PLUGINS empty\nREASON no .var/plugins/ directory found"),
        else => return err,
    };
    defer dir.close();

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.writeAll("PLUGINS\n");

    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}/plugin.json", .{ plugins_dir, entry.name });
        defer allocator.free(manifest_path);

        const exists = fsutil.fileExists(manifest_path);
        try writer.print("- {s} {s}\n", .{ entry.name, if (exists) "[ready]" else "[no manifest]" });
        count += 1;
    }

    if (count == 0) try writer.writeAll("(none)\n");

    return module.okEnvelope(allocator, "manage_plugin", output.items);
}

fn executeInfo(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    plugin_id: []const u8,
) ![]u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/.var/plugins/{s}/plugin.json", .{
        execution_context.workspace_root,
        plugin_id,
    });
    defer allocator.free(manifest_path);

    const content = fsutil.readTextAlloc(allocator, manifest_path) catch |err| switch (err) {
        error.FileNotFound => return module.okEnvelope(allocator, "manage_plugin", "PLUGIN not found\nREASON no manifest at .var/plugins/{s}/plugin.json"),
        else => return err,
    };
    defer allocator.free(content);

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.print("PLUGIN {s}\nPATH {s}\nMANIFEST\n{s}\n", .{ plugin_id, manifest_path, content });

    return module.okEnvelope(allocator, "manage_plugin", output.items);
}

fn executeToggle(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    plugin_id: []const u8,
    enabled: bool,
) ![]u8 {
    // Verify the plugin exists
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/.var/plugins/{s}/plugin.json", .{
        execution_context.workspace_root,
        plugin_id,
    });
    defer allocator.free(manifest_path);

    if (!fsutil.fileExists(manifest_path)) {
        return module.okEnvelope(allocator, "manage_plugin", "PLUGIN not found\nREASON no manifest at expected path");
    }

    // TODO: persist enable/disable state to config.json plugins section
    // For now, this is a placeholder that acknowledges the toggle
    const action_text: []const u8 = if (enabled) "enabled" else "disabled";
    const result = try std.fmt.allocPrint(allocator, "PLUGIN {s} {s}\nNOTE plugin toggle requires config.json persistence (PLUG- chain PLUGg)", .{ plugin_id, action_text });
    defer allocator.free(result);
    return module.okEnvelope(allocator, "manage_plugin", result);
}
