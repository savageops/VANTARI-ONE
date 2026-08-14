---
type: changelog
id: changelog/067-repair-diagnosis-move73
status: source-complete
date: 2026-08-14
owner: apps/backend/src/shared/protocol/events.zig
---

# Deterministic causal diagnosis — Move 73

## Shipped in source

- Failed and timed-out `turn_terminal.failure` payloads carry one bounded
  `var1.repair_diagnosis.v1` record inside the existing terminal event.
- Normalized failure class and phase select a fixed invariant label. The
  diagnosis ID hashes the failure ID, invariant, and exact causal span.
- The span names `session_started.seq` as its start and `turn_terminal.seq` as
  its end. No free-form model diagnosis or separate telemetry stream is used.
- Completed and cancelled terminal payloads remain free of failure diagnosis.

## Proof

- Full Debug: `19/19` steps, `2,180/2,180` tests.
- Full ReleaseFast: `19/19` steps, `2,180/2,180` tests.
- Source ReleaseFast build: `9/9` steps; SHA-256
  `F0D19C0BE1E92EFD59986437731B2B96884CE81F7E8703137C45B0046E861137`.
- Protocol serialization proves deterministic repeated output and the fixed
  provider-transport invariant. Runtime failure proof verifies the persisted
  event span `1 -> 4`.

## Boundary

This move names the failed invariant and causal evidence span. It does not
generate a candidate patch, apply a mutation, request approval, rerun input,
compare treatment, rollback, or promote a regression; those remain Moves
74–80.
