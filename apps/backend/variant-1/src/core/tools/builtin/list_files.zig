const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "list_files",
    .description = "Discover workspace paths. Call when the target file or directory is unknown. Arguments are an object with optional path and max_results only; omit path or use \".\" for the workspace root.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Optional existing workspace-relative file or directory path to list. Defaults to the workspace root when omitted or set to ." },
    \\    "max_results": { "type": "integer", "minimum": 1, "description": "Optional maximum number of paths to return." }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src\",\"max_results\":100}",
    .usage_hint = "Use before read_file/search_files when path certainty is low. Path must be workspace-relative and existing; never pass absolute paths or .. segments.",
};

pub const availability = module.AvailabilitySpec{};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        path: ?[]const u8 = null,
        max_results: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const search_path = try fsutil.resolveInWorkspace(
        allocator,
        execution_context.workspace_root,
        parsed.value.path orelse ".",
    );
    defer allocator.free(search_path);

    const root_abs = try fsutil.resolveAbsolute(allocator, execution_context.workspace_root);
    defer allocator.free(root_abs);

    const search_prefix = try std.fs.path.relative(allocator, root_abs, search_path);
    defer allocator.free(search_prefix);

    const listed = try module.collectFiles(allocator, search_path, search_prefix, parsed.value.max_results orelse 200);
    defer allocator.free(listed);

    return module.okEnvelope(allocator, definition.name, listed);
}
