---
id: 036-ticket-agent-pool-and-repair
type: parent
protocol_version: "3.0"
spec_status: approved
category: feature
status: pending
epic_boundary: "Add a durable buffered ticket execution plane that claims assigned work through the existing supervisor and scheduler, recovers stale runs, and exposes truthful ticket/pool evidence to clients."
subtodo_start: /todo/pending/036a-ticket-agent-pool-and-repair.md
subtodo_final: /todo/changelog/036g-ticket-agent-pool-and-repair.md
continuation: "Reopened by the 2026-08-12 harness audit. Findings 10 and 13 are closed. Resolve finding 11 through roadmap moves 21-30, add focused fix and re-review units, then repeat installed proof before parent archival."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 036 Ticket agent pool and repair queue

> [!warning] Current audit supersession
> The archived 036g receipt remains historical evidence, but its completion
> judgment is not current. The full-harness audit proved process-local worker
> ownership and missing durable agent mail. Move 23 has since closed the
> non-atomic scheduler leader lease with a two-kernel generation-fenced proof.
> Findings 10 and 13 are closed. This parent remains pending until finding 11 is repaired and a
> new terminal review passes.

## Objective

Extend VANTARI's canonical ticket, scheduler, supervisor, session, and typed-event owners into a durable buffered execution plane. `assigned` becomes queue admission only; a scheduler-owned claim atomically selects an eligible ticket and an existing configured agent identity, creates the canonical execution session, and submits one task through the existing bounded supervisor. The resulting lifecycle, lease, recovery, terminal evidence, and operator projection remain replayable from `.var/tickets` and `.var/sessions` without a second worker pool, registry, daemon, or status bus.

## Rationale

The current `log_ticket` path appends lifecycle strings but does not validate transitions, serialize claims, select expertise, lease work, or connect a ticket to a session. The existing `agent_routes.max_concurrency`, `agents.Service`, `agents.Supervisor`, and scheduler already own capacity, execution, and background wake; the chain must join those owners instead of introducing parallel machinery. The repair contract also requires exact input, causal evidence, approval, rerun, and regression proof before `closed`, so terminal status cannot be inferred from a provider response alone.

## Domain Expertise Baseline

| Domain Question | Current Evidence | Gold-Standard Requirement | What This Chain Must Not Assume |
|-----------------|------------------|---------------------------|---------------------------------|
| What does a buffered agent mean? | `.docs/research/2026-08-10-ticket-agent-pool-and-repair-queue.md:14-29,174-182`; `core/agents/supervisor.zig:154-176` | A durable capability-bearing slot may wait without an idle provider context; provider work starts after a serialized claim and session admission. | Six resident provider sessions, a second pool, or a claim triggered by the `assigned` transition. |
| Who owns ticket truth? | `core/tools/builtin/log_ticket.zig:105-260`; `.var/tickets/tickets.jsonl` | Typed append-only events plus a deterministic valid-prefix projection own lifecycle, revision, idempotency, claim, lease, and recovery. | A last-row read, unrestricted transition append, or UI-maintained status. |
| Who owns capacity and execution? | `core/agents/service.zig:355-555`; `core/agents/supervisor.zig:301-403,755-910`; `core/config/default.json:35-42` | One supervisor pool and its cancellation/terminal paths remain the execution authority; ticket admission cannot exceed verified capacity. | A scheduler-spawned provider, ticket-local thread pool, or optimistic online count. |
| How does background work recover? | `core/scheduler/service.zig:15-83`; `host/stdio_rpc.zig:178-305` | The existing stop-aware scheduler wakes, claims, heartbeats, requeues stale leases, and reconciles terminal sessions after restart. | A new ticket daemon or a heartbeat that has no durable lease evidence. |
| What closes repair work? | `Your Agent Harness Should Repair Itself 1.md:63-167`; `.docs/research/2026-08-09-tui-status-surface-and-repair-loop.md` | Trace -> causal diagnosis -> proposed diff -> explicit approval -> exact-input rerun -> regression capture -> promotion. `completed` and `closed` remain distinct. | Autonomous edits, inferred success, or a closed ticket without replay and regression evidence. |
| What does the operator need? | User TUI request; `clients/tui_chat.zig`; existing typed event sink | Minimal live rows show context/model/effort, ticket state, active/queued capacity, and truthful progress derived from the event spine. | Prompt scaffolding, `Esc cancel` filler, speculative global status, or a second UI registry. |

