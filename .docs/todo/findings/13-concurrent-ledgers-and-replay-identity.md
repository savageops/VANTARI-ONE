---
type: finding
id: harness-finding-13
status: pending
priority: P0
owner: apps/backend/src/core/sessions
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Concurrent ledgers and replay identity

## Finding

Session summary mutation and per-session message append are now serialized and append-only. Stdio still drops stored event sequence before TUI replay, and the ledger readers do not yet share the complete byte-integrity contract. The remaining defect is consumer identity and common recovery, not message sequence allocation.

## Evidence

- Closed move 12: `summaries.zig` appends v2 revisions with stable sequence,
  projects the greatest sequence per session, isolates poisoned suffixes, and
  imports the v1 object once without retaining a fallback reader.
- Closed move 13: `store.zig` routes every message role through one per-session
  ledger state and initializes its cursor from the last valid bounded tail row.
- [protocol/types.zig:68](../../../apps/backend/src/shared/protocol/types.zig#L68) omits seq from SessionEventNotification.
- [tui_chat.zig:666](../../../apps/backend/src/clients/tui_chat.zig#L666) deduplicates by timestamp, type, and message.

## Required mechanism

Carry the exact stored event sequence and byte payload through one versioned protocol envelope; make all client cursors sequence-based. Reuse one prefix-salvage reader across session ledgers without replacing the append-only files or adding a database.

## Acceptance

- [x] 100 concurrent summary upserts retain the latest row for every session.
- [x] 100 concurrent message appends produce unique monotonic sequence values.
- [ ] Duplicate same-millisecond events with identical text all render once and only once.
- [ ] Torn suffix recovery preserves valid prefix state across all three ledgers.
- [x] Long-session append initialization is not proportional to total message count.

## Source and salvage

- [Eve](https://github.com/vercel/eve): durable indexed event streams.
- Existing VANTARI event tail-scan sequencer: reuse the proven primitive instead of adding a database.
- [OpenAI Codex rollout writer](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs): retain one serialized JSONL writer and ordered identity; reject its broader task/channel architecture here.
- [pi session manager](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts): retain append/replay simplicity; reject its unguarded single-process append as the concurrency owner.

## Partial closure proof

- 100 synchronized summary upserts retained 100 latest rows with unique sequences.
- 100 synchronized mixed-role message appends retained 100 rows with unique
  monotonic sequences; a 32,768-line poisoned-prefix fixture continued from the
  valid tail row without the removed full-transcript sequencer.
- The complete graph passes 1,931/1,931. Installed `session/send` wrote two
  contiguous unique message rows, source/installed SHA-256 match, and zero
  VANTARI processes remain.
- Packaged GGUF dupe audit: 37 segments and zero candidate or exact pairs across
  `store.zig` and `summaries.zig`.
- Finding remains pending for moves 14–17 and 20.

## Out of scope

Do not change transcript semantics or introduce a global session database.
