---
type: changelog
id: changelog/052-question-panel-input-lifecycle
status: source-complete
date: 2026-08-14
owner: apps/backend/src/clients/tui_chat.zig
---

# Question panel input lifecycle correction

## Change

Closed the stale `question_view.State` boundary without adding a second input
transport or overlay owner. Missing session ownership, send failure, terminal
replay, and already-settled turns now clear the projection. Active Ctrl-C uses
the existing `input/respond` cancellation route.

## Proof

- Focused TUI Debug: `9/9` steps, `133/133` tests.
- Focused TUI ReleaseFast: `9/9` steps, `133/133` tests.
- Full Debug: `19/19` steps, `2,153/2,153` tests.
- Source ReleaseFast binary: `9/9` steps.
- Source SHA-256: `C53933B5259D5DE88447B431B01F5F2B123A3935DDBFB13F51A2A739CAFEE573`.

## Boundary

Installed promotion and provider-driven live question proof remain deferred by
the operator boundary. The installed owner was preserved and not replaced.
