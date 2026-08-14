const std = @import("std");

const loop = @import("../executor/loop.zig");
const sessions = @import("../sessions/store.zig");
const tickets = @import("../tickets/index.zig");
const provider = @import("../providers/openai_compatible.zig");
const scheduler = @import("index.zig");
const tools = @import("../tools/runtime.zig");
const types = @import("../../shared/types.zig");

pub const TickResult = struct {
    due_count: usize = 0,
    executed_count: usize = 0,
    failed_count: usize = 0,
    ticket_due_count: usize = 0,
    ticket_started_count: usize = 0,
    ticket_resumed_count: usize = 0,
    ticket_renewed_count: usize = 0,
    ticket_requeued_count: usize = 0,
    ticket_completed_count: usize = 0,
    ticket_blocked_count: usize = 0,
    ticket_failed_count: usize = 0,
};

const ticket_lease_ttl_ms: i64 = 30_000;
const ticket_heartbeat_window_ms: i64 = 10_000;
const ticket_dispatch_limit: usize = 16;

pub const Service = struct {
    allocator: std.mem.Allocator,
    config: *const types.Config,
    transport: provider.Transport,
    owner_id: []u8,
    agent_service: ?tools.AgentService = null,
    worker_generation: u64,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const types.Config,
        transport: provider.Transport,
    ) !Service {
        return initWithAgentService(allocator, config, transport, null);
    }

    pub fn initWithAgentService(
        allocator: std.mem.Allocator,
        config: *const types.Config,
        transport: provider.Transport,
        agent_service: ?tools.AgentService,
    ) !Service {
        var worker_generation = std.crypto.random.int(u64);
        if (worker_generation == 0) worker_generation = 1;
        return .{
            .allocator = allocator,
            .config = config,
            .transport = transport,
            .owner_id = try std.fmt.allocPrint(allocator, "scheduler-{d}-{x}", .{ std.time.milliTimestamp(), std.crypto.random.int(u64) }),
            .agent_service = agent_service,
            .worker_generation = worker_generation,
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
        var lease = scheduler.tryAcquireLease(self.allocator, self.config.workspace_root, self.owner_id, self.worker_generation, now, 5000) catch |err| switch (err) {
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
        try self.tickTickets(now, &result);
        return result;
    }

    fn tickTickets(self: *Service, now_ms: i64, result: *TickResult) !void {
        const ticket_store = tickets.TicketStore.init(self.allocator, self.config.workspace_root);
        try self.reconcileTerminalTickets(&ticket_store, now_ms, result);
        try self.recoverExpiredTickets(&ticket_store, now_ms, result);
        try self.renewLiveTickets(&ticket_store, now_ms, result);
        try self.dispatchAssignedTickets(&ticket_store, now_ms, result);
    }

    /// Settle one expired claim from durable session truth. Existing sessions
    /// resume under a new generation; only absent sessions return to the queue.
    fn recoverExpiredTickets(self: *Service, ticket_store: *const tickets.TicketStore, now_ms: i64, result: *TickResult) !void {
        var projection = try ticket_store.readProjection();
        defer projection.deinit();
        if (projection.poisoned_suffix) {
            result.ticket_failed_count += 1;
            return;
        }

        for (projection.tickets.items) |ticket| {
            if (ticket.status != .in_progress or !ticket.claim_complete or ticket.lease_expires_at_ms <= 0 or ticket.lease_expires_at_ms > now_ms) continue;

            var child = sessions.readSessionRecord(self.allocator, self.config.workspace_root, ticket.active_session_id) catch |err| switch (err) {
                error.FileNotFound => null,
                else => {
                    result.ticket_failed_count += 1;
                    continue;
                },
            };
            defer if (child) |*session| session.deinit(self.allocator);
            if (child) |session| {
                if (session.status == .completed or session.status == .failed or session.status == .cancelled) continue;
                const agent_service = self.agent_service orelse {
                    result.ticket_failed_count += 1;
                    continue;
                };
                const lease_token = try std.fmt.allocPrint(self.allocator, "ticket-resume-lease:{s}:{d}:{d}:{d}", .{ ticket.id, ticket.revision, ticket.attempt, self.worker_generation });
                defer self.allocator.free(lease_token);
                const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-resume:{s}:{d}:{d}:{s}", .{ ticket.id, ticket.revision, ticket.attempt, ticket.active_session_id });
                defer self.allocator.free(idempotency_key);
                const owns_session = agent_service.ownsSession(ticket.active_session_id) catch {
                    result.ticket_failed_count += 1;
                    continue;
                };
                if (owns_session) {
                    var resumed = ticket_store.resumeExpired(.{
                        .ticket_id = ticket.id,
                        .expected_revision = ticket.revision,
                        .worker_id = self.owner_id,
                        .worker_generation = self.worker_generation,
                        .lease_token = lease_token,
                        .lease_expires_at_ms = now_ms + ticket_lease_ttl_ms,
                        .session_id = ticket.active_session_id,
                        .idempotency_key = idempotency_key,
                        .resumed_at_ms = now_ms,
                    }) catch |err| switch (err) {
                        tickets.Error.RevisionConflict, tickets.Error.InvalidResume, tickets.Error.LeaseNotExpired => continue,
                        else => {
                            result.ticket_failed_count += 1;
                            continue;
                        },
                    };
                    resumed.deinit(self.allocator);
                } else {
                    var resumed = agent_service.resumeTicket(self.allocator, .{
                        .ticket_id = ticket.id,
                        .expected_revision = ticket.revision,
                        .worker_id = self.owner_id,
                        .worker_generation = self.worker_generation,
                        .lease_token = lease_token,
                        .lease_expires_at_ms = now_ms + ticket_lease_ttl_ms,
                        .session_id = ticket.active_session_id,
                        .idempotency_key = idempotency_key,
                        .resumed_at_ms = now_ms,
                    }) catch |err| {
                        if (!isRecoveryRaceError(err)) result.ticket_failed_count += 1;
                        continue;
                    };
                    defer resumed.deinit(self.allocator);
                    if (!std.mem.eql(u8, resumed.ticket_id, ticket.id) or !std.mem.eql(u8, resumed.session_id, ticket.active_session_id)) {
                        result.ticket_failed_count += 1;
                        continue;
                    }
                }
                result.ticket_resumed_count += 1;
                continue;
            }

            const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-requeue:{s}:{d}:{d}", .{ ticket.id, ticket.revision, ticket.attempt });
            defer self.allocator.free(idempotency_key);
            var mutation = ticket_store.requeueExpired(.{
                .ticket_id = ticket.id,
                .expected_revision = ticket.revision,
                .reason = "scheduler lease expired",
                .failure_class = "stale_lease",
                .idempotency_key = idempotency_key,
                .requeued_at_ms = now_ms,
            }) catch |err| switch (err) {
                tickets.Error.RevisionConflict, tickets.Error.InvalidTransition, tickets.Error.LeaseNotExpired => continue,
                else => {
                    result.ticket_failed_count += 1;
                    continue;
                },
            };
            mutation.deinit(self.allocator);
            result.ticket_requeued_count += 1;
        }
    }

    fn renewLiveTickets(self: *Service, ticket_store: *const tickets.TicketStore, now_ms: i64, result: *TickResult) !void {
        var projection = try ticket_store.readProjection();
        defer projection.deinit();
        if (projection.poisoned_suffix) {
            result.ticket_failed_count += 1;
            return;
        }

        for (projection.tickets.items) |ticket| {
            if (ticket.status != .in_progress or !ticket.claim_complete or ticket.lease_expires_at_ms <= now_ms) continue;
            if (!std.mem.eql(u8, ticket.worker_id, self.owner_id) or ticket.worker_generation != self.worker_generation) continue;
            if (ticket.lease_expires_at_ms - now_ms > ticket_heartbeat_window_ms) continue;
            const agent_service = self.agent_service orelse continue;
            const owns_session = agent_service.ownsSession(ticket.active_session_id) catch {
                result.ticket_failed_count += 1;
                continue;
            };
            if (!owns_session) continue;

            const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-heartbeat:{s}:{d}:{d}:{d}", .{ ticket.id, ticket.revision, ticket.attempt, ticket.lease_expires_at_ms });
            defer self.allocator.free(idempotency_key);
            var mutation = ticket_store.renewClaim(.{
                .ticket_id = ticket.id,
                .expected_revision = ticket.revision,
                .worker_id = ticket.worker_id,
                .worker_generation = ticket.worker_generation,
                .lease_token = ticket.lease_token,
                .lease_expires_at_ms = now_ms + ticket_lease_ttl_ms,
                .session_id = ticket.active_session_id,
                .idempotency_key = idempotency_key,
                .renewed_at_ms = now_ms,
            }) catch |err| switch (err) {
                tickets.Error.RevisionConflict, tickets.Error.InvalidRenewal, tickets.Error.LeaseExpired => continue,
                else => {
                    result.ticket_failed_count += 1;
                    continue;
                },
            };
            mutation.deinit(self.allocator);
            result.ticket_renewed_count += 1;
        }
    }

    fn reconcileTerminalTickets(self: *Service, ticket_store: *const tickets.TicketStore, now_ms: i64, result: *TickResult) !void {
        var projection = try ticket_store.readProjection();
        defer projection.deinit();
        if (projection.poisoned_suffix) {
            result.ticket_failed_count += 1;
            return;
        }

        for (projection.tickets.items) |ticket| {
            if (ticket.status != .in_progress or !ticket.claim_complete or ticket.active_session_id.len == 0) continue;
            var session = sessions.readSessionRecord(self.allocator, self.config.workspace_root, ticket.active_session_id) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    result.ticket_failed_count += 1;
                    continue;
                },
            };
            defer session.deinit(self.allocator);
            if (session.status != .completed and session.status != .failed and session.status != .cancelled) continue;

            const output = sessions.readOutput(self.allocator, self.config.workspace_root, session.id) catch null;
            defer if (output) |value| self.allocator.free(value);
            const failure = boundedText(session.failure_reason orelse "", 1024);
            const terminal = sessions.readCurrentTurnTerminal(self.allocator, self.config.workspace_root, session.id) catch null;
            defer if (terminal) |value| value.deinit(self.allocator);
            const failure_id = if (terminal) |value| value.failure_id orelse "" else "";
            const terminal_receipt = try std.fmt.allocPrint(self.allocator, "session={s};status={s};output_bytes={d};failure={s};failure_id={s}", .{
                session.id,
                types.statusLabel(session.status),
                if (output) |value| value.len else 0,
                failure,
                failure_id,
            });
            defer self.allocator.free(terminal_receipt);
            const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-complete:{s}:{d}:{d}:{s}", .{ ticket.id, ticket.revision, ticket.attempt, session.id });
            defer self.allocator.free(idempotency_key);
            var mutation = ticket_store.complete(.{
                .ticket_id = ticket.id,
                .expected_revision = ticket.revision,
                .session_id = session.id,
                .lease_token = ticket.lease_token,
                .terminal_receipt = terminal_receipt,
                .failure_id = failure_id,
                .idempotency_key = idempotency_key,
                .completed_at_ms = now_ms,
            }) catch |err| switch (err) {
                tickets.Error.RevisionConflict, tickets.Error.InvalidTerminalEvidence => continue,
                else => {
                    result.ticket_failed_count += 1;
                    continue;
                },
            };
            mutation.deinit(self.allocator);
            result.ticket_completed_count += 1;
        }
    }

    fn dispatchAssignedTickets(self: *Service, ticket_store: *const tickets.TicketStore, now_ms: i64, result: *TickResult) !void {
        const agent_service = self.agent_service orelse return;
        const capacity = agent_service.capacity() catch {
            result.ticket_failed_count += 1;
            return;
        };
        if (capacity.available == 0) return;

        var projection = try ticket_store.readProjection();
        defer projection.deinit();
        if (projection.poisoned_suffix) {
            result.ticket_failed_count += 1;
            return;
        }

        var candidates = std.array_list.Managed(*const tickets.Ticket).init(self.allocator);
        defer candidates.deinit();
        for (projection.tickets.items) |*ticket| {
            if (ticket.status == .assigned) {
                try candidates.append(ticket);
                result.ticket_due_count += 1;
            }
        }
        std.mem.sortUnstable(*const tickets.Ticket, candidates.items, {}, struct {
            fn lessThan(_: void, left: *const tickets.Ticket, right: *const tickets.Ticket) bool {
                if (left.updated_at_ms == right.updated_at_ms) return std.mem.lessThan(u8, left.id, right.id);
                return left.updated_at_ms < right.updated_at_ms;
            }
        }.lessThan);

        const max_dispatch = @min(@min(capacity.available, candidates.items.len), ticket_dispatch_limit);
        for (candidates.items[0..max_dispatch]) |ticket| {
            const attempt = if (ticket.attempt == std.math.maxInt(u32)) ticket.attempt else ticket.attempt + 1;
            const lease_expires_at_ms = now_ms + ticket_lease_ttl_ms;
            const lease_token = try std.fmt.allocPrint(self.allocator, "ticket-lease:{s}:{d}:{d}", .{ ticket.id, ticket.revision, attempt });
            defer self.allocator.free(lease_token);
            const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-claim:{s}:{d}:{d}", .{ ticket.id, ticket.revision, attempt });
            defer self.allocator.free(idempotency_key);

            var launch = agent_service.launchTicket(self.allocator, .{
                .ticket_id = ticket.id,
                .title = ticket.title,
                .description = ticket.description,
                .category = ticket.category,
                .source_session_id = ticket.source_session_id,
                .expected_revision = ticket.revision,
                .worker_id = self.owner_id,
                .worker_generation = self.worker_generation,
                .lease_token = lease_token,
                .lease_expires_at_ms = lease_expires_at_ms,
                .attempt = attempt,
                .agent_hint = ticket.agent_hint,
                .idempotency_key = idempotency_key,
            }) catch |err| {
                if (isBackpressureError(err)) break;
                if (isClaimReplayError(err)) break;
                if (isPermanentLaunchError(err)) try self.blockAssignedTicket(ticket_store, ticket, @errorName(err), now_ms, result) else result.ticket_failed_count += 1;
                continue;
            };
            defer launch.deinit(self.allocator);

            if (!std.mem.eql(u8, launch.ticket_id, ticket.id)) {
                result.ticket_failed_count += 1;
                continue;
            }
            var refreshed = try ticket_store.readProjection();
            const claimed = refreshed.findConst(ticket.id);
            const agrees = claimed != null and claimed.?.status == .in_progress and std.mem.eql(u8, claimed.?.active_session_id, launch.session_id);
            refreshed.deinit();
            if (!agrees) {
                result.ticket_failed_count += 1;
                continue;
            }
            result.ticket_started_count += 1;
        }
    }

    fn blockAssignedTicket(self: *Service, ticket_store: *const tickets.TicketStore, ticket: *const tickets.Ticket, error_name: []const u8, now_ms: i64, result: *TickResult) !void {
        const reason = try std.fmt.allocPrint(self.allocator, "ticket launch blocked: {s}", .{error_name});
        defer self.allocator.free(reason);
        const idempotency_key = try std.fmt.allocPrint(self.allocator, "ticket-block:{s}:{d}", .{ ticket.id, ticket.revision });
        defer self.allocator.free(idempotency_key);
        var mutation = ticket_store.transition(.{
            .ticket_id = ticket.id,
            .status = .blocked,
            .reason = reason,
            .idempotency_key = idempotency_key,
            .source = "scheduler",
            .transitioned_at_ms = now_ms,
        }) catch |err| switch (err) {
            tickets.Error.InvalidTransition, tickets.Error.RevisionConflict, tickets.Error.NoopTransition => return,
            else => return err,
        };
        mutation.deinit(self.allocator);
        result.ticket_blocked_count += 1;
    }

    fn isBackpressureError(err: anyerror) bool {
        const name = @errorName(err);
        return std.mem.eql(u8, name, "PoolFull") or std.mem.eql(u8, name, "AgentServiceUnavailable") or std.mem.eql(u8, name, "OutOfMemory");
    }

    fn isPermanentLaunchError(err: anyerror) bool {
        const name = @errorName(err);
        return std.mem.eql(u8, name, "InvalidBatch") or
            std.mem.eql(u8, name, "MissingParentSession") or
            std.mem.eql(u8, name, "UnknownAgentSpec") or
            std.mem.eql(u8, name, "InvalidRoute") or
            std.mem.eql(u8, name, "UnsupportedExecutionKind") or
            std.mem.eql(u8, name, "UnsupportedRouteRole");
    }

    fn isClaimReplayError(err: anyerror) bool {
        return std.mem.eql(u8, @errorName(err), "TicketClaimReplay");
    }

    fn isRecoveryRaceError(err: anyerror) bool {
        const name = @errorName(err);
        return std.mem.eql(u8, name, "RevisionConflict") or
            std.mem.eql(u8, name, "InvalidResume") or
            std.mem.eql(u8, name, "LeaseNotExpired") or
            std.mem.eql(u8, name, "DuplicateGroup") or
            std.mem.eql(u8, name, "TicketSessionTerminal");
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

fn boundedText(value: []const u8, max_len: usize) []const u8 {
    return value[0..@min(value.len, max_len)];
}

const TicketHarness = struct {
    store: tickets.TicketStore,
    capacity_snapshot: tools.AgentCapacitySnapshot = tools.AgentCapacitySnapshot.fromCounts(1, 0, 0),
    launch_count: usize = 0,
    resume_count: usize = 0,
    owns_all_sessions: bool = false,
    permanent_failure: bool = false,
    backpressure: bool = false,
};

fn ticketHarnessCapacity(ctx: ?*anyopaque) anyerror!tools.AgentCapacitySnapshot {
    const harness: *TicketHarness = @ptrCast(@alignCast(ctx.?));
    return harness.capacity_snapshot;
}

fn ticketHarnessOwnsSession(ctx: ?*anyopaque, session_id: []const u8) anyerror!bool {
    const harness: *TicketHarness = @ptrCast(@alignCast(ctx.?));
    _ = session_id;
    return harness.owns_all_sessions;
}

fn ticketHarnessResume(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: tools.ResumeTicketRequest,
) anyerror!tools.TicketLaunchReceipt {
    const harness: *TicketHarness = @ptrCast(@alignCast(ctx.?));
    harness.resume_count += 1;
    var resumed = try harness.store.resumeExpired(.{
        .ticket_id = request.ticket_id,
        .expected_revision = request.expected_revision,
        .worker_id = request.worker_id,
        .worker_generation = request.worker_generation,
        .lease_token = request.lease_token,
        .lease_expires_at_ms = request.lease_expires_at_ms,
        .session_id = request.session_id,
        .idempotency_key = request.idempotency_key,
        .resumed_at_ms = request.resumed_at_ms,
    });
    defer resumed.deinit(allocator);
    harness.owns_all_sessions = true;
    return .{
        .ticket_id = try allocator.dupe(u8, request.ticket_id),
        .group_id = try allocator.dupe(u8, "recovered-group"),
        .task_id = try allocator.dupe(u8, "recovered-task"),
        .session_id = try allocator.dupe(u8, request.session_id),
        .agent_id = try allocator.dupe(u8, resumed.agent_hint),
        .route_role = try allocator.dupe(u8, "implementation"),
        .capability_profile_id = try allocator.dupe(u8, "write"),
        .capability_hash = try allocator.dupe(u8, resumed.capability_hash),
        .model = try allocator.dupe(u8, "recovered-model"),
    };
}

fn ticketHarnessLaunch(
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    request: tools.TicketTaskRequest,
) anyerror!tools.TicketLaunchReceipt {
    const harness: *TicketHarness = @ptrCast(@alignCast(ctx.?));
    harness.launch_count += 1;
    if (harness.backpressure) return error.PoolFull;
    if (harness.permanent_failure) return error.UnknownAgentSpec;

    var claim = try harness.store.claim(.{
        .ticket_id = request.ticket_id,
        .expected_revision = request.expected_revision,
        .worker_id = request.worker_id,
        .worker_generation = request.worker_generation,
        .lease_token = request.lease_token,
        .lease_expires_at_ms = request.lease_expires_at_ms,
        .attempt = request.attempt,
        .session_id = "fake-session",
        .agent_hint = request.agent_hint,
        .capability_hash = "fake-capability",
        .idempotency_key = request.idempotency_key,
        .claimed_at_ms = request.lease_expires_at_ms - 1,
    });
    claim.deinit(allocator);

    return .{
        .ticket_id = try allocator.dupe(u8, request.ticket_id),
        .group_id = try allocator.dupe(u8, "fake-group"),
        .task_id = try allocator.dupe(u8, "fake-task"),
        .session_id = try allocator.dupe(u8, "fake-session"),
        .agent_id = try allocator.dupe(u8, request.agent_hint),
        .route_role = try allocator.dupe(u8, "implementation"),
        .capability_profile_id = try allocator.dupe(u8, "write"),
        .capability_hash = try allocator.dupe(u8, "fake-capability"),
        .model = try allocator.dupe(u8, "fake-model"),
    };
}

fn ticketHarnessAgentService(harness: *TicketHarness) tools.AgentService {
    return .{
        .context = harness,
        .launchFn = undefined,
        .launchTicketFn = ticketHarnessLaunch,
        .resumeTicketFn = ticketHarnessResume,
        .capacityFn = ticketHarnessCapacity,
        .ownsSessionFn = ticketHarnessOwnsSession,
        .statusFn = undefined,
        .waitFn = undefined,
        .listFn = undefined,
        .convergeFn = undefined,
        .reconcileFn = undefined,
    };
}

fn testConfig(allocator: std.mem.Allocator, workspace: []const u8) !types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "test-model"),
        .max_steps = 1,
        .workspace_root = try allocator.dupe(u8, workspace),
    };
}

