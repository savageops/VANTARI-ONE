---
type: changelog
id: changelog/051-question-panel-runtime-contract
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/tools/runtime.zig; apps/backend/src/clients/tui_chat.zig
---

# Question panel runtime contract

## Shipped in source

- Root normal, root-agent, and orchestrator-only catalogs now expose the
  existing bounded `ask_user` capability. The orchestrator gate permits that
  interaction without granting artifact or command tools.
- The existing settings-style question panel remains the one controller for
  `orchestrate`, `build`, `align`, and `plan`; no second dialog, event bus, or
  prompt-mode executor branch was added.
- A regression test drives `input_requested` through `ChatState`, the question
  view, Vaxis rendering, and flush for all four prompt modes.

## Evidence and boundary

- Focused TUI: `132/132` tests passed.
- Full Debug: `19/19` steps, `2,151/2,151` tests passed.
- Source ReleaseFast: `9/9` steps; SHA-256
  `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
- Installed promotion and provider-driven installed response remain deferred
  by the explicit operator boundary. Research:
  `.docs/research/2026-08-14-question-panel-runtime-contract.md`.