## Gold-Standard Decision Criteria

| Criterion ID | Decision Rule | Evidence Required Before Selection | Review Failure Signal |
|--------------|---------------|------------------------------------|-----------------------|
| GS1 | Extend a current canonical owner when it already owns the state or side effect; create `core/tickets` only because the ticket tool currently owns no reusable lifecycle service. | Ownership map and source inspection in the research artifact. | Duplicate ticket ledger, pool, scheduler, or agent registry. |
| GS2 | `assigned` must be side-effect free with respect to provider/session execution. | Transition test proves no session/provider/supervisor event before claim. | Assignment creates a child session or provider call. |
| GS3 | Claim is one serialized idempotency boundary containing ticket revision, worker generation, lease, selected agent, capability hash, attempt, and session id. | Competing-claim and replay tests plus ledger evidence. | Two workers claim one revision or retry appends a second claim. |
| GS4 | A stale owner is reconciled by durable evidence, not timeout-only deletion. | Cold-start recovery test reads ticket/session/event prefix and requeues or blocks deterministically. | Stale `in_progress` remains live or disappears without a requeue event. |
| GS5 | `closed` requires a terminal result and the repair gate when repair applies. | Completion/approval/rerun/regression tests. | Completed work is silently promoted to closed. |
| GS6 | TUI and RPC surfaces render read models from typed projections; they never invent lifecycle truth. | Event replay and installed client proof. | UI count disagrees with ledger projection. |

## Repository Ownership Reconnaissance

| Question | Evidence Found | Planning Consequence | Anti-Assumption Guard |
|----------|----------------|---------------------|-----------------------|
| Current canonical owners | `core/tools/builtin/log_ticket.zig`; `core/agents/service.zig`; `core/agents/supervisor.zig`; `core/scheduler/service.zig`; `core/sessions/store.zig`; `host/stdio_rpc.zig`; `clients/tui_chat.zig` | Add ticket domain service, then wire it through existing service/supervisor/scheduler/event owners. | Do not let the tool, TUI, or scheduler each own a ticket state machine. |
| Adjacent or duplicate owners | `fsutil.appendText` is a raw append helper; supervisor has fixed pool but immediate group submission; scheduler has durable job leases; agent registry has route definitions but no skill tags. | Reuse append/replay patterns and supervisor capacity; add ticket-specific typed records only under `core/tickets`. | Do not reuse scheduler job records as ticket truth or add a global worker registry. |
| Canonical callers and consumers | `log_ticket` runtime dispatch; `tools.AgentService`; scheduler thread from `serveKernel`; parent event sink; TUI keyed activity rows; installed `vantari.exe`. | Each unit must preserve tool, background, event, TUI, and installed proof paths. | Source-only tests do not count as end-to-end proof. |
| Existing tests and proof gaps | `core/tools/builtin/log_ticket.zig` tests only create validation; supervisor tests cover child groups; scheduler tests cover job leases; no ticket claim/lease/recovery tests. | Add adversarial ticket tests and a canonical installed smoke probe. | Green creation tests do not prove dispatch or recovery. |
| Unsupported runtime boundaries | `critical` is not in the current severity enum; `search_files` is unavailable when `iex` is absent; user-home config may be incompatible with the installed binary. | Keep severity truthful unless schema change is proven; use repo `.var` env for installed proof; name missing `iex` as a boundary. | Do not claim critical support or use hidden search fallbacks. |

## Scope

**In scope:**

- `core/tickets` typed event schema, projection, valid transitions, idempotent append, deterministic selection, claims, leases, and recovery.
- Thin `log_ticket` adaptation using the ticket owner.
- A typed claim-to-session seam in `tools.AgentService`/`agents.Service` and supervisor capacity evidence.
- Scheduler wake, dispatch, heartbeat, stale-lease requeue, and cold-start reconciliation.
- Ticket/session/event read models for RPC/TUI, including model, effort, context, active/queued capacity, and ticket state.
- Exact repair evidence fields and approval/rerun gating; no autonomous unapproved code mutation.
- Canonical unit, integration, and installed Windows proof.

**Out of scope:**

- Idle provider-backed contexts or a second pool/daemon/status registry.
- New agent definition registry or unverified free-form skill taxonomy.
- Automatic patch application without review/approval and regression evidence.
- Broad provider changes from the uncommitted 035 chain except narrow interface integration required by this chain.
- Changing the public severity vocabulary to `critical` without a separately tested schema contract.

