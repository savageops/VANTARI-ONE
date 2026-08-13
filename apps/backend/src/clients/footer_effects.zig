const std = @import("std");
const tui = @import("tui");

const Style = tui.Cell.Style;
const Segment = tui.Cell.Segment;

/// Small campaign surface for footer motion. A campaign is a data choice,
/// not a new plugin runtime: replace the config or add one renderer here when
/// a seasonal treatment is promoted.
pub const Config = struct {
    enabled: bool = true,
    effect: Effect = .orchestrate_sweep,
    period_ms: i64 = 3_000,
    duration_ms: i64 = 900,
    frame_ms: i64 = 80,
    band_half_width: f64 = 0.22,
    core_half_width: f64 = 0.075,
};

pub const Effect = enum {
    none,
    orchestrate_sweep,
};

pub const default_config: Config = .{};

pub const Palette = struct {
    base: Style,
    edge: Style,
    core: Style,
};

pub const Frame = struct {
    effect: Effect = .none,
    active: bool = false,
    phase: f64 = 0,
    band_half_width: f64 = 0.22,
    core_half_width: f64 = 0.075,
};

pub const Controller = struct {
    config: Config = default_config,
    selected_effect: Effect = .none,
    cycle_start_ms: ?i64 = null,
    last_render_ms: ?i64 = null,
    last_render_active: bool = false,

    pub fn syncMode(self: *Controller, mode_label: []const u8, now_ms: i64) void {
        const next_effect = effectForMode(mode_label, self.config);
        if (next_effect == self.selected_effect and self.cycle_start_ms != null) return;

        self.selected_effect = next_effect;
        self.cycle_start_ms = if (next_effect == .none) null else now_ms;
        self.last_render_ms = null;
        self.last_render_active = false;
    }

    pub fn frame(self: *Controller, mode_label: []const u8, now_ms: i64) Frame {
        self.syncMode(mode_label, now_ms);
        if (self.selected_effect == .none) return .{};

        self.advanceCycle(now_ms);
        const cycle_start = self.cycle_start_ms orelse return .{};
        const elapsed_ms = @max(@as(i64, 0), now_ms - cycle_start);
        const duration_ms = self.durationMs();
        const band_half_width = self.bandHalfWidth();
        const core_half_width = self.coreHalfWidth(band_half_width);
        if (elapsed_ms >= duration_ms) {
            return .{
                .effect = self.selected_effect,
                .active = false,
                .phase = 1,
                .band_half_width = band_half_width,
                .core_half_width = core_half_width,
            };
        }

        const phase = if (duration_ms == 0)
            1.0
        else
            @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(duration_ms));
        return .{
            .effect = self.selected_effect,
            .active = true,
            .phase = sweepEase(std.math.clamp(phase, 0.0, 1.0)),
            .band_half_width = band_half_width,
            .core_half_width = core_half_width,
        };
    }

    pub fn needsRender(self: *Controller, mode_label: []const u8, now_ms: i64) bool {
        const current = self.frame(mode_label, now_ms);
        if (current.effect == .none) return false;
        if (current.active != self.last_render_active) return true;
        if (!current.active) return false;

        const last_render = self.last_render_ms orelse return true;
        return now_ms - last_render >= self.frameMs();
    }

    pub fn markRendered(self: *Controller, mode_label: []const u8, now_ms: i64) Frame {
        const current = self.frame(mode_label, now_ms);
        self.last_render_ms = now_ms;
        self.last_render_active = current.active;
        return current;
    }

    /// Returns the next bounded sleep for the main UI loop. The loop remains
    /// event-driven for every non-orchestrate mode; only the selected campaign
    /// requests a timed wake.
    pub fn nextWaitMs(self: *Controller, mode_label: []const u8, now_ms: i64) usize {
        const current = self.frame(mode_label, now_ms);
        if (current.effect == .none) return 0;
        if (self.needsRender(mode_label, now_ms)) return 0;

        const cycle_start = self.cycle_start_ms orelse return 0;
        const target_ms = if (current.active)
            (self.last_render_ms orelse now_ms) + self.frameMs()
        else
            cycle_start + self.periodMs();
        const remaining_ms = @max(@as(i64, 1), target_ms - now_ms);
        return @intCast(@min(@as(i64, 100), remaining_ms));
    }

    fn advanceCycle(self: *Controller, now_ms: i64) void {
        const cycle_start = self.cycle_start_ms orelse return;
        const period_ms = self.periodMs();
        if (now_ms < cycle_start) return;
        const elapsed_ms = now_ms - cycle_start;
        if (elapsed_ms < period_ms) return;
        const cycles = @divTrunc(elapsed_ms, period_ms);
        self.cycle_start_ms = cycle_start + cycles * period_ms;
        self.last_render_active = false;
    }

    fn periodMs(self: *const Controller) i64 {
        return @max(@as(i64, 1), self.config.period_ms);
    }

    fn durationMs(self: *const Controller) i64 {
        return std.math.clamp(self.config.duration_ms, @as(i64, 0), self.periodMs() - 1);
    }

    fn frameMs(self: *const Controller) i64 {
        return @max(@as(i64, 1), self.config.frame_ms);
    }

    fn bandHalfWidth(self: *const Controller) f64 {
        return std.math.clamp(self.config.band_half_width, 0.01, 0.5);
    }

    fn coreHalfWidth(self: *const Controller, band_half_width: f64) f64 {
        return std.math.clamp(self.config.core_half_width, 0.0, band_half_width);
    }
};

