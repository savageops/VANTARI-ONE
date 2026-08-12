const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "list_files",
    .description = "Discover files and directories. Call when the target is unknown. Restricted mode keeps discovery inside the workspace; runtime.full_access_mode=true permits an explicit external path. Arguments are an object with optional path and max_results only; omit path or use \".\" for the workspace root.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Optional existing file or directory path to list. Restricted mode requires a workspace-relative path; runtime.full_access_mode=true permits an explicit external path. Defaults to the workspace root when omitted or set to ." },
    \\    "max_results": { "type": "integer", "minimum": 1, "description": "Optional maximum number of paths to return." }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src\",\"max_results\":100}",
    .usage_hint = "Use before read_file/search_files when path certainty is low. Paths must be existing and workspace-relative unless runtime.full_access_mode is explicitly true.",
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
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const search_path = try fsutil.resolveWithAccessMode(
        allocator,
        execution_context.workspace_root,
        parsed.value.path orelse ".",
        execution_context.full_access_mode,
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
