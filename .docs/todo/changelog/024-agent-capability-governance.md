---
id: 024-agent-capability-governance
type: parent
protocol_version: "2.1"
spec_status: approved
category: feature
status: done
epic_boundary: "Add a VAR1-native agent capability governance layer that upgrades tool review, scoped delegation, capability profiles, transcript-safe memory boundaries, and runtime health evidence without copying external MAS architectures or creating parallel runtime state."
subtodo_start: /todo/pending/024a-agent-capability-governance.md
subtodo_final: /todo/pending/024g-agent-capability-governance.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---
# 024 Agent Capability Governance

## Objective

Introduce a compact VAR1-native capability governance layer that improves agentic execution by making high-risk tool calls reviewable before side effects, making delegation scope explicit, turning `agent_profile` into a typed capability boundary, and recording long-running runtime/evaluator health as durable session evidence. The deliverable translates the MAS research into smaller kernel primitives already aligned with `.var/sessions`, tool registry availability, session events, and plugin sockets.

This chain is not an implementation of RecursiveMAS, OMC, OrgAgent, CORAL, LLMA-Mem, Agentic FL, CASCADE, GRASP, or Reinforced Agent. It is a VANTARI-specific architecture upgrade that uses those systems as failure-mode and boundary-shape references, then implements the smallest more-capable primitive set in the current VAR1 codebase.

## Rationale

The current executor loop records `tool_requested`, appends the assistant tool-call message, then calls `executeToolCall()` directly. That path is functional but missing an explicit `proposed -> reviewed -> executed/blocked` transition for mutating tools, delegated agent launches, and future bridge-visible capabilities.

The research harvest shows that the durable improvements are not larger agent hierarchies; they are explicit state machines, scoped communication, persistent evidence, capability profiles, and review-before-effect. VAR1 already has the substrate: `.var/sessions/<id>/events.jsonl`, append-only `messages.jsonl`, module-owned tool registry availability, plugin socket validation, and the `agent_profile` session field.

## Scope

**In scope:**
- Add a deterministic pre-tool review contract for high-risk/write-capable/delegating tool calls before side effects execute.
- Preserve current tool behavior for safe read-only tools except for explicit review metadata when policy marks review as required.
- Add durable `tool_reviewed`, `tool_blocked`, scoped delegation, heartbeat, and evaluator-separation event contracts.
- Extend agent capability ownership around `agent_profile` into typed capability profile data with tool, policy, provider, budget, and scope fields.
- Add transcript-safe derivative memory boundaries that cite source session and sequence ranges and cannot become a second full transcript.
- Update docs and validation surfaces so the final codebase explains current runtime truth.

**Out of scope:**
- Implementing model-internal latent transfer from RecursiveMAS.
- Implementing GRASP training gradients, RL policy updates, Bellman-equilibrium machinery, or consensus-gradient training.
- Adding autonomous background evolution, marketplace loading, plugin auto-discovery, or dynamic workers before cancellation, idempotency, and cold-start recovery are proven.
- Adding a second transcript store, global session root, hidden prompt scaffolding, or fallback storage reader.
- Copying any external paper architecture, role taxonomy, or product ontology into VAR1.

## Source Language Anchors

- "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?"
- "All right, I want you to proceed."
- "Use the planning spec skill to capture all the details."
- "You don't want to miss anything."
- "once done, commit with a description and a summary."
- "materially improve the architecture and the Kcapability of the code base."
- "We don't want to change anything for the worse."
- "we don't want to copy."
- "use as an idea, and do something far better, which is more simple, but more capable."

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|-----------|-------------------|---------------------------|-------------------|
| U1 | translation objective | "Could you show me how that translates to Ventori and how that improves the current code base and makes it better?" | 024a, 024b, 024c, 024d, 024e, 024f, 024g |
| U2 | execution approval | "All right, I want you to proceed." | 024a, 024g |
| U3 | planning-spec requirement | "Use the planning spec skill to capture all the details." | 024a, 024g |
| U4 | completeness requirement | "You don't want to miss anything." | 024a, 024g |
| U5 | commit requirement | "once done, commit with a description and a summary." | 024g |
| U6 | architecture/capability improvement | "materially improve the architecture and the Kcapability of the code base." | 024b, 024c, 024d, 024e, 024f, 024g |
| U7 | non-regression requirement | "We don't want to change anything for the worse." | 024a, 024b, 024c, 024d, 024e, 024f, 024g |
| U8 | anti-copy requirement | "we don't want to copy." | 024a, 024d, 024e, 024f, 024g |
| U9 | simplicity/capability requirement | "do something far better, which is more simple, but more capable." | 024b, 024c, 024d, 024e, 024f, 024g |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|------|------------------|------------------------|
| 024a | U1, U2, U3, U4, U6, U7, U8, U9 | Freeze the interpretation: VAR1 improves through smaller capability primitives, not copied MAS systems. |
| 024b | U1, U6, U7, U9 | Introduce the review contract as a typed kernel primitive with deterministic pass/fail behavior. |
| 024c | U1, U6, U7, U9 | Wire review into the executor loop without regressing existing tool execution or session evidence. |
| 024d | U1, U6, U7, U8, U9 | Add scoped delegation and capability profiles as bounded agent contracts, not a company hierarchy copy. |
| 024e | U1, U6, U7, U8, U9 | Add transcript-safe memory and evaluator/heartbeat boundaries with unsupported behavior declared explicitly. |
| 024f | U1, U3, U4, U6, U7, U8, U9 | Update architecture docs, research mapping, and operator handoff to current runtime truth. |
| 024g | U1, U2, U3, U4, U5, U6, U7, U8, U9 | Verify source coverage, tests, non-regression, no-copy boundaries, and commit-ready evidence. |

