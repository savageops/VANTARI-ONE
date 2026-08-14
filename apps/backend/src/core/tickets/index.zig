const std = @import("std");

const fsutil = @import("../../shared/fsutil.zig");
const process_lock = @import("../../shared/process_lock.zig");
const protocol_events = @import("../../shared/protocol/events.zig");

/// Keep thread and process serialization at the ledger owner. One claim event
/// commits worker generation, lease, and child-session identity together.
var ledger_mutex: std.Thread.Mutex = .{};
const ledger_lock_timeout_ms: usize = if (@import("builtin").is_test) 50 else 2000;

const LedgerGuard = struct {
    lock: process_lock.FileLock,

    fn deinit(self: *LedgerGuard) void {
        self.lock.deinit();
        ledger_mutex.unlock();
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidArguments,
    InvalidInitialStatus,
    InvalidTransition,
    InvalidClaim,
    InvalidResume,
    InvalidRenewal,
    InvalidTerminalEvidence,
    TicketNotFound,
    RevisionConflict,
    IdempotencyConflict,
    NoopTransition,
    PoisonedSuffix,
    LeaseNotExpired,
    LeaseExpired,
};

pub const TicketStatus = enum {
    unassigned,
    assigned,
    in_progress,
    blocked,
    completed,
    closed,

    pub fn parse(value: []const u8) Error!TicketStatus {
        inline for (@typeInfo(TicketStatus).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return Error.InvalidArguments;
    }
};

const RawEvent = struct {
    schema: []const u8 = "",
    seq: u64 = 0,
    event_type: []const u8 = "",
    id: []const u8 = "",
    ticket_id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    category: []const u8 = "",
    severity: []const u8 = "",
    status: []const u8 = "",
    evidence: []const []const u8 = &.{},
    proposed_owner: []const u8 = "",
    workspace_root: []const u8 = "",
    source_session_id: []const u8 = "",
    session_id: []const u8 = "",
    previous_session_id: []const u8 = "",
    created_at_ms: i64 = 0,
    transitioned_at_ms: i64 = 0,
    reason: []const u8 = "",
    source: []const u8 = "",
    idempotency_key: []const u8 = "",
    revision: u64 = 0,
    worker_id: []const u8 = "",
    worker_generation: u64 = 0,
    lease_token: []const u8 = "",
    lease_expires_at_ms: i64 = 0,
    attempt: u32 = 0,
    agent_hint: []const u8 = "",
    capability_hash: []const u8 = "",
    failure_class: []const u8 = "",
    failure_id: []const u8 = "",
    terminal_receipt: []const u8 = "",
};

pub const CreateInput = struct {
    title: []const u8,
    description: []const u8,
    category: []const u8,
    severity: []const u8,
    status: TicketStatus = .unassigned,
    evidence: []const []const u8 = &.{},
    proposed_owner: []const u8 = "",
    workspace_root: []const u8 = "",
    session_id: []const u8 = "",
    idempotency_key: []const u8 = "",
    source: []const u8 = "agent",
    created_at_ms: i64,
};

pub const TransitionInput = struct {
    ticket_id: []const u8,
    status: TicketStatus,
    reason: []const u8,
    idempotency_key: []const u8 = "",
    source: []const u8 = "agent",
    transitioned_at_ms: i64,
};

pub const ClaimInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    worker_id: []const u8,
    worker_generation: u64,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    attempt: u32,
    session_id: []const u8,
    agent_hint: []const u8,
    capability_hash: []const u8,
    idempotency_key: []const u8,
    claimed_at_ms: i64,
};

pub const RenewInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    worker_id: []const u8,
    worker_generation: u64,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    session_id: []const u8,
    idempotency_key: []const u8,
    renewed_at_ms: i64,
};

/// Replace an expired claim owner without changing the durable work identity.
/// The ticket, attempt, session, agent, and capability remain fixed; only the
/// worker generation and its new lease move.
pub const ResumeInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    worker_id: []const u8,
    worker_generation: u64,
    lease_token: []const u8,
    lease_expires_at_ms: i64,
    session_id: []const u8,
    idempotency_key: []const u8,
    resumed_at_ms: i64,
};

pub const RequeueInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    reason: []const u8,
    failure_class: []const u8,
    failure_phase: []const u8 = "scheduler",
    idempotency_key: []const u8,
    requeued_at_ms: i64,
};

pub const CompleteInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    session_id: []const u8,
    lease_token: []const u8,
    terminal_receipt: []const u8,
    failure_id: []const u8 = "",
    idempotency_key: []const u8,
    completed_at_ms: i64,
};

pub const CloseInput = struct {
    ticket_id: []const u8,
    expected_revision: u64,
    idempotency_key: []const u8,
    closed_at_ms: i64,
};

pub const Ticket = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    category: []const u8,
    severity: []const u8,
    status: TicketStatus,
    proposed_owner: []const u8,
    agent_hint: []const u8,
    workspace_root: []const u8,
    source_session_id: []const u8,
    active_session_id: []const u8,
    last_session_id: []const u8,
    worker_id: []const u8,
    lease_token: []const u8,
    capability_hash: []const u8,
    failure_class: []const u8,
    failure_id: []const u8,
    terminal_receipt: []const u8,
    revision: u64,
    worker_generation: u64,
    lease_expires_at_ms: i64,
    attempt: u32,
    created_at_ms: i64,
    updated_at_ms: i64,
    claim_complete: bool,
};

pub const TicketProjection = struct {
    arena: *std.heap.ArenaAllocator,
    tickets: std.array_list.Managed(Ticket),
    valid_events: usize = 0,
    last_seq: u64 = 0,
    poisoned_suffix: bool = false,

    fn init(parent_allocator: std.mem.Allocator) !TicketProjection {
        const arena = try parent_allocator.create(std.heap.ArenaAllocator);
        errdefer parent_allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(parent_allocator);
        return .{
            .arena = arena,
            .tickets = std.array_list.Managed(Ticket).init(arena.allocator()),
        };
    }

    pub fn deinit(self: *TicketProjection) void {
        self.tickets.deinit();
        const parent_allocator = self.arena.child_allocator;
        self.arena.deinit();
        parent_allocator.destroy(self.arena);
    }

    pub fn find(self: *TicketProjection, ticket_id: []const u8) ?*Ticket {
        for (self.tickets.items) |*ticket| {
            if (std.mem.eql(u8, ticket.id, ticket_id)) return ticket;
        }
        return null;
    }

    pub fn findConst(self: *const TicketProjection, ticket_id: []const u8) ?*const Ticket {
        for (self.tickets.items) |*ticket| {
            if (std.mem.eql(u8, ticket.id, ticket_id)) return ticket;
        }
        return null;
    }
};

