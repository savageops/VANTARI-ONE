const std = @import("std");

const tickets = @import("../../tickets/index.zig");
const session_store = @import("../../sessions/store.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "log_ticket",
    .description = "Create, queue, or list durable workspace tickets. Assignment admits work to the buffered queue; provider execution starts only after a scheduler claim and canonical session admission.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": { "type": "string", "enum": ["create", "transition", "list"], "description": "create adds a ticket; transition changes queue admission state; list reads projected current tickets." },
    \\    "title": { "type": "string", "minLength": 1, "maxLength": 256, "description": "One-line summary. Required for create." },
    \\    "description": { "type": "string", "minLength": 1, "maxLength": 8192, "description": "Full problem statement. Required for create." },
    \\    "category": { "type": "string", "enum": ["bug", "feature", "task", "refactor", "security", "architecture", "agent", "tool", "plugin", "performance", "docs"], "description": "Ticket classification. Required for create." },
    \\    "severity": { "type": "string", "enum": ["blocker", "high", "medium", "low"], "description": "Impact level. Defaults to medium; critical is not a supported schema value." },
    \\    "evidence": { "type": "array", "items": { "type": "string" }, "description": "Exact paths, commands, or links that ground the ticket." },
    \\    "proposed_owner": { "type": "string", "description": "Suggested configured agent id or owner path. It is a routing hint, not an execution trigger." },
    \\    "status": { "type": "string", "enum": ["unassigned", "assigned", "in_progress", "blocked", "completed", "closed"], "description": "Create defaults to unassigned. Public transition is queue admission/requeue only; execution and closure require typed evidence." },
    \\    "ticket_id": { "type": "string", "description": "Ticket id returned from create. Required for transition." },
    \\    "transition_reason": { "type": "string", "description": "Why the ticket is entering or leaving the queue. Required for transition." },
    \\    "idempotency_key": { "type": "string", "description": "Stable key for a retryable transition. Reusing it returns the original mutation without appending a duplicate." },
    \\    "limit": { "type": "integer", "minimum": 1, "maximum": 50, "description": "Max projected tickets to return for list. Defaults to 20." }
    \\  },
    \\  "required": ["action"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"action\":\"create\",\"title\":\"search_files unavailable when ix missing\",\"description\":\"The ix dependency is unresolved on Windows installs.\",\"category\":\"tool\",\"severity\":\"high\"}",
    .usage_hint = "Create work as unassigned, transition it to assigned when it is admitted to the queue, and let the scheduler claim it through the configured agent pool. Use list for projected current state. Never use a direct transition to pretend that a provider task or repair review completed.",
};

pub const availability = module.AvailabilitySpec{};

const max_title_bytes: usize = 256;
const max_description_bytes: usize = 8192;

