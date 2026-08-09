---
id: 034f
title: "Command autocomplete, history search, /help with contracts"
parent: 034
status: pending
priority: medium
blast_radius: low
category: feature
dependencies: [034b, 034e]
next_todo: /todo/pending/034g-tui-history-slash-commands-settings.md
source_message_anchor: discovery-ux
source_message_excerpt: "LEAVE THE CODE BETTER THAN YOU FOUND IT."
source_message_proof_obligation: Implements the discovery UX (autocomplete, search, contract help) that makes the command system and history usable without memorizing docs.
idempotency_contract: idempotent — autocomplete and search are read-only rendering.
---

## Execute Now

Add slash command autocomplete (type `/` → filtered command list), message history search (`Ctrl+R` or `/search`), and enrich `/help` with per-command contracts (parameters, effect class, category).

## Better-than-before

Every competitor with >30 commands has autocomplete (Claude Code, Codex, Gemini, Cursor). Without it, the operator must memorize commands. This slice makes the system self-discoverable — the hallmark of a polished tool. Also adds the VANTARI-unique `/contract <command>` that prints the typed command schema (no competitor has this).

## Entry State

- 034b has the command registry with names + descriptions
- 034e has the one-shot commands implemented
- 034a has persistent history
- No autocomplete, no search, no contract introspection exists

## Patch Surface

**Modifies:**
- `src/clients/tui_chat.zig` — add autocomplete rendering when input starts with `/`; add `Ctrl+R` reverse history search mode
- `src/clients/commands.zig` — add `Command.contract` field; enrich `/help` output with categories and contracts; add `/search` command

## Detailed Requirements

1. **Slash autocomplete** (`tui_chat.zig`):
   - When the composer input starts with `/`, render a filtered dropdown above the composer showing matching commands (name + description).
   - `Tab` completes to the first match (or selected match if navigating with `↑/↓`).
   - The dropdown filters live as the user types more characters.
   - Styled: command name in bold, description in dim, category tag in accent color.

2. **`Ctrl+R` reverse history search:**
   - Enters a search mode showing a prompt: `search: _`
   - As the user types, filters the global history (from 034a) and shows the most recent match.
   - `Ctrl+R` again cycles to older matches. `Enter` fills the composer with the match. `Esc` cancels.
   - This mirrors bash/shell reverse-incremental-search, which every power user expects.

3. **`/help [command]` enrichment** (`commands.zig`):
   - No args: grouped by category (session, model, config, help, agent), each command with name + one-line description. VANTARI-unique commands (`/events`, `/spans` when implemented) tagged.
   - With command arg: full contract — name, description, category, argument-hint, effect-class (read-only/local/mutating/model-prompt), usage example.

4. **`/contract <command>`** — VANTARI-unique command that prints the typed contract: parameter schema, effect class, category, whether it sends to the model or is local-only. No competitor has this. This is the "command catalog with typed metadata" white space from the research.

5. **`/search <query>`** — search global message history by substring. Shows matching entries with timestamps. `Enter` on a result fills the composer.

## Rollback Procedure

Remove autocomplete rendering, Ctrl+R handler, `/contract`, `/search`. Commands still work via manual typing.

## Exit State / Handoff Contract

- Autocomplete dropdown renders when typing `/`
- `Ctrl+R` enters reverse history search
- `/help` shows grouped commands with categories
- `/contract` prints typed command metadata
- `/search` searches global history
- Next unit (034g) is the terminal review

## Validation

```bash
zig build test
```

**New tests:**
- `test "autocomplete filters commands by prefix"`
- `test "Tab completes to first match"`
- `test "Ctrl+R enters search mode"`
- `test "reverse search cycles older matches on repeated Ctrl+R"`
- `test "/help groups commands by category"`
- `test "/help <command> shows full contract"`
- `test "/contract prints typed metadata"`
- `test "/search finds substring in history"`
