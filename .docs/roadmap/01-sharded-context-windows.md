# 01 — Sharded Context Windows (The North Star)

**Priority: P0**

## The north star

> A harness that uses the least amount of tokens, where every message is a new context window, each window is a checkpoint (a "shard") of the parent chat, each step in the task process branches into its own context window, and all branches eventually converge and are reprocessed.

This is the single most important item in the pipeline. It is not a feature; it is the design constraint that every other item serves. It is the difference between "an agent that keeps a transcript" and "an agent whose memory *is* the architecture."

## What exists today

- **WAL + checkpoint compaction** (`apps/backend/src/core/context/compactor.zig`, `builder.zig`, `budget.zig`, `overflow.zig`).
- The transcript `messages.jsonl` is the append-only write-ahead log; `context.jsonl` holds structured summary checkpoints. Compaction never rewrites the transcript.
- Checkpoints carry `source_seq_start`, `source_seq_end`, `first_kept_seq`, `compacted_entry_count`, `aggressiveness_milli`.
- The context builder reads the latest checkpoint, prepends the summary, then appends raw messages from `first_kept_seq`.
- Overflow recovery detects provider overflow patterns and rebuilds once.

**Gap:** today's model is *one* window that compacts over time. The north star is *many* windows, each a shard, that branch and converge. The WAL+checkpoint primitive is the correct substrate — it is not yet the sharded product.

## What the competitor does (Eve)

Eve (`packages/eve/src/harness/compaction.ts`, `compaction-prompt.ts`) compacts **in-memory message arrays** produced by the AI SDK `ToolLoopAgent`. It does not have a durable shard ledger. Its compaction:

- Estimates tokens with a char-based heuristic (`estimateTokens`), tracked as `lastKnownInputTokens` on session state.
- Tries model-free heuristics first (`toolResultCapHeuristic` — caps oversized tool outputs), then falls back to LLM summarization with a `temperature: 0` call.
- Keeps a "recent window" verbatim, degrades to text-only, then shrinks the window under pressure.
- Re-injects a checkpoint marker (`"Summary of our conversation so far:"`) as a `user` message + summary as `assistant` message.
- Uses a `withResumptionGuard` to avoid ending on an assistant message (provider prefill rejection).
- **Limitation:** the "checkpoint" is a single in-memory summary string, notched into the message array. It cannot branch, cannot be a sub-shard, and is re-derived from scratch each compaction. There is no durable, replayable, addressable shard graph.

## Why VANTARI does it better

1. **Durable substrate.** VANTARI already has append-only `messages.jsonl` + structured `context.jsonl` checkpoints. Eve's checkpoint is a string in memory; VANTARI's is a typed, sequence-addressed ledger entry that survives cold start. The shard is the natural next projection of this ledger.
2. **Append-only, not rewrite.** Eve rebuilds the message array in memory on every compaction. VANTARI never rewrites the transcript; a shard is a *derived, read-only* projection. Multiple shards can reference the same source sequences without copying them.
3. **Addressable by sequence.** Eve's compaction is positional over an array. VANTARI's checkpoints are sequence-addressed (`source_seq_start/end`), so a shard is a concrete, replayable window over the ledger — exactly what cold-start replay needs.
4. **No tool-batch splitting.** VANTARI's compactor retracts a boundary that falls inside a tool-call sequence. Eve's `splitMessagesForCompaction` snaps tool results into the older region to avoid orphaned `tool_result` — but only because it is reconstructing a single array. VANTARI's invariant is structural and ledger-native.

### SHARDED MODEL (target)

```text
parent chat (messages.jsonl, append-only)
  │
  ├─ shard A  = checkpoint over [seq 0..40]  +  step 1 branch
  ├─ shard B  = checkpoint over [seq 0..40]  +  step 2 branch
  ├─ shard C  = checkpoint over [seq 0..40]  +  step 3 branch
  │
  └─ converge: merge A/B/C results → new checkpoint → parent continues
```

Each shard is:
- **A fresh context window** (least tokens — the window is exactly the checkpoint + one branch, never the whole history).
- **A checkpoint of the parent chat** (a typed `context.jsonl` entry, sequence-addressed).
- **A branch** (its own step's tool calls, deltas, and results).
- **Convergent** (results are merged into the parent and *reprocessed*).

## Pipeline items under this theme

### P0-1: Shard ledger primitive
- **Contract:** a `context.jsonl` entry type `shard_checkpoint` that references a parent checkpoint + branch sequence range + branch status (`open | converged | abandoned`).
- **Mechanism:** reuse the existing compactor's `buildPlan`/checkpoint writer; add a `parent_checkpoint_id` and `branch_seq` field. No new storage system.
- **Test:** a shard can be created, read back after cold start, and its parent can converge without rewriting the transcript.
- **Proof:** cold-start replay of a sharded session from repository state.

### P0-2: Branch-and-converge reprocessing loop
- **Contract:** the executor can (a) launch N branch shards from one parent checkpoint, (b) collect their `tool_completed`/`assistant_response` evidence, (c) merge into a new checkpoint, (d) reprocess the merge.
- **Mechanism:** map onto the existing executor loop + delegation tooling. A branch is a child session whose context is `parent checkpoint + branch input`; convergence is a parent checkpoint append.
- **Test:** a task with 3 parallel branches converges into one parent result; the merge is itself a new context window.
- **Proof:** session/event evidence of the full branch→merge→reprocess causal chain.

### P0-3: Shard garbage collection
- **Contract:** abandoned or converged branches are marked in the ledger, not deleted. The transcript remains the source of truth.
- **Mechanism:** tombstone status on `shard_checkpoint` entries; no storage copy.
- **Test:** convergence leaves the parent transcript byte-identical, only checkpoints are appended.

## North-star link
This is the north star. All other theme files exist to serve it: token-minimal compilation makes each shard as cheap as possible; the typed event grammar makes shards replayable; durable execution makes shards survive cold start; tool effect receipts make branch evidence trustworthy; delegation makes branches fan out; memory makes shard recall relevant.

## Definition of done
- Shards are durable, sequence-addressed, append-only checkpoints over the transcript.
- Each step can branch into its own context window and converge.
- Branch→merge→reprocess is proven with tests and session/event evidence.
- No second transcript, no parallel storage, no rewrite of `messages.jsonl`.