## Source Language Anchors

- “`assigned` is queue admission only.”
- “Provider sessions start only after a slot claims a ticket.”
- “completed and closed remain distinct.”
- “leave the code better than you find it. whenever you look at it”

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | buffered ticket admission | “setting to assigned shouldnt trigger an agent.” | `036a`, `036b`, `036d`, `036g` |
| U2 | configurable worker pool | “have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.” | `036b`, `036c`, `036d`, `036g` |
| U3 | assignment and expertise selection | “an agent that is most relevant expertise/skill should pick up the task” | `036b`, `036c`, `036d`, `036g` |
| U4 | complete persistent cycle | “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.” | `036b`, `036d`, `036e`, `036g` |
| U5 | agent capabilities | “agents that pick up a ticket, may use explore, tools, and research/plan agents.” | `036c`, `036d`, `036g` |
| U6 | operator visibility | “context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.” | `036e`, `036g` |
| U7 | quality ratchet | “Apply this to vantari. leave the code better than you find it. whenever you look at it” | every unit; final review |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 036a | U1-U7 | Freeze the runtime interpretation and reject provider-at-assignment, parallel-owner, and UI-only substitutions. |
| 036b | U1-U4, U7 | Prove durable ticket truth, valid transitions, deterministic selection, and serialized claim/replay. |
| 036c | U2, U3, U5, U7 | Prove ticket execution reuses the configured supervisor capacity and selected agent route. |
| 036d | U1-U5, U7 | Prove scheduler-owned wake, dispatch, heartbeat, stale recovery, and terminal session reconciliation. |
| 036e | U4, U6, U7 | Prove typed event/read-model output exposes truthful ticket, context, effort, model, and worker counts with minimal UI copy. |
| 036f | U1-U7 | Prove integrated adversarial behavior through the real runtime entrypoints and preserve the quality ratchet. |
| 036g | U1-U7 | Review all evidence, ownership, source coverage, installed proof, and residual boundaries; close only if the deliverable is undeniable. |

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | Feature: durable ticket dispatch and operator-visible recovery. No unrelated provider redesign. |
| Blast radius ceiling | high — supervisor, scheduler, session/event, tool, and client contracts are involved. |
| Structural boundary | `core/tickets` is the only new lifecycle owner; existing supervisor/scheduler/session/event owners remain canonical. |
| Dependency boundary | Units touching supervisor/loop/config declare overlap with the uncommitted 035 provider chain and must preserve its diff. |
| Rollback surface | Ordered per-unit rollback of new ticket files, adapter seams, scheduler hooks, event projections, tests, and docs; no destructive reset of existing user changes. |
| Parallelism | None. Execution units are sequential because each handoff establishes the next state and the scheduler/supervisor seam is shared. |

## Invariants

- I1: `assigned` appends no provider/session execution evidence.
- I2: A ticket claim is atomic within the ticket store and one ticket revision cannot be claimed twice.
- I3: Every `in_progress` ticket has a worker id, generation, lease, selected agent, capability hash, attempt, and canonical session id.
- I4: Provider execution enters only through `agents.Supervisor` and the existing configured route/profile.
- I5: Lease expiry produces a durable requeue/block decision and cold start can reconcile it.
- I6: `completed` and `closed` are distinct; repair closure requires approval, exact rerun, and regression evidence.
- I7: Ticket/pool TUI and RPC state is a projection of typed events and session records.
- I8: Existing provider-chain changes remain intact and the installed Windows binary is tested on the changed path.

## Architectural Improvement Targets

| Target ID | Pre-Chain Weakness | Required Better-Than-Before Outcome | Verified By |
|-----------|-------------------|-------------------------------------|-------------|
| A1 | Tool-owned unrestricted ticket append | One typed ticket store owns schema, transition validation, claims, leases, and projection. | Ownership audit and ticket tests. |
| A2 | Assignment has no execution semantics | `assigned` is side-effect-free queue admission; claim creates the exact session/evidence boundary. | Assignment/claim event and session-path tests. |
| A3 | Supervisor admits all child tasks immediately | Ticket work is admitted only when a verified capacity slot claims it; one existing pool remains the authority. | Capacity and supervisor integration tests. |
| A4 | Stale work has no ticket recovery | Scheduler requeues or blocks from durable lease/session evidence on cold start. | Restart/recovery tests and ledger readback. |
| A5 | UI has no ticket/pool read model | Typed event projection shows truthful state with minimal, useful operator metadata. | TUI/RPC snapshot tests and installed smoke. |