/// Read-only queue pressure derived from the valid ticket-event prefix. This
/// is an operator projection, not a second lifecycle registry.
pub const TicketSnapshot = struct {
    unassigned: usize = 0,
    assigned: usize = 0,
    in_progress: usize = 0,
    blocked: usize = 0,
    completed: usize = 0,
    closed: usize = 0,
    valid_events: usize = 0,
    healthy: bool = true,
};

pub const MutationReceipt = struct {
    ticket_id: []u8,
    status: TicketStatus,
    revision: u64,
    appended: bool,

    pub fn deinit(self: *MutationReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.ticket_id);
    }
};

pub const ClaimReceipt = struct {
    ticket_id: []u8,
    worker_id: []u8,
    worker_generation: u64,
    lease_token: []u8,
    lease_expires_at_ms: i64,
    attempt: u32,
    session_id: []u8,
    agent_hint: []u8,
    capability_hash: []u8,
    revision: u64,
    appended: bool,

    pub fn deinit(self: *ClaimReceipt, allocator: std.mem.Allocator) void {
        allocator.free(self.ticket_id);
        allocator.free(self.worker_id);
        allocator.free(self.lease_token);
        allocator.free(self.session_id);
        allocator.free(self.agent_hint);
        allocator.free(self.capability_hash);
    }
};

