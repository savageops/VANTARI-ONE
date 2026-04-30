---
id: 022-model-presentation-prompt-layers
status: completed
owner: VAR1
created: 2026-04-30
---

# 022 Model Presentation Prompt Layers

## Source Message Proof

Verbatim trigger excerpt:

> "let's work on the upgraded lane to see if we can improve the way that it presents to the model using it. Remember, this is a agent harness, right? So we need to really accommodate for any single model, even if it's the least intellig ent models."

> "we should ensure that we have one main entry point for a system prompt. So, our harness needs a system prompt, and it should be configurable. Then we also need a developer prompt."

> "we need a deeper layer prompt, a prompt that's not necessarily what users should have access to. For example, these are guardrails and parameters in the background that will be injected into the agent as context"

## Objective

Replace the current single prompt assembled inside the tool runtime with a canonical prompt subsystem that presents VAR1's operating contract, user-configurable system/developer prompt layers, internal guardrails, and tool catalog guidance in a deterministic order that low-capability models can follow.

## Reference Lock

- Local Pi reference: `.refs/badlogic__pi-mono/packages/coding-agent/src/core/system-prompt.ts` separates prompt construction from tools and supports custom and append system prompts.
- Local Pi reference: `.refs/badlogic__pi-mono/packages/coding-agent/src/core/resource-loader.ts` discovers system and appended prompt sources through resource loading.
- Local Pi provider reference: `.refs/badlogic__pi-mono/packages/ai/src/providers/openai-completions.ts` falls back from developer role to system role when provider compatibility does not guarantee developer-role support.
- Py Code Agent 0.1.0 package artifact: `docs/prompt-loading-flow.md` and `src/py_code_agent/core/agent.py` compose base system prompt plus plugin prompt contributions before session messages.

## Invariants

- I1: `core/tools` owns tool execution and static tool definitions only; `core/prompts` owns model-presented prompt assembly.
- I2: The hidden guardrail layer is compiled into the kernel and has no user-editable file path.
- I3: User-configurable system and developer prompt files are optional, project-local, and fail closed on invalid prompt settings.
- I4: Tool descriptors remain module-owned and exported through the existing registry; no parallel registry or hand-indexed list is added.
- I5: The provider-visible message stream remains OpenAI-compatible for weak/custom providers while retaining explicit prompt-layer boundaries in the prompt text.

## Todo Chain

| File | Unit | Responsibility | Status |
| --- | --- | --- | --- |
| `.docs/todo/changelog/022a-model-presentation-prompt-layers.md` | a | Baseline and reference lock | completed |
| `.docs/todo/changelog/022b-model-presentation-prompt-layers.md` | b | Prompt subsystem implementation | completed |
| `.docs/todo/changelog/022c-model-presentation-prompt-layers.md` | c | Tool descriptor hardening | completed |
| `.docs/todo/changelog/022d-model-presentation-prompt-layers.md` | d | Validation, comparison, docs, commit | completed |

## Completion Gate

Chain is complete when all units are archived into `.docs/todo/changelog/`, runtime tests pass, live prompt/tool adherence evidence exists for the upgraded lane, and a comparison against the main-branch binary is recorded if the baseline can be built.

Completion evidence: `88/88` tests passed, `develop` `834a632` and `main` `3d33a01` both built with isolated Zig cache roots, upgraded session `session-1777576359915-3cf77bc839898869` completed the six-operation tool plan, and main session `session-1777576409385-a2b609f0db4508dc` failed after one tool call with `StepLimitExceeded`.
