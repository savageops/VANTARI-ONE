const std = @import("std");
const Image = @import("Image.zig");

char: Character = .{},
style: Style = .{},
link: Hyperlink = .{},
image: ?Image.Placement = null,
default: bool = false,
/// Set to true if this cell is the last cell printed in a row before wrap. Vaxis will determine if
/// it should rely on the terminal's autowrap feature which can help with primary screen resizes
wrapped: bool = false,
scale: Scale = .{},

/// Segment is a contiguous run of text that has a constant style
pub const Segment = struct {
    text: []const u8,
    style: Style = .{},
    link: Hyperlink = .{},
};

pub const Character = struct {
    grapheme: []const u8 = " ",
    /// width should only be provided when the application is sure the terminal
    /// will measure the same width. This can be ensure by using the gwidth method
    /// included in libvaxis. If width is 0, libvaxis will measure the glyph at
    /// render time
    width: u8 = 1,
};

pub const CursorShape = enum {
    default,
    block_blink,
    block,
    underline_blink,
    underline,
    beam_blink,
    beam,
};

pub const Hyperlink = struct {
    uri: []const u8 = "",
    /// ie "id=app-1234"
    params: []const u8 = "",
};

pub const Scale = packed struct {
    scale: u3 = 1,
    // The spec allows up to 15, but we limit to 7
    numerator: u4 = 1,
    // The spec allows up to 15, but we limit to 7
    denominator: u4 = 1,
    vertical_alignment: enum(u2) {
        top = 0,
        bottom = 1,
        center = 2,
    } = .top,

    pub fn eql(self: Scale, other: Scale) bool {
        const a_scale: u13 = @bitCast(self);
        const b_scale: u13 = @bitCast(other);
        return a_scale == b_scale;
    }
};

