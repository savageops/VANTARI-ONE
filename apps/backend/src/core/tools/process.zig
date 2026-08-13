const builtin = @import("builtin");
const std = @import("std");

const module = @import("module.zig");
const process_tree = @import("../../shared/process_tree.zig");

/// Owns bounded command-child execution for shell and persistent eval. Why:
/// these paths must share deadlines and Windows tree teardown. Preserves one
/// lifecycle owner and truthful cleanup evidence for this command surface.

pub const PersistentTerminationReceipt = struct {
    termination_requested: bool = false,
    tree_teardown_attempted: bool = false,
    child_reaped: bool = false,
    pipes_drained: bool = false,
};

/// One response read from a persistent worker. Why: a timeout must return
/// bounded evidence instead of leaving the evaluator blocked on a child pipe.
/// Preserves: line framing, output caps, and the teardown receipt.
pub const PersistentReadResult = struct {
    line: []u8,
    truncated: bool = false,
    timed_out: bool = false,
    termination: PersistentTerminationReceipt = .{},

    pub fn deinit(self: PersistentReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
    }
};

const LineReader = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    output: std.array_list.Managed(u8),
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    done: bool = false,
    saw_newline: bool = false,
    read_error: ?anyerror = null,
    truncated: bool = false,
    max_bytes: usize,

    fn init(allocator: std.mem.Allocator, file: std.fs.File, max_bytes: usize) LineReader {
        return .{
            .allocator = allocator,
            .file = file,
            .output = std.array_list.Managed(u8).init(allocator),
            .max_bytes = max_bytes,
        };
    }

    /// Publish one terminal read state to the waiting tool call. Why: the
    /// supervisor must distinguish a complete response from EOF or timeout.
    /// Preserves: condition-variable wakeup without polling the pipe.
    fn finish(self: *LineReader, read_error: ?anyerror, saw_newline: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.read_error = read_error;
        self.saw_newline = saw_newline;
        self.done = true;
        self.condition.broadcast();
    }

    /// Drain one worker response until newline or EOF. Why: discarding bytes
    /// after the display cap still prevents the child from blocking on a full
    /// pipe. Preserves: bounded memory with complete pipe consumption.
    fn run(self: *LineReader) void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = self.file.read(&buffer) catch |err| {
                self.finish(err, false);
                return;
            };
            if (count == 0) {
                self.finish(null, false);
                return;
            }

            for (buffer[0..count]) |byte| {
                if (byte == '\n') {
                    self.finish(null, true);
                    return;
                }
                if (self.output.items.len < self.max_bytes) {
                    self.output.append(byte) catch |err| {
                        self.finish(err, false);
                        return;
                    };
                } else {
                    self.truncated = true;
                }
            }
        }
    }
};

