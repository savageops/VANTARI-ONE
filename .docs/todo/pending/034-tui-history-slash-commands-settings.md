---
id: 034
title: "TUI: global persistent message history, slash command system, in-TUI settings panel"
category: feature
status: pending
priority: high
spec_status: approved
created: 2026-08-09
subtodo_start: 034a
subtodo_final: 034g
next_todo: /todo/pending/034a-tui-history-slash-commands-settings.md
---

# Parent: TUI History + Slash Commands + Settings Panel

## Original User Message Proof

**Source anchors (verbatim):**

1. *"the user message history needs to persist and combined globally, all sessions, and persistent. basically user mesages need to be recorded/kept, and can be stored in same manner as message history if not already done."*

2. *"We need to research and investigate 6 competitors how they handle forward slash commands. like manual compaction, goal loops, claude workflows, oh my pi specialists, etc. fan out and gather research using nsect."*

3. *"we also need a flag for settings, so we can configure the config json without leaving the TUI, and the TUI reveals ALL configs, setting new ones get added to the config json. (usually doesnt show in config unless custom). TUI reveals all and current setting. model, providers, hooks, prompts, personas, guardrails, etc. each setting having its own sub menu and templates. (guardrails can be enabled, disabled by defailt, new ones can be added/created, same with everyhing else too)"*

4. *"LEAVE THE CODE BETTER THAN YOU FOUND IT."*

## System Boundary

The TUI (`tui_chat.zig`, 3475 lines) is a libvaxis-based terminal interface with three regions: transcript, reasoning dock, composer footer. It communicates with the kernel via `stdio_rpc.LocalClient` (a subprocess `vantari kernel-stdio`). Three capabilities are missing:

1. **Global persistent user message history** — the current `appendHistory` (`tui_chat.zig:164-177`) is purely in-memory despite `architecture.md:562-564` claiming persistence. It resets every TUI restart. The user wants messages recorded globally across ALL sessions, stored durably, and available for recall via Up/Down navigation.

2. **Slash command system** — the only `/` handling today is a hardcoded `/exit`/`/quit` check (`tui_chat.zig:1166`). No command parsing, no command registry, no autocomplete. The 6-competitor research (Claude Code 90+ commands, Aider 30, Gemini 35+, Codex 40+, Copilot 60+, Cursor 24) identified the command canon (`/help`, `/clear`, `/compact`, `/model`, `/init`, `/permissions`, `/mcp`, `/quit`) plus VANTARI-unique commands (`/events`, `/spans`, `/replay`, `/contract`) that leverage the append-only event spine.

3. **In-TUI settings panel** — `config.json` is read-only at runtime. No `config/set` RPC method exists. The settings panel must reveal ALL config sections (runtime, provider, agent_routes, agents, context, prompts, draft, buffer, memory, environment) with sub-menus per section, showing current values + compiled defaults, and atomically writing changes that hot-load on the next turn.

**Canonical owners:** `tui_chat.zig` (TUI state/render/input), `sessions/store.zig` (durable storage patterns), `config/file.zig` (config read/validate/write), `fsutil.zig` (atomic writes, runtime root paths), `shared/protocol/types.zig` (RPC methods).

## Dependency Order and Risk Ordering

The three features share the TUI patch surface but have independent data flows. Sequence by dependency:
1. **History** first — smallest patch surface, pure storage + TUI wiring, no RPC needed. Fixes the doc/implementation discrepancy.
2. **Slash commands** second — needs a command dispatcher in the TUI event loop; some commands (`/settings`, `/model`) depend on the settings panel infrastructure. Ship the dispatcher + local-action commands first, then wire settings-dependent commands.
3. **Settings panel** last — largest patch surface: new RPC method, config write function, TUI overlay rendering. Depends on config/file.zig write capability and the slash command dispatcher for `/settings` entry.

## Research Program

**Completed (this session):**
- 6-competitor slash command harvest (Claude Code, Cursor, Codex CLI, Copilot CLI, Aider, Gemini CLI) — full command inventories, custom command formats, discovery UX, convergence canon, white space analysis.
- 6-competitor settings panel research (same 6 + Cline/Roo, OpenHands/Devin) — config surfaces, UX patterns, live application, presets/templates.
- TUI codebase map — every render function, state field, input handler, RPC method, config path, session store function with file:line references.

**Key findings that shape the plan:**
- History: `architecture.md` already documents persistence but code doesn't deliver it — this is a gap fix, not pure addition.
- Slash commands: the command canon is 8 commands present in 5+ competitors. VANTARI's unique commands (`/events`, `/spans`, `/replay`, `/contract`) leverage the event spine no competitor has.
- Settings: VANTARI already hot-loads config on next turn — the settings panel can write config.json atomically and the running kernel picks it up without restart. This is a competitive advantage to lean into.

## Architectural Improvement Targets (Chain Ratchet)

1. **Fix the history persistence lie** — `architecture.md` claims persistent history; code delivers in-memory only. This chain makes the code match the doc.
2. **Replace hardcoded `/exit` with a typed command registry** — eliminates the string-equality anti-pattern and opens extensibility.
3. **Add config write capability** — `config/file.zig` is read-only; this chain adds atomic validated writes, the missing primitive for self-tuning and settings.
4. **Unify config discovery** — the `_help` pattern already exists in `default.json`; the settings panel surfaces it as operator-visible documentation.

## Phase Plan

| Letter | Title | Patch Surface | Dependencies |
|--------|-------|---------------|--------------|
| a | Global persistent message history | `fsutil.zig`, `sessions/store.zig`, `tui_chat.zig` | none |
| b | Slash command dispatcher + local-action commands | `tui_chat.zig`, new `commands.zig` | a |
| c | Config write primitive | `config/file.zig`, new RPC method | none (parallel with a/b) |
| d | Settings panel TUI overlay | `tui_chat.zig`, new `settings_view.zig` | b, c |
| e | Settings-dependent slash commands (`/settings`, `/model`, `/effort`, `/persona`, `/agents`) | `tui_chat.zig`, `commands.zig` | b, d |
| f | Integration: command autocomplete, history search, `/help` with contracts | `tui_chat.zig`, `commands.zig` | b, e |
| g | Terminal review + QC | all files | a-f |

## Global Queue Alignment

Previous chain 033 (scheduler docs) is archived. Chain 021 (codex subscription auth) is in pending but touches auth/provider code, not TUI. No patch-surface overlap. This chain enters cleanly at 034.
