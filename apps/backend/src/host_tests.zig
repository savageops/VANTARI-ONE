const stdio_client = @import("host/stdio_client.zig");
const stdio_rpc = @import("host/stdio_rpc.zig");
const process_tree = @import("shared/process_tree.zig");

// Zig 0.15 excludes tests in external modules. Keep host lifetime, RPC, and
// process-tree tests in one source-rooted artifact so the canonical build graph
// executes them instead of merely compiling their owners.
test {
    _ = stdio_client;
    _ = stdio_rpc;
    _ = process_tree;
}