/// Owns one interactive child and its stdio handles. Why: persistent eval
/// needs a long-lived namespace, but its process lifecycle must remain the
/// same bounded owner as shell execution. Preserves: stdin serialization,
/// response draining, timeout teardown, and explicit receipts.
pub const PersistentProcess = struct {
    child: std.process.Child,
    job: process_tree.KillOnCloseJob,
    stdin: ?std.fs.File,
    stdout: ?std.fs.File,
    active: bool = true,
    receipt: PersistentTerminationReceipt = .{},
    stdin_mutex: std.Thread.Mutex = .{},

    /// Start a persistent child with bounded, supervisor-owned pipes. Why:
    /// callers must not spawn raw children with ad hoc teardown. Preserves:
    /// workspace cwd, isolated stdio, and Windows Job Object admission.
    pub fn spawn(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        argv: []const []const u8,
    ) !PersistentProcess {
        var job = process_tree.KillOnCloseJob.init() catch process_tree.KillOnCloseJob{};
        errdefer job.deinit();

        var child = std.process.Child.init(argv, allocator);
        child.cwd = cwd;
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        var spawned = true;
        errdefer if (spawned) terminateSpawnedChild(&child, &job);

        // Assignment is best effort because a process can already be inside
        // an inherited Windows job. The receipt remains honest: termination
        // records that tree teardown was attempted, not that assignment won.
        job.assign(child.id) catch {};

        const stdin = child.stdin orelse return error.MissingChildStdin;
        child.stdin = null;
        const stdout = child.stdout orelse return error.MissingChildStdout;
        child.stdout = null;
        spawned = false;

        return .{
            .child = child,
            .job = job,
            .stdin = stdin,
            .stdout = stdout,
        };
    }

    /// Write one newline-delimited request without interleaving callers. Why:
    /// persistent workers have one ordered request/response channel. Preserves:
    /// framing and the single-flight invariant.
    pub fn writeLine(self: *PersistentProcess, line: []const u8) !void {
        if (!self.active) return error.ProcessNotRunning;
        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        const stdin = self.stdin orelse return error.MissingChildStdin;
        stdin.writeAll(line) catch {
            _ = self.terminateChild();
            return error.ProcessPipeClosed;
        };
    }

    /// Wait for one bounded response and terminate on deadline. Why: a child
    /// that stops responding must not pin the executor or the TUI. Preserves:
    /// output draining, timeout semantics, and process cleanup evidence.
    pub fn readLine(
        self: *PersistentProcess,
        allocator: std.mem.Allocator,
        timeout_ms: usize,
        max_bytes: usize,
    ) !PersistentReadResult {
        if (!self.active) return error.ProcessNotRunning;
        const stdout = self.stdout orelse return error.MissingChildStdout;
        self.stdout = null;

        const reader = try allocator.create(LineReader);
        reader.* = LineReader.init(allocator, stdout, max_bytes);
        errdefer {
            self.stdout = reader.file;
            reader.output.deinit();
            allocator.destroy(reader);
        }

        const thread = try std.Thread.spawn(.{}, LineReader.run, .{reader});

        reader.mutex.lock();
        if (!reader.done) reader.condition.timedWait(&reader.mutex, timeoutToNs(timeout_ms)) catch {};
        const timed_out = !reader.done;
        reader.mutex.unlock();

        if (timed_out) {
            const termination = self.terminateChild();
            // Closing the private reader handle plus CancelSynchronousIo gives
            // Windows a bounded escape from inherited/blocked pipe reads.
            reader.file.close();
            const pipes_drained = joinReader(thread);
            if (pipes_drained) {
                reader.output.deinit();
                allocator.destroy(reader);
            }
            return .{
                .line = try allocator.dupe(u8, ""),
                .timed_out = true,
                .termination = .{
                    .termination_requested = termination.termination_requested,
                    .tree_teardown_attempted = termination.tree_teardown_attempted,
                    .child_reaped = termination.child_reaped,
                    .pipes_drained = pipes_drained,
                },
            };
        }

        thread.join();
        self.stdout = reader.file;

        if (reader.read_error) |err| {
            reader.output.deinit();
            allocator.destroy(reader);
            _ = self.terminateChild();
            return err;
        }
        if (!reader.saw_newline) {
            reader.output.deinit();
            allocator.destroy(reader);
            _ = self.terminateChild();
            return error.ProcessPipeClosed;
        }

        const line = try reader.output.toOwnedSlice();
        const truncated = reader.truncated;
        reader.output.deinit();
        allocator.destroy(reader);
        return .{
            .line = line,
            .truncated = truncated,
            .termination = .{ .pipes_drained = true },
        };
    }

    /// Stop the child and return the cleanup receipt. Why: deinit is the
    /// cancellation boundary for a session-owned persistent worker. Preserves:
    /// idempotency and truthful reaping/tree-teardown state.
    pub fn stop(self: *PersistentProcess) PersistentTerminationReceipt {
        return self.terminateChild();
    }

    /// Release the child and all supervisor-owned handles. Why: registry
    /// teardown must not leave eval workers alive after a session ends.
    /// Preserves: idempotent cleanup for normal and timeout paths.
    pub fn deinit(self: *PersistentProcess) void {
        _ = self.terminateChild();
    }

    fn terminateChild(self: *PersistentProcess) PersistentTerminationReceipt {
        if (!self.active) return self.receipt;
        self.active = false;

        if (self.stdin) |*stdin| {
            stdin.close();
            self.stdin = null;
        }
        if (self.stdout) |*stdout| {
            stdout.close();
            self.stdout = null;
        }

        var receipt = PersistentTerminationReceipt{ .termination_requested = true };
        if (builtin.os.tag == .windows) {
            receipt.tree_teardown_attempted = true;
            self.job.terminate(self.child.id, 1);
            self.job.deinit();
            if (process_tree.waitForProcess(self.child.id, 5_000) catch false) {
                _ = self.child.wait() catch {};
                receipt.child_reaped = true;
            } else {
                process_tree.closeUnreapedChildHandles(&self.child);
            }
        } else {
            _ = self.child.kill() catch {};
            _ = self.child.wait() catch {};
            self.job.deinit();
            receipt.child_reaped = true;
        }
        self.receipt = receipt;
        return receipt;
    }
};

