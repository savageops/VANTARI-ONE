const std = @import("std");
const fsutil = @import("../../shared/fsutil.zig");
const process_lock = @import("../../shared/process_lock.zig");
pub const types = @import("types.zig");

pub const Error = error{
    InvalidSchedule,
    InvalidScheduleKind,
    InvalidScheduleStatus,
    InvalidMisfirePolicy,
    InvalidTargetKind,
    ScheduleNotFound,
    LeaseUnavailable,
};

const ParsedJob = struct {
    id: []const u8,
    title: []const u8,
    target_kind: []const u8,
    target: []const u8,
    schedule_kind: []const u8,
    due_at_ms: i64,
    interval_ms: ?i64 = null,
    next_due_at_ms: i64,
    status: []const u8,
    misfire_policy: []const u8 = "fire_once",
    max_catch_up: u16 = 1,
    created_at_ms: i64,
    updated_at_ms: i64,
    revision: u64 = 1,
};

const ParsedLease = struct {
    owner_id: []const u8,
    generation: u64 = 0,
    acquired_at_ms: i64,
    expires_at_ms: i64,
};

pub const LeaseGuard = struct {
    lease: types.SchedulerLease,
    lock: process_lock.FileLock,

    pub fn deinit(self: *LeaseGuard, allocator: std.mem.Allocator) void {
        self.lease.deinit(allocator);
        self.lock.deinit();
        self.* = undefined;
    }
};

pub const CreateOptions = struct {
    title: []const u8,
    target_kind: types.TargetKind = .prompt,
    target: []const u8,
    schedule_kind: types.ScheduleKind,
    due_at_ms: i64,
    interval_ms: ?i64 = null,
    misfire_policy: types.MisfirePolicy = .fire_once,
    max_catch_up: u16 = 1,
};

pub const UpdateOptions = struct {
    title: ?[]const u8 = null,
    target_kind: ?types.TargetKind = null,
    target: ?[]const u8 = null,
    due_at_ms: ?i64 = null,
    interval_ms: ?i64 = null,
    misfire_policy: ?types.MisfirePolicy = null,
    max_catch_up: ?u16 = null,
};

pub fn createJob(allocator: std.mem.Allocator, workspace_root: []const u8, options: CreateOptions) !types.ScheduleJob {
    try validateOptions(options.schedule_kind, options.due_at_ms, options.interval_ms, options.title, options.target);

    const now = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const id = try std.fmt.allocPrint(allocator, "schedule-{d}-{x}", .{ now, nonce });
    errdefer allocator.free(id);

    const title = try allocator.dupe(u8, options.title);
    errdefer allocator.free(title);
    const target = try allocator.dupe(u8, options.target);
    errdefer allocator.free(target);

    const job = types.ScheduleJob{
        .id = id,
        .title = title,
        .target_kind = options.target_kind,
        .target = target,
        .schedule_kind = options.schedule_kind,
        .due_at_ms = options.due_at_ms,
        .interval_ms = options.interval_ms,
        .next_due_at_ms = options.due_at_ms,
        .status = .active,
        .misfire_policy = options.misfire_policy,
        .max_catch_up = options.max_catch_up,
        .created_at_ms = now,
        .updated_at_ms = now,
    };

    try writeJob(allocator, workspace_root, job);
    try appendEvent(allocator, workspace_root, .{ .event_type = "schedule_created", .job_id = job.id, .timestamp_ms = now, .revision = job.revision });
    return job;
}