pub const TicketStore = struct {
    allocator: std.mem.Allocator,
    workspace_root: []const u8,

    pub fn init(allocator: std.mem.Allocator, workspace_root: []const u8) TicketStore {
        return .{ .allocator = allocator, .workspace_root = workspace_root };
    }

    pub fn ledgerPath(self: *const TicketStore) ![]u8 {
        return fsutil.join(self.allocator, &.{ self.workspace_root, ".var", "tickets", "tickets.jsonl" });
    }

    pub fn ledgerLockPath(self: *const TicketStore) ![]u8 {
        return fsutil.join(self.allocator, &.{ self.workspace_root, ".var", "tickets", "ledger.lock" });
    }

    fn acquireLedgerGuard(self: *const TicketStore) !LedgerGuard {
        ledger_mutex.lock();
        errdefer ledger_mutex.unlock();
        const path = try self.ledgerLockPath();
        defer self.allocator.free(path);
        return .{ .lock = try process_lock.acquire(path, ledger_lock_timeout_ms) };
    }

    pub fn readProjection(self: *const TicketStore) !TicketProjection {
        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();
        return self.readProjectionLocked();
    }

    pub fn snapshot(self: *const TicketStore) !TicketSnapshot {
        var projection = try self.readProjection();
        defer projection.deinit();

        var result = TicketSnapshot{
            .valid_events = projection.valid_events,
            .healthy = !projection.poisoned_suffix,
        };
        for (projection.tickets.items) |ticket| {
            switch (ticket.status) {
                .unassigned => result.unassigned += 1,
                .assigned => result.assigned += 1,
                .in_progress => result.in_progress += 1,
                .blocked => result.blocked += 1,
                .completed => result.completed += 1,
                .closed => result.closed += 1,
            }
        }
        return result;
    }

    pub fn create(self: *const TicketStore, input: CreateInput) !MutationReceipt {
        if (input.title.len == 0 or input.description.len == 0 or input.category.len == 0 or input.severity.len == 0) return Error.InvalidArguments;
        if (input.status != .unassigned and input.status != .assigned) return Error.InvalidInitialStatus;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (input.idempotency_key.len > 0) {
            if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
                defer self.allocator.free(existing);
                var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                if (!std.mem.eql(u8, eventType(parsed.value), "create")) return Error.IdempotencyConflict;
                return self.mutationFromRaw(parsed.value, false);
            }
        }

        const ticket_id = try std.fmt.allocPrint(self.allocator, "ticket-{d}-{x}", .{ input.created_at_ms, std.crypto.random.int(u64) });
        errdefer self.allocator.free(ticket_id);

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "create",
            .id = ticket_id,
            .ticket_id = ticket_id,
            .title = input.title,
            .description = input.description,
            .category = input.category,
            .severity = input.severity,
            .status = @tagName(input.status),
            .evidence = input.evidence,
            .proposed_owner = input.proposed_owner,
            .workspace_root = input.workspace_root,
            .source_session_id = input.session_id,
            .created_at_ms = input.created_at_ms,
            .transitioned_at_ms = input.created_at_ms,
            .source = input.source,
            .idempotency_key = input.idempotency_key,
            .revision = 1,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = ticket_id, .status = input.status, .revision = 1, .appended = appended };
    }

    pub fn transition(self: *const TicketStore, input: TransitionInput) !MutationReceipt {
        if (input.ticket_id.len == 0 or input.reason.len == 0) return Error.InvalidArguments;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (input.idempotency_key.len > 0) {
            if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
                defer self.allocator.free(existing);
                var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                if (!std.mem.eql(u8, eventType(parsed.value), "transition")) return Error.IdempotencyConflict;
                return self.mutationFromRaw(parsed.value, false);
            }
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status == input.status) return Error.NoopTransition;
        if (!manualTransitionAllowed(ticket.status, input.status)) return Error.InvalidTransition;

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "transition",
            .ticket_id = input.ticket_id,
            .status = @tagName(input.status),
            .reason = input.reason,
            .source = input.source,
            .idempotency_key = input.idempotency_key,
            .transitioned_at_ms = input.transitioned_at_ms,
            .revision = ticket.revision + 1,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = try self.allocator.dupe(u8, input.ticket_id), .status = input.status, .revision = event.revision, .appended = appended };
    }

    pub fn claim(self: *const TicketStore, input: ClaimInput) !ClaimReceipt {
        if (input.ticket_id.len == 0 or input.worker_id.len == 0 or input.lease_token.len == 0 or input.session_id.len == 0 or input.agent_hint.len == 0 or input.capability_hash.len == 0 or input.idempotency_key.len == 0 or input.lease_expires_at_ms <= input.claimed_at_ms) return Error.InvalidClaim;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "claim")) return Error.IdempotencyConflict;
            return self.claimFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .assigned) return Error.InvalidClaim;
        if (ticket.revision != input.expected_revision) return Error.RevisionConflict;

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "claim",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.in_progress),
            .source = "scheduler",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .worker_id = input.worker_id,
            .worker_generation = input.worker_generation,
            .lease_token = input.lease_token,
            .lease_expires_at_ms = input.lease_expires_at_ms,
            .attempt = input.attempt,
            .session_id = input.session_id,
            .agent_hint = input.agent_hint,
            .capability_hash = input.capability_hash,
            .transitioned_at_ms = input.claimed_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return self.claimFromRawWithAllocator(event, appended);
    }

    /// Fence one expired owner onto the existing ticket session. This is the
    /// only crash-recovery mutation that preserves an active attempt.
    pub fn resumeExpired(self: *const TicketStore, input: ResumeInput) !ClaimReceipt {
        if (input.ticket_id.len == 0 or input.worker_id.len == 0 or input.worker_generation == 0 or input.lease_token.len == 0 or input.session_id.len == 0 or input.idempotency_key.len == 0 or input.lease_expires_at_ms <= input.resumed_at_ms) return Error.InvalidResume;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "resume")) return Error.IdempotencyConflict;
            return self.claimFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .in_progress or !ticket.claim_complete) return Error.InvalidResume;
        if (ticket.revision != input.expected_revision) return Error.RevisionConflict;
        if (!std.mem.eql(u8, ticket.active_session_id, input.session_id)) return Error.InvalidResume;
        if (ticket.lease_expires_at_ms <= 0 or ticket.lease_expires_at_ms > input.resumed_at_ms) return Error.LeaseNotExpired;

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "resume",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.in_progress),
            .source = "scheduler",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .worker_id = input.worker_id,
            .worker_generation = input.worker_generation,
            .lease_token = input.lease_token,
            .lease_expires_at_ms = input.lease_expires_at_ms,
            .attempt = ticket.attempt,
            .session_id = ticket.active_session_id,
            .agent_hint = ticket.agent_hint,
            .capability_hash = ticket.capability_hash,
            .transitioned_at_ms = input.resumed_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return self.claimFromRawWithAllocator(event, appended);
    }

    pub fn renewClaim(self: *const TicketStore, input: RenewInput) !MutationReceipt {
        if (input.ticket_id.len == 0 or input.worker_id.len == 0 or input.lease_token.len == 0 or input.session_id.len == 0 or input.idempotency_key.len == 0 or input.lease_expires_at_ms <= input.renewed_at_ms) return Error.InvalidRenewal;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "heartbeat")) return Error.IdempotencyConflict;
            return self.mutationFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .in_progress or !ticket.claim_complete) return Error.InvalidRenewal;
        if (ticket.revision != input.expected_revision or
            !std.mem.eql(u8, ticket.worker_id, input.worker_id) or
            ticket.worker_generation != input.worker_generation or
            !std.mem.eql(u8, ticket.lease_token, input.lease_token) or
            !std.mem.eql(u8, ticket.active_session_id, input.session_id)) return Error.InvalidRenewal;
        if (ticket.lease_expires_at_ms <= input.renewed_at_ms) return Error.LeaseExpired;
        if (input.lease_expires_at_ms <= ticket.lease_expires_at_ms) return Error.InvalidRenewal;

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "heartbeat",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.in_progress),
            .source = "scheduler",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .worker_id = input.worker_id,
            .worker_generation = input.worker_generation,
            .lease_token = input.lease_token,
            .lease_expires_at_ms = input.lease_expires_at_ms,
            .session_id = input.session_id,
            .transitioned_at_ms = input.renewed_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = try self.allocator.dupe(u8, input.ticket_id), .status = .in_progress, .revision = event.revision, .appended = appended };
    }

    pub fn requeueExpired(self: *const TicketStore, input: RequeueInput) !MutationReceipt {
        if (input.ticket_id.len == 0 or input.reason.len == 0 or input.failure_class.len == 0 or input.idempotency_key.len == 0) return Error.InvalidArguments;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "requeue")) return Error.IdempotencyConflict;
            return self.mutationFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .in_progress or !ticket.claim_complete) return Error.InvalidTransition;
        if (ticket.revision != input.expected_revision) return Error.RevisionConflict;
        if (ticket.lease_expires_at_ms <= 0 or ticket.lease_expires_at_ms > input.requeued_at_ms) return Error.LeaseNotExpired;

        const failure_class = protocol_events.normalizeFailureClass(.failed, input.failure_class, input.reason);
        const failure_phase = protocol_events.normalizeFailurePhase(input.failure_phase, input.reason);
        const failure_id = try protocol_events.failureReceiptId(
            self.allocator,
            input.ticket_id,
            ticket.revision + 1,
            failure_class,
            failure_phase,
            input.reason,
        );
        defer self.allocator.free(failure_id);

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "requeue",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.assigned),
            .source = "scheduler",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .session_id = ticket.active_session_id,
            .failure_class = failure_class,
            .failure_id = failure_id,
            .reason = input.reason,
            .transitioned_at_ms = input.requeued_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = try self.allocator.dupe(u8, input.ticket_id), .status = .assigned, .revision = event.revision, .appended = appended };
    }

    pub fn complete(self: *const TicketStore, input: CompleteInput) !MutationReceipt {
        if (input.ticket_id.len == 0 or input.session_id.len == 0 or input.lease_token.len == 0 or input.terminal_receipt.len == 0 or input.idempotency_key.len == 0) return Error.InvalidTerminalEvidence;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "complete")) return Error.IdempotencyConflict;
            return self.mutationFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .in_progress or !ticket.claim_complete) return Error.InvalidTerminalEvidence;
        if (ticket.revision != input.expected_revision or !std.mem.eql(u8, ticket.active_session_id, input.session_id) or !std.mem.eql(u8, ticket.lease_token, input.lease_token)) return Error.InvalidTerminalEvidence;

        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "complete",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.completed),
            .source = "agent",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .session_id = input.session_id,
            .failure_id = input.failure_id,
            .terminal_receipt = input.terminal_receipt,
            .transitioned_at_ms = input.completed_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = try self.allocator.dupe(u8, input.ticket_id), .status = .completed, .revision = event.revision, .appended = appended };
    }

    pub fn close(self: *const TicketStore, input: CloseInput) !MutationReceipt {
        if (input.ticket_id.len == 0 or input.idempotency_key.len == 0) return Error.InvalidTerminalEvidence;

        var guard = try self.acquireLedgerGuard();
        defer guard.deinit();

        if (try self.idempotencyExistsLocked(input.idempotency_key)) |existing| {
            defer self.allocator.free(existing);
            var parsed = try std.json.parseFromSlice(RawEvent, self.allocator, existing, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!std.mem.eql(u8, eventType(parsed.value), "close")) return Error.IdempotencyConflict;
            return self.mutationFromRaw(parsed.value, false);
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        const ticket = projection.find(input.ticket_id) orelse return Error.TicketNotFound;
        if (ticket.status != .completed or ticket.revision != input.expected_revision) return Error.InvalidTerminalEvidence;
        var event = RawEvent{
            .schema = "var1.ticket_event.v2",
            .event_type = "close",
            .ticket_id = input.ticket_id,
            .status = @tagName(TicketStatus.closed),
            .source = "review",
            .idempotency_key = input.idempotency_key,
            .revision = ticket.revision + 1,
            .transitioned_at_ms = input.closed_at_ms,
        };
        const appended = try self.appendEventLocked(&event);
        return .{ .ticket_id = try self.allocator.dupe(u8, input.ticket_id), .status = .closed, .revision = event.revision, .appended = appended };
    }

    fn readProjectionLocked(self: *const TicketStore) !TicketProjection {
        var projection = try TicketProjection.init(self.allocator);
        errdefer projection.deinit();

        const ledger_path = try self.ledgerPath();
        defer self.allocator.free(ledger_path);
        const content = fsutil.readTextAlloc(self.allocator, ledger_path) catch |err| switch (err) {
            error.FileNotFound => return projection,
            else => return err,
        };
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            var parsed = std.json.parseFromSlice(RawEvent, self.allocator, trimmed, .{ .ignore_unknown_fields = true }) catch {
                projection.poisoned_suffix = true;
                break;
            };
            defer parsed.deinit();

            const kind = eventType(parsed.value);
            if (kind.len == 0) {
                projection.poisoned_suffix = true;
                break;
            }

            projection.valid_events += 1;
            const sequence = if (parsed.value.seq > 0) parsed.value.seq else @as(u64, @intCast(projection.valid_events));
            projection.last_seq = @max(projection.last_seq, sequence);
            self.applyEvent(&projection, parsed.value, kind) catch {
                projection.poisoned_suffix = true;
                break;
            };
        }

        return projection;
    }

    fn applyEvent(self: *const TicketStore, projection: *TicketProjection, event: RawEvent, kind: []const u8) !void {
        const arena = projection.arena.allocator();
        if (std.mem.eql(u8, kind, "create")) {
            if (event.id.len == 0 or event.title.len == 0 or event.description.len == 0) return Error.InvalidArguments;
            if (projection.find(event.id) != null) return;
            const status = if (event.status.len == 0) TicketStatus.unassigned else try TicketStatus.parse(event.status);
            try projection.tickets.append(.{
                .id = try arena.dupe(u8, event.id),
                .title = try arena.dupe(u8, event.title),
                .description = try arena.dupe(u8, event.description),
                .category = try arena.dupe(u8, event.category),
                .severity = try arena.dupe(u8, event.severity),
                .status = status,
                .proposed_owner = try arena.dupe(u8, event.proposed_owner),
                .agent_hint = try arena.dupe(u8, if (event.proposed_owner.len > 0) event.proposed_owner else agentHintForCategory(event.category)),
                .workspace_root = try arena.dupe(u8, event.workspace_root),
                .source_session_id = try arena.dupe(u8, if (event.source_session_id.len > 0) event.source_session_id else event.session_id),
                .active_session_id = "",
                .last_session_id = "",
                .worker_id = "",
                .lease_token = "",
                .capability_hash = "",
                .failure_class = "",
                .failure_id = "",
                .terminal_receipt = "",
                .revision = if (event.revision > 0) event.revision else 1,
                .worker_generation = 0,
                .lease_expires_at_ms = 0,
                .attempt = 0,
                .created_at_ms = event.created_at_ms,
                .updated_at_ms = if (event.transitioned_at_ms > 0) event.transitioned_at_ms else event.created_at_ms,
                .claim_complete = false,
            });
            return;
        }

        const ticket = projection.find(event.ticket_id) orelse return Error.TicketNotFound;
        const status = if (event.status.len == 0) ticket.status else try TicketStatus.parse(event.status);
        ticket.status = status;
        ticket.revision = if (event.revision > 0) event.revision else ticket.revision + 1;
        ticket.updated_at_ms = if (event.transitioned_at_ms > 0) event.transitioned_at_ms else ticket.updated_at_ms;
        if (event.proposed_owner.len > 0) ticket.proposed_owner = try arena.dupe(u8, event.proposed_owner);
        if (event.agent_hint.len > 0) ticket.agent_hint = try arena.dupe(u8, event.agent_hint);
        if (event.worker_id.len > 0) ticket.worker_id = try arena.dupe(u8, event.worker_id);
        if (event.worker_generation > 0) ticket.worker_generation = event.worker_generation;
        if (event.lease_token.len > 0) ticket.lease_token = try arena.dupe(u8, event.lease_token);
        if (event.lease_expires_at_ms > 0) ticket.lease_expires_at_ms = event.lease_expires_at_ms;
        if (event.attempt > 0) ticket.attempt = event.attempt;
        if (event.capability_hash.len > 0) ticket.capability_hash = try arena.dupe(u8, event.capability_hash);
        if (event.failure_class.len > 0) ticket.failure_class = try arena.dupe(u8, event.failure_class);
        if (event.failure_id.len > 0) ticket.failure_id = try arena.dupe(u8, event.failure_id);
        if (event.terminal_receipt.len > 0) ticket.terminal_receipt = try arena.dupe(u8, event.terminal_receipt);

        if (std.mem.eql(u8, kind, "claim") or std.mem.eql(u8, kind, "resume")) {
            ticket.active_session_id = try arena.dupe(u8, event.session_id);
            ticket.claim_complete = event.worker_id.len > 0 and event.lease_token.len > 0 and event.session_id.len > 0 and event.capability_hash.len > 0 and event.lease_expires_at_ms > 0;
        } else if (std.mem.eql(u8, kind, "requeue")) {
            if (event.session_id.len > 0) ticket.last_session_id = try arena.dupe(u8, event.session_id);
            ticket.active_session_id = "";
            ticket.worker_id = "";
            ticket.worker_generation = 0;
            ticket.lease_token = "";
            ticket.lease_expires_at_ms = 0;
            ticket.capability_hash = "";
            ticket.claim_complete = false;
        } else if (std.mem.eql(u8, kind, "complete")) {
            ticket.active_session_id = try arena.dupe(u8, event.session_id);
            ticket.claim_complete = false;
        } else if (std.mem.eql(u8, kind, "close")) {
            ticket.claim_complete = false;
        } else if (std.mem.eql(u8, kind, "transition") and status == .in_progress) {
            ticket.claim_complete = false;
        }

        _ = self;
    }

    fn appendEventLocked(self: *const TicketStore, event: *RawEvent) !bool {
        if (event.idempotency_key.len > 0) {
            if (try self.idempotencyExistsLocked(event.idempotency_key)) |_| return false;
        }

        var projection = try self.readProjectionLocked();
        defer projection.deinit();
        if (projection.poisoned_suffix) return Error.PoisonedSuffix;
        event.seq = projection.last_seq + 1;

        const ledger_path = try self.ledgerPath();
        defer self.allocator.free(ledger_path);
        var line = std.array_list.Managed(u8).init(self.allocator);
        defer line.deinit();
        try line.writer().print("{f}\n", .{std.json.fmt(event.*, .{})});
        try fsutil.appendText(ledger_path, line.items);
        return true;
    }

    fn idempotencyExistsLocked(self: *const TicketStore, key: []const u8) !?[]u8 {
        if (key.len == 0) return null;
        const ledger_path = try self.ledgerPath();
        defer self.allocator.free(ledger_path);
        const content = fsutil.readTextAlloc(self.allocator, ledger_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(content);

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var parsed = std.json.parseFromSlice(RawEvent, self.allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return Error.PoisonedSuffix;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.idempotency_key, key)) return try self.allocator.dupe(u8, trimmed);
        }
        return null;
    }

    fn mutationFromRaw(self: *const TicketStore, event: RawEvent, appended: bool) !MutationReceipt {
        const status = if (event.status.len == 0) TicketStatus.unassigned else try TicketStatus.parse(event.status);
        return .{ .ticket_id = try self.allocator.dupe(u8, if (event.ticket_id.len > 0) event.ticket_id else event.id), .status = status, .revision = event.revision, .appended = appended };
    }

    fn claimFromRaw(self: *const TicketStore, event: RawEvent, appended: bool) !ClaimReceipt {
        return self.claimFromRawWithAllocator(event, appended);
    }

    fn claimFromRawWithAllocator(self: *const TicketStore, event: RawEvent, appended: bool) !ClaimReceipt {
        return .{
            .ticket_id = try self.allocator.dupe(u8, event.ticket_id),
            .worker_id = try self.allocator.dupe(u8, event.worker_id),
            .worker_generation = event.worker_generation,
            .lease_token = try self.allocator.dupe(u8, event.lease_token),
            .lease_expires_at_ms = event.lease_expires_at_ms,
            .attempt = event.attempt,
            .session_id = try self.allocator.dupe(u8, event.session_id),
            .agent_hint = try self.allocator.dupe(u8, event.agent_hint),
            .capability_hash = try self.allocator.dupe(u8, event.capability_hash),
            .revision = event.revision,
            .appended = appended,
        };
    }
};

