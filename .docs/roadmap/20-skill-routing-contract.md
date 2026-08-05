# 20 — Skill Routing Contract

**Priority: P1**

## The seam

A skill is an operating protocol, not a tool. Tools execute actions; skills choose method, evidence shape, validation discipline, and when to read deeper instructions (`AGENTS.md` §VII). The seam is the boundary between *what the model always sees* (compact native skill capsules compiled into the system prompt) and *what the model retrieves on demand* (the exact execution contract of one skill via `skill_info`).

The contract has two load-bearing invariants. First: a skill request is not satisfied by naming the skill — the task must route into the skill's execution contract. Second: `skill_info` is the retrieval primitive for exact skill capsules; the prompt must not inject every global `SKILL.md` body. Get this seam wrong in either direction and the harness degrades: inject every skill body and the system prompt bloats on every turn (the `.cursorrules` failure mode); inject nothing but names and the model cannot route, because a name without a trigger surface is invisible to task selection.

This theme serves the north star (01). Sharded context windows are only cheap if each shard carries the minimal skill mass its branch actually needs. Skill routing is the retrieval discipline that keeps every shard lean.

## What exists today

- **Skill capsules compiled into the system prompt.** `apps/backend/src/core/prompts/builder.zig` calls `tools.skills.renderPromptCapsules(writer)` (line 136) inside `buildAgentSystemPromptWithMemory`. The capsule section is appended after the tool-use contract and before the tool catalog, on every prompt build.
- **The capsule renderer.** `apps/backend/src/core/tools/builtin/skills.zig` → `renderPromptCapsules` emits a fixed `# Skill Routing Contract` header, one line per native skill (`- <name>: <summary>`), the canonical skill-root note, and the `skill_info` retrieval directive. Add-on skills are intentionally **not** listed in the prompt — only the directive that they are "discoverable, not always loaded".
- **`skill_info` tool — the retrieval primitive.** `skills.zig` defines the tool (`.name = "skill_info"`, `.review_risk = .read_only`) with parameters `name` (exact skill), `query` (lowercase routing filter), and `include_addons`. Its `usage_hint` states the contract: *"Native skills are already summarized in the prompt. Call skill_info for exact routing capsules; do not load every skill body unless the task explicitly needs it."*
- **Typed dispatch.** `apps/backend/src/core/tools/runtime.zig` routes `skill_info` at line 380–382 to `skills.execute`, which returns either an exact capsule (`renderExact`: `SKILL / TIER / ROOT / SUMMARY / TRIGGERS / PROTOCOL`) or a filtered index (`renderIndex`: `NATIVE SKILLS` / `ADDON SKILLS` blocks).
- **Two skill tiers, statically declared.** `native_skills` (9 entries: planning-spec, insect, dupe-audit, recon-intel, ux-playbook, t3-tape, repo-harvester, playwright, task-audit) and `addon_skills` (4 entries: docx, react-doctor, find-skills, remotion-best-practices). Each entry carries `name`, `tier`, `root`, `summary`, `triggers`, and optional `protocol`. The `protocol` field is the execution contract — only planning-spec and insect carry one today.
- **Prompt layering.** `builder.zig` reads `.var/prompts/system.md` and `.var/prompts/developer.md` (configurable via `PromptPolicy` in `shared/types.zig`), layers them between `internal_guardrails` and the tool catalog. Skill capsules sit inside this compiled envelope, not in a separate channel.

**Gap:** the capsule registry is a static Zig array, not a discoverable ledger. The `protocol` field (the actual execution contract) is present on only 2 of 9 native skills. There is no token budget on the capsule section, no decision tree that tells the model *when* to call `skill_info` versus proceed from the summary, and no proof that the capsule section stays bounded as skills grow. The retrieval primitive exists and is wired; the routing discipline around it is enforced only by prompt prose.

## What the competitor does

### Eve (Vercel) — list-all + `load_skill`

Eve implements progressive disclosure with a hard split between *announcement* and *body*.

