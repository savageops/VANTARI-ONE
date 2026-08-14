const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");
const hashline = @import("hashline.zig");

pub const definition = types.ToolDefinition{
    .name = "replace_in_file",
    .description = "Perform exact text replacement in an existing file. Restricted mode keeps the target inside the workspace; runtime.full_access_mode=true permits an explicit external path. Large replacements are allowed when exact and intentional. Supports hash-anchored edits: pass the tag from read_file to reject stale anchors.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "path": { "type": "string", "description": "Required existing file path to edit. Restricted mode requires a workspace-relative path; runtime.full_access_mode=true permits an explicit external path." },
    \\    "old_text": { "type": "string", "description": "Required exact text to replace. Prefer the narrowest stable replacement window." },
    \\    "new_text": { "type": "string", "description": "Required replacement text. Large replacements are allowed when exact and intentional; append_file chunks remain preferred for long generated additions." },
    \\    "replace_all": { "type": "boolean", "description": "When true, replace every match instead of only the first one." },
    \\    "tag": { "type": "string", "description": "Optional content hash tag from read_file. When provided, the edit is rejected if the file changed since the read (stale anchor protection)." }
    \\  },
    \\  "required": ["path", "old_text", "new_text"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"path\":\"src/core/tools/runtime.zig\",\"old_text\":\"alpha\",\"new_text\":\"beta\",\"replace_all\":false,\"tag\":\"A1B2\"}",
    .usage_hint = "This is exact string replacement, not regex. Read the target first (the response includes a #tag), copy old_text precisely, pass the tag to reject stale edits, prefer narrow anchors, and keep replace_all false unless every occurrence must change.",
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
        old_text: []const u8,
        new_text: []const u8,
        replace_all: bool = false,
        tag: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const file_path = try fsutil.resolveWithAccessMode(allocator, execution_context.workspace_root, parsed.value.path, execution_context.full_access_mode);
    defer allocator.free(file_path);

    const original = try fsutil.readTextAlloc(allocator, file_path);
    defer allocator.free(original);

    // Hash-anchored stale rejection: when the model provides a tag from
    // read_file, verify the file hasn't changed. If it has, reject the edit
    // with a typed error so the model re-reads and retries. This eliminates
    // edits landing on wrong content after another tool modified the file.
    if (parsed.value.tag) |tag| {
        const current_tag = try hashline.contentHash(allocator, original);
        defer allocator.free(current_tag);
        if (!std.mem.eql(u8, tag, current_tag)) {
            const stale_msg = try std.fmt.allocPrint(allocator, "STALE_ANCHOR: file changed since read (expected tag {s}, got {s}). Re-read the file and retry with the updated tag.", .{ tag, current_tag });
            defer allocator.free(stale_msg);
            return module.okEnvelope(allocator, definition.name, stale_msg);
        }
    }

    const before = try module.fileSnapshotFromContents(allocator, true, original);
    defer before.deinit(allocator);
    try module.requireFileInspection(execution_context, file_path, true);

    const replace_result = try module.replaceText(
        allocator,
        original,
        parsed.value.old_text,
        parsed.value.new_text,
        parsed.value.replace_all,
    );
    defer allocator.free(replace_result.contents);

    if (replace_result.replacements == 0) return module.Error.PatternNotFound;

    const intent = try module.reserveFileIntent(
        allocator,
        execution_context,
        definition.name,
        file_path,
        before.sha256_hex,
    );
    try fsutil.writeText(file_path, replace_result.contents);

    // Include the new content hash tag in the response so the model can
    // chain subsequent edits without re-reading.
    const new_tag = try hashline.contentHash(allocator, replace_result.contents);
    defer allocator.free(new_tag);

    const after = try module.fileSnapshotFromContents(allocator, true, replace_result.contents);
    defer after.deinit(allocator);
    try module.commitFileIntent(allocator, execution_context, intent, after.sha256_hex, replace_result.replacements);
    try module.recordFileInspection(allocator, execution_context, file_path, true);

    const summary = try std.fmt.allocPrint(
        allocator,
        "PATH {s}\nREPLACEMENTS {d}\nTAG {s}",
        .{ file_path, replace_result.replacements, new_tag },
    );
    defer allocator.free(summary);

    return module.fileEffectEnvelope(
        allocator,
        definition.name,
        summary,
        .replace_in_file,
        parsed.value.path,
        file_path,
        before,
        after,
        .{ .name = .replacements, .value = replace_result.replacements },
    );
}
