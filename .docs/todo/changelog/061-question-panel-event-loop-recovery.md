---
type: changelog
id: changelog/061-question-panel-event-loop-recovery
status: source-complete
date: 2026-08-14
owner: apps/backend/src/clients/tui_chat.zig
---

# Question panel event-loop recovery

## Change

Contained question-controller and `input/respond` failures at one shared
`ChatState.handleQuestionKey` boundary. The idle TUI loop and streaming-turn
loop no longer let a recoverable question error unwind the process. The existing
settings-style horizontal question panel, review/submit state, and single
`input/respond` path remain unchanged.

## Proof

- Focused TUI Debug: `9/9` steps, `135/135` tests.
- Focused TUI ReleaseFast: `9/9` steps, `135/135` tests.
- Full Debug: `19/19` steps, `2,165/2,165` tests.
- Source ReleaseFast: `9/9` steps.
- Source SHA-256: `D22A6E617DEF01BDF323F4F4500C1F53AD54C1221CFE6A8A6413FCA6D7D1EDFE`.

## Boundary

The live installed owner was preserved at
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Installed promotion and provider-driven question response remain deferred.
