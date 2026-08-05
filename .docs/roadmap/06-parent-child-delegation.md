# 06 — Parent / Child Agent Delegation (Shard Fan-Out)

**Priority: P1**

## The seam

The north star's branch-and-converge is, at the kernel level, parent/child delegation. A branch is a child session whose context is `parent checkpoint + branch input`. Parent sessions track child runs through typed edges, scoped capability profiles, heartbeat events, and resume-safe wait semantics. This is the fan-out mechanism of the sharded model.

## What exists today

- `launch_agent` with explicit scope fields (workspace, tools, budget, read-only).
- `list_agents`, `agent_status`, `wait_agent` with bounded `timeout_ms`.
- Child lifecycle is append-only session/event evidence.
- Parent supervision preserves heartbeat, terminal status, failure class, resume-safe reconciliation.

## What the competitor does (Eve)

Eve (`packages/eve/src/execution/`, `harness/tool-loop.ts`, `context/dynamic-subagent-lifecycle.ts`) has a full subagent suite:

- **Dynamic subagent tools** (`buildDynamicSubagentTools`) — tools can launch subagents at runtime, resolved from session context.
- **Subagent event proxy** (`runProxySubagentEventStep`) — proxies events from child to parent, including `subagent-input-request` and `subagent-authorization-event`.
- **Subagent usage spans** (`subagent-usage-span.ts`) — records token usage across subagent calls.
- **Subagent HITL proxy** (`subagent-hitl-proxy.ts`) — routes human-in-the-loop input through subagent chains.
- **Durable subagent lifecycle** — subagents are Temporal workflows; the parent waits for child results through `dispatchRuntimeActionsStep`/`waitForRuntimeActionResults`.

**Limitation:** Eve's subagent model is built on Temporal workflows and is as complex as that foundation. It has typed child edges, but it is designed for a single durable workflow engine, not for the sharded checkpoint topology VANTARI targets. There is no concept of "a branch is a child session whose context is a checkpoint."

## What the competitor does (pi-mono)

- pi-mono (`badlogic/pi-mono`) has an explicit subagent loop with sequential/parallel policy and a terminal completion signal. It is simpler than Eve's but narrower.

## Why VANTARI does it better

1. **Branch = child session = checkpoint.** VANTARI's delegation is not a separate feature — it is the shard model. A child session with a `parent_checkpoint_id` is a branch. Eve's subagent is a separate workflow; VANTARI's is a typed checkpoint edge on the same ledger.
2. **Scoped profiles, not ambient capabilities.** VANTARI's `launch_agent` carries workspace, tools, budget, read-only as explicit scope fields validated at the binary. Eve's subagents inherit the parent's full toolset unless explicitly filtered.
3. **Resume-safe wait, not Temporal hooks.** VANTARI's `wait_agent` with `timeout_ms` is a bounded syscall over the event spine. Eve's `waitForRuntimeActionResults` is a Temporal hook with inbox/iterator semantics.

## Pipeline items under this theme

### P1-6a: Checkpoint-addressed child launch
- **Contract:** `launch_agent` accepts an optional `parent_checkpoint_id`; the child's context is built from that checkpoint + branch input.
- **Mechanism:** the child's compiler resolves the checkpoint from the parent's `context.jsonl`; the branch input is the child's first message.
- **Test:** a child launched with a parent checkpoint reproduces the parent's summary context without accessing the parent's transcript.
- **Proof:** the child's `context.jsonl` shows the parent checkpoint id and no duplicate entries.

### P1-6b: Branch heartbeat and timeout
- **Contract:** a branch sends periodic heartbeat events; the parent marks it abandoned if the heartbeat expires.
- **Mechanism:** extend the child session's event spine with `heartbeat` events; the parent's `wait_agent` timeout is the heartbeat deadline.
- **Test:** a child that stops sending heartbeats is marked `abandoned`; the parent resumes without it.
- **Proof:** event spine shows the abandonment chain.

### P1-6c: Converge merge
- **Contract:** the parent collects all child results, reconciles their effect receipts, and appends a merge checkpoint.
- **Mechanism:** the merge is a new checkpoint in the parent's `context.jsonl`; child effect receipts are attributed by their checkpoint id.
- **Test:** 3 children produce 3 effect sets; the merge checkpoint contains all 3, and the parent continues without replaying the children.
- **Proof:** the parent's event spine shows `branch_converged` with child checkpoint ids.

## North-star link
Branch-and-converge is delegation. Every child is a shard. Every merge is a reprocessed window. The parent/child contract is the fan-out mechanism of the north star — it is not a separate feature.

## Definition of done
- Children are launched from parent checkpoints.
- Heartbeat + timeout mark abandoned branches.
- Merge produces a new checkpoint, and the parent continues without replaying children.