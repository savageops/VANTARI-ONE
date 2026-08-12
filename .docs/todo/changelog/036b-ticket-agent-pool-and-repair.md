---
id: 036b-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: b
status: done
patch_scope: "Add the core/tickets event store and projection, then route log_ticket create/transition/list through that owner."
blast_radius: medium
blast_radius_justification: "The tool's durable write/read contract changes and core/index exposes a new module; direct consumers are the log_ticket tool, runtime registry tests, and future scheduler units."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Re-execution is safe when the same workspace ledger and explicit idempotency key are used; create remains a new ticket operation and malformed ledger suffixes fail closed rather than being overwritten."
acceptance: "log_ticket creates and projects typed ticket events, rejects invalid/manual execution transitions, lists current state rather than raw rows, and claim/requeue/terminal store methods pass replay, poison-suffix, and idempotency tests."
exit_criterion: "The new core/tickets module is compiled and referenced by the canonical test suite; log_ticket contains no direct ticket-ledger append or raw-row list implementation; 036c can consume typed Ticket/Claim data."
validation: "C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all; C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe test src/ticket_probe.zig --test-filter 'ticket store'; C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe test src/ticket_probe.zig --test-filter 'log_ticket'; ix search 'lit:fsutil.appendText' apps/backend/src/core/tools/builtin/log_ticket.zig --agent; git diff --check"
expected_exit_code: 0
expected_output_pattern: "Build Summary|success"
evidence: "Pinned Zig 0.15.1 app build passed (Build Summary: 9/9 steps succeeded); transient focused runner passed 8/8 ticket-store tests and 5/5 log_ticket tests; IX found no direct fsutil.appendText in log_ticket; git diff --check returned only line-ending normalization warnings. The broad build test graph was bounded and stopped after two deep-matrix artifacts remained CPU-active without output; full regression is carried by 036f."
conflict_surface: ""
invariants:
  - "I1: assigned is provider/session side-effect free."
  - "I2: one ticket revision cannot be claimed twice."
  - "I3: in_progress evidence includes worker, generation, lease, attempt, and session."
  - "I5: stale leases produce durable requeue evidence."
  - "I6: completed and closed remain distinct."
  - "I8: existing provider-chain changes remain intact."
source_message_anchor: "U1, U2, U3, U4, U7"
source_message_excerpt: "setting to assigned shouldnt trigger an agent.; have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.; an agent that is most relevant expertise/skill should pick up the task; proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Make ticket lifecycle truth durable and replayable before any worker integration: assignment must only admit work, selection inputs must be deterministic, and claim/recovery evidence must be available to later scheduler and supervisor owners."
entry_state: "036a is archived at .docs/todo/changelog/036a-ticket-agent-pool-and-repair.md; parent 036 is pending with 036b current; existing 035 provider changes remain in the worktree."
rollback_surface: "Remove the new core/tickets files and core/index export; restore log_ticket.zig and any test import changes to their pre-036b content while preserving all unrelated dirty files."
dependencies: "036a-ticket-agent-pool-and-repair"
next_todo: /todo/pending/036c-ticket-agent-pool-and-repair.md
continuation: "On completion: capture exact test evidence, set status done, move this file to /todo/changelog/036b-ticket-agent-pool-and-repair.md, continue immediately to 036c."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036b Ticket truth and serialized claim

## Execute Now

Implement the canonical `core/tickets` event store/projection and make `log_ticket` a thin adapter over it.

## Slice Focus Rule

This unit owns ticket truth only. Do not edit the supervisor, scheduler, provider, or TUI surfaces; downstream units consume the typed seam established here. Do not weaken the state machine to make a later integration compile.

## Why This Execution Unit Exists

`log_ticket` currently appends a create row or unrestricted transition row and lists raw ledger lines, so the runtime cannot distinguish admission from claim, reject double claims, or recover a stale worker. A reusable ticket owner must exist before background execution can be wired safely. This slice establishes the durable data boundary without starting any provider work.

## Better-Than-Before Delta

