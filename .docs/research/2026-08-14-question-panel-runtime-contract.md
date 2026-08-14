---
type: research
id: research/2026-08-14-question-panel-runtime-contract
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/core/tools/runtime.zig; apps/backend/src/clients/tui_chat.zig
---

# Question panel runtime contract

## Question

Why could a normal or `align` turn still fail to reach the repaired multiple-
choice panel, and what is the smallest proof that the panel survives the real
TUI render boundary?

## Observed boundary

The earlier question-panel work repaired normalization, malformed-request
cancellation, text lifetime, hostile display text, and clipped rows. The
remaining seam was in the root tool policy: `builtinDefinitions(false)` omitted
`ask_user`, the orchestrator-only catalog omitted it, and the corresponding
allow-list rejected it. Prompt mode already reused one controller, but the
root provider turn did not have one consistent catalog/dispatch contract for
the operator question capability. The TUI tests also stopped below the actual
`ChatState -> question_view.State -> Vaxis -> render -> flush` boundary.

## Reference harvest

| Source | Invariant retained | VANTARI compression decision |
|---|---|---|
| `.refs/can1357__oh-my-pi/packages/coding-agent/src/modes/components/ask-dialog.ts` | Normalize a bounded batch, clamp focus, keep an explicit review/submit state, and size the dialog to the viewport. | Keep the interaction invariant in the existing `question_view.State`; do not import a dialog framework or create a second overlay owner. |
| `.refs/can1357__oh-my-pi/packages/tui/src/components/select-list.ts` | Selection and visible rows are clamped before drawing. | Keep the existing bounded row math and static display keys. |
| `.refs/badlogic__pi-mono/packages/coding-agent/examples/extensions/questionnaire.ts` | Related questions share one answer surface and one final submit. | Keep one batch request and one `input/respond` call. |
| `.refs/vercel__eve/docs/tools/human-in-the-loop.md` | A typed request pauses and resumes through one identity-keyed protocol. | Reuse `input_requested`, `InputBroker`, and `input/respond`; no question-specific wait loop. |

## Decision

- Keep one path: `ask_user -> input_requested -> InputBroker -> question_view.State -> input/respond`.
- Include `ask_user` in the root normal catalog, root agent catalog, and orchestrator-only catalog. The orchestrator allow-list admits only `ask_user`, agent eligibility, and agent mailbox tools; file, command, and artifact tools remain denied there.
- Keep child capability profiles headless. `recon`, `write`, `subagent`, and `model_task` do not receive operator questions.
- Prove every prompt mode through the real Vaxis frame boundary. `orchestrate`, `build`, `align`, and `plan` select the same panel owner; prompt mode does not fork the executor or question protocol.
- Keep the existing horizontal question rows, clamped focus, review/submit state, and frame-owned display projection. No popup registry, polling bus, or second question transport is justified.

## Evidence

- `apps/backend/scripts/zigw.ps1 build test-tui --summary all` — `132/132` focused TUI tests passed, including the Vaxis render-boundary probe for all four prompt modes.
- `apps/backend/scripts/zigw.ps1 build test --summary all` — `19/19` steps and `2,151/2,151` Debug tests passed.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` — `9/9` steps passed; source SHA-256 is `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
- The installed owner pair was preserved. Installed provider-driven question response and live visual capture remain deferred by the explicit operator boundary.

## Residual boundary

Source catalog, dispatch-policy, controller, and render evidence are green.
The next proof is a provider-issued question on the normal installed path after
the user permits replacement of the preserved installed owner. No source claim
here implies that live proof has already run.
