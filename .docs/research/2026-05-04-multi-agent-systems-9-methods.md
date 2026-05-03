# 2026-05-04 Insect Research: 9 New Multi-Agent System Methods

## Scope

Objective: harvest the Turing Post summary and primary arXiv records for the nine listed MAS methods, then translate the useful invariants into VANTARI-ONE without importing parallel runtimes, incidental paper scaffolding, or unverified autonomous-worker behavior.

Acquisition path:

- Insect page extraction: `https://turingpost.com/p/9masmethods`
- Insect query extraction: `RecursiveMAS OneManCompany OrgAgent CORAL LLMA-Mem Agentic Federated Learning CASCADE GRASP Reinforced Agent multi-agent systems`
- Insect primary-source extraction: arXiv pages for `2604.25917`, `2604.22446`, `2604.01020`, `2604.01658`, `2604.03295`, `2604.04895`, `2604.00451`, `2604.00717`, `2604.27233`
- Local raw captures: `.docs/research/.tmp-insect/`

## VANTARI Baseline

`apps/backend/variant-1` is the only live runtime lane. `VAR1` is the Zig harness kernel, and `.var/sessions/<session-id>/` owns `session.json`, `messages.jsonl`, `context.jsonl`, `events.jsonl`, and `output.txt`.

Current kernel ownership already contains the primitives these papers keep rediscovering under heavier names:

| Primitive | Local owner | Current invariant |
| --- | --- | --- |
| Durable transcript | `src/core/sessions/store.zig` | `messages.jsonl` is append-only full history with stable `id` and monotonic `seq`. |
| Model-visible context | `src/core/context/builder.zig` | Only the builder assembles provider messages from session state and checkpoints. |
| Context compression | `src/core/context/compactor.zig` | Checkpoints cover explicit message sequence ranges without mutating transcript history. |
| Tool capability truth | `src/core/tools/registry.zig` | Tool availability derives from module-owned definitions, not hand-indexed strings. |
| Runtime execution | `src/core/executor/loop.zig` | Tool calls, events, output, compaction, and provider-overflow recovery converge in one loop. |
| Shared protocol | `src/shared/types.zig` | Sessions, context checkpoints, tools, events, and policy fields are typed surfaces. |

## Method Identification

| Method | Core mechanism | Reported claim | VANTARI translation |
| --- | --- | --- | --- |
| RecursiveMAS | Multi-agent recursive latent-space refinement through `RecursiveLink`; agents exchange internal refined state rather than only text. | Across nine benchmarks, the paper reports +8.3 accuracy, 1.2x-2.4x speedup, and 34.6%-75.6% token reduction. | Do not chase latent tensors in VAR1. Translate the invariant into typed checkpoints, compact state transfer, artifact hashes, and source sequence ranges. |
| OneManCompany (OMC) | Portable `Talent` units combine skills, tools, and runtime configs; a Talent Market recruits capabilities; Explore-Execute-Review search governs execution. | PRDBench reports 84.67% success and +15.48 percentage points over baseline. | Evolve `agent_profile` and plugin manifests toward capability profiles: tool set, policy, provider constraints, budget, and availability. No dynamic marketplace until manifest validation, deterministic load order, enablement, and lifecycle tests exist. |
| OrgAgent | Company-like hierarchy with governance, execution, and compliance layers. | The article reports +102.73% SQuAD 2.0 improvement and -74.52% token use for GPT-OSS-120B in their setup. | Keep the layers as control functions: planner/policy, executor/tool loop, verifier/finalization gate. |
| CORAL | Long-running autonomous evolution with persistent memory, asynchronous agents, heartbeat intervention, isolated workspaces, evaluator separation, and resource/session/health management. | The paper reports 3x-10x higher improvement on open-ended tasks with fewer evaluations. | Adopt heartbeat, isolation, evaluator separation, and resource accounting as runtime safety primitives. Reject autonomous background evolution until cancellation, idempotent marks, and cold-start recovery are proven. |
| LLMA-Mem | Lifelong MAS memory with local/shared memory topologies; studies team size versus accumulated experience. | Finds non-monotonic team scaling: smaller teams can outperform larger teams when memory reuse is better. | Add retrieval-grade derivative memory only as a typed index with source `messages.jsonl` references and invalidation. Never let memory become a second transcript. |
| Agentic Federated Learning | LLM agents orchestrate FL: server agents select clients; client agents manage privacy budget, resource constraints, and local model complexity. | Presents efficiency, fairness, reliability, privacy, and security as the central orchestration axes. | Map to local-provider and host policy: model/provider selection, privacy budget, hardware envelope, and fail-closed diagnostics. This is runtime policy, not FL implementation. |
| CASCADE | Scoped communication for disrupted industrial replanning; agents expand communication only when local validation fails under latency/communication budgets. | Separates unified agent substrate from scoped interaction layer controlling who communicates, when, and how far escalation propagates. | Strong near-term fit for supervised subagents: add explicit scope contracts, contact budgets, validation state, escalation reason, and audit events. |
| GRASP | Active shared perception aligns independent gradients into a consensus gradient for multi-agent collaborative optimization; formalized through generalized Bellman equilibrium. | Evaluated on SMAC and Google Research Football. | Training-time method. For VAR1, borrow only the consensus principle for evaluator-signal aggregation, not gradient machinery. |
| Reinforced Agent | Reviewer agent evaluates provisional tool calls before execution, using inference-time feedback rather than posthoc evaluation. | Reports better irrelevance detection and multiturn decision quality; o3-mini shows a 3:1 benefit-risk ratio in their evaluation. | Strongest immediate kernel fit: insert a typed pre-tool review gate before write-capable/high-risk tool execution, then emit durable `tool_reviewed` events. |

## Structural Application

