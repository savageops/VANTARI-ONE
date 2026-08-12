---
id: 036c-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: c
status: done
patch_scope: "Add a typed ticket launch/capacity seam to AgentService and Supervisor so a claimed ticket runs through the existing bounded pool and route registry."
blast_radius: high
blast_radius_justification: "This changes shared tools.AgentService, the supervisor admission contract, and agents.Service route/session creation; failures propagate to child delegation, scheduler callers, and event consumers."
idempotency_contract: conditionally-idempotent
idempotency_notes: "The ticket claim idempotency key is the durable boundary; launch retries must reuse the same request and session/claim evidence. Supervisor group ids reject duplicate admission."
acceptance: "A typed AgentService ticket launch validates the configured agent, resolves one route/profile, creates one canonical session, claims exactly one assigned ticket, and submits exactly one task through Supervisor only when a capacity slot is available; capacity snapshots are truthful."
exit_criterion: "Supervisor exposes bounded capacity and ticket admission, tools.AgentService exposes typed launch/capacity methods, agents.Service implements them, and focused capacity/launch tests pass without a second pool or provider session on assignment."
validation: "C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all; git diff --check"
expected_exit_code: 0
expected_output_pattern: "Build Summary: 9/9 steps succeeded|no whitespace errors"
evidence: >-
  Pinned Zig 0.15.1 app build passed with `Build Summary: 9/9 steps succeeded`.
  A transient source probe, removed after validation, ran the canonical
  Supervisor capacity test and passed 2/2; the typed AgentService ticket
  launch/capacity callback test passed 2/2; the Service incomplete-admission
  guard test passed 2/2. The focused assertions cover live max/queued/running/
  available pressure, terminal-slot release, saturation, typed receipt identity,
  and eight pre-side-effect launch rejection cases. `git diff --check` exited 0;
  Git reported only existing LF/CRLF normalization warnings. No scheduler or
  TUI files were changed.
conflict_surface: "035-provider-cost-compat-model"
invariants:
  - "I1: assigned remains provider/session side-effect free."
  - "I2: claim is the only ticket admission idempotency boundary."
  - "I3: in_progress has complete worker/lease/session/agent evidence."
  - "I4: execution enters only through Supervisor and configured route/profile."
  - "I8: existing provider-chain changes remain intact."
source_message_anchor: "U2, U3, U5, U7"
source_message_excerpt: "have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.; an agent that is most relevant expertise/skill should pick up the task; agents that pick up a ticket, may use explore, tools, and research/plan agents.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Reuse the configured bounded supervisor as the worker pool, resolve the most relevant validated agent route, preserve nested explore/tool/research capability through the existing child service, and expose no eager provider work from assignment."
entry_state: "036b is archived with a typed TicketStore claim API; parent 036 is pending with 036c current; Supervisor currently has immediate submitGroup admission and no public capacity snapshot."
rollback_surface: "Revert only the tools.AgentService additions, supervisor capacity/ticket admission methods, agents.Service ticket launcher, and focused tests; preserve 036b ticket files and all unrelated 035 changes."
dependencies: "036b-ticket-agent-pool-and-repair"
next_todo: /todo/pending/036d-ticket-agent-pool-and-repair.md
continuation: "On completion: capture exact build/probe evidence, set status done, move this file to /todo/changelog/036c-ticket-agent-pool-and-repair.md, continue immediately to 036d."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036c Supervisor-backed ticket launch

## Execute Now

Add the typed capacity and ticket-launch seam that turns one durable ticket claim into one Supervisor task without creating a parallel execution pool.

## Slice Focus Rule

This unit owns the shared agent execution seam. Do not add scheduler ticks, TUI rows, or repair promotion here; the scheduler consumes the capacity/launch contract in 036d. Preserve the current batch delegation path and patch overlapping provider-chain lines narrowly.

## Why This Execution Unit Exists

The ticket store now knows how to claim a revision, but it cannot safely choose a worker or start a task without the existing agent registry, route resolver, session receipt, and Supervisor. The Supervisor currently spawns all submitted group tasks immediately and has no capacity read model. This slice adds the smallest typed bridge: capacity is measured from the existing task map, and ticket admission is rejected when no bounded slot is available.

## Better-Than-Before Delta

