---
id: 036a-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: a
status: done
patch_scope: "Interpretation freeze and invariant declaration. No artifact change."
blast_radius: low
blast_radius_justification: "No source or runtime artifact changes; this unit only locks the contract for later slices."
idempotency_contract: idempotent
idempotency_notes: "No artifact change; re-reading the same owner and research evidence is safe."
acceptance: "The ticket pool, claim, recovery, repair, and operator-visibility interpretations are explicit and no downstream unit can reintroduce assignment-triggered execution or a parallel owner."
exit_criterion: "Parent and this unit contain the complete ordered chain, source-message proof, invariants, conflicts, and verified current-owner boundaries."
validation: "Get-Content -LiteralPath .docs/todo/pending/036-ticket-agent-pool-and-repair.md; Get-Content -LiteralPath .docs/todo/pending/036a-ticket-agent-pool-and-repair.md"
expected_exit_code: 0
expected_output_pattern: "source_message_anchor|I1:|I8:|036b-ticket-agent-pool-and-repair"
evidence: "Parent and baseline readbacks succeeded; git status preserved the existing 035 provider worktree changes and showed no 036 source artifact change."
conflict_surface: "035-provider-cost-compat-model"
invariants:
  - "I1: assigned is provider/session side-effect free."
  - "I2: claim is one serialized idempotency boundary."
  - "I3: in_progress carries durable worker, lease, agent, attempt, and session evidence."
  - "I4: supervisor remains the provider execution authority."
  - "I5: stale work is requeued or blocked with durable evidence."
  - "I6: completed and closed remain distinct."
  - "I7: UI state is a typed projection."
  - "I8: current provider-chain changes are preserved."
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7"
source_message_excerpt: "setting to assigned shouldnt trigger an agent.; have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.; an agent that is most relevant expertise/skill should pick up the task; proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.; agents that pick up a ticket, may use explore, tools, and research/plan agents.; context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Freeze the exact user contract: queue admission is not execution, configured capacity and deterministic expertise selection govern claims, persistent completion and recovery are required, operator state is minimal and truthful, and every slice must improve the existing owner structure."
entry_state: "The repository contains the researched ticket architecture artifact and the 036 parent chain; existing user changes remain dirty and are not to be reset."
rollback_surface: "None; no artifact change."
dependencies: ""
next_todo: /todo/pending/036b-ticket-agent-pool-and-repair.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/036a-ticket-agent-pool-and-repair.md, continue immediately to 036b."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036a Baseline and contract lock

## Execute Now

Lock the ticket pool interpretation and verify that every later patch extends a canonical owner without triggering execution from `assigned`.

## Slice Focus Rule

This unit owns interpretation only. Do not implement, refactor, or patch sibling surfaces; do not reopen the parent design after this lock. Any newly discovered ambiguity becomes an explicit blocked risk for the owning implementation unit.

## Why This Execution Unit Exists

The user request changes the meaning of assignment, not only its label. The current ticket tool, supervisor, scheduler, session store, event spine, and TUI each own adjacent behavior, so an unrecorded interpretation would produce parallel state or an eager provider call. This baseline makes the state machine, evidence boundary, and consumer proof explicit before source changes begin.

## Better-Than-Before Delta

