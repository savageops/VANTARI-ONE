# VAR1 Prompt Layering Snapshot

Date: 2026-04-30
Runtime lane: `apps/backend/variant-1`
Base commit: `56d3eb8 feat(var1): prioritize tool effect receipts`

## Objective

Improve how VAR1 presents instructions and tools to weak or instruction-sensitive models by making prompt ownership explicit, configurable where appropriate, hidden where required, and grounded in module-owned tool descriptors.

## Reference Findings

- Local Pi reference separates prompt construction from tool runtime. `packages/coding-agent/src/core/system-prompt.ts` accepts custom prompt, append prompt, tool snippets, guidelines, working directory, context files, and skills before producing a model-ready system prompt.
- Local Pi provider code preserves compatibility by falling back from developer role to system role when a target OpenAI-compatible server does not support developer-role transport.
- Local PyCodeAgent source constructs a base system prompt inside agent message preparation and aggregates plugin prompt fragments into the final system message.
- PyCodeAgent tool definitions include examples, but the stronger transferable invariant is prompt assembly plus tool-descriptor hinting, not copying its ReAct wording or plugin wrappers.

## Implemented Contract

`src/core/prompts/builder.zig` is the only owner for the model-presented VAR1 prompt envelope.

Envelope order:

```text
VAR1 Prompt Envelope
  └─ Internal Runtime Guardrails
  └─ System Prompt
  └─ Developer Prompt
  └─ Tool Use Contract
      └─ Live Tool Catalog
```

The provider still receives a system-role message for compatibility with OpenAI-compatible servers that do not expose a reliable developer role. The internal/system/developer/tool boundaries are preserved inside the prompt text.

Optional user-editable prompt policy:

```toml
[prompts]
system_prompt_file = ".var/prompts/system.md"
developer_prompt_file = ".var/prompts/developer.md"
```

Rules:

- Prompt files are workspace-relative.
- Missing or empty prompt files fall back to built-in defaults.
- Unknown prompt keys fail closed.
- Absolute prompt paths fail closed.
- Hidden guardrails are compiled into `core/prompts` and are not file-configurable.
- Tool catalog text is assembled from module-owned `ToolDefinition` records and real availability metadata.

## Tool Descriptor Hardening

The descriptor pass tightened the high-frequency failure points for weaker models:

- `list_files` now presents as path discovery, not generic listing.
- `search_files` now presents as iex-backed content discovery and preserves the existing recovery phrase for file-not-found loops.
- `read_file` now emphasizes known-file inspection and line-range semantics.
- `write_file`, `append_file`, and `replace_in_file` now distinguish full-file, additive, and exact-edit semantics.
- Agent tools now state bounded child-run ownership and supervision responsibility.
- Workspace-state tools now publish example JSON and usage hints when they appear in the enabled catalog.
- `renderCatalog` now starts with the JSON-object call grammar and retry-repair rule.

## Validation

```text
.\scripts\zigw.ps1 build test --summary all
Build Summary: 5/5 steps succeeded; 88/88 tests passed
```

## Residual Boundary

Prompt layering and descriptor clarity improve the model-visible control surface, but they do not prove artifact correctness by themselves. The next durable step is a benchmark that compares main and upgraded binaries across the same provider/model using scripted tasks scored on tool-call validity, schema repair, evidence use, and final-answer groundedness.