fn createAssignedTicket(
    allocator: std.mem.Allocator,
    store: *const tickets.TicketStore,
    workspace: []const u8,
    title: []const u8,
    category: []const u8,
    created_at_ms: i64,
) ![]u8 {
    const create_key = try std.fmt.allocPrint(allocator, "scheduler-test-create:{s}:{d}", .{ title, created_at_ms });
    defer allocator.free(create_key);
    var created = try store.create(.{
        .title = title,
        .description = "scheduler ticket test",
        .category = category,
        .severity = "medium",
        .status = .unassigned,
        .workspace_root = workspace,
        .session_id = "source-session",
        .idempotency_key = create_key,
        .source = "test",
        .created_at_ms = created_at_ms,
    });
    defer created.deinit(allocator);

    const ticket_id = try allocator.dupe(u8, created.ticket_id);
    errdefer allocator.free(ticket_id);
    const assign_key = try std.fmt.allocPrint(allocator, "scheduler-test-assign:{s}", .{ticket_id});
    defer allocator.free(assign_key);
    var assigned = try store.transition(.{
        .ticket_id = ticket_id,
        .status = .assigned,
        .reason = "scheduler test admission",
        .idempotency_key = assign_key,
        .source = "test",
        .transitioned_at_ms = created_at_ms,
    });
    assigned.deinit(allocator);
    return ticket_id;
}

