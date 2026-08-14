---
type: changelog
id: changelog/072-repair-rerun-move77
status: source-complete
owner: apps/backend/src/host/stdio_rpc.zig + apps/backend/src/core/executor/loop.zig
roadmap: "24-harness-capability-next-90.md#77"
---

# Exact repair replay — Move 77

Move 77 closes the exact-input treatment seam after approved application.

## Shipped

- Added operator-only `repair/rerun` with deterministic source-receipt and
  applied-event identity.
- Required a valid immutable repair receipt and a later applied receipt before
  treatment admission.
- Created a fresh child session linked to the source through
  `continued_from_session_id`, preserving the source access scope without
  copying transcript rows.
- Reused the existing `session/send` and executor/provider path with the
  recorded model, provider identity, prompt mode, and exact input.
- Added pre-dispatch input/config hash gates. Mismatch records a failed child
  and never emits `turn_started` or provider I/O.
- Added append-only `repair_rerun_started`/`repair_rerun_completed` relationship
  receipts, completed-rerun idempotence, and an explicit in-progress boundary.

## Proof

- Debug: `19/19` steps, `2,193/2,193` tests passed.
- ReleaseFast: `19/19` steps, `2,193/2,193` tests passed; source build `9/9`,
  SHA-256
  `EF77BFE3144819008B027ADDB0EF66A945A0CD0CA33CC9FA76629E77E03EB07A`.
- Host tests prove changed-config rejection before provider dispatch and a
  matching exact replay through the normal provider lane.
- Installed promotion remains intentionally deferred.

## Boundary

Moves 78–80 still own machine-readable invariant comparison, rollback, and
regression promotion/cold-start repair reconciliation. No background mutator or
second repair ledger was added.
