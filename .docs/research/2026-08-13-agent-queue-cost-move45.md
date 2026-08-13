---
type: research
id: research/agent-queue-cost-move45
status: closed
updated: 2026-08-13
owner: apps/backend/src/clients/tui_chat.zig
decision: consolidate
---

# Move 45 — signal-bearing agent, queue, and cost metadata

## Objective

Make the persistent footer expose active/max agent pressure, a nonzero queue,
and known session cost only when those values carry operator signal. Preserve
one quiet read model, the existing status/context priority, and prompt-led
behavior. Do not create a footer registry, polling bus, or second telemetry
owner.

## Harvest

| Reference | Load-bearing pattern | VANTARI extraction |
|---|---|---|
| [OpenAI Codex status surfaces](https://github.com/openai/codex/blob/main/codex-rs/tui/src/chatwidget/status_surfaces.rs) | Status items are selected from one status-surface projection; thread credits and estimated cost are optional semantic items, not transcript rows. | Keep cost optional and derive it from the existing measured turn read model; do not add a cost event or a second renderer. |
| [OpenAI Codex configuration](https://github.com/openai/codex/blob/main/codex-rs/core/src/config/mod.rs) | Status-line selection is separate from model/reasoning configuration. | Footer signal policy stays in `tui_chat.zig`; it does not become settings state. |
| [OpenAI Codex usage discussion](https://github.com/openai/codex/issues/21324) | Context/usage surfaces are useful when accounting is real and can be misleading when it is estimated. | Show cost only when a priced quantity is present; retain `/status` as the detailed token/cost surface. |
| [Gemini CLI `Footer.tsx`](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/ui/components/Footer.tsx) | Footer items have explicit priority/width budgets, optional token/context/quota items, and a single `flexWrap="nowrap"` row. | Append cost to the existing lower-signal segment so the current candidate cascade can drop it before status, model, and context. |
| [pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md) | The footer can show total token/cache usage, cost, context usage, and model; detailed session information remains available through `/session`. | A compact known cost is useful, but the detailed `/status` command remains canonical for token breakdown and unpriced explanation. |
| [Aider history](https://github.com/Aider-AI/aider/blob/main/HISTORY.md) | Cost and token reporting depend on measured/provider-supported values; unknown pricing is a recognized boundary. | Never render a fabricated cost for local or unpriced models. |
| [Crush configuration schema](https://github.com/charmbracelet/crush/blob/main/schema.json) | Model/reasoning configuration and TUI options are separate contracts; no incidental status registry owns runtime truth. | Keep the fixed footer projection local and typed; no configurable signal catalog. |

## Current owner map

- `apps/backend/src/clients/tui_chat.zig::FooterPool` already carries known
  active/max pool state, pool health, assigned tickets, and in-progress ticket
  pressure.
- `ChatState.applyHealthTelemetry` copies the kernel `health_get` projection;
  it does not admit or launch work.
- `formatFooterMetaWithPool` already emits `pool running/max`, current-turn
  `agents running/total`, and `queue N` only when the corresponding values are
  nonzero or unhealthy.
- `ChatState.recordTurnTelemetry` already accumulates priced completed-turn
  cost in `session_cost_usd` and keeps `has_session_cost` false when cost is
  null. `commands.renderStatus` remains the detailed token/cost readout.

## Decision

Add one nullable `session_cost_usd` input to the existing footer formatter. The
draw owner passes the already accumulated value only when `has_session_cost` is
true. The formatter appends `cost $0.######` to the existing lower-signal
agent/pool/queue segment only for finite, nonnegative values. Unpriced or
invalid values produce no footer cost. Existing width candidates drop that
segment before primary status, mode, model, effort, and context fields.

This closes the missing footer projection without changing event schemas,
health polling, pricing, prompt behavior, agent admission, or `/status`.

## Proof boundary

- Formatter tests prove priced cost appears with active/max/queue pressure and
  null cost remains absent.
- Focused TUI and full Debug graphs pass.
- ReleaseFast installation renders the new row, source and installed hashes
  match, and exact proof-owned process teardown leaves zero VANTARI processes.

## Rejected complexity

- No `FooterSignals` registry or configurable item list: the product has a
  fixed, high-value row and no measured need for another settings surface.
- No new cost event or telemetry poll: `turn_terminal.cost_total_usd` already
  persists measured pricing and `ChatState` already aggregates it.
- No second cost row or persistent unpriced placeholder: `/status` explains
  token/cost boundaries when the footer has no priced value.