pub fn effectForMode(mode_label: []const u8, config: Config) Effect {
    if (!config.enabled or config.effect == .none) return .none;
    if (!std.mem.eql(u8, mode_label, "orchestrate")) return .none;
    return config.effect;
}

pub fn sweepEase(t: f64) f64 {
    const clamped = std.math.clamp(t, 0.0, 1.0);
    if (clamped < 0.5) return 4.0 * clamped * clamped * clamped;
    const inverse = -2.0 * clamped + 2.0;
    return 1.0 - (inverse * inverse * inverse) / 2.0;
}

/// Build the footer as terminal segments while keeping the canonical footer
/// string unchanged. The sweep only touches the mode token between the first
/// two separators; status, model, context, and transient metadata retain the
/// normal footer style.
pub fn writeSegments(
    segments: []Segment,
    line: []const u8,
    frame: Frame,
    palette: Palette,
) usize {
    if (segments.len == 0 or line.len == 0) return 0;
    if (frame.effect != .orchestrate_sweep or !frame.active) {
        segments[0] = .{ .text = line, .style = palette.base };
        return 1;
    }

    const footer_separator = " · ";
    const first_separator = std.mem.indexOf(u8, line, footer_separator) orelse {
        segments[0] = .{ .text = line, .style = palette.base };
        return 1;
    };
    const mode_start = first_separator + footer_separator.len;
    const mode_end = (std.mem.indexOfPos(u8, line, mode_start, footer_separator) orelse line.len);
    if (mode_start >= mode_end) {
        segments[0] = .{ .text = line, .style = palette.base };
        return 1;
    }

    const mode = line[mode_start..mode_end];
    const codepoint_count = std.unicode.utf8CountCodepoints(mode) catch {
        segments[0] = .{ .text = line, .style = palette.base };
        return 1;
    };
    if (codepoint_count == 0 or codepoint_count + 2 > segments.len) {
        segments[0] = .{ .text = line, .style = palette.base };
        return 1;
    }

    var segment_count: usize = 0;
    if (mode_start > 0) {
        segments[segment_count] = .{ .text = line[0..mode_start], .style = palette.base };
        segment_count += 1;
    }

    const center = frame.phase * (1.0 + 2.0 * frame.band_half_width) - frame.band_half_width;
    var byte_index: usize = 0;
    var codepoint_index: usize = 0;
    while (byte_index < mode.len) {
        const byte_length = std.unicode.utf8ByteSequenceLength(mode[byte_index]) catch {
            segments[0] = .{ .text = line, .style = palette.base };
            return 1;
        };
        if (byte_length > mode.len - byte_index) {
            segments[0] = .{ .text = line, .style = palette.base };
            return 1;
        }

        const position = (@as(f64, @floatFromInt(codepoint_index)) + 0.5) /
            @as(f64, @floatFromInt(codepoint_count));
        const distance = @abs(position - center);
        const style = if (distance <= frame.core_half_width)
            palette.core
        else if (distance <= frame.band_half_width)
            palette.edge
        else
            palette.base;
        segments[segment_count] = .{
            .text = mode[byte_index .. byte_index + byte_length],
            .style = style,
        };
        segment_count += 1;
        byte_index += byte_length;
        codepoint_index += 1;
    }

    if (mode_end < line.len) {
        segments[segment_count] = .{ .text = line[mode_end..], .style = palette.base };
        segment_count += 1;
    }
    return segment_count;
}

