---
id: 024d-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: d
status: done
patch_scope: "Scoped delegation and typed capability profile contracts for agent sessions."
blast_radius: high
blast_radius_justification: "Agent delegation can spawn child sessions and affect tool availability, session lineage, and future provider policy. Failure can create uncontrolled delegation or incorrect capability exposure."
idempotency_contract: idempotent
idempotency_notes: "The patch adds deterministic profile/scope types, service wiring, schemas, and tests. Reapplying source changes is safe."
acceptance: "Delegated agent launches carry explicit scope, contact budget, validation state, and escalation reason, and agent profiles resolve typed capability constraints instead of string-only role labels."
exit_criterion: "Zig tests prove scoped delegation fields persist and unsupported capability profiles fail before child execution begins."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend\\variant-1; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "2026-05-04: `Set-Location apps/backend/variant-1; .\\scripts\\zigw.ps1 build test --summary all` exited 0 with `Build Summary: 5/5 steps succeeded; 93/93 tests passed`. `ix search \"lit:scope_depth || lit:contact_budget || lit:capability_profile\" apps/backend/variant-1/src apps/backend/variant-1/tests --json` exited 0 and found profile/scope contracts in `src/core/agents/profile.zig`, `src/core/agents/scope.zig`, launch schema/runtime diagnostics, and focused tests."
conflict_surface: ""
invariants:
  - "I5: tool capability truth remains module-owned through registry/tool definitions."
  - "I6: scoped delegation carries explicit scope, contact budget, validation state, and escalation reason."
  - "I7: capability profiles are typed execution boundaries, not product UI role taxonomy."
  - "I8: unsupported runtime behavior fails by contract or reports explicit diagnostics."
source_message_anchor: "U1, U6, U7, U8, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"we don't want to copy.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Translate CASCADE, OMC, and OrgAgent into bounded VAR1 delegation/profile contracts without copying company hierarchy or marketplace machinery."
entry_state: "`024c-agent-capability-governance` is archived with evidence. Reviewed delegating tool calls are now explicit in the executor loop. Profile and scope contracts remain kernel-local under `core/agents`; no `src/shared/types.zig` change is required."
rollback_surface: "Revert `src/core/agents/profile.zig`, scoped delegation changes in `src/core/agents/service.zig`, agent builtin schema changes, plugin manifest validation changes, and focused tests."
dependencies: "024c-agent-capability-governance"
next_todo: /todo/pending/024e-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024d-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024d Scoped Delegation and Capability Profiles

## Execute Now

Add scoped delegation and typed capability profile contracts so child-agent work expands only through explicit budgeted capability boundaries.

## Why This Execution Unit Exists

Review-before-effect governs whether a delegated call may execute; it does not define the shape of delegated authority. This unit adds the CASCADE-style scope contract and OMC/OrgAgent-style capability profile as VAR1-native data, keeping delegation small, auditable, and capability-bound.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Translate scoped MAS ideas into live delegation surfaces. | Tests prove scope fields persist and capability failures occur early. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Improve delegation capability without unbounded agent fanout. | Scoped delegation tests pass. |
| U7 | "We don't want to change anything for the worse." | Preserve current child-session launch semantics while adding explicit scope. | Regression suite passes. |
| U8 | "we don't want to copy." | Avoid company hierarchy, Talent Market, and OrgAgent role taxonomy. | Patch adds typed profile data, not external ontology. |
| U9 | "do something far better, which is more simple, but more capable." | Replace string-only `agent_profile` with minimal typed capability data. | Profile tests prove smaller contract. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `024c-agent-capability-governance` is archived with evidence and delegating tool calls are reviewable.
- `apps/backend/variant-1/src/core/agents/service.zig` currently sets `.agent_profile = "subagent"` for child sessions.
- `apps/backend/variant-1/src/core/plugins/manifest.zig` validates socket declarations and can be extended only if capability profile data needs plugin-facing validation.

## Patch Surface

**Modifies:**
- `apps/backend/variant-1/src/core/agents/service.zig` - persist scoped delegation metadata and validate child launch scope.
- `apps/backend/variant-1/src/core/tools/builtin/agents.zig` - extend tool schema/hints for scope, budget, validation state, and escalation reason if this is the current launch tool owner.
- `apps/backend/variant-1/src/core/plugins/manifest.zig` - validate profile-related socket/capability declarations only if plugin manifests expose them.
- `apps/backend/variant-1/tests/**` - add focused scoped-delegation and capability-profile tests.

**Adds:**
- `apps/backend/variant-1/src/core/agents/profile.zig` - canonical owner for typed capability profiles.
- `apps/backend/variant-1/src/core/agents/scope.zig` - canonical owner for scoped delegation contracts if not merged into profile owner.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- Provider auth and transport surfaces.
- Context compaction behavior.
- UI/product role labels.
- Dynamic plugin discovery or marketplace loading.

## Detailed Requirements

- R1: Define a capability profile with profile id, allowed tool classes, provider policy, budget policy, delegation policy, and unsupported-capability diagnostics.
- R2: Keep existing `agent_profile = "subagent"` readable as a default profile or migration-free compatibility value.
- R3: Define scoped delegation fields: `scope_depth`, `contact_budget`, `validation_status`, `escalation_reason`, and optional `parent_capability_profile`.
- R4: Reject child launch requests that request unsupported scope expansion without an explicit reason.
- R5: Emit durable session events for delegated scope decisions.
- R6: Do not implement dynamic Talent Market, auto-discovery, company departments, or copied OrgAgent layers.
- R7: Tests must prove invalid profile/capability combinations fail before child session execution begins.

## Invariants This Unit Must Preserve

- I5: Tool capability truth remains module-owned.
- I6: Scoped delegation is explicit and budgeted.
- I7: Capability profiles are typed execution boundaries, not copied role taxonomy.
- I8: Unsupported runtime behavior fails by contract.
- I10: Capability improves through smaller primitives.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:scope_depth || lit:contact_budget || lit:capability_profile" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | `0` | `capability_profile` | yes |

**Evidence to capture:** Test stdout and search output for scope/profile fields.

## Exit State (Handoff Contract)

- Child delegation has explicit scope and budget data.
- Capability profile resolution fails unsupported capabilities before execution.
- No copied company hierarchy, Talent Market, or dynamic discovery exists.
- `024e` can layer transcript-safe memory and evaluator health on top of explicit capability boundaries.

## Rollback Procedure

1. Revert `apps/backend/variant-1/src/core/agents/profile.zig` and `scope.zig` if added.
2. Revert scoped delegation changes in `apps/backend/variant-1/src/core/agents/service.zig`.
3. Revert agent tool schema changes and plugin manifest changes introduced by this unit.
4. Revert focused tests added by this unit.
5. Run full Zig regression.

## Next todo

`/todo/pending/024e-agent-capability-governance.md`

## Completion

- [x] Pre-flight passed (all checklist items verified before execution began).
- [x] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [x] Post-flight: all Exit State claims are verifiable on the filesystem.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [ ] `mv /todo/pending/024d-agent-capability-governance.md /todo/changelog/024d-agent-capability-governance.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