fn eventType(event: RawEvent) []const u8 {
    if (std.mem.eql(u8, event.schema, "var1.ticket.v1")) return "create";
    if (std.mem.eql(u8, event.schema, "var1.ticket_transition.v1")) return "transition";
    if (std.mem.eql(u8, event.schema, "var1.ticket_event.v2")) return event.event_type;
    return "";
}

fn manualTransitionAllowed(from: TicketStatus, to: TicketStatus) bool {
    return (from == .unassigned and to == .assigned) or
        (from == .assigned and to == .unassigned) or
        (from == .assigned and to == .blocked) or
        (from == .blocked and to == .assigned);
}

pub fn agentHintForCategory(category: []const u8) []const u8 {
    if (std.mem.eql(u8, category, "architecture")) return "planner";
    if (std.mem.eql(u8, category, "bug") or std.mem.eql(u8, category, "security")) return "recon";
    if (std.mem.eql(u8, category, "docs")) return "general";
    return "implementer";
}

test "ticket store creates a queue-only ticket and projects current truth" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);

    var receipt = try store.create(.{ .title = "queue me", .description = "wait for a worker", .category = "feature", .severity = "medium", .workspace_root = workspace, .created_at_ms = 100 });
    defer receipt.deinit(allocator);
    try std.testing.expect(receipt.appended);
    try std.testing.expectEqual(TicketStatus.unassigned, receipt.status);
    try std.testing.expectEqual(@as(u64, 1), receipt.revision);
    try std.testing.expect(std.mem.startsWith(u8, receipt.ticket_id, "ticket-100-"));

    var projection = try store.readProjection();
    defer projection.deinit();
    try std.testing.expectEqual(@as(usize, 1), projection.tickets.items.len);
    try std.testing.expectEqual(@as(usize, 1), projection.valid_events);
    try std.testing.expect(!projection.poisoned_suffix);
    const ticket = projection.findConst(receipt.ticket_id).?;
    try std.testing.expectEqualStrings("queue me", ticket.title);
    try std.testing.expectEqualStrings("feature", ticket.category);
    try std.testing.expectEqualStrings("implementer", ticket.agent_hint);
    try std.testing.expectEqual(TicketStatus.unassigned, ticket.status);
    try std.testing.expectEqual(@as(u64, 1), ticket.revision);
    try std.testing.expect(!ticket.claim_complete);
}

