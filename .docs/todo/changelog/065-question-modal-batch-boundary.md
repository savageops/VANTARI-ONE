---
type: changelog
id: changelog/065-question-modal-batch-boundary
status: source-complete
date: 2026-08-14
owner: apps/backend/src/clients/question_view.zig
---

# Question modal batch boundary

## Shipped in source

- The existing full-frame question modal rejects empty, oversized, wrong-kind,
  and wrong-schema request envelopes before they reach the renderer.
- Prompt and option display truncation now uses Vaxis cell width, preserving
  Unicode alignment while response ids remain exact.
- The maximum 60-question envelope survives live and review rendering at
  clipped 1/2/4-row and normal 20-row viewports, including the final active
  row.
- Normal and `orchestrate`/`build`/`align`/`plan` continue to share one modal,
  one controller, one broker, and one `input/respond` path.

## Proof

- Focused TUI Debug and ReleaseFast: `137/137` tests each.
- Full Debug: `19/19` steps, `2,178/2,178` tests.
- Source ReleaseFast: `9/9` steps; SHA-256
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion was not run; installed SHA remains
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Boundary

No second question UI, event bus, poller, answer ledger, or mode-specific
executor branch was introduced. Provider-driven installed response remains an
explicit follow-up after the preserved owner may be replaced.
