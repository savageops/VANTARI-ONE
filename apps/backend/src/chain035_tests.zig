const std = @import("std");
const config_file = @import("core/config/file.zig");
const compat = @import("core/providers/compat.zig");
const pricing = @import("core/providers/pricing.zig");
const turn_payload = @import("core/executor/turn_payload.zig");
const auth_openai_codex = @import("core/auth/openai_codex.zig");

// Wire src-file tests into the suite. Zig 0.15 runs a file's tests only when
// the module value is referenced inside a test block of the ROOT module's own
// file tree (files in external `-M` modules never contribute tests). This
// src-rooted harness references the chain-035 modules so their tests execute
// in a dedicated test binary (same pattern as memory_tests.zig).
test {
    _ = config_file;
    _ = compat;
    _ = pricing;
    _ = turn_payload;
    _ = auth_openai_codex;
}
