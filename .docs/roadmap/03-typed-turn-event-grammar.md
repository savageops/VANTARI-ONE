# 03 — Typed Turn / Event Grammar

**Priority: P0**

## The seam

The event spine (`events.jsonl`) is the runtime's nervous system. Shards need replayable causality: an observer must be able to reconstruct a branch's full causal chain from the ledger after cold start. String breadcrumbs are legacy read models; new behavior uses versioned typed events.

## What exists today

- Typed events exist: `turn_started`, `session_started`, `assistant_delta`, `assistant_response`, `tool_requested`, `tool_reviewed`, `tool_started`, `tool_output_delta`, `tool_finished`, `tool_completed`, `tool_blocked`, cancellation, failure.
- Event cursors use monotonic ledger position + replay suppression (AGENTS.md §IV).
- Audit + evaluation consume the spine.

## What the competitor does (Eve)

Eve (`packages/eve/src/execution/workflow-steps.ts`, `turn-workflow.ts`, `harness/emission.ts`) has a rich typed event protocol (`#protocol/message.js`): `step.started`, `turn-finished`, `stream events`, `action.result`, `compaction.requested`, `compaction.completed`, `session waiting`, etc. Key strengths:

- **Durable step boundary.** `turnStep` is a `"use step"` — the workflow runtime commits session state atomically at each step boundary, so a crash mid-step resumes from committed state.
- **Turn-owned cancellation.** Cancel settles as `turn.cancelled → session.waiting`, never as a failure.
- **Stamped message stream events.** `stampMessageStreamEvent` assigns durable ids to persisted chunks.

**Limitation:** Eve's event model is built around the AI SDK's `ToolLoopAgent` stream and Temporal workflow steps. It is rich but it models a *single turn's* execution, not a shard's branch-and-converge topology. There is no `shard_started`, `shard_converged`, or branch-parent event edge.

## Why VANTARI does it better

1. **Monotonic ledger replay, not timestamps.** VANTARI's event cursor is monotonic ledger position + replay suppression. AGENTS.md forbids timestamp-only cursors (same-millisecond bursts). Eve's `stampMessageStreamEvent` uses durable ids but the ordering model is Temporal's, not a monotonic ledger the client can replay.
2. **Shard edge is a first-class event.** VANTARI's grammar can add `branch_started`/`branch_converged` as typed events on the same spine, so branch causality is replayable like any other event. Eve has no such edge.
3. **Tool spans are one keyed row.** VANTARI updates a single keyed tool row per invocation in clients; it does not append request/start/done rows. This is the "tool span" contract the AGENTS.md roadmap calls for — and it is the natural precursor to branch spans.

## Pipeline items under this theme

### P0-3a: Close the grammar (loop seam isolation)
- **Contract:** `loop.zig` is reduced around the four-phase turn body; `turn_started`, `assistant_delta`, `turn_failed`, cancellation reconciliation, and `tool_requested` are closed with replay tests.
- **Mechanism:** the executor emits each typed event in the correct phase; the event grammar is the sole contract between kernel and clients.
- **Test:** an adversarial suite replays a full turn from `events.jsonl` and reconstructs the exact causal chain (turn → deltas → tool_requested → tool_completed → turn_finished).
- **Proof:** `events.jsonl` replay after cold start reproduces the client-visible sequence.

### P0-3b: Branch events
- **Contract:** `branch_started` (parent checkpoint id + branch id + branch input), `branch_converged` (parent checkpoint id + branch results).
- **Mechanism:** extends the shard ledger primitive (theme 01); branch events reference the same checkpoint ids.
- **Test:** a branch's events replay to the exact parent checkpoint it derived from.
- **Proof:** session/event evidence of the full branch→merge→reprocess chain.

### P0-3c: Tool span completeness
- **Contract:** every tool call gets start/end timestamps, duration, risk decision, capability owner, output caps, side-effect summary, failure class (AGENTS.md roadmap item 3).
- **Mechanism:** the tool span is one keyed row in the event spine; the review gate decision is part of the span.
- **Test:** a tool that fails mid-execution records the failure class and the side-effect evidence; nothing is silent.
- **Proof:** effect receipt + event span replay together reconstruct the tool's full lifecycle.

## North-star link
A shard is replayable only if its causality is reconstructible from the ledger. The typed event grammar is the replay contract. Without it, branches cannot be audited, merged, or reprocessed with confidence.

## Definition of done
- Full turn grammar closed with replay tests.
- Branch events can be replayed to their source checkpoint.
- Every tool call is a complete span with failure class and evidence.