fn claimTicketForTest(
    allocator: std.mem.Allocator,
    store: *const tickets.TicketStore,
    ticket_id: []const u8,
    worker_id: []const u8,
    session_id: []const u8,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    attempt: u32,
    worker_generation: u64,
) !void {
    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    const claim_key = try std.fmt.allocPrint(allocator, "scheduler-test-claim:{s}:{d}", .{ ticket_id, attempt });
    defer allocator.free(claim_key);
    var claim = try store.claim(.{
        .ticket_id = ticket_id,
        .expected_revision = ticket.revision,
        .worker_id = worker_id,
        .worker_generation = worker_generation,
        .lease_token = lease_token,
        .lease_expires_at_ms = lease_expires_at_ms,
        .attempt = attempt,
        .session_id = session_id,
        .agent_hint = ticket.agent_hint,
        .capability_hash = "test-capability",
        .idempotency_key = claim_key,
        .claimed_at_ms = lease_expires_at_ms - 1,
    });
    claim.deinit(allocator);
}

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

test "scheduler dispatches oldest assigned ticket through the typed agent service" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "oldest", "architecture", 100);
    defer allocator.free(ticket_id);
    var harness = TicketHarness{
        .store = store,
        .capacity_snapshot = tools.AgentCapacitySnapshot.fromCounts(1, 0, 0),
    };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();

    var before = try store.readProjection();
    defer before.deinit();
    const queued_before = before.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.assigned, queued_before.status);
    try std.testing.expect(service.agent_service != null);
    try std.testing.expectEqual(@as(usize, 1), (try service.agent_service.?.capacity()).available);
    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), result.due_count);
    try std.testing.expectEqual(@as(usize, 1), result.ticket_due_count);
    try std.testing.expectEqual(@as(usize, 1), result.ticket_started_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_renewed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_blocked_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);
    try std.testing.expectEqual(@as(usize, 1), harness.launch_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(@as(usize, 3), projection.valid_events);
    try std.testing.expectEqual(tickets.TicketStatus.in_progress, ticket.status);
    try std.testing.expect(ticket.claim_complete);
    try std.testing.expectEqualStrings("fake-session", ticket.active_session_id);
    try std.testing.expectEqualStrings(service.owner_id, ticket.worker_id);
    try std.testing.expectEqual(service.worker_generation, ticket.worker_generation);
    try std.testing.expectEqual(@as(u32, 1), ticket.attempt);
    try std.testing.expectEqualStrings("planner", ticket.agent_hint);
    try std.testing.expectEqualStrings("fake-capability", ticket.capability_hash);
    try std.testing.expect(ticket.lease_expires_at_ms > 0);
}

