---
type: changelog
id: changelog/043-chat-log-level-and-mode-routing
status: source-complete
date: 2026-08-13
owner: apps/backend/src/core/config/file.zig
---

# Chat log posture and prompt-mode route selection

## Shipped in source

- Added validated `runtime.log_level` with `silent` default, `normal`, and
  `full` postures. The setting changes prompt guidance and TUI projection only;
  durable events, messages, and recovery ledgers remain complete.
- Added settings-cycle behavior and JSON string serialization for string
  settings, covering the prior config/set quoting defect.
- Added `agent_routes.prompt_modes` for `orchestrate`, `build`, `align`, and
  `plan`. It reuses `AgentRouteOverride`; explicit `session/send` provider/model
  fields win, and credentials remain in the auth ledger.
- Preserved the existing TUI coalescing/backpressure path: 16 ms minimum frame
  cadence, 100 ms adaptive ceiling, bounded notification bursts, and
  demand-driven sequence repair.

## Evidence

- `.\scripts\zigw.ps1 build test --summary all` — Debug `19/19` steps,
  `2,119/2,119` tests passed.
- Focused TUI source lane — `9/9` steps, `123/123` tests passed.
- `git diff --check` — no whitespace errors.

## Boundary

Installed promotion is intentionally deferred by the operator. No installed
hash, live-binary, or process-cleanup claim belongs to this source-only slice.
Anthropic/OpenCode OAuth, runtime theme tokens, and meaningful menu-position
variants remain explicit follow-on capability gaps; inert config keys were not
added.
