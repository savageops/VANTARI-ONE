const std = @import("std");
const VAR1 = @import("VAR1");
const tui = @import("tui");
const tui_chat = @import("clients/tui_chat.zig");

pub fn main() !void {
    var probe = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer probe.deinit();
    _ = probe.next(); // skip exe path
    const first_arg = probe.next();
    if (first_arg == null) {
        return runTui(.blank);
    }
    if (std.mem.eql(u8, first_arg.?, "-c") or std.mem.eql(u8, first_arg.?, "--continue")) {
        if (probe.next() != null) {
            std.process.exit(2);
        }
        return runTui(.continue_latest);
    }

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    VAR1.clients.cli.main(std.heap.page_allocator, &args) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(2),
        else => return err,
    };
}

fn runTui(mode: tui_chat.StartupMode) !void {
    switch (mode) {
        .blank => tui_chat.main(std.heap.page_allocator) catch |err| {
            tui_chat.writeStartupFailure(std.heap.page_allocator, err) catch {};
            std.process.exit(1);
        },
        .continue_latest => tui_chat.mainContinueLatest(std.heap.page_allocator) catch |err| {
            tui_chat.writeStartupFailure(std.heap.page_allocator, err) catch {};
            std.process.exit(1);
        },
    }
}

test "merged binary delegates subcommands to the kernel-owned client protocol surface" {
    try std.testing.expect(@hasDecl(VAR1.clients, "cli"));
}

test "merged binary can import the Vantari TUI module" {
    try std.testing.expect(@hasDecl(tui, "Window"));
    try std.testing.expect(@hasDecl(tui.widgets, "TextInput"));
}

test "merged binary exposes latest-session TUI continuation entrypoint" {
    try std.testing.expect(@hasDecl(tui_chat, "mainContinueLatest"));
}

test "merged binary maps bare TUI startup failures into a typed envelope" {
    const rendered = try tui_chat.renderStartupFailure(std.testing.allocator, error.InvalidHandle);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "VAR1_ERROR category=tui") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "TerminalUnavailable") != null);
}
