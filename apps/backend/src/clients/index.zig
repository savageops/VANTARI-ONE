const std = @import("std");

pub const cli = @import("cli.zig");
pub const cli_auth = @import("cli_auth.zig");

test "clients namespace exposes cli" {
    std.testing.refAllDeclsRecursive(cli);
    std.testing.refAllDeclsRecursive(cli_auth);
    try std.testing.expect(@hasDecl(@This(), "cli"));
    try std.testing.expect(@hasDecl(@This(), "cli_auth"));
}
