---
id: 022b-model-presentation-prompt-layers
parent: 022-model-presentation-prompt-layers
status: pending
owner: VAR1
created: 2026-04-30
---

# 022b Prompt Subsystem Implementation

## Contract

Create a canonical prompt subsystem under `core/prompts/` and route provider base-message construction through it.

## Scope

- Add prompt policy fields to shared config for optional system/developer prompt file paths.
- Extend `.var/config/settings.toml` parsing with a `[prompts]` section and fail closed on unknown prompt keys.
- Add prompt builder code that emits internal guardrails, configured system prompt, configured developer prompt, and tool catalog guidance.
- Replace `tools.buildAgentSystemPrompt` usage in the executor with the new prompt owner.
- Keep provider compatibility stable by emitting prompt layers as system-role messages with explicit section labels.

## Acceptance

- Tool runtime no longer owns the full agent system prompt.
- Missing prompt files fall back to built-in defaults.
- Present prompt files are loaded from workspace-relative paths.
- Prompt settings tests cover overlay and unknown-key rejection.

## Evidence

Pending.

## Exit State

This unit exits when prompt layer construction is exercised by unit tests and the executor consumes the new builder.
