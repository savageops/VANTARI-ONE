---
type: research
id: research/prompt-mode-move43
status: closed
updated: 2026-08-13
owner: apps/backend/src/core/prompts/builder.zig
decision: add
---

# Move 43 — prompt-mode cycle

## Objective

Give the operator a low-friction way to steer VANTARI's posture without adding
an executor, tool-catalog, agent, or capability branch. Shift+Tab cycles a
session-local prompt lens; the next `session/send` carries the selected label.

## Harvest

| Reference | Load-bearing pattern | VANTARI extraction |
|---|---|---|
| [OpenAI Codex TUI](https://github.com/openai/codex/blob/main/codex-rs/tui/src/exec_cell/render.rs) | Compact status and interaction surfaces stay projection-owned. | Keep the control in the TUI and pass intent through the existing RPC. |
| [pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md) | Behavior and tool guidance are assembled from code-owned prompt layers. | Rebuild one provider system envelope on every turn/context rebuild. |
| [oh-my-pi keybindings](https://github.com/can1357/oh-my-pi/blob/main/docs/keybindings.md) | Shift+Tab is a discoverable, low-cost mode/keybinding surface. | Use one cyclic key action; do not add a mode picker or settings panel. |
| [Vercel Eve](https://github.com/vercel/eve/blob/main/docs/concepts/default-harness.md) | Harness behavior is shaped by a durable default plus explicit runtime state. | Preserve VANTARI's default prompt and add one explicit session lens. |
| [Flue](https://github.com/withastro/flue/blob/main/CHANGELOG.md) | Child/session identity and runtime behavior remain tied to canonical session ownership. | Keep mode session-scoped; do not add schema state until persistence is needed. |
| [NullClaw](https://github.com/nullclaw/nullclaw) | Small harnesses expose behavior through a narrow operator surface. | Prefer one enum and one RPC field over a control-plane subsystem. |
| [OpenClaw agent loop](https://github.com/openclaw/openclaw/blob/main/docs/concepts/agent-loop.md) | The loop owns durable execution; prompts steer behavior inside it. | Mode changes guidance only; executor and capability truth remain invariant. |

## Decision

Add `PromptMode` under `core/prompts` with the fixed cycle:

```text
orchestrate -> build -> align -> plan -> orchestrate
```

`orchestrate` is the default. The TUI owns only the session-local selection.
`stdio_rpc.session/send` validates the exact lower-case label and maps omission
to `orchestrate`. `executor/loop.zig` carries the typed value through initial
build, interjection, compaction, child parking/convergence, wake, and provider
overflow rebuilds. `builder.zig` inserts one provider-visible prompt layer.

The compatibility wrapper remains defaulted to `orchestrate`, so non-TUI clients
do not change behavior. No session schema field, mode registry, settings page,
tool branch, agent route, or alternate executor was added.

## Proof boundary

- Prompt tests prove the full cycle, unknown-label rejection, and the selected
  mode appears in the provider system envelope without the default mode.
- Host tests prove an unknown `session/send.prompt_mode` fails before session
  execution with JSON-RPC `-32602`.
- TUI tests prove default state and four-step cycling. The wire path serializes
  the selected label on both existing-session and new-session sends.
- Move closure still requires the canonical Debug graph, ReleaseFast build and
  install, source/installed hash equality, installed TUI smoke, and zero
  proof-owned VANTARI processes.

## Rejected complexity

- Durable mode persistence: no user requirement yet; session-local behavior is
  sufficient and avoids schema migration.
- Mode-specific tools, permissions, models, effort, or scheduling: these would
  make prompting less authoritative and duplicate capability ownership.
- A mode registry or settings UI: four fixed lenses need no dynamic registry or
  extra surface.
- Prompt text in the TUI transcript: the mode is control state, not scaffolding
  that should leak into the operator conversation.
