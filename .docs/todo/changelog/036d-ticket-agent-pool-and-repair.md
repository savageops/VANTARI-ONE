---
id: 036d-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: d
status: done
patch_scope: "Make the existing scheduler the single ticket wake, lease, heartbeat, dispatch, stale-recovery, and terminal-reconciliation owner."
blast_radius: high
blast_radius_justification: "The scheduler thread becomes a consumer of the durable ticket projection and a caller of the shared AgentService; host lifecycle, ticket leases, child session status, and existing cron/shell execution must remain correct."
idempotency_contract: conditionally-idempotent
idempotency_notes: "One scheduler owner lease gates each tick. Ticket claim, heartbeat, requeue, and completion keys derive from ticket id, expected revision, and attempt so retry and cold start replay do not duplicate admission or terminal evidence."
acceptance: "An assigned ticket is selected only when the shared Supervisor reports a slot, launched through AgentService exactly once, kept alive by a durable heartbeat, requeued after an expired lease, and completed only from terminal child-session evidence; existing scheduled prompt/shell jobs retain their current behavior."
exit_criterion: "Scheduler Service has one bounded ticket maintenance/dispatch loop, host passes the live AgentService handle, TicketStore supports claim renewal, and focused scheduler/lease/recovery tests pass without a second worker or provider path."
validation: "C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all; pinned focused scheduler tests; git diff --check"
expected_exit_code: 0
expected_output_pattern: "Build Summary: 9/9 steps succeeded|focused scheduler tests passed|no whitespace errors"
evidence: "2026-08-10: pinned Zig 0.15.1 build passed with Build Summary: 9/9 steps succeeded; focused scheduler probe with VANTARI_HOME cleared for temporary lease isolation passed all 14 tests; focused ticket filter passed all 18 tests; git diff --check exited 0 with only repository LF/CRLF normalization warnings; eight added scheduler tests contain 95 meaningful assertions covering dispatch, capacity, ordering, permanent failure, backpressure, heartbeat, stale recovery, terminal evidence, repair marking, and idempotent completion replay."
conflict_surface: "035-provider-cost-compat-model; 036c-ticket-agent-pool-and-repair"
invariants:
  - "I1: assignment remains provider/session/supervisor side-effect free until dispatch."
  - "I2: the durable ticket claim is the only admission boundary; scheduler retries do not create a second child session."
  - "I3: in_progress retains worker, generation, lease, attempt, agent, capability, and active session evidence."
  - "I5: one scheduler owner lease gates ticket maintenance and dispatch in this process."
  - "I6: expired claims requeue with a durable failure class and a new revision; live claims renew before expiry."
  - "I7: completed ticket state is written only after child session terminal evidence is readable."
  - "I8: existing scheduled prompt and shell jobs remain behaviorally compatible."
source_message_anchor: "U2, U3, U4, U5, U7"
source_message_excerpt: "have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.; when we assign a ticket, it doesnt start immediately.; an agent that is most relevant expertise/skill should pick up the task; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Turn assignment into buffered admission, let the configured pool pull work when capacity exists, preserve relevant-agent routing and nested capabilities, and make restart/lease behavior truthful."
entry_state: "036c is archived with Supervisor capacity and typed AgentService ticket launch; scheduler runs existing cron jobs only and TicketStore has no renewal operation."
rollback_surface: "Revert only scheduler ticket maintenance/dispatch, the AgentService-aware scheduler initializer/host wiring, TicketStore renewal, and focused tests; preserve 036b/036c ticket and supervisor seams plus unrelated 035 changes."
dependencies: "036c-ticket-agent-pool-and-repair"
next_todo: /todo/pending/036e-ticket-agent-pool-and-repair.md
continuation: "On completion: capture exact build/probe/ledger evidence, set status done, move this file to /todo/changelog/036d-ticket-agent-pool-and-repair.md, continue immediately to 036e."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036d Scheduler-backed ticket dispatch and recovery

## Execute Now

Extend the existing scheduler tick into the durable ticket work loop. Keep one scheduler owner, one Supervisor capacity source, one AgentService launch seam, and one TicketStore event ledger.

## Slice Focus Rule

