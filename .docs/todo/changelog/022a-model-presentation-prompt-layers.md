---
id: 022a-model-presentation-prompt-layers
parent: 022-model-presentation-prompt-layers
status: completed
owner: VAR1
created: 2026-04-30
---

# 022a Baseline And Reference Lock

## Contract

Lock the existing prompt/tool presentation path and reference-derived boundary shape before edits.

## Scope

- Read current VAR1 prompt assembly, tool catalog rendering, provider role serialization, and config parser paths.
- Read local Codex/Pi references for custom system prompt, append prompt, and developer-role compatibility.
- Read Py Code Agent package artifact for system prompt aggregation and tool verification guidance.

## Acceptance

- Baseline confirms `apps/backend/variant-1/src/core/executor/loop.zig` currently injects one `.system` message built by `tools.buildAgentSystemPrompt`.
- Baseline confirms `apps/backend/variant-1/src/core/tools/runtime.zig` currently owns both prompt prose and tool catalog rendering.
- Reference findings are captured in the parent todo and implementation notes.

## Evidence

- Baseline confirmed the pre-slice executor injected one system message built from `tools.buildAgentSystemPrompt`.
- Baseline confirmed `core/tools/runtime.zig` owned both prompt prose and catalog rendering before the slice.
- Reference lock used local Pi/Codex prompt/provider code plus Py Code Agent 0.1.0 package sources to extract the transferable invariant: centralized prompt assembly, provider-role compatibility, and descriptor hinting.

## Exit State

This unit exits when the code edit target is explicit and no reference claim remains unverified.
