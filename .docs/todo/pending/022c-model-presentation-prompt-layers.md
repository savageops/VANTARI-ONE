---
id: 022c-model-presentation-prompt-layers
parent: 022-model-presentation-prompt-layers
status: pending
owner: VAR1
created: 2026-04-30
---

# 022c Tool Descriptor Hardening

## Contract

Improve model-facing tool descriptors and catalog guidance without introducing any new tool registry or runtime branch drift.

## Scope

- Sharpen file-tool descriptions around exact JSON keys, discovery order, mutation semantics, and verification.
- Sharpen child-agent descriptors around launch/status/wait/list argument shapes and supervision intent.
- Add catalog-level sequencing rules for weak models: discover path, search content, read exact file, mutate with the smallest matching tool, verify mutating effects.

## Acceptance

- Every built-in coding tool still has exactly one module-owned definition.
- Tool parameter schemas remain strict `additionalProperties: false`.
- Prompt catalog renders examples and guidance for each available tool.

## Evidence

Pending.

## Exit State

This unit exits when descriptor text and tests prove the strengthened tool guidance appears in the catalog.
