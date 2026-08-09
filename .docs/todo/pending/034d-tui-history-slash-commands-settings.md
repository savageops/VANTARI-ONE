---
id: 034d
title: "Settings panel TUI overlay"
parent: 034
status: pending
priority: high
blast_radius: high
category: feature
dependencies: [034b, 034c]
next_todo: /todo/pending/034e-tui-history-slash-commands-settings.md
source_message_anchor: settings-submenus
source_message_excerpt: "each setting having its own sub menu and templates. (guardrails can be enabled, disabled by defailt, new ones can be added/created, same with everyhing else too)"
source_message_proof_obligation: Implements the in-TUI settings overlay that reveals ALL config sections with sub-menus, current values, and the ability to edit/add entries via config/set RPC.
idempotency_contract: idempotent — settings panel reads config fresh on open; edits are atomic writes.
---

## Execute Now

Add a full-screen settings overlay to the TUI that renders when `settings_open` is true, organized by config section (runtime, provider, agents, context, prompts, draft, buffer, memory, environment), each navigable with a sub-menu showing current value, compiled default, `_help` text, and inline editing.

## Better-than-before

VANTARI has the largest config surface of any competitor (10 sections, 7 agent personas, per-role routing, draft+buffer layers) but no way to view or edit it in-app. After this slice, the operator can configure the entire system without leaving the TUI — a competitive advantage since VANTARI already hot-loads config on the next turn (no restart needed, unlike Gemini CLI which requires restart for some keys).

## Entry State

- 034b provides the slash command dispatcher (`/settings` registered as stub)
- 034c provides `config/set` RPC + `writeConfigKey`
- `tui_chat.zig` has no overlay/modal system — only three fixed regions (transcript, dock, footer)
- `config/default.json` has `_help` objects for every section — these become in-panel tooltips
- The settings panel research identified the three-tier pattern: master view + per-section sub-menus + inline status

## Patch Surface

**Adds:**
- `src/clients/settings_view.zig` — new module: `SettingsState`, `drawSettings`, `SettingsSection`, `SettingsEntry`, navigation + editing logic

**Modifies:**
- `src/clients/tui_chat.zig` — add `settings_state: ?SettingsState` to `ChatState`; render settings overlay when active; route keys to settings navigation when open; `/settings` command (from 034b stub) opens the overlay

## Detailed Requirements

1. **`SettingsState`** (`settings_view.zig`):
   ```zig
   pub const SettingsSection = enum {
       runtime, provider, agent_routes, agents, context,
       prompts, draft, buffer, memory, environment,
   };

   pub const SettingsState = struct {
       open: bool = false,
       section_cursor: usize = 0,     // which top-level section is highlighted
       entry_cursor: usize = 0,       // which key within the section
       editing: bool = false,         // is the current entry being edited?
       edit_buffer: []u8 = &.{},      // inline edit buffer
       sections: [][]const u8,        // section names for rendering
       // Loaded config document for display
       config_doc: std.json.Value,
   };
   ```

2. **Layout** (`drawSettings`):
   ```
   ┌─ Settings ──────────────────────────────────────┐
   │ runtime > provider > agents > context > prompts │  ← section tabs
   ├─────────────────────────────────────────────────┤
   │ runtime                                         │
   │   max_steps            [4096]                   │
   │   max_tool_calls_per_turn [16]                  │
   │   effort              [high]                    │
   │   temperature         [0.7]                     │
   │                                                 │
   │ ←/→ switch section  ↑/↓ navigate  Enter edit   │
   │ Esc close  Tab next section  ? help             │
   └─────────────────────────────────────────────────┘
   ```
   - Left panel: section list (10 sections). Right panel: keys for selected section.
   - Each key shows: name, current value, (default value in dim if different), `_help` text on the line below.
   - Editing mode: inline text input that replaces the value. On Enter, calls `config/set` RPC. On Esc, cancels.

3. **Section-specific sub-menus:**
   - **agents** — sub-menu per specialist persona (general, recon, planner, compactor, implementer, reviewer, validator). Each shows: enabled, description, when_to_use, route_role, max_steps, max_tool_calls, max_children, output_contract. Editable inline. "Create new" option at the bottom.
   - **prompts** — persona (text edit), guardrails (text edit, null=disabled), user_context (text edit), system_prompt_file, developer_prompt_file.
   - **agent_routes** — max_concurrency + per-role overrides (7 roles × provider/model/wire_api/thinking_mode/effort/temperature).
   - **draft/buffer** — enabled toggle + model/provider/effort/temperature.

4. **Key handling** (when `settings_state.open`):
   - `←/→` or `Tab` — switch section
   - `↑/↓` — navigate entries
   - `Enter` — enter edit mode (or toggle for bools)
   - `Enter` in edit mode — save via `config/set` RPC, show success/error
   - `Esc` — cancel edit, or close panel if not editing
   - `?` — show help text for current entry
   - `n` — create new entry (for agents/guardrails sections)

5. **TUI integration** (`tui_chat.zig`):
   - In `draw`, if `state.settings_state != null and state.settings_state.?.open`, render `drawSettings` as a full-screen overlay instead of the normal transcript+footer.
   - In the key handler, if settings is open, route to `settings_view.handleKey` instead of the composer.
   - The `/settings` command (from 034b) sets `state.settings_state = SettingsState.init(allocator, workspace_root)` and `open = true`.

6. **Create-new flow** (agents section): pressing `n` in the agents section opens a template form: id, extends (dropdown of built-in agents), description, when_to_use, route_role. On save, calls `addConfigSectionKey` RPC. This fulfills "new ones can be added/created."

7. **Guardrail create/enable/disable**: in the prompts section, guardrails is a text field. If null (disabled), show "[disabled] — press Enter to add". If set, show the text with an option to disable (set to null) or edit. This fulfills "guardrails can be enabled, disabled by default, new ones can be added."

## Rollback Procedure

Remove `settings_view.zig`, revert `tui_chat.zig` settings overlay fields and rendering. The `/settings` command reverts to the stub. No config.json changes are lost (writes are independent).

## Exit State / Handoff Contract

- `settings_view.zig` exists with `SettingsState`, `drawSettings`, `handleKey`
- `tui_chat.zig` renders the overlay when active and routes keys correctly
- `/settings` opens the panel; Esc closes it
- All 10 config sections are navigable with current values + help text
- Inline editing writes via `config/set` RPC and shows success/error
- Agents section supports create-new; prompts section supports guardrail enable/disable
- Next unit (034e) wires the one-shot commands (`/model`, `/effort`, `/persona`)

## Validation

```bash
zig build test
```

**New tests:**
- `test "SettingsState init loads config document"`
- `test "section cursor navigates across 10 sections"`
- `test "entry cursor navigates within a section"`
- `test "edit mode enters on Enter, exits on Esc"`
- `test "bool toggle flips value and writes via config/set"`
- `test "text edit saves string value via config/set"`
- `test "create new agent adds to agents.definitions"`
- `test "guardrail enable/disable toggles null to text"`
- `test "help text displays from _help field"`
- `test "Esc closes the settings overlay"`

**Manual proof:** Type `/settings` → see all 10 sections → navigate to runtime → edit effort to "max" → Enter → see success → Esc → type a message → the next turn uses max effort.
