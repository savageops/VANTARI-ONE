# Task 21 — Plugin Contract Surface

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/21-plugin-contract-surface.md`.

1. **Study the repo** — read `AGENTS.md` (Section V Tool Runtime Contract, Section IX Source Hierarchy, Section XII Forbidden Anti-Patterns), `.docs/log.txt` (search for "plugin", "extension", "module", "registry", "capability"), and the plugin/tools code: `apps/backend/src/core/plugins/`, `apps/backend/src/core/tools/registry.zig`, `apps/backend/src/core/tools/module.zig`.
2. **Study competitors** — `.refs/vercel__eve/` (plugins/extensions, dynamic tools), `.refs/openai__codex/`, `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: agent plugin architectures, MCP (Model Context Protocol) tool servers, VS Code extension API patterns, how to build safe plugin boundaries, WASM-based plugin isolation, dynamic library loading in Zig (dlopen/LoadLibrary), how Temporal handles activity registration.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Sections V, IX, XII)

- **Tool capability truth is contractual.** Module-owned definitions are the only source for provider schema, catalog JSON, availability, review risk, and dispatch.
- **Built-in tools remain the default capability surface.** Plugin tools are opt-in and must not silently alter the model-visible tool list.
- **Plugin contract code belongs under `apps/backend/src/core/plugins/`.** Plugin implementations must NOT live inside `core/`.
- Tool discovery is catalog-first. The model-visible catalog must explain available tools, unavailable dependencies, examples, usage hints, review risk, and exact JSON fields.
- Agent-facing tools and backend-only primitives share one module-owned capability boundary.

## Capability flow

```text
definition + availability + review_risk + execute
  -> catalog
  -> provider tool schema
  -> review gate
  -> runtime dispatch
  -> effect/event evidence
```

## Competitor angles to research

- **Vercel Eve:** dynamic tools resolved from context (`resolveTools` in tool-loop.ts). How are they registered? Are they sandboxed?
- **OpenAI Codex:** tool definitions / function calling schema.
- **MCP:** Model Context Protocol — standardized tool server protocol. How does it work? What can VANTARI borrow vs reject?
- **VS Code:** extension activation events, contribution points, lazy loading.
- **Temporal:** activity registration, worker plugins.

## Pipeline items to define

- P1: Plugin manifest format (name, version, tool definitions, availability contracts, review risk class)
- P1: Plugin loading boundary (opt-in, never alters default catalog)
- P2: Plugin isolation (process boundary vs in-process vs WASM)
- P2: Plugin capability negotiation (what tools/capabilities does a plugin expose?)

## Forbidden anti-patterns to guard against (Section XII)

- Tool schema drift between template, runtime, API endpoint, and frontend optimistic state.
- Plugin tools silently altering the model-visible tool list.
- Hidden fallback readers, hidden provider paths.

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "plugin", "extension", "module", "registry", "capability".

## Output

Write ONLY `.docs/roadmap/21-plugin-contract-surface.md`. Do not modify source code or the index.