Before this unit, “pool” meant only an internal thread pool that batch delegation could over-admit, while tickets had no path into it. After this unit, a ticket launch has one typed request, one route receipt, one claim/session boundary, one task group, and a truthful max/queued/running/available snapshot. Existing child delegation remains on the same Supervisor authority.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|----------------|----------------|----------------------------|-----------------------|
| A bounded worker pool must expose admission pressure, not only a configured max. | `supervisor.zig:154-176,301-353`; research artifact worker-slot contract. | Count queued/running tasks under the Supervisor mutex and reject ticket admission when full. | Do not report `max_concurrency` as active workers or create another queue. |
| Route selection must be registry-owned and capability-bound. | `agents/spec.zig:185-239,426-480`; `providers/routes.zig`; root tool contract. | Resolve explicit agent ids, category fallback, route role, profile, capability hash, and model from current config before claim/session. | Do not let a free-form owner path become a provider route. |
| Provider execution starts after claim and session evidence. | 036b claim contract; `supervisor.runTaskEntry`. | Create session/receipt, claim ticket, then submit the prepared task. Failed claim/admission reconciles evidence. | Do not launch from `assigned` or bypass Supervisor with a scheduler provider call. |
| Nested agent capability stays within existing delegation policy. | `agents/profile.zig`, `agents/scope.zig`, existing child service handle. | Pass the existing AgentService handle and bounded remaining depth into the ticket task. | Do not invent ticket-specific explore/research executors. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|-------------------------|-----------------|---------------------|------------------|
| Supervisor task counts and spawn lifecycle | Inspect task/group lifecycle and existing tests. | Repository source/tests | Capacity snapshot and PoolFull boundary. | `supervisor.zig` source and tests. |
| Session receipt fields | Inspect `ExecutionReceiptView` and `initSessionWithExecutionReceipt`. | Repository source | Ticket child session metadata. | `shared/types.zig`, `sessions/store.zig`, `agents/service.zig`. |
| Agent selection and fallback | Inspect current registry/built-in ids and category hint from 036b. | Repository source + saved harvest | Valid agent resolution. | Route/registry tests. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `core/tools/module.zig`, `core/agents/supervisor.zig`, `core/agents/service.zig`, `core/agents/spec.zig`, `core/providers/routes.zig`, `core/sessions/store.zig`, `core/tickets/index.zig`. |
| Existing-owner decision | Extend AgentService and Supervisor; do not add `TicketWorkerPool`, provider cache, or ticket daemon. |
| Domain owner / canonical standard | Supervisor owns worker admission/cancellation; AgentService owns registry/route/session construction; TicketStore owns ticket claim. |
| Intended design | `capacity() -> select configured agent -> prepare route/session -> TicketStore.claim -> Supervisor.submitTicketGroup -> TicketLaunchReceipt`. |
| Integration path | Scheduler will call `AgentService.capacity` and `AgentService.launchTicket`; child task uses existing `runTaskEntry` and nested handle. |
| Failure modes to prevent | over-admission, duplicate group, invalid route, claim/session mismatch, provider bypass, missing parent, route disposal leak. |
| Alternatives rejected | Holding idle provider contexts, direct `loop.runPromptWithOptions` from scheduler, reusing public batch launch with a second session, global worker registry. |
| Proof hooks | Supervisor capacity tests, PoolFull tests, route fallback tests, claim/session receipt test, no-assignment-side-effect test. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `supervisor.zig:22-1175`, `service.zig:23-555`, `tools/module.zig:163-365`, `agents/spec.zig:185-239,426-480`, `routes.zig:13-241`, and `sessions/store.zig:202-326` before editing.

**Existing-owner directive:** Add typed fields to `tools.AgentService`; implement callbacks in `agents.Service`; add `capacity` and `submitTicketGroup` to `agents.Supervisor`; reuse the existing `TaskInput`, `ExecutionReceiptView`, and `runTaskEntry` path.

**Directive:** `submitTicketGroup` must count queued/running tasks under the same mutex that publishes the group, return `PoolFull` before any provider task starts, and own one prepared task only after successful admission.

**Gold-standard guardrail:** Do not claim a ticket in the scheduler and then call ordinary `launchBatch`; that creates a second child session and breaks claim/session identity.

**Knowledge gathering route:** Repository-local source and 036b research are sufficient. Re-check the 035 provider diff before editing supervisor/service route construction.

**Runtime visualization:** `scheduler capacity -> Service launchTicket -> registry/route/session receipt -> TicketStore.claim -> Supervisor.submitTicketGroup -> existing runTaskEntry -> child event/session evidence`.

**Proof expansion:** Run the pinned app build plus focused capacity/launch tests; preserve the bounded full-suite boundary for 036f.

**Action-mode arbitration:** This is delegated asynchronous work. The typed request must carry claim identity, worker generation, lease, attempt, route/profile, and session parent; no background side effect may be hidden behind a capacity query.

## Embedded Framing

The pool is a capacity contract, not a fantasy roster: a slot is available only when the existing Supervisor can admit one task and the route/session evidence is ready to explain it.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Bounded task admission | Prevent a max-only status display. | `ix inspect` | Supervisor source/tests | Capacity and PoolFull tests. |
| Route/profile identity | Prevent free-form skill drift. | `ix inspect` | Registry/routes/profile source | Typed launch receipt. |
| Session/task ownership | Keep event/session truth canonical. | `ix inspect` | Session store + supervisor source | Claim/session/group identity test. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U2 | “have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.” | Capacity comes from the configured Supervisor ceiling and live task counts; no idle provider roster is created. | Capacity snapshot tests. |
| U3 | “an agent that is most relevant expertise/skill should pick up the task” | Explicit valid agent wins; otherwise category hint resolves to a configured specialist and persists in the launch receipt. | Registry/route tests. |
| U5 | “agents that pick up a ticket, may use explore, tools, and research/plan agents.” | Ticket child receives existing AgentService/nested capability policy. | Task input and child-service assertions. |
| U7 | “Apply this to vantari. leave the code better than you find it. whenever you look at it” | One bounded owner replaces ambiguity without adding a parallel execution system. | Ownership diff/review. |

