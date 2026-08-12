---
type: finding
id: harness-finding-11
status: pending
priority: P0
owner: apps/backend/src/core/agents
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Persistent agent worker and scheduler arbitration

## Finding

Move 21 now places the fixed agent pool in one project-local execution-owner
tree, so it survives TUI and short-lived CLI exit. The remaining failure boundary
is owner-process death: in-memory work is marked stale rather than resumed or
requeued exactly once. Move 23 closes scheduler split-brain: one crash-released
process lock and one read-back generation fence span each tick. Ticket claim plus
lease issuance is still not one serialized transition. Child results still reach
parents through convergence-specific code; no general durable direct/group/parent
mailbox exists for restart-safe peer delivery.

## Evidence

- [supervisor.zig:164](../../../apps/backend/src/core/agents/supervisor.zig#L164) owns std.Thread.Pool in-process.
- [supervisor.zig:379](../../../apps/backend/src/core/agents/supervisor.zig#L379) dispatches with pool.spawn.
- [service.zig:925](../../../apps/backend/src/core/agents/service.zig#L925) states that process restart converts running receipts to StaleAgentOwner.
- [cli.zig:814](../../../apps/backend/src/clients/cli.zig#L814) routes `run --session-id` through `LocalClient`; the dead direct `run-session` executor is removed.
- [store.zig](../../../apps/backend/src/core/scheduler/store.zig) acquires
  `.var/schedules/lease.lock`, writes and verifies a nonzero generation, and
  returns a guard held through the tick.
- `prove-scheduler-leadership.ps1` starts two complete source kernels against
  one due job. Evidence root
  `.zig-cache/owner-proofs/e421ccb28240402ead1fbcbcb3903335` contains one
  attempt ID, one reserved row, one completed row, and the winning generation.
- [roadmap move 21](../../roadmap/21-persistent-execution-owner.md) proves one
  owner/kernel generation across client detach, 20 concurrent clients,
  duplicate-start pressure, graceful stop, forced crash, and zero cleanup.

## Required mechanism

Retain the shipped-source execution owner and its sole `AgentService`/
`Supervisor` composition. Retain the shipped inter-process scheduler guard and
generation projection. Next, serialize ticket claim plus lease issuance and
verify that same worker generation before dispatch. Do not create a parallel
pool.

Use that same owner for one sequence-addressed agent mailbox. Resolve direct,
parent, and current-group targets from session receipts. Queue bounded messages
and references on the existing event spine; persist unread cursors and explicit
wake intent. Reuse depth, capacity, and contact budgets. Do not add a topic
registry, shared transcript, or message-created work lifecycle.

## Acceptance

- Assigning a ticket creates no session and starts no provider turn.
- One claim creates one durable child session.
- Closing the TUI does not stop claimed work.
- Killing the worker leaves a durable stale receipt; restarting reconciles and resumes or requeues exactly once.
- Two concurrent kernels produce one lease winner and one LeaseUnavailable loser.
- Completion, failure, cancellation, heartbeat expiry, and repair-required closure survive cold start.
- Directed, group, parent, and nested-parent messages survive worker restart,
  deliver once, expose an operator-auditable receipt, and never duplicate sibling
  transcripts into recipient context.

Current receipt: TUI/CLI detach, duplicate-start exclusion, graceful owner stop,
forced owner-tree cleanup, one-generation recovery, deletion of the dead
per-session executor, and two-kernel scheduler fencing pass in source. Installed
replacement, active-turn owner-crash reconciliation, ticket claim serialization,
and mailbox delivery remain open; this finding stays pending.

## Source and salvage

- User: “runing persistently until completed”.
- [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent): daemon-backed sessions, goals, heartbeats, and schedule ownership.
- [Eve](https://github.com/vercel/eve): one resolved artifact generation reused through schedule dispatch.
- [Oh My Pi file lock](../../../.refs/can1357__oh-my-pi/crates/pi-natives/src/file_lock/mod.rs): process-owned crash-released exclusion across platforms.
- [OpenAI Codex](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/multi_agents_spec.rs): queued directed message plus separate wake-bearing follow-up semantics.
- [Claude Code teams](https://code.claude.com/docs/en/agent-teams): independent teammate contexts, direct mailbox delivery, and shared task awareness; current resumption limits are a VANTARI rejection target.
- [AutoGen Core](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/message-and-communication.html): serializable direct and broadcast data; reject its topic/subscription breadth for this local hierarchy.

## Out of scope

Do not change ticket schema vocabulary, add dynamic worker classes, or create a second scheduler.
