---
type: research
id: installed-ticket-lifecycle-mesh
status: accepted
roadmap_move: 30
retrieved_at: 2026-08-13
---

# Installed ticket lifecycle mesh

## Problem

Move 29 proves same-session ticket recovery inside the Zig test graph. Move 30
must prove the same causal chain across real Windows processes:

```text
assigned ticket -> scheduler claim -> child provider turn
  -> owner and kernel loss -> lease expiry -> new owner generation
  -> same child session resume -> nested collaboration -> terminal ticket
```

The proof must distinguish three facts:

- A client detaches from the execution owner; it does not own durable work.
- The execution owner and its private kernel are one process tree; a forced owner
  loss must leave no proof-owned descendant alive.
- A ticket attempt, child session, execution receipt, and mailbox cursor survive
  process replacement; only the worker generation and lease change.

Do not add a public ticket RPC, a proof-only runtime branch, a second worker
registry, or a copied mailbox. Assignment can be seeded as a canonical
`var1.ticket_event.v2` row because the proof target begins at scheduler intake.

## Existing owners

| Concern | Canonical owner | Existing proof reused |
|---|---|---|
| Client-independent process lifetime | `host/owner_client.zig`, `host/http_bridge.zig` | `scripts/prove-owner-lifecycle.ps1` |
| One scheduler generation | `core/scheduler/store.zig`, `core/scheduler/service.zig` | `scripts/prove-scheduler-leadership.ps1` |
| Ticket identity and lease | `core/tickets/index.zig` | Move 24 and Move 29 tests |
| Fixed worker pool | `core/agents/supervisor.zig` | Move 28 contention tracer |
| Same-session recovery | `core/agents/service.zig` | Move 29 integration test |
| Collaboration delivery | `core/agents/mailbox.zig` | sequence/fingerprint/cursor tests |
| Terminal and repair projection | scheduler terminal reconciliation plus `TicketStore.close` gate | 036b/036d adversarial tests |

The missing artifact is one process-level tracer that composes these owners.

## Competitive pressure

| Source | Mechanism | VANTARI decision |
|---|---|---|
| [Prime Agent daemon](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/daemon.md) | Closing the TUI detaches; resident workers continue. Session-path leases prevent concurrent writers. Worker recovery reaps the old process group, restores the same active session, and does not replay uncertain effects. | Keep client lifetime outside work lifetime. Reuse one owner tree and the existing ticket/session identity. Do not claim exactly-once external effects before Move 62. |
| [Prime Agent long-running agents](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/long-running-agents.md) | Direct, sibling, child, and family-broadcast messages route through the daemon with bounded queues and delivery receipts. | Keep direct, parent, and current-group routing on the session event spine. Prove nested delivery without copying transcripts or adding a broker. |
| OpenAI Codex at `.refs/openai__codex/codex-rs/rollout-trace/README.md` | Ordered raw events are written first; offline projections interpret child and parent edges later. | Inspect durable event rows after execution. Do not make the proof depend on transient UI text. |
| Eve at `.refs/vercel__eve/docs/concepts/execution-model-and-durability.mdx` | One continuation owner receives queued delivery; client stream cancellation does not stop server work. | Treat client exit as detach and keep one active session owner. VANTARI retains a durable per-session mailbox instead of Eve's non-FIFO continuation token. |
| Paperclip heartbeat protocol | Run liveness is metadata, not issue state. Process recovery, semantic continuation, and queued wakes are separate. | Keep Supervisor ownership, ticket status, and mailbox cursor as separate projections. |
| Paperclip process-loss reports | Service restart can leave orphaned child trees and cosmetic `running` state when process truth is not reconciled. | Assert exact proof-owned PIDs are gone before restart and derive completion from session/event evidence, never a health label alone. |
| Vercel Queues | Visibility expiry redelivers at least once; consumers must deduplicate by stable message identity. | Preserve deterministic message IDs and receipt fingerprints. Reserve exactly-once arbitrary effects for the write-intent ledger. |
| Scion at `.refs/savageops__scion` | Persistent messages route through one broker; restart forces fresh heartbeat projection. | Retain persistence and liveness refresh, reject the hub/broker layer because VANTARI already owns the event spine. |