## Pre-flight Checklist

- [x] 036b is archived with evidence.
- [x] Supervisor/service/module owner boundaries are read from current source.
- [x] 035 overlap is declared.
- [x] No scheduler/TUI changes are in scope.

## Entry State

- `TicketStore.claim` is available and requires expected revision plus session/lease/agent evidence.
- Supervisor owns the only live thread pool but has no capacity snapshot or ticket-specific admission.
- AgentService handle has batch/child callbacks but no ticket callback.

## Patch Surface

**Modifies:**

- `apps/backend/src/core/tools/module.zig` — add typed ticket launch request/receipt and capacity callback surface.
- `apps/backend/src/core/agents/supervisor.zig` — add capacity snapshot and bounded ticket group admission.
- `apps/backend/src/core/agents/service.zig` — implement ticket route/session/claim/task launch and handle callbacks.
- `apps/backend/src/core/tickets/index.zig` — separate source session from active ticket execution session if required by the launch receipt.

**Adds:**

- Focused tests in the touched canonical owners only.

**Deletes:**

- None.

**Must not touch (out of scope for this unit):**

- `core/scheduler/*`, TUI files, provider adapters unrelated to route resolution, and the 035 provider feature's unrelated lines.

## Detailed Requirements

- R1: Define `AgentCapacitySnapshot { max, queued, running, available }`; values come from Supervisor's mutex-protected task map.
- R2: Define typed `TicketTaskRequest` and `TicketLaunchReceipt`; do not encode the scheduler/service contract as JSON.
- R3: Add optional `capacityFn` and `launchTicketFn` to `tools.AgentService` without breaking existing handles/tests.
- R4: Implement `Supervisor.submitTicketGroup` for exactly one task and return `PoolFull` before group/task execution when queued+running reaches max.
- R5: Keep ordinary `submitGroup` behavior unchanged for existing batch delegation.
- R6: Resolve current registry each ticket launch; explicit valid id wins, otherwise map the 036b category hint to a built-in/validated specialist.
- R7: Create one child session with `ExecutionReceiptView`, including ticket id in display/evidence metadata, before provider dispatch.
- R8: Claim the ticket with the exact child session id, selected agent id, capability hash, worker/lease/attempt fields, and expected revision before Supervisor submission.
- R9: Submit exactly one prepared task through `submitTicketGroup`; if submission fails, persist a failure/reconciliation event and do not report launch success.
- R10: Pass the existing AgentService handle and bounded `remaining_depth` to preserve nested explore/tool/research/plan delegation.
- R11: Dispose route/session/task allocations correctly on invalid route, claim conflict, PoolFull, and successful terminal ownership transfer.
- R12: Add at least 30 meaningful capacity/launch/route/session feature-value cases.

## Invariants This Unit Must Preserve

- I1-I4 and I8 from the parent.
- Ordinary child batch launch remains behaviorally compatible.
- Capacity query has no provider/session side effect.
- A successful launch receipt's ticket id, claim session id, task id, group id, and execution receipt agree.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|---------------------|-------------------------|------------|
| 1 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe build --summary all` | `0` | `Build Summary: 9/9 steps succeeded` | yes |
| 2 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe test src/ticket_probe.zig --test-filter 'capacity'` | `0` | focused capacity tests pass | yes |
| 3 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe test src/ticket_probe.zig --test-filter 'ticket launch'` | `0` | focused launch tests pass | yes |
| 4 | `git diff --check` | `0` | no whitespace errors | yes |

**Evidence to capture:** Pinned compile output, focused Supervisor/Service output, capacity snapshot values, launch receipt plus session/ticket ledger identity, and diff check.

## Exit State (Handoff Contract)

- Scheduler can query available bounded capacity without starting a provider.
- Scheduler can call one typed ticket launch after selecting an assigned ticket; successful launch means claim/session/group/task identity is durable and consistent.
- 036d owns wake, capacity admission loop, heartbeat, stale requeue, and terminal reconciliation.

## Rollback Procedure

1. Revert only the 036c additions in `tools/module.zig`, `agents/supervisor.zig`, `agents/service.zig`, and any source-session field additions in `core/tickets/index.zig`.
2. Re-run the 036b focused ticket tests and pinned app build.
3. Preserve all unrelated 035 edits and the archived 036b artifact.

## Next todo

`/todo/pending/036d-ticket-agent-pool-and-repair.md`

## Completion

- [x] Pre-flight passed.
- [x] Implementation-unit test floor satisfied: ≥30 meaningful feature-value assertions across capacity, launch, receipt, and guard paths.
- [x] Capacity and typed ticket launch prove the intended Supervisor seam; full child execution remains 036d/036f proof.
- [x] All validation commands executed with matching output.
- [x] Exit state verified.
- [x] Evidence captured; `PLACEHOLDER` removed.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036c-ticket-agent-pool-and-repair.md`.
- [x] Continue immediately to `036d`.
