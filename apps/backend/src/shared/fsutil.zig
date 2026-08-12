const builtin = @import("builtin");
const std = @import("std");
const jsonl = @import("jsonl.zig");

pub const max_text_file_bytes: usize = 64 * 1024 * 1024;

pub const PathError = error{
    PathOutsideWorkspace,
};

pub const RuntimeError = error{
    RuntimeRootNotFound,
    TestRuntimePathOutsideRoot,
};

const test_runtime_root_env = "VANTARI_TEST_ROOT";

pub fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn ensureParent(path: []const u8) !void {
    const dir_name = std.fs.path.dirname(path) orelse return;
    if (dir_name.len == 0) return;
    try std.fs.cwd().makePath(dir_name);
}

pub fn writeText(path: []const u8, text: []const u8) !void {
    try ensureParent(path);

    var buffer: [4096]u8 = undefined;
    var file = try std.fs.cwd().atomicFile(path, .{
        .write_buffer = &buffer,
    });
    defer file.deinit();

    try file.file_writer.interface.writeAll(text);
    try file.finish();
}

pub fn appendText(path: []const u8, text: []const u8) !void {
    try ensureParent(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = false,
        }),
        else => return err,
    };
    defer file.close();

    const end_position = try file.getEndPos();
    try file.pwriteAll(text, end_position);
}

/// Append one JSONL record without allowing a torn suffix to absorb it. The
/// caller chooses whether this append is the durability boundary.
pub fn appendJsonlRecord(path: []const u8, record: []const u8, sync: bool) !void {
    if (record.len == 0) return;
    try ensureParent(path);

    var file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    defer file.close();

    var end_position = try file.getEndPos();
    try requireValidJsonlTail(&file, end_position);
    if (end_position > 0) {
        var tail: [1]u8 = undefined;
        if (try file.preadAll(tail[0..], end_position - 1) == 1 and tail[0] != '\n') {
            try file.pwriteAll("\n", end_position);
            end_position += 1;
        }
    }
    try file.pwriteAll(record, end_position);
    if (record[record.len - 1] != '\n') try file.pwriteAll("\n", end_position + record.len);
    if (sync) try file.sync();
}

/// Validate a bounded suffix ending on the current tail record. Healthy files
/// read one small window; a long final record expands only to its LF boundary.
fn requireValidJsonlTail(file: *std.fs.File, end_position: u64) !void {
    if (end_position == 0) return;

    var window_bytes: u64 = @min(end_position, 4 * 1024);
    while (true) {
        const start_position = end_position - window_bytes;
        const tail_len = std.math.cast(usize, window_bytes) orelse return error.JsonlTailTooLarge;
        const tail = try std.heap.page_allocator.alloc(u8, tail_len);
        defer std.heap.page_allocator.free(tail);
        const read_count = try file.preadAll(tail, start_position);
        var first_complete: usize = 0;
        if (start_position > 0) {
            first_complete = if (std.mem.indexOfScalar(u8, tail[0..read_count], '\n')) |boundary|
                boundary + 1
            else if (window_bytes == end_position or window_bytes >= max_text_file_bytes)
                return error.JsonlTailTooLarge
            else {
                window_bytes = @min(end_position, window_bytes * 2);
                continue;
            };
        }

        var reader = jsonl.PrefixReader.init(std.heap.page_allocator, tail[first_complete..read_count]);
        while (try reader.next()) |_| reader.accept();
        if (reader.issue != null) return error.PoisonedJsonlSuffix;
        return;
    }
}

pub fn readTextAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, path, max_text_file_bytes);
}

pub fn moveFile(old_path: []const u8, new_path: []const u8) !void {
    try ensureParent(new_path);
    try std.fs.cwd().rename(old_path, new_path);
}

test "appendJsonlRecord rejects a torn suffix without hiding later records" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/append-jsonl.jsonl", .{tmp.sub_path});
    defer allocator.free(path);

    try appendText(path, "torn");
    try std.testing.expectError(error.PoisonedJsonlSuffix, appendJsonlRecord(path, "{\"seq\":1}", false));

    const content = try readTextAlloc(allocator, path);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("torn", content);
}

pub fn resolveAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(allocator, &.{path});
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    return std.fs.path.resolve(allocator, &.{ cwd, path });
}

