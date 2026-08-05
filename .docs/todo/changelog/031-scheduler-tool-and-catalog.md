---
id: 031-scheduler-tool-and-catalog
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Expose scheduler CRUD through a single registered built-in tool without bypassing tool review, availability, or runtime dispatch."
subtodo_start: /todo/pending/031a-scheduler-tool-and-catalog.md
subtodo_final: /todo/pending/031l-scheduler-tool-and-catalog.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 031 Scheduler Tool And Catalog

## Objective
Add schedule_job as the agent-facing CRUD and run-now tool for the scheduler. The tool schema, runtime parser, catalog availability, review risk, and execution envelope must all be module-owned and catalog-visible.

## Rationale
VANTARI tools are declared capabilities, not hidden backend routes. The scheduler becomes agent-usable only when it enters the existing ToolDefinition, registry, review, provider-schema, and dispatch pipeline.

## Scope

**In scope:**
- apps/backend/src/core/tools builtin scheduler tool and catalog wiring.
- Scheduler capability work required by this chain's phase boundary.
- Tests, documentation, and evidence needed to prove this phase before downstream chains depend on it.

**Out of scope:**
- Implementing a hidden OS cron dependency as source truth.
- Adding a second tool runtime, provider loop, command runner, or schedule store.
- Shipping platform-specific service installers before the portable kernel-owned scheduler is proven.

## Current Code Alignment (2026-05-21)
- The current built-in tool surface is module-owned through apps/backend/src/core/tools/runtime.zig, registry.zig, module.zig, review.zig, sockets.zig, and index.zig. schedule_job must enter as a normal built-in module under apps/backend/src/core/tools/builtin/ and be exported through the current runtime/registry/index contract; hidden host-only scheduler routes would violate agent tool access.
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
| 031a | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase a and capture evidence before archival. |
| 031b | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase b and capture evidence before archival. |
| 031c | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase c and capture evidence before archival. |
| 031d | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase d and capture evidence before archival. |
| 031e | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase e and capture evidence before archival. |
| 031f | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase f and capture evidence before archival. |
| 031g | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase g and capture evidence before archival. |
| 031h | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase h and capture evidence before archival. |
| 031i | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase i and capture evidence before archival. |
| 031j | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase j and capture evidence before archival. |
| 031k | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase k and capture evidence before archival. |
| 031l | U1, U2, U3, U4, U5, U6, U7, U8 | Preserve scheduler capability requirements for phase l and capture evidence before archival. |

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
| /todo/pending/031-scheduler-tool-and-catalog.md | parent | Chain root | done |
| /todo/pending/031a-scheduler-tool-and-catalog.md | a | Baseline / contract lock | done |
| /todo/pending/031b-scheduler-tool-and-catalog.md | b | schedule_job definition module | done |
| /todo/pending/031c-scheduler-tool-and-catalog.md | c | Create action parser and executor | done |
| /todo/pending/031d-scheduler-tool-and-catalog.md | d | Get and list action parser and executor | done |
| /todo/pending/031e-scheduler-tool-and-catalog.md | e | Update action parser and executor | done |
| /todo/pending/031f-scheduler-tool-and-catalog.md | f | Delete action parser and executor | done |
| /todo/pending/031g-scheduler-tool-and-catalog.md | g | Pause and resume action parser and executor | done |
| /todo/pending/031h-scheduler-tool-and-catalog.md | h | Run-now action parser and executor | done |
| /todo/pending/031i-scheduler-tool-and-catalog.md | i | Tool error hints and effect envelope | done |
| /todo/pending/031j-scheduler-tool-and-catalog.md | j | Provider schema/catalog parity | done |
| /todo/pending/031k-scheduler-tool-and-catalog.md | k | Tool contract tests | done |
| /todo/pending/031l-scheduler-tool-and-catalog.md | l | Verification / closeout | done |

Chain is complete when all rows read archived and all files are in /todo/changelog/.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| a | Baseline / contract lock | Tool contract and schema lock | - | No |
| b | schedule_job definition module | schedule_job definition module | 031a | No |
| c | Create action parser and executor | Create action parser and executor | 031b | No |
| d | Get and list action parser and executor | Get and list action parser and executor | 031c | No |
| e | Update action parser and executor | Update action parser and executor | 031d | No |
| f | Delete action parser and executor | Delete action parser and executor | 031e | No |
| g | Pause and resume action parser and executor | Pause and resume action parser and executor | 031f | No |
| h | Run-now action parser and executor | Run-now action parser and executor | 031g | No |
| i | Tool error hints and effect envelope | Tool error hints and effect envelope | 031h | No |
| j | Provider schema/catalog parity | Provider schema/catalog parity | 031i | No |
| k | Tool contract tests | Tool contract tests | 031j | No |
| l | Verification / closeout | Verification / regression / closeout | 031k | No |

## Validation Expectations
- Signal 1: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all exits 0 after this chain's implementation units are complete.
- Signal 2: Scheduler-specific tests for this chain prove at least one adversarial failure or recovery path, not only a happy path.
- Signal 3: VAR1 tools --json and/or protocol surfaces remain catalog-consistent where this chain touches tool or host behavior.
- Per-unit test floor: every implementation execution unit must provide at least 30 meaningful feature-value tests before archival, unless it is explicitly documentation-only or baseline-only and records that exemption.
- Evidence format expected: exact command, exit code, and stdout excerpt for every validation command.

## Next todo
/todo/pending/031a-scheduler-tool-and-catalog.md


## Completion Evidence (2026-05-21)
- Runtime implementation committed through canonical backend lane: core scheduler store/service, schedule_job tool, stdio protocol read model, CLI schedule read model, and health supervisor proof.
- Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed.
- Validation: apps/backend/scripts/zigw.ps1 build install --summary all => install success.
- Capability proof: VAR1 health --json => scheduler_supervisor=true.
- Capability proof: VAR1 tools --json => schedule_job advertised.
- Capability proof: VAR1 schedule list --json => canonical schedule list response.
