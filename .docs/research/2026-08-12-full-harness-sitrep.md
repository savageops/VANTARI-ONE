---
type: research
id: docs/research/2026-08-12-full-harness-sitrep
status: current
updated: 2026-08-13
scope: full-harness
---

# VANTARI full harness SITREP

## Executive verdict

VANTARI has a strong kernel thesis and several unusually good local mechanisms: one context compiler, append-only transcript and event ledgers, typed tool review and dispatch, bounded Windows process execution, provider-wire separation, one project-local execution owner around fixed agent capacity, and a compact TUI read model. The architecture is materially better than a chat-wrapper harness.

The current checkout is not production-ready for persistent autonomous execution. Its critical gap is not model intelligence or UI polish. Move 21 separates presentation lifetime from execution lifetime in source: TUI/CLI detach leaves one owner/kernel/pool generation alive. Move 22 removed the unused per-session executor that bypassed that owner. Move 23 closes scheduler split-brain with one crash-released process lock and a read-back generation fence. Move 24 process-serializes the ticket ledger and commits worker generation, lease, capability, and deterministic child identity in the winning claim before child creation. Move 25 proves assignment is ledger-only and deletes the unused ticket-policy branch. Exact active-turn reconciliation after owner death, durable agent messaging, and installed artifact parity remain open. Host request lifetime, test isolation, append-only summary mutation, per-session message sequencing, exact event sequence transport, and shipped-TUI replay are closed. Chain 036 remains pending until moves 26–30 close the process-failure contract.

Current classification:

| Axis | State | Boundary |
|---|---|---|
| Build | Pass | ReleaseFast builds 9/9 with Zig 0.15.1. |
| Focused TUI | Pass | Backend TUI 61/61 with zero skips. |
| Broad tests | Pass | Canonical isolated graph is 19/19 and 1,933/1,933 with zero skips; one registry loop executes all 53 declared cases. |
| Installed proof | Historical pass through move 20; current replacement blocked | Installed move-19 SHA-256 remains `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`; current source is `77A2B111DCA35AA08E4D33973D83AB2FB9783E6C4D423A09611D24F0EE3142FD`. Operator PIDs 12028/14452 are preserved until natural exit. |
| Execution owner | Source pass | `LocalClient` reconnects to one workspace owner; 20/20 concurrent clients converge, foreground duplicate start is rejected, explicit workspace defeats inherited redirection, graceful/crash recovery creates one new generation, and teardown leaves zero proof-owned processes. |
| Agent pool | Presentation-persistent; owner-crash recovery open | The fixed pool survives TUI/CLI exit. Owner restart still converts running receipts to `StaleAgentOwner`; exactly-once resume/requeue is not wired. |
| Scheduler/ticket persistence | Admission pass; owner-crash recovery open | Two complete kernels yield one scheduler generation, one schedule attempt, one serialized ticket claim, and one matching deterministic child session. |
| Event replay | Pass for tracked TUI | `var1.session_event_notification.v1` carries exact stored sequence after persistence; the TUI advances by that sequence and requests only a missing durable suffix. Raw command bytes persist through one typed base64 envelope with stream/cap evidence. Ignored browser prototypes retain a compatibility SSE transport id. |
| Self-repair | Evidence floor only | Trace, diagnostics, and rerun substrate exist; causal diagnosis, approved patching, exact-input replay, and regression locking do not form one runtime loop. |

Move 21 promoted the existing loopback bridge and private stdio child instead of
adding a daemon framework, second scheduler, or worker registry. Current findings
remain executable at [../todo/findings/00-INDEX.md](../todo/findings/00-INDEX.md).

## Product thesis and why

VANTARI is a deterministic local agent kernel. Its value is not a particular chat surface. It is the ability to replay the same causal chain after cold start:

~~~mermaid
flowchart LR
    I["Operator input"] --> M["messages.jsonl"]
    M --> C["Context compiler"]
    X["context.jsonl checkpoints"] --> C
    C --> P["Provider wire"]
    P --> D["Assistant deltas or tool calls"]
    D --> R["Review and tool runtime"]
    R --> E["events.jsonl"]
    D --> E
    E --> U["TUI, CLI, future clients"]
    E --> S["Terminal session state"]
~~~

The design choices follow from that thesis:

- Keep the transcript complete and append-only. Context compression is a model-visible projection, not transcript mutation.
- Keep provider context assembly in one compiler. Clients and adapters do not invent history.
- Treat tools as typed capabilities: definition, availability, review risk, execution, and effect evidence share one owner.
- Treat the TUI as a projection over durable events. UI state must be reconstructable rather than guessed.
- Treat child agents as normal sessions. Delegation changes scheduling and supervision, not transcript truth.
- Prefer compact filesystem ledgers and explicit state machines over a database or service forest until measured pressure requires one.

## Current owner map