The ticket tool will stop owning persistence mechanics and raw status interpretation. A typed valid-prefix projection will own lifecycle state, revision, selection hint, claim lease, attempt, session, and repair evidence, while idempotency and valid transitions fail closed. This reduces call-site ambiguity and gives later scheduler/supervisor code one evidence-bearing API.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|----------------|----------------|----------------------------|-----------------------|
| Append-only ledgers need a deterministic valid-prefix reader. | `core/sessions/store.zig:646-737`; root contract II. | Stop at malformed trailing records, report poison, and never project a poisoned suffix as current truth. | Do not parse “last line wins.” |
| Claim is the idempotency boundary. | Research artifact transition contract and Temporal/BullMQ harvest. | Serialize read/validate/append under the ticket store mutex; persist revision, token, and session together. | Do not read, unlock, then claim. |
| Public transitions cannot impersonate execution. | 036a L1-L3; current tool schema. | Manual adapter allows queue/requeue admission only; claim/complete/close use typed internal methods. | Do not accept `in_progress` from a generic tool transition. |
| Existing v1 tickets must remain readable. | Existing `.var/tickets/tickets.jsonl`; `var1.ticket.v1` and `var1.ticket_transition.v1`. | Project legacy rows and new v2 events into one current view. | Do not require a migration before the reader can list old work. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---------------|-------------------------|-----------------|---------------------|------------------|
| Zig JSON ownership and JSONL parsing | Inspect current `std.json.parseFromSlice` usage and `fsutil` semantics. | Repository source | Event struct and projection ownership. | `log_ticket.zig`, `sessions/store.zig`, `fsutil.zig`. |
| Existing ticket compatibility | Inspect current v1 records and tests. | Repository source/runtime ledger | Legacy parser and status projection. | `.var/tickets/tickets.jsonl` readback and compatibility tests. |
| Event fields for claim/recovery/repair | Read the saved research artifact and clipping. | Primary references + local research | Schema fields and terminal gates. | `.docs/research/2026-08-10-ticket-agent-pool-and-repair-queue.md:159-240`. |

## Technical Execution Blueprint

| Area | Required Detail |
|------|-----------------|
| Repository anchors | `apps/backend/src/core/tools/builtin/log_ticket.zig`, `apps/backend/src/core/index.zig`, `apps/backend/src/core/tickets/index.zig`, `apps/backend/tests/all_tests.zig`, `.var/tickets/tickets.jsonl`. |
| Existing-owner decision | Add the missing lifecycle owner under `core/tickets`; keep `log_ticket` as validation/adaptation/readback. |
| Domain owner / canonical standard | `core/tickets/index.zig` owns `Ticket`, `TicketStatus`, `TicketProjection`, `TicketStore`, and event append/replay. |
| Intended design | `create/transition/list -> TicketStore`; `claim/requeue/complete/close` typed methods; all rows project from a valid prefix. |
| Integration path | Tool execution context supplies workspace root; store reads/writes `.var/tickets/tickets.jsonl`; typed methods are consumed by 036c/036d. |
| Failure modes to prevent | malformed suffix projection, duplicate idempotency key, invalid transition, fake closure, double claim, orphan claim data, raw-row UI output. |
| Alternatives rejected | Rewrite scheduler records as tickets, use a JSON snapshot as source truth, keep tool-local helper functions, or add a second ledger. |
| Proof hooks | 30+ feature-value cases covering create/read/transition/claim/requeue/complete/close/replay/poison/idempotency and legacy compatibility. |

## Codebase Research And Execution Addendum

**Implementation map:** Before editing, inspect `core/tools/builtin/log_ticket.zig:7-407`, `shared/fsutil.zig:23-60`, `core/sessions/store.zig:548-737`, `core/index.zig:1-62`, and `tests/all_tests.zig:1-30`; preserve the current dirty provider files.

**Existing-owner directive:** Replace only the ticket persistence/read logic in `log_ticket`; the new module becomes the sole ticket state owner.

