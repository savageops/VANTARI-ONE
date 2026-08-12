---
type: roadmap-closeout
id: roadmap/18-generation-bound-cancellation
status: closed
updated: 2026-08-12
owner: apps/backend/src/host/stdio_rpc.zig
parent: .docs/roadmap/24-harness-capability-next-90.md
decision: consolidate
---

# 18 — Generation-bound cancellation

## Problem

`session/cancel` currently addresses only `session_id`. A delayed request can
arrive after one run finishes and a newer run starts on the same session. The
runtime then sets the newer run's mutable `cancel_requested` bit even though the
client observed the prior run.

## Competitive synthesis

| Source | Strong invariant | VANTARI decision |
|---|---|---|
| [OpenAI Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) | `turn/interrupt` requires both thread ID and exact turn ID. | Require the exact observed run generation, not only the session container. |
| [Vercel Eve turn cancellation](https://github.com/vercel/eve/blob/main/packages/eve/src/execution/turn-cancellation-control.ts) | A cancel guard must match `expectedTurnId`; stale guards are consumed as no-ops and tested before a matching guard is honored. | Copy the stale-guard invariant and its falsification test, not Eve's hook/control stack. |
| [LangGraph run cancellation](https://docs.langchain.com/langsmith/cancel-run) | Cancel addresses one `thread_id + run_id`; a run record remains inspectable after interrupt. | Keep the session as the container and the event sequence as the run address. |
| [AutoGen team abort](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/tutorial/teams.html#aborting-a-team) | One `CancellationToken` is passed into one `run`/`run_stream` invocation. | Bind the request to one admitted run; do not expose a session-global token. |
| [OpenAI Agents SDK streaming result](https://openai.github.io/openai-agents-python/results/#streaming-lifecycle-and-diagnostics) | Cancellation is a method on the specific `RunResultStreaming` invocation and cleanup remains part of that run's event stream. | Preserve cancellation as a run-owned transition on the existing event spine. |
| [Temporal workflow execution](https://github.com/temporalio/sdk-go/blob/master/workflow/workflow.go) | Exact cancellation can include workflow ID plus run ID; omitting run ID means “current” and is therefore intentionally weaker. | Reject “current run” guessing for an observed interactive cancel. |
| [pi agent session](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/core/agent-session.ts) | `abort()` reaches the active in-process agent invocation and waits for that invocation to become idle. | Retain the small invocation-local mechanism, but strengthen the remote address with durable identity. |

The shared invariant is exact execution identity. VANTARI already persists that
identity: the `session_started` event sequence is monotonic, durable, and emitted
once for each admitted `session/send` run.

## Sprout decision

Three candidates were reduced before implementation:

1. Add a random run UUID to `session.json`. Rejected: it adds a second durable
   identity and migration surface while the event ledger already supplies one.
2. Reuse `turn_started.seq`. Rejected: one session run can contain multiple
   provider/tool turns, so the value changes inside the operation being
   cancelled.
3. Reuse `session_started.seq`. Selected: one value per admitted run, already
   persisted before provider dispatch and already observed by the TUI.

The protocol will call this value `expected_run_seq`. The runtime projection is
`active_run_seq`. Shutdown remains generation-independent because shutdown
atomically fences new admissions before cancelling every active owner.

## Tracer

The first executable proof is a delayed-cancel race:

```text
start run A -> observe seq 11 -> finish A
start run B -> observe seq 22
cancel expected seq 11 -> stale_run; B remains live
cancel expected seq 22 -> requested; B observes cancellation
```

The tracer must fail against the current session-only runtime before the owner
changes. RPC and TUI tests then prove the generation crosses the public boundary
without a second state bus.

## Scope boundary

- Add no random identifier, cancellation ledger, queue, background watcher, or
  provider-specific abort path.
- Keep initialized-session cancellation and stale-owner reconciliation available
  without a run sequence because neither path has a live newer owner to kill.
- Treat a missing or mismatched generation on an active owner as a typed no-op.
- Preserve the existing `shouldCancel(session_id)` loop hook; generation is
  checked once when the request mutates the active run's bit.

## Implementation

- `host/stdio_rpc.zig` binds `active_run_seq` from the persisted
  `session_started` event before notification emission. `requestCancel` is the
  sole mutation gate and returns `requested`, `not_running`, `run_not_observed`,
  `generation_required`, or `stale_run`.
- `clients/tui_chat.zig` projects the observed run sequence from replay and live
  events, sends it as `expected_run_seq`, and never retargets a stale request to
  the runtime's newer generation.
- `shared/protocol/types.zig` exposes the typed outcome and optional active
  generation. No UUID, second cancellation ledger, or tool-local abort path was
  added.

## Proof

- Tracer: run A sequence 11 finished; run B sequence 22 started. Unguarded
  cancellation returned `generation_required`, sequence 11 returned `stale_run`
  without setting B's bit, and sequence 22 returned `requested`.
- Pinned Zig 0.15.1 graph: 19/19 steps and 1,950/1,950 tests. Focused TUI:
  61/61. Host lifecycle: 237/237. ReleaseFast: 9/9.
- Packaged GGUF duplicate audit: 130 segments across host, TUI, and protocol;
  zero candidate pairs and zero exact duplicates.
- Source and installed `%LOCALAPPDATA%\Vantari\bin\vantari.exe` SHA-256 both
  equal `B361AD2A66609590236E4967517718C7ECD3563E7474578D08009D09622E1FA4`.
- Installed delayed race used one disposable provider: run sequences 1, 6, and
  11. Delayed cancels for 1 and 6 returned `stale_run`; run 6 completed. Exact
  sequence 11 returned `requested`, the terminal event was `session_cancelled`,
  the kernel exited 0, three provider requests were observed, and zero VANTARI
  process remained.

The event name above is retained as historical move-18 evidence. Move 19 removed
that writer; current cancellation closes through one generation-bound
`var1.turn_terminal.v1` row with outcome `cancelled`.