test "default campaign is enabled for orchestrate only" {
    try std.testing.expectEqual(Effect.orchestrate_sweep, effectForMode("orchestrate", default_config));
    try std.testing.expectEqual(Effect.none, effectForMode("build", default_config));
    try std.testing.expectEqual(Effect.none, effectForMode("align", default_config));
    try std.testing.expectEqual(Effect.none, effectForMode("plan", default_config));
}

test "campaign can be disabled without changing the renderer" {
    try std.testing.expectEqual(Effect.none, effectForMode("orchestrate", .{ .enabled = false }));
    try std.testing.expectEqual(Effect.none, effectForMode("orchestrate", .{ .effect = .none }));
    try std.testing.expectEqual(Effect.none, effectForMode("ORCHESTRATE", default_config));
}

test "sweep ease preserves endpoints and midpoint" {
    try std.testing.expectEqual(@as(f64, 0), sweepEase(0));
    try std.testing.expectEqual(@as(f64, 1), sweepEase(1));
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), sweepEase(0.5), 0.000001);
    try std.testing.expect(sweepEase(0.25) < 0.25);
    try std.testing.expect(sweepEase(0.75) > 0.75);
}

test "sweep ease clamps out of range phases" {
    try std.testing.expectEqual(sweepEase(0), sweepEase(-1));
    try std.testing.expectEqual(sweepEase(1), sweepEase(2));
}

test "controller starts orchestrate immediately" {
    var controller = Controller{};
    const current = controller.frame("orchestrate", 1_000);
    try std.testing.expectEqual(Effect.orchestrate_sweep, current.effect);
    try std.testing.expect(current.active);
    try std.testing.expectEqual(@as(f64, 0), current.phase);
    try std.testing.expectEqual(@as(i64, 1_000), controller.cycle_start_ms.?);
}

test "controller keeps other modes static" {
    var controller = Controller{};
    const current = controller.frame("build", 1_000);
    try std.testing.expectEqual(Effect.none, current.effect);
    try std.testing.expect(!current.active);
    try std.testing.expect(controller.cycle_start_ms == null);
    try std.testing.expect(!controller.needsRender("build", 2_000));
    try std.testing.expectEqual(@as(usize, 0), controller.nextWaitMs("build", 2_000));
}

test "controller completes before the three second period" {
    var controller = Controller{};
    _ = controller.frame("orchestrate", 0);
    const idle = controller.frame("orchestrate", 901);
    try std.testing.expectEqual(Effect.orchestrate_sweep, idle.effect);
    try std.testing.expect(!idle.active);
    try std.testing.expectEqual(@as(f64, 1), idle.phase);
    try std.testing.expectEqual(@as(i64, 0), controller.cycle_start_ms.?);
}

test "controller starts the next cycle at the configured period" {
    var controller = Controller{};
    _ = controller.frame("orchestrate", 0);
    const next = controller.frame("orchestrate", 3_000);
    try std.testing.expect(next.active);
    try std.testing.expectEqual(@as(f64, 0), next.phase);
    try std.testing.expectEqual(@as(i64, 3_000), controller.cycle_start_ms.?);
}

