---
type: changelog
id: changelog/066-repair-receipts-move72
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/evaluation/events.zig
---

# Immutable replay receipts — Move 72

## Shipped in source

- Each admitted root turn appends one `var1.repair_receipt.v1` event to the
  existing `events.jsonl` ledger before context compilation or provider
  dispatch.
- The receipt retains the exact original input and selected model, marks the
  replay input immutable, and records SHA-256 values for the effective config,
  canonical tool catalog, tracked environment, and source baseline.
- The source baseline is `git:<commit>` when Git is available and
  `unavailable` otherwise. Raw config, tool catalog, and environment snapshots
  are transient and are not persisted.

## Proof

- Full Debug: `19/19` steps, `2,180/2,180` tests.
- Full ReleaseFast: `19/19` steps, `2,180/2,180` tests.
- Source ReleaseFast build: `9/9` steps; SHA-256
  `8E15F5ED22631B232EFF2F5FE2FF1E6B336250D22C61E0313645A6BEAB256639`.
- The receipt regression persists exact input/model and proves an API-key-like
  value in a transient config snapshot is absent from the durable event.

## Boundary

This move records the immutable replay boundary. It does not implement
diagnosis, candidate patching, operator approval, mutation, exact rerun,
comparison, rollback, or installed promotion; those remain Moves 73–80.
