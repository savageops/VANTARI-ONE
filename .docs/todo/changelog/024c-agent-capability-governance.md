---
id: 024c-agent-capability-governance
parent: 024-agent-capability-governance
type: execution-unit
protocol_version: "2.1"
category: feature
phase: c
status: done
patch_scope: "Executor loop integration for pre-tool review and durable review/block events."
blast_radius: high
blast_radius_justification: "The executor loop controls model/tool turns, session status, tool budgets, session messages, and durable events. Failure can regress every tool-mediated session."
idempotency_contract: idempotent
idempotency_notes: "The patch is deterministic source and tests. Reapplying the same loop integration yields the same executable state."
acceptance: "The executor records `tool_reviewed` before every reviewed high-risk tool, blocks denied calls without invoking the tool implementation, preserves approved tool execution, and keeps session messages coherent."
exit_criterion: "Zig tests prove approved mutating tool execution, blocked mutating tool denial, and event order `tool_requested -> tool_reviewed -> tool_completed/tool_blocked`."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend\\variant-1; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "2026-05-04 024c validation passed. Command: Set-Location apps/backend/variant-1; .\\scripts\\zigw.ps1 build test --summary all -> exit 0, stdout: Build Summary: 5/5 steps succeeded; 92/92 tests passed; test success. Command: ix search \"lit:tool_reviewed || lit:tool_blocked\" apps/backend/variant-1/src apps/backend/variant-1/tests --json -> exit 0, found executor event recording at loop.zig lines 268 and 287, review policy labels at review.zig lines 28/37/46/54, and runtime-loop event-order assertions at tests/runtime_loop_test.zig lines 739-742 and 788-792."
conflict_surface: ""
invariants:
  - "I1: messages.jsonl remains the complete durable transcript."
  - "I3: high-risk/write-capable/delegating tool calls must be reviewed before side effects."
  - "I4: read-only tool behavior remains backward compatible."
  - "I8: unsupported runtime behavior fails by contract."
source_message_anchor: "U1, U6, U7, U9"
source_message_excerpt: "\"Could you show me how that translates to Ventori and how that improves the current code base and makes it better?\"; \"materially improve the architecture and the Kcapability of the code base.\"; \"We don't want to change anything for the worse.\"; \"do something far better, which is more simple, but more capable.\""
source_message_proof_obligation: "Wire the review primitive into the live executor without regressing existing tool-loop semantics."
entry_state: "`024b-agent-capability-governance` is archived with evidence. The review primitive exports deterministic approval/block decisions and tests prove its standalone behavior."
rollback_surface: "Revert `apps/backend/variant-1/src/core/executor/loop.zig`, executor-loop tests, and any event-label helper changes introduced by this unit; retain `024b` review primitives unless tests prove the primitive itself is faulty."
dependencies: "024b-agent-capability-governance"
next_todo: /todo/pending/024d-agent-capability-governance.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/024c-agent-capability-governance.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 024c Executor Loop Review Integration

## Execute Now

Wire the pre-tool review primitive into the executor loop so high-risk tool calls are reviewed and durably recorded before execution.

## Why This Execution Unit Exists

This unit touches the central runtime loop and must be separate from review policy definition. The split keeps semantics testable before the executor depends on them, and it gives rollback a precise boundary if loop integration regresses session events or tool message ordering.

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---------------|---------------------------|------------------------|------------------|
| U1 | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | Translate review research into the live code path. | Executor tests assert event order and side-effect blocking. |
| U6 | "materially improve the architecture and the Kcapability of the code base." | Add a missing state transition to the core loop. | Tests prove `tool_reviewed` exists before execution. |
| U7 | "We don't want to change anything for the worse." | Preserve existing approved tool behavior and transcript coherence. | Full Zig regression passes. |
| U9 | "do something far better, which is more simple, but more capable." | Insert one deterministic review phase instead of a parallel agent runtime. | Patch surface remains in `loop.zig` plus tests. |

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent source-message capture.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `024b-agent-capability-governance` is archived with review primitive evidence.
- `apps/backend/variant-1/src/core/executor/loop.zig` still records `tool_requested` before tool execution.
- `store.appendEvent()` writes append-only session events to `.var/sessions/<session-id>/events.jsonl`.

## Patch Surface

**Modifies:**
- `apps/backend/variant-1/src/core/executor/loop.zig` - call review primitive between assistant tool-call append and `executeToolCall()`.
- `apps/backend/variant-1/tests/**` - add executor/event-order tests for reviewed, approved, and blocked tool calls.

**Adds:**
- None unless a focused test fixture file is needed under `apps/backend/variant-1/tests/`.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/variant-1/src/core/tools/review.zig` - review policy semantics are owned by `024b`.
- `apps/backend/variant-1/src/core/agents/service.zig` - scoped delegation is `024d`.
- Provider auth, bridge transport, and prompt envelope files.

## Detailed Requirements

- R1: Place review after assistant tool-call message persistence and before `executeToolCall()`.
- R2: Record `tool_reviewed` with tool name, risk class, approved/blocked status, and redacted reason.
- R3: If review blocks a call, do not invoke the underlying tool implementation.
- R4: Append a tool-result message for blocked calls only if the existing provider protocol requires a tool response for the proposed tool call; the content must be an explicit denial with `ok:false` semantics if the current envelope supports it.
- R5: Preserve existing cancellation checks before each tool call.
- R6: Preserve existing tool budget accounting unless review policy explicitly blocks before execution; blocked calls still count as model-requested tool calls.
- R7: Preserve `requires_child_supervision` semantics for approved child-launch calls.
- R8: Tests must assert event order, not only final output.

## Invariants This Unit Must Preserve

- I1: `messages.jsonl` remains complete durable transcript.
- I3: High-risk tool calls are reviewed before side effects.
- I4: Read-only tool behavior remains backward compatible.
- I8: Unsupported behavior fails by contract.
- I9: Evaluator/review evidence does not mutate executor state through a side channel.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|-------------------------|------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix search "lit:tool_reviewed || lit:tool_blocked" apps/backend/variant-1/src apps/backend/variant-1/tests --json` | `0` | `tool_reviewed` | yes |

**Evidence to capture:** Full Zig test stdout and search output proving event labels are implemented and tested.

## Exit State (Handoff Contract)

- The executor loop reviews high-risk tool calls before side effects.
- Event order and blocked-call behavior are covered by tests.
- `024d` can build scoped delegation policy on top of reviewed delegating tool calls.

## Rollback Procedure

1. Revert `apps/backend/variant-1/src/core/executor/loop.zig` changes from this unit.
2. Revert executor-loop tests added by this unit.
3. Run `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all`.
4. If tests still fail, block this unit and inspect whether `024b` review primitives need a follow-up bug chain.

## Next todo

`/todo/pending/024d-agent-capability-governance.md`

## Completion

- [x] Pre-flight passed (all checklist items verified before execution began).
- [x] All validation commands executed. Exit codes match `expected_exit_code`. Output matches `expected_output_pattern`.
- [x] Post-flight: all Exit State claims are verifiable on the filesystem.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [x] `mv /todo/pending/024c-agent-capability-governance.md /todo/changelog/024c-agent-capability-governance.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
