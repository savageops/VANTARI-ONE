---
type: changelog
id: changelog/063-question-modal-frame
status: source-complete
date: 2026-08-14
owner: apps/backend/src/clients/{question_view,tui_chat}.zig
---

# Full-frame question modal

## Change

Moved the existing `ask_user` projection out of the shared footer layout and
gave it one complete Vaxis frame, matching the settings-style interaction
shape requested by the operator and harvested from oh-my-pi. The controller,
broker, request schema, and `input/respond` path remain unchanged.

Multi-select Enter/Space now toggles without advancing to another question.
The final review state remains the only submit boundary, and deselecting
`f / Other` clears its custom text before serialization.

## Proof

- Focused TUI Debug: `9/9` steps, `136/136` tests.
- Focused TUI ReleaseFast: `9/9` steps, `136/136` tests.
- Full Debug: `19/19` steps, `2,168/2,168` tests.
- Source ReleaseFast: `9/9` steps, install success.
- Source SHA-256: `EDE276134231600AE8978B0C88BCBA6C26F7F303A5336025D5B0E371852EC8F8`.
- Installed SHA-256 remains
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`;
  promotion was intentionally not performed.

## Boundary

No second question overlay owner, poller, answer ledger, status bus, or
prompt-mode branch was introduced. Installed promotion and provider-driven
question response remain deferred.
