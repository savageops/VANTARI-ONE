---
id: 025-tool-risk-metadata-ownership
type: parent
protocol_version: "2.1"
spec_status: approved
category: simplification
status: done
epic_boundary: "Collapse pre-dispatch tool risk classification into module-owned tool metadata so the review gate cannot drift from the provider-visible tool catalog."
subtodo_start: /todo/pending/025a-tool-risk-metadata-ownership.md
subtodo_final: /todo/pending/025c-tool-risk-metadata-ownership.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 025 Tool Risk Metadata Ownership

## Objective
Move capability risk truth from the private `review.zig` string table into `shared.types.ToolDefinition`, annotate every live built-in definition, and make the executor review only against the currently exposed catalog for the active execution context.

## Rationale
The completed capability-governance chain introduced review-before-effect, but left a transitional hard-coded risk map inside the reviewer. That violates the stronger architecture invariant that tool capability truth remains module-owned and catalog-derived.

## Scope

**In scope:**
- Add a stable tool risk enum and field to `ToolDefinition`.
- Annotate file, agent, and workspace-state tool definitions.
- Rewrite the review function to classify by the provided active tool definition set.
- Add validation that unavailable-context tools are blocked even if they exist elsewhere in the codebase.
- Update architecture docs and changelog.

**Out of scope:**
- Dynamic plugin loading.
- New worker or evaluator behavior.
- Replacing registry availability.
- Changing tool execution semantics.

## Source Language Anchors
- "All right, proceed."
- "not too much runtime diagnostics and investigation and verbose outputs"
- "usability, usefulness, and actual strength in the harness"
- "Is it adding unnecessary complexity?"
- "more simple, but more capable."

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | execution approval | "All right, proceed." | 025a, 025b, 025c |
| U2 | anti-noise constraint | "not too much runtime diagnostics and investigation and verbose outputs" | 025b, 025c |
| U3 | harness strength | "usability, usefulness, and actual strength in the harness" | 025b, 025c |
| U4 | complexity check | "Is it adding unnecessary complexity?" | 025a, 025b, 025c |
| U5 | simplicity/capability invariant | "more simple, but more capable." | 025a, 025b, 025c |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 025a | U1, U4, U5 | Freeze the correction as simplification, not new runtime machinery. |
| 025b | U1, U2, U3, U4, U5 | Implement catalog-owned risk metadata and remove the private reviewer name table. |
| 025c | U1, U2, U3, U4, U5 | Verify tests, docs, and chain evidence prove the simplification holds. |

## Constraints

| Dimension | Constraint |
|-----------|------------|
| Category boundary | Only simplification of the existing governance contract. |
| Blast radius ceiling | medium - shared tool definition type and executor review call site are observable by provider/tool tests. |
| Structural boundary | `apps/backend/variant-1` remains the only live runtime lane. |
| Dependency boundary | Existing pending 021 auth chain is not touched. |
| Rollback surface | Revert shared type field, definition annotations, review function signature, loop call-site, tests, docs, and this chain. |
| Parallelism | No parallel execution units; type contract gates implementation and verification. |

## Invariants
- I1: Provider-visible tool definitions and review-visible risk classification derive from the same `ToolDefinition` records.
- I2: Unknown or context-unavailable tools remain blocked before execution.
- I3: No new runtime diagnostics, background workers, evaluator mutation, or parallel system is introduced.
- I4: Tool execution behavior remains unchanged after approval.
- I5: Documentation describes current runtime truth.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/025-tool-risk-metadata-ownership.md` | parent | Chain root | archived |
| `/todo/changelog/025a-tool-risk-metadata-ownership.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/025b-tool-risk-metadata-ownership.md` | b | Metadata ownership implementation | archived |
| `/todo/changelog/025c-tool-risk-metadata-ownership.md` | c | Verification / closeout | archived |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline / contract lock | Planning artifact only | - | No |
| `b` | Implementation | Shared type, tool definitions, review interpreter, loop call site, tests, docs | `a` | No |
| `c` | Verification / closeout | Tests, git evidence, changelog, archive parent | `b` | No |

## Validation Expectations
- `review.zig` no longer owns hand-indexed read/write/delegating tool name arrays.
- `reviewToolCall` receives active definitions and blocks catalog-absent tool names.
- Focused tests and full Zig tests pass.
- `_log.md` records the simplification.

## Next todo
`NONE`
