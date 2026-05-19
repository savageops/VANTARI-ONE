const std = @import("std");
const types = @import("../../shared/types.zig");

pub const Error = error{
    InvalidValue,
};

const settings_path_parts = [_][]const u8{ ".var", "config", "settings.toml" };

pub fn loadContextPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    defaults: types.ContextPolicy,
) !types.ContextPolicy {
    const settings_path = try std.fs.path.join(allocator, &.{ workspace_root, settings_path_parts[0], settings_path_parts[1], settings_path_parts[2] });
    defer allocator.free(settings_path);

    const content = std.fs.cwd().readFileAlloc(allocator, settings_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return defaults,
        else => return err,
    };
    defer allocator.free(content);

    return parseContextPolicy(content, defaults);
}

pub fn loadPromptPolicy(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    defaults: types.PromptPolicy,
) !types.PromptPolicy {
    const settings_path = try std.fs.path.join(allocator, &.{ workspace_root, settings_path_parts[0], settings_path_parts[1], settings_path_parts[2] });
    defer allocator.free(settings_path);

    const content = std.fs.cwd().readFileAlloc(allocator, settings_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return clonePromptPolicy(allocator, defaults),
        else => return err,
    };
    defer allocator.free(content);

    return parsePromptPolicy(allocator, content, defaults);
}

pub fn parseContextPolicy(content: []const u8, defaults: types.ContextPolicy) !types.ContextPolicy {
    var policy = defaults;
    var in_context_section = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line_without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') return Error.InvalidValue;
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            in_context_section = std.mem.eql(u8, section, "context");
            continue;
        }

        if (!in_context_section) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse return Error.InvalidValue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        const value = std.mem.trim(u8, line[separator_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return Error.InvalidValue;

        if (std.mem.eql(u8, key, "auto_compaction")) {
            policy.auto_compaction = try parseBool(value);
        } else if (std.mem.eql(u8, key, "manual_compaction")) {
            policy.manual_compaction = try parseBool(value);
        } else if (std.mem.eql(u8, key, "context_window_tokens")) {
            policy.context_window_tokens = try parseUnsigned(u64, value);
        } else if (std.mem.eql(u8, key, "compact_at_ratio_milli")) {
            policy.compact_at_ratio_milli = try parseRatioMilli(value);
        } else if (std.mem.eql(u8, key, "compact_at_ratio")) {
            policy.compact_at_ratio_milli = try parseFloatRatioMilli(value);
        } else if (std.mem.eql(u8, key, "reserve_output_tokens")) {
            policy.reserve_output_tokens = try parseUnsigned(u64, value);
        } else if (std.mem.eql(u8, key, "keep_recent_messages")) {
            policy.keep_recent_messages = try parseUnsigned(usize, value);
        } else if (std.mem.eql(u8, key, "max_entries_per_checkpoint")) {
            policy.max_entries_per_checkpoint = try parseUnsigned(usize, value);
        } else if (std.mem.eql(u8, key, "aggressiveness_milli")) {
            policy.aggressiveness_milli = try parseRatioMilli(value);
        } else if (std.mem.eql(u8, key, "retry_on_provider_overflow")) {
            policy.retry_on_provider_overflow = try parseBool(value);
        } else {
            return Error.InvalidValue;
        }
    }

    try validate(policy);
    return policy;
}

pub fn parsePromptPolicy(
    allocator: std.mem.Allocator,
    content: []const u8,
    defaults: types.PromptPolicy,
) !types.PromptPolicy {
    var policy = try clonePromptPolicy(allocator, defaults);
    errdefer policy.deinit(allocator);
    var in_prompts_section = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line_without_comment = stripComment(raw_line);
        const line = std.mem.trim(u8, line_without_comment, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') return Error.InvalidValue;
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            in_prompts_section = std.mem.eql(u8, section, "prompts");
            continue;
        }

        if (!in_prompts_section) continue;

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse return Error.InvalidValue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        const value = try parseTomlStringScalar(allocator, std.mem.trim(u8, line[separator_index + 1 ..], " \t"));
        defer allocator.free(value);
        if (key.len == 0 or value.len == 0) return Error.InvalidValue;
        if (std.fs.path.isAbsolute(value)) return Error.InvalidValue;

        if (std.mem.eql(u8, key, "system_prompt_file")) {
            policy.system_prompt_file = try dupeReplacing(allocator, policy.system_prompt_file, value);
        } else if (std.mem.eql(u8, key, "developer_prompt_file")) {
            policy.developer_prompt_file = try dupeReplacing(allocator, policy.developer_prompt_file, value);
        } else {
            return Error.InvalidValue;
        }
    }

    return policy;
}

fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    var escaped = false;

    for (line, 0..) |byte, index| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }

        if (byte == '"') {
            in_string = true;
        } else if (byte == '#') {
            return line[0..index];
        }
    }

    return line;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return Error.InvalidValue;
}

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseUnsigned(T, trimQuotes(value), 10) catch return Error.InvalidValue;
}

