# Task 12 — Binary-Safe Event Spine

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/12-binary-safe-event-spine.md`. This is a deep-research + web-research task. You must:

1. **Study the repo** — read `AGENTS.md` (sections IV, XIV, XVIII item 2 and item 14), `.docs/log.txt` (search for "event", "spine", "cursor", "sequence", "replay"), and the existing event/host code under `apps/backend/src/host/` and `apps/backend/src/shared/protocol/types.zig`.
2. **Study competitors** — `.refs/vercel__eve/` (event/telemetry shapes, `workflow-steps.ts`, `tool-loop.ts`), `.refs/openai__codex/` and `.refs/badlogic__pi-mono/` if present.
3. **Web research** — search for how modern agent runtimes (OpenAI Agents SDK, LangGraph, Temporal, Vercel AI SDK event shapes) handle durable event logs, binary-safe payloads, monotonic cursors, and torn-write recovery.
4. **Write the roadmap file** following the exact shape of the existing roadmap files (see `.docs/roadmap/01-sharded-context-windows.md` for the template).

## What this theme covers (from AGENTS.md Section XVIII items 2 and 14)

- **Binary-safe event spine:** store event payloads as canonical JSON plus optional base64 byte fields, stable sequence numbers, monotonic causal order, and replay cursors.
- **Byte-level session integrity:** JSONL append/read paths detect torn writes, BOMs, invalid UTF-8, duplicated sequence IDs, and poisoned trailing rows without corrupting valid prefix state.
- **Event cursors** use monotonic ledger position plus replay suppression. Timestamp-only cursors are insufficient under same-millisecond bursts (AGENTS.md Section IV).

## Competitor angles to research

- **Vercel Eve:** How does it persist events? Does it have a durable event log or just Temporal step history? What is the cursor model?
- **Temporal:** durable execution event sourcing — what can VANTARI borrow vs reject?
- **OpenAI Codex:** rollout/conversation persistence format.
- **SQLite WAL / LMDB / event-sourcing systems:** torn-write detection patterns.

## File shape to follow

```markdown
# 12 — Binary-Safe Event Spine

**Priority: P0**

## The seam
[What the event spine is, why binary safety matters]

## What exists today
[VANTARI's current event code — files, types, cursor model]

## What the competitor does
[Eve, Temporal, Codex — with file references]

## Why VANTARI does it better
[Mechanism + proof, not vibes]

## Pipeline items under this theme
### P0-XX: [item name]
- Contract / Mechanism / Test / Proof

## North-star link
[How this serves sharded context windows]

## Definition of done
```

## Reminders from .docs/log.txt

Read `.docs/log.txt` before writing. Search for entries mentioning "event", "cursor", "replay", "sequence", "jsonl", "poisoned", "torn write". The log has 442 entries of project history. Key themes: events (419 mentions), sessions (402).

## Output

Write ONLY `.docs/roadmap/12-binary-safe-event-spine.md`. Do not modify any source code. Do not modify the index yet — the orchestrator will do that after all 12 agents complete.
