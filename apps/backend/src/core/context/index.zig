const std = @import("std");

pub const builder = @import("builder.zig");
pub const budget = @import("budget.zig");
pub const compactor = @import("compactor.zig");
pub const overflow = @import("overflow.zig");
pub const shard_graph = @import("shard_graph.zig");
pub const embeddings = @import("embeddings.zig");
pub const semantic = @import("semantic.zig");
pub const stream_rules = @import("stream_rules.zig");

pub const appendProviderMessages = builder.appendProviderMessages;
pub const compactSession = compactor.compactSession;

test "context namespace exposes builder" {
    try std.testing.expect(@hasDecl(@This(), "builder"));
    try std.testing.expect(@hasDecl(@This(), "budget"));
    try std.testing.expect(@hasDecl(@This(), "compactor"));
    try std.testing.expect(@hasDecl(@This(), "overflow"));
    try std.testing.expect(@hasDecl(@This(), "embeddings"));
    try std.testing.expect(@hasDecl(@This(), "semantic"));
}