- **All skills announced in the static system prompt, every turn.** `packages/eve/src/execution/session.ts:148-155` (`createSessionSystemPrompt`) appends `formatAvailableSkillsSection(input.turnAgent.availableSkills)` to the turn agent's instructions block. The section (`packages/eve/src/execution/skills/instructions.ts`) lists **every** skill as `- <name>: <description> (path: <skillRoot>/<name>/SKILL.md)` with the directive: *"If the user names a skill or the request clearly matches one of the descriptions below, call load_skill before proceeding."*
- **`load_skill` fetches the full markdown body.** `packages/eve/src/runtime/framework-tools/skill.ts` → `executeLoadSkillTool` returns `authoredSkill.markdown` verbatim, or reads the dynamic skill from the sandbox via `loadSkillFromSandbox`. The returned body is what the model follows instead of improvising.
- **Dynamic skills are event-driven and sandbox-materialized.** `packages/eve/src/context/dynamic-skill-lifecycle.ts` → `dispatchDynamicSkillEvent` runs resolvers on allowed stream events, materializes resolved skill packages into the sandbox (`writeSkillPackageToSandbox`), and stores a *pending announcement* (`PendingSkillAnnouncementKey`) that the tool-loop injects as a system message on the next turn (`tool-loop.ts:850-852`).
- **Discovery is filesystem-based and collision-aware.** `packages/eve/src/discover/skills.ts` scans `skills/` for flat `*.md|ts` files or `<name>/SKILL.md` packages, deduplicates by skill id, and emits typed diagnostics (`DISCOVER_SKILL_COLLISION`, `DISCOVER_SKILL_MARKDOWN_MISSING`).

**Limitation:** Eve pays the announcement cost on every turn for every skill, with no budget cap and no tier distinction. The announcement is a string appended to instructions, not a typed, versioned capsule. The body is demand-loaded, but the index never shrinks. `disable-model-invocation` is not an Eve concept — all authored skills are always announced.

### pi-mono (badlogic) — Agent Skills standard, XML announcement

