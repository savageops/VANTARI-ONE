const VAR1 = @import("VAR1");
const std = @import("std");

test {
    _ = @import("agent_pipeline_deep_matrix_test.zig");
    _ = @import("auth_store_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("core_store_test.zig");
    _ = @import("prompts_test.zig");
    _ = @import("pipeline_matrix_test.zig");
    _ = @import("provider_test.zig");
    _ = @import("runtime_loop_test.zig");
    _ = @import("tools_test.zig");
    _ = @import("user_flow_trellis_test.zig");
    _ = @import("web_test.zig");
    _ = @import("workspace_resolution_test.zig");
    std.testing.refAllDeclsRecursive(VAR1.clients.cli);
    std.testing.refAllDeclsRecursive(VAR1.core.auth_store);
    std.testing.refAllDeclsRecursive(VAR1.host.stdio_rpc);
}
