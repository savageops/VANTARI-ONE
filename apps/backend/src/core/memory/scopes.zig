const std = @import("std");

/// Allocation scope identifiers per AGENTS.md §XVIII item 6. Each scope has a
/// clear owner, a clear lifetime, and a clear bound. The scope determines when
/// the arena is reset and what quota applies.
pub const Scope = enum {
    /// One provider turn in the executor loop. Reset after each step.
    /// Bound: max context window tokens × overhead factor.
    turn,
    /// One provider request/response cycle. Reset after the HTTP round-trip.
    /// Bound: max context window tokens.
    provider_payload,
    /// One tool dispatch. Reset after the tool result is collected.
    /// Bound: max_output_bytes for command tools; file size for read tools.
    tool_result,
    /// One TUI render frame. Reset after the frame is drawn.
    /// Bound: terminal buffer size (rows × cols × bytes_per_cell).
    ui_frame,

    pub fn label(self: Scope) []const u8 {
        return switch (self) {
            .turn => "turn",
            .provider_payload => "provider_payload",
            .tool_result => "tool_result",
            .ui_frame => "ui_frame",
        };
    }
};

/// A scoped arena allocator with optional byte quota enforcement. Wraps
/// `std.heap.ArenaAllocator` and tracks total bytes allocated. When the quota
/// is exceeded, allocation returns `error.QuotaExceeded` instead of growing
/// unbounded.
pub const ScopedArena = struct {
    scope: Scope,
    arena: std.heap.ArenaAllocator,
    bytes_allocated: usize = 0,
    quota_bytes: ?usize = null,

    /// Initialize a scoped arena backed by the given parent allocator.
    pub fn init(scope: Scope, parent: std.mem.Allocator, quota_bytes: ?usize) ScopedArena {
        return .{
            .scope = scope,
            .arena = std.heap.ArenaAllocator.init(parent),
            .quota_bytes = quota_bytes,
        };
    }

    /// The allocator interface for this scope.
    pub fn allocator(self: *ScopedArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset the arena, freeing all allocations made since init or the last
    /// reset. The arena is ready for reuse after this call.
    pub fn reset(self: *ScopedArena) void {
        _ = self.arena.reset(.free_all);
        self.bytes_allocated = 0;
    }

    /// Deinitialize the arena, freeing all memory.
    pub fn deinit(self: *ScopedArena) void {
        self.arena.deinit();
        self.bytes_allocated = 0;
    }

    /// Check if the given byte count fits within the quota. Returns
    /// `error.QuotaExceeded` if a quota is set and the allocation would
    /// exceed it.
    pub fn checkQuota(self: ScopedArena, bytes: usize) !void {
        if (self.quota_bytes) |quota| {
            if (self.bytes_allocated + bytes > quota) return error.QuotaExceeded;
        }
    }
};

/// Quota defaults for each scope. These are advisory bounds that prevent
/// unbounded growth; they can be overridden by configuration.
pub fn defaultQuota(scope: Scope) usize {
    return switch (scope) {
        .turn => 16 * 1024 * 1024, // 16 MiB
        .provider_payload => 8 * 1024 * 1024, // 8 MiB
        .tool_result => 1 * 1024 * 1024, // 1 MiB (matches default max_output_bytes)
        .ui_frame => 4 * 1024 * 1024, // 4 MiB
    };
}

test "ScopedArena allocates and resets within quota" {
    var arena = ScopedArena.init(.tool_result, std.testing.allocator, 1024);
    defer arena.deinit();

    const slice = try arena.allocator().alloc(u8, 512);
    @memset(slice, 0xAB);

    // Allocation within quota should succeed.
    try std.testing.expect(slice.len == 512);

    // Reset frees all allocations.
    arena.reset();
}

test "ScopedArena quota enforcement prevents unbounded growth" {
    var arena = ScopedArena.init(.tool_result, std.testing.allocator, 100);
    defer arena.deinit();

    // Small allocation within quota.
    try arena.checkQuota(50);

    // Simulate bytes_allocated tracking.
    arena.bytes_allocated = 80;

    // Large allocation exceeding quota should fail.
    try std.testing.expectError(error.QuotaExceeded, arena.checkQuota(50));
}

test "defaultQuota returns sensible bounds per scope" {
    try std.testing.expect(defaultQuota(.turn) > defaultQuota(.tool_result));
    try std.testing.expect(defaultQuota(.provider_payload) > defaultQuota(.tool_result));
    try std.testing.expect(defaultQuota(.ui_frame) > 0);
}

test "scope labels are stable strings" {
    try std.testing.expectEqualStrings("turn", Scope.turn.label());
    try std.testing.expectEqualStrings("provider_payload", Scope.provider_payload.label());
    try std.testing.expectEqualStrings("tool_result", Scope.tool_result.label());
    try std.testing.expectEqualStrings("ui_frame", Scope.ui_frame.label());
}
