---
type: changelog
id: changelog/071-repair-apply-move76
status: source-complete
owner: apps/backend/src/host/stdio_rpc.zig + apps/backend/src/core/evaluation/events.zig
roadmap: "24-harness-capability-next-90.md#76"
---

# Approved repair application — Move 76

Move 76 closes the apply seam in the gated repair workflow.

## Shipped

- Added operator-only `repair/apply`.
- Bound application to the exact candidate and approval event sequences,
  candidate/approval IDs, operation, resolved target, patch hash, and source
  baseline.
- Required the candidate patch to be the exact `replace_in_file` JSON payload,
  including its `read_file` tag.
- Dispatched the existing reviewed `replace_in_file` path; no patcher or
  second write owner was added.
- Reused the existing file-inspection ledger, effect envelope, and
  reserve/commit write-intent ledger.
- Added `var1.repair_candidate_applied.v1` evidence and concurrent/retry
  idempotence through the applied receipt and committed intent identity.

## Proof

- Debug: `19/19` steps, `2,191/2,191` tests passed.
- ReleaseFast: `19/19` steps, `2,191/2,191` tests passed; source build `9/9`,
  SHA-256
  `E57D6491A7385BAF945CA6AA7938FA15CC5B971045A3A735950F8E10EB6EB2A2`.
- The host integration test proves one mutation, one intent pair, one applied
  receipt, and a no-op retry.
- Installed promotion remains intentionally deferred.

## Boundary

Moves 77–80 still own exact-input rerun, invariant evaluation, rollback, and
regression promotion. No autonomous unapproved source mutation is enabled.