Before this unit, the architecture lived in research and scattered owner behavior. After it, the implementation chain has a reviewable state contract, a fixed owner map, source-message proof, conflict declaration, and falsifiable acceptance signals. The code is unchanged by design; the next unit is constrained to improve the real ticket owner.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|----------------|----------------|----------------------------|-----------------------|
| Queue admission and execution are separate state transitions. | `core/tools/builtin/log_ticket.zig`; research artifact transition table. | Assignment appends only an admission event; claim is the only dispatch boundary. | Never call provider/session/supervisor from transition handling. |
| A worker slot is capability identity plus lease, not a resident context. | `core/agents/supervisor.zig`; Temporal/BullMQ/Claude research in `.docs/research`. | Reuse configured supervisor capacity and create provider context at claim time. | Never keep idle provider sessions as “online agents.” |
| Recovery is a durable state transition. | `core/scheduler/service.zig`; session valid-prefix reader. | Persist lease expiry, requeue/block decision, and session reconciliation. | Never delete stale rows or infer health from a timer alone. |
| Operator telemetry is a read model. | root contract IV; existing TUI keyed rows. | Project typed ticket/pool state into client output. | Never create a second status registry. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|-------------------------|-----------------|---------------------|------------------|
| Existing ticket and pool owners | Read the owner files and current tests. | Repository source and tests | New owner boundary and patch order. | `.docs/research/2026-08-10-ticket-agent-pool-and-repair-queue.md`. |
| Claim/recovery reference shape | Read the 12-source research artifact and the clipping. | Primary source docs and local references | Lease fields and repair gate. | Research artifact lines 159-190 and 240-317. |
| Current worktree overlap | Inspect `git status` and provider-chain diff before each overlapping edit. | Repository state | Preserve 035 changes. | Current dirty-worktree record in parent. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `core/tools/builtin/log_ticket.zig`, `core/tickets/` target, `core/agents/supervisor.zig`, `core/scheduler/service.zig`, `core/sessions/store.zig`, TUI/event sink. |
| Existing-owner decision | Extend existing execution, scheduler, session, and event owners; add `core/tickets` because no reusable ticket lifecycle owner exists. |
| Domain owner / canonical standard | `core/tickets` owns ticket truth; `Supervisor` owns capacity; `scheduler.Service` owns wake/recovery; session store owns execution evidence. |
| Intended design | `create/transition -> append typed ticket event -> project -> scheduler claim -> session -> supervisor task -> terminal/recovery event`. |
| Integration path | `log_ticket` tool and scheduler thread feed the same store; typed events feed RPC/TUI; installed binary exercises the tool path. |
| Failure modes to prevent | eager execution, double claim, stale lease loss, orphan session, false closure, UI drift, duplicate owner. |
| Alternatives rejected | ticket daemon, idle provider pool, direct scheduler provider call, global status bus, prompt-only assignment behavior. |
| Proof hooks | transition/claim/replay tests, supervisor capacity snapshot, cold-start recovery, TUI/RPC snapshot, installed Windows smoke. |

## Codebase Research And Execution Addendum

**Implementation map:** Existing source was inspected at `core/tools/builtin/log_ticket.zig:7-390`, `core/agents/service.zig:23-555`, `core/agents/supervisor.zig:22-1175`, `core/scheduler/service.zig:15-131`, `core/sessions/store.zig:202-737`, `host/stdio_rpc.zig:178-338`, and `clients/tui_chat.zig` event/read-model paths.

**Existing-owner directive:** Extend the current owners. Put only ticket schema/projection/claim logic under `apps/backend/src/core/tickets/`; keep `log_ticket` as an adapter.

**Directive:** Make the claim event the sole boundary that can create a ticket execution session and submit work.

**Gold-standard guardrail:** Do not use a process-local `read -> unlock -> claim` sequence, a raw last-row ticket status, or a second worker/status registry.

**Knowledge gathering route:** Use repository-local owner evidence and the saved research artifact before each implementation unit; re-check the 035 provider diff at overlapping seams.

**Runtime visualization:** `log_ticket/scheduler -> ticket event ledger -> projection + serialized claim -> supervisor task/session -> typed terminal event -> RPC/TUI read model + installed proof`.

**Proof expansion:** Every implementation unit adds narrow adversarial tests and must reach the parent test floor before archival; this baseline is exempt because it makes no artifact change.

**Action-mode arbitration:** Ticket execution is delegated/background work. Admission, claim, launch, heartbeat, cancellation, recovery, and closure must be distinct state transitions with durable evidence.

## Embedded Framing

