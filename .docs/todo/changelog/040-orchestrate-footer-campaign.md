---
id: 040
title: "Orchestrate footer campaign sweep"
category: feature
status: done
priority: medium
created: 2026-08-13
---

# Orchestrate footer campaign sweep

## Change

Added `apps/backend/src/clients/footer_effects.zig` as the small campaign
owner for bottom-row motion. The default campaign sweeps the `orchestrate`
token immediately on selection, repeats every 3,000 ms, runs at an 80 ms frame
cadence for 900 ms, and uses VANTARI mint/green styles. The sweep now uses a
quintic smootherstep with zero velocity and acceleration at both endpoints,
plus symmetric low-contrast outer shoulders on both sides of the accent. The
middle edge is no longer bold, so the label settles without a hard visual
stop. `build`, `align`, and `plan` remain static.

`apps/backend/src/clients/tui_chat.zig` keeps the existing footer formatter and
event loop. The renderer now emits styled terminal segments for the mode token;
the UI loop supplies timed wakes only when the campaign is visible. There is no
new event spine, thread, provider path, or settings registry.

## Harvested patterns

- Codex: bounded frame scheduling behind an animation-enabled surface.
- oh-my-pi: interval-driven motion with a fixed-height render boundary.
- pi-mono: replaceable working-indicator configuration without a second runtime.
- DiaText: eased repeated sweep translated from web gradient text to terminal
  codepoint segments.

## Proof

Focused TUI proof is green: `117/117` tests passed through
`apps/backend/scripts/zigw.ps1 build test-tui --summary all`.

Full Debug proof is green: `19/19` build steps and `2,095/2,095` tests passed.
ReleaseFast/install is green at `9/9` steps. Source and installed
`vantari.exe` SHA-256 both equal
`5A38A17C7B6C4F0A9966E678C41025089E62E7DF8F26ACA319AB82F653DCA318`.
Installed provider/model selector, settings, and `health --json` probes passed;
the owner shutdown was accepted and the final installed-process census was
zero.
