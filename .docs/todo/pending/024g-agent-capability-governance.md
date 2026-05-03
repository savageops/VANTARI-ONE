---
id: 024g-agent-capability-governance
parent: 024-agent-capability-governance
type: verification-closeout
protocol_version: "2.1"
category: feature
phase: g
status: pending
patch_scope: "No artifact change. This unit validates, verifies invariants, and terminates the chain."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only. Re-execution from any point is safe."
acceptance: "All capability-governance units are archived with evidence, full Zig regression passes, reviewed tool calls and scoped delegation are durable, memory/evaluator boundaries preserve transcript ownership, docs match runtime truth, and no copied MAS architecture or hidden parallel runtime exists."
exit_criterion: "Full regression commands exit 0, all invariant assertions pass, source-message coverage is complete, and parent archival protocol can move `024-agent-capability-governance.md` to `/todo/changelog/`."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend\\variant-1; .\\scripts\\zigw.ps1 build test --summary all; Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; ix search \"lit:tool_reviewed || lit:scope_depth || lit:capability_profile || lit:source_seq_start || lit:heartbeat\" apps/backend/variant-1/src apps/backend/variant-1/tests .docs --json; git diff --check"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "PLACEHOLDER - replace with captured final validation output. Chain cannot terminate until this is populated."
conflict_surface: ""
invariants:
  - "I1: messages.jsonl remains the complete durable transcript."
  - "I2: context.jsonl remains checkpoint history only."
  - "I3: high-risk/write-capable/delegating tool calls have a review transition before side effects."
  - "I4: read-only tool behavior remains backward compatible."
  - "I5: tool capability truth remains module-owned."
  - "I6: scoped delegation carries explicit scope and budget evidence."
  - "I7: capability profiles are typed execution boundaries, not role taxonomy."
  - "I8: unsupported behavior is explicit."
  - "I9: evaluator/heartbeat behavior is durable evidence, not hidden mutation."
  - "I10: implementation is simpler and more capable than copied MAS architecture."
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"All right, I want you to proceed.\"; \"Use the planning spec skill to capture all the details.\"; \"You don't want to miss anything.\"; \"once done, commit with a description and a summary.\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"we don't want to copy.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Verify every source-message anchor is mapped to completed units, every proof obligation has evidence, and the committed chain materially improves VAR1 without copied architecture or regression."
entry_state: "All implementation units from `024a` through `024f` are archived. All exit states from `024b` through `024f` are provably true. System is in a state where full regression can run cleanly."
rollback_surface: "None. This unit introduces no artifact changes. If validation fails, block this unit and identify the responsible implementation unit; do not archive closeout."
dependencies: "024a-agent-capability-governance, 024b-agent-capability-governance, 024c-agent-capability-governance, 024d-agent-capability-governance, 024e-agent-capability-governance, 024f-agent-capability-governance"
next_todo: NONE
continuation: "On completion: record evidence, set status done, archive this unit, then execute Parent Archival Protocol. Chain is fully terminated when parent is in /todo/changelog/."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024g Verification, Regression, and Closeout

## Execute Now

Run the full regression suite, assert all chain invariants, verify all acceptance criteria, record aggregate evidence, archive this unit, and archive the parent.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Covered By Unit(s) | Evidence / Closeout Signal |
|---------------|---------------------------|--------------------|----------------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | 024a, 024b, 024c, 024d, 024e, 024f, 024g | Runtime tests and docs show the concrete VAR1 translation. |
| U2 | "All right, I want you to proceed." | 024a, 024g | Chain execution completed and parent archived. |
| U3 | "Use the planning spec skill to capture all the details." | 024a, 024f, 024g | Planning-spec fields and source coverage audit pass. |
| U4 | "You don't want to miss anything." | 024a, 024f, 024g | Source Message Coverage Audit passes for every anchor. |
| U5 | "once done, commit with a description and a summary." | 024g | Commit-ready evidence exists after closeout. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | 024b, 024c, 024d, 024e, 024f, 024g | Regression and event/profile/memory evidence pass. |
| U7 | "We don't want to change anything for the worse." | all units | Full regression passes and non-regression invariants pass. |
| U8 | "we don't want to copy." | 024a, 024d, 024e, 024f, 024g | Docs and source audit reject copied MAS architecture. |
| U9 | "do something far better, which is more simple, but more capable." | 024b, 024c, 024d, 024e, 024f, 024g | Capability primitives are present without parallel runtime. |