test "scheduler leaves assigned tickets queued when supervisor capacity is full" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "queued", "bug", 100);
    defer allocator.free(ticket_id);
    var harness = TicketHarness{
        .store = store,
        .capacity_snapshot = tools.AgentCapacitySnapshot.fromCounts(1, 0, 1),
    };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), result.ticket_due_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_started_count);
    try std.testing.expectEqual(@as(usize, 0), harness.launch_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(@as(usize, 2), projection.valid_events);
    try std.testing.expectEqual(tickets.TicketStatus.assigned, ticket.status);
    try std.testing.expect(!ticket.claim_complete);
    try std.testing.expectEqual(@as(i64, 0), ticket.lease_expires_at_ms);
}

test "scheduler dispatches the oldest ticket first under partial capacity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const oldest_id = try createAssignedTicket(allocator, &store, workspace, "oldest", "docs", 100);
    defer allocator.free(oldest_id);
    const newest_id = try createAssignedTicket(allocator, &store, workspace, "newest", "docs", 200);
    defer allocator.free(newest_id);
    var harness = TicketHarness{
        .store = store,
        .capacity_snapshot = tools.AgentCapacitySnapshot.fromCounts(2, 0, 1),
    };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 2), result.ticket_due_count);
    try std.testing.expectEqual(@as(usize, 1), result.ticket_started_count);
    try std.testing.expectEqual(@as(usize, 1), harness.launch_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const oldest = projection.findConst(oldest_id) orelse return error.TestExpectedTicket;
    const newest = projection.findConst(newest_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.in_progress, oldest.status);
    try std.testing.expectEqual(tickets.TicketStatus.assigned, newest.status);
    try std.testing.expectEqual(@as(u32, 1), oldest.attempt);
    try std.testing.expectEqual(@as(u32, 0), newest.attempt);
    try std.testing.expect(std.mem.eql(u8, oldest.active_session_id, "fake-session"));
    try std.testing.expectEqual(@as(usize, 5), projection.valid_events);
}

