---
type: research
id: research/2026-08-14-question-modal-frame
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/clients/{question_view,tui_chat}.zig
---

# Question modal frame

## Objective

Make model-issued multiple-choice input safe and legible in normal and `align`
turns. The operator needs one compact surface that shows horizontal question
rows, keeps related answers together, and requires one explicit review/submit
boundary.

## Reference pressure

- `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/ask-dialog.ts`
  keeps one dialog state owner, stable dialog geometry, bounded question focus,
  a separate review/Submit state, and multi-select toggles that do not advance
  the question.
- `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/settings-selector.ts`
  uses the same bounded selection vocabulary as the settings surface.
- VANTARI already owns the durable path:
  `ask_user -> input_requested -> InputBroker -> question_view.State ->
  input/respond`. The reference invariant is reusable state ownership and a
  review boundary, not a second dialog framework or answer bus.

## Diagnosis

The question controller and key-error boundary were already shared, but the
active panel was still inserted into the normal footer layout. That made the
question renderer share transcript, reasoning-dock, status-bar, and composer
geometry. A long batch or cramped terminal could force those projections to
compete for a frame even though the controller itself was guarded.

## Applied slice

- An active `question_view.State` now owns the complete Vaxis frame before the
  transcript/footer layout. It renders the same quiet modal hierarchy as
  Settings and the autocomplete surface, then reaches `vx.render` through one
  frame-owned arena.
- Idle and streaming key ingress already converge on
  `ChatState.handleQuestionKey`; routing now gives a live question precedence
  over a stale settings projection.
- Multi-select Enter and Space toggle in place until review. Selecting `Other`
  with Enter opens the inline editor; deselecting it clears stale custom text.
- No second broker, question poller, transcript copy, mode-specific controller,
  or resolved-event family was added.

## State machine

```text
input_requested
  -> full-frame question modal
  -> row/option navigation or inline Other
  -> review/submit
  -> input/respond
  -> terminal event clears the projection
```

Malformed requests, missing session ownership, transport failure, terminal
replay, and controller errors remain recoverable at the existing client/event
boundary.

## Proof boundary

Focused TUI Debug and ReleaseFast both pass `9/9` steps and `136/136` tests,
including multi-select review and full-frame rendering at 14, 4, and 1 row
across `orchestrate`, `build`, `align`, and `plan`. Full Debug passes `19/19`
steps and `2,168/2,168` tests. Source ReleaseFast passes `9/9` with SHA-256
`EDE276134231600AE8978B0C88BCBA6C26F7F303A5336025D5B0E371852EC8F8`.

Installed promotion and a provider-issued live question response remain
deferred by the operator boundary. The installed owner is not replaced by
this source slice.