The required local Prime Agent checkout is absent, as `.refs/index.md` records.
The public source is the evidence boundary for that reference.

## Sprout decision

### Candidate A — extend the owner lifecycle script

Reject. That script proves process ownership and concurrent client attachment. A
ticket/provider/mailbox state machine would obscure its narrow failure signal.

### Candidate B — add a ticket RPC or test-only kernel command

Reject. The scheduler consumes the ticket ledger directly. A new API would exist
only for proof setup and become a second semantic entry point.

### Candidate C — add one composed proof script

Accept. Add `scripts/prove-ticket-lifecycle.ps1` with a required `BinaryPath`.
It creates one isolated workspace, seeds the same ticket event the runtime reads,
runs a bounded fake OpenAI-compatible provider, and drives the real execution
owner. The script reports the binary path and SHA-256 so source and installed runs
cannot be confused.

## Tracer state machine

```text
proof root created
  -> assigned row exists; sessions/ absent
  -> short-lived health client starts owner generation G1 and exits
  -> scheduler claim creates ticket child S and parent claim notice
  -> provider request for S blocks
  -> force-kill exact owner G1; owner and kernel PIDs reach zero
  -> ticket lease expires
  -> short-lived health client starts owner generation G2
  -> scheduler resumes S under G2; no second claim or child identity
  -> S launches two bounded children
       -> child A sends current_group wake to child B
       -> child A sends direct queue to S
       -> child B sends parent wake to S
  -> child B provider context observes the group message once
  -> S provider context observes direct/parent messages once
  -> S completes; scheduler appends one ticket complete row
  -> graceful shutdown; every proof-owned PID reaches zero
```

The first provider request is intentionally uncertain and is not counted as a
successful effect. The resumed provider call is allowed to repeat model work on
the same transcript. Message sends use stable tool-call IDs, so a replay returns
the existing receipt instead of appending a duplicate.

## Red tracer obligations

The proof fails unless all conditions hold:

1. Assignment creates no session before the scheduler starts.
2. One `claim` row exists and names one deterministic child session.
3. The first owner and kernel exit after an exact-PID forced kill.
4. The replacement owner has a different owner generation.
5. One `resume` row adopts a different nonzero worker generation while retaining
   ticket, attempt, session, execution group, task, and capability hash.
6. The provider observes one aborted parent request and one successful resumed
   chain; terminal completion occurs only after restart.
7. Direct, current-group, parent, and automatic child-summary receipts have one
   sender row and one recipient row per message ID.
8. A sibling provider request sees the group body once; the ticket child provider
   request sees both nested bodies once.
9. Recipient transcripts contain no copied sibling transcript. Collaboration is
   present only through bounded `AGENT_MAILBOX` context and event receipts.
10. One ticket `complete` row exists with `repair_required=false`.
11. A fresh file read reproduces the same counts after graceful shutdown.
12. No proof-owned process remains.

Failure and cancellation remain separate source pressure cases: scheduler tests
must show both terminal states become `completed + repair_required=true`, and
`TicketStore.close` must reject repair closure without approval, rerun, and
regression evidence. Moves 71-80 own the actual self-repair promotion loop; Move
30 must not synthesize its missing approval or patch evidence.

## Installed promotion gate

The tracer can run against a source-built ReleaseFast artifact without touching
the operator's active installation. Move 30's installed promotion gate passed
on 2026-08-13: the same script ran against
`%LOCALAPPDATA%\Vantari\bin\vantari.exe`, its SHA-256 equaled the current
ReleaseFast source artifact, the noninteractive TUI detach boundary passed, and
the installed process count returned to zero.

Installed evidence:

