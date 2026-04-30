---
id: 022c-model-presentation-prompt-layers
parent: 022-model-presentation-prompt-layers
status: completed
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

- Hardened `list_files`, `search_files`, `read_file`, `write_file`, `append_file`, `replace_in_file`, and child-agent descriptors in their module-owned definitions.
- Added catalog-level call grammar in `core/tools/runtime.zig`: one JSON object, declared fields only, inspect `ok:false` and `tool_error_hint` before retrying.
- Added workspace-state tool examples and usage hints without introducing a second registry.
- Verified upgraded `tools --json` emits the new descriptor text after isolated-cache rebuild.

## Exit State

This unit exits when descriptor text and tests prove the strengthened tool guidance appears in the catalog.