This unit owns wake, lease, heartbeat, dispatch, stale requeue, and terminal reconciliation. Do not add TUI rows, RPC fields, a ticket worker registry, idle provider contexts, or a second scheduler thread; 036e owns the operator projection and 036f owns integrated installed proof.

## Why This Execution Unit Exists

036b made ticket claims serializable and 036c made one claim executable through the bounded Supervisor. Without a scheduler consumer, `assigned` is still a dead queue. This slice connects the queue to the existing wake owner and makes restarts recoverable without treating an assignment as execution.

## Better-Than-Before Delta

Before this unit, scheduled work and ticket work had separate realities: cron jobs woke, while tickets waited for a caller. After this unit, one durable scheduler lease wakes both lanes; tickets remain queued until Supervisor capacity exists, claim identity is stable across retry, live work renews its lease, expired work returns to `assigned`, and terminal child evidence advances the ticket.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|-----------------|----------------|----------------------------|-----------------------|
| A queue worker must claim before side effects and make the claim recoverable. | `core/tickets/index.zig:351-430`; 036c typed launch. | Scheduler selects assigned tickets, then AgentService performs the claim immediately before Supervisor admission. | Do not transition `assigned` to `in_progress` in scheduler code or call the provider directly. |
| Lease ownership must be renewed by the owner and reclaimed after expiry. | 036b lease fields; scheduler durable owner lease in `scheduler/store.zig:266-291`. | Add a typed claim-renewal event and call requeue on expired claims under the scheduler owner. | Do not infer liveness from process presence or timestamps without a ledger event. |
| Terminal state requires an effect receipt, not only a process exit. | Session store status/output and Supervisor terminal evidence. | Read child session status and output/failure evidence, then call `TicketStore.complete` with an idempotency key. | Do not mark completed from `launchTicket` return or a missing session as success. |
| A single capacity source prevents over-admission. | `agents.Supervisor.capacity`, `submitTicketGroup`; 036c receipt. | Query AgentService capacity for dispatch ordering; let Supervisor perform the final serialized admission check. | Do not cache capacity in scheduler state or add a worker pool. |
| Existing scheduler work must remain stable while ticket work is added. | `scheduler/service.zig:50-131`; current scheduler tests. | Keep due-job reservation/execution unchanged and add ticket maintenance as a bounded neighboring phase. | Do not route prompts/shells through ticket claims or change their attempt ledger. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|--------------|--------------------------|-----------------|---------------------|------------------|
| Scheduler lease and tick ordering | Inspect `scheduler/store.zig` and existing service tests. | Repository source/tests | Maintenance order and single-owner boundary. | Scheduler lease test plus tick result. |
| Child terminal evidence | Inspect Supervisor `runTaskEntry`, session record/status/output, and existing event projection. | Repository source | Complete vs retry vs stale decision. | Session/ticket ledger excerpt. |
| Claim-renewal revision semantics | Inspect TicketStore projection/revision/idempotency behavior. | `core/tickets` source | Heartbeat event shape and exact retry key. | Renewal replay test. |
| Capacity race behavior | Inspect `submitTicketGroup` mutex boundary. | 036c source/tests | Scheduler preflight is advisory; Supervisor admission is authoritative. | Saturated dispatch test. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `core/scheduler/service.zig`, `core/scheduler/store.zig`, `core/scheduler/index.zig`, `host/stdio_rpc.zig`, `core/tickets/index.zig`, `core/tools/module.zig`, `core/agents/service.zig`, `core/agents/supervisor.zig`, session store/types. |
| Existing-owner decision | Extend `scheduler.Service`; add `TicketStore.renewClaim`; pass the existing `tools.AgentService` handle from `stdio_rpc`. Do not create `TicketScheduler`, `TicketWorkerPool`, or `TicketDaemon`. |
| Tick order | Acquire scheduler owner lease → requeue expired claims → renew near-expiry live claims → reconcile terminal child sessions → read capacity → select oldest assigned tickets → call typed AgentService launch until capacity is exhausted. |
| Worker identity | `worker_id` is the current scheduler owner id; `worker_generation` is a stable per-owner generation for the process; claim idempotency and lease tokens derive from ticket id, expected revision, and attempt. |
| Dispatch selection | Read the projection, ignore poisoned suffixes as a named failure, select `assigned` tickets by `updated_at_ms` then id, and do not mutate before AgentService launch. `PoolFull` leaves the ticket assigned. Invalid route/parent blocks the ticket with durable reason. |
| Heartbeat | Add `TicketStore.renewClaim` with expected revision, active session, worker, lease token, new expiry, and idempotency key. Renew only near expiry; revision advances and `claim_complete` remains true. |
| Terminal reconciliation | For each in-progress ticket, read the active child session and its output/failure evidence. Completed/failed/cancelled sessions write one `complete` event; incomplete or missing live records stay in progress until the lease policy decides. |
| Recovery | Expired `in_progress` tickets call `requeueExpired`; stale child session id is preserved as `last_session_id`; a later assignment creates a new claim/session/attempt. |
| Existing schedule lane | Preserve due job reservation, prompt execution, shell execution, attempt completion, and current `TickResult` fields; add ticket counters rather than replacing schedule counts. |
| Host lifecycle | `serveKernel` calls an AgentService-aware scheduler initializer; server shutdown stops and joins the same scheduler thread before service deinit. |

