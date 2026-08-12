---
type: roadmap-closeout
id: roadmap/20-adversarial-concurrency-mesh
status: closed
updated: 2026-08-12
owner: apps/backend/tests, apps/backend/src/host/stdio_rpc.zig
parent: .docs/roadmap/24-harness-capability-next-90.md
decision: consolidate/add-tests
idempotency_contract: idempotent
blast_radius: low; test-only unless a tracer falsifies a production invariant
source_message_excerpt: "run through ALL of these items, ensuring at all times YAGNI. Less is more."
---

# 20 — Adversarial concurrency mesh

## Entry state and owner map

Move 20 closes finding 13 without a new test framework. Three required
100-contender probes already exist and use synchronized release plus durable
readback:

- `host/stdio_rpc.zig`: 100 same-session admissions produce one owner and 99
  non-starters.
- `core/sessions/summaries.zig`: 100 concurrent summary upserts retain 100
  unique sequences.
- `tests/core_store_test.zig`: 100 mixed-role message appends retain 100 unique
  monotonic rows.

The missing scale pressure is narrower: the event writer and tracked TUI were
proven only with small same-millisecond bursts, while the shutdown cancellation
sweep had one end-to-end active request plus repeated runs. The canonical
owners can absorb those probes; no runner, scheduler, randomizer, fixture
registry, or production status path is needed.

## Competitive synthesis

