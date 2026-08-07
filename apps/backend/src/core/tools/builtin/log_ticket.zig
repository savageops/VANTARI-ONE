const std = @import("std");

const fsutil = @import("../../../shared/fsutil.zig");
const types = @import("../../../shared/types.zig");
const module = @import("../module.zig");

pub const definition = types.ToolDefinition{
    .name = "log_ticket",
    .description = "Create, transition, or list durable tickets in the workspace ticket ledger (.var/tickets/tickets.jsonl). Tickets track gaps, defects, tasks, and improvements through a full lifecycle: unassigned → assigned → in_progress → completed → closed. Use for long-task tracking, quality steps, and research-focused work.",
    .review_risk = .write_capable,
    .parameters_json =
    \\{
    \\  "type": "object",
    \\  "properties": {
    \\    "action": { "type": "string", "enum": ["create", "transition", "list"], "description": "create appends a new ticket; transition moves an existing ticket to a new state; list reads recent tickets." },
    \\    "title": { "type": "string", "minLength": 1, "maxLength": 256, "description": "One-line summary. Required for create." },
    \\    "description": { "type": "string", "minLength": 1, "maxLength": 8192, "description": "Full problem statement. Required for create." },
    \\    "category": { "type": "string", "enum": ["bug", "feature", "task", "refactor", "security", "architecture", "agent", "tool", "plugin", "performance", "docs"], "description": "Ticket classification. Required for create." },
    \\    "severity": { "type": "string", "enum": ["blocker", "high", "medium", "low"], "description": "Impact level. Defaults to medium." },
    \\    "evidence": { "type": "array", "items": { "type": "string" }, "description": "Exact paths, commands, or links that ground the ticket." },
    \\    "proposed_owner": { "type": "string", "description": "Suggested owner path, module, or agent id." },
    \\    "status": { "type": "string", "enum": ["unassigned", "assigned", "in_progress", "blocked", "completed", "closed"], "description": "Lifecycle state. Defaults to unassigned for create; required for transition." },
    \\    "ticket_id": { "type": "string", "description": "Ticket id returned from create. Required for transition." },
    \\    "transition_reason": { "type": "string", "description": "Why the ticket is transitioning. Required for transition." },
    \\    "limit": { "type": "integer", "minimum": 1, "maximum": 50, "description": "Max tickets to return for list. Defaults to 20." }
    \\  },
    \\  "required": ["action"],
    \\  "additionalProperties": false
    \\}
    ,
    .example_json = "{\"action\":\"create\",\"title\":\"search_files unavailable when iex missing\",\"description\":\"The iex dependency is unresolved on Windows.\",\"category\":\"tool\",\"severity\":\"high\"}",
    .usage_hint = "Use create for new tickets, transition to move through lifecycle states (unassigned→assigned→in_progress→completed→closed), and list to review recent tickets. Every long task should be tracked as a ticket for accuracy and recovery. Never silently drop work items.",
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

pub const Status = enum {
    unassigned,
    assigned,
    in_progress,
    blocked,
    completed,
    closed,

    pub fn parse(value: []const u8) error{InvalidStatus}!Status {
        inline for (@typeInfo(Status).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
        }
        return error.InvalidStatus;
    }
};

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

    if (std.mem.eql(u8, args.action, "list")) {
        return executeList(allocator, execution_context, args);
    }

    if (std.mem.eql(u8, args.action, "transition")) {
        return executeTransition(allocator, execution_context, args);
    }

    // Default: create
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

    const now_ms = std.time.milliTimestamp();
    const nonce = std.crypto.random.int(u64);
    const ticket_id = try std.fmt.allocPrint(allocator, "ticket-{d}-{x}", .{ now_ms, nonce });
    defer allocator.free(ticket_id);

    const record = try buildRecord(
        allocator,
        ticket_id,
        title,
        description,
        category,
        severity,
        status,
        args.evidence,
        args.proposed_owner,
        execution_context.workspace_root,
        execution_context.parent_session_id,
        now_ms,
    );
    defer allocator.free(record);

    const ledger_path = try fsutil.join(allocator, &.{ execution_context.workspace_root, ".var", "tickets", "tickets.jsonl" });
    defer allocator.free(ledger_path);

    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();
    try line.appendSlice(record);
    try line.append('\n');
    try fsutil.appendText(ledger_path, line.items);

    const receipt = try buildReceipt(allocator, ticket_id, category, severity, status, ledger_path, record.len);
    defer allocator.free(receipt);
    return module.okEnvelope(allocator, "log_ticket", receipt);
}

