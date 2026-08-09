---
id: 034e
title: "Settings-dependent slash commands (/model, /effort, /persona, /agents)"
parent: 034
status: pending
priority: high
blast_radius: medium
category: feature
dependencies: [034b, 034d]
next_todo: /todo/pending/034f-tui-history-slash-commands-settings.md
source_message_anchor: one-shot-commands
source_message_excerpt: "model, providers, hooks, prompts, personas, guardrails, etc. each setting having its own sub menu"
source_message_proof_obligation: Implements the high-frequency one-shot slash commands that act as shortcuts into the settings panel leaves.
idempotency_contract: idempotent — each command reads current config, mutates one key, writes atomically.
---

## Execute Now

Implement the one-shot slash commands (`/model`, `/effort`, `/persona`, `/agents`) that bypass the settings panel for high-frequency config switches, writing directly via `config/set` RPC.

## Better-than-before

The 6-competitor research found that every top agent has one-shot commands for model switching (Claude `/model`, Aider `/model`, Gemini `/model`, Cursor `/model`). Forcing users to navigate a menu for model switching is a UX failure. This slice gives VANTARI the one-shot pattern while the settings panel (034d) remains the discovery surface.

## Entry State

- 034b registered these commands as stubs returning "coming in 034e"
- 034c provides `config/set` RPC
- 034d provides the settings panel infrastructure and `SettingsState`

## Patch Surface

**Modifies:**
- `src/clients/commands.zig` — replace stubs with real implementations

## Detailed Requirements

1. **`/model [model]`** — switch active model. No args: show current model + list available (from `models/list` RPC). With arg: call `config/set {section: "runtime", key: "openai_model", value: "<model>"}`. Confirmation message in transcript: "Model set to `<model>`. Applies on next turn."

2. **`/effort [level]`** — set reasoning effort. No args: show current + levels (low/medium/high/max). With arg: `config/set {section: "runtime", key: "effort", value: "<level>"}`. Validation: reject invalid levels.

3. **`/persona [text]`** — set prompts.persona inline. No args: show current persona text. With arg: `config/set {section: "prompts", key: "persona", value: "<text>"}`. With `--clear`: set to null (revert to default). This lets the operator reshape VAR1's voice without opening settings.

4. **`/agents`** — list specialist personas from config (enabled/disabled, name, route_role). With `--enable <id>` / `--disable <id>`: toggle. With `--edit <id>`: open settings panel to that agent's sub-menu.

5. **`/context`** — read-only: show context window pressure (session tokens, compaction threshold, checkpoint count). Calls `session/get` RPC for current state. This is the "inline status reflection" from the research.

6. **All commands** print a one-line confirmation to the transcript on success, or an error message on failure. None of them send a message to the model — they are pure local actions that write config.

## Rollback Procedure

Revert the command implementations to stubs in `commands.zig`.

## Exit State / Handoff Contract

- `/model`, `/effort`, `/persona`, `/agents`, `/context` are fully implemented
- Each writes via `config/set` and shows confirmation
- Next unit (034f) adds autocomplete and `/help` with contracts

## Validation

```bash
zig build test
```

**New tests:**
- `test "/model sets runtime.openai_model via config/set"`
- `test "/effort rejects invalid level"`
- `test "/persona sets prompts.persona inline"`
- `test "/persona --clear sets to null"`
- `test "/agents lists specialist personas"`
- `test "/agents --enable toggles enabled flag"`
- `test "/context shows context pressure read-only"`
- `test "all commands print confirmation to transcript"`
