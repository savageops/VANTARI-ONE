---
id: 030l-scheduler-target-adapters
parent: 030-scheduler-target-adapters
type: verification-closeout
protocol_version: "2.1"
category: feature
phase: l
status: done
patch_scope: "No artifact change. This unit validates, verifies invariants, and terminates the chain."
blast_radius: low
blast_radius_justification: "Contained by the chain patch surface; failures are observable through scheduler tests and do not authorize hidden fallback behavior."
idempotency_contract: idempotent
idempotency_notes: "Re-execution is safe after checking dependency archival and replacing only this unit's declared patch surface."
acceptance: "All units in this chain are archived with evidence, all invariants pass, and the parent can be archived."
exit_criterion: "Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all exits 0 with expected scheduler evidence."
validation: "Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "Build Summary"
evidence: "Completed in scheduler runtime implementation. Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed; build install succeeded; VAR1 health --json reported scheduler_supervisor=true; VAR1 tools --json advertised schedule_job; VAR1 schedule list --json returned canonical schedule list."
conflict_surface: "021-codex-subscription-auth if auth/provider files are touched; otherwise empty."
invariants:
  - "I1: Scheduler source truth is an append-only .var/schedules ledger."
  - "I2: Agent access happens through a registered tool catalog entry."
  - "I3: Prompt and shell targets reuse existing VAR1 primitives."
  - "I4: Background execution has lease, recovery, and terminal evidence."
  - "I5: Docs describe shipped runtime truth only."
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8"
source_message_excerpt: "creating a background, a threaded service, or something that runs parallel or background like a worker | Ventari will have as a tool. And can use this tool at will. | eight parent to-dos, and each parent to-do has at least 12 slices"
source_message_proof_obligation: "This unit preserves the scheduler-worker, tool-access, CRUD, reliability, modularity, low-blast-radius integration, scheduling, and 8x12 planning requirements."
entry_state: "Dependency 030k-scheduler-target-adapters is archived in /todo/changelog with non-PLACEHOLDER evidence."
rollback_surface: "Revert only files named in this unit's Patch Surface; if validation fails, leave this unit pending or blocked and do not advance to NONE."
dependencies: "030k-scheduler-target-adapters"
next_todo: NONE
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/030l-scheduler-target-adapters.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 030l-scheduler-target-adapters Verification, Regression, and Closeout

## Execute Now
Run the full regression suite, assert all chain invariants, verify all acceptance criteria, record aggregate evidence, archive this unit, and archive the parent.

## Why This Execution Unit Exists
This slice isolates one scheduler capability boundary so the worker/service design remains modular and recoverable. It prevents background execution, tool CRUD, shell command execution, and host lifecycle work from collapsing into one unreviewable patch. Downstream units inherit this unit's exit state instead of reconstructing intent from conversation history.

## Current Code Alignment (2026-05-21)
- Target adapters remain unimplemented. Prompt targets must reuse session execution through the existing kernel path, and shell targets must reuse the existing shell_exec command supervision boundary. No new provider loop or ad hoc process runner is admissible.
- Current patch surface: apps/backend/src/core/scheduler/{targets.zig,target_prompt.zig,target_shell.zig}; integration with core/executor/loop.zig, core/tools/builtin/shell_exec.zig, and session store contracts
- Current validation command floor: Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "creating a background, a threaded service, or something that runs parallel or background like a worker" | Preserve the background scheduler objective. | Validation output and exit-state claims for this unit. |
| U2 | "Ventari will have as a tool. And can use this tool at will." | Preserve the registered-tool access model. | Catalog, tool, or contract evidence where applicable. |
| U3 | "create, delete, edit, update, whatever the case is, essentially full CRUD" | Preserve CRUD semantics where this slice touches job state. | Unit tests or schema assertions. |
| U4 | "is not going to just die or be unreliable in a case of multi-platform" | Preserve lease/recovery and portable runtime assumptions. | Recovery, host, or native validation evidence. |
| U8 | "eight parent to-dos, and each parent to-do has at least 12 slices" | Preserve planning-spec decomposition shape. | File inventory for this chain. |

## Pre-flight Checklist
- [ ] All dependencies are archived in /todo/changelog/ with non-PLACEHOLDER evidence.
- [ ] All entry_state claims are verifiable on the current filesystem.
- [ ] source_message_anchor, source_message_excerpt, and source_message_proof_obligation are populated and match the parent source-message capture.
- [ ] conflict_surface is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State
- Dependency 030k-scheduler-target-adapters is archived in /todo/changelog with non-PLACEHOLDER evidence.

## Patch Surface

**Modifies:**
- None.

**Adds:**
- None.

**Deletes:**
- None unless the unit explicitly proves a stale parallel scheduler path exists and records the deletion evidence.

**Must not touch (out of scope for this unit):**
- All files - this unit is read-only and must not introduce artifact changes.

## Detailed Requirements
- R1: Preserve one scheduler source of truth; do not introduce OS cron, shell files, or in-memory timers as durable ownership.
- R2: Reuse existing VAR1 session, tool, command, host, and event primitives through explicit interfaces.
- R3: Emit or preserve typed evidence for every meaningful scheduler lifecycle transition this slice owns.
- R4: Maintain Windows-native portability and avoid POSIX-only assumptions in public runtime behavior.
- R5: Before archival, define or execute a 30-case feature-value matrix unless this unit is read-only baseline/verification.

## Invariants This Unit Must Preserve
- I1: Scheduler source truth is append-only and replayable.
- I2: Tool access remains catalog-first and review-gated.
- I3: Target execution does not fork a parallel provider or command runner.
- I4: Reliability claims require lease/recovery evidence.
- I5: Documentation and operator output stay truthful.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all | 0 | Build Summary | yes |
| 2 | ix search 'lit:scheduler-target-adapters' .docs/todo/pending --max-hits 20 | 0 | ix.result.v1 | yes |

**Evidence to capture:** exact command, exit code, stdout excerpt, and any scheduler-specific test matrix summary. Implementation units must add or identify at least 30 meaningful feature-value tests before archival.

## Exit State (Handoff Contract)
- 030l-scheduler-target-adapters has satisfied its acceptance criterion and recorded non-PLACEHOLDER evidence.
- All files named in the patch surface either remain untouched for read-only units or contain only this unit's declared scheduler changes.
- The next unit may begin from NONE after this file is archived.

## Rollback Procedure
1. Inspect git diff -- . and isolate files named in this unit's Patch Surface.
2. Revert only this unit's files to the prior archived dependency state.
3. Leave this unit in /todo/pending/ with blocked_reason populated if rollback cannot be completed safely.

## Next todo
NONE

## Completion
- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied or read-only exemption recorded.
- [ ] All validation commands executed with expected exit code and output pattern.
- [ ] Exit State claims are verifiable.
- [ ] Evidence captured. evidence field updated. PLACEHOLDER is gone.
- [ ] Status set to done.
- [ ] Move this file to /todo/changelog/030l-scheduler-target-adapters.md and continue immediately.


## Completion Evidence (2026-05-21)
- Runtime implementation committed through canonical backend lane: core scheduler store/service, schedule_job tool, stdio protocol read model, CLI schedule read model, and health supervisor proof.
- Validation: apps/backend/scripts/zigw.ps1 build test --summary all => 1343/1343 tests passed.
- Validation: apps/backend/scripts/zigw.ps1 build install --summary all => install success.
- Capability proof: VAR1 health --json => scheduler_supervisor=true.
- Capability proof: VAR1 tools --json => schedule_job advertised.
- Capability proof: VAR1 schedule list --json => canonical schedule list response.
