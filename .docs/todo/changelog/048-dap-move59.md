---
type: changelog
id: changelog/048-dap-move59
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/tools/builtin/dap.zig; apps/backend/src/core/tools/process.zig
---

# Session-owned DAP lifecycle

## Shipped in source

- Registered the DAP scaffold through the normal definition/catalog/dispatch
  path and kept review risk explicit per operation.
- Replaced the raw adapter child with the shared `PersistentProcess` owner.
- Added exact Content-Length framing with bounded body/frame caps, timeout
  teardown, and no next-frame consumption.
- Added one workspace-plus-session adapter registry covering attach, pause,
  stack trace, scopes, variables, continue, and detach.
- Added host teardown after request-worker join and a real Python stdio
  lifecycle regression test.

## Evidence

- Zig `0.15.1`: Debug `19/19`, `2,141/2,141`.
- `test-tui`: exit `0`; existing focused graph `9/9`, `130/130`.
- Source ReleaseFast: exit `0`; SHA-256
  `20D9B9001719F891DF984CAD480B0DFCB712E6197FAF27F6907CE8B205F97D8D`.
- GGUF audit: 89 segments, 2 semantic candidate pairs, 0 exact duplicate
  candidates across the four changed runtime files.
- No adapter child remains after the source test. Installed promotion is
  intentionally deferred.

## Boundary

No launch, breakpoint, evaluate, thread browser, durable debugger ledger, or
second DAP manager was added. Those require separate user evidence and are not
part of Move 59.
