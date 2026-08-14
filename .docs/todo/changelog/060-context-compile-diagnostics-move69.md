---
type: changelog
id: changelog/060-context-compile-diagnostics-move69
status: source-complete
updated: 2026-08-14
owner: apps/backend/src/core/context/builder.zig + apps/backend/src/core/executor/loop.zig + apps/backend/src/shared/protocol/events.zig + apps/backend/src/clients/tui_chat.zig
---

# Move 69 — typed context-compile diagnostics

The context compiler now returns a per-build repair report. Interrupted tool
calls are counted when synthesized, and orphan/missing-id/mismatched tool rows
are counted when skipped. The executor emits one typed
`var1.context_compile_diagnostic.v1` event through the existing event spine
when either count is nonzero.

Provider overflow continues to compact, rebuild through the context compiler,
and retry once. No executor-local durable tool batch is replayed into the retry
payload. The TUI keeps the diagnostic out of silent/normal chat and renders a
compact count only in full logs.

Proof: Debug `19/19`, `2,163/2,163`; source ReleaseFast `9/9`; source SHA-256
`898CAF97FD90F14B0FF3C202887467F7FFDDAC670583BEFB8B4491C2F6909DD6`.
Installed promotion is deferred by policy.
