---
id: 024e-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: e
status: done
patch_scope: "Transcript-safe derivative memory boundary plus heartbeat/evaluator event contracts."
blast_radius: high
blast_radius_justification: "Memory and evaluator contracts can corrupt context ownership or session truth if implemented as hidden stores or side channels."
idempotency_contract: idempotent
idempotency_notes: "The patch adds deterministic boundary modules, event contracts, and tests. Reapplying source changes is safe."
acceptance: "Derivative memory entries can only cite source session/sequence ranges, heartbeat and evaluator events are durable and redacted, and unsupported autonomous/background behavior is explicitly rejected by contract."
exit_criterion: "Zig tests prove memory entries reject transcript duplication, heartbeat/evaluator events persist, and unsupported background evolution returns explicit diagnostics."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend\\variant-1; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "2026-05-04: `Set-Location apps/backend/variant-1; .\\scripts\\zigw.ps1 build test --summary all` exited 0 with `Build Summary: 5/5 steps succeeded; 95/95 tests passed`. `ix search \"lit:source_seq_start || lit:heartbeat || lit:evaluator\" apps/backend/variant-1/src apps/backend/variant-1/tests --json` exited 0 and found sequence-bound derivative memory, runtime heartbeat events, evaluator result events, unsupported-behavior events, and focused tests."
conflict_surface: ""
invariants:
  - "I1: messages.jsonl remains the complete durable transcript."
  - "I2: context.jsonl remains model-visible checkpoint history only."
  - "I8: unsupported runtime behavior fails by contract or reports explicit diagnostics."
  - "I9: long-running/evaluator behavior emits durable redacted session events and does not mutate executor state through a side channel."
source_message_anchor: "U1, U6, U7, U8, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"we don't want to copy.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Translate LLMA-Mem and CORAL into transcript-safe memory and health/evaluator boundaries without introducing background evolution or a second transcript."
entry_state: "`024d-agent-capability-governance` is archived with evidence. Scoped delegation and capability profiles exist, so memory/evaluator boundaries can attach to explicit session/capability contexts."
rollback_surface: "Revert new `src/core/memory/` files or checkpoint metadata changes, evaluator/heartbeat event additions, and focused tests introduced by this unit."
dependencies: "024d-agent-capability-governance"
next_todo: /todo/pending/024f-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024e-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024e Transcript-Safe Memory and Evaluator Health Boundaries

## Execute Now

Add derivative memory and heartbeat/evaluator contracts that preserve transcript ownership and expose unsupported autonomous behavior as explicit diagnostics.

## Why This Execution Unit Exists

Memory and evaluator behavior are the easiest place to accidentally add a parallel runtime. This unit isolates those surfaces after review and scoped delegation exist, so memory can cite session truth and evaluator output can remain evidence instead of hidden executor mutation.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Translate memory/evolution methods into safer VAR1 boundaries. | Tests prove transcript-safe memory and heartbeat/evaluator events. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Add long-horizon capability without duplicate transcript ownership. | Memory tests reject full transcript duplication. |
| U7 | "We don't want to change anything for the worse." | Preserve `messages.jsonl` and context builder ownership. | Full regression passes. |
| U8 | "we don't want to copy." | Reject CORAL autonomous evolution and LLMA-Mem topology cloning. | Unsupported behavior diagnostics are tested. |
| U9 | "do something far better, which is more simple, but more capable." | Use source references and events, not hidden workers. | Patch surface remains contract modules and tests. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `024d-agent-capability-governance` is archived with scoped delegation/capability profile evidence.
- `apps/backend/variant-1/src/core/context/builder.zig` remains the only owner converting session storage into provider messages.
- `apps/backend/variant-1/src/core/context/compactor.zig` advances checkpoints by stable JSONL entries.
- `apps/backend/variant-1/src/core/sessions/store.zig` appends session events to `events.jsonl`.

## Patch Surface

**Modifies:**
- `apps/backend/variant-1/src/core/sessions/store.zig` - add typed append/read helpers only if generic event helpers are insufficient.
- `apps/backend/variant-1/tests/**` - add focused memory-boundary and heartbeat/evaluator tests.

**Adds:**
- `apps/backend/variant-1/src/core/memory/` - canonical derivative memory boundary if implemented as a module.
- `apps/backend/variant-1/src/core/evaluation/` - evaluator event boundary if a distinct owner is needed.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/variant-1/src/core/context/builder.zig` except for test-only consumer integration explicitly required by memory summaries.
- `messages.jsonl` write semantics.
- Background workers, schedulers, dynamic evolution loops, or autonomous evaluator mutation paths.

## Detailed Requirements

- R1: Define derivative memory entries with `session_id`, `source_seq_start`, `source_seq_end`, `entry_type`, `summary`, `created_at_ms`, and invalidation metadata if needed.
- R2: Reject or fail tests for derivative memory entries that contain raw full transcript replay without source sequence ranges.
- R3: Keep `messages.jsonl` the only full transcript owner.
- R4: Keep `context.jsonl` as model-visible checkpoint history; do not overload it as a general memory database unless the entry remains checkpoint-shaped and sequence-bound.
- R5: Define heartbeat event labels for long-running work with redacted status payloads.
- R6: Define evaluator event labels that record evaluator result/evidence without directly mutating executor state.
- R7: Return explicit unsupported diagnostics for autonomous background evolution, exact tokenizer integration, or model-internal latent transfer if requested before prerequisites exist.

## Invariants This Unit Must Preserve

- I1: Full transcript ownership remains in `messages.jsonl`.
- I2: `context.jsonl` remains checkpoint history only.
- I8: Unsupported behavior fails by contract.
- I9: Evaluator behavior is durable evidence, not hidden mutation.
- I10: The implementation remains simple and capability-increasing.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:source_seq_start || lit:heartbeat || lit:evaluator" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | `0` | `source_seq_start` | yes |

**Evidence to capture:** Zig test stdout plus search output proving sequence-bound memory and heartbeat/evaluator terms.

## Exit State (Handoff Contract)

- Derivative memory cannot duplicate full transcript and must cite source sequence ranges.
- Heartbeat/evaluator events are durable session evidence.
- Unsupported autonomous/background behavior has explicit diagnostics.
- `024f` can document shipped runtime truth and rejected research boundaries.

## Rollback Procedure

1. Revert added `apps/backend/variant-1/src/core/memory/` and `src/core/evaluation/` files if present.
2. Revert session-store changes introduced by this unit, if any.
3. Revert focused tests introduced by this unit.
4. Run full Zig regression.

## Next todo

`/todo/pending/024f-agent-capability-governance.md`

## Completion

- [x] Pre-flight passed (all checklist items verified before execution began).
- [x] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [x] Post-flight: all Exit State claims are verifiable on the filesystem.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [ ] `mv /todo/pending/024e-agent-capability-governance.md /todo/changelog/024e-agent-capability-governance.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