| Source | Load-bearing test invariant | VANTARI consequence |
|---|---|---|
| [OpenAI Codex app-server client](https://github.com/openai/codex/tree/main/codex-rs/app-server-client) and `.refs/openai__codex/codex-rs/app-server-client/README.md:58` | Bounded queues return explicit overload; shutdown is deterministic rather than drop-only. | Keep the existing fixed request bounds and test the fence, not queue growth. |
| [OpenAI Codex rollout trace](https://github.com/openai/codex/tree/main/codex-rs/rollout-trace) and `.refs/openai__codex/codex-rs/rollout-trace/README.md:199` | Replay consumes raw events in sequence order and rejects internally inconsistent evidence. | Read back every event sequence after contention; do not assert only thread success. |
| [Vercel Eve sessions/runs/streaming](https://github.com/vercel/eve/blob/main/docs/concepts/sessions-runs-and-streaming.md) | One ordered durable writer may coalesce adjacent deltas, but other events remain ordering barriers. | Stress one existing serialized writer with same-timestamp rows and verify exact suffix order. |
| [pi concurrent session test](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/test/agent-session-concurrent.test.ts) and `.refs/badlogic__pi-mono/packages/coding-agent/src/core/agent-session.ts:447` | Concurrent prompts are guarded; asynchronous events are serialized through one queue that remains live after handler error. | Preserve one admission owner and test exact event identity independently from callback timing. |
| [oh-my-pi agent loop](https://github.com/can1357/oh-my-pi/blob/main/packages/agent/src/agent-loop.ts) and `.refs/can1357__oh-my-pi/packages/agent/test/agent-loop.test.ts:253` | Abort-before-first-event and final `agent_end` behavior are explicit test cases. | Release all shutdown observers together and require every active owner to see the fence. |
| [NullClaw](https://github.com/nullclaw/nullclaw) and `.refs/nullclaw-main/src/subagent.zig:212` | Mutex-owned capacity rejects overflow; daemon startup checks shutdown before spawning work. | Exercise capacity and shutdown as one ordered state transition, not sleep-based probability. |
| [Scion](https://github.com/GoogleCloudPlatform/scion) and `.refs/savageops__scion/README.md:70` | Independent agents run concurrently and accept queued/interjected input while detached. | Test shared-runtime identity at 100-way pressure without importing containers or tmux. |
| [Temporal testing](https://docs.temporal.io/develop/go/testing-suite) | Time-skipping, injected failures, and history replay make recovery assertions deterministic. | Use explicit gates and ledger readback; avoid timing-only race claims. |
| [Tokio Loom](https://github.com/tokio-rs/loom) | A small concurrency model is rerun across possible schedules rather than trusting one lucky interleaving. | Keep each VANTARI probe small, synchronized, and invariant-focused; do not add Loom or a model checker to Zig. |
| [FoundationDB simulation](https://apple.github.io/foundationdb/testing.html) | Deterministic failure injection plus post-run checks outperforms nondeterministic load alone. | Separate the release barrier from the durable check phase and make every expected identity enumerable. |

VANTARI surpasses the comparable harness tests on one axis: each high-cardinality
probe reads the same append-only identity or runtime state used after cold start,
while retaining no external simulator or second harness.

## Sprout decision

1. Add a fuzz/property framework. Rejected: the current defect is cardinality
   pressure over known finite state, not input generation.
2. Launch 100 provider-backed RPC turns during shutdown. Rejected: four workers
   and 32 admitted requests make that mostly an overload benchmark; failures
   would not isolate the cancellation sweep.
3. Reuse the existing synchronized-gate pattern in three missing seams. Selected:
   100 concurrent event appends plus suffix readback, 100 tracked-TUI deliveries
   plus exact replay suppression, and 100 active runtime owners plus one shutdown
   fence. The existing full RPC shutdown probe retains terminal/event proof.

## Tracer and acceptance

```text
event writer: 100 threads -> one same-ms ledger -> seq 1..100 exactly once
TUI reader:   100 same-text notifications -> seq 100 + 100 concatenated chunks
              -> exact replay changes neither cursor nor transcript
shutdown:     100 running sessions -> beginShutdown() == 100 -> all cancel bits
              -> every late tryStartSession returns ServerShuttingDown
```

- Modify tests only unless one tracer fails.
- Reuse local gate structs; add no shared test abstraction for three files.
- Run the focused owner lanes, then the canonical graph, ReleaseFast, and
  installed/source hash and process checks. This is a test-only/baseline slice;
  the planning-spec 30-feature-test floor does not require inventing 30 runtime
  behaviors.
- Close finding 13 only after all six 100-way owners and the existing installed
  ledger replay are recorded in current docs.

## Proof

- `tests/core_store_test.zig` releases 100 event writers at one barrier. The
  durable ledger contains exactly 100 same-millisecond `assistant_delta` rows,
  sequences `1..100`, every unique message once, and an exact 63-row suffix
  after sequence 37.
- `clients/tui_chat.zig` consumes 100 identical same-timestamp notifications,
  produces one 400-byte assistant projection at cursor 100, then rejects every
  replay without changing text or cursor.
- `host/stdio_rpc.zig` starts 100 distinct runtime owners, atomically marks all
  100 cancelled through `beginShutdown`, and rejects every late start with
  `ServerShuttingDown`.
- The existing 100-way admission, summary, and mixed-role message probes remain
  green. Together, the six high-cardinality seams cover admission, summary,
  message, event, client replay, and shutdown ownership without a new test
  framework.
- `scripts/zigw.ps1 build test --summary all` passed four consecutive canonical
  runs at 19/19 steps and 1,959/1,959 tests. The owner artifacts report 1,499
  integration tests, 61 tracked-TUI tests, and 239 host tests.
- `scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` passed 9/9. The
  regenerated artifact SHA-256 is
  `7F1256550B859566F89DD7B86A33E34D239D69CEB612D185396CB621388A24B2`.
- This is a test-only slice. No production declaration or runtime path changed,
  so dupe-audit and a disruptive installed replacement are explicitly deferred.
  The installed move-19 artifact remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`
  with its provider/tool replay proof. Operator-owned TUI PID 12028 and its
  `kernel-stdio` child PID 14452 were observed and preserved.
- Finding 13 is closed. No database, model checker, randomizer, simulator,
  scheduler, or parallel replay owner was added.
