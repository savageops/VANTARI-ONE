---
type: research
id: research/tui-composer-move42
status: current
updated: 2026-08-13
owner: apps/backend/src/clients/tui_chat.zig
---

# Move42 — composer hierarchy and conditional cancellation

## Decision

Keep `apps/backend/src/clients/tui_chat.zig:styles` as the sole TUI palette
owner. It already supplies the three semantic surfaces required by the
operator contract:

```text
transcript surface < metadata surface < focused composer
```

The composer remains the first row of the compact footer. Runtime metadata
remains below it. No border, persistent shortcut hint, theme registry, CSS
token layer, or screenshot framework is added.

Cancellation is transient state, not steady-state copy. The footer renders
`cancelling` only when `waiting && cancel_requested`; terminal events clear the
request. Escape/Ctrl-C keep the direct cancellation path. `/cancel` now routes
through the same request owner during an active interjection and reports
`No active run to cancel.` while idle.

## Competitive harvest

The visual details of these harnesses differ, but the load-bearing convergence
is the same: session-owned lifecycle state, compact operator telemetry, and
terminal state that does not remain disguised as active work. We inherit the
invariant, not a second UI architecture.

| Primary source | Load-bearing observation | VANTARI adoption or rejection |
|---|---|---|
| [OpenAI Codex TUI execution cell](https://github.com/openai/codex/blob/main/codex-rs/tui/src/exec_cell/render.rs) | Execution rendering is derived from typed cell/item state, with active and terminal presentation separated from transcript content. | Keep one typed TUI read model; reject text-derived cancellation or a second status bus. |
| [pi AgentSession SDK](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sdk.md) | A session owns lifecycle and event delivery for custom surfaces. | Keep `ChatState` as a projection over the kernel session; do not create a composer-owned ledger. |
| [oh-my-pi RPC protocol](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md) | RPC clients consume explicit lifecycle/progress frames rather than guessing state from display strings. | Keep cancellation and agent activity tied to typed runtime state. |
| [Vercel Eve sessions, runs, and streaming](https://github.com/vercel/eve/blob/main/docs/concepts/sessions-runs-and-streaming.md) | Sessions and runs provide an ordered boundary for live streaming and terminal reconciliation. | Clear transient cancellation at the terminal boundary; keep the footer a projection. |
| [Flue event and run history](https://github.com/withastro/flue/blob/main/CHANGELOG.md) | Durable event indexes and terminal run history are more reliable than a parallel stream cache. | Use the existing event sequence and no persistent “cancel” hint. |
| [NullClaw](https://github.com/nullclaw/nullclaw) | A small Zig agent runtime keeps operator surfaces subordinate to the execution substrate. | Preserve a single Zig TUI owner; reject a general UI framework for three colors and one flag. |
| [OpenClaw agent loop](https://github.com/openclaw/openclaw/blob/main/docs/concepts/agent-loop.md) | Agent-loop lifecycle hooks distinguish active work from final result delivery. | Expose cancellation only during active work; keep final summaries as final state. |

## Current seam and proof

- `styles.surface`, `styles.meta_surface`, and `styles.composer` are the
  canonical background tokens. `colorLevel` asserts strict lightness order.
- Wide metadata remains exact:
  `glm-5.1 · high · ctx 5k / 200k (3%) · 195k left`.
- The width-40 metadata projection remains exact:
  `glm-5.1 · high · ctx 5k / 200k (3%)`.
- Active cancellation contains `cancelling` but never persistent `Esc cancel`.
- Idle cancellation state contains neither `cancelling` nor `Esc cancel`.
- Terminal run events clear `cancel_requested` with `active_run_seq`.
- `/cancel` uses the canonical request owner during an active interjection and
  is truthful when no run is active.
- Focused TUI proof: `scripts/zigw.ps1 build test-tui --summary all` -> 9/9
  build steps, 75/75 tests passed.

## Boundary

Move42 does not add prompt modes, Agent Hub detail, a visual snapshot matrix,
or a configurable theme system. Narrow/wide formatter snapshots are sufficient
for this seam; installed ANSI inspection remains the release proof for the
actual Windows surface. Prompt-driven behavior remains a provider/context
concern, not a hardcoded TUI behavior branch.
