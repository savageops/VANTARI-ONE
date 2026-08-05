# Task 20 — Skill Routing Contract

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/20-skill-routing-contract.md`.

1. **Study the repo** — read `AGENTS.md` (Section VII Skill Routing Contract), `.docs/log.txt` (search for "skill", "route", "prompt", "capsule", "planning", "insect", "dupe", "recon"), and any skill-related code under `apps/backend/src/core/` (prompts, tools, docs sync).
2. **Study competitors** — `.refs/vercel__eve/` (skills system, `resolveSkills` in tool-loop.ts), `.refs/openai__codex/`, `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: agent skill/prompt routing systems, Claude Code skills, OpenAI Codex instructions/custom-prompts, Cursor rules files, how agent runtimes select between prompts/instructions dynamically, prompt-as-code patterns, MCP (Model Context Protocol) resource/prompt routing.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section VII)

- **Skills are operating protocols.** Tools execute actions; skills choose method, evidence shape, validation discipline, and when to read deeper instructions.

- **Native high-leverage skills:**

| Skill | Use When |
|---|---|
| `planning-spec` | Decomposed execution chains, state-machine handoff, invariant preservation, crash recovery |
| `insect` / `insect-rs-runtime` | External research, crawling, scraping, search extraction |
| `dupe-audit` | Large implementations, refactors, parity checks, duplicate ownership risk |
| `recon-intel` | Unfamiliar code areas, orchestration/storage/auth/runtime changes |
| `ux-playbook` | TUI/browser/frontend layout, hierarchy, disclosure, feedback |
| `t3-tape` | PatchMD/T3 Tape state, patch import/export, validation, migration |
| `repo-harvester` | Global source corpus harvesting |
| `task-audit` | Findings-first implementation correctness review |

- **Key rules:**
  - The prompt may include compact native skill capsules.
  - `skill_info` is the retrieval primitive for exact skill capsules. Do NOT inject every global `SKILL.md` into the prompt.
  - Add-on skills are demand-loaded protocols, not always-on prompt mass.
  - A skill request is not satisfied by naming the skill. The task must route into the skill's execution contract.

## Competitor angles to research

- **Vercel Eve:** `resolveSkills` in `tool-loop.ts` — how does it load skills? Are they always-on or demand-loaded? Token cost?
- **OpenAI Codex:** custom instructions / AGENTS.md / prompt customization.
- **Cursor:** `.cursorrules` file — always injected? Token cost?
- **Claude Code:** CLAUDE.md + skill system.
- **MCP:** Model Context Protocol resources and prompts — standardized routing.

## Pipeline items to define

- P1: Skill capsule registry (compact descriptions in prompt, full content on demand)
- P1: `skill_info` as the retrieval primitive (typed request/response)
- P2: Skill routing decision tree (when to activate which skill)
- P2: Token-budgeted skill injection (never exceed N tokens of skill capsules in the system prompt)

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "skill", "route", "prompt", "capsule".

## Output

Write ONLY `.docs/roadmap/20-skill-routing-contract.md`. Do not modify source code or the index.