## Embedded Framing Contract

| Frame ID | Embedded Meaning | Where It Appears | Gold-Standard Pressure |
|----------|------------------|------------------|------------------------|
| F1 | Capability completion | Objective, state machine, exit states | A ticket is not complete because a task was admitted; terminal evidence is required. |
| F2 | Owner clarity | Ownership recon, execution blueprint, review | Every mutation has one canonical owner and one readback path. |
| F3 | Recovery discipline | lease contract, scheduler units, tests | Crashes become typed requeue/reconcile evidence, never silent loss. |
| F4 | Consumer empathy | TUI unit and user anchors | Expose useful live state without clutter or prompt scaffolding. |

## Research Program

The external harvest is closed by `.docs/research/2026-08-10-ticket-agent-pool-and-repair-queue.md`, which records source extracts and VANTARI decisions for the following references:

| Research ID | Why This Research Exists | Questions To Answer | Insect Surface | Priority Sources | Expected Artifact / Evidence |
|-------------|--------------------------|---------------------|----------------|------------------|------------------------------|
| RCH-1 | Durable queue ownership | How do task queues separate admission, claim, and execution? | `.refs` / source docs | Temporal task queues | Research artifact + claim tests |
| RCH-2 | Lease and retry semantics | How are stalled workers detected and recovered? | `.refs` / source docs | BullMQ stalled jobs | Research artifact + stale lease tests |
| RCH-3 | Buffered agent semantics | How do agent teams separate coordination from resident model contexts? | `.refs` / source docs | Claude agent teams | Research artifact + no-provider-on-assignment test |
| RCH-4 | Task result evidence | What terminal receipts are needed for autonomous task systems? | `.refs` / source docs | Celery task states | Research artifact + terminal evidence tests |
| RCH-5 | Agent execution plane | How does a coding agent preserve tool/session ownership? | `.refs/openai__codex` | OpenAI Codex | Existing ref + supervisor seam |
| RCH-6 | Lean context lifecycle | What should stay code-owned and demand-loaded? | `.refs/badlogic__pi-mono` | pi-mono | Existing ref + owner audit |
| RCH-7 | Recursive harness repair | What makes exact replay and refinement safe? | `.refs/prime-intellect__prime-agent` | Prime Agent | Research artifact + repair gate |
| RCH-8 | Long-running recovery | How do goals, heartbeats, and daemon recovery interact? | `.refs` / source docs | Prime Agent daemon | Research artifact + scheduler recovery |
| RCH-9 | Trace-to-fix loop | What evidence precedes an approved repair? | Obsidian clipping | Your Agent Harness Should Repair Itself | Clipping + repair fields |
| RCH-10 | TUI information hierarchy | Which live metrics help without clutter? | competitor docs / existing TUI | Codex, Claude, pi | Existing TUI research + snapshot tests |
| RCH-11 | Durable event replay | How should poisoned suffixes and monotonic cursors behave? | local source | `core/sessions/store.zig` | Prefix/read tests |
| RCH-12 | Windows installed proof | What real consumer path must be validated? | local runtime probe | `vantari.exe` / `.var` env | Installed smoke evidence |

## Assumption Ledger