fn parseRatioMilli(value: []const u8) !u16 {
    const parsed = try parseUnsigned(u16, value);
    if (parsed > 1000) return Error.InvalidValue;
    return parsed;
}

fn parseFloatRatioMilli(value: []const u8) !u16 {
    const parsed = std.fmt.parseFloat(f64, trimQuotes(value)) catch return Error.InvalidValue;
    if (parsed <= 0 or parsed > 1) return Error.InvalidValue;
    return @intFromFloat(@round(parsed * 1000));
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseTomlStringScalar(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return Error.InvalidValue;

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var index: usize = 1;
    while (index < value.len - 1) : (index += 1) {
        const byte = value[index];
        if (byte == '"') return Error.InvalidValue;
        if (byte != '\\') {
            try output.append(byte);
            continue;
        }

        index += 1;
        if (index >= value.len - 1) return Error.InvalidValue;
        switch (value[index]) {
            '"' => try output.append('"'),
            '\\' => try output.append('\\'),
            'n' => try output.append('\n'),
            'r' => try output.append('\r'),
            't' => try output.append('\t'),
            else => return Error.InvalidValue,
        }
    }

    return output.toOwnedSlice();
}

fn validate(policy: types.ContextPolicy) !void {
    if (policy.context_window_tokens == 0) return Error.InvalidValue;
    if (policy.compact_at_ratio_milli == 0 or policy.compact_at_ratio_milli > 1000) return Error.InvalidValue;
    if (policy.reserve_output_tokens >= policy.context_window_tokens) return Error.InvalidValue;
    if (policy.keep_recent_messages == 0) return Error.InvalidValue;
    if (policy.aggressiveness_milli > 1000) return Error.InvalidValue;
}

fn clonePromptPolicy(allocator: std.mem.Allocator, defaults: types.PromptPolicy) !types.PromptPolicy {
    return .{
        .system_prompt_file = if (defaults.system_prompt_file) |value| try allocator.dupe(u8, value) else null,
        .developer_prompt_file = if (defaults.developer_prompt_file) |value| try allocator.dupe(u8, value) else null,
    };
}

fn dupeReplacing(allocator: std.mem.Allocator, existing: ?[]u8, value: []const u8) ![]u8 {
    if (existing) |previous| allocator.free(previous);
    return allocator.dupe(u8, value);
}

test "settings parse context policy TOML" {
    const policy = try parseContextPolicy(
        \\[context]
        \\auto_compaction = false
        \\manual_compaction = true
        \\context_window_tokens = 128000
        \\compact_at_ratio = 0.75
        \\reserve_output_tokens = 4096
        \\keep_recent_messages = 6
        \\max_entries_per_checkpoint = 2
        \\aggressiveness_milli = 500
        \\retry_on_provider_overflow = false
        \\
    , .{});

    try std.testing.expect(!policy.auto_compaction);
    try std.testing.expect(policy.manual_compaction);
    try std.testing.expectEqual(@as(u64, 128_000), policy.context_window_tokens);
    try std.testing.expectEqual(@as(u16, 750), policy.compact_at_ratio_milli);
    try std.testing.expectEqual(@as(u64, 4_096), policy.reserve_output_tokens);
    try std.testing.expectEqual(@as(usize, 6), policy.keep_recent_messages);
    try std.testing.expectEqual(@as(usize, 2), policy.max_entries_per_checkpoint);
    try std.testing.expectEqual(@as(u16, 500), policy.aggressiveness_milli);
    try std.testing.expect(!policy.retry_on_provider_overflow);
}

test "settings reject unknown context policy keys" {
    try std.testing.expectError(
        Error.InvalidValue,
        parseContextPolicy(
            \\[context]
            \\auto_compact = false
            \\
        , .{}),
    );
}

test "settings parse prompt policy TOML" {
    var policy = try parsePromptPolicy(std.testing.allocator,
        \\[prompts]
        \\system_prompt_file = ".var/prompts/system#main.md" # outside comment
        \\developer_prompt_file = ".var/prompts/developer.md"
        \\
    , .{});
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(".var/prompts/system#main.md", policy.system_prompt_file.?);
    try std.testing.expectEqualStrings(".var/prompts/developer.md", policy.developer_prompt_file.?);
}

test "settings reject unquoted prompt policy strings" {
    try std.testing.expectError(
        Error.InvalidValue,
        parsePromptPolicy(std.testing.allocator,
            \\[prompts]
            \\system_prompt_file = .var/prompts/system.md
            \\
        , .{}),
    );
}

test "settings reject invalid prompt policy keys" {
    try std.testing.expectError(
        Error.InvalidValue,
        parsePromptPolicy(std.testing.allocator,
            \\[prompts]
            \\hidden_guardrail_file = ".var/prompts/guardrail.md"
            \\
        , .{}),
    );
}
