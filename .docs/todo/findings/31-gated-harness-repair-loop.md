---
type: finding
id: harness-finding-31
status: closed
priority: P2
owner: apps/backend/src/core
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Retired repair/replay control plane

## Finding

The Move 72–80 self-repair and replay chain was removed in the 2026-08-14
YAGNI pass. It spread one optional workflow across evaluation, host RPC, tool
catalog, protocol types, ticket closure, and cold-start reconciliation without
a current consumer or installed promotion proof.

## Decision

Delete the proposal, approval, apply, rerun, evaluation, rollback, regression,
and repair-specific ticket closure paths. Keep the canonical session transcript,
typed terminal/failure evidence, review gate, write-intent ledger, and normal
session/provider lane. Historical research and changelog files remain as
provenance; they are not active runtime contracts.

## Reopen gate

Reopen only after a fresh owner map identifies a concrete user capability gap,
a single reusable owner, and a proof plan that beats the removed mechanism on
usefulness per line of code. No autonomous source mutation or hidden retry.

Retirement proof: research/2026-08-14-yagni-repair-replay-retirement.md.