/// Terminate a just-spawned child while ownership is still local. Why: a
/// partial spawn must not leak a process when a pipe or job assignment fails.
/// Preserves: the same tree-first cleanup invariant as steady-state teardown.
fn terminateSpawnedChild(child: *std.process.Child, job: *process_tree.KillOnCloseJob) void {
    if (child.stdin) |*stdin| {
        stdin.close();
        child.stdin = null;
    }
    if (child.stdout) |*stdout| {
        stdout.close();
        child.stdout = null;
    }
    if (builtin.os.tag == .windows) {
        job.terminate(child.id, 1);
        job.deinit();
        if (process_tree.waitForProcess(child.id, 5_000) catch false) {
            _ = child.wait() catch {};
        } else {
            process_tree.closeUnreapedChildHandles(child);
        }
    } else {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
    }
}

/// Bound a thread join after process termination. Why: Windows pipe handles
/// can survive the direct child; the supervisor needs a finite drain receipt.
/// Preserves: no indefinite executor wait and no use-after-free on the reader.
fn joinReader(thread: std.Thread) bool {
    if (builtin.os.tag != .windows) {
        thread.join();
        return true;
    }
    process_tree.cancelThreadIo(thread);
    if (process_tree.waitForThread(thread, 1_000) catch false) {
        thread.join();
        return true;
    }
    // The reader owns its heap context and closed file handle. Detaching is
    // safe here; the context is intentionally retained if the OS refuses the
    // bounded join, and the receipt reports pipes_drained=false.
    thread.detach();
    return false;
}

fn timeoutToNs(timeout_ms: usize) u64 {
    return @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms;
}

/// Run one bounded command through the canonical tool process owner. Why:
/// shell_exec and eval must share output caps, deadlines, and teardown code.
/// Preserves: the existing CommandRunner contract and live output callbacks.
pub fn runWithLimits(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!module.CommandOutput {
    if (builtin.os.tag == .windows) return runWithLimitsWindows(allocator, cwd, argv, limits);
    return runWithLimitsPortable(allocator, cwd, argv, limits);
}

fn runWithLimitsPortable(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!module.CommandOutput {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    var spawned = true;
    errdefer if (spawned) {
        _ = child.kill() catch {};
    };
    try child.waitForSpawn();

    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;

    child.stderr = null;
    var stdout_collector = PipeCollector{
        .allocator = allocator,
        .file = stdout_file,
        .stream = .stdout,
        .output = &stdout,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    var stderr_collector = PipeCollector{
        .allocator = allocator,
        .file = stderr_file,
        .stream = .stderr,
        .output = &stderr,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    const stdout_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stdout_collector});
    const stderr_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stderr_collector});

    const timeout_ns = @as(u64, @intCast(limits.timeout_ms)) * std.time.ns_per_ms;
    const start_ns = std.time.nanoTimestamp();
    var timed_out = false;
    var term: std.process.Child.Term = undefined;
    while (true) {
        const wait_result = std.posix.waitpid(child.id, std.posix.W.NOHANG);
        if (wait_result.pid == child.id) {
            term = posixStatusToTerm(wait_result.status);
            child.id = undefined;
            spawned = false;
            break;
        }
        const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - start_ns));
        if (elapsed_ns >= timeout_ns) {
            timed_out = true;
            term = try child.kill();
            spawned = false;
            break;
        }
        std.Thread.sleep(@min(timeout_ns - elapsed_ns, 10 * std.time.ns_per_ms));
    }

    stdout_thread.join();
    stderr_thread.join();
    if (stdout_collector.err) |err| return err;
    if (stderr_collector.err) |err| return err;

    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        else => if (timed_out) 1 else return module.Error.CommandTerminated,
    };
    return .{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .timed_out = timed_out,
        .truncated = stdout_collector.cap_reached or stderr_collector.cap_reached,
    };
}