- ticket lifecycle: `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9`;
- owner lifecycle: `.zig-cache/owner-proofs/9cc5d7b8a1624e49937cb3b78716e1bb`;
- owner tracer: `.zig-cache/owner-proofs/65df1918745748ae9736cd9ba438fb13`;
- source and installed SHA-256:
  `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`;
- final installed process census: zero `vantari.exe` processes.

## Source Windows result

The composed tracer passes against ReleaseFast SHA-256
`F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`.
Retained evidence root:
`apps/backend/.zig-cache/owner-proofs/ddc238496ee944a2bb586db735e6da2a`.

The final projection records:

- queue-only assignment before scheduler intake;
- noninteractive TUI exit at the typed `TerminalUnavailable` boundary while work
  remains owner-held;
- first owner/kernel PIDs 19684/34508 and generation
  `03892103048d43ef4305af86d838d16b`;
- exact forced tree cleanup before restart;
- second owner/kernel PIDs 5800/27484 and generation
  `1ad6bf5642beb7b14c9e21e7a41e2abf`;
- one ticket claim, one same-session resume, and one completion;
- two nested children, one directed message, one group message, one parent
  message, six unique recipient deliveries, and zero transcript copies;
- sibling and parent provider contexts each observe their bounded mailbox input;
- graceful second-owner shutdown, cold post-shutdown ticket/session/message
  replay, retained `result.json`, and final zero proof-owned processes.

The adjacent Windows gates also pass:

- owner lifecycle: 20/20 clients converge, forced tree cleanup passes, and the
  replacement owner reaches a third clean generation at
  `.zig-cache/owner-proofs/8e02c2b054864bb699cfd8f6182d4d9a`;
- scheduler leadership: two complete kernels produce one attempt, one claim, one
  child, one terminal row, one winning generation, and zero survivors at
  `.zig-cache/owner-proofs/b80d4d5bcc7f438089f9a35dce16ce9a`;
- owner tracer: explicit workspace wins, reconnect preserves one generation, and
  the owner remains alive after two short-lived clients at
  `.zig-cache/owner-proofs/ee06ea88d61845fb8d32eb9405758aea`;
- core graph: 19/19 steps and 1,953/1,953 tests;
- focused TUI: 9/9 steps and 61/61 tests.

The GGUF duplicate-owner audit covers ten lifecycle files: HTTP bridge, owner
client, scheduler service/store, ticket store, agent service/mailbox, and all
three Windows proof scripts. It segments 139 regions, reports six semantic
candidates, and finds zero exact duplicates.

Scheduler source pressure now includes completed, failed, and cancelled child
sessions in one cold-start reconciliation test. Failed and cancelled children
settle the work row with `repair_required=true`; cancelled evidence contains
`status=cancelled`. The existing closure gate rejects repair completion without
approval, original-input rerun, and regression evidence.

## Repair discovered by the tracer

The first tracer run repeatedly crashed the detached owner immediately after
`/owner/health`. Windows Error Reporting captured access violation `0xC0000005`
at the page base plus `0x18`. Symbol resolution traced the fault to
`host/http_bridge.zig:handleConnectionJob`.

Two independent `defer` statements executed in LIFO order: allocator destroy
unmapped the page-allocated `ConnectionJob`, then lifecycle release read
`job.lifecycle` from the freed object. The repair captures allocator and lifecycle
before cleanup and performs lifecycle release before destroy in one defer block.
Owner lifecycle, owner tracer, scheduler leadership, the composed lifecycle mesh,
ReleaseFast, core, and TUI proofs pass after the repair.

A standard-handle inheritance hypothesis was tested and rejected; restoring the
original process-launch code did not reproduce the crash after the cleanup-order
repair. No proof-only owner branch or alternate process runtime remains.

## Current boundary

Source and installed ReleaseFast artifacts match at SHA-256
`F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`.
Move 30, finding 11, and parent ticket 036 are closed by the installed run and
the 036h terminal review. The remaining boundary is arbitrary external-effect
certainty, which belongs to the write-intent and self-repair roadmap rather than
to owner or ticket lifecycle recovery.
