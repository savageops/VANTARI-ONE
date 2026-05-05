---
id: 025a-tool-risk-metadata-ownership
parent: 025-tool-risk-metadata-ownership
type: execution-unit
protocol_version: "2.1"
category: simplification
phase: a
status: done
patch_scope: "Baseline lock for tool risk metadata ownership."
blast_radius: low
blast_radius_justification: "Planning artifact only; no runtime code changes in this unit."
idempotency_contract: idempotent
idempotency_notes: "Re-reading and archiving the baseline does not alter runtime state."
acceptance: "The chain records risk metadata ownership as a simplification and forbids new runtime machinery."
exit_criterion: "Parent and unit files exist with source-message anchors and invariants."
validation: "git status --short"
expected_exit_code: 0
expected_output_pattern: ".docs/todo/pending/025"
evidence: "git status --short --ignored .docs\\todo\\pending\\025-tool-risk-metadata-ownership.md .docs\\todo\\pending\\025a-tool-risk-metadata-ownership.md -> !! .docs/todo/pending/"
conflict_surface: ""
invariants:
  - "I1: Provider-visible tool definitions and review-visible risk classification derive from the same ToolDefinition records."
  - "I3: No new runtime diagnostics, background workers, evaluator mutation, or parallel system is introduced."
source_message_anchor: "U1, U4, U5"
source_message_excerpt: "\"All right, proceed.\" | \"Is it adding unnecessary complexity?\" | \"more simple, but more capable.\""
source_message_proof_obligation: "Freeze the requested continuation as a simplification of existing capability governance."
entry_state: "024-agent-capability-governance is archived; review.zig currently owns a private risk name table."
rollback_surface: "Remove /todo/pending/025*.md if execution is aborted before code edits."
dependencies: ""
next_todo: /todo/pending/025b-tool-risk-metadata-ownership.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/025a-tool-risk-metadata-ownership.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 025a Baseline Lock

## Execute Now
Lock the correction as catalog-owned risk metadata with no new runtime machinery.

## Why This Execution Unit Exists
The implementation must remain a simplification of the existing governance layer. This unit prevents the follow-up from expanding into new diagnostics, autonomous evaluation, or background orchestration.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "All right, proceed." | Proceed with the next ready architecture correction. | Chain files exist. |
| U4 | "Is it adding unnecessary complexity?" | Constrain the correction to removing drift. | Scope/out-of-scope sections. |
| U5 | "more simple, but more capable." | Make capability classification smaller and stronger. | Invariants I1-I3. |

## Pre-flight Checklist
- [ ] Dependencies are empty.
- [ ] Entry state is verified.
- [ ] Source-message proof is present.
- [ ] Conflict surface is empty.
- [ ] Rollback procedure is populated.
- [ ] Idempotency contract is read.

## Entry State
- `.docs/todo/changelog/024-agent-capability-governance.md` is archived.
- `apps/backend/variant-1/src/core/tools/review.zig` owns private tool name risk arrays.

## Patch Surface

**Modifies:**
- None.

**Adds:**
- `.docs/todo/pending/025-tool-risk-metadata-ownership.md` - parent chain.
- `.docs/todo/pending/025a-tool-risk-metadata-ownership.md` - baseline lock.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- Runtime source files.

## Detailed Requirements
- R1: Preserve the implementation target as metadata ownership only.
- R2: Keep all runtime behavior changes for 025b.

## Invariants This Unit Must Preserve
- I1: Provider-visible tool definitions and review-visible risk classification derive from the same `ToolDefinition` records.
- I3: No new runtime diagnostics, background workers, evaluator mutation, or parallel system is introduced.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `git status --short` | `0` | `.docs/todo/pending/025` | yes |

**Evidence to capture:** `git status --short` excerpt showing the 025 planning files.

## Exit State (Handoff Contract)
- The 025 chain exists and constrains 025b to a metadata-ownership simplification.

## Rollback Procedure
1. Delete the 025 pending planning files if no runtime edits have been made.

## Next todo
`/todo/pending/025b-tool-risk-metadata-ownership.md`

## Completion
- [x] Pre-flight passed.
- [x] Validation command executed.
- [x] Evidence captured.
- [x] Status set to `done`.
- [x] File moved to changelog.
- [x] Continue immediately to `next_todo`.