test "ticket store supports queue admission without execution and rejects direct execution status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "admit", .description = "not yet running", .category = "bug", .severity = "high", .created_at_ms = 200 });
    defer created.deinit(allocator);

    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "operator admitted", .idempotency_key = "assign-1", .transitioned_at_ms = 210 });
    defer assigned.deinit(allocator);
    try std.testing.expectEqual(TicketStatus.assigned, assigned.status);
    try std.testing.expectEqual(@as(u64, 2), assigned.revision);
    try std.testing.expectError(Error.InvalidTransition, store.transition(.{ .ticket_id = created.ticket_id, .status = .in_progress, .reason = "start", .transitioned_at_ms = 220 }));

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.assigned, ticket.status);
    try std.testing.expectEqualStrings("recon", ticket.agent_hint);
    try std.testing.expectEqual(@as(usize, 2), projection.valid_events);
}

test "ticket store claim is revision-bound and idempotent" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "claim", .description = "one worker", .category = "task", .severity = "medium", .created_at_ms = 300 });
    defer created.deinit(allocator);
    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "queue", .idempotency_key = "assign-claim", .transitioned_at_ms = 301 });
    defer assigned.deinit(allocator);

    var claim = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = assigned.revision, .worker_id = "worker-1", .worker_generation = 4, .lease_token = "lease-1", .lease_expires_at_ms = 500, .attempt = 1, .session_id = "session-1", .agent_hint = "implementer", .capability_hash = "cap-1", .idempotency_key = "claim-1", .claimed_at_ms = 400 });
    defer claim.deinit(allocator);
    try std.testing.expect(claim.appended);
    try std.testing.expectEqual(@as(u64, 3), claim.revision);
    try std.testing.expectEqualStrings("session-1", claim.session_id);
    try std.testing.expectEqual(@as(u32, 1), claim.attempt);

    var replay = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = 999, .worker_id = "worker-1", .worker_generation = 4, .lease_token = "lease-1", .lease_expires_at_ms = 500, .attempt = 1, .session_id = "session-1", .agent_hint = "implementer", .capability_hash = "cap-1", .idempotency_key = "claim-1", .claimed_at_ms = 400 });
    defer replay.deinit(allocator);
    try std.testing.expect(!replay.appended);
    try std.testing.expectEqual(claim.revision, replay.revision);
    try std.testing.expectError(Error.InvalidClaim, store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .worker_id = "worker-2", .worker_generation = 1, .lease_token = "lease-2", .lease_expires_at_ms = 600, .attempt = 1, .session_id = "session-2", .agent_hint = "implementer", .capability_hash = "cap-2", .idempotency_key = "claim-2", .claimed_at_ms = 401 }));

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.in_progress, ticket.status);
    try std.testing.expect(ticket.claim_complete);
    try std.testing.expectEqualStrings("worker-1", ticket.worker_id);
    try std.testing.expectEqualStrings("lease-1", ticket.lease_token);
    try std.testing.expectEqual(@as(u64, 3), projection.last_seq);
}

