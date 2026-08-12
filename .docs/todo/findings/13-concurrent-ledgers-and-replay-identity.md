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

Session summaries use whole-object last-writer-wins replacement, message sequence allocation reparses the full transcript without a per-session writer lock, and stdio drops the event sequence before TUI replay. These are three forms of the same defect: durable rows exist, but concurrent mutation and consumer identity do not have one serialized owner.

## Evidence

- [summaries.zig:120](../../../apps/backend/src/core/sessions/summaries.zig#L120) reads all rows and rewrites one JSON object.
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

## Out of scope

Do not change transcript semantics or introduce a global session database.