test "scheduler durably blocks permanent ticket launch failures" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "bad route", "bug", 100);
    defer allocator.free(ticket_id);
    var harness = TicketHarness{
        .store = store,
        .capacity_snapshot = tools.AgentCapacitySnapshot.fromCounts(1, 0, 0),
        .permanent_failure = true,
    };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), result.ticket_due_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_started_count);
    try std.testing.expectEqual(@as(usize, 1), result.ticket_blocked_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);
    try std.testing.expectEqual(@as(usize, 1), harness.launch_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.blocked, ticket.status);
    try std.testing.expectEqual(@as(usize, 3), projection.valid_events);
    try std.testing.expect(!ticket.claim_complete);
}

test "scheduler preserves assignment across expected pool backpressure" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "retry later", "security", 100);
    defer allocator.free(ticket_id);
    var harness = TicketHarness{
        .store = store,
        .capacity_snapshot = tools.AgentCapacitySnapshot.fromCounts(1, 0, 0),
        .backpressure = true,
    };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), result.ticket_due_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_started_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_blocked_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);
    try std.testing.expectEqual(@as(usize, 1), harness.launch_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.assigned, ticket.status);
    try std.testing.expectEqual(@as(usize, 2), projection.valid_events);
}

test "scheduler does not heartbeat a claimed session absent from its supervisor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "heartbeat", "architecture", 100);
    defer allocator.free(ticket_id);
    var service = try Service.init(allocator, &config, .{ .context = null, .sendFn = provider.httpSend });
    defer service.deinit();
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, ticket_id, service.owner_id, "missing-child", "heartbeat-lease", now_ms + 1000, 1, service.worker_generation);

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), result.ticket_renewed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(@as(usize, 3), projection.valid_events);
    try std.testing.expectEqual(tickets.TicketStatus.in_progress, ticket.status);
    try std.testing.expect(ticket.claim_complete);
    try std.testing.expectEqual(@as(u64, 3), ticket.revision);
    try std.testing.expectEqualStrings("missing-child", ticket.active_session_id);
    try std.testing.expectEqualStrings(service.owner_id, ticket.worker_id);
    try std.testing.expectEqual(now_ms + 1000, ticket.lease_expires_at_ms);
}

