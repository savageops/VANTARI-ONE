## 088 — Ticket ledger single-pass scan + TUI streaming-path allocations

- **Commits**: `0bf9398` (single-parse tool deltas, question Down-confirm, palette Enter guard), `fb4036d` (ticket single-scan fold, gated delta wrap, frame-arena reasoning rows)
- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `169625c9c9aa796c` at `/usr/local/bin/vantari`

### Ticket store (`core/tickets/index.zig`)

Every mutation replayed the ledger 3–4× per call (idempotency scan →
projection read → both again inside append). One fold now:
`scanLedgerForKeyLocked` builds projection + `last_seq` + first key match in
one pass; `appendEventFromScan` consumes it. Preserved semantics: prefix-
preserving poison on projection reads vs abort-on-torn for key reads;
applyEvent failure stops projection but not key matching; empty key never
matches but projection still builds. Dead `idempotencyExistsLocked` and
`appendEventLocked` removed.

### TUI (`clients/tui_chat.zig`)

- `addAssistantDelta`: previous/next row-count wrap scans gated on
  `scroll_offset > 0`; pinned-bottom streaming appends without the
  O(text) scan per delta.
- Reasoning dock rows: per-frame alloc/deinit on the general allocator
  moved into the existing frame arena (rows borrow `dock_source`).

### Audit findings rejected with evidence

- `root.fill` per-frame memset: required immediate-mode clear; Vaxis diffs
  content (`InternalCell.eql`), not dirty flags — identical blanks skip.
- `InternalScreen` arena growth: bounded by `clearRetainingCapacity`
  retained per-cell capacity; grows only for longer graphemes.

### Verification

- Debug gate 19/19, 2,232/2,236 (4 platform skips)
- Live owner proof: `health/get` ticket buckets via single-scan projection
  (`tickets_assigned: 1`, `ticket_ledger_healthy: true`)
- TUI smoke on deployed binary: boot, settings cycle, scroll, clean exit