| Capability | Canonical source owner | Current role |
|---|---|---|
| Process entry | [main.zig](../../apps/backend/src/main.zig) | Selects TUI, continuation, CLI, foreground serve, hidden execution-owner, or private kernel-stdio mode. |
| Execution owner | [http_bridge.zig](../../apps/backend/src/host/http_bridge.zig), [owner_state.zig](../../apps/backend/src/host/owner_state.zig) | Holds the workspace lease, exact owner routes, atomic projection, one private child, and shutdown drain. |
| Kernel composition | [stdio_rpc.zig](../../apps/backend/src/host/stdio_rpc.zig) | Composes session, executor, agents, scheduler, buffer, and JSON-RPC. |
| Public local client | [owner_client.zig](../../apps/backend/src/host/owner_client.zig) | Resolves/starts one owner, validates its live identity, and reconnects without owning process lifetime. |
| Private child transport | [stdio_client.zig](../../apps/backend/src/host/stdio_client.zig) | Owner-only `ChildClient` spawns the same executable in kernel-stdio mode and supervises framed replies and process-tree cleanup. |
| Turn execution | [loop.zig](../../apps/backend/src/core/executor/loop.zig) | Compiles context, streams provider output, reviews tools, emits events, and closes turns. |
| Context | [context/](../../apps/backend/src/core/context/) | Sole transcript/checkpoint to provider-message compiler. |
| Sessions | [sessions/](../../apps/backend/src/core/sessions/) | Session lifecycle, messages, checkpoints, events, output, and summaries. |
| Provider wires | [providers/](../../apps/backend/src/core/providers/) | Chat Completions, Responses, and Anthropic request/stream adaptation. |
| Tools | [tools/](../../apps/backend/src/core/tools/) | Catalog, availability, review, runtime dispatch, and built-ins. |
| Agents | [agents/](../../apps/backend/src/core/agents/) | Route specs, execution receipts, in-process fixed pool, and child convergence. |
| Tickets | [tickets/](../../apps/backend/src/core/tickets/) | Ticket event ledger, transition rules, claims, leases, and projection. |
| Scheduler | [scheduler/](../../apps/backend/src/core/scheduler/) | Process-exclusive generation-fenced leadership, scheduled jobs, ticket wake/claim, heartbeat, and stale reconciliation. |
| TUI | [tui_chat.zig](../../apps/backend/src/clients/tui_chat.zig) | Input, RPC notifications, event projection, transcript, footer, and agent rows. |
| Terminal library | [packages/tui/](../../packages/tui/) | Tracked local libvaxis fork consumed directly by the backend build. This is a real vendored runtime dependency, not an inert package. |
| Browser prototype | apps/frontend | Local ignored tree with zero tracked files. It is not a shipped checkout surface. |

## Repository and worktree state

Audit-entry snapshot:

- Branch: feat/reasoning-trace-checkpoints.
- Backend source: 109 Zig files and 37,648 lines.
- Largest source owners: tui_chat.zig 4,189 lines; cli.zig 1,931;
  stdio_rpc.zig 1,673; executor/loop.zig 1,500; sessions/store.zig 1,456;
  agents/service.zig 1,410; openai_compatible.zig 1,299; supervisor.zig
  1,251.
- Existing tracked diff: 55 modified files, about 4,327 insertions and 620
  deletions, plus untracked provider, ticket, record, and doctrine files.
- Project docs at entry: 475 files, about 10.98 MB; 187 tracked.
- Local reference corpus: about 15,663 files and 375 MB, ignored by policy.
- packages/tui: 71 tracked files and about 767 KB.
- apps/frontend: about 15,178 local files and 702 MB, entirely ignored and
  zero tracked files.

The audit preserved all pre-existing source changes. Documentation, ignore
rules, and current planning records were the only modified surfaces in this
pass.

## Runtime pipelines

### Startup and TUI

~~~mermaid
sequenceDiagram
    participant U as Operator
    participant T as TUI process
    participant O as execution owner
    participant K as kernel-stdio child
    participant H as Host services
    U->>T: vantari
    T->>O: resolve/start and validate generation
    O->>K: one private ChildClient
    K->>H: compose scheduler, buffer, agents, executor
    T->>O: exact loopback JSON-RPC
    O->>K: private Content-Length frame
    K-->>O: response and session/event notifications
    O-->>T: exact response/events
    U->>T: exit
    T--xO: detach only
    O->>K: owner and services remain live
~~~

The settings-hang class is closed in source. Public `LocalClient.deinit` owns no
process. Every RPC has a method deadline; late response IDs are retired. The
private child transport has bounded shutdown and one Job Object. Detached owner
spawn sets `bInheritHandles = FALSE`, so a resident owner cannot retain the
calling PowerShell/TUI capture pipe.

### Turn execution

1. session/send admits a session.
2. The context builder compiles system/runtime context, latest checkpoint, and raw transcript suffix.
3. The selected provider adapter emits live deltas and reconstructs tool calls.
4. Tool definitions are reviewed against the active capability set.
5. Tool output and effect evidence append to the event and message ledgers.
6. Overflow rebuilds through the context compiler.
7. The turn closes with a typed turn payload, terminal assistant response, output projection, and summary freshness gate.

The turn pipeline is coherent. Host concurrency now uses one atomic
`tryStartSession` transition: 100 contenders produce one owner and bounded steer
messages for losers. Admission-fenced shutdown settles one terminal event before
state is freed.

### Agent execution

~~~mermaid
flowchart LR
    A["launch_agents or scheduler claim"] --> V["AgentService route validation"]
    V --> P["Supervisor fixed thread pool"]
    P --> C["Child session"]
    C --> L["Child transcript and events"]
    L --> G["Parent control events"]
    G --> T["Keyed TUI agent row"]
    C --> Q["Terminal convergence or stale receipt"]
~~~