pub fn readJob(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8) !types.ScheduleJob {
    const path = try jobPath(allocator, workspace_root, job_id);
    defer allocator.free(path);
    const content = fsutil.readTextAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return Error.ScheduleNotFound,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(ParsedJob, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return .{
        .id = try allocator.dupe(u8, parsed.value.id),
        .title = try allocator.dupe(u8, parsed.value.title),
        .target_kind = try types.parseTargetKind(parsed.value.target_kind),
        .target = try allocator.dupe(u8, parsed.value.target),
        .schedule_kind = try types.parseScheduleKind(parsed.value.schedule_kind),
        .due_at_ms = parsed.value.due_at_ms,
        .interval_ms = parsed.value.interval_ms,
        .next_due_at_ms = parsed.value.next_due_at_ms,
        .status = try types.parseJobStatus(parsed.value.status),
        .misfire_policy = try types.parseMisfirePolicy(parsed.value.misfire_policy),
        .max_catch_up = parsed.value.max_catch_up,
        .created_at_ms = parsed.value.created_at_ms,
        .updated_at_ms = parsed.value.updated_at_ms,
        .revision = parsed.value.revision,
    };
}

pub fn listJobs(allocator: std.mem.Allocator, workspace_root: []const u8, include_deleted: bool) ![]types.ScheduleJob {
    const root = try jobsRoot(allocator, workspace_root);
    defer allocator.free(root);
    if (!fsutil.fileExists(root)) return allocator.alloc(types.ScheduleJob, 0);

    const root_abs = try fsutil.resolveAbsolute(allocator, root);
    defer allocator.free(root_abs);
    var dir = try std.fs.openDirAbsolute(root_abs, .{ .iterate = true });
    defer dir.close();

    var jobs: std.ArrayList(types.ScheduleJob) = .empty;
    errdefer {
        for (jobs.items) |job| job.deinit(allocator);
        jobs.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const job_id = entry.name[0 .. entry.name.len - ".json".len];
        const job = readJob(allocator, workspace_root, job_id) catch continue;
        if (!include_deleted and job.status == .deleted) {
            job.deinit(allocator);
            continue;
        }
        try jobs.append(allocator, job);
    }

    return jobs.toOwnedSlice(allocator);
}

pub fn updateJob(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8, options: UpdateOptions) !types.ScheduleJob {
    var job = try readJob(allocator, workspace_root, job_id);
    errdefer job.deinit(allocator);
    if (job.status == .deleted) return Error.ScheduleNotFound;

    if (options.title) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.InvalidSchedule;
        allocator.free(job.title);
        job.title = try allocator.dupe(u8, value);
    }
    if (options.target_kind) |value| job.target_kind = value;
    if (options.target) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len == 0) return Error.InvalidSchedule;
        allocator.free(job.target);
        job.target = try allocator.dupe(u8, value);
    }
    if (options.due_at_ms) |value| {
        if (value < 0) return Error.InvalidSchedule;
        job.due_at_ms = value;
        job.next_due_at_ms = value;
    }
    if (options.interval_ms) |value| {
        if (job.schedule_kind != .interval or value <= 0) return Error.InvalidSchedule;
        job.interval_ms = value;
    }
    if (options.misfire_policy) |value| job.misfire_policy = value;
    if (options.max_catch_up) |value| job.max_catch_up = @max(1, value);
    job.revision += 1;
    job.updated_at_ms = std.time.milliTimestamp();

    try writeJob(allocator, workspace_root, job);
    try appendEvent(allocator, workspace_root, .{ .event_type = "schedule_updated", .job_id = job.id, .timestamp_ms = job.updated_at_ms, .revision = job.revision });
    return job;
}

pub fn setStatus(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8, status: types.JobStatus) !types.ScheduleJob {
    var job = try readJob(allocator, workspace_root, job_id);
    errdefer job.deinit(allocator);
    if (job.status == .deleted and status != .deleted) return Error.ScheduleNotFound;
    job.status = status;
    job.revision += 1;
    job.updated_at_ms = std.time.milliTimestamp();
    try writeJob(allocator, workspace_root, job);
    const event_type = switch (status) {
        .active => "schedule_resumed",
        .paused => "schedule_paused",
        .completed => "schedule_completed",
        .deleted => "schedule_deleted",
    };
    try appendEvent(allocator, workspace_root, .{ .event_type = event_type, .job_id = job.id, .timestamp_ms = job.updated_at_ms, .revision = job.revision });
    return job;
}

pub fn dueJobs(allocator: std.mem.Allocator, workspace_root: []const u8, now_ms: i64, limit: usize) ![]types.ScheduleJob {
    const jobs = try listJobs(allocator, workspace_root, false);
    defer {
        for (jobs) |job| job.deinit(allocator);
        allocator.free(jobs);
    }

    var due: std.ArrayList(types.ScheduleJob) = .empty;
    errdefer {
        for (due.items) |job| job.deinit(allocator);
        due.deinit(allocator);
    }

    for (jobs) |job| {
        if (due.items.len >= limit) break;
        if (job.status != .active or job.next_due_at_ms > now_ms) continue;
        try due.append(allocator, try cloneJob(allocator, job));
    }

    return due.toOwnedSlice(allocator);
}