pub const Style = struct {
    pub const Underline = enum {
        off,
        single,
        double,
        curly,
        dotted,
        dashed,
    };

    fg: Color = .default,
    bg: Color = .default,
    ul: Color = .default,
    ul_style: Underline = .off,

    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    blink: bool = false,
    reverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        const SGRBits = packed struct {
            bold: bool,
            dim: bool,
            italic: bool,
            blink: bool,
            reverse: bool,
            invisible: bool,
            strikethrough: bool,
        };
        const a_sgr: SGRBits = .{
            .bold = a.bold,
            .dim = a.dim,
            .italic = a.italic,
            .blink = a.blink,
            .reverse = a.reverse,
            .invisible = a.invisible,
            .strikethrough = a.strikethrough,
        };
        const b_sgr: SGRBits = .{
            .bold = b.bold,
            .dim = b.dim,
            .italic = b.italic,
            .blink = b.blink,
            .reverse = b.reverse,
            .invisible = b.invisible,
            .strikethrough = b.strikethrough,
        };
        return a_sgr == b_sgr and
            Color.eql(a.fg, b.fg) and
            Color.eql(a.bg, b.bg) and
            Color.eql(a.ul, b.ul) and
            a.ul_style == b.ul_style;
    }
};

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,

    pub const Kind = union(enum) {
        fg,
        bg,
        cursor,
        index: u8,
    };

    /// Returned when querying a color from the terminal
    pub const Report = struct {
        kind: Kind,
        value: [3]u8,
    };

    pub const Scheme = enum {
        dark,
        light,
    };

    pub fn eql(a: Color, b: Color) bool {
        switch (a) {
            .default => return b == .default,
            .index => |a_idx| {
                switch (b) {
                    .index => |b_idx| return a_idx == b_idx,
                    else => return false,
                }
            },
            .rgb => |a_rgb| {
                switch (b) {
                    .rgb => |b_rgb| return a_rgb[0] == b_rgb[0] and
                        a_rgb[1] == b_rgb[1] and
                        a_rgb[2] == b_rgb[2],
                    else => return false,
                }
            },
        }
    }

    pub fn rgbFromUint(val: u24) Color {
        const r_bits = val & 0b11111111_00000000_00000000;
        const g_bits = val & 0b00000000_11111111_00000000;
        const b_bits = val & 0b00000000_00000000_11111111;
        const rgb = [_]u8{
            @truncate(r_bits >> 16),
            @truncate(g_bits >> 8),
            @truncate(b_bits),
        };
        return .{ .rgb = rgb };
    }

    /// parse an XParseColor-style rgb specification into an rgb Color. The spec
    /// is of the form: rgb:rrrr/gggg/bbbb. Generally, the high two bits will always
    /// be the same as the low two bits.
    pub fn rgbFromSpec(spec: []const u8) !Color {
        var iter = std.mem.splitScalar(u8, spec, ':');
        const prefix = iter.next() orelse return error.InvalidColorSpec;
        if (!std.mem.eql(u8, "rgb", prefix)) return error.InvalidColorSpec;

        const spec_str = iter.next() orelse return error.InvalidColorSpec;

        var spec_iter = std.mem.splitScalar(u8, spec_str, '/');

        const r_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (r_raw.len != 4) return error.InvalidColorSpec;

        const g_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (g_raw.len != 4) return error.InvalidColorSpec;

        const b_raw = spec_iter.next() orelse return error.InvalidColorSpec;
        if (b_raw.len != 4) return error.InvalidColorSpec;

        const r = try std.fmt.parseUnsigned(u8, r_raw[2..], 16);
        const g = try std.fmt.parseUnsigned(u8, g_raw[2..], 16);
        const b = try std.fmt.parseUnsigned(u8, b_raw[2..], 16);

        return .{
            .rgb = [_]u8{ r, g, b },
        };
    }

    /// Quantize a 24-bit color to the nearest xterm-256 palette index when the
    /// terminal does not advertise truecolor support. The 256-color palette is
    /// 16 base colors (terminal-defined, skipped — we cannot guess their RGB),
    /// a 6×6×6 color cube at indices 16..231, and a 24-step grayscale ramp at
    /// 232..255. The cube is quantized on the standard 6-level ladder
    /// (0, 95, 135, 175, 215, 255); grayscale is matched when the source is
    /// near-achromatic, which keeps theme neutrals (borders, dim text, panels)
    /// from drifting into hue-tinted cube corners.
    pub fn to256(rgb: [3]u8) Color {
        const r: u16 = rgb[0];
        const g: u16 = rgb[1];
        const b: u16 = rgb[2];

        const cube_index: u16 = 16 + 36 * @as(u16, levelOf(r)) + 6 * @as(u16, levelOf(g)) + @as(u16, levelOf(b));

        const maxc = @max(r, @max(g, b));
        const minc = @min(r, @min(g, b));
        // Near-achromatic sources also consider the grayscale ramp: it has no
        // hue, so it is often nearer than a hue-tinted cube corner. Pick the
        // candidate with the smaller squared Euclidean distance.
        if (maxc -| minc <= 8) {
            // Grayscale ramp: index 232 = 8, step 10, up to 238 at 255.
            const gray = @as(u16, @intCast(@min(r + g + b, 3 * 255)));
            const level = if (gray <= 26) 0 else (gray - 26) / 30;
            const ramp_level: u16 = @min(23, level);
            const ramp_value: u16 = 8 + 10 * ramp_level;
            const cube_value = cubeLuma(cube_index);
            const ramp_dist = dist3(r, ramp_value) + dist3(g, ramp_value) + dist3(b, ramp_value);
            const cube_dist = dist3(r, cube_value) + dist3(g, cube_value) + dist3(b, cube_value);
            if (ramp_dist < cube_dist) {
                return .{ .index = @intCast(232 + ramp_level) };
            }
        }
        return .{ .index = @intCast(cube_index) };
    }

    fn dist3(a: u16, v: u16) u32 {
        const d = if (a > v) a - v else v - a;
        return @as(u32, d) * @as(u32, d);
    }

    /// The representative channel value of a color-cube index (16..231):
    /// level l maps to the standard ladder value.
    fn cubeLuma(index: u16) u16 {
        const ladder = [6]u16{ 0, 95, 135, 175, 215, 255 };
        const cube = index - 16;
        // Average of the three channel levels weighted by their cube position.
        const ri = cube / 36;
        const gi = (cube / 6) % 6;
        const bi = cube % 6;
        return (ladder[ri] + ladder[gi] + ladder[bi]) / 3;
    }

    fn levelOf(channel: u16) u8 {
        const ladder = [6]u16{ 0, 95, 135, 175, 215, 255 };
        var best: u8 = 0;
        var best_dist: u32 = std.math.maxInt(u32);
        for (ladder, 0..) |candidate, i| {
            const dist = if (candidate >= channel) candidate - channel else channel - candidate;
            if (dist < best_dist) {
                best_dist = dist;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Downgrade a color for terminals without truecolor. `.default` and
    /// `.index` pass through untouched; `.rgb` quantizes through `to256`.
    pub fn downgrade(color: Color) Color {
        return switch (color) {
            .default, .index => color,
            .rgb => |rgb| to256(rgb),
        };
    }

    test "rgbFromSpec" {
        const spec = "rgb:aaaa/bbbb/cccc";
        const actual = try rgbFromSpec(spec);
        switch (actual) {
            .rgb => |rgb| {
                try std.testing.expectEqual(0xAA, rgb[0]);
                try std.testing.expectEqual(0xBB, rgb[1]);
                try std.testing.expectEqual(0xCC, rgb[2]);
            },
            else => try std.testing.expect(false),
        }
    }

    test "to256 maps palette corners exactly" {
        // Pure primary channels hit cube corner indices.
        try std.testing.expectEqual(@as(u8, 16), indexValue(to256(.{ 0, 0, 0 })));
        try std.testing.expectEqual(@as(u8, 231), indexValue(to256(.{ 255, 255, 255 })));
        try std.testing.expectEqual(@as(u8, 196), indexValue(to256(.{ 255, 0, 0 })));
        try std.testing.expectEqual(@as(u8, 46), indexValue(to256(.{ 0, 255, 0 })));
        try std.testing.expectEqual(@as(u8, 21), indexValue(to256(.{ 0, 0, 255 })));
    }

    test "to256 prefers grayscale for near-achromatic colors" {
        // The vantari theme's dim border color (0x4a6a5c) is green-tinted
        // (max-min = 32 > 8), so it must land in the cube, not grayscale.
        const cube = to256(.{ 0x4a, 0x6a, 0x5c });
        try std.testing.expect(indexValue(cube) < 232);
        // A gray that the ramp represents exactly (89 ≈ ramp gray-88) must
        // land on the ramp; mid-gray 128 is nearer cube 102 and stays there.
        const gray = to256(.{ 0x59, 0x59, 0x59 });
        try std.testing.expect(indexValue(gray) >= 232);
        const cube_gray = to256(.{ 0x80, 0x80, 0x80 });
        try std.testing.expectEqual(@as(u8, 102), indexValue(cube_gray));
        // Pure white maps to the white end of the ramp (gray-238), which is
        // nearer than the cube's (255,255,255) corner only when equal — cube
        // white is exact, so white stays at 231.
        try std.testing.expectEqual(@as(u8, 231), indexValue(to256(.{ 255, 255, 255 })));
    }

    test "downgrade passes through non-rgb colors" {
        try std.testing.expectEqual(Color.default, downgrade(.default));
        const indexed = Color{ .index = 42 };
        try std.testing.expect(indexValue(downgrade(indexed)) == 42);
        switch (downgrade(.{ .rgb = .{ 255, 0, 0 } })) {
            .index => {},
            else => return error.TestUnexpectedResult,
        }
    }

    fn indexValue(color: Color) u8 {
        return switch (color) {
            .index => |idx| idx,
            else => 0,
        };
    }
};
