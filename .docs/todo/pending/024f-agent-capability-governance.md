---
id: 024f-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: f
status: pending
patch_scope: "Architecture documentation, research mapping, and operator handoff for shipped capability governance."
blast_radius: medium
blast_radius_justification: "Docs and changelog are operator-facing and can misrepresent runtime truth if incorrect, but this unit does not change executable code."
idempotency_contract: idempotent
idempotency_notes: "Documentation edits are deterministic and can be reapplied from source control."
acceptance: "Operator documentation describes the shipped capability-governance runtime truth, cites the MAS research mapping, and explicitly rejects unsupported copied/autonomous behavior."
exit_criterion: "ix search finds review, scoped delegation, capability profile, derivative memory, heartbeat/evaluator, and unsupported-boundary descriptions in docs."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; ix search \"lit:tool_reviewed || lit:scoped delegation || lit:capability profile || lit:derivative memory || lit:unsupported\" README.md apps/backend/variant-1/README.md apps/backend/variant-1/architecture.md .docs/research .docs/todo/changelog/_log.md --json"
expected_exit_code: 0
expected_output_pattern: "tool_reviewed"
evidence: "PLACEHOLDER - replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: "021-codex-subscription-auth"
invariants:
  - "I7: capability profiles are typed execution boundaries, not product UI role taxonomy."
  - "I8: unsupported runtime behavior fails by contract or reports explicit diagnostics."
  - "I10: final implementation must improve capability with fewer and stronger primitives."
source_message_anchor: "U1, U3, U4, U6, U7, U8, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"Use the planning spec skill to capture all the details.\"; \"You don't want to miss anything.\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"we don't want to copy.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Document the shipped architecture truth and research translation so future operators cannot mistake the implementation for copied MAS architecture."
entry_state: "`024e-agent-capability-governance` is archived with evidence. Runtime review, scope, capability, memory, heartbeat, and evaluator contracts exist and are covered by tests."
rollback_surface: "Revert documentation, research crosswalk, and changelog edits introduced by this unit; do not revert runtime files from prior units unless terminal verification identifies a code regression."
dependencies: "024e-agent-capability-governance, 021f-codex-subscription-auth"
next_todo: /todo/pending/024g-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024f-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024f Docs, Research Mapping, and Operator Handoff

## Execute Now

Update operator documentation and research mapping so the shipped capability-governance runtime truth is explicit and unsupported behavior is contractually bounded.

## Why This Execution Unit Exists

Runtime capability governance changes affect how operators reason about tool effects, delegation, memory, and long-running evaluation. Documentation must be downstream of the code units so it describes what exists, not what was intended.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Preserve the translation in durable docs. | `ix search` finds docs terms. |
| U3 | "Use the planning spec skill to capture all the details." | Preserve planning-detail handoff in docs/changelog. | Changelog references implemented chain. |
| U4 | "You don't want to miss anything." | Document all shipped surfaces and rejected boundaries. | Research crosswalk covers all nine methods. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Explain the codebase improvement as current runtime truth. | README/architecture docs state capability governance. |
| U7 | "We don't want to change anything for the worse." | Document non-regression and fallback boundaries. | Docs state no hidden fallback or second transcript. |
| U8 | "we don't want to copy." | Document that research was used as input signals only. | Research crosswalk rejects copied MAS structures. |
| U9 | "do something far better, which is more simple, but more capable." | Explain the smaller primitive architecture. | Docs list primitives and owning modules. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- Runtime implementation units `024b` through `024e` are archived with evidence.
- The research artifact `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` exists and contains source links for all nine MAS methods.
- README and architecture docs currently describe the pre-existing VAR1 runtime and must be updated only to shipped behavior.

## Patch Surface

**Modifies:**
- `README.md` - root runtime summary if it describes agent/session capability surface.
- `apps/backend/variant-1/README.md` - operator-facing capability governance behavior.
- `apps/backend/variant-1/architecture.md` - module ownership, event sequence, scope/memory/evaluator boundaries.
- `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` - update adopt/adapt/reject matrix to shipped implementation evidence.
- `.docs/todo/changelog/_log.md` - append implementation completion entry.

**Adds:**
- Optional `.docs/handoff/2026-05-04-agent-capability-governance.md` if a cold-start handoff dump is necessary.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- Runtime Zig source.
- Tests.
- `.var/sessions/**` live runtime state.
- The raw Insect capture directory unless explicitly pruning ignored temporary files.

## Detailed Requirements

- R1: Document exact event order for reviewed tool calls.
- R2: Document scoped delegation fields and their validation purpose.
- R3: Document capability profiles as typed runtime boundaries, not product roles.
- R4: Document derivative memory as source-sequence-referenced data, not transcript storage.
- R5: Document heartbeat/evaluator events and their non-mutating relationship to executor state.
- R6: Document unsupported boundaries for RecursiveMAS latent transfer, GRASP gradients, dynamic markets, background evolution, exact tokenizer work, and plugin auto-discovery.
- R7: Append changelog with validation evidence only after runtime tests pass in prior units.

## Invariants This Unit Must Preserve

- I7: Capability profiles are not copied role taxonomy.
- I8: Unsupported behavior is explicit.
- I10: Simpler, stronger primitives are documented as current truth.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:tool_reviewed || lit:scoped delegation || lit:capability profile || lit:derivative memory || lit:unsupported" README.md apps/backend/variant-1/README.md apps/backend/variant-1/architecture.md .docs/research .docs/todo/changelog/_log.md --json` | `0` | `tool_reviewed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; git diff --check -- README.md apps/backend/variant-1/README.md apps/backend/variant-1/architecture.md .docs/research/2026-05-04-multi-agent-systems-9-methods.md .docs/todo/changelog/_log.md` | `0` | `` | yes |

**Evidence to capture:** Search output for docs coverage and `git diff --check` output.

## Exit State (Handoff Contract)

- Docs describe shipped capability governance, not planned future behavior.
- Research artifact maps every MAS method to adopt/adapt/reject state after implementation.
- Changelog contains a validation-backed entry.
- `024g` can run terminal regression and source-message coverage audit.

## Rollback Procedure

1. Revert documentation files touched by this unit.
2. Revert `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` edits from this unit only.
3. Revert `.docs/todo/changelog/_log.md` entry from this unit.
4. Run `git diff --check` on the same file set.

## Next todo

`/todo/pending/024g-agent-capability-governance.md`

## Completion

- [ ] Pre-flight passed (all checklist items verified before execution began).
- [ ] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [ ] Post-flight: all Exit State claims are verifiable on the filesystem.
- [ ] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/024f-agent-capability-governance.md /todo/changelog/024f-agent-capability-governance.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