const PipeCollector = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    stream: module.CommandOutputStream,
    output: *std.ArrayList(u8),
    max_output_bytes: usize,
    callback: module.CommandOutputCallback,
    err: ?anyerror = null,
    cap_reached: bool = false,

    fn run(self: *PipeCollector) void {
        defer self.file.close();
        self.readLoop() catch |err| {
            self.err = err;
        };
    }

    fn readLoop(self: *PipeCollector) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = try self.file.read(&buffer);
            if (count == 0) break;
            if (self.output.items.len >= self.max_output_bytes) {
                if (!self.cap_reached) {
                    self.cap_reached = true;
                    try self.callback.onOutput(self.stream, "", true);
                }
                continue;
            }
            const remaining = self.max_output_bytes - self.output.items.len;
            const kept_len = @min(remaining, count);
            const kept = buffer[0..kept_len];
            try self.output.appendSlice(self.allocator, kept);
            const cap_reached = kept_len < count or self.output.items.len >= self.max_output_bytes;
            if (cap_reached) self.cap_reached = true;
            try self.callback.onOutput(self.stream, kept, cap_reached);
        }
    }
};

fn posixStatusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

/// Windows implementation uses a Job Object so timeout kills include
/// descendants. Why: direct TerminateProcess leaves shell grandchildren alive.
/// Preserves: concurrent drains and bounded termination evidence.
fn runWithLimitsWindows(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    argv: []const []const u8,
    limits: module.CommandLimits,
) anyerror!module.CommandOutput {
    const windows = std.os.windows;
    var job = process_tree.KillOnCloseJob.init() catch process_tree.KillOnCloseJob{};
    defer job.deinit();

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = cwd;
    child.create_no_window = true;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);

    try child.spawn();
    var spawned = true;
    errdefer if (spawned) {
        job.terminate(child.id, 1);
        _ = process_tree.waitForProcess(child.id, 5_000) catch false;
    };
    job.assign(child.id) catch {};

    const stdout_file = child.stdout.?;
    child.stdout = null;
    const stderr_file = child.stderr.?;
    child.stderr = null;
    var stdout_collector = PipeCollector{
        .allocator = allocator,
        .file = stdout_file,
        .stream = .stdout,
        .output = &stdout,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    var stderr_collector = PipeCollector{
        .allocator = allocator,
        .file = stderr_file,
        .stream = .stderr,
        .output = &stderr,
        .max_output_bytes = limits.max_output_bytes,
        .callback = limits.output_callback,
    };
    const stdout_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stdout_collector});
    const stderr_thread = try std.Thread.spawn(.{}, PipeCollector.run, .{&stderr_collector});

    const timeout_ms: windows.DWORD = @intCast(@min(limits.timeout_ms, std.math.maxInt(windows.DWORD)));
    var timed_out = false;
    windows.WaitForSingleObjectEx(child.id, timeout_ms, false) catch |err| switch (err) {
        error.WaitTimeOut => {
            timed_out = true;
            job.terminate(child.id, 1);
            windows.WaitForSingleObjectEx(child.id, windows.INFINITE, false) catch {};
        },
        else => return err,
    };

    stdout_thread.join();
    stderr_thread.join();
    if (stdout_collector.err) |err| return err;
    if (stderr_collector.err) |err| return err;

    const term = try child.wait();
    spawned = false;
    const exit_code: i32 = switch (term) {
        .Exited => |code| code,
        else => return module.Error.CommandTerminated,
    };
    return .{
        .exit_code = exit_code,
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .timed_out = timed_out,
        .truncated = stdout_collector.cap_reached or stderr_collector.cap_reached,
    };
}