test "scheduler heartbeats only the live session owned by its supervisor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "owned heartbeat", "architecture", 100);
    defer allocator.free(ticket_id);
    var harness = TicketHarness{ .store = store, .owns_all_sessions = true };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, ticket_id, service.owner_id, "owned-child", "owned-heartbeat-lease", now_ms + 1000, 1, service.worker_generation);

    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), result.ticket_renewed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(@as(u64, 4), ticket.revision);
    try std.testing.expect(ticket.lease_expires_at_ms > now_ms + 1000);
}

test "scheduler requeues expired claims once and preserves the last child session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "stale", "bug", 100);
    defer allocator.free(ticket_id);
    var service = try Service.init(allocator, &config, .{ .context = null, .sendFn = provider.httpSend });
    defer service.deinit();
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, ticket_id, "dead-worker", "stale-child", "stale-lease", now_ms - 1, 1, 1);

    const first = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), first.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), first.ticket_renewed_count);
    try std.testing.expectEqual(@as(usize, 0), first.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 0), first.ticket_failed_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.assigned, ticket.status);
    try std.testing.expectEqual(@as(usize, 4), projection.valid_events);
    try std.testing.expectEqualStrings("stale-child", ticket.last_session_id);
    try std.testing.expectEqual(@as(usize, 0), ticket.active_session_id.len);
    try std.testing.expect(!ticket.claim_complete);
    try std.testing.expectEqual(@as(i64, 0), ticket.lease_expires_at_ms);
    try std.testing.expectEqualStrings("stale_lease", ticket.failure_class);
    try std.testing.expectEqual(@as(u32, 1), ticket.attempt);

    const second = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), second.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 4), projection.valid_events);
}

