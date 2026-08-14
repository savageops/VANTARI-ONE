---
type: changelog
id: changelog/047-process-supervisor-move58
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/tools/process.zig; apps/backend/src/core/tools/builtin/eval.zig
---

# Canonical process supervisor for tool workers

## Shipped in source

- Moved bounded one-shot command execution into `core/tools/process.zig`, the
  shared owner used by `shell_exec` and persistent eval workers.
- Replaced eval's raw persistent child and local reader with
  `PersistentProcess`, including serialized writes, bounded newline reads,
  post-cap draining, timeout teardown, Windows Job Object handling, and cleanup
  receipts.
- Added `OUTPUT_TRUNCATED` and conditional `PROCESS_RECEIPT` output so abnormal
  worker termination is explainable without adding normal-turn log noise.
- Added adversarial coverage for timeout reaping, pipe draining, tree teardown,
  and oversized-response framing recovery.

## Evidence

- Debug `19/19`, `2,137/2,137`.
- Focused TUI `9/9`, `129/129`.
- Source ReleaseFast `9/9`.
- `dupe-audit`: zero duplicate or exact-duplicate candidates across the process
  owner, runtime, eval, and Windows process primitive.
- Installed promotion is intentionally deferred; no live installed owner or
  provider file was changed.

## Boundary

Timeout and session/host teardown are the supported persistent-worker
cancellation boundaries. A user-facing mid-read cancellation signal remains a
separate future seam and was not added to avoid a second cancellation path.
