---
type: finding
id: harness-finding-30
status: pending
priority: P2
owner: apps/backend/src/clients/tui_chat.zig
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# TUI operator hierarchy

## Finding

The compact footer and child-summary direction are correct. The next improvement is disclosure, not more footer density: one minimal persistent row and an on-demand Agent Hub for per-agent detail. Replay identity must be fixed before adding more derived state.

## Required surface

- Persistent row: status, model, effort, context used/capacity/percent, remaining, active/max agents, nonzero queue, known session cost.
- Composer: lighter than transcript background and lighter than the metadata row.
- No persistent Esc cancel copy.
- Group row: Agents completed/total.
- Child row: agent name plus bounded canonical turn summary; tool phase is a marker.
- Agent Hub: model, effort, route, state, elapsed time, tool count, tokens/context/cost, receipt, and latest summary.
- Unknown context after compaction renders unknown, not fabricated precision.

## Acceptance

- Narrow, wide, idle, streaming, tool, multi-agent, failed, cancelled, replayed, and unknown-context states have separate snapshots.
- Footer never wraps into a status forest.
- Agent Hub totals do not double-count child cost in the parent.
- All rows reconstruct from sequence-bearing events and canonical summaries.
- Installed Windows visual proof matches source.

## Source and salvage

- [pi](https://github.com/earendil-works/pi): compact model/effort/context/cost footer.
- [oh-my-pi](https://github.com/can1357/oh-my-pi): detailed Agent Hub with per-agent telemetry.
- User: “still clean minimal, but elegant and User friendly”.

## Out of scope

Do not add decorative chrome, persistent shortcut hints, or another activity registry.