/// Transition a ticket to a new lifecycle state. Appends a transition record
/// to the same ledger with the ticket_id, new status, reason, and timestamp.
fn executeTransition(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    args: Args,
) ![]u8 {
    const ticket_id = args.ticket_id orelse return module.Error.InvalidArguments;
    const new_status = Status.parse(args.status orelse return module.Error.InvalidArguments) catch return module.Error.InvalidArguments;
    const reason = args.transition_reason orelse return module.Error.InvalidArguments;

    const now_ms = std.time.milliTimestamp();
    const record = try std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.ticket_transition.v1\",\"ticket_id\":{f},\"status\":{f},\"reason\":{f},\"transitioned_at_ms\":{d},\"source\":\"agent\"}}",
        .{
            std.json.fmt(ticket_id, .{}),
            std.json.fmt(@tagName(new_status), .{}),
            std.json.fmt(reason, .{}),
            now_ms,
        },
    );
    defer allocator.free(record);

    const ledger_path = try fsutil.join(allocator, &.{ execution_context.workspace_root, ".var", "tickets", "tickets.jsonl" });
    defer allocator.free(ledger_path);

    var line = std.array_list.Managed(u8).init(allocator);
    defer line.deinit();
    try line.appendSlice(record);
    try line.append('\n');
    try fsutil.appendText(ledger_path, line.items);

    const receipt = try std.fmt.allocPrint(allocator, "{{\"ticket_id\":{f},\"transitioned_to\":{f},\"reason\":{f}}}", .{
        std.json.fmt(ticket_id, .{}),
        std.json.fmt(@tagName(new_status), .{}),
        std.json.fmt(reason, .{}),
    });
    defer allocator.free(receipt);
    return module.okEnvelope(allocator, "log_ticket", receipt);
}

/// List recent tickets from the ledger (most recent first).
fn executeList(
    allocator: std.mem.Allocator,
    execution_context: module.ExecutionContext,
    args: Args,
) ![]u8 {
    const limit = if (args.limit) |l| @min(@max(l, 1), 50) else 20;

    const ledger_path = try fsutil.join(allocator, &.{ execution_context.workspace_root, ".var", "tickets", "tickets.jsonl" });
    defer allocator.free(ledger_path);

    const content = fsutil.readTextAlloc(allocator, ledger_path) catch |err| switch (err) {
        error.FileNotFound => return module.okEnvelope(allocator, "log_ticket", "TICKETS empty\nREASON no ticket ledger found yet"),
        else => return err,
    };
    defer allocator.free(content);

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
    try writer.print("TICKETS {d} of {d}\n", .{ count, total });

    var i: usize = total;
    while (i > start) {
        i -= 1;
        try writer.print("- {s}\n", .{lines.items[i]});
    }

    return module.okEnvelope(allocator, "log_ticket", output.items);
}

