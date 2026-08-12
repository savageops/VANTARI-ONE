const std = @import("std");

pub const http_bridge = @import("http_bridge.zig");
pub const bridge_access = @import("bridge_access.zig");
pub const owner_state = @import("owner_state.zig");
pub const owner_client = @import("owner_client.zig");
pub const stdio_client = @import("stdio_client.zig");
pub const stdio_rpc = @import("stdio_rpc.zig");
pub const stdio_wire = @import("stdio_wire.zig");

test "host namespace exposes transport adapters" {
    try std.testing.expect(@hasDecl(@This(), "http_bridge"));
    try std.testing.expect(@hasDecl(@This(), "bridge_access"));
    try std.testing.expect(@hasDecl(@This(), "owner_state"));
    try std.testing.expect(@hasDecl(@This(), "owner_client"));
    try std.testing.expect(@hasDecl(@This(), "stdio_client"));
    try std.testing.expect(@hasDecl(@This(), "stdio_rpc"));
    try std.testing.expect(@hasDecl(@This(), "stdio_wire"));
}
