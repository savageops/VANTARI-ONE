---
id: 026-scheduler-baseline-contract-lock
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Freeze the durable scheduler architecture contract before implementation so every later chain preserves one kernel-owned schedule ledger, one supervisor contract, and one registered tool surface."
subtodo_start: /todo/pending/026a-scheduler-baseline-contract-lock.md
subtodo_final: /todo/pending/026l-scheduler-baseline-contract-lock.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 026 Scheduler Baseline Contract Lock

## Objective
Lock the scheduler source-language interpretation, current runtime topology, and invariant set before artifact changes begin. This chain establishes the non-negotiable boundaries that all implementation chains inherit: no OS cron as source truth, no parallel tool system, and no background worker without durable recovery evidence.

## Rationale
The scheduler touches tool dispatch, session execution, process supervision, ledgers, and host lifecycle. A baseline chain prevents implementation units from drifting into shell-only cron glue or host-specific daemon assumptions.

## Scope

**In scope:**
- docs and recon evidence only.
- Scheduler capability work required by this chain's phase boundary.
- Tests, documentation, and evidence needed to prove this phase before downstream chains depend on it.

**Out of scope:**
- Implementing a hidden OS cron dependency as source truth.
- Adding a second tool runtime, provider loop, command runner, or schedule store.
- Shipping platform-specific service installers before the portable kernel-owned scheduler is proven.

## Current Code Alignment (2026-05-21)
- Live backend lane is still apps/backend. There is no apps/backend/src/core/scheduler/ module yet, so this chain remains a prerequisite contract lock. Current evidence owners are apps/backend/src/core/tools/runtime.zig, apps/backend/src/core/tools/registry.zig, apps/backend/src/core/tools/index.zig, apps/backend/src/core/executor/loop.zig, apps/backend/src/host/stdio_rpc.zig, apps/backend/src/shared/protocol/types.zig, and apps/backend/src/clients/cli.zig.
- Current validation command floor: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all

## Insect Research Alignment (2026-05-21)
- Temporal research reinforces idempotency keys and durable attempt records: every scheduled execution needs a replay-safe reservation before side effects.
- Quartz research reinforces explicit misfire policy as schedule data, not incidental timer behavior; VANTARI keeps misfire_policy on each job.
- Kubernetes research reinforces leases with owner, expiry, and reconciliation semantics; future host supervision should be a lease-renewing reconcile loop over .var/schedules, not a hidden timer cache.
- System timer research was attempted through Insect, but the freedesktop systemd timer page failed extraction; no design decision relies on that failed source. OS timers remain wrappers only, never source truth.
- Final architecture decision: append-only schedule/attempt evidence plus a small deterministic reconciler is more future-proof than cron binding, job-queue mimicry, or provider-loop duplication.

## Source Language Anchors
- "creating a background, a threaded service, or something that runs parallel or background like a worker"
- "Ventari will have as a tool. And can use this tool at will."
- "create, delete, edit, update, whatever the case is, essentially full CRUD"
- "is not going to just die or be unreliable in a case of multi-platform"
- "building in a very modular, independent fashion"
- "not doing it in a way that now we have to change the whole code base"
- "go and schedule a task or update a task or set a reminder"
- "eight parent to-dos, and each parent to-do has at least 12 slices"

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | objective | "creating a background, a threaded service, or something that runs parallel or background like a worker" | All chains preserve the scheduler-worker objective. |
| U2 | tool access | "Ventari will have as a tool. And can use this tool at will." | 031 exposes the registered tool; 032 proves host access. |
| U3 | crud | "create, delete, edit, update, whatever the case is, essentially full CRUD" | 027 models state; 031 exposes CRUD. |
| U4 | reliability | "is not going to just die or be unreliable in a case of multi-platform" | 029, 032, and 033 prove lease recovery and native behavior. |
| U5 | modularity | "building in a very modular, independent fashion" | All chains preserve modular ownership boundaries. |
| U6 | minimal integration blast radius | "not doing it in a way that now we have to change the whole code base" | 030-032 wire through existing primitives. |
| U7 | schedule semantics | "go and schedule a task or update a task or set a reminder" | 028 and 031 preserve scheduling semantics. |
| U8 | implementation packaging | "eight parent to-dos, and each parent to-do has at least 12 slices" | This backlog creates eight parent chains with twelve lettered units each. |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 026a | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase a and capture evidence before archival. |
| 026b | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase b and capture evidence before archival. |
| 026c | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase c and capture evidence before archival. |
| 026d | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase d and capture evidence before archival. |
| 026e | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase e and capture evidence before archival. |
| 026f | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase f and capture evidence before archival. |
| 026g | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase g and capture evidence before archival. |
| 026h | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase h and capture evidence before archival. |
| 026i | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase i and capture evidence before archival. |
| 026j | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase j and capture evidence before archival. |
| 026k | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase k and capture evidence before archival. |
| 026l | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase l and capture evidence before archival. |

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | Only feature operations for the scheduler capability. Documentation and tests are admissible only as proof/support for this feature. |
| Blast radius ceiling | high - scheduler state, host lifecycle, tool dispatch, and command/session execution can cross runtime boundaries. |
| Structural boundary | Scheduler truth lives under apps/backend/src/core/scheduler/ and .var/schedules/; no OS cron or shell script becomes source truth. |
| Dependency boundary | Existing session, tool, command, provider, and host primitives must be reused through declared interfaces instead of forked. |
| Rollback surface | Revert the files named in each execution unit; downstream chains must not start until this parent chain closes. |
| Parallelism | No units in this chain run in parallel. Sequential archival preserves cold-start proof. |