test "scheduler resumes one expired nonterminal session under its generation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "resume", "feature", 100);
    defer allocator.free(ticket_id);
    var child = try sessions.initSessionWithOptions(allocator, workspace, "resume durable work", .{ .status = .running, .display_name = "ticket child" });
    defer child.deinit(allocator);
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, ticket_id, "dead-worker", child.id, "expired-lease", now_ms - 1, 4, 77);

    var harness = TicketHarness{ .store = store };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();
    const first = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), first.ticket_resumed_count);
    try std.testing.expectEqual(@as(usize, 0), first.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), first.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 1), harness.resume_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.in_progress, ticket.status);
    try std.testing.expectEqualStrings(child.id, ticket.active_session_id);
    try std.testing.expectEqual(@as(u32, 4), ticket.attempt);
    try std.testing.expectEqual(service.worker_generation, ticket.worker_generation);
    try std.testing.expectEqualStrings(service.owner_id, ticket.worker_id);
    try std.testing.expect(ticket.lease_expires_at_ms > now_ms);
    try std.testing.expectEqual(@as(usize, 4), projection.valid_events);

    const second = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), second.ticket_resumed_count);
    try std.testing.expectEqual(@as(usize, 1), harness.resume_count);
}

test "scheduler settles an expired terminal child before owner recovery" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const ticket_id = try createAssignedTicket(allocator, &store, workspace, "terminal first", "bug", 100);
    defer allocator.free(ticket_id);
    var child = try sessions.initSessionWithOptions(allocator, workspace, "done", .{ .display_name = "done child" });
    defer child.deinit(allocator);
    try sessions.setSessionStatus(allocator, workspace, &child, .completed);
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, ticket_id, "dead-worker", child.id, "expired-terminal-lease", now_ms - 1, 1, 9);

    var harness = TicketHarness{ .store = store };
    var service = try Service.initWithAgentService(allocator, &config, .{ .context = null, .sendFn = provider.httpSend }, ticketHarnessAgentService(&harness));
    defer service.deinit();
    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 1), result.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_resumed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), harness.resume_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.completed, ticket.status);
}

