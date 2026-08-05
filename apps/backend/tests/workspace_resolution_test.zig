const std = @import("std");
const VAR1 = @import("VAR1");

const cli = VAR1.clients.cli;

test "workspace candidate predicates reject ancestor-only runtime ledgers" {
    try std.testing.expect(cli.testing_hooks.acceptsConfigMarkerCandidate(true, false, true));
    try std.testing.expect(cli.testing_hooks.acceptsConfigMarkerCandidate(false, true, true));
    try std.testing.expect(!cli.testing_hooks.acceptsConfigMarkerCandidate(false, false, true));
    try std.testing.expect(!cli.testing_hooks.acceptsConfigMarkerCandidate(true, false, false));

    try std.testing.expect(cli.testing_hooks.acceptsSessionsCandidate(true, false));
    try std.testing.expect(cli.testing_hooks.acceptsSessionsCandidate(false, true));
    try std.testing.expect(!cli.testing_hooks.acceptsSessionsCandidate(false, false));
}

test "workspace resolution keeps fresh child directory when parent only has config" {
    const tmp_root = try makeIsolatedTempRoot(std.testing.allocator, "auth-parent");
    defer std.testing.allocator.free(tmp_root);
    defer cleanupIsolatedTempRoot(tmp_root);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    try tmp_dir.makePath("home/.var");
    try tmp_dir.writeFile(.{ .sub_path = "home/.var/config.json", .data = "{}" });
    try tmp_dir.makePath("home/new-project");

    const cwd_abs = try realpathUnder(std.testing.allocator, tmp_root, "home/new-project");
    defer std.testing.allocator.free(cwd_abs);

    const resolved = try cli.testing_hooks.resolveWorkspaceRootForCwd(std.testing.allocator, cwd_abs, null);
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(cwd_abs, resolved);
}

test "workspace resolution keeps fresh child directory when parent only has sessions" {
    const tmp_root = try makeIsolatedTempRoot(std.testing.allocator, "sessions-parent");
    defer std.testing.allocator.free(tmp_root);
    defer cleanupIsolatedTempRoot(tmp_root);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    try tmp_dir.makePath("home/.var/sessions/session-old");
    try tmp_dir.makePath("home/new-project");

    const cwd_abs = try realpathUnder(std.testing.allocator, tmp_root, "home/new-project");
    defer std.testing.allocator.free(cwd_abs);

    const resolved = try cli.testing_hooks.resolveWorkspaceRootForCwd(std.testing.allocator, cwd_abs, null);
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(cwd_abs, resolved);
}

test "workspace resolution accepts current directory config as an explicit local marker" {
    const tmp_root = try makeIsolatedTempRoot(std.testing.allocator, "local-auth");
    defer std.testing.allocator.free(tmp_root);
    defer cleanupIsolatedTempRoot(tmp_root);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    try tmp_dir.makePath("project/.var");
    try tmp_dir.writeFile(.{ .sub_path = "project/.var/config.json", .data = "{}" });

    const cwd_abs = try realpathUnder(std.testing.allocator, tmp_root, "project");
    defer std.testing.allocator.free(cwd_abs);

    const resolved = try cli.testing_hooks.resolveWorkspaceRootForCwd(std.testing.allocator, cwd_abs, null);
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(cwd_abs, resolved);
}

test "workspace resolution climbs to real project marker before installed override" {
    const tmp_root = try makeIsolatedTempRoot(std.testing.allocator, "project-marker");
    defer std.testing.allocator.free(tmp_root);
    defer cleanupIsolatedTempRoot(tmp_root);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    try tmp_dir.makePath("repo/.git");
    try tmp_dir.makePath("repo/src/nested");
    try tmp_dir.makePath("installed");

    const cwd_abs = try realpathUnder(std.testing.allocator, tmp_root, "repo/src/nested");
    defer std.testing.allocator.free(cwd_abs);
    const repo_abs = try realpathUnder(std.testing.allocator, tmp_root, "repo");
    defer std.testing.allocator.free(repo_abs);
    const installed_abs = try realpathUnder(std.testing.allocator, tmp_root, "installed");
    defer std.testing.allocator.free(installed_abs);

    const resolved = try cli.testing_hooks.resolveWorkspaceRootForCwd(std.testing.allocator, cwd_abs, installed_abs);
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(repo_abs, resolved);
}

test "workspace resolution uses installed override only when cwd has no owner" {
    const tmp_root = try makeIsolatedTempRoot(std.testing.allocator, "installed-override");
    defer std.testing.allocator.free(tmp_root);
    defer cleanupIsolatedTempRoot(tmp_root);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_root, .{});
    defer tmp_dir.close();

    try tmp_dir.makePath("plain");
    try tmp_dir.makePath("installed");

    const cwd_abs = try realpathUnder(std.testing.allocator, tmp_root, "plain");
    defer std.testing.allocator.free(cwd_abs);
    const installed_abs = try realpathUnder(std.testing.allocator, tmp_root, "installed");
    defer std.testing.allocator.free(installed_abs);

    const resolved = try cli.testing_hooks.resolveWorkspaceRootForCwd(std.testing.allocator, cwd_abs, installed_abs);
    defer std.testing.allocator.free(resolved);

    try std.testing.expectEqualStrings(installed_abs, resolved);
}

fn makeIsolatedTempRoot(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const temp = std.process.getEnvVarOwned(allocator, "TEMP") catch try std.process.getEnvVarOwned(allocator, "TMP");
    defer allocator.free(temp);

    const root = try std.fmt.allocPrint(allocator, "{s}{c}vantari-workspace-resolution-{s}-{d}", .{
        temp,
        std.fs.path.sep,
        name,
        std.time.nanoTimestamp(),
    });
    defer allocator.free(root);

    try std.fs.makeDirAbsolute(root);
    return std.fs.cwd().realpathAlloc(allocator, root);
}

fn cleanupIsolatedTempRoot(root: []const u8) void {
    const parent = std.fs.path.dirname(root) orelse return;
    const child = std.fs.path.basename(root);
    var parent_dir = std.fs.openDirAbsolute(parent, .{}) catch return;
    defer parent_dir.close();
    parent_dir.deleteTree(child) catch {};
}

fn realpathUnder(allocator: std.mem.Allocator, root: []const u8, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, sub_path });
    defer allocator.free(path);
    return std.fs.cwd().realpathAlloc(allocator, path);
}
