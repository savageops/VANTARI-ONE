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

Move 21 places the fixed agent pool in one project-local execution-owner tree, so
it survives TUI and short-lived CLI exit. Move 30 now proves source owner-process
death and replacement end to end; the remaining boundary is the hash-matched
installed run. Move 23 closes scheduler split-brain: one crash-released
process lock and one read-back generation fence span each tick. Move 24 closes
ticket admission split-brain: one process lock spans ticket projection,
validation, and append; one winning row commits generation, lease, capability,
attempt, and deterministic child identity before materialization. Move 26 closes
the source mailbox: one event-spine owner resolves direct, parent, and
current-group delivery, persists recipient sequence and sender receipt, injects
bounded unread input, and advances the cursor only after provider success.
Child completion and ticket-claim notices now use that path without parent
transcript injection.
Move 27 closes model-selection drift: `agents {}` now projects only
route-resolvable specialists plus current pool/team/communication state, binds
the exact sorted snapshot to a receipt, and leaves collaboration posture to the
active prompt.
Move 28 closes capacity drift: one `AgentCapacitySnapshot.fromCounts` owner
derives active, idle, queued, and admission headroom; the same physical pool
applies changed config only at an idle boundary while busy projections retain
the actual old ceiling.
Move 29 closes source owner-generation drift: terminal session evidence settles
first; heartbeat requires exact nonterminal `Supervisor` ownership; an expired
claim with a surviving session appends one generation-fenced `resume` and runs
the immutable receipt's same group/task/session/attempt; only an absent session
requeues. Cold receipt reconstruction defers ticket-owned sessions, and
same-session replay preserves one mailbox delivery and cursor.
Move 30 composes those owners through a source-built Windows process mesh. The
tracer detaches a noninteractive TUI, kills the exact owner/kernel tree, waits for
lease expiry, starts a different generation, resumes the same ticket session,
runs two nested children, delivers direct/group/parent mail once, completes the
ticket, and returns the proof-owned process count to zero. It also exposed a real
HTTP bridge cleanup use-after-free; lifecycle release now precedes destruction of
the page-allocated connection job.
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
- [mailbox.zig](../../../apps/backend/src/core/agents/mailbox.zig) owns bounded
  direct, parent, and current-group delivery, idempotent receipts, unread batches,
  provider-success cursors, and queue/wake intent on `events.jsonl`.
- [agent_message.zig](../../../apps/backend/src/core/tools/builtin/agent_message.zig)
  exposes the sole model-facing collaboration write without assigning or
  launching work.
- [spec.zig](../../../apps/backend/src/core/agents/spec.zig) renders one sorted
  `var1.agent_eligibility.v1` snapshot and hashes its exact canonical payload.
- [service.zig](../../../apps/backend/src/core/agents/service.zig) hot-loads the
  registry, filters failed routes, and reads the existing supervisor/session
  projections without adding a selector, registry, or team bus.
- [module.zig](../../../apps/backend/src/core/tools/module.zig) owns the sole
  capacity arithmetic; [supervisor.zig](../../../apps/backend/src/core/agents/supervisor.zig)
  tracks submitted closures through their terminal persistence tail and replaces
  the existing pool only after it becomes idle.
- [agent_scale_test.zig](../../../apps/backend/tests/agent_scale_test.zig) drives
  20 tasks through a three-worker ceiling, observes queued backlog, proves
  `running <= max`, drains a live reduction, and applies one worker at release.
- [tickets/index.zig](../../../apps/backend/src/core/tickets/index.zig) owns the
  serialized `resume` transition and rejects wrong revision, session, live lease,
  or poisoned suffix.
- [scheduler/service.zig](../../../apps/backend/src/core/scheduler/service.zig)
  reconciles terminal evidence before owner recovery, renews only owned sessions,
  resumes surviving sessions, and requeues absent sessions.
- [agent_scale_test.zig](../../../apps/backend/tests/agent_scale_test.zig) proves
  one real same-session resume and replay produce one provider call, preserve
  attempt/generation/session, and retain exactly one mailbox delivery/cursor.
- [roadmap move 21](../../roadmap/21-persistent-execution-owner.md) proves one
  owner/kernel generation across client detach, 20 concurrent clients,
  duplicate-start pressure, graceful stop, forced crash, and zero cleanup.

## Required mechanism

Retain the shipped-source execution owner and its sole `AgentService`/
`Supervisor` composition. Retain the shipped inter-process scheduler guard and
generation projection. Retain the process-serialized ticket claim and
deterministic child identity. Do not create a parallel pool or admission ledger.

