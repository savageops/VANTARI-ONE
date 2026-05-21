const std = @import("std");

const scheduler = @import("../../scheduler/index.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "schedule_job",
    .description = "Create, read, update, delete, pause, resume, list, or reserve an immediate run for durable VAR1 scheduler jobs.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": { "type": "string", "enum": ["create", "get", "list", "update", "delete", "pause", "resume", "run_now"] },
    \\    "job_id": { "type": "string" },
    \\    "title": { "type": "string" },
    \\    "target_kind": { "type": "string", "enum": ["prompt", "shell"] },
    \\    "target": { "type": "string" },
    \\    "schedule_kind": { "type": "string", "enum": ["once", "interval"] },
    \\    "due_at_ms": { "type": "integer", "minimum": 0 },
    \\    "interval_ms": { "type": "integer", "minimum": 1 },
    \\    "misfire_policy": { "type": "string", "enum": ["fire_once", "skip"] },
    \\    "max_catch_up": { "type": "integer", "minimum": 1, "maximum": 65535 },
    \\    "include_deleted": { "type": "boolean" }
    \\  },
    \\  "required": ["action"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"action\":\"create\",\"title\":\"daily planning\",\"target_kind\":\"prompt\",\"target\":\"Review open tasks and produce a short plan.\",\"schedule_kind\":\"interval\",\"due_at_ms\":1770000000000,\"interval_ms\":86400000}",
    .usage_hint = "Use create for new durable jobs, update for schedule/target edits, pause/resume/delete for lifecycle, list/get for readback, and run_now only to reserve an immediate attempt record. Scheduler truth is .var/schedules; OS cron is not used.",
};

pub const availability = module.AvailabilitySpec{};

const Args = struct {
    action: []const u8,
    job_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    target_kind: ?[]const u8 = null,
    target: ?[]const u8 = null,
    schedule_kind: ?[]const u8 = null,
    due_at_ms: ?i64 = null,
    interval_ms: ?i64 = null,
    misfire_policy: ?[]const u8 = null,
    max_catch_up: ?u16 = null,
    include_deleted: ?bool = null,
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "create")) {
        return create(allocator, execution_context.workspace_root, args);
    }
    if (std.mem.eql(u8, args.action, "get")) {
        const job_id = args.job_id orelse return module.Error.InvalidArguments;
        var job = try scheduler.readJob(allocator, execution_context.workspace_root, job_id);
        defer job.deinit(allocator);
        return renderJobEnvelope(allocator, "get", job);
    }
    if (std.mem.eql(u8, args.action, "list")) {
        const jobs = try scheduler.listJobs(allocator, execution_context.workspace_root, args.include_deleted orelse false);
        defer {
            for (jobs) |job| job.deinit(allocator);
            allocator.free(jobs);
        }
        return renderListEnvelope(allocator, jobs);
    }
    if (std.mem.eql(u8, args.action, "update")) {
        const job_id = args.job_id orelse return module.Error.InvalidArguments;
        var job = try scheduler.updateJob(allocator, execution_context.workspace_root, job_id, .{
            .title = args.title,
            .target_kind = if (args.target_kind) |value| try scheduler.types.parseTargetKind(value) else null,
            .target = args.target,
            .due_at_ms = args.due_at_ms,
            .interval_ms = args.interval_ms,
            .misfire_policy = if (args.misfire_policy) |value| try scheduler.types.parseMisfirePolicy(value) else null,
            .max_catch_up = args.max_catch_up,
        });
        defer job.deinit(allocator);
        return renderJobEnvelope(allocator, "update", job);
    }
    if (std.mem.eql(u8, args.action, "delete")) return setStatus(allocator, execution_context.workspace_root, args.job_id, .deleted, "delete");
    if (std.mem.eql(u8, args.action, "pause")) return setStatus(allocator, execution_context.workspace_root, args.job_id, .paused, "pause");
    if (std.mem.eql(u8, args.action, "resume")) return setStatus(allocator, execution_context.workspace_root, args.job_id, .active, "resume");
    if (std.mem.eql(u8, args.action, "run_now")) {
        const job_id = args.job_id orelse return module.Error.InvalidArguments;
        var attempt = try scheduler.reserveRunNow(allocator, execution_context.workspace_root, job_id);
        defer attempt.deinit(allocator);
        return renderAttemptEnvelope(allocator, attempt);
    }

    return module.Error.InvalidArguments;
}