pub const Category = enum {
    bug,
    feature,
    task,
    refactor,
    security,
    architecture,
    agent,
    tool,
    plugin,
    performance,
    docs,

    pub fn parse(value: []const u8) error{InvalidCategory}!Category {
        inline for (@typeInfo(Category).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidCategory;
    }
};

pub const Severity = enum {
    blocker,
    high,
    medium,
    low,

    pub fn parse(value: []const u8) error{InvalidSeverity}!Severity {
        inline for (@typeInfo(Severity).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidSeverity;
    }
};

pub const Status = tickets.TicketStatus;

const Args = struct {
    action: []const u8 = "create",
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    category: ?[]const u8 = null,
    severity: ?[]const u8 = null,
    evidence: []const []const u8 = &.{},
    proposed_owner: ?[]const u8 = null,
    status: ?[]const u8 = null,
    ticket_id: ?[]const u8 = null,
    transition_reason: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    limit: ?usize = null,
};

pub fn execute(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    arguments_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(Args, allocator, arguments_json, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const args = parsed.value;

    if (std.mem.eql(u8, args.action, "list")) return executeList(allocator, execution_context, args);
    if (std.mem.eql(u8, args.action, "transition")) return executeTransition(allocator, execution_context, args);
    if (!std.mem.eql(u8, args.action, "create")) return module.Error.InvalidArguments;
    return executeCreate(allocator, execution_context, args);
}

fn executeCreate(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    args: Args,
) ![]u8 {
    const title = std.mem.trim(u8, args.title orelse return module.Error.InvalidArguments, " \t\r\n");
    if (title.len == 0) return module.Error.InvalidArguments;
    if (title.len > max_title_bytes) return module.Error.ToolPayloadExceeded;

    const description = std.mem.trim(u8, args.description orelse return module.Error.InvalidArguments, " \t\r\n");
    if (description.len == 0) return module.Error.InvalidArguments;
    if (description.len > max_description_bytes) return module.Error.ToolPayloadExceeded;

    const category = Category.parse(args.category orelse return module.Error.InvalidArguments) catch return module.Error.InvalidArguments;
    const severity = if (args.severity) |value| Severity.parse(value) catch return module.Error.InvalidArguments else .medium;
    const status = if (args.status) |value| Status.parse(value) catch return module.Error.InvalidArguments else .unassigned;
    const source_session_id = execution_context.session_id orelse execution_context.parent_session_id orelse "";

    const store = tickets.TicketStore.init(allocator, execution_context.workspace_root);
    var receipt = store.create(.{
        .title = title,
        .description = description,
        .category = @tagName(category),
        .severity = @tagName(severity),
        .status = status,
        .evidence = args.evidence,
        .proposed_owner = args.proposed_owner orelse "",
        .workspace_root = execution_context.workspace_root,
        .session_id = source_session_id,
        .idempotency_key = args.idempotency_key orelse "",
        .created_at_ms = std.time.milliTimestamp(),
    }) catch |err| return mapStoreError(err);
    defer receipt.deinit(allocator);

    const ledger_path = try store.ledgerPath();
    defer allocator.free(ledger_path);
    const body = try std.fmt.allocPrint(allocator, "{{\"ticket_id\":{f},\"category\":{f},\"severity\":{f},\"status\":{f},\"revision\":{d},\"queued\":{s},\"ledger_path\":{f}}}", .{
        std.json.fmt(receipt.ticket_id, .{}),
        std.json.fmt(@tagName(category), .{}),
        std.json.fmt(@tagName(severity), .{}),
        std.json.fmt(@tagName(receipt.status), .{}),
        receipt.revision,
        if (receipt.status == .assigned) "true" else "false",
        std.json.fmt(ledger_path, .{}),
    });
    defer allocator.free(body);
    return module.okEnvelope(allocator, "log_ticket", body);
}

fn executeTransition(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    args: Args,
) ![]u8 {
    const ticket_id = args.ticket_id orelse return module.Error.InvalidArguments;
    const status = Status.parse(args.status orelse return module.Error.InvalidArguments) catch return module.Error.InvalidArguments;
    const reason = std.mem.trim(u8, args.transition_reason orelse return module.Error.InvalidArguments, " \t\r\n");
    if (reason.len == 0) return module.Error.InvalidArguments;

    const store = tickets.TicketStore.init(allocator, execution_context.workspace_root);
    var receipt = store.transition(.{
        .ticket_id = ticket_id,
        .status = status,
        .reason = reason,
        .idempotency_key = args.idempotency_key orelse "",
        .transitioned_at_ms = std.time.milliTimestamp(),
    }) catch |err| return mapStoreError(err);
    defer receipt.deinit(allocator);

    const body = try std.fmt.allocPrint(allocator, "{{\"ticket_id\":{f},\"transitioned_to\":{f},\"revision\":{d},\"appended\":{s},\"reason\":{f}}}", .{
        std.json.fmt(receipt.ticket_id, .{}),
        std.json.fmt(@tagName(receipt.status), .{}),
        receipt.revision,
        if (receipt.appended) "true" else "false",
        std.json.fmt(reason, .{}),
    });
    defer allocator.free(body);
    return module.okEnvelope(allocator, "log_ticket", body);
}

fn executeList(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    args: Args,
) ![]u8 {
    const limit = if (args.limit) |value| @min(@max(value, 1), 50) else 20;
    const store = tickets.TicketStore.init(allocator, execution_context.workspace_root);
    var projection = store.readProjection() catch |err| return mapStoreError(err);
    defer projection.deinit();

    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    const writer = output.writer();
    try writer.print("TICKETS {d} of {d} valid_events={d} poisoned_suffix={s}\n", .{
        @min(projection.tickets.items.len, limit),
        projection.tickets.items.len,
        projection.valid_events,
        if (projection.poisoned_suffix) "true" else "false",
    });

    var emitted: usize = 0;
    var index = projection.tickets.items.len;
    while (index > 0 and emitted < limit) {
        index -= 1;
        const ticket = projection.tickets.items[index];
        try writer.print("- {s} [{s}] {s} severity={s} rev={d} agent={s} claim={s}\n", .{
            ticket.id,
            @tagName(ticket.status),
            ticket.title,
            ticket.severity,
            ticket.revision,
            ticket.agent_hint,
            if (ticket.claim_complete) "active" else "waiting",
        });
        emitted += 1;
    }

    return module.okEnvelope(allocator, "log_ticket", output.items);
}

fn mapStoreError(err: anyerror) module.Error {
    return switch (err) {
        error.PoisonedSuffix => module.Error.ToolUnavailable,
        error.InvalidArguments,
        error.InvalidInitialStatus,
        error.InvalidTransition,
        error.InvalidClaim,
        error.InvalidTerminalEvidence,
        error.TicketNotFound,
        error.RevisionConflict,
        error.IdempotencyConflict,
        error.NoopTransition,
        error.LeaseNotExpired,
        => module.Error.InvalidArguments,
        else => module.Error.ToolUnavailable,
    };
}

test "log_ticket creates a durable projected queue record" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace, .session_id = "source-session" };

    const output = try execute(allocator, ctx,
        \\{"title":"search_files unavailable when ix missing","description":"The advertised ix dependency is unresolved on Windows installs.","category":"tool","severity":"high","evidence":["registry.zig:141","health --json"],"proposed_owner":"apps/backend/src/core/tools/registry.zig"}
    );
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "log_ticket") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ticket-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "unassigned") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "queued") != null);

    const store = tickets.TicketStore.init(allocator, workspace);
    var projection = try store.readProjection();
    defer projection.deinit();
    try std.testing.expectEqual(@as(usize, 1), projection.tickets.items.len);
    try std.testing.expectEqualStrings("source-session", projection.tickets.items[0].source_session_id);
    try std.testing.expectEqualStrings("apps/backend/src/core/tools/registry.zig", projection.tickets.items[0].agent_hint);
}

