---
type: research
id: research/2026-08-14-question-modal-batch-boundary
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/clients/question_view.zig
---

# Question modal batch boundary

## Objective

Keep model-issued multiple-choice input compact and recoverable in normal and
`align` turns. The operator gets one settings-style frame, horizontal question
rows, and one final review/submit boundary.

## Reference pressure

- `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/ask-dialog.ts`
  normalizes untrusted question entries, clamps active state, and keeps a
  dedicated review/Submit state.
- `.refs/can1357__oh-my-pi/packages/tui/src/components/select-list.ts` bounds
  visible rows and selection before drawing.
- `.refs/badlogic__pi-mono/packages/coding-agent/examples/extensions/questionnaire.ts`
  keeps related questions in one answer surface with one final submit.

VANTARI keeps the same compression decision: reuse
`ask_user -> input_requested -> InputBroker -> question_view.State ->
input/respond`. No second dialog owner, poller, answer ledger, or prompt-mode
branch is justified.

## Applied slice

- Reject empty or over-`max_serialized_bytes` request payloads before JSON
  parsing; require the existing input schema and `question` kind.
- Truncate prompts and options by Vaxis terminal-cell width, not UTF-8 byte or
  codepoint count. Original option ids remain unchanged in the response.
- Exercise the maximum 60-question batch at 1, 2, 4, and 20 rows in both live
  and review states. The active tail row is rendered after viewport scrolling.
- Keep the complete modal frame and shared controller for `orchestrate`,
  `build`, `align`, `plan`, and root normal catalog use.

## State machine

```text
input_requested
  -> bounded full-frame question modal
  -> horizontal row/option navigation
  -> review/submit
  -> input/respond
  -> terminal event clears the projection
```

## Evidence

- Focused TUI Debug: `9/9` steps, `137/137` tests.
- Focused TUI ReleaseFast: `9/9` steps, `137/137` tests.
- Full Debug: `19/19` steps, `2,178/2,178` tests.
- Source ReleaseFast: `9/9` steps; source SHA-256
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion remains deferred. The preserved installed owner remains
  on SHA-256
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Residual boundary

The source renderer and protocol envelope are covered. A provider-issued
question response through the installed TUI still requires explicit promotion
of the preserved installed owner; no live claim is made here.