## Pre-flight Checklist

- [ ] Every execution unit from `024a` through `024f` is in `/todo/changelog/`.
- [ ] No unit in `/todo/changelog/` for this chain has `evidence: PLACEHOLDER`.
- [ ] No unit in `/todo/pending/` for this chain remains with `status: in-progress` or `status: blocked`.
- [ ] All exit state claims from all prior units are verifiable on the current filesystem.
- [ ] Every parent source-message anchor appears in at least one archived unit's `Original User Message Proof` section.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|-------------|-----------|----------------------|----------------|
| I1 | `messages.jsonl` remains the complete durable transcript. | `ix search "lit:messages.jsonl" AGENTS.md apps/backend/variant-1/src apps/backend/variant-1/architecture.md --json` | `messages.jsonl` ownership remains documented. |
| I2 | `context.jsonl` remains checkpoint history only. | `ix search "lit:context.jsonl || lit:source_seq_start" AGENTS.md apps/backend/variant-1/src apps/backend/variant-1/architecture.md --json` | Context and source sequence boundaries appear. |
| I3 | High-risk tool calls have review before side effects. | `ix search "lit:tool_reviewed || lit:ToolReviewDecision" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | Review event and decision type appear. |
| I4 | Read-only tools remain backward compatible. | `.\scripts\zigw.ps1 build test --summary all` | Tool regression tests pass. |
| I5 | Tool capability truth remains module-owned. | `ix search "lit:resolveAvailability || lit:availabilitySpec" apps/backend/variant-1/src/core/tools --json` | Registry ownership remains. |
| I6 | Scoped delegation carries scope and budget evidence. | `ix search "lit:scope_depth || lit:contact_budget" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | Scope fields appear. |
| I7 | Capability profiles are typed boundaries. | `ix search "lit:capability_profile || lit:agent_profile" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | Profile surface appears. |
| I8 | Unsupported behavior is explicit. | `ix search "lit:unsupported" apps/backend/variant-1/src apps/backend/variant-1/architecture.md .docs/research --json` | Unsupported diagnostics/docs appear. |
| I9 | Evaluator/heartbeat behavior is durable evidence. | `ix search "lit:heartbeat || lit:evaluator" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | Event contract appears. |
| I10 | No copied MAS architecture or parallel runtime exists. | `ix search "lit:Talent Market || lit:Bellman || lit:RecursiveLink || lit:company hierarchy" apps/backend/variant-1/src --json` | No copied architecture terms appear in runtime source. |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|------|---------------------|--------|
| 024a | Interpretation locks reject copied MAS architecture and preserve every source anchor. | [ ] PASS / [ ] FAIL |
| 024b | Review primitive classifies mutating/delegating/read-only tools deterministically. | [ ] PASS / [ ] FAIL |
| 024c | Executor records reviewed/blocked events before side effects and preserves approved execution. | [ ] PASS / [ ] FAIL |
| 024d | Scoped delegation and capability profiles fail unsupported capability requests before execution. | [ ] PASS / [ ] FAIL |
| 024e | Derivative memory, heartbeat, and evaluator contracts preserve transcript ownership. | [ ] PASS / [ ] FAIL |
| 024f | Docs describe shipped runtime truth and rejected MAS boundaries. | [ ] PASS / [ ] FAIL |

## Source Message Coverage Audit

| Source Anchor | Original Snippet Present In Parent | Covered By Unit | Evidence Present | Status |
|---------------|------------------------------------|-----------------|------------------|--------|
| U1 | [ ] YES / [ ] NO | 024a-024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U2 | [ ] YES / [ ] NO | 024a, 024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U3 | [ ] YES / [ ] NO | 024a, 024f, 024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U4 | [ ] YES / [ ] NO | 024a, 024f, 024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U5 | [ ] YES / [ ] NO | 024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U6 | [ ] YES / [ ] NO | 024b-024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U7 | [ ] YES / [ ] NO | all units | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U8 | [ ] YES / [ ] NO | 024a, 024d, 024e, 024f, 024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U9 | [ ] YES / [ ] NO | 024b-024g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Regression Surface