pub fn reserveDueAttempt(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8, now_ms: i64) !types.ScheduleAttempt {
    var job = try readJob(allocator, workspace_root, job_id);
    defer job.deinit(allocator);
    if (job.status != .active or job.next_due_at_ms > now_ms) return Error.ScheduleNotFound;

    const attempt = try reserveAttemptForJob(allocator, workspace_root, job, now_ms);
    try advanceAfterReservation(allocator, workspace_root, &job, now_ms);
    try appendEvent(allocator, workspace_root, .{ .event_type = "schedule_due_reserved", .job_id = job.id, .timestamp_ms = now_ms, .revision = job.revision });
    return attempt;
}

pub fn completeAttempt(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    attempt: types.ScheduleAttempt,
    status: types.AttemptStatus,
    finished_at_ms: i64,
) !void {
    var completed = types.ScheduleAttempt{
        .attempt_id = try allocator.dupe(u8, attempt.attempt_id),
        .job_id = try allocator.dupe(u8, attempt.job_id),
        .idempotency_key = try allocator.dupe(u8, attempt.idempotency_key),
        .due_at_ms = attempt.due_at_ms,
        .started_at_ms = attempt.started_at_ms,
        .finished_at_ms = finished_at_ms,
        .status = status,
    };
    defer completed.deinit(allocator);
    try appendAttempt(allocator, workspace_root, completed);
    try appendEvent(allocator, workspace_root, .{
        .event_type = if (status == .completed) "schedule_attempt_completed" else "schedule_attempt_failed",
        .job_id = attempt.job_id,
        .timestamp_ms = finished_at_ms,
        .revision = 0,
    });
}

pub fn tryAcquireLease(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    owner_id: []const u8,
    generation: u64,
    now_ms: i64,
    ttl_ms: i64,
) !LeaseGuard {
    if (ttl_ms <= 0 or generation == 0) return Error.InvalidSchedule;

    const lock_path = try schedulesPath(allocator, workspace_root, "lease.lock");
    defer allocator.free(lock_path);
    var lock = process_lock.acquire(lock_path, 0) catch |err| switch (err) {
        error.LockUnavailable => return Error.LeaseUnavailable,
        else => return err,
    };
    errdefer lock.deinit();

    const existing = readLease(allocator, workspace_root) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (existing) |lease| lease.deinit(allocator);

    if (existing) |lease| {
        if (lease.expires_at_ms > now_ms and
            (!std.mem.eql(u8, lease.owner_id, owner_id) or lease.generation != generation))
        {
            return Error.LeaseUnavailable;
        }
    }

    const lease = types.SchedulerLease{
        .owner_id = try allocator.dupe(u8, owner_id),
        .generation = generation,
        .acquired_at_ms = now_ms,
        .expires_at_ms = now_ms + ttl_ms,
    };
    errdefer lease.deinit(allocator);
    try writeLease(allocator, workspace_root, lease);

    const persisted = try readLease(allocator, workspace_root);
    defer persisted.deinit(allocator);
    if (!std.mem.eql(u8, persisted.owner_id, lease.owner_id) or
        persisted.generation != lease.generation or
        persisted.acquired_at_ms != lease.acquired_at_ms or
        persisted.expires_at_ms != lease.expires_at_ms)
    {
        return Error.LeaseUnavailable;
    }

    return .{ .lease = lease, .lock = lock };
}

pub fn reserveRunNow(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8) !types.ScheduleAttempt {
    const job = try readJob(allocator, workspace_root, job_id);
    defer job.deinit(allocator);
    if (job.status == .deleted) return Error.ScheduleNotFound;

    return reserveAttemptForJob(allocator, workspace_root, job, std.time.milliTimestamp());
}

