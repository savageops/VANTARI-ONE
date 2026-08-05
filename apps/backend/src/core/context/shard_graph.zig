const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");

/// Render a text-based shard branch/converge topology from the session's
/// context.jsonl checkpoint ledger (roadmap P2-16). This is the TUI item
/// graph projection: a compact ASCII tree showing parent → branch →
/// converge/abandon relationships.
///
/// Example output:
///   parent (cp-1)
///     ├─ branch 1 [open] Branch A: investigating search
///     ├─ branch 2 [converged] Branch B: audit results
///     └─ branch 3 [abandoned] Branch C: cold-start recovery
pub fn renderShardGraph(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
) ![]u8 {
    const checkpoints = try store.readAllContextCheckpoints(allocator, workspace_root, session_id);
    defer types.deinitContextCheckpoints(allocator, checkpoints);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    // Find the latest summary checkpoint (the parent).
    var parent_id: ?[]const u8 = null;
    var i: usize = checkpoints.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, checkpoints[i].entry_type, "summary_checkpoint")) {
            parent_id = checkpoints[i].id;
            break;
        }
    }

    if (parent_id == null) {
        try writer.writeAll("(no parent checkpoint)");
        return output.toOwnedSlice();
    }

    // Track the latest status per (branch_seq).
    var branch_statuses = std.AutoHashMap(u64, types.ShardStatus).init(allocator);
    defer branch_statuses.deinit();
    var branch_summaries = std.AutoHashMap(u64, []const u8).init(allocator);
    defer branch_summaries.deinit();

    for (checkpoints) |cp| {
        if (!std.mem.eql(u8, cp.entry_type, "shard_checkpoint")) continue;
        if (cp.parent_checkpoint_id == null) continue;
        if (!std.mem.eql(u8, cp.parent_checkpoint_id.?, parent_id.?)) continue;
        if (cp.branch_status) |status| {
            try branch_statuses.put(cp.branch_seq, status);
            try branch_summaries.put(cp.branch_seq, cp.summary);
        }
    }

    if (branch_statuses.count() == 0) {
        try writer.print("parent ({s})\n  (no branches)", .{parent_id.?});
        return output.toOwnedSlice();
    }

    try writer.print("parent ({s})\n", .{parent_id.?});

    // Sort branch_seqs for deterministic output.
    var keys = std.array_list.Managed(u64).init(allocator);
    defer keys.deinit();
    var it = branch_statuses.keyIterator();
    while (it.next()) |key| try keys.append(key.*);
    std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));

    for (keys.items, 0..) |branch_seq, idx| {
        const is_last = idx == keys.items.len - 1;
        const prefix = if (is_last) "  └─ " else "  ├─ ";
        const status = branch_statuses.get(branch_seq).?;
        const summary = branch_summaries.get(branch_seq) orelse "";
        const status_label = switch (status) {
            .open => "open",
            .converged => "converged",
            .abandoned => "abandoned",
        };
        // Truncate summary to 50 chars for terminal display.
        const max_summary: usize = 50;
        const display_summary = if (summary.len > max_summary) summary[0..max_summary] else summary;
        try writer.print("{s}branch {d} [{s}] {s}\n", .{ prefix, branch_seq, status_label, display_summary });
    }

    return output.toOwnedSlice();
}

test "renderShardGraph shows parent with no branches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    const session_store = @import("../sessions/store.zig");
    var session = try session_store.initSession(std.testing.allocator, workspace_root, "graph test");
    defer session.deinit(std.testing.allocator);

    const graph = try renderShardGraph(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(graph);

    try std.testing.expect(std.mem.indexOf(u8, graph, "(no parent checkpoint)") != null);
}

test "renderShardGraph shows branch topology with statuses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace_root);

    const session_store = @import("../sessions/store.zig");
    var session = try session_store.initSession(std.testing.allocator, workspace_root, "graph branches");
    defer session.deinit(std.testing.allocator);

    // Write parent checkpoint.
    {
        const id = try std.testing.allocator.dupe(u8, "cp-graph-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 1000,
            .source_seq_start = 1, .source_seq_end = 5, .first_kept_seq = 3,
            .tokens_before_estimate = 200, .tokens_after_estimate = 100,
            .trigger = trigger, .summary = summary,
        });
    }

    // Open and converge branches.
    try session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, session.id, "cp-graph-1", 1, .open, "Branch A investigating.");
    try session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, session.id, "cp-graph-1", 1, .converged, "Branch A converged.");
    try session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, session.id, "cp-graph-1", 2, .open, "Branch B scouting.");
    try session_store.appendShardCheckpoint(std.testing.allocator, workspace_root, session.id, "cp-graph-1", 2, .abandoned, "Branch B abandoned.");

    const graph = try renderShardGraph(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(graph);

    // Must show parent.
    try std.testing.expect(std.mem.indexOf(u8, graph, "parent (cp-graph-1)") != null);
    // Must show both branches with their terminal statuses.
    try std.testing.expect(std.mem.indexOf(u8, graph, "branch 1 [converged]") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph, "branch 2 [abandoned]") != null);
    // Must use tree-drawing characters.
    try std.testing.expect(std.mem.indexOf(u8, graph, "├─") != null or std.mem.indexOf(u8, graph, "└─") != null);
}
