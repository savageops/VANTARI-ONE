---
id: 032-scheduler-host-supervisor-and-protocol
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Start and supervise the scheduler from the VAR1 host and expose protocol/CLI read models without introducing a second scheduler implementation."
subtodo_start: /todo/pending/032a-scheduler-host-supervisor-and-protocol.md
subtodo_final: /todo/pending/032l-scheduler-host-supervisor-and-protocol.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 032 Scheduler Host Supervisor And Protocol

## Objective
Wire a scheduler supervisor into the kernel host lifecycle, add JSON-RPC/CLI schedule surfaces backed by the same core, and emit typed lifecycle notifications for scheduled attempts. This chain promotes the scheduler from passive ledger to background runtime.

## Rationale
The scheduler must run in the background without becoming platform-shaped too early. Host-supervised execution inside VAR1 establishes the portable runtime loop; separate process and OS services can later wrap the same core.

## Scope

**In scope:**
- apps/backend/src/host, clients/cli, shared/protocol scheduler surfaces.
- Scheduler capability work required by this chain's phase boundary.
- Tests, documentation, and evidence needed to prove this phase before downstream chains depend on it.

**Out of scope:**
- Implementing a hidden OS cron dependency as source truth.
- Adding a second tool runtime, provider loop, command runner, or schedule store.
- Shipping platform-specific service installers before the portable kernel-owned scheduler is proven.

## Current Code Alignment (2026-05-21)
- The live host protocol methods are declared in apps/backend/src/shared/protocol/types.zig and dispatched in apps/backend/src/host/stdio_rpc.zig; CLI command surfaces are in apps/backend/src/clients/cli.zig. Scheduler host supervision must extend those exact surfaces and keep the background loop inside VAR1 host lifecycle, with HTTP bridge exposure only as a read/transport layer over the same stdio RPC owner.
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
| 032a | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase a and capture evidence before archival. |
| 032b | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase b and capture evidence before archival. |
| 032c | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase c and capture evidence before archival. |
| 032d | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase d and capture evidence before archival. |
| 032e | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase e and capture evidence before archival. |
| 032f | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase f and capture evidence before archival. |
| 032g | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase g and capture evidence before archival. |
| 032h | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase h and capture evidence before archival. |
| 032i | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase i and capture evidence before archival. |
| 032j | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase j and capture evidence before archival. |
| 032k | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase k and capture evidence before archival. |
| 032l | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase l and capture evidence before archival. |

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
| /todo/pending/032-scheduler-host-supervisor-and-protocol.md | parent | Chain root | done |
| /todo/pending/032a-scheduler-host-supervisor-and-protocol.md | a | Baseline / contract lock | done |
| /todo/pending/032b-scheduler-host-supervisor-and-protocol.md | b | Scheduler service construction | done |
| /todo/pending/032c-scheduler-host-supervisor-and-protocol.md | c | Supervisor thread and shutdown semantics | done |
| /todo/pending/032d-scheduler-host-supervisor-and-protocol.md | d | Wake/sleep condition scheduling | done |
| /todo/pending/032e-scheduler-host-supervisor-and-protocol.md | e | Session event notification emission | done |
| /todo/pending/032f-scheduler-host-supervisor-and-protocol.md | f | JSON-RPC schedule methods | done |
| /todo/pending/032g-scheduler-host-supervisor-and-protocol.md | g | CLI schedule commands | done |
| /todo/pending/032h-scheduler-host-supervisor-and-protocol.md | h | Bridge audit classification | done |
| /todo/pending/032i-scheduler-host-supervisor-and-protocol.md | i | Health/readiness scheduler summary | done |
| /todo/pending/032j-scheduler-host-supervisor-and-protocol.md | j | Stale supervisor recovery behavior | done |
| /todo/pending/032k-scheduler-host-supervisor-and-protocol.md | k | Host/protocol integration tests | done |
| /todo/pending/032l-scheduler-host-supervisor-and-protocol.md | l | Verification / closeout | done |

Chain is complete when all rows read archived and all files are in /todo/changelog/.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| a | Baseline / contract lock | Host lifecycle contract lock | - | No |
| b | Scheduler service construction | Scheduler service construction | 032a | No |
| c | Supervisor thread and shutdown semantics | Supervisor thread and shutdown semantics | 032b | No |
| d | Wake/sleep condition scheduling | Wake/sleep condition scheduling | 032c | No |
| e | Session event notification emission | Session event notification emission | 032d | No |
| f | JSON-RPC schedule methods | JSON-RPC schedule methods | 032e | No |
| g | CLI schedule commands | CLI schedule commands | 032f | No |
| h | Bridge audit classification | Bridge audit classification | 032g | No |
| i | Health/readiness scheduler summary | Health/readiness scheduler summary | 032h | No |
| j | Stale supervisor recovery behavior | Stale supervisor recovery behavior | 032i | No |
| k | Host/protocol integration tests | Host/protocol integration tests | 032j | No |
| l | Verification / closeout | Verification / regression / closeout | 032k | No |

## Validation Expectations
- Signal 1: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all exits 0 after this chain's implementation units are complete.
- Signal 2: Scheduler-specific tests for this chain prove at least one adversarial failure or recovery path, not only a happy path.
- Signal 3: VAR1 tools --json and/or protocol surfaces remain catalog-consistent where this chain touches tool or host behavior.
- Per-unit test floor: every implementation execution unit must provide at least 30 meaningful feature-value tests before archival, unless it is explicitly documentation-only or baseline-only and records that exemption.
- Evidence format expected: exact command, exit code, and stdout excerpt for every validation command.

## Next todo
/todo/pending/032a-scheduler-host-supervisor-and-protocol.md


## Completion Evidence (2026-05-21)
- Runtime implementation committed through canonical backend lane: core scheduler store/service, schedule_job tool, stdio protocol read model, CLI schedule read model, and health supervisor proof.
- Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed.
- Validation: apps/backend/scripts/zigw.ps1 build install --summary all => install success.
- Capability proof: VAR1 health --json => scheduler_supervisor=true.
- Capability proof: VAR1 tools --json => schedule_job advertised.
- Capability proof: VAR1 schedule list --json => canonical schedule list response.
