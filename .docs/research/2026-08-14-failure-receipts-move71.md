---
type: research
id: research/2026-08-14-failure-receipts-move71
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/shared/protocol/events.zig
---

# Failure receipts — Move 71

## Objective

Give terminal sessions and ticket recovery one deterministic failure identity
without creating a second repair ledger or changing the append-only event
spine.

## Reference pressure

- `.refs/openai__codex` keeps failure state in the typed item/turn lifecycle
  and preserves permanent authentication failures as explicit operator
  evidence.
- `.refs/badlogic__pi-mono` carries provider error detail with the assistant
  error boundary instead of hiding it in an untyped log line.
- `.refs/nullclaw-main` normalizes user-facing failure classes before they
  cross the runtime boundary.

VANTARI keeps the smaller invariant: embed one bounded receipt in the existing
`turn_terminal` event and project its ID into the existing session and ticket
records. No repair queue, diagnosis store, or new event bus is justified by
this move.

## Applied slice

- `var1.failure_receipt.v1` carries `failure_id`, normalized class and phase,
  and bounded detail for failed and timed-out terminal turns.
- The ID is deterministic for the subject, run sequence, class, phase, and
  bounded detail. Completed and cancelled turns do not receive a failure
  receipt.
- Session cold projection retains the receipt ID. Scheduler terminal
  reconciliation copies the same ID into the ticket terminal receipt.
- Expired-ticket requeue uses the same normalization and deterministic ID
  owner, so replaying the idempotency key cannot create a second failure
  identity.

## State machine

```text
failure outcome
  -> normalize class/phase/detail
  -> deterministic failure receipt
  -> turn_terminal
  -> session projection + ticket terminal receipt
  -> cold replay / idempotent recovery
```

## Evidence

- Focused TUI Debug: `9/9` steps, `137/137` tests.
- Focused TUI ReleaseFast: `9/9` steps, `137/137` tests.
- Full Debug: `19/19` steps, `2,178/2,178` tests.
- Source ReleaseFast: `9/9` steps; source SHA-256
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion remains deferred. The preserved installed owner remains
  on SHA-256
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Residual boundary

The receipt is evidence, not an autonomous repair loop. Diagnosis, approval,
exact replay, regression comparison, rollback, and promotion remain later
gated moves.