fn reserveAttemptForJob(allocator: std.mem.Allocator, workspace_root: []const u8, job: types.ScheduleJob, now: i64) !types.ScheduleAttempt {
    const attempt_id = try std.fmt.allocPrint(allocator, "attempt-{d}-{x}", .{ now, std.crypto.random.int(u64) });
    errdefer allocator.free(attempt_id);
    const owned_job_id = try allocator.dupe(u8, job.id);
    errdefer allocator.free(owned_job_id);
    const idempotency_key = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{ job.id, job.next_due_at_ms, job.revision });
    errdefer allocator.free(idempotency_key);

    const attempt = types.ScheduleAttempt{
        .attempt_id = attempt_id,
        .job_id = owned_job_id,
        .idempotency_key = idempotency_key,
        .due_at_ms = job.next_due_at_ms,
        .started_at_ms = now,
        .status = .reserved,
    };
    try appendAttempt(allocator, workspace_root, attempt);
    try appendEvent(allocator, workspace_root, .{ .event_type = "schedule_attempt_reserved", .job_id = job.id, .timestamp_ms = now, .revision = job.revision });
    return attempt;
}

pub fn writeJob(allocator: std.mem.Allocator, workspace_root: []const u8, job: types.ScheduleJob) !void {
    const path = try jobPath(allocator, workspace_root, job.id);
    defer allocator.free(path);
    const payload = .{
        .id = job.id,
        .title = job.title,
        .target_kind = job.target_kind.label(),
        .target = job.target,
        .schedule_kind = job.schedule_kind.label(),
        .due_at_ms = job.due_at_ms,
        .interval_ms = job.interval_ms,
        .next_due_at_ms = job.next_due_at_ms,
        .status = job.status.label(),
        .misfire_policy = job.misfire_policy.label(),
        .max_catch_up = job.max_catch_up,
        .created_at_ms = job.created_at_ms,
        .updated_at_ms = job.updated_at_ms,
        .revision = job.revision,
    };
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(payload, .{ .whitespace = .indent_2 })});
    defer allocator.free(json);
    try fsutil.writeText(path, json);
}

fn appendEvent(allocator: std.mem.Allocator, workspace_root: []const u8, event: types.ScheduleEvent) !void {
    const path = try schedulesPath(allocator, workspace_root, "events.jsonl");
    defer allocator.free(path);
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(event, .{})});
    defer allocator.free(json);
    try fsutil.appendText(path, json);
}

fn appendAttempt(allocator: std.mem.Allocator, workspace_root: []const u8, attempt: types.ScheduleAttempt) !void {
    const path = try schedulesPath(allocator, workspace_root, "attempts.jsonl");
    defer allocator.free(path);
    const payload = .{
        .attempt_id = attempt.attempt_id,
        .job_id = attempt.job_id,
        .idempotency_key = attempt.idempotency_key,
        .due_at_ms = attempt.due_at_ms,
        .started_at_ms = attempt.started_at_ms,
        .finished_at_ms = attempt.finished_at_ms,
        .status = attempt.status.label(),
    };
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(payload, .{})});
    defer allocator.free(json);
    try fsutil.appendText(path, json);
}

fn advanceAfterReservation(allocator: std.mem.Allocator, workspace_root: []const u8, job: *types.ScheduleJob, now_ms: i64) !void {
    switch (job.schedule_kind) {
        .once => job.status = .completed,
        .interval => {
            const interval_ms = job.interval_ms orelse return Error.InvalidSchedule;
            var next_due = job.next_due_at_ms + interval_ms;
            if (job.misfire_policy == .skip) {
                while (next_due <= now_ms) next_due += interval_ms;
            } else if (job.max_catch_up <= 1 and next_due <= now_ms) {
                next_due = now_ms + interval_ms;
            }
            job.next_due_at_ms = next_due;
        },
    }
    job.revision += 1;
    job.updated_at_ms = now_ms;
    try writeJob(allocator, workspace_root, job.*);
}

fn readLease(allocator: std.mem.Allocator, workspace_root: []const u8) !types.SchedulerLease {
    const path = try schedulesPath(allocator, workspace_root, "lease.json");
    defer allocator.free(path);
    const content = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(content);
    var parsed = try std.json.parseFromSlice(ParsedLease, allocator, content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .owner_id = try allocator.dupe(u8, parsed.value.owner_id),
        .generation = parsed.value.generation,
        .acquired_at_ms = parsed.value.acquired_at_ms,
        .expires_at_ms = parsed.value.expires_at_ms,
    };
}