test "scheduler completes terminal child sessions and reconciles failed or cancelled work" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    var config = try testConfig(allocator, workspace);
    defer config.deinit(allocator);

    const store = tickets.TicketStore.init(allocator, workspace);
    const completed_ticket_id = try createAssignedTicket(allocator, &store, workspace, "complete", "docs", 100);
    defer allocator.free(completed_ticket_id);
    const failed_ticket_id = try createAssignedTicket(allocator, &store, workspace, "failed task", "bug", 200);
    defer allocator.free(failed_ticket_id);
    const cancelled_ticket_id = try createAssignedTicket(allocator, &store, workspace, "cancelled", "task", 300);
    defer allocator.free(cancelled_ticket_id);

    var completed_session = try sessions.initSessionWithOptions(allocator, workspace, "complete", .{ .display_name = "completed child" });
    defer completed_session.deinit(allocator);
    try sessions.writeOutput(allocator, workspace, completed_session.id, "done-data");
    try sessions.setSessionStatus(allocator, workspace, &completed_session, .completed);
    const now_ms = std.time.milliTimestamp();
    try claimTicketForTest(allocator, &store, completed_ticket_id, "worker-complete", completed_session.id, "complete-lease", now_ms + 30_000, 1, 1);

    var failed_session = try sessions.initSessionWithOptions(allocator, workspace, "failed task", .{ .display_name = "failed child" });
    defer failed_session.deinit(allocator);
    try sessions.setSessionStatus(allocator, workspace, &failed_session, .running);
    const failed_run_seq = try sessions.appendEventWithSeq(allocator, workspace, failed_session.id, .{
        .event_type = "session_started",
        .message = "failed run",
        .timestamp_ms = now_ms,
    });
    var failed_terminal = try sessions.commitTurnTerminal(
        allocator,
        workspace,
        &failed_session,
        failed_run_seq,
        .{
            .outcome = .failed,
            .detail = "provider failed",
            .failure_class = "provider_transport",
            .failure_phase = "provider",
        },
        now_ms + 1,
    );
    defer failed_terminal.deinit(allocator);
    try claimTicketForTest(allocator, &store, failed_ticket_id, "worker-failed", failed_session.id, "failed-lease", now_ms + 30_000, 1, 1);

    var cancelled_session = try sessions.initSessionWithOptions(allocator, workspace, "cancelled", .{ .display_name = "cancelled child" });
    defer cancelled_session.deinit(allocator);
    try sessions.setSessionStatus(allocator, workspace, &cancelled_session, .cancelled);
    try claimTicketForTest(allocator, &store, cancelled_ticket_id, "worker-cancelled", cancelled_session.id, "cancelled-lease", now_ms + 30_000, 1, 1);

    var service = try Service.init(allocator, &config, .{ .context = null, .sendFn = provider.httpSend });
    defer service.deinit();
    const result = try service.tick();
    try std.testing.expectEqual(@as(usize, 3), result.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_requeued_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_renewed_count);
    try std.testing.expectEqual(@as(usize, 0), result.ticket_failed_count);

    var projection = try store.readProjection();
    defer projection.deinit();
    const completed_ticket = projection.findConst(completed_ticket_id) orelse return error.TestExpectedTicket;
    const failed_ticket = projection.findConst(failed_ticket_id) orelse return error.TestExpectedTicket;
    const cancelled_ticket = projection.findConst(cancelled_ticket_id) orelse return error.TestExpectedTicket;
    try std.testing.expectEqual(tickets.TicketStatus.completed, completed_ticket.status);
    try std.testing.expectEqualStrings(completed_session.id, completed_ticket.active_session_id);
    try std.testing.expect(std.mem.indexOf(u8, completed_ticket.terminal_receipt, "output_bytes=9") != null);
    try std.testing.expectEqual(tickets.TicketStatus.completed, failed_ticket.status);
    try std.testing.expect(std.mem.indexOf(u8, failed_ticket.terminal_receipt, "status=failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_ticket.terminal_receipt, "failure=provider failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_ticket.terminal_receipt, "failure_id=failure-") != null);
    try std.testing.expect(std.mem.startsWith(u8, failed_ticket.failure_id, "failure-"));
    try std.testing.expectEqual(tickets.TicketStatus.completed, cancelled_ticket.status);
    try std.testing.expect(std.mem.indexOf(u8, cancelled_ticket.terminal_receipt, "status=cancelled") != null);
    try std.testing.expectEqual(@as(usize, 12), projection.valid_events);

    const completion_key = try std.fmt.allocPrint(allocator, "ticket-complete:{s}:3:1:{s}", .{ completed_ticket_id, completed_session.id });
    defer allocator.free(completion_key);
    var replay = try store.complete(.{
        .ticket_id = completed_ticket_id,
        .expected_revision = 3,
        .session_id = completed_session.id,
        .lease_token = "complete-lease",
        .terminal_receipt = "replay",
        .idempotency_key = completion_key,
        .completed_at_ms = now_ms,
    });
    defer replay.deinit(allocator);
    try std.testing.expect(!replay.appended);
    try std.testing.expectEqual(@as(u64, 4), replay.revision);

    const second = try service.tick();
    try std.testing.expectEqual(@as(usize, 0), second.ticket_completed_count);
    try std.testing.expectEqual(@as(usize, 12), projection.valid_events);
}
