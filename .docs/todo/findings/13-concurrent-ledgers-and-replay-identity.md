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

Session summary mutation is now serialized and append-only. Message sequence allocation still reparses the full transcript without a per-session state owner, and stdio still drops the event sequence before TUI replay. The remaining defect is the same: durable rows exist, but message mutation and consumer identity do not yet share one exact sequence owner.

## Evidence

- Closed move 12: `summaries.zig` appends v2 revisions with stable sequence,
  projects the greatest sequence per session, isolates poisoned suffixes, and
  imports the v1 object once without retaining a fallback reader.
- [store.zig:1623](../../../apps/backend/src/core/sessions/store.zig#L1623) reparses all messages to find the next sequence.
- [protocol/types.zig:68](../../../apps/backend/src/shared/protocol/types.zig#L68) omits seq from SessionEventNotification.
- [tui_chat.zig:666](../../../apps/backend/src/clients/tui_chat.zig#L666) deduplicates by timestamp, type, and message.

## Required mechanism

Use append-only summaries.jsonl with stable row sequence and latest-row projection. Give messages.jsonl one per-session append lock and tail-initialized sequencer. Carry the exact stored event sequence and byte payload through one versioned protocol envelope; make all client cursors sequence-based.

## Acceptance

- 100 concurrent summary upserts retain the latest row for every session.
- 100 concurrent message appends produce unique monotonic sequence values.
- Duplicate same-millisecond events with identical text all render once and only once.
- Torn suffix recovery preserves valid prefix state across all three ledgers.
- Long-session append time is not proportional to total message count.

## Source and salvage

- [Eve](https://github.com/vercel/eve): durable indexed event streams.
- Existing VANTARI event tail-scan sequencer: reuse the proven primitive instead of adding a database.
- [OpenAI Codex rollout writer](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs): retain one serialized JSONL writer and ordered identity; reject its broader task/channel architecture here.
- [pi session manager](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/session-manager.ts): retain append/replay simplicity; reject its unguarded single-process append as the concurrency owner.

## Partial closure proof

- 100 synchronized summary upserts retained 100 latest rows with unique sequences.
- V1 import, two-revision projection, poisoned-suffix continuation, and shared
  JSONL tail repair pass in the 1,929-test graph.
- Packaged GGUF dupe audit: 42 segments, zero candidate pairs, zero exact pairs
  across `summaries.zig`, `store.zig`, and `fsutil.zig`.
- Finding remains pending for moves 13–17 and 20.

## Out of scope

Do not change transcript semantics or introduce a global session database.