test "ticket store resumes one expired claim on the same session under a new generation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "resume", .description = "same durable work", .category = "architecture", .severity = "high", .created_at_ms = 410 });
    defer created.deinit(allocator);
    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "queue", .idempotency_key = "assign-resume", .transitioned_at_ms = 411 });
    defer assigned.deinit(allocator);
    var claim = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = assigned.revision, .worker_id = "worker-old", .worker_generation = 7, .lease_token = "lease-old", .lease_expires_at_ms = 500, .attempt = 3, .session_id = "session-stable", .agent_hint = "implementer", .capability_hash = "cap-stable", .idempotency_key = "claim-resume", .claimed_at_ms = 450 });
    defer claim.deinit(allocator);

    try std.testing.expectError(Error.LeaseNotExpired, store.resumeExpired(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .worker_id = "worker-new", .worker_generation = 8, .lease_token = "lease-new", .lease_expires_at_ms = 800, .session_id = "session-stable", .idempotency_key = "resume-early", .resumed_at_ms = 499 }));
    var resumed = try store.resumeExpired(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .worker_id = "worker-new", .worker_generation = 8, .lease_token = "lease-new", .lease_expires_at_ms = 800, .session_id = "session-stable", .idempotency_key = "resume-once", .resumed_at_ms = 501 });
    defer resumed.deinit(allocator);
    try std.testing.expect(resumed.appended);
    try std.testing.expectEqual(@as(u64, 4), resumed.revision);
    try std.testing.expectEqual(@as(u32, 3), resumed.attempt);
    try std.testing.expectEqualStrings("session-stable", resumed.session_id);
    try std.testing.expectEqualStrings("worker-new", resumed.worker_id);
    try std.testing.expectEqual(@as(u64, 8), resumed.worker_generation);
    try std.testing.expectEqualStrings("lease-new", resumed.lease_token);

    var replay = try store.resumeExpired(.{ .ticket_id = created.ticket_id, .expected_revision = 999, .worker_id = "wrong-worker", .worker_generation = 99, .lease_token = "wrong-lease", .lease_expires_at_ms = 9999, .session_id = "wrong-session", .idempotency_key = "resume-once", .resumed_at_ms = 501 });
    defer replay.deinit(allocator);
    try std.testing.expect(!replay.appended);
    try std.testing.expectEqual(resumed.revision, replay.revision);
    try std.testing.expectError(Error.InvalidResume, store.resumeExpired(.{ .ticket_id = created.ticket_id, .expected_revision = resumed.revision, .worker_id = "worker-next", .worker_generation = 9, .lease_token = "lease-next", .lease_expires_at_ms = 900, .session_id = "session-other", .idempotency_key = "resume-wrong-session", .resumed_at_ms = 801 }));

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.in_progress, ticket.status);
    try std.testing.expect(ticket.claim_complete);
    try std.testing.expectEqualStrings("session-stable", ticket.active_session_id);
    try std.testing.expectEqual(@as(u32, 3), ticket.attempt);
    try std.testing.expectEqualStrings("cap-stable", ticket.capability_hash);
    try std.testing.expectEqual(@as(usize, 4), projection.valid_events);

    const ledger_path = try store.ledgerPath();
    defer allocator.free(ledger_path);
    try fsutil.appendText(ledger_path, "{poisoned resume suffix\n");
    try std.testing.expectError(Error.PoisonedSuffix, store.resumeExpired(.{ .ticket_id = created.ticket_id, .expected_revision = resumed.revision, .worker_id = "worker-next", .worker_generation = 9, .lease_token = "lease-next", .lease_expires_at_ms = 1000, .session_id = "session-stable", .idempotency_key = "resume-poisoned", .resumed_at_ms = 801 }));
}

test "ticket store requeues only expired claims and preserves stale session evidence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "recover", .description = "stale lease", .category = "architecture", .severity = "blocker", .created_at_ms = 500 });
    defer created.deinit(allocator);
    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "queue", .idempotency_key = "assign-recover", .transitioned_at_ms = 501 });
    defer assigned.deinit(allocator);
    var claim = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = assigned.revision, .worker_id = "worker-stale", .worker_generation = 2, .lease_token = "lease-stale", .lease_expires_at_ms = 700, .attempt = 2, .session_id = "session-stale", .agent_hint = "planner", .capability_hash = "cap-stale", .idempotency_key = "claim-recover", .claimed_at_ms = 600 });
    defer claim.deinit(allocator);

    try std.testing.expectError(Error.LeaseNotExpired, store.requeueExpired(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .reason = "still live", .failure_class = "heartbeat_pending", .idempotency_key = "requeue-early", .requeued_at_ms = 699 }));
    var requeued = try store.requeueExpired(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .reason = "worker disappeared", .failure_class = "stale_lease", .idempotency_key = "requeue-1", .requeued_at_ms = 701 });
    defer requeued.deinit(allocator);
    try std.testing.expectEqual(TicketStatus.assigned, requeued.status);
    try std.testing.expectEqual(@as(u64, 4), requeued.revision);

    var replay = try store.requeueExpired(.{ .ticket_id = created.ticket_id, .expected_revision = 999, .reason = "worker disappeared", .failure_class = "stale_lease", .idempotency_key = "requeue-1", .requeued_at_ms = 701 });
    defer replay.deinit(allocator);
    try std.testing.expect(!replay.appended);
    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.assigned, ticket.status);
    try std.testing.expectEqualStrings("session-stale", ticket.last_session_id);
    try std.testing.expectEqualStrings("stale_lease", ticket.failure_class);
    try std.testing.expect(std.mem.startsWith(u8, ticket.failure_id, "failure-"));
    try std.testing.expect(!ticket.claim_complete);
}

