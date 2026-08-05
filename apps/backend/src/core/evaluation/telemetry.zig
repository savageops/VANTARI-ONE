const std = @import("std");

/// Performance counter names, one per cost center from AGENTS.md §X.
/// Each counter is a power-of-two histogram bucket + count + total_ns.
pub const Counter = enum {
    context_compile,
    provider_turn,
    tool_dispatch,
    command_run,
    tui_frame,
    session_recovery,
    jsonl_scan,
    event_replay,

    pub fn label(self: Counter) []const u8 {
        return switch (self) {
            .context_compile => "context_compile",
            .provider_turn => "provider_turn",
            .tool_dispatch => "tool_dispatch",
            .command_run => "command_run",
            .tui_frame => "tui_frame",
            .session_recovery => "session_recovery",
            .jsonl_scan => "jsonl_scan",
            .event_replay => "event_replay",
        };
    }
};

/// A single counter's accumulated statistics. Fixed size — no allocation
/// per record. The histogram has 16 power-of-two buckets from 1µs to ~30s.
pub const CounterStat = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    /// Power-of-two histogram: bucket[i] covers [2^i, 2^(i+1)) ns.
    /// Bucket 0 = [1, 2) ns ... Bucket 15 = [2^15, 2^16) ns ≈ [33ms, 65ms).
    /// Higher buckets overflow into bucket 15.
    histogram: [16]u64 = [_]u64{0} ** 16,

    pub fn record(self: *CounterStat, duration_ns: u64) void {
        self.count += 1;
        self.total_ns += duration_ns;
        if (duration_ns < self.min_ns) self.min_ns = duration_ns;
        if (duration_ns > self.max_ns) self.max_ns = duration_ns;

        // Power-of-two bucket: floor(log2(duration_ns)) clamped to 15.
        if (duration_ns == 0) {
            self.histogram[0] += 1;
        } else {
            const log2_val: u64 = @intFromFloat(@floor(@log2(@as(f64, @floatFromInt(duration_ns)))));
            const bucket: usize = @intCast(@min(log2_val, @as(u64, 15)));
            self.histogram[bucket] += 1;
        }
    }

    pub fn avgNs(self: CounterStat) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }
};

/// Fixed-memory counter register. ~300 bytes total (8 counters × ~36 bytes).
/// No per-record allocation. Thread-safe via atomic operations where needed
/// (in production); for the current single-threaded stats read-out, direct
/// field access is sufficient.
pub const CounterRegister = struct {
    stats: [@typeInfo(Counter).@"enum".fields.len]CounterStat = [_]CounterStat{.{}} ** @typeInfo(Counter).@"enum".fields.len,

    pub fn record(self: *CounterRegister, counter: Counter, duration_ns: u64) void {
        self.stats[@intFromEnum(counter)].record(duration_ns);
    }

    pub fn get(self: *const CounterRegister, counter: Counter) CounterStat {
        return self.stats[@intFromEnum(counter)];
    }

    /// Render the register as JSON for the `VAR1 stats` command.
    pub fn renderJson(self: *const CounterRegister, allocator: std.mem.Allocator) ![]u8 {
        var output = std.array_list.Managed(u8).init(allocator);
        errdefer output.deinit();
        const writer = output.writer();

        try writer.writeAll("{\"counters\":{");
        const counters = [_]Counter{
            .context_compile, .provider_turn, .tool_dispatch, .command_run,
            .tui_frame, .session_recovery, .jsonl_scan, .event_replay,
        };
        for (counters, 0..) |counter, i| {
            if (i > 0) try writer.writeAll(",");
            const stat = self.get(counter);
            try writer.print(
                "\"{s}\":{{\"count\":{d},\"total_ns\":{d},\"min_ns\":{d},\"max_ns\":{d},\"avg_ns\":{d}}}",
                .{
                    counter.label(),
                    stat.count,
                    stat.total_ns,
                    if (stat.count == 0) @as(u64, 0) else stat.min_ns,
                    stat.max_ns,
                    stat.avgNs(),
                },
            );
        }
        try writer.writeAll("}}");

        return output.toOwnedSlice();
    }
};

test "CounterStat records min/max/count correctly" {
    var stat = CounterStat{};
    stat.record(1_000); // 1µs
    stat.record(2_000); // 2µs
    stat.record(5_000); // 5µs

    try std.testing.expectEqual(@as(u64, 3), stat.count);
    try std.testing.expectEqual(@as(u64, 8_000), stat.total_ns);
    try std.testing.expectEqual(@as(u64, 1_000), stat.min_ns);
    try std.testing.expectEqual(@as(u64, 5_000), stat.max_ns);
    try std.testing.expectEqual(@as(u64, 2_666), stat.avgNs());
}

test "CounterRegister renders JSON with all cost centers" {
    var reg = CounterRegister{};
    reg.record(.context_compile, 500_000);
    reg.record(.provider_turn, 1_000_000);
    reg.record(.tool_dispatch, 250_000);

    const json = try reg.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"context_compile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider_turn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_dispatch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"avg_ns\"") != null);
}

test "CounterRegister with no data renders zero counts" {
    const reg = CounterRegister{};
    const json = try reg.renderJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    // All counters present with count 0.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":0") != null);
}
