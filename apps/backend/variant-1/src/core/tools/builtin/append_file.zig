const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "append_file",
    .description = "Append text to a workspace file, creating it only when absent. Arguments require path and content. Use for additive logs, ledgers, and notes.",
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required workspace-relative file path to append to." },
    \\    "content": { "type": "string", "description": "Required text to append." }
    \\  },
    \\  "required": ["path", "content"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"notes/todo.md\",\"content\":\"beta\\n\"}",
    .usage_hint = "Use for additive writes only. Include your own newline when needed. Use write_file for full replacement and replace_in_file for exact local edits.",
};

pub const availability = module.AvailabilitySpec{};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveInWorkspace(allocator, execution_context.workspace_root, parsed.value.path);
    defer allocator.free(file_path);

    var before_exists = true;
    const before_contents = fsutil.readTextAlloc(allocator, file_path) catch |err| switch (err) {
        error.FileNotFound => missing: {
            before_exists = false;
            break :missing try allocator.dupe(u8, "");
        },
        else => return err,
    };
    defer allocator.free(before_contents);

    const before = try module.fileSnapshotFromContents(allocator, before_exists, before_contents);
    defer before.deinit(allocator);

    try fsutil.appendText(file_path, parsed.value.content);

    const after = try module.fileSnapshotFromParts(
        allocator,
        true,
        before_contents.len + parsed.value.content.len,
        &.{ before_contents, parsed.value.content },
    );
    defer after.deinit(allocator);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nAPPENDED_BYTES {d}",
        .{ file_path, parsed.value.content.len },
    );
    defer allocator.free(summary);

    return module.fileEffectEnvelope(
        allocator,
        definition.name,
        summary,
        .append_file,
        parsed.value.path,
        file_path,
        before,
        after,
        .{ .name = .bytes_appended, .value = parsed.value.content.len },
    );
}
