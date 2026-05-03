---
id: 024b-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: b
status: pending
patch_scope: "Pre-tool review contract primitives for deterministic review-before-effect decisions."
blast_radius: high
blast_radius_justification: "This unit introduces shared tool review types and policy used by the executor loop before side effects. Failure can block or wrongly approve foundational tool execution."
idempotency_contract: idempotent
idempotency_notes: "The patch adds/replaces deterministic Zig source and tests. Reapplying the same source changes produces the same filesystem state."
acceptance: "A new review module classifies tool calls into review risk, returns deterministic approved/blocked decisions, and has focused tests proving mutating/delegating tools require review while safe read-only tools remain available."
exit_criterion: "Zig tests covering tool review policy pass and `ix search \"lit:ToolReviewDecision || lit:tool_reviewed\" apps/backend/variant-1/src apps/backend/variant-1/tests --json` finds the typed review contract."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend\\variant-1; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "PLACEHOLDER - replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: "021-codex-subscription-auth"
invariants:
  - "I3: high-risk/write-capable/delegating tool calls must have a deterministic reviewed transition before side effects."
  - "I4: read-only tool behavior remains backward compatible unless explicit review policy requires metadata-only review evidence."
  - "I5: tool capability truth remains module-owned through registry/tool definitions."
  - "I8: unsupported runtime behavior fails by contract or reports explicit diagnostics."
source_message_anchor: "U1, U6, U7, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Implement the smallest review-before-effect primitive that materially improves architecture without regressing existing tool availability or behavior."
entry_state: "`024a-agent-capability-governance` is archived with non-PLACEHOLDER evidence. If `apps/backend/variant-1/src/shared/types.zig` is still touched by pending `021b`, `021f-codex-subscription-auth` is archived first."
rollback_surface: "Revert `apps/backend/variant-1/src/core/tools/review.zig`, review exports in `src/core/tools/runtime.zig` and `src/core/tools/module.zig`, shared review structs in `src/shared/types.zig`, and focused review tests; then rerun Zig tests."
dependencies: "024a-agent-capability-governance, 021f-codex-subscription-auth"
next_todo: /todo/pending/024c-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024b-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024b Pre-Tool Review Contract Primitives

## Execute Now

Add deterministic tool-review contract primitives that classify tool-call risk and return approved or blocked decisions before runtime side effects.

## Why This Execution Unit Exists

The executor cannot safely gain a review phase until review semantics exist independently of the loop. This unit isolates the policy contract from execution so tests can prove risk classification, diagnostics, and backward-compatible read-only behavior before the loop begins depending on the new primitive.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Translate Reinforced Agent into a concrete VAR1 review primitive. | Tests and `ix search` show review types and policy. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Improve architecture by adding an explicit transition state. | Review tests prove mutating/delegating tools are governed. |
| U7 | "We don't want to change anything for the worse." | Preserve existing read-only tool behavior. | Tests prove safe tools remain approved. |
| U9 | "do something far better, which is more simple, but more capable." | Use a small deterministic module, not a second agent runtime. | Patch surface contains one review owner and focused tests. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `024a-agent-capability-governance` is archived with evidence and locks the interpretation.
- `021f-codex-subscription-auth` is archived if the unit needs `apps/backend/variant-1/src/shared/types.zig`; otherwise document why no shared-types conflict remains before execution.
- `apps/backend/variant-1/src/core/tools/registry.zig` resolves availability from module-owned definitions.
- `apps/backend/variant-1/src/core/tools/module.zig` owns shared tool execution types and error contracts.

## Patch Surface

**Modifies:**
- `apps/backend/variant-1/src/core/tools/runtime.zig` - export or route the review primitive without changing current catalog shape.
- `apps/backend/variant-1/src/core/tools/module.zig` - add minimal shared review enums/structs only if they are tool-runtime owned.
- `apps/backend/variant-1/src/shared/types.zig` - add protocol-visible review structs only if loop/session/event consumers need them.
- `apps/backend/variant-1/tests/**` - add focused review-policy tests.

**Adds:**
- `apps/backend/variant-1/src/core/tools/review.zig` - canonical owner for risk classification and deterministic review decisions.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/variant-1/src/core/executor/loop.zig` - loop integration is `024c`.
- `apps/backend/variant-1/src/core/agents/service.zig` - delegation scope is `024d`.
- `.var/sessions/**` - tests must use isolated temp workspaces only.

## Detailed Requirements

- R1: Define a review risk taxonomy with at least `read_only`, `write_capable`, `delegating`, and `unknown_high_impact`.
- R2: Define a deterministic review result with fields equivalent to `approved`, `risk`, `reason`, `event_type`, and optional `tool_error_hint`.
- R3: Classify `write_file`, `append_file`, and `replace_in_file` as write-capable.
- R4: Classify `launch_agent`, child-session creation, or equivalent agent-spawning tools as delegating.
- R5: Classify unknown tool names as blocked or unresolved before execution; do not silently treat unknown capabilities as safe.
- R6: Keep `list_files`, `search_files`, and `read_file` approved unless later policy explicitly requires metadata-only review.
- R7: Keep availability truth delegated to `registry.resolveAvailability()` or its current owner; review policy must not introduce a second availability table.
- R8: Write tests that assert blocked decisions never require a model-backed reviewer or external network.

## Invariants This Unit Must Preserve

- I3: High-risk/write-capable/delegating tool calls must have a deterministic review transition before side effects.
- I4: Read-only tool behavior remains backward compatible.
- I5: Tool capability truth remains module-owned through registry/tool definitions.
- I8: Unsupported runtime behavior fails by contract.
- I10: The implementation remains smaller than copied MAS architecture.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:ToolReviewDecision || lit:tool_reviewed" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | `0` | `ToolReviewDecision` | yes |

**Evidence to capture:** Zig test stdout and `ix search` output proving review contract ownership.

## Exit State (Handoff Contract)

- `src/core/tools/review.zig` or equivalent canonical owner exists and exports deterministic review classification.
- Tests prove mutating and delegating tools require review and read-only tools remain approved.
- `024c` can call the review primitive from the executor loop without inventing review semantics inside `loop.zig`.

## Rollback Procedure

1. Revert `apps/backend/variant-1/src/core/tools/review.zig`.
2. Revert review-related changes in `apps/backend/variant-1/src/core/tools/runtime.zig`, `apps/backend/variant-1/src/core/tools/module.zig`, and `apps/backend/variant-1/src/shared/types.zig`.
3. Revert focused review tests under `apps/backend/variant-1/tests/**`.
4. Run `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all`.

## Next todo

`/todo/pending/024c-agent-capability-governance.md`

## Completion

- [ ] Pre-flight passed (all checklist items verified before execution began).
- [ ] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [ ] Post-flight: all Exit State claims are verifiable on the filesystem.
- [ ] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/024b-agent-capability-governance.md /todo/changelog/024b-agent-capability-governance.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