### U1: Pre-Tool Review Gate

```text
<VAR1 session turn>
  └─ <Context builder emits provider messages>
  └─ <Assistant proposes tool call { name, arguments, risk_class }>
        │ <tool_call proposed>
        ▼
  <PreToolReview>
  ├─ <Schema validation>
  ├─ <Availability validation> -> <Tool registry>
  ├─ <Risk/policy validation> -> <Context policy + session config>
  ├─ <Review result { approved, reason, redactions, audit_id }>
  ├─ <Event append> -> <events.jsonl: tool_reviewed>
  └─ <Control handoff>
        ▼
  <Tool runtime>
  └─ <Execute only approved call>
      ├─ <Effect receipt>
      ├─ <Session message append>
      └─ <Terminal state: audited tool result>
```

Adopt from Reinforced Agent. Keep the reviewer as a typed kernel phase first. A model-backed reviewer can become an implementation detail later, but the durable contract is `proposed -> reviewed -> executed/blocked`.

### U4: Scoped Escalation State Machine

```text
<LocalPlan>
  │ <local validation fails>
  ▼
<ScopedEscalation>
  ├─ <entry action: allocate contact budget>
  ├─ <invariant: escalation reason is recorded>
  │ <budget exhausted>
  ▼
<TerminalBlocked>
  └─ <effect/emit: session event + user-visible blocker>

<ScopedEscalation>
  │ <peer evidence sufficient>
  ▼
<Resolved>
  └─ <effect/emit: scoped result + audit trail>
```

Adopt from CASCADE. The invariant is explicit communication scope under a budgeted state machine.

### U2: Capability Profile Direction

```text
apps/backend/variant-1/
├─ src/core/agents/
│  ├─ profile.zig        // canonical capability profile owner
│  ├─ policy.zig         // execution and resource constraints
│  └─ index.zig          // exports
├─ src/core/plugins/
│  ├─ manifest.zig       // typed sockets and capability declarations
│  └─ validation.zig     // deterministic validation
└─ src/core/tools/
   ├─ registry.zig       // module-derived tool truth
   └─ runtime.zig        // execution surface
```

Adopt from OMC and OrgAgent only at the manifest/profile layer. Avoid importing company structure into the runtime graph.

## Ordered Adoption Plan

1. Pre-tool review gate.
   - Source method: Reinforced Agent.
   - Local touchpoints: `loop.zig`, `tools/runtime.zig`, `tools/registry.zig`, `shared/types.zig`.
   - Contract: every high-risk or write-capable tool call receives a durable `tool_reviewed` event before execution.
   - Test: approved call executes; blocked call appends event and session-visible denial without invoking the tool.

2. Scoped escalation contract.
   - Source method: CASCADE.
   - Local touchpoints: agent/supervision tool definitions, event schema, session messages.
   - Contract: delegated or peer communication carries `scope_depth`, `contact_budget`, `validation_status`, and `escalation_reason`.
   - Test: local validation success avoids escalation; failure expands scope only within budget.

3. Memory topology without transcript duplication.
   - Source method: LLMA-Mem.
   - Local touchpoints: future `src/core/memory/` or checkpoint metadata.
   - Contract: derivative memory entries cite source session id and sequence range; invalidation is explicit; no full-message replay store exists outside `messages.jsonl`.
   - Test: model context can consume memory summaries while full transcript remains the only durable transcript.

4. Capability profile and talent manifest.
   - Source methods: OMC and OrgAgent.
   - Local touchpoints: existing `agent_profile`, plugin manifests, tool registry.
   - Contract: a capability profile is a typed bundle of tools, policy, resource envelope, provider constraints, and availability.
   - Test: unavailable capability fails at registry/profile resolution, not during late execution.

5. Runtime health and evaluator separation.
   - Source method: CORAL.
   - Local touchpoints: bridge audit, events, session lifecycle, future evaluator socket.
   - Contract: long-running work emits heartbeat/health records and evaluator outputs are separated from executor state mutation.
   - Test: stale/failed runtime reports a diagnosable event with redacted payloads.

6. Provider and local-host policy guard.
   - Source method: Agentic Federated Learning.
   - Local touchpoints: runtime config, provider selection, host bridge diagnostics.
   - Contract: hardware, privacy, budget, and policy constraints are checked before provider selection.
   - Test: unknown high-impact policy keys fail closed with operator-visible diagnostics.

7. Hold for research only.
   - RecursiveMAS requires model-internal latent transfer. Use its token-efficiency principle only.
   - GRASP requires training/RL gradient infrastructure. Use its consensus principle only.

## Rejection Ledger

- Do not create a second transcript store under the label "memory".
- Do not add a dynamic Talent Market before plugin validation and deterministic enablement exist.
- Do not add autonomous background evolution before cancellation, idempotency, and cold-start recovery are testable.
- Do not import company-role taxonomy into product UI or provider prompts.
- Do not route around the context builder; all provider-visible history remains builder-owned.
- Do not make scoped escalation a hidden side channel; every expansion needs an event and budget.

## Source Index

- Turing Post: `https://www.turingpost.com/p/9masmethods`
- RecursiveMAS: `https://arxiv.org/abs/2604.25917`
- OneManCompany: `https://arxiv.org/abs/2604.22446`
- OrgAgent: `https://arxiv.org/abs/2604.01020`
- CORAL: `https://arxiv.org/abs/2604.01658`
- LLMA-Mem: `https://arxiv.org/abs/2604.03295`
- Agentic Federated Learning: `https://arxiv.org/abs/2604.04895`
- CASCADE: `https://arxiv.org/abs/2604.00451`
- GRASP: `https://arxiv.org/abs/2604.00717`
- Reinforced Agent: `https://arxiv.org/abs/2604.27233`
