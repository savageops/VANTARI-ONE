---
type: research
id: research/status-row-move44
status: closed
updated: 2026-08-13
owner: apps/backend/src/clients/tui_chat.zig
decision: consolidate
---

# Move 44 — compact status row

## Objective

Make the operator’s persistent footer answer the current runtime questions in
one quiet, non-wrapping row: what is happening, which prompt lens is active,
which model and effort are selected, and how much context remains.

## Harvest

| Reference | Load-bearing pattern | VANTARI extraction |
|---|---|---|
| [OpenAI Codex status surfaces](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs) | Status is a compact semantic projection (`Ready`, `Starting`, or active work), not a transcript event dump. | Map the existing `ChatState` lifecycle to one visible status label while keeping event ownership unchanged. |
| [OpenAI Codex usage/status discussion](https://github.com/openai/codex/issues/21324) | Context usage is useful when it uses real accounting; ambiguous gauges consume space and are easy to misread. | Keep exact used/capacity/percent plus remaining tokens; do not add a progress bar. |
| [OpenAI Codex TUI configuration](https://github.com/openai/codex/blob/main/codex-rs/core/src/config/mod.rs) | Model, reasoning, and status line are separate operator-facing signals. | Preserve model and effort as adjacent compact fields; do not make footer formatting a settings subsystem. |
| [Gemini CLI Footer.tsx](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/components/Footer.tsx) | Footer items have explicit width budgets, priority, truncation, and `flexWrap="nowrap"`. | Use the existing candidate cascade and terminal-safe `truncateEnd`; add mode/status before lower-priority signals. |
| [Gemini CLI configuration](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md) | Model and context usage are first-class footer values, while percentage display is optional and independent. | Keep context data visible by default because it is a direct runtime safety signal; omit unrelated settings labels. |
| [pi coding agent](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md) | Status lines, headers, and footers are presentation extension points; core behavior stays in the prompt/runtime layer. | Keep this row a TUI read model over existing state, with no prompt or executor coupling. |
| [Aider model history](https://github.com/Aider-AI/aider/blob/main/HISTORY.md) | Thinking-token and reasoning-effort values are useful model information when surfaced compactly. | Render VANTARI’s already-owned effort value; do not add a second effort accounting path. |
| [Crush configuration schema](https://github.com/charmbracelet/crush/blob/main/schema.json) | Model/context/tool configuration belongs to capability configuration, not incidental status rendering. | Read existing kernel projections only; no new config keys or footer registry. |

## Decision

Extend the existing `formatFooterMetaWithPool` projection with the session-local
`PromptMode` label and a mapped runtime status. Keep the order:

```text
status · mode · model · effort · ctx used / capacity (percent) · remaining
```

The existing context compiler telemetry remains the only source for context
used/capacity. Unknown or zero capacity stays `ctx —`; no estimate is invented.
The existing candidate cascade remains the width policy: full context first,
then compact context, then lower-signal fields, and finally bounded end
truncation. Every render uses `.wrap = .none`.

`READY` becomes `ready`, `RUNNING`/waiting becomes `working`, cancellation
becomes `cancelling`, and `FAILED`/`RPC_ERROR` becomes `failed`. The status label
is derived from existing `ChatState` fields; it is not a new state machine.

Agent counts, queue pressure, and session cost remain in the existing projection
but are not promoted by this move; Move 45 owns their signal policy. No settings
surface, configurable item registry, progress bar, event type, telemetry poll,
or second footer owner is added.

## Proof boundary

- Formatter tests must prove the complete wide row, all status mappings, active
  prompt mode, exact context arithmetic, unknown context, narrow priority, and
  byte-bounded no-wrap output.
- The focused TUI graph and full Debug graph must pass.
- ReleaseFast installation must prove the installed binary renders/starts with
  the new row, source and installed SHA-256 must match, and the final
  proof-owned VANTARI process census must be zero.

## Rejected complexity

- A configurable footer/status registry: fixed product-critical fields have no
  measured need for another settings surface.
- A context progress bar: it adds ambiguity and consumes scarce terminal width.
- New event or telemetry fields: all required values already exist in the TUI
  read model and typed turn telemetry.
- Wrapping or a second footer row: it violates the compact operator contract and
  steals transcript height.
