---
type: changelog
id: changelog/064-failure-receipts-move71
status: source-complete
date: 2026-08-14
owner: apps/backend/src/shared/protocol/events.zig
---

# Failure receipts — Move 71

## Shipped in source

- Failed and timed-out `turn_terminal` events now carry one bounded
  `var1.failure_receipt.v1` payload with normalized class, phase, detail, and a
  deterministic `failure-<sha256>` identity.
- Session projection preserves the receipt ID through cold read.
- Scheduler terminal reconciliation writes the same ID into the ticket
  terminal receipt; stale-lease requeue derives it through the same normalized
  contract and remains idempotency-keyed.
- Completed and cancelled terminal events remain free of failure receipts.

## Proof

- Focused TUI Debug and ReleaseFast: `137/137` tests each.
- Full Debug: `19/19` steps, `2,178/2,178` tests.
- Source ReleaseFast: `9/9` steps; SHA-256
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion was not run; installed SHA remains
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Boundary

This move makes failure evidence stable and replayable. It does not claim the
future self-repair loop, patch approval, rollback, or live installed proof.
