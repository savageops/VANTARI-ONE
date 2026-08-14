const builtin = @import("builtin");
const std = @import("std");
const fsutil = @import("../shared/fsutil.zig");
const process_lock = @import("../shared/process_lock.zig");

pub const schema_version = "var1.execution_owner.v1";
pub const protocol_version = "var1.owner_http.v1";
pub const state_filename = "execution-owner.json";
pub const start_lock_filename = "execution-owner-start.lock";
pub const lease_filename = "execution-owner-lease.lock";

pub const Projection = struct {
    type: []const u8 = schema_version,
    protocol: []const u8 = protocol_version,
    generation: []const u8,
    pid: u32,
    port: u16,
    token: []const u8,
    workspace_root: []const u8,
    executable_path: []const u8,
    started_at_ms: i64,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    generation: []u8,
    pid: u32,
    port: u16,
    token: []u8,
    workspace_root: []u8,
    executable_path: []u8,
    started_at_ms: i64,

    pub fn deinit(self: Snapshot) void {
        self.allocator.free(self.generation);
        self.allocator.free(self.token);
        self.allocator.free(self.workspace_root);
        self.allocator.free(self.executable_path);
    }
};

pub const Identity = struct {
    generation: []const u8,
    pid: u32,
    port: u16,
    token: []const u8,
    workspace_root: []const u8,
};

/// Return the project-local execution-owner projection path. Owner state never
/// relocates into a home-scoped runtime root.
pub fn statePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "runtime", state_filename });
}

/// Return the project-local file used to serialize owner startup decisions.
pub fn startLockPath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "runtime", start_lock_filename });
}

/// Return the project-local owner lifetime lease path. The operating system
/// releases this lock on crash; the file itself is only an identity anchor.
pub fn leasePath(allocator: std.mem.Allocator, workspace_root: []const u8) ![]u8 {
    return fsutil.join(allocator, &.{ workspace_root, ".var", "runtime", lease_filename });
}

pub const FileLock = process_lock.FileLock;

pub fn acquireStartLock(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    timeout_ms: usize,
) !FileLock {
    const path = try startLockPath(allocator, workspace_root);
    defer allocator.free(path);
    return acquireFileLock(path, timeout_ms);
}

pub fn acquireOwnerLease(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    timeout_ms: usize,
) !FileLock {
    const path = try leasePath(allocator, workspace_root);
    defer allocator.free(path);
    return acquireFileLock(path, timeout_ms);
}

/// Return true only when no owner process currently holds the lifetime lease.
pub fn ownerLeaseAvailable(allocator: std.mem.Allocator, workspace_root: []const u8) !bool {
    var lease = acquireOwnerLease(allocator, workspace_root, 0) catch |err| switch (err) {
        error.OwnerLockUnavailable => return false,
        else => return err,
    };
    lease.deinit();
    return true;
}

fn acquireFileLock(path: []const u8, timeout_ms: usize) !FileLock {
    return process_lock.acquire(path, timeout_ms) catch |err| switch (err) {
        error.LockUnavailable => error.OwnerLockUnavailable,
        else => err,
    };
}

/// Atomically publish a ready execution owner. Call only after the listener and
/// child kernel have completed a real health handshake.
pub fn write(allocator: std.mem.Allocator, projection: Projection) !void {
    const path = try statePath(allocator, projection.workspace_root);
    defer allocator.free(path);

    const payload = try std.fmt.allocPrint(allocator, "{f}\n", .{
        std.json.fmt(projection, .{}),
    });
    defer allocator.free(payload);
    try fsutil.writeText(path, payload);
}

/// Remove the projection only when it still identifies this exact owner.
/// Crash-stale or replaced projections remain available for fail-closed
/// diagnosis; a clean owner cannot erase a newer generation.
pub fn removeIfCurrent(allocator: std.mem.Allocator, identity: Identity) !bool {
    const path = try statePath(allocator, identity.workspace_root);
    defer allocator.free(path);

    var snapshot = read(allocator, identity.workspace_root) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    defer snapshot.deinit();

    if (!std.mem.eql(u8, snapshot.generation, identity.generation) or
        snapshot.pid != identity.pid or
        snapshot.port != identity.port or
        !std.mem.eql(u8, snapshot.token, identity.token) or
        !std.mem.eql(u8, snapshot.workspace_root, identity.workspace_root))
    {
        return false;
    }

    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

/// Read and validate one owner projection. Schema or protocol drift fails
/// closed so clients never attach to a transport with unknown semantics.
pub fn read(allocator: std.mem.Allocator, workspace_root: []const u8) !Snapshot {
    const path = try statePath(allocator, workspace_root);
    defer allocator.free(path);
    const payload = try fsutil.readTextAlloc(allocator, path);
    defer allocator.free(payload);

    var parsed = std.json.parseFromSlice(Projection, allocator, payload, .{}) catch {
        return error.InvalidOwnerProjection;
    };
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.type, schema_version) or
        !std.mem.eql(u8, parsed.value.protocol, protocol_version) or
        parsed.value.generation.len == 0 or
        parsed.value.token.len == 0 or
        parsed.value.port == 0 or
        !std.mem.eql(u8, parsed.value.workspace_root, workspace_root))
    {
        return error.InvalidOwnerProjection;
    }

    const generation = try allocator.dupe(u8, parsed.value.generation);
    errdefer allocator.free(generation);
    const token = try allocator.dupe(u8, parsed.value.token);
    errdefer allocator.free(token);
    const owned_workspace = try allocator.dupe(u8, parsed.value.workspace_root);
    errdefer allocator.free(owned_workspace);
    const executable_path = try allocator.dupe(u8, parsed.value.executable_path);
    errdefer allocator.free(executable_path);

    return .{
        .allocator = allocator,
        .generation = generation,
        .pid = parsed.value.pid,
        .port = parsed.value.port,
        .token = token,
        .workspace_root = owned_workspace,
        .executable_path = executable_path,
        .started_at_ms = parsed.value.started_at_ms,
    };
}

