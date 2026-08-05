const std = @import("std");

/// Operator-response sanitization. Prevents internal tool names from
/// leaking into assistant output unless the operator explicitly asked
/// for tool documentation. Extracted from loop.zig for seam isolation.

const ToolNameAlias = struct {
    internal_name: []const u8,
    public_phrase: []const u8,
};

const internal_tool_aliases = [_]ToolNameAlias{
    .{ .internal_name = "launch_agent", .public_phrase = "child-run orchestration" },
    .{ .internal_name = "agent_status", .public_phrase = "child-run status checks" },
    .{ .internal_name = "wait_agent", .public_phrase = "child-run wait checks" },
    .{ .internal_name = "list_agents", .public_phrase = "child-run listing" },
};

const documentation_keywords = [_][]const u8{
    "tool",
    "tools",
    "catalog",
    "launch_agent",
    "agent_status",
    "wait_agent",
    "list_agents",
};

pub fn sanitizeOperatorResponse(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    content: []const u8,
) ![]u8 {
    if (promptRequestsToolDocumentation(prompt) or !contentLeaksInternalToolNames(content)) {
        return allocator.dupe(u8, content);
    }

    const redacted = try redactInternalToolNames(allocator, content);
    if (!contentLeaksInternalToolNames(redacted)) {
        return redacted;
    }

    allocator.free(redacted);
    return allocator.dupe(u8, "I completed the request and can provide an operator-safe summary.");
}

fn promptRequestsToolDocumentation(prompt: []const u8) bool {
    for (documentation_keywords) |keyword| {
        if (std.ascii.indexOfIgnoreCase(prompt, keyword) != null) return true;
    }
    return false;
}

fn contentLeaksInternalToolNames(content: []const u8) bool {
    for (internal_tool_aliases) |alias| {
        if (std.ascii.indexOfIgnoreCase(content, alias.internal_name) != null) return true;
    }
    return false;
}

fn redactInternalToolNames(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var redacted = try allocator.dupe(u8, content);
    errdefer allocator.free(redacted);

    for (internal_tool_aliases) |alias| {
        const updated = try replaceAllIgnoreCaseOwned(allocator, redacted, alias.internal_name, alias.public_phrase);
        allocator.free(redacted);
        redacted = updated;
    }

    return redacted;
}

fn replaceAllIgnoreCaseOwned(
    allocator: std.mem.Allocator,
    input: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    if (needle.len == 0) return allocator.dupe(u8, input);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var cursor: usize = 0;
    while (indexOfIgnoreCasePos(input, needle, cursor)) |match_index| {
        try output.appendSlice(input[cursor..match_index]);
        try output.appendSlice(replacement);
        cursor = match_index + needle.len;
    }

    try output.appendSlice(input[cursor..]);
    return output.toOwnedSlice();
}

fn indexOfIgnoreCasePos(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len) return null;

    var index = start;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }

    return null;
}
