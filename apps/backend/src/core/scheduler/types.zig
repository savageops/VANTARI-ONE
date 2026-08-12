const std = @import("std");

pub const JobStatus = enum {
    active,
    paused,
    completed,
    deleted,

    pub fn label(self: JobStatus) []const u8 {
        return switch (self) {
            .active => "active",
            .paused => "paused",
            .completed => "completed",
            .deleted => "deleted",
        };
    }
};

pub const ScheduleKind = enum {
    once,
    interval,

    pub fn label(self: ScheduleKind) []const u8 {
        return switch (self) {
            .once => "once",
            .interval => "interval",
        };
    }
};

pub const MisfirePolicy = enum {
    fire_once,
    skip,

    pub fn label(self: MisfirePolicy) []const u8 {
        return switch (self) {
            .fire_once => "fire_once",
            .skip => "skip",
        };
    }
};

pub const TargetKind = enum {
    prompt,
    shell,

    pub fn label(self: TargetKind) []const u8 {
        return switch (self) {
            .prompt => "prompt",
            .shell => "shell",
        };
    }
};

pub const ScheduleJob = struct {
    id: []u8,
    title: []u8,
    target_kind: TargetKind,
    target: []u8,
    schedule_kind: ScheduleKind,
    due_at_ms: i64,
    interval_ms: ?i64 = null,
    next_due_at_ms: i64,
    status: JobStatus,
    misfire_policy: MisfirePolicy = .fire_once,
    max_catch_up: u16 = 1,
    created_at_ms: i64,
    updated_at_ms: i64,
    revision: u64 = 1,

    pub fn deinit(self: ScheduleJob, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.target);
    }
};

pub const ScheduleEvent = struct {
    event_type: []const u8,
    job_id: []const u8,
    timestamp_ms: i64,
    revision: u64,
};

pub const AttemptStatus = enum {
    reserved,
    completed,
    failed,

    pub fn label(self: AttemptStatus) []const u8 {
        return switch (self) {
            .reserved => "reserved",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub const ScheduleAttempt = struct {
    attempt_id: []u8,
    job_id: []u8,
    idempotency_key: []u8,
    due_at_ms: i64,
    started_at_ms: i64,
    finished_at_ms: ?i64 = null,
    status: AttemptStatus,

    pub fn deinit(self: ScheduleAttempt, allocator: std.mem.Allocator) void {
        allocator.free(self.attempt_id);
        allocator.free(self.job_id);
        allocator.free(self.idempotency_key);
    }
};

pub const SchedulerLease = struct {
    owner_id: []u8,
    generation: u64,
    acquired_at_ms: i64,
    expires_at_ms: i64,

    pub fn deinit(self: SchedulerLease, allocator: std.mem.Allocator) void {
        allocator.free(self.owner_id);
    }
};

pub fn parseJobStatus(value: []const u8) !JobStatus {
    if (std.mem.eql(u8, value, "active")) return .active;
    if (std.mem.eql(u8, value, "paused")) return .paused;
    if (std.mem.eql(u8, value, "completed")) return .completed;
    if (std.mem.eql(u8, value, "deleted")) return .deleted;
    return error.InvalidScheduleStatus;
}

pub fn parseScheduleKind(value: []const u8) !ScheduleKind {
    if (std.mem.eql(u8, value, "once")) return .once;
    if (std.mem.eql(u8, value, "interval")) return .interval;
    return error.InvalidScheduleKind;
}

pub fn parseMisfirePolicy(value: []const u8) !MisfirePolicy {
    if (std.mem.eql(u8, value, "fire_once")) return .fire_once;
    if (std.mem.eql(u8, value, "skip")) return .skip;
    return error.InvalidMisfirePolicy;
}

pub fn parseTargetKind(value: []const u8) !TargetKind {
    if (std.mem.eql(u8, value, "prompt")) return .prompt;
    if (std.mem.eql(u8, value, "shell")) return .shell;
    return error.InvalidTargetKind;
}
