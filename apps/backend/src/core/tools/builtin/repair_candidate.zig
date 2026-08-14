const std = @import("std");
const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");
const evaluation_events = @import("../../evaluation/events.zig");

pub const definition = types.ToolDefinition{
    .name = "repair_candidate",
    .description = "Record a source-baseline-anchored repair candidate without changing files. Approval and apply are separate operations.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "candidate_id": { "type": "string", "description": "Stable id for this repair proposal." },
    \\    "failure_id": { "type": "string", "description": "Durable failure receipt id that caused this proposal." },
    \\    "path": { "type": "string", "description": "Existing target path that was inspected before proposal." },
    \\    "operation": { "type": "string", "enum": ["replace_in_file"] },
    \\    "patch": { "type": "string", "description": "Exact proposed patch body. It is hashed for the durable receipt and is not applied." },
    \\    "expected_source_baseline": { "type": "string", "description": "Source baseline captured with the failure, such as git:<commit> or unavailable." }
    \\  },
    \\  "required": ["candidate_id", "failure_id", "path", "operation", "patch", "expected_source_baseline"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"candidate_id\":\"candidate-1\",\"failure_id\":\"failure-1\",\"path\":\"apps/backend/src/core/foo.zig\",\"operation\":\"replace_in_file\",\"patch\":\"...\",\"expected_source_baseline\":\"git:abc123\"}",
    .usage_hint = "Proposal only: inspect the exact target first. This tool records hashes and baseline status, never changes source, and baseline drift blocks the candidate.",
};

pub const availability = module.AvailabilitySpec{};
const max_candidate_patch_bytes: usize = 64 * 1024;

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
    _: module.CommandRunner,
) ![]u8 {
    const Args = struct {
        candidate_id: []const u8,
        failure_id: []const u8,
        path: []const u8,
        operation: []const u8,
        patch: []const u8,
        expected_source_baseline: []const u8,
    };

    const session_id = execution_context.session_id orelse return module.Error.InvalidRepairCandidate;
    var parsed = std.json.parseFromSlice(Args, allocator, arguments_json, .{
        .ignore_unknown_fields = false,
    }) catch return module.Error.InvalidRepairCandidate;
    defer parsed.deinit();

    const candidate_id = parsed.value.candidate_id;
    const failure_id = parsed.value.failure_id;
    const requested_path = parsed.value.path;
    const operation = parsed.value.operation;
    const patch = parsed.value.patch;
    const expected_baseline = parsed.value.expected_source_baseline;
    if (std.mem.trim(u8, candidate_id, " \t\r\n").len == 0 or
        std.mem.trim(u8, failure_id, " \t\r\n").len == 0 or
        std.mem.trim(u8, requested_path, " \t\r\n").len == 0 or
        std.mem.trim(u8, operation, " \t\r\n").len == 0 or
        std.mem.trim(u8, patch, " \t\r\n").len == 0 or
        std.mem.trim(u8, expected_baseline, " \t\r\n").len == 0 or
        !std.mem.eql(u8, operation, "replace_in_file") or
        patch.len > max_candidate_patch_bytes)
    {
        return module.Error.InvalidRepairCandidate;
    }

    const file_path = fsutil.resolveWithAccessMode(
        allocator,
        execution_context.workspace_root,
        requested_path,
        execution_context.full_access_mode,
    ) catch |err| return err;
    defer allocator.free(file_path);

    const before = try module.captureFileSnapshot(allocator, file_path);
    defer before.deinit(allocator);
    if (!before.exists or before.sha256_hex == null) return module.Error.InvalidRepairCandidate;
    try module.requireFileInspection(execution_context, file_path, true);

    const current_baseline = try evaluation_events.sourceBaseline(allocator);
    defer allocator.free(current_baseline);
    const patch_descriptor = try std.fmt.allocPrint(allocator, "{s}\x00{s}\x00{s}", .{ operation, requested_path, patch });
    defer allocator.free(patch_descriptor);
    const patch_hash = evaluation_events.contentHash(patch_descriptor);
    const baseline_match = std.mem.eql(u8, expected_baseline, current_baseline);

    const candidate_event_seq = try evaluation_events.appendRepairCandidateEvent(
        allocator,
        execution_context.workspace_root,
        session_id,
        candidate_id,
        failure_id,
        operation,
        file_path,
        before.sha256_hex.?,
        patch_hash[0..],
        expected_baseline,
        current_baseline,
        baseline_match,
    );

    if (!baseline_match) return module.Error.RepairBaselineConflict;

    const summary = try std.fmt.allocPrint(
        allocator,
        "CANDIDATE_ID {s}\nCANDIDATE_EVENT_SEQ {d}\nSTATUS ready\nSOURCE_BASELINE {s}\nPATCH_SHA256 sha256:{s}\nBEFORE_SHA256 sha256:{s}\nMUTATION_ALLOWED false\nNEXT operator approval required before apply",
        .{ candidate_id, candidate_event_seq, current_baseline, patch_hash[0..], before.sha256_hex.? },
    );
    defer allocator.free(summary);
    return module.okEnvelope(allocator, definition.name, summary);
}
