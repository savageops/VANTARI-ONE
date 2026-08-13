---
type: finding
id: harness-finding-30
status: closed
priority: P2
owner: apps/backend/src/clients/tui_chat.zig
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# TUI operator hierarchy

## Finding

The compact footer and child-summary direction are correct. Move 50 closed the useful part of the request with a live bounded summary on the existing keyed child row. A full Agent Hub is deferred until measured scale or operator need requires disclosure beyond that row. Replay identity remains owned by the event cursor and canonical summary ledger.

## Required surface

- Persistent row: status, model, effort, context used/capacity/percent, remaining, active/max agents, nonzero queue, known session cost.
- Composer: lighter than transcript background and lighter than the metadata row.
- No persistent Esc cancel copy.
- Group row: Agents completed/total.
- Child row: agent name plus bounded canonical turn summary; tool phase is a marker.
- On-demand detail, if later required: use canonical `session/get` and summary records for model, effort, route, state, elapsed time, tool count, tokens/context/cost, receipt, and latest summary. Do not add a second registry.
- Unknown context after compaction renders unknown, not fabricated precision.

## Acceptance

- Narrow, wide, idle, streaming, tool, multi-agent, failed, cancelled, replayed, and unknown-context states have separate snapshots.
- Footer never wraps into a status forest.
- Live summary refresh updates one keyed child row and does not append duplicate tool rows or copy the transcript.
- All rows reconstruct from sequence-bearing events and canonical summaries.
- Installed Windows visual proof matches source.

## Source and salvage

- [pi](https://github.com/earendil-works/pi): compact model/effort/context/cost footer.
- [oh-my-pi](https://github.com/can1357/oh-my-pi): detailed Agent Hub with per-agent telemetry.
- User: “still clean minimal, but elegant and User friendly”.

## Out of scope

Do not add decorative chrome, persistent shortcut hints, or another activity registry.

## Closure receipt

Move 50 reused the existing `update_session_summary` completion boundary and canonical `sessions/summaries.jsonl` ledger. The supervisor emits the existing `child_progress` envelope with `phase=summary`; the TUI renders the bounded quoted summary on the same row. Focused TUI `9/9`, `78/78`; full Debug `19/19`, `2,000/2,000`; ReleaseFast/install `9/9`; source/installed SHA-256 `6814396B7E2A134E9ECAED9DA5B6567FEAA01824DAC948CC54DC725EFC3DF178`; installed TUI smoke and exact process teardown passed. A full Agent Hub is conditional, not part of the compact default surface.
