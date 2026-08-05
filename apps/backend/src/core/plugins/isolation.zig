const std = @import("std");

/// Plugin isolation strategy (roadmap P2-21).
///
/// VANTARI isolates plugin tools via a subprocess boundary with stdio
/// JSON-RPC transport. The plugin runs as a child process; the kernel
/// communicates via line-delimited JSON-RPC over stdin/stdout. This is
/// the same shape as MCP (Model Context Protocol) stdio transport and
/// maps cleanly onto VANTARI's existing process-supervision surface
/// (CommandRunner, CommandLimits, Job Object kill-on-close).
///
/// Isolation levels (from weakest to strongest):
///   1. in_process  — shared allocator, no isolation (built-in tools only)
///   2. subprocess   — separate process, stdio-RPC, kernel-supervised kill
///   3. wasm_sandbox — WASM module with capability tokens (future, P3)
///
/// The default for all plugin tools is `subprocess`. In-process is reserved
/// for built-in tools that ship with the kernel binary.

pub const IsolationLevel = enum {
    /// Plugin runs in the kernel process. No isolation. Built-in tools only.
    in_process,
    /// Plugin runs as a child process with stdio JSON-RPC transport.
    /// Kernel supervises via Job Object / process group. Crash in the
    /// plugin does not crash the kernel.
    subprocess,
    /// Plugin runs in a WASM sandbox with capability tokens (future).
    wasm_sandbox,

    pub fn label(self: IsolationLevel) []const u8 {
        return switch (self) {
            .in_process => "in_process",
            .subprocess => "subprocess",
            .wasm_sandbox => "wasm_sandbox",
        };
    }

    /// Returns true if this isolation level provides process-level crash
    /// isolation (plugin crash does not crash the kernel).
    pub fn providesCrashIsolation(self: IsolationLevel) bool {
        return self != .in_process;
    }
};

/// The transport contract for subprocess-isolated plugins. Uses
/// line-delimited JSON-RPC over stdin/stdout — the same shape as MCP
/// stdio transport and VANTARI's own host/stdio_rpc.zig.
pub const SubprocessTransport = struct {
    /// The executable path for the plugin process.
    executable: []const u8,
    /// Arguments passed to the plugin process (after the executable).
    args: []const []const u8 = &.{},
    /// Timeout for individual tool dispatches (ms).
    timeout_ms: usize = 30_000,
    /// Maximum output bytes from the plugin process.
    max_output_bytes: usize = 65_536,
};

/// Default isolation level for new plugins. Subprocess is the safe default —
/// it provides crash isolation without the complexity of WASM.
pub const default_isolation_level: IsolationLevel = .subprocess;

test "IsolationLevel labels are stable" {
    try std.testing.expectEqualStrings("in_process", IsolationLevel.in_process.label());
    try std.testing.expectEqualStrings("subprocess", IsolationLevel.subprocess.label());
    try std.testing.expectEqualStrings("wasm_sandbox", IsolationLevel.wasm_sandbox.label());
}

test "subprocess and wasm provide crash isolation, in_process does not" {
    try std.testing.expect(!IsolationLevel.in_process.providesCrashIsolation());
    try std.testing.expect(IsolationLevel.subprocess.providesCrashIsolation());
    try std.testing.expect(IsolationLevel.wasm_sandbox.providesCrashIsolation());
}

test "default isolation level is subprocess" {
    try std.testing.expectEqual(IsolationLevel.subprocess, default_isolation_level);
}

test "SubprocessTransport has bounded timeout and output" {
    const transport = SubprocessTransport{
        .executable = "my-plugin",
        .timeout_ms = 5_000,
        .max_output_bytes = 1_024,
    };
    try std.testing.expectEqual(@as(usize, 5_000), transport.timeout_ms);
    try std.testing.expectEqual(@as(usize, 1_024), transport.max_output_bytes);
}
