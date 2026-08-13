---
type: changelog
id: changelog/044-persistent-eval-kernels
status: source-complete
date: 2026-08-13
owner: apps/backend/src/core/tools/builtin/eval.zig
---

# Persistent Python and Bun eval kernels

## Shipped in source

- Moves 56–57 now use one process-local kernel registry keyed by workspace and
  session. Python and Bun JavaScript preserve state across calls and isolate
  state across sessions.
- Both workers use the same bounded newline protocol, response reader, output
  cap, timeout termination, and host teardown path. Bun uses `bun.exe` on
  Windows so the runtime does not spawn the package-manager wrapper.
- `ToolDefinition.availability` owns Python plus the platform-correct Bun
  alternative. The capability registry probes all declared alternatives and
  exposes them in the JSON catalog.
- Trusted eval remains gated by `runtime.full_access_mode=true`; no OS sandbox
  claim is made.

## Evidence

- `scripts/zigw.ps1 build test --summary all` — Debug `19/19` steps,
  `2,121/2,121` tests passed.
- The eval component covers Python persistence, Bun persistence, timeout
  termination, cross-session isolation, bounded output, and definition-owned
  availability.
- The source ReleaseFast graph was rebuilt successfully; live installed
  promotion and installed process evidence are intentionally deferred.

## Boundary

Move 58 still routes worker lifecycle through the canonical process supervisor
for shared pipe drain, cancellation, and process-tree receipts. Anthropic and
OpenCode OAuth remain provider/auth parity gaps. Runtime theme and menu-position
settings remain deferred until the renderer has a consuming typed owner.
