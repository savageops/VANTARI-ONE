---
id: 025b-tool-risk-metadata-ownership
parent: 025-tool-risk-metadata-ownership
type: execution-unit
protocol_version: "2.1"
category: simplification
phase: b
status: done
patch_scope: "Move tool review risk classification from reviewer-owned name arrays to ToolDefinition metadata."
blast_radius: medium
blast_radius_justification: "Shared ToolDefinition and executor review call site affect provider-visible tool metadata and all tool-call execution paths."
idempotency_contract: idempotent
idempotency_notes: "The patch replaces deterministic declarations and tests; reapplying produces the same source state."
acceptance: "review.zig classifies risk from active ToolDefinition values and blocks tool names absent from the active catalog."
exit_criterion: "Focused tool review tests pass and review.zig contains no private name arrays."
validation: ".\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "95/95"
evidence: ".\\scripts\\zigw.ps1 build test --summary all -> Build Summary: 5/5 steps succeeded; 95/95 tests passed"
conflict_surface: ""
invariants:
  - "I1: Provider-visible tool definitions and review-visible risk classification derive from the same ToolDefinition records."
  - "I2: Unknown or context-unavailable tools remain blocked before execution."
  - "I3: No new runtime diagnostics, background workers, evaluator mutation, or parallel system is introduced."
  - "I4: Tool execution behavior remains unchanged after approval."
source_message_anchor: "U1, U2, U3, U4, U5"
source_message_excerpt: "\"All right, proceed.\" | \"not too much runtime diagnostics and investigation and verbose outputs\" | \"usability, usefulness, and actual strength in the harness\" | \"Is it adding unnecessary complexity?\" | \"more simple, but more capable.\""
source_message_proof_obligation: "Implement the stronger harness primitive by removing private review drift while preserving low-noise runtime behavior."
entry_state: "025a is archived; shared ToolDefinition has no risk field; review.zig owns hard-coded risk arrays."
rollback_surface: "Revert shared/types.zig, tool definitions, review.zig, loop.zig, tests, and docs changed by this unit."
dependencies: "025a-tool-risk-metadata-ownership"
next_todo: /todo/pending/025c-tool-risk-metadata-ownership.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/025b-tool-risk-metadata-ownership.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 025b Metadata Ownership Implementation

## Execute Now
Add tool risk metadata to `ToolDefinition`, annotate every built-in tool definition, and make the review gate classify only from the active catalog.

## Why This Execution Unit Exists
This is the only runtime patch surface. It compresses the previous governance implementation by moving risk truth into the same object that defines provider-visible capability.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U2 | "not too much runtime diagnostics and investigation and verbose outputs" | Keep review output shape unchanged except risk source. | Test output and diff. |
| U3 | "usability, usefulness, and actual strength in the harness" | Strengthen harness capability gating. | Runtime loop and test assertions. |
| U5 | "more simple, but more capable." | Remove private reviewer arrays. | `review.zig` diff and tests. |

## Pre-flight Checklist
- [ ] `025a-tool-risk-metadata-ownership.md` is archived with evidence.
- [ ] Entry state claims are verified.
- [ ] Source-message proof is present.
- [ ] Conflict surface is empty.
- [ ] Rollback procedure is populated.
- [ ] Idempotency contract is read.

## Entry State
- `apps/backend/variant-1/src/shared/types.zig` defines `ToolDefinition`.
- `apps/backend/variant-1/src/core/tools/review.zig` currently classifies names with private arrays.
- `apps/backend/variant-1/src/core/executor/loop.zig` calls `reviewToolCall(tool_call)`.

## Patch Surface

**Modifies:**
- `apps/backend/variant-1/src/shared/types.zig`
- `apps/backend/variant-1/src/core/tools/review.zig`
- `apps/backend/variant-1/src/core/tools/runtime.zig`
- `apps/backend/variant-1/src/core/executor/loop.zig`
- `apps/backend/variant-1/src/core/tools/builtin/*.zig`
- `apps/backend/variant-1/src/core/tools/workspace_runtime.zig`
- `apps/backend/variant-1/tests/tools_test.zig`
- `apps/backend/variant-1/architecture.md`

**Adds:**
- None.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- Provider transport semantics.
- Agent service lifecycle.
- Memory/evaluation modules.

## Detailed Requirements
- R1: Add `ToolRiskClass` to shared types with the existing risk vocabulary.
- R2: Add `review_risk` to `ToolDefinition`.
- R3: Annotate each built-in definition with its risk class.
- R4: Change `reviewToolCall` to receive active definitions and classify only matching names.
- R5: Keep blocked result and review event schemas unchanged.
- R6: Update catalog JSON to expose `review_risk` for operator inspection.
- R7: Add tests for catalog-owned classification and context-unavailable blocking.

## Invariants This Unit Must Preserve
- I1: Provider-visible tool definitions and review-visible risk classification derive from the same `ToolDefinition` records.
- I2: Unknown or context-unavailable tools remain blocked before execution.
- I3: No new runtime diagnostics, background workers, evaluator mutation, or parallel system is introduced.
- I4: Tool execution behavior remains unchanged after approval.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `.\\scripts\\zigw.ps1 build test --summary all` | `0` | `95/95` | yes |

**Evidence to capture:** full Zig test summary.

## Exit State (Handoff Contract)
- `ToolDefinition` owns risk metadata.
- `review.zig` has no private read/write/delegating name arrays.
- Executor review uses active context definitions.
- Tests cover read, write, delegation, unknown, and context-unavailable blocking.

## Rollback Procedure
1. Revert this unit's changes to source, tests, and docs.
2. Re-run `.\\scripts\\zigw.ps1 build test --summary all`.

## Next todo
`/todo/pending/025c-tool-risk-metadata-ownership.md`

## Completion
- [x] Pre-flight passed.
- [x] Validation command executed.
- [x] Evidence captured.
- [x] Status set to `done`.
- [x] File moved to changelog.
- [x] Continue immediately to `next_todo`.