## Invariants
- I1: Scheduler source truth is an append-only .var/schedules/ ledger, not in-memory timers, OS cron, or shell-script state.
- I2: Agent access happens through a registered tool catalog entry with schema, review risk, availability, and dispatch ownership.
- I3: Prompt execution and shell execution reuse existing VAR1 session and command primitives; no parallel provider or shell runner is introduced.
- I4: Background execution has explicit lease, cancellation/recovery, and terminal evidence before reliability is claimed.
- I5: All public docs describe shipped runtime truth and never imply unsupported daemon/service behavior.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| /todo/pending/026-scheduler-baseline-contract-lock.md | parent | Chain root | done |
| /todo/pending/026a-scheduler-baseline-contract-lock.md | a | Baseline / contract lock | done |
| /todo/pending/026b-scheduler-baseline-contract-lock.md | b | Scheduler source-language anchors and invariants | done |
| /todo/pending/026c-scheduler-baseline-contract-lock.md | c | Existing session/event ledger topology map | done |
| /todo/pending/026d-scheduler-baseline-contract-lock.md | d | Existing process/thread supervision topology map | done |
| /todo/pending/026e-scheduler-baseline-contract-lock.md | e | Reference pressure notes for cron versus durable ledger | done |
| /todo/pending/026f-scheduler-baseline-contract-lock.md | f | Scheduler target taxonomy lock | done |
| /todo/pending/026g-scheduler-baseline-contract-lock.md | g | Risk register and rejected architecture paths | done |
| /todo/pending/026h-scheduler-baseline-contract-lock.md | h | Cross-chain dependency map for 027-033 | done |
| /todo/pending/026i-scheduler-baseline-contract-lock.md | i | Test mesh blueprint and value-test inventory | done |
| /todo/pending/026j-scheduler-baseline-contract-lock.md | j | Operator proof checklist and installed-binary gate | done |
| /todo/pending/026k-scheduler-baseline-contract-lock.md | k | Planning artifact consistency audit | done |
| /todo/pending/026l-scheduler-baseline-contract-lock.md | l | Verification / closeout | done |

Chain is complete when all rows read archived and all files are in /todo/changelog/.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| a | Baseline / contract lock | Current runtime and tool catalog evidence | - | No |
| b | Scheduler source-language anchors and invariants | Scheduler source-language anchors and invariants | 026a | No |
| c | Existing session/event ledger topology map | Existing session/event ledger topology map | 026b | No |
| d | Existing process/thread supervision topology map | Existing process/thread supervision topology map | 026c | No |
| e | Reference pressure notes for cron versus durable ledger | Reference pressure notes for cron versus durable ledger | 026d | No |
| f | Scheduler target taxonomy lock | Scheduler target taxonomy lock | 026e | No |
| g | Risk register and rejected architecture paths | Risk register and rejected architecture paths | 026f | No |
| h | Cross-chain dependency map for 027-033 | Cross-chain dependency map for 027-033 | 026g | No |
| i | Test mesh blueprint and value-test inventory | Test mesh blueprint and value-test inventory | 026h | No |
| j | Operator proof checklist and installed-binary gate | Operator proof checklist and installed-binary gate | 026i | No |
| k | Planning artifact consistency audit | Planning artifact consistency audit | 026j | No |
| l | Verification / closeout | Verification / regression / closeout | 026k | No |

## Validation Expectations
- Signal 1: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all exits 0 after this chain's implementation units are complete.
- Signal 2: Scheduler-specific tests for this chain prove at least one adversarial failure or recovery path, not only a happy path.
- Signal 3: VAR1 tools --json and/or protocol surfaces remain catalog-consistent where this chain touches tool or host behavior.
- Per-unit test floor: every implementation execution unit must provide at least 30 meaningful feature-value tests before archival, unless it is explicitly documentation-only or baseline-only and records that exemption.
- Evidence format expected: exact command, exit code, and stdout excerpt for every validation command.

## Next todo
/todo/pending/026a-scheduler-baseline-contract-lock.md


## Completion Evidence (2026-05-21)
- Runtime implementation committed through canonical backend lane: core scheduler store/service, schedule_job tool, stdio protocol read model, CLI schedule read model, and health supervisor proof.
- Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed.
- Validation: apps/backend/scripts/zigw.ps1 build install --summary all => install success.
- Capability proof: VAR1 health --json => scheduler_supervisor=true.
- Capability proof: VAR1 tools --json => schedule_job advertised.
- Capability proof: VAR1 schedule list --json => canonical schedule list response.
