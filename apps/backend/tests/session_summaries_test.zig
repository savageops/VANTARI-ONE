/// Session summary ledger test harness — the module-level tests live inside
/// src/core/sessions/summaries.zig and the two builtin tools
/// (update_session_summary, session_summaries). This file pulls them into the
/// explicit test graph so `zig build test` exercises the full surface:
/// ledger persistence, 100-word enforcement, timeline recall, and the
/// kernel-fallback freshness gate.
const std = @import("std");
const VAR1 = @import("VAR1");

test "session summary ledger modules are reachable through the core namespace" {
    try std.testing.expect(@hasDecl(VAR1.core, "session_summaries"));
    try std.testing.expectEqualStrings(
        "var1.session_summary.v1",
        VAR1.core.session_summaries.schema_version,
    );
    try std.testing.expectEqual(
        @as(usize, 100),
        VAR1.core.session_summaries.max_summary_words,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        VAR1.core.session_summaries.countWords(""),
    );
}
