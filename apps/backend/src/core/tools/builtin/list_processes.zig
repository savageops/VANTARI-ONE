const std = @import("std");

const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "list_processes",
    .description = "List recent process execution records from the workspace process ledger (.var/processes/processes.jsonl). Returns the most recent commands, their exit codes, duration, mode, and arguments.",
    .review_risk = .read_only,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "limit": { "type": "integer", "minimum": 1, "maximum": 100, "description": "Maximum records to return (most recent first). Defaults to 20." }
    \\  },
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"limit\":10}",
    .usage_hint = "Use to review what commands have been run in this workspace, their exit codes, and duration. Records are read from the append-only process ledger.",
};

pub const availability = module.AvailabilitySpec{};

const default_limit: usize = 20;
const max_limit: usize = 100;

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    const Args = struct {
        limit: ?usize = null,
    };

    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();

    const limit = clamp(parsed.value.limit orelse default_limit, 1, max_limit);

    const ledger_path = try fsutil.join(allocator, &.{ execution_context.workspace_root, ".var", "processes", "processes.jsonl" });
    defer allocator.free(ledger_path);

    const content = fsutil.readTextAlloc(allocator, ledger_path) catch |err| switch (err) {
        error.FileNotFound => return module.okEnvelope(allocator, "list_processes", "PROCESSES empty\nREASON no process ledger found yet"),
        else => return err,
    };
    defer allocator.free(content);

    // Split into lines, collect the last `limit` non-empty lines (most recent).
    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) lines.append(trimmed) catch break;
    }

    const total = lines.items.len;
    const start = if (total > limit) total - limit else 0;
    const count = total - start;

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.print("PROCESSES {d} of {d}\n", .{ count, total });

    // Most recent first.
    var i: usize = total;
    while (i > start) {
        i -= 1;
        try writer.print("- {s}\n", .{lines.items[i]});
    }

    return module.okEnvelope(allocator, "list_processes", output.items);
}

fn clamp(value: usize, min: usize, max: usize) usize {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}
