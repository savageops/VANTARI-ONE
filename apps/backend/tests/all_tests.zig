const VAR1 = @import("VAR1");
const std = @import("std");

test {
    _ = @import("agent_scale_test.zig");
    _ = @import("agent_registry_test.zig");
    _ = @import("agent_pipeline_deep_matrix_test.zig");
    _ = @import("auth_store_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("core_store_test.zig");
    _ = @import("prompts_test.zig");
    _ = @import("pipeline_matrix_test.zig");
    _ = @import("provider_test.zig");
    _ = @import("runtime_loop_test.zig");
    _ = @import("session_summaries_test.zig");
    _ = @import("tools_test.zig");
    _ = @import("user_flow_trellis_test.zig");
    _ = @import("web_test.zig");
    _ = @import("workspace_resolution_test.zig");
    std.testing.refAllDeclsRecursive(VAR1.clients.cli);
    std.testing.refAllDeclsRecursive(VAR1.core.auth_store);
    std.testing.refAllDeclsRecursive(VAR1.core.scheduler);
    std.testing.refAllDeclsRecursive(VAR1.host.stdio_rpc);
    std.testing.refAllDeclsRecursive(VAR1.core.tickets);
    // Value references force src-file tests into the suite (Zig 0.15: a file's
    // tests run only when the module value is referenced inside a test block).
    _ = VAR1.core.provider_pricing;
    _ = VAR1.core.provider_compat;
    _ = VAR1.core.turn_payload;
    _ = VAR1.core.config_file;
}