test "controller catches up after a long sleep without drift" {
    var controller = Controller{};
    _ = controller.frame("orchestrate", 0);
    const next = controller.frame("orchestrate", 9_000);
    try std.testing.expect(next.active);
    try std.testing.expectEqual(@as(i64, 9_000), controller.cycle_start_ms.?);
}

test "mode changes clear the prior campaign clock" {
    var controller = Controller{};
    _ = controller.frame("orchestrate", 100);
    _ = controller.frame("build", 200);
    try std.testing.expectEqual(Effect.none, controller.selected_effect);
    try std.testing.expect(controller.cycle_start_ms == null);
    _ = controller.frame("orchestrate", 300);
    try std.testing.expectEqual(@as(i64, 300), controller.cycle_start_ms.?);
}

test "controller honors a custom cadence" {
    var controller = Controller{ .config = .{ .period_ms = 1_000, .duration_ms = 200, .frame_ms = 40 } };
    _ = controller.frame("orchestrate", 0);
    const idle = controller.frame("orchestrate", 201);
    try std.testing.expect(!idle.active);
    const next = controller.frame("orchestrate", 1_000);
    try std.testing.expect(next.active);
    try std.testing.expectEqual(@as(i64, 1_000), controller.cycle_start_ms.?);
}

test "controller clamps invalid cadence values safely" {
    var controller = Controller{ .config = .{ .period_ms = 0, .duration_ms = 8, .frame_ms = 0 } };
    const current = controller.frame("orchestrate", 0);
    try std.testing.expect(!current.active);
    try std.testing.expectEqual(@as(i64, 1), controller.periodMs());
    try std.testing.expectEqual(@as(i64, 0), controller.durationMs());
    try std.testing.expectEqual(@as(i64, 1), controller.frameMs());
}

test "controller marks the initial frame and waits for the next frame" {
    var controller = Controller{};
    try std.testing.expect(controller.needsRender("orchestrate", 0));
    _ = controller.markRendered("orchestrate", 0);
    try std.testing.expect(!controller.needsRender("orchestrate", 79));
    try std.testing.expect(controller.needsRender("orchestrate", 80));
}

test "controller emits one static frame at sweep completion" {
    var controller = Controller{};
    _ = controller.markRendered("orchestrate", 0);
    try std.testing.expect(controller.needsRender("orchestrate", 900));
    _ = controller.markRendered("orchestrate", 900);
    try std.testing.expect(!controller.needsRender("orchestrate", 901));
}

test "controller waits for the next cycle while static" {
    var controller = Controller{};
    _ = controller.markRendered("orchestrate", 0);
    _ = controller.markRendered("orchestrate", 900);
    try std.testing.expectEqual(@as(usize, 100), controller.nextWaitMs("orchestrate", 1_000));
    try std.testing.expectEqual(@as(usize, 0), controller.nextWaitMs("orchestrate", 3_000));
}