fn create(allocator: std.mem.Allocator, workspace_root: []const u8, args: Args) ![]u8 {
    const title = args.title orelse return module.Error.InvalidArguments;
    const target = args.target orelse return module.Error.InvalidArguments;
    const schedule_kind = try scheduler.types.parseScheduleKind(args.schedule_kind orelse return module.Error.InvalidArguments);
    const due_at_ms = args.due_at_ms orelse return module.Error.InvalidArguments;
    var job = try scheduler.createJob(allocator, workspace_root, .{
        .title = title,
        .target_kind = if (args.target_kind) |value| try scheduler.types.parseTargetKind(value) else .prompt,
        .target = target,
        .schedule_kind = schedule_kind,
        .due_at_ms = due_at_ms,
        .interval_ms = args.interval_ms,
        .misfire_policy = if (args.misfire_policy) |value| try scheduler.types.parseMisfirePolicy(value) else .fire_once,
        .max_catch_up = args.max_catch_up orelse 1,
    });
    defer job.deinit(allocator);
    return renderJobEnvelope(allocator, "create", job);
}

fn setStatus(allocator: std.mem.Allocator, workspace_root: []const u8, maybe_job_id: ?[]const u8, status: scheduler.types.JobStatus, action: []const u8) ![]u8 {
    const job_id = maybe_job_id orelse return module.Error.InvalidArguments;
    var job = try scheduler.setStatus(allocator, workspace_root, job_id, status);
    defer job.deinit(allocator);
    return renderJobEnvelope(allocator, action, job);
}

fn renderJobEnvelope(allocator: std.mem.Allocator, action: []const u8, job: scheduler.types.ScheduleJob) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().writeAll("{\"ok\":true,\"tool\":\"schedule_job\",\"action\":");
    try output.writer().print("{f}", .{std.json.fmt(action, .{})});
    try output.writer().writeAll(",\"job\":");
    try writeJobJson(output.writer(), job);
    try output.writer().writeAll("}");
    return output.toOwnedSlice();
}

fn renderListEnvelope(allocator: std.mem.Allocator, jobs: []const scheduler.types.ScheduleJob) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    try output.writer().writeAll("{\"ok\":true,\"tool\":\"schedule_job\",\"action\":\"list\",\"jobs\":[");
    for (jobs, 0..) |job, index| {
        if (index > 0) try output.writer().writeAll(",");
        try writeJobJson(output.writer(), job);
    }
    try output.writer().writeAll("]}");
    return output.toOwnedSlice();
}

fn renderAttemptEnvelope(allocator: std.mem.Allocator, attempt: scheduler.types.ScheduleAttempt) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"tool\":\"schedule_job\",\"action\":\"run_now\",\"attempt\":{{\"attempt_id\":{f},\"job_id\":{f},\"idempotency_key\":{f},\"due_at_ms\":{d},\"started_at_ms\":{d},\"status\":{f}}}}}",
        .{
            std.json.fmt(attempt.attempt_id, .{}),
            std.json.fmt(attempt.job_id, .{}),
            std.json.fmt(attempt.idempotency_key, .{}),
            attempt.due_at_ms,
            attempt.started_at_ms,
            std.json.fmt(attempt.status.label(), .{}),
        },
    );
}

fn writeJobJson(writer: anytype, job: scheduler.types.ScheduleJob) !void {
    try writer.writeAll("{\"id\":");
    try writer.print("{f}", .{std.json.fmt(job.id, .{})});
    try writer.writeAll(",\"title\":");
    try writer.print("{f}", .{std.json.fmt(job.title, .{})});
    try writer.writeAll(",\"target_kind\":");
    try writer.print("{f}", .{std.json.fmt(job.target_kind.label(), .{})});
    try writer.writeAll(",\"target\":");
    try writer.print("{f}", .{std.json.fmt(job.target, .{})});
    try writer.writeAll(",\"schedule_kind\":");
    try writer.print("{f}", .{std.json.fmt(job.schedule_kind.label(), .{})});
    try writer.print(",\"due_at_ms\":{d}", .{job.due_at_ms});
    if (job.interval_ms) |interval_ms| try writer.print(",\"interval_ms\":{d}", .{interval_ms});
    try writer.print(",\"next_due_at_ms\":{d}", .{job.next_due_at_ms});
    try writer.writeAll(",\"status\":");
    try writer.print("{f}", .{std.json.fmt(job.status.label(), .{})});
    try writer.writeAll(",\"misfire_policy\":");
    try writer.print("{f}", .{std.json.fmt(job.misfire_policy.label(), .{})});
    try writer.print(",\"max_catch_up\":{d},\"created_at_ms\":{d},\"updated_at_ms\":{d},\"revision\":{d}}}", .{
        job.max_catch_up,
        job.created_at_ms,
        job.updated_at_ms,
        job.revision,
    });
}

test "schedule_job tool creates lists and reserves attempts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    const created = try execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"t\",\"target\":\"hello\",\"schedule_kind\":\"once\",\"due_at_ms\":1}");
    defer allocator.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"action\":\"create\"") != null);

    const listed = try execute(allocator, ctx, "{\"action\":\"list\"}");
    defer allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"jobs\":[") != null);
}
