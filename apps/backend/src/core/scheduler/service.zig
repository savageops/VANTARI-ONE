const std = @import("std");

const loop = @import("../executor/loop.zig");
const provider = @import("../providers/openai_compatible.zig");
const scheduler = @import("index.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const TickResult = struct {
    due_count: usize = 0,
    executed_count: usize = 0,
    failed_count: usize = 0,
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    owner_id: []u8,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const types.Config,
        transport: provider.Transport,
    ) !Service {
        return .{
            .allocator = allocator,
            .config = config,
            .transport = transport,
            .owner_id = try std.fmt.allocPrint(allocator, "scheduler-{d}-{x}", .{ std.time.milliTimestamp(), std.crypto.random.int(u64) }),
        };
    }

    pub fn deinit(self: *Service) void {
        self.allocator.free(self.owner_id);
    }

    pub fn requestStop(self: *Service) void {
        self.stop_requested.store(true, .release);
    }

    pub fn run(self: *Service) void {
        while (!self.stop_requested.load(.acquire)) {
            _ = self.tick() catch {};
            std.Thread.sleep(1000 * std.time.ns_per_ms);
        }
    }

    pub fn tick(self: *Service) !TickResult {
        const now = std.time.milliTimestamp();
        const lease = scheduler.tryAcquireLease(self.allocator, self.config.workspace_root, self.owner_id, now, 5000) catch |err| switch (err) {
            scheduler.store.Error.LeaseUnavailable => return .{},
            else => return err,
        };
        defer lease.deinit(self.allocator);

        const due = try scheduler.dueJobs(self.allocator, self.config.workspace_root, now, 16);
        defer {
            for (due) |job| job.deinit(self.allocator);
            self.allocator.free(due);
        }

        var result = TickResult{ .due_count = due.len };
        for (due) |job| {
            var attempt = scheduler.reserveDueAttempt(self.allocator, self.config.workspace_root, job.id, now) catch |err| switch (err) {
                scheduler.store.Error.ScheduleNotFound => continue,
                else => return err,
            };
            defer attempt.deinit(self.allocator);

            const ok = self.executeJob(job) catch false;
            try scheduler.completeAttempt(
                self.allocator,
                self.config.workspace_root,
                attempt,
                if (ok) .completed else .failed,
                std.time.milliTimestamp(),
            );
            if (ok) result.executed_count += 1 else result.failed_count += 1;
        }
        return result;
    }

    fn executeJob(self: *Service, job: scheduler.types.ScheduleJob) !bool {
        return switch (job.target_kind) {
            .prompt => try self.executePrompt(job),
            .shell => try self.executeShell(job),
        };
    }

    fn executePrompt(self: *Service, job: scheduler.types.ScheduleJob) !bool {
        var session = try @import("../sessions/store.zig").initSessionWithOptions(self.allocator, self.config.workspace_root, job.target, .{
            .display_name = job.title,
        });
        defer session.deinit(self.allocator);

        const result = loop.runPromptWithOptions(self.allocator, self.config.*, "", .{
            .transport = self.transport,
            .execution_context = .{
                .workspace_root = self.config.workspace_root,
            },
            .session_id = session.id,
        }) catch return false;
        defer result.deinit(self.allocator);
        return true;
    }

    fn executeShell(self: *Service, job: scheduler.types.ScheduleJob) !bool {
        const args_json = try std.fmt.allocPrint(
            self.allocator,
            "{{\"mode\":\"shell\",\"command\":{f},\"cwd\":\".\",\"timeout_ms\":60000,\"max_output_bytes\":65536}}",
            .{std.json.fmt(job.target, .{})},
        );
        defer self.allocator.free(args_json);

        const tool_call = types.ToolCall{
            .id = try self.allocator.dupe(u8, "scheduled-shell"),
            .name = try self.allocator.dupe(u8, "shell_exec"),
            .arguments_json = args_json,
        };
        defer {
            self.allocator.free(tool_call.id);
            self.allocator.free(tool_call.name);
        }

        const output = try tools.execute(self.allocator, .{ .workspace_root = self.config.workspace_root }, tool_call);
        defer self.allocator.free(output);
        return std.mem.indexOf(u8, output, "\"exit_code\":0") != null and
            std.mem.indexOf(u8, output, "\"timed_out\":true") == null;
    }
};

test "scheduler service tick ignores empty schedule set" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = types.Config{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1"),
        .openai_api_key = try allocator.dupe(u8, "x"),
        .openai_model = try allocator.dupe(u8, "model"),
        .max_steps = 1,
        .workspace_root = try allocator.dupe(u8, workspace),
    };
    defer config.deinit(allocator);

    var service = try Service.init(allocator, &config, .{ .context = null, .sendFn = provider.httpSend });
    defer service.deinit();
    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), result.due_count);
}

test "scheduler service executes due shell target and advances once job" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = types.Config{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1"),
        .openai_api_key = try allocator.dupe(u8, "x"),
        .openai_model = try allocator.dupe(u8, "model"),
        .max_steps = 1,
        .workspace_root = try allocator.dupe(u8, workspace),
    };
    defer config.deinit(allocator);

    var job = try scheduler.createJob(allocator, workspace, .{
        .title = "shell",
        .target_kind = .shell,
        .target = "echo scheduled",
        .schedule_kind = .once,
        .due_at_ms = 1,
    });
    defer job.deinit(allocator);

    var service = try Service.init(allocator, &config, .{ .context = null, .sendFn = provider.httpSend });
    defer service.deinit();
    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), result.due_count);
    try std.testing.expectEqual(@as(usize, 1), result.executed_count);

    var advanced = try scheduler.readJob(allocator, workspace, job.id);
    defer advanced.deinit(allocator);
    try std.testing.expectEqual(scheduler.types.JobStatus.completed, advanced.status);
}