test "plain footer line remains one base segment" {
    var segments: [16]Segment = undefined;
    const count = writeSegments(&segments, "ready · build · model", .{}, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("ready · build · model", segments[0].text);
    try std.testing.expect(Style.eql(.{}, segments[0].style));
}

test "inactive orchestrate frame remains static" {
    var segments: [16]Segment = undefined;
    const count = writeSegments(&segments, "ready · orchestrate · model", .{ .effect = .orchestrate_sweep, .active = false, .phase = 1 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(Style.eql(.{}, segments[0].style));
}

test "active sweep preserves status and model segment styles" {
    var segments: [32]Segment = undefined;
    const base: Style = .{};
    const count = writeSegments(&segments, "ready · orchestrate · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = base, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expect(count > 3);
    try std.testing.expectEqualStrings("ready · ", segments[0].text);
    try std.testing.expectEqualStrings(" · model", segments[count - 1].text);
    try std.testing.expect(Style.eql(base, segments[0].style));
    try std.testing.expect(Style.eql(base, segments[count - 1].style));
}

test "active sweep produces the core style at the leading edge" {
    var segments: [32]Segment = undefined;
    const core: Style = .{ .bold = true };
    const count = writeSegments(&segments, "ready · orchestrate · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.19 }, .{ .base = .{}, .edge = .{ .italic = true }, .core = core });
    try std.testing.expect(count > 2);
    try std.testing.expect(Style.eql(core, segments[1].style));
}

test "active sweep produces the core style at the trailing edge" {
    var segments: [32]Segment = undefined;
    const core: Style = .{ .bold = true };
    const count = writeSegments(&segments, "ready · orchestrate · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.82 }, .{ .base = .{}, .edge = .{ .italic = true }, .core = core });
    try std.testing.expect(count > 2);
    try std.testing.expect(Style.eql(core, segments[count - 2].style));
}

test "active sweep keeps the whole line safe when there is no mode separator" {
    var segments: [16]Segment = undefined;
    const count = writeSegments(&segments, "orchestrate", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("orchestrate", segments[0].text);
}

test "active sweep handles the smallest valid mode token" {
    var segments: [16]Segment = undefined;
    const count = writeSegments(&segments, "ready · x · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expect(count > 1);
}

test "segment capacity failure falls back to the canonical line" {
    var segments: [2]Segment = undefined;
    const count = writeSegments(&segments, "ready · orchestrate · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("ready · orchestrate · model", segments[0].text);
}

test "unicode mode labels retain valid UTF-8 during a sweep" {
    var segments: [32]Segment = undefined;
    const count = writeSegments(&segments, "ready · orchestraté · model", .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expect(count > 2);
    for (segments[0..count]) |segment| try std.testing.expect(std.unicode.utf8ValidateSlice(segment.text));
}

test "non-orchestrate frames never emit accent styles" {
    var segments: [16]Segment = undefined;
    const accent: Style = .{ .bold = true };
    const count = writeSegments(&segments, "ready · build · model", .{}, .{ .base = .{}, .edge = accent, .core = accent });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(Style.eql(.{}, segments[0].style));
}

test "campaign style never changes the footer text bytes" {
    var segments: [32]Segment = undefined;
    const line = "ready · orchestrate · model";
    const count = writeSegments(&segments, line, .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    var rebuilt: [64]u8 = undefined;
    var length: usize = 0;
    for (segments[0..count]) |segment| {
        @memcpy(rebuilt[length .. length + segment.text.len], segment.text);
        length += segment.text.len;
    }
    try std.testing.expectEqualStrings(line, rebuilt[0..length]);
}

test "empty footer text produces no segments" {
    var segments: [4]Segment = undefined;
    try std.testing.expectEqual(@as(usize, 0), writeSegments(&segments, "", .{}, .{ .base = .{}, .edge = .{}, .core = .{} }));
}

test "empty segment storage is a safe no-op" {
    var segments: [0]Segment = .{};
    try std.testing.expectEqual(@as(usize, 0), writeSegments(&segments, "ready · orchestrate · model", .{}, .{ .base = .{}, .edge = .{}, .core = .{} }));
}

test "controller phase advances through the active sweep" {
    var controller = Controller{};
    const first = controller.frame("orchestrate", 100);
    const second = controller.frame("orchestrate", 500);
    try std.testing.expect(first.active);
    try std.testing.expect(second.active);
    try std.testing.expect(second.phase > first.phase);
}

test "campaign geometry is carried into the frame config" {
    var controller = Controller{ .config = .{ .band_half_width = 0.31, .core_half_width = 0.09 } };
    const current = controller.frame("orchestrate", 100);
    try std.testing.expectApproxEqAbs(@as(f64, 0.31), current.band_half_width, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.09), current.core_half_width, 0.000001);
}

test "invalid UTF-8 mode data falls back to one canonical segment" {
    var segments: [16]Segment = undefined;
    const line = [_]u8{ 'r', 'e', 'a', 'd', 'y', ' ', 0xc2, 0xb7, ' ', 0xff, ' ', 0xc2, 0xb7, ' ', 'm' };
    const count = writeSegments(&segments, &line, .{ .effect = .orchestrate_sweep, .active = true, .phase = 0.5 }, .{ .base = .{}, .edge = .{ .bold = true }, .core = .{ .italic = true } });
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualSlices(u8, &line, segments[0].text);
}