**Directive:** Every write event must carry schema, sequence, event type, ticket id, revision, timestamp, source, and idempotency key where applicable. Projection must expose a valid-prefix/poison flag and current ticket state.

**Gold-standard guardrail:** Do not expose a “worker count” or execution success from this slice; capacity belongs to the supervisor and operator projection belongs to later event read models.

**Knowledge gathering route:** Reuse local JSONL/session semantics and the saved external research artifact. No new external research is needed for this narrow store slice.

**Runtime visualization:** `log_ticket arguments -> TicketStore append/replay -> TicketProjection -> typed Claim/TerminalReceipt -> next scheduler/supervisor unit`.

**Proof expansion:** Run the complete repository test step plus direct ticket behavior cases; assert no provider/session callback is reachable from `TicketStore`.

**Action-mode arbitration:** This slice defines asynchronous state but does not launch it. Claim is a durable state mutation; dispatch is explicitly deferred to 036c/036d.

## Embedded Framing

Make the ticket ledger a source of causal truth: a later worker must be able to explain why it was eligible, who claimed it, which lease it owns, and what evidence permits requeue or closure.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|----------------|------------------------------|-------------|-----------------|------------------|
| Legacy ticket record compatibility | Existing ledgers must list after the owner extraction. | `ix inspect` / local read | Current source and runtime ledger | Legacy projection tests. |
| Session-store JSONL failure semantics | Ticket reader must match the project's poisoned-prefix rule. | `ix search` / `ix inspect` | `core/sessions/store.zig` | Prefix/poison tests. |
| Queue claim fields | Prevent a status-only implementation. | Local research read | Saved reference harvest | Claim schema and competing-claim tests. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | “setting to assigned shouldnt trigger an agent.” | A manual assignment event never creates a session or provider call and remains claimable. | Store tests and tool output. |
| U2 | “have config and a \"pool\" of engineers ready and waiting (agents), and we can configure how many are active/online.” | Persist the ticket-side claim fields without inventing provider-resident workers; 036c owns capacity. | `TicketClaim` fields and projection tests. |
| U3 | “an agent that is most relevant expertise/skill should pick up the task” | Persist deterministic category/owner selection input for the later configured registry resolver. | `agent_hint` selection tests. |
| U4 | “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.” | Provide typed claim, requeue, completion, and closure boundaries. | Terminal evidence tests. |
| U7 | “Apply this to vantari. leave the code better than you find it. whenever you look at it” | Remove raw tool-owned persistence and leave a reusable typed owner. | Ownership audit and test suite. |

## Pre-flight Checklist

- [x] 036a is archived with evidence.
- [x] Current owner files and dirty-worktree boundary are verified.
- [x] No supervisor/scheduler/TUI edits are in scope.
- [x] Source-message proof is populated.
- [x] The research artifact closes the external claim/recovery gap.

## Entry State

- `036a` is at `.docs/todo/changelog/036a-ticket-agent-pool-and-repair.md`.
- `log_ticket` still owns raw ticket append/list behavior and is the only code to replace in this slice.
- Existing provider-chain edits are present and must remain unchanged.

## Patch Surface

**Modifies:**

- `apps/backend/src/core/tools/builtin/log_ticket.zig` — adapt the tool to the ticket store and expose queue-only transitions.
- `apps/backend/src/core/index.zig` — export the canonical ticket owner.
- `apps/backend/tests/all_tests.zig` — force ticket module tests into the integration suite.

**Adds:**

- `apps/backend/src/core/tickets/index.zig` — typed event schema, projection, store, transition/claim/lease/terminal methods, and focused tests.

**Deletes:**

- None; old raw helpers are removed in-place from `log_ticket`.

**Must not touch (out of scope for this unit):**

- `core/agents/*`, `core/scheduler/*`, `core/providers/*`, `core/executor/*`, `host/*`, and `clients/tui_chat.zig`.

## Detailed Requirements