pi-mono implements the [Agent Skills standard](https://agentskills.io/specification) (the Anthropic-published format, Dec 2025).

- **XML `<available_skills>` block in the system prompt.** `packages/coding-agent/src/core/skills.ts:339-365` (`formatSkillsForPrompt`) emits `<available_skills>` with one `<skill>` per entry: `<name>`, `<description>`, `<location>`. The header tells the model: *"Use the read tool to load a skill's file when the task matches its description."*
- **Progressive disclosure is explicit design policy** (`docs/skills.md`): *"At startup, pi scans skill locations and extracts names and descriptions. The system prompt includes available skills in XML format. When a task matches, the agent uses `read` to load the full SKILL.md. This is progressive disclosure: only descriptions are always in context, full instructions load on-demand."*
- **`disable-model-invocation` opt-out.** Skills with this frontmatter flag are excluded from the prompt (`formatSkillsForPrompt` filters them); they are reachable only via explicit `/skill:name` commands. This is the one knob competitors expose for keeping prompt mass down.
- **Multi-source discovery.** Global (`~/.pi/agent/skills/`, `~/.agents/skills/`), project (`.pi/skills/`, `.agents/skills/` walk to git root), packages, settings, and `--skill` CLI — all unified into one validated list with spec-compliant name/description rules.

**Limitation:** the body is loaded with the generic `read` tool, not a typed retrieval primitive. There is no `protocol`/execution-contract field — the model gets raw markdown and must infer the discipline. The announcement is unbounded: every visible skill's name+description+location is in every prompt.

### Codex (OpenAI) / Cursor — instructions files, no skill tiering

- **Codex** loads `AGENTS.md` as always-on project instructions (the convention VANTARI also follows) with recursive ancestor walk. There is no native skill-capsule system in the codex-rs core; capability extension is tool-based, not protocol-based. Custom instructions are a static prompt layer, not a routed, demand-loaded surface.
- **Cursor** (`.cursorrules` / `.cursor/rules`) injects the rules file into every request — the canonical anti-pattern. No retrieval primitive, no tiering, no budget. The file is always-on prompt mass regardless of relevance.

**Limitation:** both treat instructions as a monolithic, always-injected layer. Neither has the concept of a skill as a separable protocol with its own retrieval contract.

## Why VANTARI does it better

1. **Tiered disclosure, not flat announcement.** VANTARI distinguishes `native` (high-leverage, summarized in the prompt) from `addon` (discoverable, not in the prompt). Eve and pi-mono announce every skill equally; VANTARI's prompt carries only the ~9 skills that change method, and relegates the rest to `skill_info` retrieval. This is the operator's stated design (`AGENTS.md` §VII; `.docs/log.txt`: *"make those native skills that he should know about by default … add-ons are demand-loaded"*).
2. **The capsule carries the execution contract, not just a description.** `skill_info` returns `SKILL / TIER / ROOT / SUMMARY / TRIGGERS / PROTOCOL`. The `PROTOCOL` field is the routing target — the exact steps the skill demands (e.g. insect's canonical runtime path and script invocation; planning-spec's todo-chain persistence contract). Eve's `load_skill` returns raw markdown; pi-mono returns raw markdown via `read`. VANTARI's typed envelope is what satisfies *"a skill request is not satisfied by naming the skill — the task must route into the skill's execution contract."*
3. **One compiled prompt envelope, one retrieval primitive.** The capsule section is compiled inside `buildAgentSystemPromptWithMemory` alongside the tool catalog — it is part of the same deterministic, replayable prompt build the context compiler owns (roadmap 02). `skill_info` is the single retrieval path, dispatched through the same `executeWithRunner` lane as every other tool (roadmap 05). There is no second prompt-assembly surface, no sandbox-only skill channel, no ad-hoc `read`-the-markdown escape hatch.
4. **Read-only, review-safe retrieval.** `skill_info` is `.review_risk = .read_only`. Skill routing never touches the filesystem mutation path and never needs a review gate. Eve's dynamic skills write packages into a sandbox; pi-mono's `read` is a general file tool. VANTARI's retrieval is a closed, typed query over a static registry — no side effects, no sandbox materialization, no collision-with-filesystem hazard.
5. **Prompt-layer configurable, skill-layer stable.** `PromptPolicy` lets an operator point `system_prompt_file`/`developer_prompt_file` at workspace-owned markdown, but the skill capsule contract is kernel-owned and stable. Competitors conflate instructions and skills (Cursor) or push skills into the same filesystem-discovery layer as tools (Eve). VANTARI keeps the prompt layers operator-editable and the skill registry kernel-owned — matching §IX (source hierarchy) and §V (tool capability truth is contractual).

### ROUTING MODEL (target)

```text
system prompt (compiled once per turn by builder.zig)
  └─ # Skill Routing Contract
       └─ native capsule index:  name + one-line summary   (always present, bounded)
       └─ directive:             "use skill_info for exact capsules"

task arrives
  ├─ matches a native summary closely  → call skill_info{name} → PROTOCOL capsule → execute contract
  ├─ matches an addon (not in prompt)  → call skill_info{query} → filtered index → skill_info{name} → capsule
  └─ no skill match                     → proceed with tool catalog only; no skill mass paid
```

The model never carries a skill body it did not retrieve. The prompt never carries an addon it did not promote to native. Every shard (roadmap 01) inherits exactly this bounded capsule section.

## Pipeline items under this theme

### P1-1: Skill capsule registry as a typed, versioned ledger
- **Contract:** the static `native_skills` / `addon_skills` arrays in `skills.zig` become a typed registry where every entry carries `name`, `tier`, `root`, `summary`, `triggers`, and a non-empty `protocol`. Today only 2 of 9 native skills carry `protocol`; the contract is that every native skill carries one, because the protocol is the routing target.
- **Mechanism:** extend the `SkillEntry` struct with a required `protocol` field; backfill the 7 missing protocols (dupe-audit, recon-intel, ux-playbook, t3-tape, repo-harvester, playwright, task-audit) from their canonical `SKILL.md` bodies. Keep the registry compile-time-constant (no runtime disk scan) so the capsule section is deterministic and replayable. Reconcile the registry with the `AGENTS.md` §VII table (playwright is in code but not in the table — pick one source of truth).
- **Test:** the renderer rejects a registry entry with an empty `protocol` at build time (comptime assertion); the rendered capsule section contains exactly one line per native skill and zero addon bodies.
- **Proof:** a snapshot test of the full capsule section byte-for-byte, plus a comptime guarantee that no `protocol` is empty.

### P1-2: `skill_info` retrieval contract hardened
- **Contract:** `skill_info` is the only legal path from a skill name to its execution contract. The exact-capsule response (`renderExact`) is the canonical routing target; the index response (`renderIndex`) is the discovery surface for addons and ambiguous queries. The tool must fail closed on an unknown name with a typed `InvalidArguments` that lists available names.
- **Mechanism:** `skills.execute` already returns `module.Error.InvalidArguments` for unknown names (`findByName` returns null). Add the available-names list to the error hint (parity with Eve's `formatSkillNotFoundError`), and make the `query` match cover the `protocol` field (today `matchesQuery` checks name/summary/triggers but not protocol — a routing query like "state-machine handoff" should hit planning-spec's protocol).
- **Test:** (a) `skill_info{name="planning-spec"}` returns a capsule whose `PROTOCOL` line is non-empty; (b) `skill_info{name="nonexistent"}` fails closed with a hint listing native names; (c) `skill_info{query="web search"}` returns insect via protocol/trigger match; (d) `skill_info{include_addons=false}` omits the addon block.
- **Proof:** event/session evidence that a turn which routes through `skill_info` emits `tool_requested → tool_completed` with the capsule as bounded output, replayable from `events.jsonl`.

### P1-3: Token-budgeted capsule section
- **Contract:** the compiled capsule section (`# Skill Routing Contract` + native index + directive) must never exceed a bounded token cost on any prompt build. The budget is enforced by the builder, not by hope.
- **Mechanism:** add a `max_skill_capsule_bytes` to the prompt/budget configuration; `renderPromptCapsules` emits native entries in priority order until the budget is reached and appends a `… (N more native skills; call skill_info to inspect)` truncation marker rather than silently overflowing. This is the direct counter to the `.cursorrules` / unbounded-announcement failure mode. Tie into the token-minimal compiler (roadmap 02): the capsule section is part of `window_input_tokens` telemetry.
- **Test:** construct a registry with 200 native skills; assert the rendered capsule section stays under the byte budget and the truncation marker names the count of omitted skills.
- **Proof:** the capsule-section byte count is recorded as a typed diagnostic on `turn_started`, replayable after cold start; no prompt build can exceed the budget without the truncation marker.

### P2-1: Skill routing decision tree
- **Contract:** the model has a deterministic, prompt-resident rule for *when to call `skill_info`* versus proceed from the native summary alone. Today this is implicit in the directive prose; the contract makes it explicit and testable.
- **Mechanism:** replace the single directive line in `renderPromptCapsules` with a compact decision rule: (1) operator says "use <skill>" → `skill_info{name}`; (2) task matches a native summary's triggers AND the work is non-trivial → `skill_info{name}` for the protocol; (3) addon territory (docx, react-doctor, video) → `skill_info{query}` to discover; (4) no match → proceed with tools only. The rule is prose in the capsule section (not a tool), so it stays inside the compiled prompt envelope.
- **Test:** an eval-style fixture: given a prompt that clearly matches a native trigger, the rendered decision rule points at that skill; given a prompt with no skill signal, the rule says proceed with tools. (This is a prompt-construction test, not a model-behavior test — the contract is about what the prompt says, not what the model does.)
- **Proof:** the decision rule is part of the byte-for-byte capsule snapshot from P1-1; it is replayable and versioned with the registry.

### P2-2: Add-on discovery and provenance
- **Contract:** add-on skills are discoverable through `skill_info{include_addons=true}` with provenance (which root they come from), but never compiled into the prompt. The add-on list may grow at runtime (scanned skill roots) without inflating the native capsule section.
- **Mechanism:** today `addon_skills` is a static array. Allow a bounded, kernel-owned scan of configured skill roots (e.g. `%USERPROFILE%\.codex\skills`, `%USERPROFILE%\.claude\skills`) that populates the addon index used by `renderIndex`, while keeping `native_skills` compile-time-constant. Each addon entry records its discovered root for the `ROOT` line in the capsule. This borrows pi-mono's multi-source discovery without adopting its always-on XML announcement.
- **Test:** a workspace with a fake addon skill root produces an addon entry in `skill_info{query}` output with the correct `ROOT`, and the compiled capsule section is unchanged (byte-identical to the no-addon case).
- **Proof:** `skill_info` output and the capsule-section snapshot together prove addons are discoverable-but-not-compiled.

## North-star link

The north star (01) is many windows, each a shard, each a fresh context window carrying the least token mass. Skill routing is the discipline that decides what skill mass enters each shard. Unbounded skill announcement (Eve, pi-mono, Cursor) taxes every shard equally; VANTARI's tiered capsules + `skill_info` retrieval means a shard pays only for the native index (bounded, P1-3) plus the one protocol capsule its branch actually retrieved (P1-2). Cheaper skill mass per shard → more branches per token → the north star's economic engine holds. This theme also feeds roadmap 02 (token-minimal context: the capsule section is measured telemetry), roadmap 05 (tool governance: `skill_info` is a review-safe read-only tool), and roadmap 06 (parent-child delegation: child shards inherit the same bounded capsule contract).

## Definition of done
- Every native skill carries a non-empty `protocol` (the execution contract), enforced at compile time.
- `skill_info` is the single retrieval primitive; it fails closed on unknown names with an available-names hint and matches queries against the protocol field.
- The compiled capsule section is byte-bounded by a budget and emits a truncation marker rather than overflowing.
- Add-ons are discoverable via `skill_info` but never compiled into the system prompt.
- The capsule section, the decision rule, and the `skill_info` output are snapshot-tested and replayable from repository state.
- No second prompt-assembly surface, no sandbox-only skill channel, no raw-`read` escape hatch for skill bodies.
