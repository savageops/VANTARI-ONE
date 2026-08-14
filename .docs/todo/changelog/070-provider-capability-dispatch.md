---
type: changelog
id: changelog/070-provider-capability-dispatch
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/providers/{capability,dispatch}.zig
---

# Provider capability dispatch (Move 61)

The dead provider capability cache now has one live consumer. Dispatch resolves
the wire adapter, materializes its capability snapshot, and validates the
streaming, native tool, and context-overflow contract before provider I/O.
Unresolved `wire_api: auto` cannot reach an adapter; Responses capability is
reported only for the Responses-shaped route.

The slice stays small: no network preflight, model catalog, fallback chain,
provider registry, or second cache. Dynamic model metadata remains a separate
provider-parity boundary.

Debug and ReleaseFast pass `19/19` steps and `2,190/2,190` tests. The source
ReleaseFast build passes `9/9` at SHA-256
`9C54A17D903D4B51ACEE8AE4806C460F1B6AC59D04810185AD9C02A6F256DB89`.
Installed promotion remains deferred.