The Supervisor owns a `std.Thread.Pool` inside the persistent execution owner
([supervisor.zig](../../apps/backend/src/core/agents/supervisor.zig#L164)) and
dispatches with `pool.spawn`
([supervisor.zig](../../apps/backend/src/core/agents/supervisor.zig#L379)). Closing
the TUI no longer closes that owner/kernel tree. Cold recovery still turns
initialized or running receipts into `StaleAgentOwner`
([service.zig](../../apps/backend/src/core/agents/service.zig#L925)). Move 22
deleted the uncalled direct `run-session` executor; `run --session-id` now has no
parallel continuation path around the owner.

Child completion currently reaches the parent through convergence-specific
messages and control events. There is no general peer mailbox, group delivery,
restart-safe unread cursor, or model-selected queue/wake path. The accepted
direction for moves 26–30 is selective awareness: one sequence-addressed
direct/group/parent mailbox over the same session/event owner, canonical
summaries and artifact references on demand, and no shared transcript or topic
broker. Codex supplies queued versus wake-bearing delivery pressure; Claude Code
teams supplies independent contexts plus direct mail; AutoGen supplies typed
target scope. VANTARI must add cold-start replay and fewer concepts.

### Ticket execution

Assignment is correctly modeled as queue admission. The scheduler claims assigned tickets only when AgentService reports capacity. This preserves one capacity owner and avoids a second worker registry.

Move 25 locks that invariant. Both create-as-assigned and transition-to-assigned
append queue state without creating a claim, active-session id, session record,
or provider turn. `agent_routes.max_concurrency` is the sole capacity setting;
the four-key `tickets` policy object, loader, validation, and public examples are
deleted because none governed execution.

Move 23 closes the former split-brain seam. [tryAcquireLease](../../apps/backend/src/core/scheduler/store.zig) acquires `.var/schedules/lease.lock` through the shared process-lock primitive, rejects an active different owner/generation, writes `lease.json`, reads the exact generation back, and returns a guard held through scheduled-job and ticket mutation. The lease file remains a durable projection and failover clock; the operating-system lock is the mutex.

The mechanism combines the strongest useful pressure from six tracked harnesses without importing their incidental architecture. Oh My Pi contributes a process-owned crash-released lock; Eve contributes one resolved generation reused through dispatch. Scion, NullClaw, and KrillClaw retain in-process schedulers and therefore fail the two-kernel leadership requirement. Flue exposes cron as manifest-only in the tracked source; Codex and pi have no comparable project-local scheduler owner. VANTARI adds no database, daemon, election service, or second registry.

Move 24 extends the same owner instead of adding a second transaction system. `core/tickets` acquires `.var/tickets/ledger.lock` around every projection and mutation. One claim append commits revision, worker generation, lease, attempt, selected capability, and a child-session id derived from the claim identity. Only the append winner may materialize and submit that child. Flue supplies the strongest identity precedent by deriving a child session from parent plus task identity; Codex, Oh My Pi, Eve, pi, NullClaw, and KrillClaw either remain in one runtime or do not provide a durable cross-process ticket claim. VANTARI adds the missing process fence without a database, transaction coordinator, second queue, or second pool.

Native evidence root `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` starts two full source `kernel-stdio` processes against one due shell job and one assigned ticket. It records one attempt ID, one reserved row, one completed row, one ticket claim, one matching deterministic child session, one shared nonzero worker generation, empty stderr, graceful EOF shutdown, and zero proof-owned survivors.

Competitive pressure confirms the smaller boundary. Temporal, Eve, Celery, and
BullMQ separate durable admission from capacity-bound claim. Codex claims bounded
eligible rows before model calls. Flue derives child identity before execution.
Pi and Oh My Pi spawn from explicit live task calls, while Scion, NullClaw, and
KrillClaw queue inside one process. VANTARI keeps the durable split and claim
identity without their database, broker, daemon, or direct-launch branch.

### TUI projection

The current footer direction is correct:

~~~text
● glm-5.2 · max · ctx 5k/200k (3%) · 195k left · agents 2/12 · queue 1 · $0.0042
~~~

- Keep one compact row.
- Hide zero-value queue and cost segments.
- Keep Esc cancel out of persistent copy.
- Keep the composer slightly lighter than the transcript and lighter than the metadata row.
- Keep the child group label as Agents completed/total.
- Use the bounded child turn summary as the child row label; tool phases are state markers only.
- Put per-agent model, effort, elapsed time, token/cost detail, tools, and receipts in an on-demand Agent Hub, not the footer.

At the time of this sitrep, the producer/transport replay contract carried exact
identity but the TUI still ignored it and deduplicated by timestamp, event type,
and message. Move 41 supersedes that pre-change diagnosis: `ChatState` now
uses the stored sequence as its sole activity identity, rejects sequence-less
legacy activity on cold load, and proves live/cold keyed-row parity.

Move 41 also repaired the installed latest-session selector. The TUI requests
`session/list { limit: 1 }` so a large workspace cannot overflow the owner
response cap before continuation begins; the existing unbounded list behavior
remains available to callers that do not supply `limit`.

## What is already strong

1. Context compilation has one owner and a clear transcript/checkpoint separation.
2. JSONL readers preserve valid prefix state across malformed tails.
3. Provider wire adaptation is concentrated behind one dispatch seam.
4. Tool schemas, review risk, availability, and dispatch are module-owned.
5. shell_exec has the right Windows mechanics: concurrent stdout/stderr drain, timeout, output caps, and process-tree control.
6. Full-access mode is centralized, default-off, and projected through ExecutionContext rather than tool-local bypass flags.
7. Child work uses immutable route specs and secret-free execution receipts.
8. Hash-anchored edits reject stale file versions.
9. The TUI surface has moved toward a useful hierarchy instead of a status forest.
10. Cost and token telemetry have one typed turn-payload owner and reach the current source TUI.

## Ranked findings

### P0 — integrity and lifecycle blockers

| ID | Concern | Evidence and effect | Smallest durable correction |
|---|---|---|---|
| P0-1 | Detached RPC workers outlive Server ownership | **Closed 2026-08-12.** The host formerly detached one thread per request and could free Server state first. | `Server` owns one bounded four-worker executor, caps admission at 32, returns typed overload, stops admission, fences late starts, signals active turns, joins, then frees services/state. A blocked provider request proved one terminal cancellation and no surviving worker. |
| P0-2 | Session admission and buffer routing race | **Closed 2026-08-12.** The old check/set and split buffer identity surfaces could double-run a session or expose a freed/cross-session preview. | `Runtime.tryStartSession` is one atomic transition; losing prompts become bounded interjections. One `BufferProjection` owns session identity plus preview and rejects late prior-session callbacks. |
| P0-3 | Owner-crash recovery and agent collaboration are incomplete | **Moves 21–22 source slices closed:** the fixed pool survives presentation detach in one owner tree, and the dead per-session executor is deleted. Owner restart still marks work stale. Completion has a special parent convergence path, but peers lack durable directed/group/parent mail and unread replay. | Retain the one execution owner. Add generation-fenced exactly-once resume/requeue and replace convergence-only delivery with one sequence-addressed session/event mailbox. Do not add a second scheduler, shared transcript, or generic broker. |
| P0-4 | Scheduler leader lease can split-brain | **Closed 2026-08-13.** One shared crash-released byte-range lock spans each scheduler tick; `lease.json` carries a random nonzero generation and is read back before dispatch. A synchronized race and two complete Windows source kernels each yield one winner. | Keep `shared/process_lock.zig` as the sole primitive and the lease file as projection only. Do not restore read/check/write leadership. |
| P0-5 | Summary ledger loses concurrent updates | **Closed 2026-08-12.** The keyed v1 object was last-writer-wins and rewrote the full live ledger. | `summaries.jsonl` v2 appends stable sequenced revisions under one host-process owner, projects the greatest sequence per session, isolates poisoned suffixes, and imports the legacy object once. One hundred concurrent writers retained 100 rows and unique sequences. |
| P0-6 | Broad tests write into live runtime state | **Closed 2026-08-12.** The invalid broad run, a later direct-test wrapper bypass, and 877 older initialized context-poison fixtures reached the live root. | Six build artifacts and both direct wrappers now assign generated cache-owned homes plus the cache-root guard. All three fixture sets are backed up or quarantined with manifests and rollback. The post-repair scan covers 29,937 ledgers and 1,417,061 rows with zero integrity defects. |
| P0-7 | Secret-shaped legacy state is unignored | **Closed 2026-08-12.** Seven backend runtime-shaped owners existed outside canonical ownership. | All 2,252 files were archived reversibly without merging fixtures into live state. Automatic todo/changelog sync now writes direct workspace `.var` paths; no fallback reader was added. |

### P1 — capability truth and deterministic replay

| ID | Concern | Evidence and effect | Smallest durable correction |
|---|---|---|---|
| P1-1 | Clients ignore exact event sequence | **Closed for the tracked TUI 2026-08-12.** Stored SessionEvent sequence survives persist-first notification, owns render identity, and drives demand-only suffix repair. The one-shot CLI has no event replay surface; ignored browser prototypes retain a compatibility SSE transport id. | Keep stored sequence as the only shipped render identity. Binary payload remains move 16; promote a browser cursor only when a tracked browser consumer exists. |
| P1-2 | Message append was O(N²) and not serialized | **Closed 2026-08-12.** Every message role now routes through one per-session ledger state. Cold start scans backward from a 4 KiB tail window and expands only when no complete valid row exists; append failure invalidates the cached cursor. | The removed whole-transcript sequencer and empty-file rewrite stay deleted. Multi-process writer authority remains part of the persistent-host boundary, not a second message lock. |
| P1-3 | eval advertises a capability it does not provide | eval claims persistent Python/Bun, but creates and destroys a kernel per call; Bun is one-shot and ignores timeout. Pipe draining can deadlock. | Gate only the unsafe execution point while keeping the implementation obligation. Rebuild it on the canonical process supervisor and a session-owned kernel registry. |
| P1-4 | DAP calls are non-composable | dap_attach destroys its client before returning; stacktrace and variables spawn fresh unattached adapters, despite usage hints that they continue the attach session. Reads have no deadline. | Make one session-scoped DAP client with request IDs, timeouts, cancellation, and teardown evidence. |
| P1-5 | TTSR does not abort mid-stream | rule_abort_requested is set by a delta callback, but the callback returns normally and correction happens only after provider completion. | Give provider streaming an explicit abort result and prove the network/read loop stops before terminal completion. |
| P1-6 | Shadow owners are documented as shipped | Provider capability cache has no runtime consumer; write-intent reserve/commit is test-only; memory quota counters are not updated. | Wire each through its canonical consumer or label it frontier. Do not preserve dead schemas as pretend capability. |
| P1-7 | Ticket policy knobs do not govern execution | **Closed 2026-08-13.** The unused `tickets` object, four keys, loader, validation, and false public examples are deleted. Direct assignment probes retain two queued tickets with zero claims or sessions. | Keep assignment non-configurable and ledger-only. Use `agent_routes.max_concurrency` as the sole capacity setting. Do not restore an assignment-to-launch branch. |
| P1-8 | Work state has parallel owners | Tickets are declared canonical, but todo_slice, session_record, .var/todos, and changelog are also model-facing lifecycle surfaces. | Tickets own work state. Plans, research, summaries, and changelog become ticket-linked artifacts, not independent task systems. |
| P1-9 | Prompt duplicates native tool schema and doctrine | The builder renders the full catalog while the provider request also sends native tool definitions. The operating prompt repeats repository doctrine and carries contradictions. | Keep native schemas as API truth. Inject only policy deltas and demand-load examples/help through skill_info or catalog lookup. |
| P1-10 | Search is unavailable on the installed owner path | search_files requires iex; the machine has ix.exe but no iex executable, and installed tools reports the capability unavailable. | Choose one executable identity and resolve it once in installation/config. Do not add rg or grep as hidden fallback. |

### P2 — ownership clarity and maintainability

| ID | Concern | Effect | Direction |
|---|---|---|---|
| P2-1 | Large mixed-owner files | tui_chat.zig is 4,189 lines; cli.zig 1,931; stdio_rpc.zig 1,673; loop.zig 1,500; store.zig 1,456. Concurrency, protocol, projection, and lifecycle review are coupled. | Split only at proven seams: host lifetime/request execution/projection; TUI protocol/read model/render/input; session ledger writers; CLI user commands/hidden process entries. |
| P2-2 | packages/tui ownership is undocumented | AGENTS says apps/backend is the only live lane, but build.zig.zon consumes packages/tui directly. | Classify it as a vendored platform dependency with its own proof lane, or move it under backend. |
| P2-3 | Browser docs exceed checkout truth | apps/frontend is fully ignored, about 702 MB locally, and has zero tracked files. Public docs call it shipped. | Call it a local prototype until a tracked consumer, tests, and packaging path exist. |
| P2-4 | Public proof numbers and capability claims drift | README source count, architecture test counts, installed hashes, write-intent, probing, DAP, eval, and ticket closure claims are stale or false. | Generate small factual metrics during release and keep future contracts separate from shipped status. |

## External harness harvest

| Reference | Mechanism worth inheriting | VANTARI decision |
|---|---|---|
| [Opik](https://github.com/comet-ml/opik) and the operator clipping | Bad trace → causal diagnosis → proposed diff → explicit approval → exact-input rerun → regression case. | Use this as the repair state machine. Preserve approval and deterministic replay; do not call observability self-repair. |
| [Prime Agent](https://github.com/PrimeIntellect-ai/prime-agent) | Daemon-backed sessions, goals, heartbeats, schedules, persistent IPython, and snapshot/rollback refinement. | Harvest process-survival and refinement conflict checks. Reject its unsandboxed model-Python default. |
| [Eve](https://github.com/vercel/eve) | Durable indexed event streams, guarded cancellation, and filesystem-first artifacts. | Carry exact ledger position through every client event and guard cancellation against the observed turn. |
| [oh-my-pi](https://github.com/can1357/oh-my-pi) | Real persistent Python/Bun, composable DAP, true stream-rule interruption, typed subagents, and an Agent Hub. | Use as the capability-truth bar for eval, DAP, TTSR, and agent detail. Keep VANTARI's smaller footer. |
| [pi](https://github.com/earendil-works/pi) | Minimal footer plus a lean synchronous append/in-memory session index. | Show unknown instead of fabricated precision; retain the lean append shape but add VANTARI's concurrency and recovery evidence. |
| [OpenHands Runtime](https://docs.openhands.dev/openhands/usage/architecture/runtime) | Action/observation boundary, sandbox-owned execution, deterministic runtime images, and locked resource allocation. | Add a capability profile for sandboxed execution rather than widening full access into a universal mode. |
| [OpenAI Codex](https://github.com/openai/codex) | Typed items, scoped instructions, cancellation pressure, compact plan state, and one bounded rollout writer that owns order and flush. | Preserve segment-per-concern context and serialized append ownership; avoid extension forests and channels where one session-ledger state is enough. |
| [OpenAI Agents SDK sessions](https://openai.github.io/openai-agents-python/sessions/) | Concurrent first writes require atomic ordering inside the shared session store. | Make same-session sequence allocation a mechanical writer invariant, not a caller convention. |
| [Goose](https://block.github.io/goose/) | Recipes, MCP, subagents, and explicit security/sandbox surfaces. | Keep skills demand-loaded and make security profiles visible capability contracts. |

## Self-repair contract

The clipping's useful invariant is not automatic editing. It is closure of the post-trace loop:

~~~mermaid
stateDiagram-v2
    [*] --> FailureReceipt
    FailureReceipt --> CausalDiagnosis
    CausalDiagnosis --> CandidatePatch
    CandidatePatch --> Approval
    Approval --> IsolatedApply
    IsolatedApply --> ExactInputRerun
    ExactInputRerun --> RegressionLock: invariants pass
    ExactInputRerun --> Rollback: regression or mismatch
    RegressionLock --> [*]
    Rollback --> CausalDiagnosis
~~~

VANTARI currently owns FailureReceipt and part of ExactInputRerun. It does not yet own a deterministic causal diagnosis record, baseline conflict detection, exact approved patch receipt, side-by-side invariant evaluation, or regression-suite promotion. The repair loop must remain gated until all of those are persisted and replayable.

## Work-in-progress accountability

| Chain or request | Filesystem state | Source truth | Accounted status |
|---|---|---|---|
| 021 Codex subscription auth | 021a-b archived; 021c-f pending | Live chain at 021c. It overlaps provider/auth owners and must precede any 035 installed provider proof that changes the same surfaces. | Open; unchanged by this audit. |
| 035 provider cost and compat | 035a-f archived; 035g-h pending | Cost/telemetry client code exists and source tests cover it. The current artifact is installed, but no current live provider event plus installed /status proof exists. | Implemented in source, not closed. Keep 035g/h pending. |
| 036 ticket pool and repair | 036a-g archived; parent remains pending | Process-persistent pool, process-exclusive scheduler leadership, serialized claim/child admission, and queue-only assignment now pass in source. Durable agent mail and active-turn owner-crash reconciliation remain open. | Historical closeout remains superseded. Continue with moves 26–30 before parent archival. |
| PLUG plugin socket | Parent and PLUGa-h pending; no archived units | Unstarted chain. Built-ins remain the only default capability surface. | Open, lower priority than integrity findings. |
| Full access mode | Default false; one shared resolver and ExecutionContext projection | Source tests are green. Installed `config/set` flipped the key to true in an isolated workspace and returned `var1.config_set.v1` in 5 ms. | Installed and source proof complete for the setting path. |
| TUI footer and child summary | Source implements compact telemetry, surface tint hierarchy, Agents completed/total, and bounded child summary | Focused TUI tests pass 61/61 and the current source binary is installed. | Functional source proof complete; installed visual matrix remains pending. |
| Settings hang | Settings state tests cover open, apply, close, reopen, timeout, and remote errors. | Local RPC calls have method deadlines and retired late IDs; server admission, session ownership, buffer projection, shutdown cancellation, child exit/tree termination, and reader drain are bounded. Installed transport proof completed in 1.1 s with zero surviving process. | Closed with moves 5–11 and finding 10. |

## Proof ledger

| Probe | Result |
|---|---|
| apps/backend ReleaseFast build | 9/9 steps succeeded. |
| Canonical isolated graph | 19/19 steps; 1,933/1,933 tests across integration, executable, TUI, memory, chain 035, and host lanes. One loop executes all 53 registry cases; 45 wrappers that left ten cases undiscovered are removed. |
| Backend TUI lane | 61/61 passed, including exact same-millisecond render identity, gap catch-up, observed-run cancellation, settings open/apply/close/reopen/timeout, and remote-error handling. |
| Host lifecycle lane | 238/238 passed, including atomic same-session admission, session-keyed buffer projection, exact-generation cancellation, single terminal settlement, cancellation-before-join shutdown, deadlines, and Job Object ownership. |
| Admission and buffer races | 100 contenders produced one turn owner and 99 non-starters; a losing prompt was retained as a steer. A→B buffer switching rejected late A state. |
| Summary concurrency | 100 synchronized upserts retained every session with unique sequences; latest-row projection, v1 import, shared valid-prefix parsing, and poisoned-tail append refusal pass. Dupe audit found zero production-owner duplicates. |
| Message append concurrency | 100 synchronized mixed-role appends retained 100 unique monotonic rows. Bounded tail initialization remains independent of transcript length, while a poisoned current tail now blocks append instead of hiding later records. |
| Shared JSONL integrity | Event latest/all/suffix, message, context, intent, and summary projections stop at one typed BOM/UTF-8/JSON/schema/sequence boundary. Installed replay preserved the prefix before duplicate/torn rows, append left the 107-byte poison file unchanged, source/installed hashes match, and zero process remained. The 124-segment GGUF audit found zero exact pairs. |
| Installed session ledgers | Disposable `VANTARI_HOME` imported 1,176/1,176 legacy summary rows, appended one terminal summary through `session/send`, retained 1,177 unique summary sequences, wrote contiguous unique `user,assistant,tool,assistant` messages, emitted 12 unique monotonic event notifications, returned contiguous sequences 2–12 after `after_seq=1`, reconstructed stdout `0080E280A8FF` and capped stderr `FF010080E280A8FE` from two typed deltas, and ended on one stored/notified `turn_terminal` at sequence 12 with schema `var1.turn_terminal.v1`, outcome `completed`, and `run_seq = 1`; the live legacy SHA-256 was preserved and zero VANTARI processes remained. |
| Terminal settlement | Completed, failed, timed-out, cancelled, and empty-success source probes each persisted exactly one `turn_terminal` bound to the active `session_started.seq`. Repeated identical settlement was idempotent; stale, conflicting, malformed, and duplicate settlement failed closed. |
| Active shutdown | A real blocked provider request observed cancellation before join, returned `cancelled`, fenced late starts, and passed 20 repeats. Move 19 now routes that close through the sole `turn_terminal` writer. |
| Installed generation cancellation | The move-18 race returned `stale_run` for observed sequences 1 and 6 while newer work survived; exact sequence 11 returned `requested`, then the kernel exited 0 with zero processes. Its legacy terminal writer is superseded by move 19. |
| Direct-test isolation | Wrapper rerun kept 99,960 files / 693,051,144 bytes and config/auth hashes unchanged; one generated cache-owned home; zero VANTARI processes. |
| git diff --check | Exit 0; line-ending warnings only. |
| Last installed-proven ReleaseFast SHA-256 | Move-19 source/installed artifact `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`; exact match at that gate. Current source is `77A2B111DCA35AA08E4D33973D83AB2FB9783E6C4D423A09611D24F0EE3142FD`; replacement remains blocked by the preserved operator pair. |
| Scheduler and ticket admission | Barrier race: one guard/one unavailable. Native two-kernel proof: one unique attempt, one ticket claim, one matching child session, one nonzero generation shared by scheduler and ticket, empty stderr, final zero. Evidence root `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1`. |
| Ticket assignment and policy | Create-as-assigned plus transition-to-assigned produce two queued tickets, zero claims, zero active sessions, and zero session records. Four dead policy keys are deleted. The 94-segment GGUF audit found one import/declaration adjacency candidate, zero exact pairs, and no duplicate queue or execution owner. |
| Installed settings transport | `initialize` plus `config/set` returned in 5 ms; isolated runtime removed; live config/auth/lease and full tree metrics unchanged; zero processes. |
| Installed process boundary | Forced parent termination also removed its kernel child through the shared Windows Job Object; zero VANTARI processes remained. |
| Smoke-harness correction | The first settings smoke inherited live `VANTARI_HOME` and rotated only the expired scheduler `lease.json` (one-byte timestamp-width change). Config, auth, summaries, and process inventory were unchanged. The retained script now pins a disposable workspace and proves the live lease hash unchanged. |
| Structural deep-audit fallback | 902 non-Zig source/docs files indexed; one legacy marker and 43 stale markers. The packaged semantic engine does not parse Zig, so this is supporting evidence only. |

## Test-isolation incident

The first broad test command inherited production VANTARI_HOME. The code in [runtimeRootForWorkspace](../../apps/backend/src/shared/fsutil.zig#L191) gives that environment variable precedence over the temporary workspace. The test process therefore created live-looking state under C:\Users\Savage\.vantari.

Observed audit-owned contamination:

- 130 session directories created or updated between 09:43:57 and 09:51:26.
- 512 session files, 17 changelog files, and 4 todo files touched.
- 535 files and 2,214,002 bytes in the incident window.
- The legacy `sessions/summaries.json` object then contained 1,194 rows; 18 of the 130 generated IDs were present.
- changelog/_log.md was rewritten during the run.

No destructive cleanup was attempted because the installed TUI remained active and timestamp-only selection could include legitimate concurrent operator work. The cleanup obligation is recorded in [12-test-isolation-and-runtime-hygiene.md](../todo/findings/12-test-isolation-and-runtime-hygiene.md): stop the exact process pair, snapshot the runtime root, identify generated IDs from the test interval and fixtures, quarantine rather than delete, rebuild projections, and read back every retained row.

Resolution on 2026-08-12: after all installed owner processes exited, a full
pre-repair snapshot was retained at
`C:\Users\Savage\.vantari-backups\2026-08-12-test-isolation-incident-pre-repair`.
The exact generated set was classified by source literals, then 129 session
directories, 16 changelog directories, 18 summary keys, and 64 known test rows
were moved to
`C:\Users\Savage\.vantari-quarantine\2026-08-12-test-isolation-incident`.
The quarantine contains a manifest and rollback script. Readback found zero
incident rows in live sessions, summaries, or changelog and preserved auth.

A follow-up direct `zig test` stress command bypassed `build.zig` environment
injection and created 21 shutdown-probe sessions: 84 files and 19,401 bytes.
Every row carried the exact prompt marker `stay active until shutdown`; no ID
appeared in summaries or changelog, and config/auth hashes were unchanged. The
payload was copied to
`C:\Users\Savage\.vantari-backups\2026-08-12-host-shutdown-stress-incident-pre-repair`
and moved to
`C:\Users\Savage\.vantari-quarantine\2026-08-12-host-shutdown-stress-incident`.
Both copies produced digest
`0565AFC0EA1D6D65991DEB8280F0BCDD665BBF5D8BC73FEF85A984F9676E838A`.
The quarantine carries a manifest and rollback. `zigw.ps1` and `zigw.sh` now
assign direct tests generated cache-owned runtime roots; the rerun left the live
root byte/count/hash identical.

## Less-code architecture direction

1. **Closed:** one bounded host executor, atomic session admission, session-keyed buffer projection, and cancellation-before-join shutdown replace detached threads, check/set races, and lifetime ambiguity.
2. **Closed for summaries and messages:** append-only summary revisions and one per-session message writer replace whole-object rewrites, global contention, and transcript-length sequence scans.
3. **Closed through the tracked TUI:** one persist-first versioned event envelope carries the stored sequence through stdio and browser projections. The TUI deletes timestamp/text replay heuristics and repairs only a missing suffix. Ignored browser prototypes retain their transport cursor until a tracked consumer exists.
4. Move hidden kernel and worker process entries out of the user CLI switch into narrow host entry modules.
5. Remove model-facing todo_slice and session_record lifecycle duplication. Keep tickets as work truth and summaries as handoff truth.
6. Stop rendering the full tool catalog into every prompt when native tool definitions are already sent. Demand-load examples and unavailable-dependency detail.
7. Gate eval and DAP at their unsafe mutation point until their session-owned runtimes exist. Preserve the implementation obligations in the findings ledger.
8. Split large files only along existing owners. Do not add registries, services, or plugin layers to organize code.

## Ordered closure

1. Protect state: **closed** — tests are isolated, incident rows are quarantined, and legacy runtime-shaped owners are archived without merge.
2. Fix host lifetime: **closed** — bounded executor, deadlines, atomic session admission, synchronized buffer routing, cancellation-before-join stress, and child-process cleanup all pass.
3. Fix persistent arbitration: **owner, scheduler, ticket-admission, and assignment source slices
   closed** — presentation detach, duplicate exclusion, graceful/crash owner
   lifecycle, process-exclusive scheduler generation, process-serialized ticket
   claims, deterministic child identity, queue-only assignment, and cleanup pass.
   Exactly-once active-turn recovery remains.
4. Fix ledgers and replay: **closed** — summary/message mutation, binary-safe
   payload, common prefix salvage, and six synchronized 100-way admission,
   ledger, tracked-TUI replay, and shutdown probes pass four consecutive graphs.
5. Restore capability truth: dead ticket policy is **closed**; persistent eval, composable DAP, real TTSR abort, and one search executable identity remain.
6. Close existing chains in order: 021 frontier, 035 live installed proof, reopened 036 re-review, then PLUG.
7. Promote only after isolated broad tests, adversarial multi-process tests, installed source-hash equality, live provider/tool evidence, and clean child/process exit.

## Residual boundary

This audit plus moves 21–25 proves the current checkout, one reconnectable source
execution owner, 20-way cross-process client convergence, duplicate exclusion,
graceful/crash generation recovery, 100-way atomic same-session admission,
100-way event/message/summary ownership, a 100-owner shutdown fence, 100-event
tracked-TUI replay, ReleaseFast installed binary, disposable summary migration,
isolated settings transport, exact TUI event suffix catch-up, and Windows child
cleanup on this machine. It also proves one scheduler winner, one ticket claim,
 and one matching child session across two complete source kernels, plus
 ledger-only assignment with no execution-policy branch. It does not
prove the current owner path through the installed
binary, a clean clone, another host, a multi-process session writer,
exactly-once mid-turn owner recovery, or a live external-provider turn on this
ReleaseFast binary. Those remain
explicit promotion gates, not implied success.

## Superseding current evidence — Move 41 (2026-08-13)

The earlier residual boundary is a historical snapshot from before the later
closure chain. Move 41 now has its own current owner and proof record at
`[2026-08-13-tui-projection-move41.md](2026-08-13-tui-projection-move41.md)`.
The installed source/consumer path passes 19/19 build steps and 1,967/1,967
tests, the focused TUI lane passes 63/63, and the ReleaseFast/install artifact
hash matches `C65C98363F8DDD9A31F39FAB36F4A280972DCE5E69475AE29DA01FB80A7ABF54`.
The latest-session TUI selector is bounded, sequence-less legacy activity is
not rendered, and live/cold keyed-row projection is equal. The persistent owner
survives presentation detach by design; the exact proof-owned tree was torn
down after installed continuation and blank-TUI checks, leaving zero processes.

## Superseding current evidence — Move 42 (2026-08-13)

Move 42 closes the composer/cancellation surface at
`[2026-08-13-tui-composer-move42.md](2026-08-13-tui-composer-move42.md)`. The
single TUI style owner proves transcript < metadata < composer background
lightness; exact wide and width-40 metadata projections preserve the high-value
fields; and cancellation copy is present only for an active waiting run. The
terminal event clears the cancellation intent, and `/cancel` shares the
generation-bound request owner during an active interjection while idle use is
truthful. The complete Debug graph passes 19/19 build steps and 1,991/1,991
tests; focused TUI passes 75/75; ReleaseFast/install passes 9/9. Installed ANSI
inspection, blank TUI, and `vantari -c` continuation pass with source/installed
SHA-256 `A6E93FA6671256E2755C5DC397747F5E350C6ED7D3DE4BF242AC557B96953072`.
The exact owner tree was torn down after presentation detach and the final
VANTARI process census is zero. Move 43 is the active frontier.

## Superseding current evidence — Move 43 (2026-08-13)

Move 43 closes the session-local prompt-mode boundary. The dedicated harvest and
subtractive decision are recorded at
`[2026-08-13-prompt-mode-move43.md](2026-08-13-prompt-mode-move43.md)`. One
`PromptMode` enum cycles `orchestrate -> build -> align -> plan`; the TUI owns
Shift+Tab, and the next `session/send` carries the selected lower-case label.
The host rejects unknown labels with JSON-RPC `-32602` before session/provider
execution. The executor carries the typed value through every context rebuild,
while `core/prompts/builder.zig` inserts one provider-visible guidance layer.
No tool, access, model, capacity, registry, settings schema, or alternate
executor branch was added.

The Debug graph passes 19/19 steps and 1,996/1,996 tests; focused TUI passes
76/76; ReleaseFast/install passes 9/9. Installed TUI startup accepted
Shift+Tab and blank startup/exit passed. Source and installed SHA-256 match
`145F08FF38FA94D325006B4CC78A8C0EFD83A885E9A2F8DBA6152CFA20BFC1EC`. The
proof-owned owner/kernel tree was explicitly torn down and the final VANTARI
process census is zero. Move 44 is the active frontier.
