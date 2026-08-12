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
process lock and one read-back generation fence span each tick. Move 24 closes
ticket admission split-brain: one process lock spans ticket projection,
validation, and append; one winning row commits generation, lease, capability,
attempt, and deterministic child identity before materialization. Child results still reach
parents through convergence-specific code; no general durable direct/group/parent
mailbox exists for restart-safe peer delivery.
Move 25 closes assignment ambiguity: create-as-assigned and
transition-to-assigned append queue state only, and the dead ticket execution
policy is deleted.

## Evidence

- [supervisor.zig:164](../../../apps/backend/src/core/agents/supervisor.zig#L164) owns std.Thread.Pool in-process.
- [supervisor.zig:379](../../../apps/backend/src/core/agents/supervisor.zig#L379) dispatches with pool.spawn.
- [service.zig:925](../../../apps/backend/src/core/agents/service.zig#L925) states that process restart converts running receipts to StaleAgentOwner.
- [cli.zig:814](../../../apps/backend/src/clients/cli.zig#L814) routes `run --session-id` through `LocalClient`; the dead direct `run-session` executor is removed.
- [store.zig](../../../apps/backend/src/core/scheduler/store.zig) acquires
  `.var/schedules/lease.lock`, writes and verifies a nonzero generation, and
  returns a guard held through the tick.
- `prove-scheduler-leadership.ps1` starts two complete source kernels against
  one due job and one assigned ticket. Evidence root
  `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` contains one
  attempt ID, one ticket claim, one matching child session, and the shared
  winning generation.
- [tickets/index.zig](../../../apps/backend/src/core/tickets/index.zig) holds
  `.var/tickets/ledger.lock` across ticket read/validate/append.
- [agents/service.zig](../../../apps/backend/src/core/agents/service.zig) derives
  the child identity from the durable claim key and creates it only after the
  winning append.
- [log_ticket.zig](../../../apps/backend/src/core/tools/builtin/log_ticket.zig)
  proves both assignment paths leave zero claims, active-session ids, and session
  records. `agent_routes.max_concurrency` remains the sole capacity setting.
- [roadmap move 21](../../roadmap/21-persistent-execution-owner.md) proves one
  owner/kernel generation across client detach, 20 concurrent clients,
  duplicate-start pressure, graceful stop, forced crash, and zero cleanup.

## Required mechanism

Retain the shipped-source execution owner and its sole `AgentService`/
`Supervisor` composition. Retain the shipped inter-process scheduler guard and
generation projection. Retain the process-serialized ticket claim and
deterministic child identity. Do not create a parallel pool or admission ledger.

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
per-session executor, two-kernel scheduler fencing, and one-claim/one-child ticket
admission pass in source. Queue-only assignment and deletion of the unused ticket
policy also pass. Installed replacement, active-turn owner-crash
reconciliation, and mailbox delivery remain open; this finding stays pending.

## Source and salvage

- User: “runing persistently until completed”.
- [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent): daemon-backed sessions, goals, heartbeats, and schedule ownership.
- [Eve](https://github.com/vercel/eve): one resolved artifact generation reused through schedule dispatch.
- [Oh My Pi file lock](../../../.refs/can1357__oh-my-pi/crates/pi-natives/src/file_lock/mod.rs): process-owned crash-released exclusion across platforms.
- [Flue task sessions](../../../.refs/withastro__flue/packages/sdk/src/agent-client.ts): deterministic parent-plus-task child identity; VANTARI adds process fencing and append-only claim evidence.
- [OpenAI Codex](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/multi_agents_spec.rs): queued directed message plus separate wake-bearing follow-up semantics.
- [Claude Code teams](https://code.claude.com/docs/en/agent-teams): independent teammate contexts, direct mailbox delivery, and shared task awareness; current resumption limits are a VANTARI rejection target.
- [AutoGen Core](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/message-and-communication.html): serializable direct and broadcast data; reject its topic/subscription breadth for this local hierarchy.

## Out of scope

Do not change ticket schema vocabulary, add dynamic worker classes, or create a second scheduler.
