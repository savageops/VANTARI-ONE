const std = @import("std");
const types = @import("../../shared/types.zig");

pub const ToolReviewRisk = enum {
    read_only,
    write_capable,
    delegating,
    unknown_high_impact,
};

pub const ToolReviewDecision = struct {
    approved: bool,
    risk: ToolReviewRisk,
    event_type: []const u8,
    reason: []const u8,
    tool_error_hint: ?[]const u8 = null,
};

pub fn reviewToolCall(tool_call: types.ToolCall) ToolReviewDecision {
    return reviewToolName(tool_call.name);
}

pub fn reviewToolName(tool_name: []const u8) ToolReviewDecision {
    if (isReadOnly(tool_name)) {
        return .{
            .approved = true,
            .risk = .read_only,
            .event_type = "tool_reviewed",
            .reason = "declared read-only capability",
        };
    }

    if (isWriteCapable(tool_name)) {
        return .{
            .approved = true,
            .risk = .write_capable,
            .event_type = "tool_reviewed",
            .reason = "declared write-capable capability",
        };
    }

    if (std.mem.eql(u8, tool_name, "launch_agent")) {
        return .{
            .approved = true,
            .risk = .delegating,
            .event_type = "tool_reviewed",
            .reason = "declared bounded delegation capability",
        };
    }

    return .{
        .approved = false,
        .risk = .unknown_high_impact,
        .event_type = "tool_blocked",
        .reason = "undeclared capability cannot be dispatched",
        .tool_error_hint = "Use only tools from the current catalog. Unknown tool names are blocked before execution.",
    };
}

pub fn riskLabel(risk: ToolReviewRisk) []const u8 {
    return switch (risk) {
        .read_only => "read_only",
        .write_capable => "write_capable",
        .delegating => "delegating",
        .unknown_high_impact => "unknown_high_impact",
    };
}

pub fn renderReviewEvent(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    decision: ToolReviewDecision,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"schema\":\"var1.tool_review.v1\",\"tool\":");
    try output.writer().print("{f}", .{std.json.fmt(tool_call.name, .{})});
    try output.writer().writeAll(",\"call_id\":");
    try output.writer().print("{f}", .{std.json.fmt(tool_call.id, .{})});
    try output.writer().writeAll(",\"risk\":");
    try output.writer().print("{f}", .{std.json.fmt(riskLabel(decision.risk), .{})});
    try output.writer().writeAll(",\"approved\":");
    try output.writer().writeAll(if (decision.approved) "true" else "false");
    try output.writer().writeAll(",\"reason\":");
    try output.writer().print("{f}", .{std.json.fmt(decision.reason, .{})});
    if (decision.tool_error_hint) |hint| {
        try output.writer().writeAll(",\"tool_error_hint\":");
        try output.writer().print("{f}", .{std.json.fmt(hint, .{})});
    }
    try output.writer().writeAll("}");

    return output.toOwnedSlice();
}

pub fn renderBlockedToolResult(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    decision: ToolReviewDecision,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    try output.writer().writeAll("{\"ok\":false,\"tool\":");
    try output.writer().print("{f}", .{std.json.fmt(tool_call.name, .{})});
    try output.writer().writeAll(",\"error\":\"ToolReviewBlocked\",\"risk\":");
    try output.writer().print("{f}", .{std.json.fmt(riskLabel(decision.risk), .{})});
    try output.writer().writeAll(",\"reason\":");
    try output.writer().print("{f}", .{std.json.fmt(decision.reason, .{})});
    if (decision.tool_error_hint) |hint| {
        try output.writer().writeAll(",\"tool_error_hint\":");
        try output.writer().print("{f}", .{std.json.fmt(hint, .{})});
    }
    try output.writer().writeAll("}");

    return output.toOwnedSlice();
}

pub fn renderReviewLog(
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
    decision: ToolReviewDecision,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "tool reviewed: {s} risk={s} approved={s}", .{
        tool_call.name,
        riskLabel(decision.risk),
        if (decision.approved) "true" else "false",
    });
}

fn isReadOnly(tool_name: []const u8) bool {
    const names = [_][]const u8{
        "list_files",
        "search_files",
        "read_file",
        "agent_status",
        "wait_agent",
        "list_agents",
        "instruction_ingestion",
    };

    return containsName(names[0..], tool_name);
}

fn isWriteCapable(tool_name: []const u8) bool {
    const names = [_][]const u8{
        "write_file",
        "append_file",
        "replace_in_file",
        "init_workspace",
        "memory_ledger",
        "changelog_ledger",
        "todo_slice",
        "session_record",
        "research_artifact",
        "docs_artifact",
        "git_worktree",
        "workspace_backup",
    };

    return containsName(names[0..], tool_name);
}

fn containsName(names: []const []const u8, tool_name: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, tool_name)) return true;
    }
    return false;
}