**Files in combined patch surface:**
- `apps/backend/variant-1/src/core/tools/review.zig` - added by `024b`.
- `apps/backend/variant-1/src/core/tools/module.zig` - possibly touched by `024b`.
- `apps/backend/variant-1/src/core/tools/runtime.zig` - touched by `024b`.
- `apps/backend/variant-1/src/core/executor/loop.zig` - touched by `024c`.
- `apps/backend/variant-1/src/core/agents/profile.zig` - added by `024d`.
- `apps/backend/variant-1/src/core/agents/scope.zig` - possibly added by `024d`.
- `apps/backend/variant-1/src/core/agents/service.zig` - touched by `024d`.
- `apps/backend/variant-1/src/core/tools/builtin/agents.zig` - touched by `024d`.
- `apps/backend/variant-1/src/core/plugins/manifest.zig` - possibly touched by `024d`.
- `apps/backend/variant-1/src/core/memory/**` - possibly added by `024e`.
- `apps/backend/variant-1/src/core/evaluation/**` - possibly added by `024e`.
- `apps/backend/variant-1/src/core/sessions/store.zig` - possibly touched by `024e`.
- `apps/backend/variant-1/src/shared/types.zig` - possibly touched by `024b`, `024d`, and `024e`.
- `apps/backend/variant-1/tests/**` - touched by `024b` through `024e`.
- `README.md`, `apps/backend/variant-1/README.md`, `apps/backend/variant-1/architecture.md` - touched by `024f`.
- `.docs/research/2026-05-04-multi-agent-systems-9-methods.md` - touched by `024f`.
- `.docs/todo/changelog/_log.md` - touched by `024f`.

## Full Regression Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern |
|------|---------|-------------------|-------------------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:tool_reviewed || lit:scope_depth || lit:capability_profile || lit:source_seq_start || lit:heartbeat" apps/backend/variant-1/src apps/backend/variant-1/tests .docs --json` | `0` | `tool_reviewed` |
| 3 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:Talent Market || lit:Bellman || lit:RecursiveLink || lit:company hierarchy" apps/backend/variant-1/src --json` | `0` | `"matches_found":0` |
| 4 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; git diff --check` | `0` | `` |

**Evidence to capture:** Full stdout from all validation commands. This is the aggregate chain evidence.

## Regression Triage (if failures occur)

1. Identify which test, search assertion, or whitespace check failed.
2. Trace the failure to the responsible unit by regression surface.
3. Determine whether the issue is a regression against parent invariants or incomplete implementation of a unit acceptance criterion.
4. For regressions, block this verification unit and create a bug-category chain naming the responsible implementation unit.
5. For incomplete implementation, block this verification unit with the exact acceptance criterion and failing command.

## Chain Audit

- [ ] Chain manifest in parent is complete: every planned letter has a file in `/todo/changelog/`.
- [ ] Parent's Phase Plan table: all letters marked `archived`.
- [ ] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [ ] Source Message Coverage Audit shows PASS for every original user-message anchor.
- [ ] All invariants in Invariant Assertion Surface table show PASS.
- [ ] All acceptance criteria in Acceptance Criteria Matrix show PASS.

## Next todo

`NONE`

## Completion

- [ ] All pre-flight checks passed.
- [ ] Full regression suite executed. All commands exit 0. All output patterns matched.
- [ ] All invariants asserted: PASS.
- [ ] All acceptance criteria resolved: PASS.
- [ ] Chain audit complete: all rows verified.
- [ ] Evidence captured. `evidence` field populated with full regression stdout. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/024g-agent-capability-governance.md /todo/changelog/024g-agent-capability-governance.md` - verified.
- [ ] Parent Archival Protocol: update parent status to `done`, update chain manifest, `mv /todo/pending/024-agent-capability-governance.md /todo/changelog/024-agent-capability-governance.md` - verified.
- [ ] Chain is complete. `/todo/pending/` contains zero files for this chain.
