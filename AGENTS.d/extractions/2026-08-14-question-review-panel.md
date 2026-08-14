---
type: extraction
date: 2026-08-14
source: user-message
status: applied
---

# Root question review panel

> “multiple choice questions in align mode or normal, when vantari does it, it
> crashes. we need something like the autocomplete popover. or better. to show
> all questions, basically like settings menu, same format/layout. each question
> horizontal and confirm at the end, see oh my pi”

## Why

Interactive question payloads are model-generated input at the TUI boundary.
They must fail into a visible, recoverable terminal state instead of unwinding
the renderer. A batch question is easier to answer when every row is visible,
options stay horizontal, and submission is an explicit review boundary.

## How to apply

- Keep `ask_user`, `input_requested`, `InputBroker`, and `input/respond` as the
  only protocol owners. Do not add a question poller, transcript copy, or mode
  branch.
- Render one settings-style row per question in `question_view.State`. Use
  Up/Down for question focus, Left/Right for option focus, Enter to select,
  Space to toggle multi-select, Tab/Shift+Tab to move rows, and a review state
  before submit.
- Clamp question and option cursors before every access. Bound row rendering to
  the viewport and keep inline `f / Other` input in the same panel. The frame
  projection must sanitize invalid UTF-8/control text, use static display keys,
  and preserve the original option ids in the response.
- Treat malformed `input_requested` data as recoverable client input. Show one
  bounded system message and cancel the waiting run through a direct RPC helper;
  do not propagate the parse error through event replay.
- Route both idle-loop and streaming-turn key events through one
  `ChatState.handleQuestionKey` boundary. Contain controller and
  `input/respond` failures so a recoverable question error cannot unwind the
  TUI process; keep the panel available for retry or explicit cancellation.
- Keep prompt modes behavioral only. `orchestrate` and `align` use the same
  question controller and broker path.

## Proof gate

Graduate this extraction only after focused TUI, full Debug, and source
ReleaseFast lanes pass. Installed provider-driven question response remains a
separate consumer probe.
