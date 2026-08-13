---
type: research
id: owner-generation-reconciliation
status: accepted
roadmap_move: 29
retrieved_at: 2026-08-13
---

# Owner-generation reconciliation

## Problem

`agents/service.zig::recoverReceiptGroups` currently converts every persisted
`initialized` or `running` child receipt into `StaleAgentOwner` as soon as a new
`Service` reads the parent. This ignores the ticket claim's durable worker
generation, heartbeat, and lease expiry. It can fail a child while its lease is
still live, race the scheduler's stale-claim path, and discard the same session
whose mailbox cursor is the only durable delivery position.

The rest of the mechanism already has one correct owner:

- `core/tickets/index.zig` atomically persists claim identity, worker generation,
  lease token, expiry, attempt, session identity, and heartbeat renewals.
- `core/scheduler/service.zig` holds the process-exclusive tick lease and is the
  only ticket maintenance/dispatch owner.
- `core/agents/mailbox.zig` persists recipient delivery sequence and the highest
  provider-observed sequence on the recipient session event spine.
- `core/agents/supervisor.zig` is the only live fixed-pool inventory.

Move 29 must connect these owners. It must not add an agent lease file, recovery
queue, worker registry, copied mailbox cursor, or second scheduler.

## Competitive pressure

| Source | Mechanism | VANTARI decision |
|---|---|---|
| [Prime Agent daemon](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/daemon.md) | Session leases fence concurrent writers; generation-aware cursors reject retired owners; uncertain mutations are journaled and not replayed. | Fence the same ticket/session identity to a new worker generation. Never claim exactly-once external effects without an effect journal. |
| [Prime Agent long-running agents](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/long-running-agents.md) | Resident workers restore persisted sessions and descendants; direct messages remain session-addressed across restart. | Resume the existing child session so its transcript and mailbox cursor remain in place. |
| [Temporal Activity failure detection](https://docs.temporal.io/encyclopedia/detecting-activity-failures) | Heartbeat timeout detects worker loss; heartbeat payload can carry retry progress. | Treat heartbeat/expiry as ownership evidence, not as the work lifecycle itself. |
| [BullMQ stalled jobs](https://docs.bullmq.io/guide/jobs/stalled) and [idempotent jobs](https://docs.bullmq.io/patterns/idempotent-jobs) | Lost locks return work to waiting or failed; repeated effects require idempotent jobs. | Requeue only when no claimed session exists to resume. Keep external-effect guarantees honest until move 62's write-intent ledger. |
| [Vercel Queues](https://vercel.com/docs/queues) | Consumer position is durable; expired visibility leases redeliver at least once; handler idempotence owns duplicate effects. | Preserve the mailbox consumer position on the same session. Do not copy or reset it during owner recovery. |
| [Paperclip heartbeat protocol](https://github.com/paperclipai/paperclip/blob/master/docs/guides/agent-developer/heartbeat-protocol.md) | Run liveness is metadata and does not replace issue state; process recovery, queued delivery, and semantic continuation are separate. | Keep Supervisor liveness, ticket lifecycle, and mailbox delivery as distinct projections. |
| Scion at `2fad47cf`, `pkg/store/sqlite/sqlite.go:1370-1413` and `docs-site/src/content/docs/hub-admin/observability.md:371-378` | `state_version` provides compare-and-swap mutation; heartbeat drives offline projection separately from agent state. | Require revision plus worker generation for recovery and keep liveness out of ticket status. |
| Eve at `5e3119b`, `packages/eve/src/execution/session-delivery-hook.ts:36-95` | A committed delivery may resolve on replay, while retired-hook cursors prevent double yield. | Advance one sequence cursor only; owner recovery reuses that cursor's session. |

## Sprout decision

### Candidate A — keep unconditional stale requeue

Reject. A new attempt creates a new child session, strands directed mail on the
old session, and can repeat work that already crossed a provider or tool boundary.

### Candidate B — add mutable ownership to every execution receipt

Reject. Execution receipts are immutable execution contracts. Mirroring ticket
generation, heartbeat, expiry, and cursor into them creates four competing state
owners and requires a second mutation protocol.

### Candidate C — resume through the ticket ledger

Accept.

1. `claim` starts one ticket attempt and session.
2. The scheduler persists `heartbeat` only while the current Supervisor still
   owns that exact session.
3. After expiry, terminal session evidence settles before recovery.
4. If the claimed session exists and is nonterminal, one serialized `resume`
   event replaces worker id, generation, lease token, and expiry while preserving
   ticket, attempt, session, receipt, transcript, and mailbox cursor identity.
5. The existing `AgentService` resolves the persisted receipt and submits that
   same session to the existing Supervisor pool.
6. If the claimed session does not exist, one idempotent `requeue` returns the
   ticket to `assigned`; no provider or tool work existed to duplicate.
7. Receipt-group recovery defers any nonterminal session still owned by an
   `in_progress` ticket. It never wins a race against the scheduler.

`resume` means exactly one durable work identity and one mailbox delivery
position. It does not mean exactly-once arbitrary external side effects. A crash
inside an uncommitted effect remains uncertain until move 62 supplies the shared
write-intent/effect ledger. The context compiler and tool topology guards must
fail closed rather than inventing missing results.

## State machine

```text
assigned
  -> claim(ticket, revision, generation G1, lease L1, session S)
  -> in_progress
       -> heartbeat(G1, S, L1)                    [Supervisor owns S]
       -> complete(S, terminal receipt)           [terminal evidence first]
       -> resume(G2, S, L2)                       [lease expired; S exists]
       -> requeue(previous_session=S)             [lease expired; S absent]
```

Every transition is process-serialized, revision-checked, and idempotency-keyed.
A resumed session keeps its original attempt. A requeued ticket increments the
attempt only when the normal dispatcher later claims a new session.

## Red tracer

The implementation is rejected unless tests first fail on all of these cases:

1. A live ticket lease survives a cold `AgentService` read; the child is not
   changed to `StaleAgentOwner`.
2. Two recovery calls for one expired claim append one `resume` row and submit
   one same-session task.
3. A resumed claim has the new worker generation and lease but the same ticket,
   attempt, child session, group, task, transcript, and mailbox cursor.
4. A missing claimed session appends one `requeue` row and no `resume` row.
5. A terminal child settles before lease recovery and is never resumed/requeued.
6. Heartbeat renewal stops when the Supervisor does not own the claimed session.
7. A poisoned ticket suffix prevents recovery mutation.
8. Restart reconstruction does not append a second recipient delivery or cursor.

## Boundary

Move 29 closes source-level owner-generation reconciliation. Move 30 owns the
installed Windows kill/restart mesh. Move 62 owns exactly-once write effects.

## Landed proof

- `TicketStore.resumeExpired` owns the only generation replacement and rejects
  live lease, wrong revision/session, idempotency conflict, and poisoned suffix.
- Scheduler order is terminal reconciliation, expired-owner recovery,
  live-owner heartbeat, then new dispatch.
- `AgentService.resumeTicket` validates the immutable receipt against the live
  agent capability floor and submits its original group/task/session once.
- Cold receipt recovery defers ticket-owned nonterminal groups. Ordinary
  non-ticket orphan receipts retain `StaleAgentOwner` settlement.
- The real integration replay retained attempt 5, adopted generation 42, called
  the provider once, and kept one mailbox delivery plus one cursor.
- Debug and ReleaseFast pass 19/19 and 1,953/1,953. ReleaseFast build passes 9/9.
  Source SHA-256 is
  `ADDA84517C3DD1CC870E75C293E64BF1A7E1B3CE4525C1D56EC0B260E551ECD8`.
- The six-owner GGUF audit segmented 139 blocks, reported five candidates, zero
  exact duplicates, and no parallel recovery owner.