fn writeLease(allocator: std.mem.Allocator, workspace_root: []const u8, lease: types.SchedulerLease) !void {
    const path = try schedulesPath(allocator, workspace_root, "lease.json");
    defer allocator.free(path);
    const json = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(lease, .{ .whitespace = .indent_2 })});
    defer allocator.free(json);
    try fsutil.writeText(path, json);
}

fn cloneJob(allocator: std.mem.Allocator, job: types.ScheduleJob) !types.ScheduleJob {
    return .{
        .id = try allocator.dupe(u8, job.id),
        .title = try allocator.dupe(u8, job.title),
        .target_kind = job.target_kind,
        .target = try allocator.dupe(u8, job.target),
        .schedule_kind = job.schedule_kind,
        .due_at_ms = job.due_at_ms,
        .interval_ms = job.interval_ms,
        .next_due_at_ms = job.next_due_at_ms,
        .status = job.status,
        .misfire_policy = job.misfire_policy,
        .max_catch_up = job.max_catch_up,
        .created_at_ms = job.created_at_ms,
        .updated_at_ms = job.updated_at_ms,
        .revision = job.revision,
    };
}

fn validateOptions(kind: types.ScheduleKind, due_at_ms: i64, interval_ms: ?i64, title: []const u8, target: []const u8) !void {
    if (std.mem.trim(u8, title, " \t\r\n").len == 0) return Error.InvalidSchedule;
    if (std.mem.trim(u8, target, " \t\r\n").len == 0) return Error.InvalidSchedule;
    if (due_at_ms < 0) return Error.InvalidSchedule;
    if (kind == .interval and (interval_ms orelse 0) <= 0) return Error.InvalidSchedule;
    if (kind == .once and interval_ms != null) return Error.InvalidSchedule;
}

fn schedulesPath(allocator: std.mem.Allocator, workspace_root: []const u8, leaf: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const sched_dir = try fsutil.join(allocator, &.{ root, "schedules" });
    defer allocator.free(sched_dir);
    std.fs.cwd().makePath(sched_dir) catch {};
    return fsutil.join(allocator, &.{ root, "schedules", leaf });
}

fn jobsRoot(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const jobs_dir = try fsutil.join(allocator, &.{ root, "schedules", "jobs" });
    std.fs.cwd().makePath(jobs_dir) catch {};
    return jobs_dir;
}

fn jobPath(allocator: std.mem.Allocator, workspace_root: []const u8, job_id: []const u8) ![]u8 {
    const leaf = try std.fmt.allocPrint(allocator, "{s}.json", .{job_id});
    defer allocator.free(leaf);
    const root = try fsutil.runtimeRootForWorkspace(allocator, workspace_root);
    defer allocator.free(root);
    const jobs_dir = try fsutil.join(allocator, &.{ root, "schedules", "jobs" });
    defer allocator.free(jobs_dir);
    std.fs.cwd().makePath(jobs_dir) catch {};
    return fsutil.join(allocator, &.{ root, "schedules", "jobs", leaf });
}

test "scheduler store creates durable job and run-now attempt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var job = try createJob(allocator, workspace, .{
        .title = "remind",
        .target = "say hello",
        .schedule_kind = .once,
        .due_at_ms = 1234,
    });
    defer job.deinit(allocator);
    try std.testing.expectEqualStrings("remind", job.title);
    try std.testing.expectEqual(types.JobStatus.active, job.status);

    var loaded = try readJob(allocator, workspace, job.id);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings(job.id, loaded.id);

    var attempt = try reserveRunNow(allocator, workspace, job.id);
    defer attempt.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, attempt.idempotency_key, job.id));
}

test "scheduler store rejects invalid interval and soft deletes jobs" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    try std.testing.expectError(Error.InvalidSchedule, createJob(allocator, workspace, .{
        .title = "bad",
        .target = "x",
        .schedule_kind = .interval,
        .due_at_ms = 1,
    }));

    var job = try createJob(allocator, workspace, .{
        .title = "ok",
        .target = "x",
        .schedule_kind = .interval,
        .due_at_ms = 1,
        .interval_ms = 1000,
    });
    defer job.deinit(allocator);

    var deleted = try setStatus(allocator, workspace, job.id, .deleted);
    defer deleted.deinit(allocator);
    try std.testing.expectEqual(types.JobStatus.deleted, deleted.status);
    try std.testing.expectError(Error.ScheduleNotFound, reserveRunNow(allocator, workspace, job.id));
}

