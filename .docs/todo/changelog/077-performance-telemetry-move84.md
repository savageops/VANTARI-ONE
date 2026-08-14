---
type: changelog
id: changelog/077-performance-telemetry-move84
status: closed
updated: 2026-08-14
---

# Move 84 — delete unconnected performance telemetry

## Result

Deleted the `CounterRegister`, its evaluation export, and the
`VAR1 stats` help/dispatch surface. The old command token remains a narrow
unknown-command guard, so it cannot fall through as a provider prompt.

## Changed owners

- `apps/backend/src/core/evaluation/telemetry.zig` — deleted.
- `apps/backend/src/core/evaluation/index.zig` — removed the dead export.
- `apps/backend/src/clients/cli.zig` — removed zero-valued stats output and
  help advertisement; retained the retired-command guard.
- `AGENTS.md` — moved local performance counters behind a measured-owner
  reopen gate.

## Proof

- `ix search 'lit:CounterRegister' apps/backend/src apps/backend/tests` found
  only the empty CLI construction and unit-test implementation; no production
  `record` caller existed.
- Source validation passed: `19/19` build steps and `2,184/2,184` tests.
- Current source ReleaseFast hash:
  `A1337ABC29728EAB78AB27BAA042227BEF62FEC295288B29400D822757C3F8FE`.
- Source `vantari.exe stats` and `vantari.exe help stats` both returned
  `unknown command 'stats'` with exit code `2`; no provider dispatch occurred.

## Reopen gate

Reopen only after a measured bottleneck names one canonical runtime owner, an
explicit operator consumer, and a durable readback path. Installed promotion
remains separate and is not claimed.
