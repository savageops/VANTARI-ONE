# 07 — Deterministic Memory

**Priority: P1**

## The seam

Memory must stay smaller than the transcript. In the sharded model, memory is what makes a branch's recall *relevant*: a branch knows which parent facts apply without pulling the whole parent transcript. Memory is a compact, source-linked projection of facts, decisions, preferences, invariants, and lessons.

## What exists today

- Two scopes: session `memories.jsonl` (typed, append-only, cannot escape session) + global `memories/memories.md` (human-readable bullets with embedded machine metadata).
- No embeddings, no vector store, no background consolidator. Recall is rebuilt at cold start and bounded by the `memory` policy.
- Deterministic lexical relevance for global entries; session entries considered first.
- Append-only with tombstones; stable topic key makes update = append-replacement, forget = append-tombstone.
- `memory_read` / `memory_write` tools; humans can say "remember this globally" / "forget the memory about X".
- Secrets and transcript-shaped payloads rejected.

## What the competitor does (Eve)

Eve's memory is minimal — it uses the AI SDK with a **system prompt** and dynamic instructions, not a dedicated memory ledger. Its durable context is the conversation history + compaction checkpoint. It does not have a deployable memory store.

## What the competitor does (the memory harvest — 2026-07-15)

The research file already maps 9 systems. The strongest references:

- **Claude Code:** project auto-memory in `~/.claude/projects/<project>/memory/`, plain Markdown `MEMORY.md` index + topic files, agent-decided writes. Rejected: prefix injection without claim-level provenance.
- **OpenAI Codex:** foreground extraction + async consolidation with leases, watermarks, heartbeat, redaction. Rejected: background machinery before direct memory proves value.
- **Cursor:** project-scoped memories, sidecar extraction, approval for background candidates. Rejected: opaque schema/ranking.
- **Aider:** graph-ranked repository map under a strict token budget. Note: this is retrieval context, not semantic memory, but its *token budget discipline* is a useful north-star pattern.

## Why VANTARI does it better

1. **One typed model, two scopes.** VANTARI's memory is one append-only model across exactly two scopes. No vector service, no database, no hidden ranking model, no second transcript. This is the compression test: fewer concepts at the call site, stronger guarantees in the core.
2. **Deterministic, no background machinery.** VANTARI proves capture, scope, update, forget, recall, budgeting, evidence, and cold-start reconstruction *before* any automation is allowed to grow. Codex's background consolidation is rejected until it earns its lifecycle.
3. **Source-linked provenance.** Every mutation records its trigger, source session, and transcript sequence. Claude's auto-memory lacks claim-level provenance; VANTARI's is append-only with the source edge.
4. **Memory under the transcript, always.** In the sharded model, memory is a *projection* that never outranks the current user, live code, or runtime evidence. A branch pulls only relevant memory, not the parent transcript.

## Pipeline items under this theme

### P1-7a: Shard-scoped memory recall
- **Contract:** a branch's recall considers the parent checkpoint's memory plus the branch's own session memory, under the same deterministic relevance rule.
- **Mechanism:** the branch's memory projection reads the parent checkpoint summary + branch `memories.jsonl`; the source edge is the checkpoint id.
- **Test:** a branch recalls a parent-session fact without reading the parent transcript; the projection is a bounded, deterministic set.
- **Proof:** the branch's memory projection is replayed from cold start.

### P1-7b: Memory budget under token pressure
- **Contract:** memory recall is bounded by the `memory` policy; the projection reports its token cost on the event spine.
- **Mechanism:** reuse the token telemetry from theme 02; memory is a bounded projection with a measured cost.
- **Test:** a memory projection that exceeds the policy budget is rejected with a typed error, not silently truncated.
- **Proof:** the rejection is a typed event with the policy boundary as evidence.

## North-star link
Each shard is a fresh context window. Memory is what makes a shard's window *relevant* without pulling the whole parent. Deterministic, bounded, source-linked memory is the recall layer of the sharded model.

## Definition of done
- Branch recall considers parent checkpoint + branch memory, deterministically.
- Memory projection is token-bounded and reports its cost.
- No vector service, no background consolidator added.