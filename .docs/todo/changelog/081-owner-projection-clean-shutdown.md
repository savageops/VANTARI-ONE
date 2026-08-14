---
type: changelog
id: owner-projection-clean-shutdown
status: closed
updated: 2026-08-14
---

# Owner projection clean shutdown

`apps/backend/src/host/owner_state.zig` now owns exact identity comparison for
clean projection removal. `http_bridge.zig` calls it after listener drain and
removes `.var/runtime/execution-owner.json` only when generation, PID, port,
token, and workspace still match. A crash-stale or replaced projection is
preserved for fail-closed diagnosis.

Proof: the owner projection unit test rejects a mismatched generation and
removes the matching projection; the current source graph passes `19/19`
steps and `2,180/2,180` tests. The real-provider source smoke then accepted
authenticated owner shutdown and ended with zero exact source-path processes.
