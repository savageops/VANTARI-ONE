const std = @import("std");

pub const types = @import("types.zig");
pub const events = @import("events.zig");

test "protocol namespace exposes wire types" {
    try std.testing.expect(@hasDecl(@This(), "types"));
    try std.testing.expect(@hasDecl(@This(), "events"));
}
