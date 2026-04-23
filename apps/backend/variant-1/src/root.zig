const std = @import("std");

// TODO: Keep root exports narrow and readable so the harness stays easy to audit.
pub const types = @import("types.zig");
pub const fsutil = @import("fsutil.zig");
pub const config = @import("config.zig");
pub const store = @import("store.zig");
pub const docs_sync = @import("docs_sync.zig");
pub const provider = @import("provider.zig");
pub const harness_tools = @import("harness_tools.zig");
pub const tools = @import("tools.zig");
pub const loop = @import("loop.zig");
pub const agents = @import("agents.zig");
pub const protocol_types = @import("protocol_types.zig");
pub const stdio_rpc = @import("stdio_rpc.zig");
pub const web = @import("web.zig");
pub const cli = @import("cli.zig");

test "root exports scaffold" {
    try std.testing.expect(@hasDecl(@This(), "config"));
    try std.testing.expect(@hasDecl(@This(), "loop"));
}

test {
    _ = @import("provider.zig");
}
