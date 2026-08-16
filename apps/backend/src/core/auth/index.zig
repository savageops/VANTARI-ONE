const std = @import("std");

pub const resolver = @import("resolver.zig");
pub const store = @import("store.zig");
pub const openai_codex = @import("openai_codex.zig");
pub const detect = @import("detect.zig");
pub const import = @import("import.zig");

test "auth namespace exposes resolver and store" {
    try std.testing.expect(@hasDecl(@This(), "resolver"));
    try std.testing.expect(@hasDecl(@This(), "store"));
    try std.testing.expect(@hasDecl(@This(), "openai_codex"));
    try std.testing.expect(@hasDecl(@This(), "detect"));
    try std.testing.expect(@hasDecl(@This(), "import"));
}