pub fn resolveInWorkspace(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
) ![]u8 {
    const root_abs = try resolveAbsolute(allocator, workspace_root);
    defer allocator.free(root_abs);

    const target_abs = if (std.fs.path.isAbsolute(requested_path))
        try resolveAbsolute(allocator, requested_path)
    else
        try std.fs.path.resolve(allocator, &.{ root_abs, requested_path });

    if (!isWithinPath(root_abs, target_abs)) {
        allocator.free(target_abs);
        return PathError.PathOutsideWorkspace;
    }

    return target_abs;
}

/// Resolve an agent-facing path under the configured access mode.
///
/// Restricted mode preserves the workspace containment contract. Full access
/// mode keeps relative paths anchored at the workspace root, but permits
/// traversal and absolute paths so an agent can work in a sibling checkout or
/// another explicitly selected directory.
pub fn resolveWithAccessMode(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    requested_path: []const u8,
    full_access_mode: bool,
) ![]u8 {
    if (!full_access_mode) return resolveInWorkspace(allocator, workspace_root, requested_path);

    if (std.fs.path.isAbsolute(requested_path)) {
        return resolveAbsolute(allocator, requested_path);
    }

    const root_abs = try resolveAbsolute(allocator, workspace_root);
    defer allocator.free(root_abs);
    return std.fs.path.resolve(allocator, &.{ root_abs, requested_path });
}

fn isWithinPath(root: []const u8, target: []const u8) bool {
    if (target.len < root.len) return false;
    if (!pathPrefixEqual(root, target[0..root.len])) return false;
    if (target.len == root.len) return true;

    return root[root.len - 1] == std.fs.path.sep or target[root.len] == std.fs.path.sep;
}

fn pathPrefixEqual(left: []const u8, right: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(left, right);
    return std.mem.eql(u8, left, right);
}

fn ensurePathWithinRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    candidate: []const u8,
) !void {
    const root_abs = try resolveAbsolute(allocator, root);
    defer allocator.free(root_abs);
    const candidate_abs = try resolveAbsolute(allocator, candidate);
    defer allocator.free(candidate_abs);

    if (!isWithinPath(root_abs, candidate_abs)) {
        return RuntimeError.TestRuntimePathOutsideRoot;
    }
}

fn ensureTestRuntimePath(allocator: std.mem.Allocator, candidate: []const u8) !void {
    if (!builtin.is_test) return;
    const test_root = std.process.getEnvVarOwned(allocator, test_runtime_root_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(test_root);
    try ensurePathWithinRoot(allocator, test_root, candidate);
}

fn acceptRuntimeRoot(allocator: std.mem.Allocator, path: []u8) ![]u8 {
    errdefer allocator.free(path);
    try ensureTestRuntimePath(allocator, path);
    ensureDirExists(path) catch {};
    return path;
}

/// Resolve the runtime root for Vantari state (sessions, auth, config, loops,
/// schedules, personas). This replaces the workspace-anchored `.var/`.
///
/// Resolution order:
/// 1. `$VANTARI_HOME` (explicit override — production sets this to ~/.vantari)
/// 2. `$HOME/.vantari` (Linux/macOS/Windows with HOME)
/// 3. `%USERPROFILE%\.vantari` (Windows native)
/// 4. Fallback: `$LOCALAPPDATA/Vantari` (Windows)
///
/// The directory is created if it does not exist. For test isolation, tests
/// pass their tmp dir as workspace_root and the path functions use it directly
/// (not runtimeRoot) — see runtimeRootForWorkspace below.
pub fn runtimeRoot(allocator: std.mem.Allocator) ![]u8 {
    // 1. Explicit override
    if (std.process.getEnvVarOwned(allocator, "VANTARI_HOME")) |env_path| {
        return acceptRuntimeRoot(allocator, env_path);
    } else |_| {}

    // 2. HOME/.vantari (works on Linux, macOS, and Windows with HOME set)
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const path = try std.fs.path.join(allocator, &.{ home, ".vantari" });
        return acceptRuntimeRoot(allocator, path);
    } else |_| {}

    // 3. USERPROFILE\.vantari (Windows native)
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |profile| {
        defer allocator.free(profile);
        const path = try std.fs.path.join(allocator, &.{ profile, ".vantari" });
        return acceptRuntimeRoot(allocator, path);
    } else |_| {}

    // 4. LOCALAPPDATA/Vantari (Windows fallback)
    if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |local| {
        defer allocator.free(local);
        const path = try std.fs.path.join(allocator, &.{ local, "Vantari" });
        return acceptRuntimeRoot(allocator, path);
    } else |_| {}

    return error.RuntimeRootNotFound;
}

