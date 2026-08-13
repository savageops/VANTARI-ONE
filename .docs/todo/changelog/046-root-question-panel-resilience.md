---
type: changelog
id: changelog/046-root-question-panel-resilience
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/tools/builtin/ask_user.zig; apps/backend/src/clients/question_view.zig; apps/backend/src/clients/tui_chat.zig
---

# Root question panel resilience

## Shipped in source

- `ask_user` now frees only initialized question-id and option slices. A late
  invalid question returns `InvalidArguments` without dereferencing unassigned
  memory; response serialization uses the same initialized-slice discipline.
- `question_view.State` now renders a compact settings-style list with one
  horizontal question row per visible question, keyboard focus for question and
  option, inline `Other`, and an explicit review/submit state.
- Cursor accesses are clamped and zero-sized/empty panel dimensions are safe.
  `orchestrate` and `align` share the exact controller and broker path.
- `tui_chat.zig` catches malformed `input_requested` payloads, reports one
  bounded system message, and cancels the waiting run without recursively
  re-entering progress replay.

## Evidence

- Focused TUI: `9/9` steps, `129/129` tests passed.
- Full Debug: `19/19` steps, `2,136/2,136` tests passed.
- Source ReleaseFast: `9/9` steps succeeded; source SHA-256
  `284E99A020F28E480AEF8B42E06E4C73A5CEE1820B383C010E167749D015EBD2`.
- Live installed promotion was not run by design.

## Reference and boundary

The interaction shape harvests oh-my-pi's normalization, clamped state, and
review boundary while preserving VANTARI's existing `ask_user`/event/broker/
RPC owners. No dialog framework, poller, mode branch, or second answer ledger
was added. Research: `.docs/research/2026-08-14-root-question-review-panel.md`.
