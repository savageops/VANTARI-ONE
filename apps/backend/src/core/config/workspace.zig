const std = @import("std");
const config_file = @import("file.zig");

/// Resolve the one workspace root used by runtime state, configuration, and the
/// persistent execution owner. Invocation-local markers outrank the installed
/// workspace override so running VANTARI inside a project remains predictable.
pub fn resolve(allocator: std.mem.Allocator) ![]u8 {
    const env_workspace_maybe = std.process.getEnvVarOwned(allocator, "VANTARI_WORKSPACE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (env_workspace_maybe) |env_workspace| {
        defer allocator.free(env_workspace);
        return std.fs.cwd().realpathAlloc(allocator, env_workspace);
    }

    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd_abs);

    var runtime_policy = try config_file.loadRuntimePolicy(allocator, cwd_abs);
    defer runtime_policy.deinit(allocator);
    if (runtime_policy.workspace) |configured_workspace| {
        return std.fs.cwd().realpathAlloc(allocator, configured_workspace);
    }

    const installed_workspace_root = try readInstalledRoot(allocator);
    defer if (installed_workspace_root) |value| allocator.free(value);
    return resolveFromCwd(allocator, cwd_abs, installed_workspace_root);
}

pub fn resolveFromCwd(
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    installed_workspace_root: ?[]const u8,
) ![]u8 {
    var fallback_sessions_root: ?[]u8 = null;
    errdefer if (fallback_sessions_root) |value| allocator.free(value);

    var current = try allocator.dupe(u8, cwd_abs);
    defer allocator.free(current);

    while (true) {
        const is_invocation_root = std.mem.eql(u8, current, cwd_abs);
        const has_project_marker = try hasProjectMarker(allocator, current);
        const has_config_marker = try hasConfigMarker(allocator, current);
        if (acceptsConfigMarkerCandidate(is_invocation_root, has_project_marker, has_config_marker)) {
            return allocator.dupe(u8, current);
        }
        if (fallback_sessions_root == null and acceptsSessionsCandidate(is_invocation_root, has_project_marker) and try hasSessions(allocator, current)) {
            fallback_sessions_root = try allocator.dupe(u8, current);
        }
        if (has_project_marker) return allocator.dupe(u8, current);

        const backend_candidate = try std.fs.path.join(allocator, &.{ current, "apps", "backend" });
        defer allocator.free(backend_candidate);
        if (try hasConfigMarker(allocator, backend_candidate)) return allocator.dupe(u8, backend_candidate);
        if (fallback_sessions_root == null and try hasSessions(allocator, backend_candidate)) {
            fallback_sessions_root = try allocator.dupe(u8, backend_candidate);
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    if (fallback_sessions_root) |value| {
        fallback_sessions_root = null;
        return value;
    }
    if (installed_workspace_root) |installed_workspace| return allocator.dupe(u8, installed_workspace);
    return allocator.dupe(u8, cwd_abs);
}

pub fn acceptsConfigMarkerCandidate(is_invocation_root: bool, has_project_marker: bool, has_config_marker: bool) bool {
    return has_config_marker and (is_invocation_root or has_project_marker);
}

pub fn acceptsSessionsCandidate(is_invocation_root: bool, has_project_marker: bool) bool {
    return is_invocation_root or has_project_marker;
}

pub fn installedFilePath(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.InvalidArgs;
    return std.fs.path.join(allocator, &.{ exe_dir, "workspace.txt" });
}

fn readInstalledRoot(allocator: std.mem.Allocator) !?[]u8 {
    const workspace_file = try installedFilePath(allocator);
    defer allocator.free(workspace_file);
    if (!exists(workspace_file)) return null;

    const raw = std.fs.openFileAbsolute(workspace_file, .{}) catch return null;
    defer raw.close();
    const content = try raw.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);
    const workspace_root = std.mem.trim(u8, content, " \t\r\n");
    if (workspace_root.len == 0) return null;
    if (try hasConfigMarker(allocator, workspace_root) or try hasSessions(allocator, workspace_root)) {
        const resolved = try allocator.dupe(u8, workspace_root);
        return resolved;
    }
    return null;
}

fn hasConfigMarker(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const env_path = try std.fs.path.join(allocator, &.{ workspace_root, ".env" });
    defer allocator.free(env_path);
    if (exists(env_path)) return true;

    const config_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "config.json" });
    defer allocator.free(config_path);
    return exists(config_path);
}

fn hasSessions(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const sessions_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "sessions" });
    defer allocator.free(sessions_path);
    if (!exists(sessions_path)) return false;

    var dir = std.fs.openDirAbsolute(sessions_path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) return true;
    }
    return false;
}

fn hasProjectMarker(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    const agents_path = try std.fs.path.join(allocator, &.{ workspace_root, "AGENTS.md" });
    defer allocator.free(agents_path);
    if (exists(agents_path)) return true;

    const git_path = try std.fs.path.join(allocator, &.{ workspace_root, ".git" });
    defer allocator.free(git_path);
    return exists(git_path);
}

fn exists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}
