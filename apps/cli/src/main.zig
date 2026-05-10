const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const tui_chat = @import("tui_chat.zig");

pub fn main() !void {
    var probe = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer probe.deinit();
    _ = probe.next();
    if (probe.next() == null) {
        return tui_chat.main(std.heap.page_allocator);
    }

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    VAR1.clients.cli.main(std.heap.page_allocator, &args) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(2),
        else => return err,
    };
}

test "var cli package delegates to the kernel-owned client protocol surface" {
    try std.testing.expect(@hasDecl(VAR1.clients, "cli"));
}

test "var cli package can import the Vantari TUI module" {
    try std.testing.expect(@hasDecl(tui, "Window"));
    try std.testing.expect(@hasDecl(tui.widgets, "TextInput"));
}
