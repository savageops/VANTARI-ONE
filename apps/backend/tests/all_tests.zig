const VAR1 = @import("VAR1");
const std = @import("std");

test {
    _ = @import("cli_test.zig");
    _ = @import("core_store_test.zig");
    _ = @import("prompts_test.zig");
    _ = @import("pipeline_matrix_test.zig");
    _ = @import("runtime_loop_test.zig");
    _ = @import("tools_test.zig");
    _ = @import("web_test.zig");
    std.testing.refAllDeclsRecursive(VAR1.host.stdio_rpc);
}
