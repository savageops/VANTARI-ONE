# Task 19 — Reference Pressure Loop

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/19-reference-pressure-loop.md`.

1. **Study the repo** — read `AGENTS.md` (Section XI Reference Discipline, Section XVIII item 16), `.docs/log.txt` (search for "ref", "harvest", "codex", "pi-mono", "eve", "vercel", "borrow", "pressure"), and the existing `.refs/` directory structure.
2. **Study the harvested references** — `.refs/vercel__eve/`, `.refs/openai__codex/`, `.refs/badlogic__pi-mono/`. Understand what each has contributed and what remains to be learned.
3. **Web research** — search for: agent runtime open-source landscape 2026, new agent frameworks worth harvesting (Mastra, Inngest agent, Hatchet, Trigger.dev, PydanticAI, Agno/Multi-Agent, DSPy, AutoGen v0.4, CrewAI, Swarm), how mature engineering teams run reference-harvesting loops, competitive analysis methodology for infrastructure.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XI, Section XVIII item 16)

- **Reference pressure loop:** periodically re-harvest `.refs/openai__codex` and `.refs/badlogic__pi-mono`, but land only primitives that reduce VANTARI surface complexity while increasing runtime proof strength.

- **Reference discipline (Section XI):**
  - Use `iex` for repository search.
  - Before intricate kernel changes, inspect `.refs/openai__codex` and `.refs/badlogic__pi-mono`.
  - Copy ownership patterns, not complexity. Borrow checkpoint boundaries, item lifecycle pressure, and context ownership; reject extension forests, branch graphs, and global session stores.
  - Every reference-harvested idea must pass the VANTARI compression test: fewer concepts at the call site, stronger guarantees in the core, lower runtime ambiguity, clearer recovery evidence.

## What has been harvested so far

- `.refs/vercel__eve/` (2026-08-04): Temporal durable workflows, AI SDK transport, in-memory compaction. Key finding: Eve has no sharded model; VANTARI's ledger is ahead.
- `.refs/openai__codex/`: auth chain, session persistence, tool schema. Key finding: subscription-auth model to replicate.
- `.refs/badlogic__pi-mono/`: Rust agent loop, context budget tracking. Key finding: lightweight harness patterns.

## Pipeline items to define

- P1: Systematic re-harvest schedule (quarterly or per-major-milestone)
- P1: New candidates to harvest: Mastra, Inngest, Hatchet, Trigger.dev, PydanticAI, DSPy, AutoGen v0.4
- P2: Compression test checklist (does this primitive reduce VANTARI surface complexity?)
- P2: Rejected-primitive archive (what we looked at and explicitly rejected, with rationale)

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "ref", "harvest", "codex", "eve", "vercel", "pi-mono". Vercel/eve at 700 mentions, codex at 156 mentions — these are the two most-studied references.

## Output

Write ONLY `.docs/roadmap/19-reference-pressure-loop.md`. Do not modify source code or the index.
