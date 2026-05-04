---
id: 024a-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: a
status: done
patch_scope: "Interpretation freeze and invariant declaration. No artifact change."
blast_radius: low
blast_radius_justification: "No runtime files are modified. Failure is contained to chain interpretation quality before implementation begins."
idempotency_contract: idempotent
idempotency_notes: "No artifact changes occur during this unit; re-execution revalidates the same source and code evidence."
acceptance: "The chain interpretation is locked so later units improve VAR1 through native capability primitives, explicitly reject copied MAS architecture, and preserve all parent source-message anchors."
exit_criterion: "ix inspect .docs/todo/pending/024-agent-capability-governance.md --range 1:180 shows source anchors, invariants, conflict boundary, and phase plan covering every lettered unit."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; ix inspect .docs/todo/pending/024-agent-capability-governance.md --range 1:180"
expected_exit_code: 0
expected_output_pattern: "024 Agent Capability Governance"
evidence: "2026-05-04 024a validation passed. Command: ix inspect .docs/todo/pending/024-agent-capability-governance.md --range 1:180 -> exit 0, stdout included '# 024 Agent Capability Governance', source anchors U1-U9, invariants I1-I10, and phase plan 024a-024g. Command: ix inspect apps/backend/variant-1/src/core/executor/loop.zig --range 230:285 -> exit 0, stdout lines 252-258 show for (completion.tool_calls) and const tool_result = try executeToolCall(allocator, execution_context, tool_call). Entry-state verification: ix inspect AGENTS.md --range 1:170 -> exit 0, stdout lines 5-8 declare apps/backend/variant-1 live lane and .var/sessions canonical; Test-Path .docs/research/2026-05-04-multi-agent-systems-9-methods.md -> True; Test-Path apps/backend/variant-1/src/core/agents/service.zig -> True."
conflict_surface: ""
invariants:
  - "I1: messages.jsonl remains the complete durable transcript."
  - "I3: high-risk tool calls require a reviewed transition before side effects."
  - "I7: capability profiles are typed execution boundaries, not copied role taxonomy."
  - "I10: final implementation must be simpler and more capable than copied MAS architecture."
source_message_anchor: "U1, U2, U3, U4, U6, U7, U8, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"All right, I want you to proceed.\"; \"Use the planning spec skill to capture all the details.\"; \"You don't want to miss anything.\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"we don't want to copy.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Freeze the interpretation that external MAS methods are reference signals only, and that the implementation must produce a smaller VAR1-native capability architecture."
entry_state: "The research artifact `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` exists locally, `AGENTS.md` declares VAR1 and `.var/sessions` ownership, and live code evidence shows direct executor tool execution before review."
rollback_surface: "None. This unit modifies no files during execution. If interpretation is wrong, block this unit and revise the parent before implementation begins."
dependencies: ""
next_todo: /todo/pending/024b-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024a-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024a Baseline and Contract Lock

## Execute Now

Lock the source-message interpretation, MAS-to-VAR1 translation boundary, conflict boundary, and invariant set before any runtime patch begins.

## Why This Execution Unit Exists

This unit prevents the implementation from drifting into a copied MAS framework or a vague refactor. It locks the user requirement as a capability-governance upgrade: stronger state transitions, narrower capability boundaries, durable evidence, and no regression to runtime ownership.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Preserve the translation-to-codebase objective. | Parent objective and phase plan show concrete VAR1 patch surfaces. |
| U3 | "Use the planning spec skill to capture all the details." | Preserve the planning-spec contract. | Parent and units use planning-spec v2.1 fields. |
| U4 | "You don't want to miss anything." | Preserve complete source-message coverage. | Parent Source Message Coverage maps every anchor to a unit. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Require measurable architecture/capability improvement. | Parent invariants and validation signals define improvement. |
| U7 | "We don't want to change anything for the worse." | Preserve non-regression as a hard invariant. | Parent invariants I1-I10 govern all units. |
| U8 | "we don't want to copy." | Reject external architecture cloning. | Out-of-scope list rejects copied MAS structures. |
| U9 | "do something far better, which is more simple, but more capable." | Lock the smaller-primitive implementation criterion. | Parent objective and I10 state this as a chain invariant. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` exists and maps the nine MAS methods to VANTARI adoption boundaries.
- `AGENTS.md` states `apps/backend/variant-1` is the only live code lane and `.var/sessions/<session-id>/` is canonical.
- `apps/backend/variant-1/src/core/executor/loop.zig` currently calls `executeToolCall()` after `tool_requested` without an explicit review phase.
- `apps/backend/variant-1/src/core/agents/service.zig` currently seeds child sessions with `agent_profile = "subagent"` but no typed capability profile.

## Patch Surface

**Modifies:**
- None.

**Adds:**
- None.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- All repository files - this unit is interpretation lock only.

## Interpretation Locks

- L1: "Ventori" is interpreted as VANTARI-ONE because the active repository and supplied agent rules are VANTARI-ONE.
- L2: The MAS research is a source of invariants and failure modes only; no external architecture, role hierarchy, or framework vocabulary is imported into runtime ownership.
- L3: The first durable implementation primitive is review-before-effect for high-risk tool calls, not a second agent loop.
- L4: CASCADE translates to scoped delegation state, not broader communication fanout.
- L5: LLMA-Mem translates to derivative memory with source sequence references, not another transcript.
- L6: OMC and OrgAgent translate to typed capability profiles, not a company simulation in product or prompts.
- L7: CORAL translates to heartbeat and evaluator separation, not autonomous background evolution.
- L8: Agentic FL translates to provider/resource policy diagnostics, not federated training.
- L9: RecursiveMAS and GRASP remain research-only for now; their runtime boundary is unsupported until model-internal latent transfer or training-gradient infrastructure exists.

## Invariants This Unit Must Preserve

- I1: `.var/sessions/<session-id>/messages.jsonl` remains the complete durable transcript.
- I3: High-risk/write-capable/delegating tool calls must have a deterministic review transition before side effects.
- I7: Capability profiles are typed execution boundaries, not product UI role taxonomy.
- I8: Unsupported runtime behavior fails by contract or reports explicit diagnostics.
- I10: The final implementation must improve capability with fewer and stronger primitives.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix inspect .docs/todo/pending/024-agent-capability-governance.md --range 1:180` | `0` | `024 Agent Capability Governance` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix inspect apps/backend/variant-1/src/core/executor/loop.zig --range 230:285` | `0` | `executeToolCall` | yes |

**Evidence to capture:** stdout from both commands showing the parent contract and current executor insertion point.

## Exit State (Handoff Contract)

- The interpretation locks are accepted as the only valid reading of the source messages for this chain.
- Implementation units inherit the constraint that all new runtime behavior must be smaller, more explicit, and more capable than copied MAS architecture.
- `024b` may begin only after the live `021` shared-types conflict is resolved if `apps/backend/variant-1/src/shared/types.zig` remains in the patch surface.

## Rollback Procedure

1. No runtime rollback is required because this unit does not modify files during execution.
2. If the interpretation lock is found incorrect, leave this unit pending and revise the parent before running `024b`.

## Next todo

`/todo/pending/024b-agent-capability-governance.md`

## Completion

- [x] Pre-flight passed (all checklist items verified before execution began).
- [x] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [x] Post-flight: all Exit State claims are verifiable on the filesystem.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [x] `mv /todo/pending/024a-agent-capability-governance.md /todo/changelog/024a-agent-capability-governance.md` - verified.
- [x] Continue immediately to `next_todo`. No pause. No batch.