Retain the shipped eligibility projection. Let the prompt choose quiet, inspect,
message, challenge, launch, queue, or wake from one route-resolved snapshot. Keep
capacity, team, depth, contact, and communication state read-only in discovery;
revalidate at launch and message effects. Do not add a selector model, behavior
mode branch, shared transcript, or capacity reservation token.

Retain the shipped sequence-addressed mailbox. Resolve direct, parent, and
current-group targets from session receipts. Keep bounded messages and references
on the existing event spine with unread cursors and explicit wake intent. Reuse
depth, capacity, and contact budgets. Do not add a topic registry, shared
transcript, or message-created work lifecycle.

## Acceptance

- Assigning a ticket creates no session and starts no provider turn.
- One claim creates one durable child session.
- Identical route/team/capacity state yields an identical eligibility payload and
  receipt; changed or unavailable state changes the receipt and visible choices.
- Quiet and hive prompts choose different collaboration actions through the same
  executor and tool runtime.
- Configured active work never exceeds the physical pool ceiling; idle, queued,
  and ticket-admission projections remain coherent through contention, release,
  and config refresh.
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
policy also pass. Direct/group/parent and nested-parent mailbox delivery,
idempotent receipts, provider-failure replay, safe-boundary wake, ticket claim,
and child-completion convergence pass in source without transcript replication.
Route filtering, depth denial, queue-only pressure, receipt verification, and
quiet-versus-hive prompt selection also pass through the canonical executor.
Configured capacity now passes Debug and ReleaseFast at 1,953/1,953 tests; a
20-task tracer reaches three active calls, preserves backlog separately, drains
under the old ceiling, and applies the reduced ceiling at idle. The 256-segment
capacity audit finds zero exact duplicates. Same-session owner recovery passes
terminal-first, live-owner heartbeat, absent-session requeue, poisoned-tail,
idempotent replay, and cursor-preservation pressure. Its 139-segment audit finds
zero exact duplicates. The composed lifecycle result at
`.zig-cache/owner-proofs/ddc238496ee944a2bb586db735e6da2a` records one claim,
one resume, two nested children, one direct, one group, one parent message, six
unique received messages, zero transcript copies, one completion, cold
post-shutdown replay, and final zero processes. Separate source pressure settles failed and cancelled children with
`repair_required=true` and rejects repair closure without approval, exact rerun,
and regression evidence. Owner lifecycle evidence is retained at
`.zig-cache/owner-proofs/8e02c2b054864bb699cfd8f6182d4d9a`; scheduler
leadership evidence is retained at
`.zig-cache/owner-proofs/b80d4d5bcc7f438089f9a35dce16ce9a`. Source SHA-256
is `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`;
installed remains the move-19 hash while operator PIDs 12028/14452 are active.
The 10-file, 139-segment lifecycle audit finds six candidates and zero exact
duplicates. This finding stays pending until the installed tracer and new
terminal review pass.

## Source and salvage

- User: “runing persistently until completed”.
- [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent): daemon-backed sessions, goals, heartbeats, and schedule ownership.
- [Eve](https://github.com/vercel/eve): one resolved artifact generation reused through schedule dispatch.
- [Oh My Pi file lock](../../../.refs/can1357__oh-my-pi/crates/pi-natives/src/file_lock/mod.rs): process-owned crash-released exclusion across platforms.
- [Flue task sessions](../../../.refs/withastro__flue/packages/sdk/src/agent-client.ts): deterministic parent-plus-task child identity; VANTARI adds process fencing and append-only claim evidence.
- [OpenAI Codex](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/multi_agents_spec.rs): queued directed message plus separate wake-bearing follow-up semantics.
- [Claude Code teams](https://code.claude.com/docs/en/agent-teams): independent teammate contexts, direct mailbox delivery, and shared task awareness; current resumption limits are a VANTARI rejection target.
- [AutoGen Core](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/message-and-communication.html): serializable direct and broadcast data; reject its topic/subscription breadth for this local hierarchy.
- [OpenAI Agents SDK orchestration](https://openai.github.io/openai-agents-python/multi_agent/): model-owned orchestration with dynamically enabled destinations; reject callback and handoff object layers.
- [AutoGen selector teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/selector-group-chat.html): concise candidate descriptions before model selection; reject a second selector call and broadcast history.

## Out of scope

Do not change ticket schema vocabulary, add dynamic worker classes, or create a second scheduler.