## Constraints

| Dimension | Constraint |
|-----------|------------|
| Category boundary | Only `feature` operations that add VAR1 capability governance. Cosmetic refactors, research-only prose, and unrelated auth work are out of scope. |
| Blast radius ceiling | high - executor loop, tool contracts, session events, agent delegation, and shared protocol surfaces are foundational. |
| Structural boundary | `apps/backend/variant-1` remains the only live code lane; `.var/sessions` remains the canonical runtime state root. |
| Dependency boundary | The live `021-codex-subscription-auth` chain may touch `apps/backend/variant-1/src/shared/types.zig`, tests, docs, and `_log.md`; implementation units that overlap MUST depend on `021f-codex-subscription-auth` being archived with evidence. |
| Rollback surface | Revert new review, scoped delegation, capability profile, memory-boundary, heartbeat/evaluator, test, and docs surfaces as one feature chain if terminal verification fails. |
| Parallelism | No implementation units run in parallel. The review contract gates loop integration; loop integration gates scoped delegation; capability/memory/evaluator boundaries gate docs and closeout. |

## Invariants

- I1: `.var/sessions/<session-id>/messages.jsonl` remains the complete durable transcript; no new memory or review artifact may become a second transcript.
- I2: `context.jsonl` remains model-visible checkpoint history only; derivative memory entries must cite source session and sequence ranges instead of replaying full transcript rows.
- I3: High-risk/write-capable/delegating tool calls must have a deterministic `proposed -> reviewed -> executed/blocked` transition before side effects.
- I4: Read-only tool behavior remains backward compatible unless explicit review policy requires metadata-only review evidence.
- I5: Tool capability truth remains module-owned through registry/tool definitions; no hand-indexed hidden tool list may be introduced.
- I6: Scoped delegation must carry explicit scope, contact budget, validation state, and escalation reason before expanding communication.
- I7: Capability profiles are typed execution boundaries, not product UI role taxonomy or copied company metaphors.
- I8: Unsupported runtime behavior fails by contract or reports explicit diagnostics; no silent fallback or simulated capability is allowed.
- I9: Long-running/evaluator behavior must emit durable, redacted session events and must not mutate executor state through an evaluator side channel.
- I10: The final implementation must improve capability with fewer and stronger primitives; any copied MAS architecture, parallel runtime, or hidden worker system violates the chain.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/024-agent-capability-governance.md` | parent | Chain root | archived |
| `/todo/changelog/024a-agent-capability-governance.md` | a | Baseline / contract lock | archived |
| `/todo/changelog/024b-agent-capability-governance.md` | b | Pre-tool review contract primitives | archived |
| `/todo/changelog/024c-agent-capability-governance.md` | c | Executor loop review integration | archived |
| `/todo/changelog/024d-agent-capability-governance.md` | d | Scoped delegation and capability profiles | archived |
| `/todo/changelog/024e-agent-capability-governance.md` | e | Transcript-safe memory and evaluator health boundaries | archived |
| `/todo/changelog/024f-agent-capability-governance.md` | f | Docs, research mapping, and operator handoff | archived |
| `/todo/changelog/024g-agent-capability-governance.md` | g | Verification / closeout | archived |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|---------------|------------|----------------|
| `a` | Baseline / contract lock | Interpretation freeze, boundary declaration, invariant declaration - no artifact change | - | No |
| `b` | Implementation unit 1 | `src/core/tools/review.zig`, `src/core/tools/module.zig`, `src/core/tools/runtime.zig`, focused review tests | `a`; shared-types conflict removed by keeping review contracts tool-runtime owned | No |
| `c` | Implementation unit 2 | `src/core/executor/loop.zig`, session event append path, executor loop tests | `b` | No |
| `d` | Implementation unit 3 | `src/core/agents/profile.zig`, `src/core/agents/service.zig`, agent builtin tool schemas, plugin manifest validation, agent tests | `c` | No |
| `e` | Implementation unit 4 | `src/core/memory/` boundary module or checkpoint metadata, evaluator/heartbeat event contracts, shared types, tests | `d` | No |
| `f` | Implementation unit 5 | README, architecture docs, research crosswalk, `.docs/todo/changelog/_log.md` | `e` | No |
| `g` | Verification / regression / closeout | Full deliverable validation, invariant assertion, parent archival | all prior | No |

## Validation Expectations

- Signal 1: `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend\variant-1; .\scripts\zigw.ps1 build test --summary all` exits `0` and reports all tests passed.
- Signal 2: A high-risk mutating tool call records `tool_requested`, `tool_reviewed`, and `tool_completed` or `tool_blocked` in `.var/sessions/<session-id>/events.jsonl`.
- Signal 3: A blocked high-risk tool does not call the underlying tool implementation and appends a session-visible denial result.
- Signal 4: Child delegation includes scope, contact budget, validation state, and escalation reason in durable evidence before expanding work.
- Signal 5: Capability profiles resolve unsupported capabilities before execution, with explicit diagnostics rather than late runtime failure.
- Signal 6: Derivative memory entries cite session and sequence ranges and never duplicate the full transcript outside `messages.jsonl`.
- Signal 7: Documentation states current runtime truth and explicitly rejects copied MAS architecture, autonomous background evolution, and hidden parallel stores.
- Evidence format expected: exact command, exit code, stdout excerpt, and file/evidence path for session-event assertions.

## Next todo

`NONE`
