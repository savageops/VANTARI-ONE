const std = @import("std");
const builtin = @import("builtin");

const win = std.os.windows;

extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*win.SECURITY_ATTRIBUTES, lpName: ?win.LPCWSTR) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SetInformationJobObject(
    hJob: win.HANDLE,
    JobObjectInfoClass: win.DWORD,
    lpJobObjectInfo: *anyopaque,
    cbJobObjectInfoLength: win.DWORD,
) callconv(.winapi) win.BOOL;
extern "kernel32" fn AssignProcessToJobObject(hJob: win.HANDLE, hProcess: win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn TerminateJobObject(hJob: win.HANDLE, uExitCode: win.UINT) callconv(.winapi) win.BOOL;
extern "kernel32" fn CancelSynchronousIo(hThread: win.HANDLE) callconv(.winapi) win.BOOL;

const job_object_extended_limit_information: win.DWORD = 9;
const job_object_limit_kill_on_close: win.DWORD = 0x2000;

const IoCounters = extern struct {
    read_operation_count: win.ULONGLONG,
    write_operation_count: win.ULONGLONG,
    other_operation_count: win.ULONGLONG,
    read_transfer_count: win.ULONGLONG,
    write_transfer_count: win.ULONGLONG,
    other_transfer_count: win.ULONGLONG,
};

const BasicLimitInformation = extern struct {
    per_process_user_time_limit: win.LARGE_INTEGER,
    per_job_user_time_limit: win.LARGE_INTEGER,
    limit_flags: win.DWORD,
    minimum_working_set_size: win.SIZE_T,
    maximum_working_set_size: win.SIZE_T,
    active_process_limit: win.DWORD,
    affinity: win.ULONG_PTR,
    priority_class: win.DWORD,
    scheduling_class: win.DWORD,
};

const ExtendedLimitInformation = extern struct {
    basic_limit_information: BasicLimitInformation,
    io_info: IoCounters,
    process_memory_limit: win.SIZE_T,
    job_memory_limit: win.SIZE_T,
    peak_process_memory_used: win.SIZE_T,
    peak_job_memory_used: win.SIZE_T,
};

/// Owns one Windows Job Object with kill-on-close semantics. On non-Windows
/// targets it is a zero-cost no-op so callers retain one process-tree contract.
pub const KillOnCloseJob = struct {
    handle: ?win.HANDLE = null,

    pub fn init() !KillOnCloseJob {
        if (builtin.os.tag != .windows) return .{};
        const handle = CreateJobObjectW(null, null) orelse return error.JobObjectCreateFailed;
        errdefer _ = win.CloseHandle(handle);

        var info = std.mem.zeroes(ExtendedLimitInformation);
        info.basic_limit_information.limit_flags = job_object_limit_kill_on_close;
        if (SetInformationJobObject(
            handle,
            job_object_extended_limit_information,
            @ptrCast(&info),
            @sizeOf(ExtendedLimitInformation),
        ) == 0) return error.JobObjectSetInfoFailed;
        return .{ .handle = handle };
    }

    pub fn assign(self: KillOnCloseJob, process_handle: std.process.Child.Id) !void {
        if (builtin.os.tag != .windows) return;
        const handle = self.handle orelse return error.JobObjectUnavailable;
        if (AssignProcessToJobObject(handle, process_handle) == 0) return error.JobObjectAssignFailed;
    }

    pub fn terminate(self: KillOnCloseJob, process_handle: std.process.Child.Id, exit_code: u32) void {
        if (builtin.os.tag != .windows) return;
        if (self.handle) |handle| _ = TerminateJobObject(handle, exit_code);
        win.TerminateProcess(process_handle, exit_code) catch {};
    }

    pub fn deinit(self: *KillOnCloseJob) void {
        if (builtin.os.tag == .windows) {
            if (self.handle) |handle| _ = win.CloseHandle(handle);
        }
        self.handle = null;
    }
};

pub fn waitForProcess(process_handle: std.process.Child.Id, timeout_ms: usize) !bool {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const timeout: win.DWORD = @intCast(@min(timeout_ms, std.math.maxInt(win.DWORD)));
    win.WaitForSingleObjectEx(process_handle, timeout, false) catch |err| switch (err) {
        error.WaitTimeOut => return false,
        else => return err,
    };
    return true;
}

pub fn waitForThread(thread: std.Thread, timeout_ms: usize) !bool {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const timeout: win.DWORD = @intCast(@min(timeout_ms, std.math.maxInt(win.DWORD)));
    win.WaitForSingleObjectEx(thread.getHandle(), timeout, false) catch |err| switch (err) {
        error.WaitTimeOut => return false,
        else => return err,
    };
    return true;
}

pub fn cancelThreadIo(thread: std.Thread) void {
    if (builtin.os.tag == .windows) _ = CancelSynchronousIo(thread.getHandle());
}

pub fn closeUnreapedChildHandles(child: *std.process.Child) void {
    if (builtin.os.tag != .windows) return;
    _ = win.CloseHandle(child.id);
    _ = win.CloseHandle(child.thread_handle);
    child.id = undefined;
    child.thread_handle = undefined;
}

test "kill-on-close job has one idempotent owner" {
    var job = try KillOnCloseJob.init();
    job.deinit();
    job.deinit();
    try std.testing.expect(job.handle == null);
}
