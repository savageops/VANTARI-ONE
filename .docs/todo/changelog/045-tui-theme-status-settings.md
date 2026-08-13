---
type: changelog
id: changelog/045-tui-theme-status-settings
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/config/file.zig; apps/backend/src/clients/tui_chat.zig
---

# Saved TUI theme and status placement

## Shipped in source

- `core/config/file.zig::TuiPolicy` owns the finite renderer configuration:
  `theme` (`vantari`, `midnight`, `high_contrast`, `amber`) and
  `status_bar_position` (`bottom`, `top`). The defaults are `vantari` and
  `bottom`; invalid values fail config validation.
- The settings overlay exposes both values through the existing `config/set`
  path. A successful save marks the state changed and the active TUI reloads
  the policy without restarting or adding a second settings owner.
- `tui_chat.zig` owns four complete palettes and applies them to the existing
  renderer tokens. Each palette keeps transcript surface < metadata surface <
  focused composer surface. Moving the status row to the top reserves one row
  while keeping the composer at the bottom.
- The stream loop is unchanged: policy reads happen at startup and after a
  settings mutation, not once per frame. Existing coalescing, adaptive frame
  cadence, bounded notification bursts, and demand-driven replay repair remain
  the responsiveness path.

## Evidence

- `scripts/zigw.ps1 build test-tui --summary all` — `9/9` steps,
  `126/126` tests passed.
- `scripts/zigw.ps1 build test --summary all` — `19/19` steps,
  `2,129/2,129` tests passed.
- `scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` — source
  ReleaseFast `9/9` succeeded; `zig-out/bin/vantari.exe` SHA-256 is
  `94B9049D97FCE35CCAC365916CC13D04452AF7A70BEA2BF23A11A0F89D7CA837`.
- `git diff --check` is required before the owned source commit. No live
  installed binary or installed process-cleanup claim belongs to this slice.

## Boundary

Arbitrary per-cell color maps, user-authored theme files, and a menu/layout
registry remain deferred until a real renderer consumer or measured operator
need justifies them. Codex OAuth is shipped; Anthropic/OpenCode OAuth remain
provider-owned parity work and are not changed by this slice. Move 58 still
owns canonical eval process supervision.