The chain is complete only when the ticket can wait without a provider, claim exactly once, run through the existing execution authority, recover after failure, and present the operator with evidence rather than theater.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| User wording and current ticket behavior | Prevent assignment-triggered execution and paraphrase drift. | Local artifact/source read | User message + repository | Parent anchors U1-U7 and current owner map. |
| Existing quality contract | Preserve installed proof and no duplicate owner. | Local AGENTS/source read | `AGENTS.md` and `.docs` | Parent constraints and invariants. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | “setting to assigned shouldnt trigger an agent.” | Lock assignment as side-effect-free admission. | I1 and 036b/036d tests. |
| U2 | “have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.” | Lock configured capacity and non-resident slot semantics. | I3/I4 and 036c tests. |
| U3 | “an agent that is most relevant expertise/skill should pick up the task” | Lock deterministic validated route selection. | 036b/036c tests. |
| U4 | “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.” | Lock terminal cycle and recovery requirement. | I5/I6 and 036d/036f tests. |
| U5 | “agents that pick up a ticket, may use explore, tools, and research/plan agents.” | Preserve nested capability through existing child service. | 036c/036d tests. |
| U6 | “context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.” | Lock useful minimal operator projection. | 036e tests. |
| U7 | “Apply this to vantari. leave the code better than you find it. whenever you look at it” | Require a measurable structural ratchet and review proof. | A1-A5 and 036g audit. |

## Pre-flight Checklist

- [x] Parent exists and contains the complete ordered sequence.
- [x] Source anchors and exact excerpts are populated.
- [x] Current owner and conflict boundaries are recorded.
- [x] No source artifact is modified by this unit.
- [x] Implementation units remain sequential.

## Entry State

- The 036 parent chain and research artifact are present.
- Existing provider worktree changes remain untouched.

## Patch Surface

**Modifies:**

- None.

**Adds:**

- None beyond this planning record.

**Deletes:**

- None.

**Must not touch (out of scope for this unit):**

- All source files and existing user changes.

## Interpretation Locks

- L1: `unassigned -> assigned` writes a typed admission event only; it does not start a session, provider call, child agent, or supervisor task.
- L2: A buffered agent is a configured capability identity and available supervisor capacity, not an idle provider context.
- L3: `assigned -> in_progress` requires one serialized claim event containing lease and canonical session evidence; no later “claim” append is allowed.
- L4: Explicit validated agent identity wins; otherwise selection is deterministic from configured agent definitions and ticket fields. Free-form skill strings cannot create an unregistered route.
- L5: The scheduler is the only background wake/recovery owner. It may run ticket ticks beside scheduled jobs but may not become a provider execution owner.
- L6: The supervisor remains the only bounded task pool. Ticket work uses its configured `agent_routes.max_concurrency` ceiling and existing cancellation/terminal paths.
- L7: `completed` means terminal execution/effect evidence exists; `closed` requires the applicable review/approval/rerun/regression gate.
- L8: TUI/RPC displays are projections over typed ticket/session/event state and may not mutate ticket truth.
- L9: Existing 035 provider changes are preserved; overlapping seams are patched narrowly and validated with their current tests.
- L10: The current severity ceiling remains truthful. The logged feedback can carry a `[CRITICAL]` title/boundary note, but this chain does not silently invent a new severity enum.

## Invariants This Unit Must Preserve

- All parent invariants I1-I8.
- No implementation unit may add a parallel ticket ledger, pool, scheduler thread, agent registry, or UI status bus.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|---------------------|-------------------------|------------|
| 1 | `Get-Content -LiteralPath .docs/todo/pending/036-ticket-agent-pool-and-repair.md` | `0` | `036 Ticket agent pool and repair` | yes |
| 2 | `Get-Content -LiteralPath .docs/todo/pending/036a-ticket-agent-pool-and-repair.md` | `0` | `source_message_anchor|Interpretation Locks|036b-ticket-agent-pool-and-repair` | yes |
| 3 | `git status --short` | `0` | Existing provider changes remain present; no source change from 036a | yes |

**Evidence to capture:** Exact output for all three reads and the unchanged source diff boundary.

## Exit State (Handoff Contract)

- The state machine, owner boundaries, user anchors, invariants, and rejection rules are locked.
- `036b` may implement only the ticket event/projection/claim owner and must preserve I1-I10.
- No source artifact has been modified by this unit.

## Rollback Procedure

1. Remove only this pending planning file if the parent chain is abandoned.
2. Leave all existing source and user changes intact.

## Next todo

`/todo/pending/036b-ticket-agent-pool-and-repair.md`

## Completion

- [x] Pre-flight passed.
- [x] Baseline exemption recorded: no implementation artifact and no feature-test floor applies.
- [x] Validation commands executed and evidence captured.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036a-ticket-agent-pool-and-repair.md`.
- [x] Continue immediately to `036b`.