## Codebase Research And Execution Addendum

**Implementation map:** Read `scheduler/service.zig:1-188`, `scheduler/store.zig:207-291,390-445`, `host/stdio_rpc.zig:178-305,340-342`, `tickets/index.zig:251-630`, `agents/service.zig:341-555`, `agents/supervisor.zig:319-390,470-523`, and `sessions/store.zig:277-365,490-545,1216-1228` before editing.

**Existing-owner directive:** Scheduler owns wake and serialized lease; TicketStore owns ticket lifecycle events; AgentService owns route/session/claim/submit; Supervisor owns final task capacity/admission; session storage owns terminal status/output. No owner may infer another owner's state from a shadow registry.

**Gold-standard guardrail:** A ticket is not “started” because capacity is positive. It is started only when the AgentService launch receipt agrees with the durable claim, child session, task, and group identity.

**Failure handling directive:** `PoolFull` is expected backpressure and leaves the ticket assigned. Invalid agent, route, missing parent, poisoned ledger, and irreconcilable launch errors are durable blocked/failure evidence; do not spin a one-second retry loop over a permanent error.

**Runtime visualization:**

```text
owner lease -> expired claim recovery -> heartbeat -> terminal read
           -> capacity snapshot -> assigned ticket selection
           -> AgentService.launchTicket -> TicketStore.claim
           -> Supervisor.submitTicketGroup -> child session/events
           -> terminal receipt -> TicketStore.complete
```

**Proof expansion:** Run focused scheduler/ticket tests with temporary probes only when a source module cannot be tested directly because of Zig module-root imports; remove every probe after the run. Record exact ticket/session/event identities for one dispatch and one stale recovery.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U2 | “have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.” | Scheduler reads live Supervisor capacity and never creates a second pool. | Capacity/PoolFull dispatch test. |
| U3 | “an agent that is most relevant expertise/skill should pick up the task” | The scheduler passes ticket category/hint to the existing registry-owned AgentService. | Launch receipt and claim agent id. |
| U4 | “when we assign a ticket, it doesnt start immediately.” | Assignment remains `assigned` until a capacity-admitted launch occurs. | Assignment-only and full-slot test. |
| U5 | “agents that pick up a ticket, may use explore, tools, and research/plan agents.” | Existing nested AgentService handle remains in the Supervisor task. | Task/service capability assertion. |
| U7 | “Apply this to vantari. leave the code better than you find it. whenever you look at it” | Recovery and shutdown are truthful, bounded, and owned by existing lifecycle code. | Restart/lease and diff ownership audit. |

## Pre-flight Checklist

- [x] 036c is archived with build and focused capacity/launch evidence.
- [x] Parent manifest and frontier point to 036d.
- [x] Scheduler, host, ticket, session, AgentService, and Supervisor owners are read from current source.
- [x] Existing scheduled prompt/shell behavior is declared out of replacement scope.

## Patch Surface

**Modifies:**