// Rationale: the owner projection needs the current process identity for
// generation-bound lifecycle checks on every non-Windows host.
// Decision: use Zig's POSIX system namespace, whose 0.15.x API exposes the
// platform `getpid` primitive without a second process-identity abstraction.
// Source: Zig 0.15.1 `std/posix.zig` maps `system` to the host POSIX layer;
// `std/os/linux.zig` and `std/c.zig` both own `getpid` for their ABI paths.
// Reference: https://ziglang.org/documentation/0.15.1/std/#std.posix.system
// Proof: `zig build -Doptimize=ReleaseFast` must compile this owner path and
// the existing owner lifecycle tests exercise the resulting projection.
pub fn currentPid() u32 {
    return if (builtin.os.tag == .windows)
        std.os.windows.GetCurrentProcessId()
    else
        @intCast(std.posix.system.getpid());
}

test "owner projection stays project local and round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(workspace_root);

    const path = try statePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, ".var/runtime/" ++ state_filename) or
        std.mem.endsWith(u8, path, ".var\\runtime\\" ++ state_filename));

    try write(std.testing.allocator, .{
        .generation = "generation-a",
        .pid = 42,
        .port = 4311,
        .token = "owner-token-a",
        .workspace_root = workspace_root,
        .executable_path = "E:/bin/vantari.exe",
        .started_at_ms = 100,
    });

    const snapshot = try read(std.testing.allocator, workspace_root);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("generation-a", snapshot.generation);
    try std.testing.expectEqual(@as(u32, 42), snapshot.pid);
    try std.testing.expectEqual(@as(u16, 4311), snapshot.port);
    try std.testing.expectEqualStrings("owner-token-a", snapshot.token);
    try std.testing.expectEqualStrings(workspace_root, snapshot.workspace_root);
}

test "owner projection replacement is atomic and latest generation wins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(workspace_root);

    try write(std.testing.allocator, .{
        .generation = "generation-old",
        .pid = 1,
        .port = 4311,
        .token = "token-old",
        .workspace_root = workspace_root,
        .executable_path = "old.exe",
        .started_at_ms = 1,
    });
    try write(std.testing.allocator, .{
        .generation = "generation-new",
        .pid = 2,
        .port = 4312,
        .token = "token-new",
        .workspace_root = workspace_root,
        .executable_path = "new.exe",
        .started_at_ms = 2,
    });

    const snapshot = try read(std.testing.allocator, workspace_root);
    defer snapshot.deinit();
    try std.testing.expectEqualStrings("generation-new", snapshot.generation);
    try std.testing.expectEqual(@as(u32, 2), snapshot.pid);
    try std.testing.expectEqual(@as(u16, 4312), snapshot.port);
}

test "owner projection rejects protocol drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(workspace_root);
    const path = try statePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(path);

    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"type\":\"{s}\",\"protocol\":\"future\",\"generation\":\"g\",\"pid\":1,\"port\":4311,\"token\":\"t\",\"workspace_root\":{f},\"executable_path\":\"v.exe\",\"started_at_ms\":1}}",
        .{ schema_version, std.json.fmt(workspace_root, .{}) },
    );
    defer std.testing.allocator.free(payload);
    try fsutil.writeText(path, payload);
    try std.testing.expectError(error.InvalidOwnerProjection, read(std.testing.allocator, workspace_root));
}

test "owner projection removes only the matching generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(workspace_root);
    const path = try statePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(path);

    try write(std.testing.allocator, .{
        .generation = "generation-current",
        .pid = 42,
        .port = 4311,
        .token = "owner-token-current",
        .workspace_root = workspace_root,
        .executable_path = "E:/bin/vantari.exe",
        .started_at_ms = 100,
    });

    try std.testing.expect(!try removeIfCurrent(std.testing.allocator, .{
        .generation = "generation-old",
        .pid = 42,
        .port = 4311,
        .token = "owner-token-current",
        .workspace_root = workspace_root,
    }));
    try std.testing.expect(fsutil.fileExists(path));
    try std.testing.expect(try removeIfCurrent(std.testing.allocator, .{
        .generation = "generation-current",
        .pid = 42,
        .port = 4311,
        .token = "owner-token-current",
        .workspace_root = workspace_root,
    }));
    try std.testing.expect(!fsutil.fileExists(path));
}
