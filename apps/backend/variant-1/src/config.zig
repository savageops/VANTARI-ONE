const std = @import("std");
const fsutil = @import("fsutil.zig");
const types = @import("types.zig");

// TODO: Replace the manual env parsing with a fuller parser only if the simple `.env` contract becomes insufficient.

pub const Error = error{
    MissingKey,
    InvalidValue,
};

pub fn loadFromEnvFile(allocator: std.mem.Allocator, env_path: []const u8) !types.Config {
    const content = try std.fs.cwd().readFileAlloc(allocator, env_path, 1024 * 1024);
    defer allocator.free(content);

    var openai_base_url: ?[]u8 = null;
    var openai_api_key: ?[]u8 = null;
    var openai_model: ?[]u8 = null;
    var workspace_root: ?[]u8 = null;
    var harness_max_steps: usize = 1;

    errdefer if (openai_base_url) |value| allocator.free(value);
    errdefer if (openai_api_key) |value| allocator.free(value);
    errdefer if (openai_model) |value| allocator.free(value);
    errdefer if (workspace_root) |value| allocator.free(value);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) {
            line = std.mem.trim(u8, line["export ".len..], " \t");
        }

        const separator_index = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator_index], " \t");
        var value = std.mem.trim(u8, line[separator_index + 1 ..], " \t");
        value = trimQuotes(value);

        if (std.mem.eql(u8, key, "OPENAI_BASE_URL")) {
            openai_base_url = try dupeReplacing(allocator, openai_base_url, value);
        } else if (std.mem.eql(u8, key, "OPENAI_API_KEY")) {
            openai_api_key = try dupeReplacing(allocator, openai_api_key, value);
        } else if (std.mem.eql(u8, key, "OPENAI_MODEL")) {
            openai_model = try dupeReplacing(allocator, openai_model, value);
        } else if (std.mem.eql(u8, key, "HARNESS_WORKSPACE")) {
            workspace_root = try dupeReplacing(allocator, workspace_root, value);
        } else if (std.mem.eql(u8, key, "HARNESS_MAX_STEPS")) {
            harness_max_steps = std.fmt.parseInt(usize, value, 10) catch return Error.InvalidValue;
        }
    }

    return .{
        .openai_base_url = openai_base_url orelse return Error.MissingKey,
        .openai_api_key = openai_api_key orelse return Error.MissingKey,
        .openai_model = openai_model orelse return Error.MissingKey,
        .harness_max_steps = harness_max_steps,
        .workspace_root = workspace_root orelse try allocator.dupe(u8, "."),
    };
}

pub fn loadDefault(allocator: std.mem.Allocator, workspace_root: []const u8) !types.Config {
    const env_path = try std.fs.path.join(allocator, &.{ workspace_root, ".env" });
    defer allocator.free(env_path);

    var config = try loadFromEnvFile(allocator, env_path);

    const canonical_workspace_root = try canonicalizeWorkspaceRoot(
        allocator,
        workspace_root,
        config.workspace_root,
    );
    allocator.free(config.workspace_root);
    config.workspace_root = canonical_workspace_root;
    return config;
}

fn canonicalizeWorkspaceRoot(
    allocator: std.mem.Allocator,
    invocation_root: []const u8,
    configured_root: []const u8,
) ![]u8 {
    const invocation_abs = try fsutil.resolveAbsolute(allocator, invocation_root);
    defer allocator.free(invocation_abs);

    const anchored_root = if (std.fs.path.isAbsolute(configured_root))
        try allocator.dupe(u8, configured_root)
    else
        try std.fs.path.resolve(allocator, &.{ invocation_abs, configured_root });
    defer allocator.free(anchored_root);

    return std.fs.realpathAlloc(allocator, anchored_root);
}

fn trimQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn dupeReplacing(allocator: std.mem.Allocator, existing: ?[]u8, value: []const u8) ![]u8 {
    if (existing) |previous| allocator.free(previous);
    return allocator.dupe(u8, value);
}