/// Resolve the runtime root for a given workspace context.
///
/// Resolution order:
/// 1. Test build: `workspace_root + ".var"` under `$VANTARI_TEST_ROOT`
/// 2. `$VANTARI_HOME` (production sets this to `~/.vantari`)
/// 3. `workspace_root + ".var"` (backward compatibility)
///
/// Production sets `VANTARI_HOME=$HOME/.vantari` (or `%USERPROFILE%\.vantari`)
/// via the install script. The build graph gives each test artifact a generated
/// home and constrains fixture state to Zig's cache root. Production does not
/// set `VANTARI_TEST_ROOT`, so its precedence is unchanged.
pub fn runtimeRootForWorkspace(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    // Test runs keep each workspace fixture isolated under Zig's generated
    // cache root. VANTARI_HOME remains available for global-state tests.
    if (builtin.is_test and std.process.hasEnvVarConstant(test_runtime_root_env)) {
        const local = try std.fs.path.join(allocator, &.{ workspace_root, ".var" });
        errdefer allocator.free(local);
        try ensureTestRuntimePath(allocator, local);
        ensureDirExists(local) catch {};
        return local;
    }

    // 1. Explicit env override (production)
    if (std.process.getEnvVarOwned(allocator, "VANTARI_HOME")) |env_path| {
        return acceptRuntimeRoot(allocator, env_path);
    } else |_| {}

    // 2. Workspace-local .var (backward compatible with existing tests)
    const local = try std.fs.path.join(allocator, &.{ workspace_root, ".var" });
    ensureDirExists(local) catch {};
    return local;
}

/// Resolve a subdirectory under the runtime root (e.g. "sessions", "auth",
/// "loops"). Creates the subdirectory if it does not exist.
pub fn runtimePath(allocator: std.mem.Allocator, subsystem: []const u8) ![]u8 {
    const root = try runtimeRoot(allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, subsystem });
    ensureDirExists(path) catch {};
    return path;
}

/// Resolve a file under a subsystem directory in the runtime root.
/// Example: runtimeFilePath(allocator, "auth", "auth.json")
pub fn runtimeFilePath(allocator: std.mem.Allocator, subsystem: []const u8, filename: []const u8) ![]u8 {
    const root = try runtimeRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, subsystem, filename });
}

fn ensureDirExists(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch {};
}

test "runtimeRoot returns a valid path" {
    const root = try runtimeRoot(std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expect(root.len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(root));
}

test "resolveWithAccessMode keeps containment unless full access is explicit" {
    const workspace = try resolveAbsolute(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);
    const outside = try std.fs.path.resolve(std.testing.allocator, &.{ workspace, "..", "vantari-full-access-probe" });
    defer std.testing.allocator.free(outside);

    try std.testing.expectError(
        PathError.PathOutsideWorkspace,
        resolveWithAccessMode(std.testing.allocator, workspace, outside, false),
    );
    const resolved = try resolveWithAccessMode(std.testing.allocator, workspace, outside, true);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(outside, resolved);
}

test "test runtime guard rejects paths outside its generated root" {
    const root = try resolveAbsolute(std.testing.allocator, ".zig-cache/vantari-test-guard");
    defer std.testing.allocator.free(root);
    const inside = try std.fs.path.join(std.testing.allocator, &.{ root, "integration", ".var" });
    defer std.testing.allocator.free(inside);
    const outside = try std.fs.path.resolve(std.testing.allocator, &.{ root, "..", "operator-home" });
    defer std.testing.allocator.free(outside);

    try ensurePathWithinRoot(std.testing.allocator, root, inside);
    try std.testing.expectError(
        RuntimeError.TestRuntimePathOutsideRoot,
        ensurePathWithinRoot(std.testing.allocator, root, outside),
    );
}
