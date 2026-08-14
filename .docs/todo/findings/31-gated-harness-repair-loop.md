---
type: finding
id: harness-finding-31
status: pending
priority: P2
owner: apps/backend/src/core
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Gated harness repair loop

## Finding

VANTARI has now closed the source path through approved application, but the
full repair loop remains open. Moves 71–76 provide deterministic failure
receipts, causal diagnosis, source-anchored candidates, operator approval, and
exact approved application through the existing reviewed writer. Moves 77–80
still own exact-input replay, invariant comparison, rollback, and regression
promotion.

## Required state machine

Failure receipt → deterministic causal diagnosis → candidate patch with baseline conflict check → explicit operator approval → isolated apply → exact original-input rerun → invariant comparison → regression lock and promote, or rollback with evidence.

Every transition persists an ID, input hash, source baseline hash, decision, effect receipt, evaluator result, and terminal state. Repair uses the existing tool runtime, tickets, sessions, and event spine. It does not create a parallel patcher or silent background mutator.

## Acceptance

- A captured failure reruns from the exact original input and configuration.
- No file changes before approval.
- Baseline drift blocks apply before mutation.
- An approved apply reaches `replace_in_file`, records the normal write intent,
  and retries do not repeat a committed mutation.
- A failed invariant rolls back and preserves both traces.
- A passing repair creates a durable regression case that fails on the old baseline and passes on the new one.
- Cold start resumes or reconciles every nonterminal repair state exactly once.

## Source and salvage

- User clipping: Your Agent Harness Should Repair Itself.
- [Opik](https://github.com/comet-ml/opik): trace, diagnosis, approved diff, rerun, regression.
- [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent): refinement snapshots, conflict detection, and rollback.

## Out of scope

Do not permit autonomous unapproved source mutation or call health telemetry self-repair.