- `apps/backend/src/core/tickets/index.zig` — add typed claim renewal and replay semantics.
- `apps/backend/src/core/scheduler/service.zig` — add ticket maintenance/dispatch/reconciliation to the existing tick.
- `apps/backend/src/host/stdio_rpc.zig` — pass the existing AgentService handle into scheduler lifecycle.
- `apps/backend/src/core/scheduler/index.zig` — expose only any new scheduler-owned types/functions required by tests/clients.

**Adds:**

- Focused scheduler/ticket recovery tests in canonical owners only.

**Deletes:**

- None.

**Must not touch:**

- TUI/RPC response schema, provider adapters, `core/tools/builtin/log_ticket.zig`, unrelated 035 provider lines, or a new worker registry/pool.

## Detailed Requirements

- R1: `scheduler.Service` accepts the live `tools.AgentService` handle without breaking existing unit-test initialization.
- R2: Ticket maintenance runs under the existing durable scheduler owner lease and does not start a provider/session from assignment alone.
- R3: Expired claims requeue exactly once per revision/attempt and preserve the previous child session as `last_session_id`.
- R4: Near-expiry live claims renew through a typed TicketStore event with expected revision, session, worker, and lease identity checks.
- R5: Dispatch is capacity-aware but Supervisor-authoritative; `PoolFull` leaves the ticket assigned and does not create a claim/session.
- R6: Dispatch selects the oldest assigned ticket first and passes the stored source session/category/hint into `AgentService.launchTicket`.
- R7: Permanent launch failures produce a durable blocked transition with reason and idempotency key; transient backpressure remains queued.
- R8: Terminal child session evidence maps to one `TicketStore.complete` event with a bounded terminal receipt and repair-required flag when failure evidence demands it.
- R9: Completion/reconciliation retries are idempotent and do not duplicate terminal events.
- R10: Existing scheduled prompt/shell jobs and their attempt ledger remain compatible.
- R11: Shutdown requests the scheduler stop before AgentService/Supervisor teardown and joins the existing thread.
- R12: Add at least 30 meaningful feature-value cases across ticket renewal, recovery, admission, reconciliation, and existing schedule compatibility.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|---------------------|-------------------------|------------|
| 1 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe build --summary all` | `0` | `Build Summary: 9/9 steps succeeded` | yes |
| 2 | Pinned transient scheduler probe with `--test-filter 'ticket'` | `0` | dispatch/backpressure/heartbeat/requeue/terminal tests pass | yes |
| 3 | Pinned transient scheduler probe with `--test-filter 'schedule'` | `0` | existing empty/shell schedule tests pass | yes |
| 4 | `git diff --check` | `0` | no whitespace errors; line-ending warnings named if present | yes |

**Evidence to capture:** exact build output, focused ticket counts, scheduler lease/heartbeat/requeue/complete event rows, one receipt identity chain, existing schedule test output, and diff ownership check.

## Exit State (Handoff Contract)

- A running host wakes ticket work through the existing scheduler thread.
- Assignment remains buffered until a Supervisor slot is actually admitted.
- Live claims have durable renewal; dead claims return to `assigned` after expiry.
- Terminal child evidence produces one durable completion event; repair promotion remains 036e/036f.
- 036e owns the minimal typed operator projection over these events.

## Rollback Procedure

1. Revert only scheduler ticket maintenance, host AgentService wiring, TicketStore renewal, and 036d tests.
2. Re-run 036c focused capacity/typed callback probes and the pinned app build.
3. Preserve 036b/036c artifacts and all unrelated provider changes.

## Next todo

`/todo/pending/036e-ticket-agent-pool-and-repair.md`

## Completion

- [x] Pre-flight passed.
- [x] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests.
- [x] Scheduler wakes and dispatches through the existing Supervisor path.
- [x] Heartbeat, stale requeue, and terminal reconciliation prove durable identity.
- [x] Existing scheduled prompt/shell tests remain green.
- [x] All validation commands executed with matching output.
- [x] Exit state verified.
- [x] Evidence captured; `PLACEHOLDER` removed.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036d-ticket-agent-pool-and-repair.md`.
- [x] Continue immediately to `036e`.