test "ticket store terminal evidence keeps completed separate from closed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "failed task", .description = "needs terminal evidence", .category = "bug", .severity = "high", .created_at_ms = 800 });
    defer created.deinit(allocator);
    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "queue", .idempotency_key = "assign-terminal", .transitioned_at_ms = 801 });
    defer assigned.deinit(allocator);
    var claim = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = assigned.revision, .worker_id = "worker-terminal", .worker_generation = 1, .lease_token = "lease-terminal", .lease_expires_at_ms = 900, .attempt = 1, .session_id = "session-terminal", .agent_hint = "recon", .capability_hash = "cap-terminal", .idempotency_key = "claim-terminal", .claimed_at_ms = 850 });
    defer claim.deinit(allocator);

    try std.testing.expectError(Error.InvalidTerminalEvidence, store.complete(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .session_id = "session-terminal", .lease_token = "lease-terminal", .terminal_receipt = "", .idempotency_key = "complete-empty", .completed_at_ms = 901 }));
    var completed = try store.complete(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .session_id = "session-terminal", .lease_token = "lease-terminal", .terminal_receipt = "receipt-1", .idempotency_key = "complete-1", .completed_at_ms = 901 });
    defer completed.deinit(allocator);
    try std.testing.expectEqual(TicketStatus.completed, completed.status);
    var closed = try store.close(.{ .ticket_id = created.ticket_id, .expected_revision = completed.revision, .idempotency_key = "close-1", .closed_at_ms = 902 });
    defer closed.deinit(allocator);
    try std.testing.expectEqual(TicketStatus.closed, closed.status);

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.closed, ticket.status);
}

test "ticket store preserves valid prefix and rejects poisoned suffix writes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    var created = try store.create(.{ .title = "poison", .description = "suffix", .category = "task", .severity = "low", .created_at_ms = 1000 });
    defer created.deinit(allocator);
    const path = try store.ledgerPath();
    defer allocator.free(path);
    try fsutil.appendText(path, "{malformed trailing json\n");

    var projection = try store.readProjection();
    defer projection.deinit();
    try std.testing.expect(projection.poisoned_suffix);
    try std.testing.expectEqual(@as(usize, 1), projection.valid_events);
    try std.testing.expect(projection.findConst(created.ticket_id) != null);
    try std.testing.expectError(Error.PoisonedSuffix, store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "cannot append behind poison", .idempotency_key = "poison-transition", .transitioned_at_ms = 1001 }));
}

test "ticket store projects legacy v1 rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    const path = try store.ledgerPath();
    defer allocator.free(path);
    try fsutil.appendText(path, "{\"schema\":\"var1.ticket.v1\",\"id\":\"legacy-1\",\"title\":\"legacy\",\"description\":\"old row\",\"category\":\"docs\",\"severity\":\"low\",\"status\":\"unassigned\",\"created_at_ms\":1}\n");
    try fsutil.appendText(path, "{\"schema\":\"var1.ticket_transition.v1\",\"ticket_id\":\"legacy-1\",\"status\":\"assigned\",\"reason\":\"old queue\",\"transitioned_at_ms\":2}\n");

    var projection = try store.readProjection();
    defer projection.deinit();
    try std.testing.expectEqual(@as(usize, 2), projection.valid_events);
    const ticket = projection.findConst("legacy-1").?;
    try std.testing.expectEqual(TicketStatus.assigned, ticket.status);
    try std.testing.expectEqualStrings("general", ticket.agent_hint);
    try std.testing.expectEqual(@as(u64, 2), ticket.revision);
}

test "ticket store snapshots every lifecycle bucket and flags a poisoned suffix" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);

    var unassigned = try store.create(.{ .title = "unassigned", .description = "snapshot", .category = "task", .severity = "low", .created_at_ms = 1200 });
    defer unassigned.deinit(allocator);
    var assigned = try store.create(.{ .title = "assigned", .description = "snapshot", .category = "task", .severity = "low", .status = .assigned, .created_at_ms = 1201 });
    defer assigned.deinit(allocator);

    var running = try store.create(.{ .title = "running", .description = "snapshot", .category = "task", .severity = "low", .created_at_ms = 1202 });
    defer running.deinit(allocator);
    var running_assignment = try store.transition(.{ .ticket_id = running.ticket_id, .status = .assigned, .reason = "snapshot", .idempotency_key = "snapshot-assign-running", .transitioned_at_ms = 1203 });
    defer running_assignment.deinit(allocator);
    var running_claim = try store.claim(.{ .ticket_id = running.ticket_id, .expected_revision = running_assignment.revision, .worker_id = "snapshot-worker", .worker_generation = 1, .lease_token = "snapshot-running-lease", .lease_expires_at_ms = 5000, .attempt = 1, .session_id = "snapshot-running-session", .agent_hint = "implementer", .capability_hash = "snapshot-cap", .idempotency_key = "snapshot-claim-running", .claimed_at_ms = 4000 });
    defer running_claim.deinit(allocator);

    var blocked = try store.create(.{ .title = "blocked", .description = "snapshot", .category = "task", .severity = "low", .status = .assigned, .created_at_ms = 1204 });
    defer blocked.deinit(allocator);
    var blocked_transition = try store.transition(.{ .ticket_id = blocked.ticket_id, .status = .blocked, .reason = "snapshot block", .idempotency_key = "snapshot-block", .transitioned_at_ms = 1205 });
    defer blocked_transition.deinit(allocator);

    var completed = try store.create(.{ .title = "completed", .description = "snapshot", .category = "task", .severity = "low", .status = .assigned, .created_at_ms = 1206 });
    defer completed.deinit(allocator);
    var completed_claim = try store.claim(.{ .ticket_id = completed.ticket_id, .expected_revision = completed.revision, .worker_id = "snapshot-worker", .worker_generation = 1, .lease_token = "snapshot-complete-lease", .lease_expires_at_ms = 5000, .attempt = 1, .session_id = "snapshot-complete-session", .agent_hint = "implementer", .capability_hash = "snapshot-cap", .idempotency_key = "snapshot-claim-complete", .claimed_at_ms = 4000 });
    defer completed_claim.deinit(allocator);
    var completed_receipt = try store.complete(.{ .ticket_id = completed.ticket_id, .expected_revision = completed_claim.revision, .session_id = "snapshot-complete-session", .lease_token = "snapshot-complete-lease", .terminal_receipt = "snapshot complete", .idempotency_key = "snapshot-complete", .completed_at_ms = 5001 });
    defer completed_receipt.deinit(allocator);

    var closed = try store.create(.{ .title = "closed", .description = "snapshot", .category = "task", .severity = "low", .status = .assigned, .created_at_ms = 1207 });
    defer closed.deinit(allocator);
    var closed_claim = try store.claim(.{ .ticket_id = closed.ticket_id, .expected_revision = closed.revision, .worker_id = "snapshot-worker", .worker_generation = 1, .lease_token = "snapshot-closed-lease", .lease_expires_at_ms = 5000, .attempt = 1, .session_id = "snapshot-closed-session", .agent_hint = "implementer", .capability_hash = "snapshot-cap", .idempotency_key = "snapshot-claim-closed", .claimed_at_ms = 4000 });
    defer closed_claim.deinit(allocator);
    var closed_receipt = try store.complete(.{ .ticket_id = closed.ticket_id, .expected_revision = closed_claim.revision, .session_id = "snapshot-closed-session", .lease_token = "snapshot-closed-lease", .terminal_receipt = "snapshot closed", .idempotency_key = "snapshot-complete-closed", .completed_at_ms = 5001 });
    defer closed_receipt.deinit(allocator);
    var close_receipt = try store.close(.{ .ticket_id = closed.ticket_id, .expected_revision = closed_receipt.revision, .idempotency_key = "snapshot-close", .closed_at_ms = 5002 });
    defer close_receipt.deinit(allocator);

    const snapshot = try store.snapshot();
    try std.testing.expectEqual(@as(usize, 1), snapshot.unassigned);
    try std.testing.expectEqual(@as(usize, 1), snapshot.assigned);
    try std.testing.expectEqual(@as(usize, 1), snapshot.in_progress);
    try std.testing.expectEqual(@as(usize, 1), snapshot.blocked);
    try std.testing.expectEqual(@as(usize, 1), snapshot.completed);
    try std.testing.expectEqual(@as(usize, 1), snapshot.closed);
    try std.testing.expectEqual(@as(usize, 14), snapshot.valid_events);
    try std.testing.expect(snapshot.healthy);

    const path = try store.ledgerPath();
    defer allocator.free(path);
    try fsutil.appendText(path, "{poisoned snapshot suffix\n");
    const poisoned = try store.snapshot();
    try std.testing.expect(!poisoned.healthy);
    try std.testing.expectEqual(@as(usize, 14), poisoned.valid_events);
    try std.testing.expectEqual(@as(usize, 1), poisoned.assigned);
    try std.testing.expectEqual(@as(usize, 1), poisoned.closed);
}

