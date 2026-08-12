---
type: roadmap-closeout
id: roadmap/19-single-terminal-event
status: closed
updated: 2026-08-12
owner: apps/backend/src/core/sessions/store.zig
parent: .docs/roadmap/24-harness-capability-next-90.md
decision: consolidate/delete
---

# 19 — One terminal event per run

## Problem

The durable event spine has three terminal dialects. Successful runs usually end
with typed `turn_finished`; failures and cancellations end with untyped
`session_failed` or `session_cancelled`; the empty-success branch emits no
terminal row. Provider connection timeout is stored as a generic failure. A
cold-start reader must infer closure from event names, session projection, and
branch-specific omissions.

## Competitive synthesis

| Source | Strong invariant | VANTARI decision |
|---|---|---|
| [OpenAI Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) | Every turn closes through one `turn/completed` notification whose status is completed, interrupted, or failed. | Use one terminal carrier with an explicit outcome. |
| [pi agent loop](https://github.com/badlogic/pi-mono/blob/main/packages/agent/src/agent-loop.ts) | `agent_end` is the final run event for normal, aborted, and error stop reasons. | Make terminal uniqueness a run invariant, not a UI convention. |
| [Vercel Eve execution](https://github.com/vercel/eve/tree/main/packages/eve/src/execution) | Completed, failed, and cancelled turns are mutually exclusive settlements; cancellation is not failure. | Preserve cancellation as its own outcome without a second event family. |
| [LangGraph Agent Server](https://langchain-ai.github.io/langgraph/concepts/langgraph_server/) | Durable run state is updated when execution closes; stream delivery is a projection over persisted run state. | Persist closure before live notification and reconstruct it after restart. |
| [Temporal event history](https://github.com/temporalio/temporal/blob/main/docs/architecture/README.md) | Append-only history recreates execution state; completed, failed, timed out, and cancelled are distinct close outcomes. | Keep timeout distinct in terminal evidence while projecting it to the existing failed session status. |
| [AutoGen agents](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/agents.html) | `run_stream()` ends with one `TaskResult` after intermediate messages and events. | Give consumers one final record instead of several terminal names. |
| [OpenAI Agents SDK results](https://openai.github.io/openai-agents-python/results/) | A streaming run is terminal only after its stream settles; cancellation cleanup remains inside that lifecycle. | Emit the terminal row after output/effects settle and before returning. |

The common invariant is one final carrier plus a typed outcome. Separate names
can work, but they force every reader to reproduce terminal-set logic. VANTARI
already owns a durable run identity in `session_started.seq`; the terminal row
will bind to that sequence as `run_seq`.

## Sprout decision

Three candidates were reduced before implementation:

1. Type the existing three event names and add `turn_timed_out`. Rejected: four
   names preserve four reader branches and still require a shared uniqueness set.
2. Keep `turn_finished` and add an `outcome` field. Rejected: calling failed and
   cancelled runs “finished” obscures the contract and retains the old schema as
   both telemetry and lifecycle.
3. Replace active writes with `turn_terminal` plus `outcome`. Selected: one event
   type, one payload schema, one atomic append gate, and one cold-start reader.

`outcome` is `completed`, `failed`, `timed_out`, or `cancelled`. The session
projection remains `completed`, `failed`, or `cancelled`; `timed_out` projects to
`failed` without losing the precise terminal evidence.

## Tracer

The first executable proof targets the owner, not the renderer:

```text
session_started seq 11
commit completed -> turn_terminal(run_seq=11, outcome=completed)
commit completed again -> idempotent, no second row
commit failed -> TerminalOutcomeConflict, completed row remains authoritative
session_started seq 19 -> prior terminal no longer closes the new run
commit timed_out -> one turn_terminal(run_seq=19, outcome=timed_out)
```

Four executor probes then force completed, failed, timed-out, and cancelled paths
and replay `events.jsonl` from disk. Each run must have exactly one parseable
`var1.turn_terminal.v1` row. The empty-success path is a required falsification
case because it currently has none.

## Scope boundary

- Add no terminal table, sidecar, daemon, timeout status enum, or second event
  ledger.
- Keep old terminal names as read-only compatibility inputs; emit none from the
  current runtime.
- Serialize terminal admission under the existing per-session event-ledger lock.
- Reject a stale expected `run_seq`, a conflicting second outcome, and malformed
  terminal payloads before another terminal row can append.
- Keep assistant output, summaries, docs projections, and live notifications as
  consumers of the same terminal commit.

## Implementation

The tracer first failed at compile time because `store.commitTurnTerminal` did
not exist. The smallest durable slice then changed these owners:

- `shared/protocol/events.zig` owns `TurnTerminalOutcome`,
  `var1.turn_terminal.v1`, and canonical serialization.
- `core/sessions/store.zig::commitTurnTerminal` scans and commits under the
  existing per-session event lock. It binds to the latest
  `session_started.seq`, makes an identical retry idempotent, rejects stale or
  conflicting settlement, and writes the session-status projection.
- `core/executor/loop.zig`, `core/agents/supervisor.zig`,
  `core/agents/service.zig`, and `host/stdio_rpc.zig` route success, empty
  success, failure, timeout, cancellation, admission failure, and stale-owner
  repair through that owner.
- `clients/tui_chat.zig` consumes the current payload, clears active-run state
  only at terminal settlement, and retains old terminal names only for replay
  of existing ledgers.
- `core/executor/turn_payload.zig` now builds completed-run telemetry instead of
  owning a second terminal serializer.

No terminal table, sidecar, daemon, new session status, or second event ledger
was added. Current-source search finds no writer for `turn_finished`,
`session_failed`, or `session_cancelled`.

## Proof

- Canonical Zig 0.15.1 graph: 19/19 steps and 1,958/1,958 tests. Completed,
  failed, timed-out, cancelled, and empty-success probes each read back exactly
  one current terminal row. Duplicate-identical, conflicting, stale-generation,
  malformed-payload, duplicate-ledger, and cold-start projection probes pass.
- ReleaseFast: 9/9 steps.
- Packaged GGUF duplicate audit: 237 segments, eight similarity candidates,
  zero exact duplicates. The eight candidates are import blocks and independent
  host-RPC test fixtures; no second production terminal owner exists.
- Installed `%LOCALAPPDATA%\Vantari\bin\vantari.exe` ran a disposable local
  provider plus binary-output tool turn. The ledger and live notification ended
  on the same sole `turn_terminal` at sequence 12; its payload was
  `var1.turn_terminal.v1`, `completed`, and `run_seq = 1`. Replay returned
  contiguous sequences 2–12 and exact bounded stdout/stderr bytes.
- Source and installed SHA-256 both equal
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`.
  The smoke exited 0 and left zero VANTARI processes.
