---
type: documentation-index
id: docs/index
status: current
updated: 2026-08-12
---

# VANTARI documentation index

This directory contains project records, research, planning chains, and completed-work evidence. Runtime truth remains in `.var/`; source ownership remains in `apps/backend/src/`.

## Start here

| Record | Purpose |
|---|---|
| [`technical_summary.md`](technical_summary.md) | Current runtime owners, ticket/pool flow, TUI projection, and proof boundary |
| [`workspace.json`](workspace.json) | Machine-readable coordination record |
| [`log.txt`](log.txt) | Append-only project log; logger-owned |
| [`research/`](research/) | Source-backed research and product implications |
| [`todo/findings/00-INDEX.md`](todo/findings/00-INDEX.md) | Current priority-ordered harness readiness findings |
| [`todo/pending/`](todo/pending/) | Active planning-spec chains |
| [`todo/changelog/`](todo/changelog/) | Completed chain units with evidence |
| [`todo/changelog/_log.md`](todo/changelog/_log.md) | Completed-work index and closeout receipts |
| [`handoff/`](handoff/) | Cold-start handoffs and continuity records |
| [`roadmap/24-harness-capability-next-90.md`](roadmap/24-harness-capability-next-90.md) | Current value-ranked execution order for the next 90 harness moves |
| [`roadmap/21-persistent-execution-owner.md`](roadmap/21-persistent-execution-owner.md) | Current owner-lifecycle decision, source proof, and installed promotion boundary |

## Current capability records

- [`research/2026-08-12-full-harness-sitrep.md`](research/2026-08-12-full-harness-sitrep.md) — full design, owner, pipeline, method, proof, competitive harvest, readiness concerns, and WIP accountability.
- [`todo/findings/00-INDEX.md`](todo/findings/00-INDEX.md) — executable P0/P1/P2 closure order; current authority over older completion claims.
- [`roadmap/24-harness-capability-next-90.md`](roadmap/24-harness-capability-next-90.md) — 90 dependency-ordered moves ranked by operator value, capability leverage, integrity risk, and friction removed.
- [`roadmap/21-persistent-execution-owner.md`](roadmap/21-persistent-execution-owner.md) — source-complete single-owner lifecycle: reconnect, duplicate exclusion, graceful/crash recovery, process cleanup, and blocked installed gate.
- [`roadmap/20-adversarial-concurrency-mesh.md`](roadmap/20-adversarial-concurrency-mesh.md) — closed six-seam 100-way contention mesh with exact ledger, replay, and shutdown evidence and no new harness.
- [`roadmap/19-single-terminal-event.md`](roadmap/19-single-terminal-event.md) — closed single-settlement contract, seven-source harvest, generation binding, cold-start validation, and installed Windows proof.
- [`roadmap/18-generation-bound-cancellation.md`](roadmap/18-generation-bound-cancellation.md) — closed exact-run cancellation contract, seven-source harvest, stale-generation race, and installed Windows proof.
- [`roadmap/17-byte-level-session-integrity.md`](roadmap/17-byte-level-session-integrity.md) — closed valid-prefix and poisoned-tail append contract, six-source storage harvest, installed proof, and reversible production-state reconciliation.
- [`research/2026-08-09-tui-status-surface-and-repair-loop.md`](research/2026-08-09-tui-status-surface-and-repair-loop.md) — compact TUI telemetry, durable summary projection, and repair-loop boundary.
- [`research/2026-08-10-ticket-agent-pool-and-repair-queue.md`](research/2026-08-10-ticket-agent-pool-and-repair-queue.md) — buffered ticket admission, fixed agent capacity, leases, and stale-owner repair.
- Runtime access boundary — `runtime.full_access_mode` is default-off, validated, and projected through one shared path resolver; the technical owner is recorded in [`technical_summary.md`](technical_summary.md) and [`workspace.json`](workspace.json).
- [`todo/changelog/036g-ticket-agent-pool-and-repair.md`](todo/changelog/036g-ticket-agent-pool-and-repair.md) — historical ticket/pool closeout receipt. The 2026-08-12 audit supersedes its production-complete conclusion: owner-crash recovery, durable agent messaging, installed parity, and remaining multi-process writer proof remain open. Moves 21–24 now close presentation persistence, scheduler leadership, and ticket admission in source.

Historical or nested archival records remain in place. Do not treat them as the current owner when a source module or this index names a newer contract.
