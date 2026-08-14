---
type: research
id: research/2026-08-14-question-panel-consumer-hardening
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/clients/question_view.zig
---

# Question panel consumer hardening

## Question

Why can a valid model-issued multiple-choice request still crash the normal or
`align` TUI path, and what is the smallest safer interaction shape for a batch
of questions?

## Observed boundary

The earlier root-question repair fixed uninitialized cleanup, malformed event
cancellation, and Vaxis text lifetime. The remaining renderer boundary still
trusted model-provided prompt/label bytes and printed fixed header/divider rows
without checking a clipped viewport. That made hostile control text and very
small terminal heights able to corrupt the visible frame or fail its ownership
contract even when the request was structurally valid.

The source ReleaseFast binary is `7CD32F0D445F96E411EE8B35308A40CF08077BDE3703855525E446667799B3BB`.
The preserved installed owner is still `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
The user explicitly deferred live promotion, so installed consumer behavior is
not claimed as repaired in this record.

## Reference harvest

| Source | Invariant retained | VANTARI compression decision |
|---|---|---|
| `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/ask-dialog.ts:341-415,614-731` | Normalize untrusted question/options, clamp state, keep one state per question, and require an explicit review/submit boundary. | Keep the invariant; use VANTARI’s existing panel and RPC instead of importing a dialog framework or tab architecture. |
| `.refs/can1357__oh-my-pi/packages/tui/src/components/select-list.ts:86-107` | Bound visible rows and selection state before rendering. | Keep bounded row math and clamped focus; the existing question panel remains the owner. |
| `.refs/badlogic__pi-mono/packages/coding-agent/examples/extensions/questionnaire.ts:92-109` | Normalize defaults and keep multi-question answers in one interactive surface with an explicit submit state. | Keep one review state while rendering all visible questions as the requested horizontal rows. |
| `.refs/vercel__eve/docs/tools/human-in-the-loop.md:86-110` | One durable `input.requested` pause/resume protocol keyed by request identity. | Reuse `input_requested` and `InputBroker`; do not add a question-specific wait loop. |
| `.refs/openai__codex/codex-rs/app-server/README.md:207-218` | Keep user-input requests typed at the protocol boundary and bounded in size. | Preserve the existing bounded `var1.input_requested.v1` envelope and `input/respond`. |
| `.refs/savageops__scion/cmd/template_resolution.go:522-561` | Validate choices explicitly and handle noninteractive/default paths without guessing. | Preserve exact option ids in the response while using static display keys; reject ambiguous input at the existing broker boundary. |
| `.refs/nullclaw-main/src/channels/discord.zig:597-635` | Expire, identity-check, and consume selections exactly once; distinguish stale and invalid answers. | Leave lifecycle ownership in the current session/broker path; do not add a second answer ledger. |

## Decision

- Keep one path: `ask_user -> input_requested -> InputBroker -> question_view.State -> input/respond`.
- Render one bounded horizontal row per visible question. Up/Down changes the
  question; Left/Right changes the option; Enter selects; Space toggles; the
  existing review state confirms the batch once.
- Treat model text as display data. The frame-owned projection rejects invalid
  UTF-8, replaces ASCII controls/newlines/tabs with spaces, and uses static
  `a`–`f` display keys while preserving the original option ids in the response.
- Guard every fixed header, divider, and row against the actual viewport. Empty
  or clipped frames are valid render states and must not index a negative row.
- Keep `orchestrate` and `align` on the same controller. Prompt mode changes
  provider-visible guidance only; it does not create a second interaction path.

## IX/log relevance

`ix xo "multiple choice question TUI crash" .docs/log.txt` resolves the current
request at `.docs/log.txt:634`. Earlier `.docs/log.txt:488-489` records the
operator’s streaming/render responsiveness concern, and `.docs/log.txt:632`
records the explicit decision not to promote to the live installed binary yet.
Those constraints make a bounded frame projection and source-only proof the
highest-value current slice.

## Evidence

- `apps/backend/scripts/zigw.ps1 build test-tui --summary all` — focused TUI
  graph passes `131/131`, including hostile text and clipped viewport coverage.
- `apps/backend/scripts/zigw.ps1 build test --summary all` — `19/19` steps and
  `2,144/2,144` Debug tests pass.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` —
  exit `0`; source SHA-256 is the value recorded above.
- The installed owner process tree was preserved. No live installation or
  installed provider-driven question response was run by design.

## Residual boundary

Source rendering and protocol tests are green. A provider-driven installed
question response and visual terminal capture remain open until the user lifts
the live-promotion boundary and the preserved installed owner can be replaced
through its normal proof path. No second popup, question registry, event type,
poller, or prompt-mode executor branch is justified.
