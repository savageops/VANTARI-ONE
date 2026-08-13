---
type: research
id: research/tui-projection-move41
status: current
updated: 2026-08-13
owner: apps/backend/src/clients/tui_chat.zig
---

# Move41 — sequence-addressed TUI projection

## Decision

Consolidate the existing TUI event path and delete the last sequence-less cold
replay fallback. `ChatState` remains the sole client read model. Parent
`events.jsonl` sequence is the render identity; the supervisor already replaces
the child `assistant_response` payload with the latest canonical row from
`sessions/summaries.jsonl`. No activity registry, child transcript reader,
transport-local cursor, or footer status bus is added.

## Current seam

- Live notifications reject `seq == 0`, recover gaps through `session/get`, and
  apply only contiguous stored events in `apps/backend/src/clients/tui_chat.zig`.
- Cold `loadSession` previously rendered legacy `seq == 0` child events even
  though those rows had no replay identity. Move41 removes that branch; durable
  transcript messages remain the cold transcript source, and activity rows
  require sequence-bearing parent events.
- `apps/backend/src/core/agents/supervisor.zig:onChildSessionEvent` reads the
  canonical child summary at the `assistant_response` boundary before emitting
  the parent projection event. Tool lifecycle phases remain typed state markers.
- Footer agent counts are derived only from keyed activity rows created by that
  event projection. Pool and ticket values remain the existing canonical health
  projection; zero-value pressure stays hidden.
- The existing `session/list` owner endpoint accepts an optional `limit`.
  The TUI uses `limit: 1` for latest-session selection, keeping the public
  unbounded response compatible while preventing large workspaces from
  overflowing the owner response cap.

## Six-source harvest

| Primary source | Load-bearing invariant | VANTARI adoption or rejection |
|---|---|---|
| [OpenAI Codex TUI event lifecycle](https://github.com/openai/codex/blob/main/codex-rs/tui/src/exec_cell/render.rs) | A typed execution lifecycle is the source for active/completed rendering; event identity cannot be replaced by display text. | Keep typed parent event sequence and one keyed row; reject timestamp/text identity. |
| [pi AgentSession SDK](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/sdk.md) | One session owns message history, lifecycle, and the event subscription consumed by custom UIs. | Keep `ChatState` as a projection over the kernel session; do not create a TUI-owned ledger. |
| [oh-my-pi RPC subagent frames](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md) | Child lifecycle/progress is an explicit typed frame family, with subscription as an intentional surface. | Keep child group/item events explicit and bounded; do not infer agents from tool names. |
| [Vercel Eve sessions, runs, and streaming](https://github.com/vercel/eve/blob/main/docs/concepts/sessions-runs-and-streaming.md) | Durable event history and resumable live streams share one ordered event coordinate. | Use stored `events.jsonl` sequence for both replay and live updates. |
| [Flue event and run history](https://github.com/withastro/flue/blob/main/CHANGELOG.md) | Durable run history, monotonic `eventIndex`, and terminal run events are canonical; streamed chunks are not a second state store. | Preserve one event spine and terminal evidence; reject a parallel UI status channel. |
| [NullClaw named-agent routing](https://github.com/nullclaw/nullclaw) | Agent identity is resolved by durable route/binding state, not guessed from the current display. | Keep `group_id + task_id` as the row key and leave routing to AgentService/Supervisor. |
| [OpenClaw agent-loop hooks](https://github.com/openclaw/openclaw/blob/main/docs/concepts/agent-loop.md) | Lifecycle hooks expose terminal agent state with final messages and run metadata. | Keep child summary at the terminal/assistant boundary; do not expose intermediate tool phases as conclusions. |

## Proof obligation

- `tui_chat.zig` ignores sequence-less legacy activity events.
- A contiguous live event application and a cold replay of the same events
  produce identical keyed group/item rows, text, state, and final cursor.
- A latest-session selector with `limit: 1` serializes one summary even when
  the workspace contains many sessions.
- Canonical Debug and ReleaseFast graphs pass; the installed binary is rebuilt,
  hash-matched, exercised through the Windows owner path, and leaves zero
  VANTARI processes.

## Closure evidence

- Debug: `scripts/zigw.ps1 build test --summary all` -> 19/19 build steps,
  1,967/1,967 tests passed.
- ReleaseFast/install: 9/9 build steps; installed SHA-256 equals source
  `C65C98363F8DDD9A31F39FAB36F4A280972DCE5E69475AE29DA01FB80A7ABF54`.
- Installed `vantari -c` loaded the latest session from a 19,213-session
  workspace, rendered transcript and child rows, and exited cleanly after the
  exact persistent-owner tree was torn down. Blank TUI startup/exit also passed.

## Boundary

Move41 does not ship the Agent Hub, visual snapshot matrix, prompt-mode cycle,
or per-agent token/cost detail. Those remain later roadmap owners (Moves 43,
44–50). The remaining TUI risk is visual installed-matrix coverage, not a second
projection owner.
