const builtin = @import("builtin");
const std = @import("std");

const retry_ns = 10 * std.time.ns_per_ms;

/// One process-owned exclusive byte-range lock. The operating system releases
/// ownership when the process exits; the file remains only as a stable anchor.
pub const FileLock = struct {
    file: std.fs.File,

    pub fn deinit(self: *FileLock) void {
        self.file.unlock();
        self.file.close();
        self.* = undefined;
    }
};

pub fn acquire(path: []const u8, timeout_ms: usize) !FileLock {
    if (std.fs.path.dirname(path)) |parent| try std.fs.cwd().makePath(parent);
    var file = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = false,
    });
    errdefer file.close();

    var timer = try std.time.Timer.start();
    const timeout_ns = std.math.mul(u64, @intCast(timeout_ms), std.time.ns_per_ms) catch std.math.maxInt(u64);
    while (!try tryExclusive(file)) {
        if (timer.read() >= timeout_ns) return error.LockUnavailable;
        std.Thread.sleep(retry_ns);
    }
    return .{ .file = file };
}

/// Zig 0.15.1's Windows `File.tryLock` has a malformed `.none` return arm.
/// Call the same one-byte operating-system primitive directly on Windows.
fn tryExclusive(file: std.fs.File) !bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const range_off: windows.LARGE_INTEGER = 0;
        const range_len: windows.LARGE_INTEGER = 1;
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        windows.LockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &range_off,
            &range_len,
            null,
            windows.TRUE,
            windows.TRUE,
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        return true;
    }
    return file.tryLock(.exclusive);
}

test "process lock excludes a second owner and releases cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/process.lock",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(path);

    var first = try acquire(path, 0);
    try std.testing.expectError(error.LockUnavailable, acquire(path, 0));
    first.deinit();

    var successor = try acquire(path, 0);
    successor.deinit();
}
