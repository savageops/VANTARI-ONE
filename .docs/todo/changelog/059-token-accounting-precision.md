---
type: changelog
id: changelog/059-token-accounting-precision
status: source-complete
updated: 2026-08-14
owner: apps/backend/src/shared/types.zig + apps/backend/src/shared/protocol/events.zig + apps/backend/src/core/executor/turn_payload.zig + apps/backend/src/clients/{commands,tui_chat}.zig
---

# Move 68 — exact, estimated, and unknown token accounting

`TokenPrecision` now travels through the existing `turn_started` and
`turn_terminal` event contracts. Provider usage with non-zero evidence is
`exact`; compiler context arithmetic is `estimated`; omitted usage is
`unknown`. The TUI footer marks estimated context with `~` and refuses to
render a numeric used/remaining value when precision is unknown. `/status`
suppresses cumulative token/cost totals after an unaccounted completed turn.

The slice reuses `Usage`, the terminal payload builder, the existing event
serializer, and the existing TUI read model. No provider file, telemetry
registry, poller, event family, or second ledger was added.

Proof: Debug `19/19`, `2,159/2,159`; source ReleaseFast `9/9`; source SHA-256
`41C90C2BDF0CB6350E9056EC361E8280FB8EF423AC941A8F4015B88B71695E15`.
Installed promotion is deferred by policy.