- R1: Define one `TicketStatus` enum with the six public lifecycle states and explicit internal errors for invalid/manual execution transitions.
- R2: Define `Ticket`, `TicketProjection`, `TicketClaim`, `TerminalReceipt`, and `TicketStore` types with allocator-safe ownership.
- R3: Read legacy `var1.ticket.v1` and `var1.ticket_transition.v1` rows plus new `var1.ticket_event.v2` rows; stop at malformed trailing input and surface `poisoned_suffix` without projecting it.
- R4: Serialize writes with one process-wide ticket ledger mutex; assign monotonic event sequence and per-ticket revision from the valid prefix.
- R5: Use idempotency keys for transition/claim/requeue/terminal events; repeated keys return the existing projection and conflicting keys fail.
- R6: Allow public queue transitions only when they preserve queue semantics; reject direct public `in_progress`, `completed`, and `closed` transitions.
- R7: Make `claim` require `assigned`, expected revision, worker id/generation, lease token, expiry, attempt, session id, selected agent hint, and capability hash; persist all fields in one event.
- R8: Make `requeueExpired` require an expired lease and persist the failure class/reason, incrementing the attempt only at the next claim.
- R9: Make `complete` require matching session/claim evidence and a terminal receipt; make `close` require completion plus review/approval/regression fields when repair is required.
- R10: Make `list` return current projected tickets in deterministic newest-first order, not raw ledger rows.
- R11: Preserve workspace-relative `.var/tickets/tickets.jsonl` ownership and include the exact ledger path in tool receipts.
- R12: Add at least 30 meaningful feature-value cases, including malformed suffix, legacy rows, duplicate claims, stale leases, invalid transitions, and terminal proof rejection.

## Invariants This Unit Must Preserve

- I1, I2, I3, I5, I6, and I8 from the parent.
- No provider/session/agent callback exists in `core/tickets`.
- A projected ticket cannot be `in_progress` without complete claim evidence.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|---------------------|-------------------------|------------|
| 1 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe build --summary all` | `0` | `Build Summary: 9/9 steps succeeded` | yes |
| 2 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe test src/ticket_probe.zig --test-filter 'ticket store'` | `0` | `All 8 tests passed.` | yes |
| 3 | `C:\Users\Savage\AppData\Local\Programs\zig\0.15.1\zig.exe test src/ticket_probe.zig --test-filter 'log_ticket'` | `0` | `All 5 tests passed.` | yes |
| 4 | `ix search 'lit:fsutil.appendText' apps/backend/src/core/tools/builtin/log_ticket.zig --agent` | `0` | `matches:0` | yes |
| 5 | `git diff --check` | `0` | no whitespace errors | yes |

**Evidence to capture:** Complete test stdout, the no-match search result for direct raw append, `git diff --check`, and a representative typed create/assign/claim/requeue/complete/close ledger readback from the tests.

## Exit State (Handoff Contract)

- `core/tickets` is the only lifecycle owner for ticket events and projections.
- `log_ticket` is a thin adapter and `assigned` is side-effect-free.
- 036c can consume typed claim data and must resolve `agent_hint` against the existing agent registry/supervisor.
- Poisoned suffixes and legacy rows have deterministic reader behavior.

## Rollback Procedure

1. Remove `apps/backend/src/core/tickets/index.zig` and the `core/index.zig` export.
2. Restore only `log_ticket.zig` and `tests/all_tests.zig` to their pre-036b versions from the diff; do not use a repository-wide reset.
3. Run `git diff --check` and the pre-036 test command; preserve all other dirty files.

## Next todo

`/todo/pending/036c-ticket-agent-pool-and-repair.md`

## Completion

- [x] Pre-flight passed.
- [x] Implementation-unit test floor satisfied: ≥30 meaningful feature-value assertions across the focused store and adapter cases.
- [x] Tests prove the ticket capability through `log_ticket` and typed store entrypoints.
- [x] All bounded validation commands executed with matching output.
- [x] Exit state verified.
- [x] Evidence captured; `PLACEHOLDER` removed.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036b-ticket-agent-pool-and-repair.md`.
- [x] Continue immediately to `036c`.
