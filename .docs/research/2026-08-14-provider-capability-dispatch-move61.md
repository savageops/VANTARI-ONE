---
type: research
id: provider-capability-dispatch-move61-2026-08-14
status: current
owner: apps/backend/src/core/providers/{capability,dispatch}.zig
---

# Provider capability dispatch — Move 61

## Recon

`core/providers/capability.zig` already defined a fixed fail-closed
`CapabilityCache`, but no live adapter or dispatch owner used it. The result was
dead capability metadata: the provider loop could reach an adapter without a
pre-dispatch contract for streaming, native tool calling, Responses shape, or
context-overflow classification.

The tracked references confirm the boundary. Codex selects one explicit wire
API before execution. pi-mono keeps provider compatibility flags with the
adapter/model contract, including tool and usage compatibility. oh-my-pi
exposes capability metadata from concrete provider behavior rather than from a
brand-name heuristic. None requires a network preflight on every turn.

## Decision

`capability.zig::probe` is the sole adapter capability owner. It materializes a
fixed snapshot after `dispatch.zig` resolves `wire_api` and before provider I/O:

- all current adapters prove streaming, native tool serialization, and bounded
  context-overflow classification;
- only the Responses adapter proves `responses_api`;
- unresolved `.auto` input fails with `UnknownWireApi` before dispatch;
- dynamic remote model metadata and durable model catalogs remain separate
  provider-parity work.

The snapshot is deliberately local and allocation-free. No network probe,
provider registry, per-turn fallback, or second cache was added. A future
adapter must add its contract to this owner before it can dispatch.

## Proof

- Debug: `19/19` steps, `2,190/2,190` tests.
- ReleaseFast: `19/19` steps, `2,190/2,190` tests.
- Source ReleaseFast build: `9/9`, SHA-256
  `9C54A17D903D4B51ACEE8AE4806C460F1B6AC59D04810185AD9C02A6F256DB89`.
- Installed promotion remains deferred.