test "ticket claim heartbeat renews the matching live lease and replays idempotently" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);

    var created = try store.create(.{ .title = "heartbeat", .description = "keep alive", .category = "feature", .severity = "medium", .created_at_ms = 1100 });
    defer created.deinit(allocator);
    var assigned = try store.transition(.{ .ticket_id = created.ticket_id, .status = .assigned, .reason = "queue", .idempotency_key = "assign-heartbeat", .transitioned_at_ms = 1101 });
    defer assigned.deinit(allocator);
    var claim = try store.claim(.{ .ticket_id = created.ticket_id, .expected_revision = assigned.revision, .worker_id = "worker-live", .worker_generation = 3, .lease_token = "lease-live", .lease_expires_at_ms = 1200, .attempt = 1, .session_id = "session-live", .agent_hint = "implementer", .capability_hash = "cap-live", .idempotency_key = "claim-heartbeat", .claimed_at_ms = 1150 });
    defer claim.deinit(allocator);

    var renewed = try store.renewClaim(.{ .ticket_id = created.ticket_id, .expected_revision = claim.revision, .worker_id = "worker-live", .worker_generation = 3, .lease_token = "lease-live", .lease_expires_at_ms = 1400, .session_id = "session-live", .idempotency_key = "heartbeat-1", .renewed_at_ms = 1190 });
    defer renewed.deinit(allocator);
    try std.testing.expect(renewed.appended);
    try std.testing.expectEqual(TicketStatus.in_progress, renewed.status);
    try std.testing.expectEqual(@as(u64, 4), renewed.revision);

    var replay = try store.renewClaim(.{ .ticket_id = created.ticket_id, .expected_revision = 999, .worker_id = "other-worker", .worker_generation = 99, .lease_token = "other-lease", .lease_expires_at_ms = 9999, .session_id = "other-session", .idempotency_key = "heartbeat-1", .renewed_at_ms = 1190 });
    defer replay.deinit(allocator);
    try std.testing.expect(!replay.appended);
    try std.testing.expectEqual(renewed.revision, replay.revision);
    try std.testing.expectError(Error.InvalidRenewal, store.renewClaim(.{ .ticket_id = created.ticket_id, .expected_revision = renewed.revision, .worker_id = "wrong-worker", .worker_generation = 3, .lease_token = "lease-live", .lease_expires_at_ms = 1500, .session_id = "session-live", .idempotency_key = "heartbeat-wrong-worker", .renewed_at_ms = 1200 }));
    try std.testing.expectError(Error.InvalidRenewal, store.renewClaim(.{ .ticket_id = created.ticket_id, .expected_revision = renewed.revision, .worker_id = "worker-live", .worker_generation = 3, .lease_token = "lease-live", .lease_expires_at_ms = 1400, .session_id = "session-live", .idempotency_key = "heartbeat-backward", .renewed_at_ms = 1200 }));
    try std.testing.expectError(Error.LeaseExpired, store.renewClaim(.{ .ticket_id = created.ticket_id, .expected_revision = renewed.revision, .worker_id = "worker-live", .worker_generation = 3, .lease_token = "lease-live", .lease_expires_at_ms = 1500, .session_id = "session-live", .idempotency_key = "heartbeat-too-late", .renewed_at_ms = 1400 }));

    var projection = try store.readProjection();
    defer projection.deinit();
    const ticket = projection.findConst(created.ticket_id).?;
    try std.testing.expectEqual(TicketStatus.in_progress, ticket.status);
    try std.testing.expect(ticket.claim_complete);
    try std.testing.expectEqualStrings("worker-live", ticket.worker_id);
    try std.testing.expectEqualStrings("lease-live", ticket.lease_token);
    try std.testing.expectEqualStrings("session-live", ticket.active_session_id);
    try std.testing.expectEqual(@as(i64, 1400), ticket.lease_expires_at_ms);
    try std.testing.expectEqual(@as(u64, 4), ticket.revision);
    try std.testing.expectEqual(@as(usize, 4), projection.valid_events);
}

test "ticket ledger rejects a second process lock owner" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const store = TicketStore.init(allocator, workspace);
    const lock_path = try store.ledgerLockPath();
    defer allocator.free(lock_path);

    var external_owner = try process_lock.acquire(lock_path, 0);
    try std.testing.expectError(error.LockUnavailable, store.readProjection());
    external_owner.deinit();

    var projection = try store.readProjection();
    defer projection.deinit();
    try std.testing.expectEqual(@as(usize, 0), projection.valid_events);
}