test "scheduler lease excludes concurrent generations and fences failover" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var first = try tryAcquireLease(allocator, workspace, "scheduler-a", 11, 100, 50);
    try std.testing.expectEqual(@as(u64, 11), first.lease.generation);
    try std.testing.expectError(Error.LeaseUnavailable, tryAcquireLease(allocator, workspace, "scheduler-b", 22, 100, 50));
    try std.testing.expectError(Error.LeaseUnavailable, tryAcquireLease(allocator, workspace, "scheduler-a", 12, 100, 50));
    first.deinit(allocator);

    try std.testing.expectError(Error.LeaseUnavailable, tryAcquireLease(allocator, workspace, "scheduler-b", 22, 149, 50));

    var successor = try tryAcquireLease(allocator, workspace, "scheduler-b", 22, 151, 50);
    defer successor.deinit(allocator);
    try std.testing.expectEqualStrings("scheduler-b", successor.lease.owner_id);
    try std.testing.expectEqual(@as(u64, 22), successor.lease.generation);
    try std.testing.expectEqual(@as(i64, 201), successor.lease.expires_at_ms);
}

test "scheduler lease race yields exactly one generation" {
    const Race = struct {
        const Outcome = enum { pending, won, unavailable, failed };
        const Context = struct {
            allocator: std.mem.Allocator,
            workspace: []const u8,
            owner_id: []const u8,
            generation: u64,
            ready: *std.atomic.Value(u8),
            start: *std.atomic.Value(bool),
            resolved: *std.atomic.Value(u8),
            outcome: *Outcome,
        };

        fn contend(context: Context) void {
            _ = context.ready.fetchAdd(1, .acq_rel);
            while (!context.start.load(.acquire)) std.atomic.spinLoopHint();

            var guard = tryAcquireLease(
                context.allocator,
                context.workspace,
                context.owner_id,
                context.generation,
                100,
                50,
            ) catch |err| {
                context.outcome.* = if (err == Error.LeaseUnavailable) .unavailable else .failed;
                _ = context.resolved.fetchAdd(1, .acq_rel);
                return;
            };
            context.outcome.* = .won;
            _ = context.resolved.fetchAdd(1, .acq_rel);
            while (context.resolved.load(.acquire) < 2) std.atomic.spinLoopHint();
            guard.deinit(context.allocator);
        }
    };

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);

    var ready = std.atomic.Value(u8).init(0);
    var start = std.atomic.Value(bool).init(false);
    var resolved = std.atomic.Value(u8).init(0);
    var first_outcome: Race.Outcome = .pending;
    var second_outcome: Race.Outcome = .pending;
    const common = .{
        .allocator = allocator,
        .workspace = workspace,
        .ready = &ready,
        .start = &start,
        .resolved = &resolved,
    };
    var first = try std.Thread.spawn(.{}, Race.contend, .{Race.Context{
        .allocator = common.allocator,
        .workspace = common.workspace,
        .owner_id = "scheduler-race-a",
        .generation = 31,
        .ready = common.ready,
        .start = common.start,
        .resolved = common.resolved,
        .outcome = &first_outcome,
    }});
    var second = try std.Thread.spawn(.{}, Race.contend, .{Race.Context{
        .allocator = common.allocator,
        .workspace = common.workspace,
        .owner_id = "scheduler-race-b",
        .generation = 32,
        .ready = common.ready,
        .start = common.start,
        .resolved = common.resolved,
        .outcome = &second_outcome,
    }});
    while (ready.load(.acquire) < 2) std.atomic.spinLoopHint();
    start.store(true, .release);
    first.join();
    second.join();

    const winners: u8 = @intFromBool(first_outcome == .won) + @intFromBool(second_outcome == .won);
    const unavailable: u8 = @intFromBool(first_outcome == .unavailable) + @intFromBool(second_outcome == .unavailable);
    try std.testing.expectEqual(@as(u8, 1), winners);
    try std.testing.expectEqual(@as(u8, 1), unavailable);
}
