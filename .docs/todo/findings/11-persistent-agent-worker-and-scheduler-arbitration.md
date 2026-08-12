---
type: finding
id: harness-finding-11
status: pending
priority: P0
owner: apps/backend/src/core/agents
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Persistent agent worker and scheduler arbitration

## Finding

The fixed agent pool is process-local and the scheduler leader lease is not an inter-process claim. Ticket events survive, but the executor that must run a ticket to terminal state does not survive TUI/kernel exit. Two kernels can also both believe they hold the scheduler lease.

## Evidence

- [supervisor.zig:164](../../../apps/backend/src/core/agents/supervisor.zig#L164) owns std.Thread.Pool in-process.
- [supervisor.zig:379](../../../apps/backend/src/core/agents/supervisor.zig#L379) dispatches with pool.spawn.
- [service.zig:925](../../../apps/backend/src/core/agents/service.zig#L925) states that process restart converts running receipts to StaleAgentOwner.
- [cli.zig:643](../../../apps/backend/src/clients/cli.zig#L643) defines run-session, but source ownership search found no launcher.
- [store.zig:266](../../../apps/backend/src/core/scheduler/store.zig#L266) performs lease read/check/write without CAS or an inter-process lock.

## Required mechanism

Make one daemon or detached worker process the long-lived execution owner. Keep AgentService route validation, Supervisor capacity, ticket claims, receipts, and event ledgers as the existing primitives; do not create a parallel pool. Claim scheduler leadership with an inter-process exclusive primitive and verify owner generation before dispatch.

## Acceptance

- Assigning a ticket creates no session and starts no provider turn.
- One claim creates one durable child session.
- Closing the TUI does not stop claimed work.
- Killing the worker leaves a durable stale receipt; restarting reconciles and resumes or requeues exactly once.
- Two concurrent kernels produce one lease winner and one LeaseUnavailable loser.
- Completion, failure, cancellation, heartbeat expiry, and repair-required closure survive cold start.

## Source and salvage

- User: “runing persistently until completed”.
- [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent): daemon-backed sessions, goals, heartbeats, and schedule ownership.
- [Eve](https://github.com/vercel/eve): indexed durable streams and terminal reconciliation.

## Out of scope

Do not change ticket schema vocabulary, add dynamic worker classes, or create a second scheduler.
