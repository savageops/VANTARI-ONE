---
type: changelog
id: changelog/068-repair-candidate-baseline
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/tools/builtin/repair_candidate.zig
---

# Source-anchored repair candidates — Move 74

## Shipped in source

- The existing tool registry and runtime expose one proposal-only
  `repair_candidate` socket for the source repair loop.
- The tool resolves the target through the shared access-mode resolver,
  requires an existing inspected file, captures its before hash, hashes the
  exact operation/path/patch descriptor, and records one
  `var1.repair_candidate.v1` event in the existing `events.jsonl` spine.
- The event records expected/current source baselines and hashes, a ready or
  baseline-conflict status, and `mutation_allowed: false`. The patch body never
  enters the durable receipt and no write intent or file mutation occurs.
- A source-baseline mismatch returns typed `RepairBaselineConflict`; applying a
  later approved candidate remains the responsibility of existing reviewed
  write tools.

## Proof

- Full Debug: `19/19` steps, `2,182/2,182` tests.
- Full ReleaseFast: `19/19` steps, `2,182/2,182` tests.
- Source ReleaseFast build: `9/9` steps; SHA-256
  `E92BD7C72EBF06D2D6B43F0ECF85B90AD6E0C34605D72833B96CBD5F0B7BB0FD`.
- Runtime proof records both ready and baseline-conflict candidates, proves
  the target remains unchanged, and proves the raw patch body is absent from
  the durable candidate event.

## Boundary

This move records a source-anchored proposal and blocks drift before any
mutation. Approval, isolated application, exact replay, invariant comparison,
rollback, and regression promotion remain Moves 75–80.
