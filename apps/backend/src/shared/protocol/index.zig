const std = @import("std");

pub const types = @import("types.zig");
pub const events = @import("events.zig");
pub const input = @import("input.zig");

test "protocol namespace exposes wire types" {
    try std.testing.expect(@hasDecl(@This(), "types"));
    try std.testing.expect(@hasDecl(@This(), "events"));
    try std.testing.expect(@hasDecl(@This(), "input"));
}
