const std = @import("std");

pub const cli = @import("cli.zig");

test "clients namespace exposes cli" {
    std.testing.refAllDeclsRecursive(cli);
    try std.testing.expect(@hasDecl(@This(), "cli"));
}