| Assumption ID | Assumption | Evidence Class | Risk If Wrong | Slice That Proves Or Eliminates It |
|---------------|------------|----------------|--------------|------------------------------------|
| AS1 | Existing supervisor capacity can serve ticket slots without a second pool. | verified repo fact + research artifact | Duplicate workers or unfair admission. | 036c |
| AS2 | Scheduler can own ticket wake/recovery alongside scheduled jobs. | verified repo fact | Missed tickets or competing background owners. | 036d |
| AS3 | A ticket can create a canonical session before provider dispatch without changing transcript truth. | unresolved hypothesis | Orphan sessions or missing parent event evidence. | 036c/036d |
| AS4 | Existing agent definitions are sufficient for deterministic ticket routing. | verified repo fact + unresolved skill mapping | Wrong specialist or free-form routing drift. | 036b/036c |
| AS5 | Current TUI event/read-model seam can carry ticket/pool metadata without a status bus. | unresolved hypothesis | UI-only truth or cluttered footer. | 036e |
| AS6 | Current severity ceiling is an acceptable truthful boundary for the logged feedback. | verified repo fact + user request | False critical support. | 036b/036g |

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/pending/036-ticket-agent-pool-and-repair.md` | parent | Chain root | pending |
| `/todo/changelog/036a-ticket-agent-pool-and-repair.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/036b-ticket-agent-pool-and-repair.md` | b | Ticket schema, projection, transitions, claims, leases | archived |
| `/todo/changelog/036c-ticket-agent-pool-and-repair.md` | c | Supervisor capacity and ticket launch seam | archived |
| `/todo/changelog/036d-ticket-agent-pool-and-repair.md` | d | Scheduler wake, dispatch, heartbeat, recovery | archived |
| `/todo/changelog/036e-ticket-agent-pool-and-repair.md` | e | Typed event/TUI/RPC operator projection | archived |
| `/todo/changelog/036f-ticket-agent-pool-and-repair.md` | f | Integrated adversarial and installed proof | archived |
| `/todo/changelog/036g-ticket-agent-pool-and-repair.md` | g | Review / QC / closeout | archived |

The original 036a-036g units are archived, but the parent is reopened by
post-review evidence. Do not archive it until the current findings ledger
produces focused repair units and a new terminal re-review.

## Execution Index

| Order | Unit | Role | Decision After Completion |
|-------|------|------|---------------------------|
| 1 | `036a` | Baseline / contract lock | Continue to `036b`. |
| 2 | `036b` | Ticket truth and serialized claim | Continue to `036c`. |
| 3 | `036c` | Supervisor-backed ticket launch | Continue to `036d`. |
| 4 | `036d` | Scheduler dispatch and recovery | Continue to `036e`. |
| 5 | `036e` | Operator read model and TUI | Continue to `036f`. |
| 6 | `036f` | Full feature proof | Continue to `036g`. |
| 7 | `036g` | Review / QC / architectural judgment | `NONE` if pass; create a focused fix/re-review only if evidence requires it. |

Every row above compounds the parent ratchet.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|---------------|------------|----------------|
| `a` | Baseline / contract lock | Interpretation, invariants, no artifact change | — | No |
| `b` | Implementation unit 1 | `core/tickets`, ticket tool adapter, ticket tests | `a` | No |
| `c` | Implementation unit 2 | `tools.AgentService`, `agents.Service`, `agents.Supervisor`, capacity tests | `b` | No |
| `d` | Implementation unit 3 | `scheduler.Service`, host lifecycle, recovery tests | `c` | No |
| `e` | Implementation unit 4 | typed event projection, RPC/TUI read model, UI tests | `d` | No |
| `f` | Implementation unit 5 | integrated tests, docs, Windows installed proof | `e` | No |
| `g` | Review / regression / closeout | read-only audit and final evidence | `f` | No |

## Validation Expectations

- Signal 1: assignment changes only ticket projection; no session/provider/supervisor execution appears.
- Signal 2: one claim wins under competing workers; replay and retry are idempotent.
- Signal 3: active/queued/idle capacity is bounded by `agent_routes.max_concurrency` and is read from the supervisor/ticket projection.
- Signal 4: stale leases requeue or block with durable evidence after cold start.
- Signal 5: completion, repair approval, exact rerun, regression, and closure are separately evidenced.
- Signal 6: TUI/RPC output is minimal, typed, and consistent with ledger/session truth.
- Per-unit test floor: each implementation unit must provide at least 30 meaningful feature-value cases or explicitly record a justified baseline/documentation exemption.
- Evidence format expected: exact test stdout, ticket/event/session ledger excerpts, installed binary output, and final diff/ownership audit.

## Current Frontier

[`../findings/11-persistent-agent-worker-and-scheduler-arbitration.md`](../findings/11-persistent-agent-worker-and-scheduler-arbitration.md)

Move 24 is closed in source. One shared ticket-ledger process lock now serializes
projection, revision validation, and append; the winning row commits lease,
generation, capability, attempt, and deterministic child identity before one
child is materialized. The two-kernel proof at
`.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` records one claim
and one matching child. Move 25 is next: preserve and pressure-test assignment as
side-effect-free queue admission across every caller and projection.

## Stop Condition

Stop only after findings 10, 11, and 13 pass, a new terminal review is archived,
the isolated broad graph is green, and built/installed hashes match with clean
process exit.

## Next todo

[`../findings/11-persistent-agent-worker-and-scheduler-arbitration.md`](../findings/11-persistent-agent-worker-and-scheduler-arbitration.md)