test "log_ticket rejects empty fields and unsupported severity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"   \",\"description\":\"valid\",\"category\":\"bug\"}"));
    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"valid\",\"description\":\"\",\"category\":\"bug\"}"));
    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"t\",\"description\":\"d\",\"category\":\"not_a_real_category\"}"));
    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"t\",\"description\":\"d\",\"category\":\"bug\",\"severity\":\"critical\"}"));
}

test "log_ticket assignment paths append queue state without a child session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };
    const create_output = try execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"queue\",\"description\":\"wait\",\"category\":\"feature\"}");
    defer allocator.free(create_output);

    var projection = try (tickets.TicketStore.init(allocator, workspace)).readProjection();
    const ticket_id = try allocator.dupe(u8, projection.tickets.items[0].id);
    projection.deinit();
    defer allocator.free(ticket_id);
    const transition_input = try std.fmt.allocPrint(allocator, "{{\"action\":\"transition\",\"ticket_id\":{f},\"status\":\"assigned\",\"transition_reason\":\"admit\",\"idempotency_key\":\"tool-assign-1\"}}", .{std.json.fmt(ticket_id, .{})});
    defer allocator.free(transition_input);
    const assigned_output = try execute(allocator, ctx, transition_input);
    defer allocator.free(assigned_output);
    try std.testing.expect(std.mem.indexOf(u8, assigned_output, "transitioned_to") != null);
    try std.testing.expect(std.mem.indexOf(u8, assigned_output, "assigned") != null);

    const direct_assigned_output = try execute(allocator, ctx, "{\"action\":\"create\",\"title\":\"direct queue\",\"description\":\"wait too\",\"category\":\"task\",\"status\":\"assigned\"}");
    defer allocator.free(direct_assigned_output);
    var direct_envelope = try std.json.parseFromSlice(struct {
        ok: bool,
        content: []const u8,
    }, allocator, direct_assigned_output, .{ .ignore_unknown_fields = true });
    defer direct_envelope.deinit();
    try std.testing.expect(direct_envelope.value.ok);
    try std.testing.expect(std.mem.indexOf(u8, direct_envelope.value.content, "\"queued\":true") != null);

    try std.testing.expectError(module.Error.InvalidArguments, execute(allocator, ctx, "{\"action\":\"transition\",\"ticket_id\":\"missing\",\"status\":\"in_progress\",\"transition_reason\":\"start\"}"));
    const list_output = try execute(allocator, ctx, "{\"action\":\"list\",\"limit\":10}");
    defer allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "[assigned]") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "claim=waiting") != null);

    var assigned_projection = try (tickets.TicketStore.init(allocator, workspace)).readProjection();
    defer assigned_projection.deinit();
    try std.testing.expectEqual(@as(usize, 3), assigned_projection.valid_events);
    try std.testing.expectEqual(@as(usize, 2), assigned_projection.tickets.items.len);
    for (assigned_projection.tickets.items) |ticket| {
        try std.testing.expectEqual(Status.assigned, ticket.status);
        try std.testing.expect(!ticket.claim_complete);
        try std.testing.expectEqual(@as(usize, 0), ticket.active_session_id.len);
    }

    const sessions = try session_store.listSessionRecords(allocator, workspace);
    defer types.deinitSessionRecords(allocator, sessions);
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "category severity and status enums map their supported tag surface" {
    try std.testing.expectEqualStrings("bug", @tagName(try Category.parse("bug")));
    try std.testing.expectEqualStrings("architecture", @tagName(try Category.parse("architecture")));
    try std.testing.expectEqualStrings("plugin", @tagName(try Category.parse("plugin")));
    try std.testing.expectEqualStrings("blocker", @tagName(try Severity.parse("blocker")));
    try std.testing.expectEqualStrings("low", @tagName(try Severity.parse("low")));
    try std.testing.expectEqualStrings("closed", @tagName(try Status.parse("closed")));
    try std.testing.expectError(error.InvalidCategory, Category.parse("unknown"));
    try std.testing.expectError(error.InvalidSeverity, Severity.parse("unknown"));
    try std.testing.expectError(tickets.Error.InvalidArguments, Status.parse("resolved"));
}