fn buildRecord(
    allocator: std.mem.Allocator,
    ticket_id: []const u8,
    title: []const u8,
    description: []const u8,
    category: Category,
    severity: Severity,
    status: Status,
    evidence: []const []const u8,
    proposed_owner: ?[]const u8,
    workspace_root: []const u8,
    session_id: ?[]const u8,
    created_at_ms: i64,
) ![]u8 {
    var evidence_list = std.array_list.Managed(u8).init(allocator);
    defer evidence_list.deinit();
    const ev_writer = evidence_list.writer();
    try ev_writer.writeByte('[');
    for (evidence, 0..) |item, index| {
        if (index > 0) try ev_writer.writeByte(',');
        try ev_writer.print("{f}", .{std.json.fmt(item, .{})});
    }
    try ev_writer.writeByte(']');

    const owner_value = proposed_owner orelse "";

    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.ticket.v1\",\"id\":{f},\"title\":{f},\"description\":{f},\"category\":{f},\"severity\":{f},\"status\":{f},\"evidence\":{s},\"proposed_owner\":{f},\"workspace_root\":{f},\"session_id\":{f},\"created_at_ms\":{d},\"source\":\"agent\"}}",
        .{
            std.json.fmt(ticket_id, .{}),
            std.json.fmt(title, .{}),
            std.json.fmt(description, .{}),
            std.json.fmt(@tagName(category), .{}),
            std.json.fmt(@tagName(severity), .{}),
            std.json.fmt(@tagName(status), .{}),
            evidence_list.items,
            std.json.fmt(owner_value, .{}),
            std.json.fmt(workspace_root, .{}),
            std.json.fmt(session_id orelse "", .{}),
            created_at_ms,
        },
    );
}

fn buildReceipt(
    allocator: std.mem.Allocator,
    ticket_id: []const u8,
    category: Category,
    severity: Severity,
    status: Status,
    ledger_path: []const u8,
    record_bytes: usize,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ticket_id\":{f},\"category\":{f},\"severity\":{f},\"status\":{f},\"ledger_path\":{f},\"record_bytes\":{d}}}",
        .{
            std.json.fmt(ticket_id, .{}),
            std.json.fmt(@tagName(category), .{}),
            std.json.fmt(@tagName(severity), .{}),
            std.json.fmt(@tagName(status), .{}),
            std.json.fmt(ledger_path, .{}),
            record_bytes,
        },
    );
}

test "log_ticket appends a durable schema-bound record to the workspace ledger" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    const output = try execute(allocator, ctx,
        \\{"title":"search_files unavailable when iex missing","description":"The advertised iex dependency is unresolved on Windows installs.","category":"tool","severity":"high","evidence":["registry.zig:141","health --json"],"proposed_owner":"apps/backend/src/core/tools/registry.zig"}
    );
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "log_ticket") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ticket-") != null);

    const ledger_path = try fsutil.join(allocator, &.{ workspace, ".var", "tickets", "tickets.jsonl" });
    defer allocator.free(ledger_path);
    try std.testing.expect(fsutil.fileExists(ledger_path));

    const content = try fsutil.readTextAlloc(allocator, ledger_path);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "var1.ticket.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "search_files unavailable when iex missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"category\":\"tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"severity\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"source\":\"agent\"") != null);
}

test "log_ticket rejects empty title or description" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, ctx, "{\"title\":\"   \",\"description\":\"valid\",\"category\":\"bug\"}"),
    );
    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, ctx, "{\"title\":\"valid\",\"description\":\"\",\"category\":\"bug\"}"),
    );
}

test "log_ticket rejects unknown category or severity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer allocator.free(workspace);
    const ctx = module.ExecutionContext{ .workspace_root = workspace };

    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, ctx, "{\"title\":\"t\",\"description\":\"d\",\"category\":\"not_a_real_category\"}"),
    );
    try std.testing.expectError(
        module.Error.InvalidArguments,
        execute(allocator, ctx, "{\"title\":\"t\",\"description\":\"d\",\"category\":\"bug\",\"severity\":\"critical\"}"),
    );
}

test "category severity and status enums map their full tag surface" {
    try std.testing.expectEqualStrings("bug", @tagName(try Category.parse("bug")));
    try std.testing.expectEqualStrings("architecture", @tagName(try Category.parse("architecture")));
    try std.testing.expectEqualStrings("plugin", @tagName(try Category.parse("plugin")));
    try std.testing.expectEqualStrings("blocker", @tagName(try Severity.parse("blocker")));
    try std.testing.expectEqualStrings("low", @tagName(try Severity.parse("low")));
    try std.testing.expectEqualStrings("resolved", @tagName(try Status.parse("resolved")));
    try std.testing.expectError(error.InvalidCategory, Category.parse("unknown"));
    try std.testing.expectError(error.InvalidSeverity, Severity.parse("unknown"));
    try std.testing.expectError(error.InvalidStatus, Status.parse("unknown"));
}
