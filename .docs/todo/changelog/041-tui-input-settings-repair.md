---
id: 041
parent: harness-capability-next-90
type: execution-unit
protocol_version: "3.0"
title: "TUI input and settings repair"
category: fix
status: done
priority: high
created: 2026-08-13
next_todo: Move 55 — generate the model-visible capability manifest
source_message_anchor: "shift-tab-settings-autocomplete"
source_message_excerpt: "shift tabbing doesnt work anymore. also, settings page freezes. ... have an autocomplete popover above the text input field ..."
source_message_proof_obligation: "Restore standard reverse navigation and settings visibility, then provide bounded bare-prefix command discovery through the existing command owner with installed proof and no parallel input system."
acceptance: "The installed TUI visibly opens settings, navigates sections forward and backward with terminal-standard keys, falls back to defaults for unavailable workspace config, and shows a bounded bare-prefix palette that dispatches through the existing command registry."
exit_criterion: "Canonical Debug, focused TUI, ReleaseFast/install, source-installed hash equality, live TUI smoke, and proof-owned process teardown all pass."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && .\\scripts\\zigw.ps1 build test --summary all && .\\scripts\\install_windows.ps1"
expected_exit_code: 0
expected_output_pattern: "Build Summary: 19/19 steps succeeded; 2101/2101 tests passed|source and installed SHA-256 match|process census was zero"
evidence: ".docs/research/2026-08-13-tui-input-command-palette.md; installed SHA-256 2851E4EBA24ED13A6A5DBBBB3F3A97392DEA0249B9D9C221F8936917734F8D2C; focused TUI 120/120; final installed process census zero."
dependencies: [Move 43, Move 44, Move 50, Move 52a, Move 54]
---

# TUI input and settings repair

## Change

- Settings now renders through the normal Vaxis `render`/flush boundary and
  falls back to compiled defaults when the workspace config is missing or
  invalid, keeping the overlay visible with a status message.
- Settings navigation follows the terminal convention: Tab/Right advances and
  Shift+Tab/Left reverses.
- The transient composer palette uses the executable `command_registry`,
  accepts bare first-token prefixes while retaining slash compatibility, and
  routes selection through the existing dispatch path. It disappears for prose
  or no matches and never appends suggestion rows to the transcript.
- Startup shows the three highest-value entry points: `help · settings · model`.

## Proof

- Focused TUI: `9/9` build steps; `120/120` tests passed.
- Full Debug: `19/19` build steps; `2,101/2,101` tests passed.
- ReleaseFast install completed; source and installed
  `C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe` SHA-256 both equal
  `2851E4EBA24ED13A6A5DBBBB3F3A97392DEA0249B9D9C221F8936917734F8D2C`.
- Installed smoke: bare `s`/`e` opened the palette, `settings` opened the
  overlay, Right then `CSI Z` moved `runtime → provider → runtime`, Escape
  closed it, and Ctrl+C exited. The proof-owned `execution-owner` and
  `kernel-stdio` processes were explicitly stopped; final installed process
  census was zero.

## Boundary

The palette remains a bounded first-token projection over the existing command
registry. A full keyboard navigation surface remains deferred until the current
palette proves insufficient; no second registry, poller, suggestion ledger, or
overlay event bus was introduced.
