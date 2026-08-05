---
id: 028-scheduler-grammar-and-policy
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Implement schedule grammar parsing and timing policy without starting any runtime worker."
subtodo_start: /todo/pending/028a-scheduler-grammar-and-policy.md
subtodo_final: /todo/pending/028l-scheduler-grammar-and-policy.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 028 Scheduler Grammar And Policy

## Objective
Add RFC3339, interval, and five-field cron parsing with explicit timezone, misfire, overlap, and next-run computation policy. The chain makes schedule interpretation deterministic before due-job execution exists.

## Rationale
The user selected both cron and simpler time grammars, but cron must not own runtime truth. A parser/policy layer gives the scheduler one canonical temporal contract across platforms.

## Scope

**In scope:**
- apps/backend/src/core/scheduler parser and policy modules.
- Scheduler capability work required by this chain's phase boundary.
- Tests, documentation, and evidence needed to prove this phase before downstream chains depend on it.

**Out of scope:**
- Implementing a hidden OS cron dependency as source truth.
- Adding a second tool runtime, provider loop, command runner, or schedule store.
- Shipping platform-specific service installers before the portable kernel-owned scheduler is proven.

## Current Code Alignment (2026-05-21)
- Schedule grammar and policy remain unimplemented. This chain should add parser/time-zone/policy modules inside apps/backend/src/core/scheduler/ and must feed normalized due instants into the ledger rather than storing natural-language strings as executable truth.
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
| 028a | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase a and capture evidence before archival. |
| 028b | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase b and capture evidence before archival. |
| 028c | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase c and capture evidence before archival. |
| 028d | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase d and capture evidence before archival. |
| 028e | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase e and capture evidence before archival. |
| 028f | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase f and capture evidence before archival. |
| 028g | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase g and capture evidence before archival. |
| 028h | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase h and capture evidence before archival. |
| 028i | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase i and capture evidence before archival. |
| 028j | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase j and capture evidence before archival. |
| 028k | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase k and capture evidence before archival. |
| 028l | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase l and capture evidence before archival. |

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
| /todo/pending/028-scheduler-grammar-and-policy.md | parent | Chain root | done |
| /todo/pending/028a-scheduler-grammar-and-policy.md | a | Baseline / contract lock | done |
| /todo/pending/028b-scheduler-grammar-and-policy.md | b | RFC3339 one-shot parser | done |
| /todo/pending/028c-scheduler-grammar-and-policy.md | c | Interval parser and duration validation | done |
| /todo/pending/028d-scheduler-grammar-and-policy.md | d | Five-field cron parser | done |
| /todo/pending/028e-scheduler-grammar-and-policy.md | e | Timezone and UTC normalization policy | done |
| /todo/pending/028f-scheduler-grammar-and-policy.md | f | Misfire policy computation | done |
| /todo/pending/028g-scheduler-grammar-and-policy.md | g | Overlap policy computation | done |
| /todo/pending/028h-scheduler-grammar-and-policy.md | h | Next-run calculator | done |
| /todo/pending/028i-scheduler-grammar-and-policy.md | i | Invalid grammar diagnostics | done |
| /todo/pending/028j-scheduler-grammar-and-policy.md | j | Boundary fixture corpus | done |
| /todo/pending/028k-scheduler-grammar-and-policy.md | k | Temporal parser and policy tests | done |
| /todo/pending/028l-scheduler-grammar-and-policy.md | l | Verification / closeout | done |

Chain is complete when all rows read archived and all files are in /todo/changelog/.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| a | Baseline / contract lock | Temporal policy contract lock | - | No |
| b | RFC3339 one-shot parser | RFC3339 one-shot parser | 028a | No |
| c | Interval parser and duration validation | Interval parser and duration validation | 028b | No |
| d | Five-field cron parser | Five-field cron parser | 028c | No |
| e | Timezone and UTC normalization policy | Timezone and UTC normalization policy | 028d | No |
| f | Misfire policy computation | Misfire policy computation | 028e | No |
| g | Overlap policy computation | Overlap policy computation | 028f | No |
| h | Next-run calculator | Next-run calculator | 028g | No |
| i | Invalid grammar diagnostics | Invalid grammar diagnostics | 028h | No |
| j | Boundary fixture corpus | Boundary fixture corpus | 028i | No |
| k | Temporal parser and policy tests | Temporal parser and policy tests | 028j | No |
| l | Verification / closeout | Verification / regression / closeout | 028k | No |

## Validation Expectations
- Signal 1: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all exits 0 after this chain's implementation units are complete.
- Signal 2: Scheduler-specific tests for this chain prove at least one adversarial failure or recovery path, not only a happy path.
- Signal 3: VAR1 tools --json and/or protocol surfaces remain catalog-consistent where this chain touches tool or host behavior.
- Per-unit test floor: every implementation execution unit must provide at least 30 meaningful feature-value tests before archival, unless it is explicitly documentation-only or baseline-only and records that exemption.
- Evidence format expected: exact command, exit code, and stdout excerpt for every validation command.

## Next todo
/todo/pending/028a-scheduler-grammar-and-policy.md


## Completion Evidence (2026-05-21)
- Runtime implementation committed through canonical backend lane: core scheduler store/service, schedule_job tool, stdio protocol read model, CLI schedule read model, and health supervisor proof.
- Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed.
- Validation: apps/backend/scripts/zigw.ps1 build install --summary all => install success.
- Capability proof: VAR1 health --json => scheduler_supervisor=true.
- Capability proof: VAR1 tools --json => schedule_job advertised.
- Capability proof: VAR1 schedule list --json => canonical schedule list response.
