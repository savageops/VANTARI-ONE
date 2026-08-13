---
id: 039
title: "Root interactive input and session-scoped access"
category: feature
status: source-complete
priority: high
created: 2026-08-13
---

# Root interactive input and session-scoped access

## Change

Full access is now immutable session state and is visible in the TUI footer as
`scope workspace` or `scope full`. The root model can call `ask_user` when a
decision materially changes the result. The tool emits bounded
`var1.input_requested.v1` data, the TUI reuses the existing input surface, and
`input/respond` resolves the host wait.

## YAGNI boundary

The slice does not add a question registry, poller, second status bus,
transcript copy, resolved-event family, or child input loop. Child profiles omit
the interactive tool and fail with `InputUnavailable`. The broker is process
local and keyed by session plus request id; cancellation, shutdown, and terminal
replay close pending state.

## Proof

- Debug: `19/19` steps, `2,023/2,023` tests.
- ReleaseFast/install: `9/9` steps.
- Built/installed SHA-256: `739F0D10D366738D01CEB3879D5B9487F7C99FB7CDB4D7FF9DB3418386A0DEED`.
- Installed health and root `tools --json` pass; `ask_user` is present with
  its bounded schema; exact proof-owned processes are zero after teardown.
- Source tests cover cross-session duplicate request ids, cancellation wake,
  empty answers, inline Other, terminal cleanup, and normalized choices.

Open proof boundary: provider-driven installed TUI response. The installed
catalog and source controller/broker proof do not claim that consumer path.
