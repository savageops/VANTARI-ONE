---
type: findings-index
id: harness-readiness-findings
status: live
updated: 2026-08-12
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Harness readiness findings

This ledger converts the full-harness SITREP into executable work. Closed work
owns request lifetime, test roots, summary/message sequencing, exact event
transport and TUI replay, one valid-prefix ledger contract, and generation-bound
cancellation. Move 21 is source-complete: one project-local execution owner now
survives presentation detach and excludes duplicate starts. Finding 11 remains
open for owner-crash reconciliation, inter-process scheduler/ticket claims,
durable agent messaging, installed proof, and multi-process writer authority.

[`../../roadmap/24-harness-capability-next-90.md`](../../roadmap/24-harness-capability-next-90.md) expands this ledger into the current 90-move execution order. This findings index remains the immediate P0/P1/P2 authority; roadmap 24 sequences the downstream capability and friction-removal work behind it.

Execute one item at a time in priority and numeric order. Do not start PLUG, TUI expansion, or autonomous repair while a P0 item remains. Historical evidence stays readable, but a prior closeout cannot override current source and runtime proof.

| Order | Priority | Finding | Owner surface | Status |
|---|---|---|---|---|
| 10 | P0 | [Kernel lifetime and RPC admission](10-kernel-lifetime-and-rpc-admission.md) | host/stdio client and server | closed 2026-08-12 |
| 11 | P0 | [Persistent agent worker and scheduler arbitration](11-persistent-agent-worker-and-scheduler-arbitration.md) | agents, scheduler, host | move 21 source-complete; pending moves 22–30 |
| 12 | P0 | [Test isolation and runtime hygiene](12-test-isolation-and-runtime-hygiene.md) | build/test root, install/state hygiene | closed 2026-08-12 |
| 13 | P0 | [Concurrent ledgers and replay identity](13-concurrent-ledgers-and-replay-identity.md) | sessions, protocol, TUI cursor | closed 2026-08-12 |
| 20 | P1 | [Tool capability truth](20-tool-capability-truth.md) | eval, DAP, TTSR, search, capability probes | pending |
| 21 | P1 | [Work-state and prompt consolidation](21-work-state-and-prompt-consolidation.md) | tickets, workspace tools, prompt builder | pending |
| 22 | P1 | [Documentation and WIP truth](22-documentation-and-wip-truth.md) | project records, public docs, 021/035/036/PLUG | pending |
| 30 | P2 | [TUI operator hierarchy](30-tui-operator-hierarchy.md) | TUI read model and Agent Hub | pending |
| 31 | P2 | [Gated harness repair loop](31-gated-harness-repair-loop.md) | failure evidence, approval, replay, regression | pending |

## Promotion floor

The ledger closes only when:

1. Isolated broad tests pass without access to an installed runtime root.
2. Multi-process lease and same-session admission tests prove one winner.
3. TUI exit leaves intended durable work running and leaves no unintended child process behind.
4. Every event consumer advances by ledger sequence.
5. Built and installed ReleaseFast hashes match.
6. A live provider/tool turn produces replayable session and event evidence.
7. Chain 035 and reopened 036 pass a new terminal review; no pending parent claims complete.

## Source-message proof

- “settings makes the TUI hang”
- “runing persistently until completed”
- “leave the code better than you find it”
- “Now do a full sitrep/recon of the full harness”
- “assume full responsibility for any in progress work and make sure it is complete/accounted for”
