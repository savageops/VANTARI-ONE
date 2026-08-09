---
id: 034b
title: "Slash command dispatcher + local-action commands"
parent: 034
status: pending
priority: high
blast_radius: medium
category: feature
dependencies: [034a]
next_todo: /todo/pending/034c-tui-history-slash-commands-settings.md
source_message_anchor: slash-commands
source_message_excerpt: "We need to research and investigate 6 competitors how they handle forward slash commands"
source_message_proof_obligation: Implements the slash command system that intercepts /-prefixed input before message submission, dispatching to registered local-action commands.
idempotency_contract: idempotent — command dispatch is pure routing; commands themselves declare their own idempotency.
---

## Execute Now

Create a typed slash command registry that intercepts `/`-prefixed input in the TUI event loop, dispatches to registered commands (local-action first), and replaces the hardcoded `/exit`/`/quit` check.

## Better-than-before

Replaces the `std.mem.eql(u8, prompt, "/exit")` string-equality anti-pattern with a typed command registry. Opens extensibility for 034e (settings commands) and 034f (autocomplete). Every competitor has this; VANTARI's version will be simpler (no SKILL.md files needed for built-in commands) and leverage the event spine for VANTARI-unique commands.

## Entry State

- `tui_chat.zig:1166` has a hardcoded `/exit`/`/quit` check
- No command parsing, registry, or autocomplete exists
- The 6-competitor research identified the command canon: `/help`, `/clear`, `/compact`, `/model`, `/exit`, `/status`, `/agents`, `/tasks`

## Patch Surface

**Adds:**
- `src/clients/commands.zig` — new module: `Command`, `CommandRegistry`, `CommandResult`, built-in command definitions, `dispatch` function

**Modifies:**
- `src/clients/tui_chat.zig` — replace the `/exit` check with `commands.dispatch(state, prompt)`; add command result rendering (local output to transcript or status line)

## Detailed Requirements

1. **`Command` struct** (`commands.zig`):
   ```zig
   pub const CommandResult = enum { handled, not_a_command, pass_to_model };

   pub const Command = struct {
       name: []const u8,           // "help", "clear", "exit"
       description: []const u8,    // one-line help text
       category: CommandCategory,  // .session, .model, .config, .help, .agent
       execute: *const fn(
           state: *ChatState,
           args: []const u8,
       ) anyerror!CommandResult,
   };
   ```

2. **Built-in local-action commands (phase 1):**
   - `/help [command]` — list all commands with descriptions; per-command detail
   - `/clear` — reset transcript (local action, no model call)
   - `/exit`, `/quit` — break the event loop (replaces the hardcoded check)
   - `/status` — print workspace, model, session id, version to transcript
   - `/history` — show recent global message history (from 034a)
   - `/compact [focus]` — send a compact request to the kernel via existing `session/compact` RPC
   - `/cancel` — cancel the current turn (equivalent to existing Ctrl-C during a turn)

3. **Dispatch flow** (`commands.zig`):
   ```
   fn dispatch(state, input) CommandResult:
     if not input starts with "/": return .not_a_command
     parse command_name = first token after "/"
     parse args = remainder
     find command in registry by name (exact match first, then prefix match)
     if found: return command.execute(state, args)
     if not found: show "Unknown command: /<name>. Type /help for available commands." return .handled
   ```

4. **TUI integration** (`tui_chat.zig`):
   - In the Enter handler (line 1162-1169), after trim, call `commands.dispatch`. If `.handled`, clear input and continue (don't submit). If `.not_a_command` or `.pass_to_model`, proceed to `state.submit`.
   - During an active turn (`drainUiEventsDuringTurn`), most commands should be no-ops except `/cancel` and `/status`.

5. **Command categories** (for `/help` grouping and future autocomplete coloring):
   - `.session` — clear, exit, compact, cancel
   - `.model` — model, effort (stubbed in 034b, implemented in 034e)
   - `.config` — settings (stubbed in 034b, implemented in 034e)
   - `.help` — help, status, history
   - `.agent` — agents, tasks, subtask (stubbed)

## Rollback Procedure

Remove `commands.zig`, restore the hardcoded `/exit`/`/quit` check in `tui_chat.zig`.

## Exit State / Handoff Contract

- `commands.zig` exists with `Command`, `CommandRegistry`, `dispatch`, and 6 local-action commands
- `tui_chat.zig` routes `/`-prefixed input through the dispatcher
- Hardcoded `/exit` check is removed
- `/settings`, `/model`, `/effort`, `/persona` are registered as stubs (return "coming in 034e") — their implementation depends on 034d

## Validation

```bash
zig build test
```

**New tests:**
- `test "dispatch returns not_a_command for non-slash input"`
- `test "dispatch routes /help to help command"`
- `test "dispatch routes /exit to exit command"`
- `test "unknown command shows error message"`
- `test "command args are parsed correctly"`
- `test "/clear resets transcript"`
- `test "/status prints workspace model session"`

**Manual proof:** Type `/help` → see command list. Type `/unknown` → see error. Type `/exit` → TUI exits.
