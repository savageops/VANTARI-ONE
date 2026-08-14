---
type: research
id: research/2026-08-14-question-panel-event-loop-recovery
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/clients/tui_chat.zig
---

# Question panel event-loop recovery

## Objective

The operator reported that model-issued multiple-choice questions could crash
VANTARI in normal or align use. The requested interaction remains one compact
settings-style panel: related questions in one batch, horizontal options, and a
single review/submit boundary.

## Reference pressure

- `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/ask-dialog.ts`
  keeps question state in one component and separates selection, review,
  submit, and cancel states.
- `.refs/can1357__oh-my-pi/packages/tui/src/components/select-list.ts` and
  `settings-list.ts` clamp focus before rendering and keep keyboard navigation
  inside one bounded list owner.
- `.refs/can1357__oh-my-pi/docs/tools/ask.md` batches related questions and
  resolves them through one final answer boundary.
- `.refs/badlogic__pi-mono/packages/coding-agent/examples/extensions/questionnaire.ts`
  keeps questionnaire state in one extension-owned interaction rather than
  creating a second prompt or event loop.
- `.refs/vercel__eve/docs/tools/human-in-the-loop.md` resumes a waiting typed
  request by identity instead of creating an untracked wait path.

The VANTARI compression decision remains `ask_user -> input_requested ->
InputBroker -> question_view.State -> input/respond`. No autocomplete popover,
question poller, transcript copy, mode branch, or second broker is justified.

## Diagnosis

The panel renderer and broker already had the requested layout and lifecycle
guards. Both TUI key ingress paths still used `try` directly on
`question_view.State.handleKey` and `respondInput`. A recoverable allocation,
serialization, or response-transport error could therefore unwind the top-level
TUI loop and present as a process crash. The streaming-turn path and idle event
loop duplicated this failure boundary.

## Applied correction

- `ChatState.handleQuestionKey` is now the one key boundary for both TUI paths.
- Controller errors become one bounded system message and leave the active
  panel available for retry or explicit cancellation.
- Submit/cancel response errors are contained at the same boundary; existing
  `input/respond` remains the only resolution path.
- Normal, `orchestrate`, `build`, `align`, and `plan` continue to share the
  same horizontal-row controller. Prompt modes remain behavioral prompt
  layers, not executor or UI forks.
- The new mode-matrix test drives question navigation and cancellation through
  the same `ChatState` owner used by both runtime loops.

## Evidence

- `apps/backend/scripts/zigw.ps1 build test-tui --summary all` — `9/9` steps,
  `135/135` Debug tests passed.
- `apps/backend/scripts/zigw.ps1 build test-tui -Doptimize=ReleaseFast --summary all`
  — `9/9` steps, `135/135` ReleaseFast tests passed.
- `apps/backend/scripts/zigw.ps1 build test --summary all` — `19/19` steps,
  `2,165/2,165` Debug tests passed.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all`
  — source artifact `9/9`; SHA-256
  `D22A6E617DEF01BDF323F4F4500C1F53AD54C1221CFE6A8A6413FCA6D7D1EDFE`.
- `zig fmt --check src/clients/tui_chat.zig` and `git diff --check` pass.

## Residual boundary

The source controller and both TUI event-loop ingress paths are now covered.
The preserved installed owner still has SHA-256
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Installed promotion and a provider-issued live question response remain
deferred by the operator boundary.
