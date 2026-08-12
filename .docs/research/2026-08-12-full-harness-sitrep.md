---
type: research
id: docs/research/2026-08-12-full-harness-sitrep
status: current
updated: 2026-08-12
scope: full-harness
---

# VANTARI full harness SITREP

## Executive verdict

VANTARI has a strong kernel thesis and several unusually good local mechanisms: one context compiler, append-only transcript and event ledgers, typed tool review and dispatch, bounded Windows process execution, provider-wire separation, fixed in-process agent capacity, and a compact TUI read model. The architecture is materially better than a chat-wrapper harness.

The current checkout is not production-ready for persistent autonomous execution. Its critical gap is not model intelligence or UI polish. Agent process ownership, inter-process scheduler arbitration, and client replay identity still stop at the process boundary. Host request lifetime, test isolation, append-only summary mutation, and per-session message sequencing are now closed with installed proof; the fixed agent pool and event notification cursor still prevent crash-surviving autonomous execution. Chain 036 closed over in-process proof while the user requirement was persistent execution through process failure.

Current classification:

| Axis | State | Boundary |
|---|---|---|
| Build | Pass | ReleaseFast builds 9/9 with Zig 0.15.1. |
| Focused TUI | Pass | Backend TUI 58/58 with zero skips. |
| Broad tests | Pass | Canonical isolated graph is 19/19 and 1,931/1,931 with zero skips. |
| Installed proof | Pass for moves 1–13 | Source and installed ReleaseFast share SHA-256 `3E1B87D8AFD02FA37AE08396B89288E95DB7329D35C1683725B087E2929F124A`; disposable settings and session-ledger probes exit with zero processes. |
| Agent pool | In-process only | A process restart converts running receipts to StaleAgentOwner; no detached worker launch is wired. |
| Ticket persistence | Partial | Ticket events persist, but leader lease acquisition is read/check/write without an inter-process compare-and-swap. |
| Event replay | Partial | Stored events have sequence numbers; stdio notifications discard them and the TUI deduplicates by timestamp, type, and text. |
| Self-repair | Evidence floor only | Trace, diagnostics, and rerun substrate exist; causal diagnosis, approved patching, exact-input replay, and regression locking do not form one runtime loop. |

No broad runtime rewrite was made during this audit. The worktree already contains 55 modified tracked files plus a large untracked implementation set, and the installed process is active. Current findings are converted into the executable ledger at [../todo/findings/00-INDEX.md](../todo/findings/00-INDEX.md).

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
| Process entry | [main.zig](../../apps/backend/src/main.zig) | Selects TUI, continuation, CLI, or kernel-stdio mode. |
| Kernel composition | [stdio_rpc.zig](../../apps/backend/src/host/stdio_rpc.zig) | Composes session, executor, agents, scheduler, buffer, and JSON-RPC. |
| Local client transport | [stdio_client.zig](../../apps/backend/src/host/stdio_client.zig) | Spawns the same executable in kernel-stdio mode and waits for framed replies. |
| Turn execution | [loop.zig](../../apps/backend/src/core/executor/loop.zig) | Compiles context, streams provider output, reviews tools, emits events, and closes turns. |
| Context | [context/](../../apps/backend/src/core/context/) | Sole transcript/checkpoint to provider-message compiler. |
| Sessions | [sessions/](../../apps/backend/src/core/sessions/) | Session lifecycle, messages, checkpoints, events, output, and summaries. |
| Provider wires | [providers/](../../apps/backend/src/core/providers/) | Chat Completions, Responses, and Anthropic request/stream adaptation. |
| Tools | [tools/](../../apps/backend/src/core/tools/) | Catalog, availability, review, runtime dispatch, and built-ins. |
| Agents | [agents/](../../apps/backend/src/core/agents/) | Route specs, execution receipts, in-process fixed pool, and child convergence. |
| Tickets | [tickets/](../../apps/backend/src/core/tickets/) | Ticket event ledger, transition rules, claims, leases, and projection. |
| Scheduler | [scheduler/](../../apps/backend/src/core/scheduler/) | Scheduled jobs, ticket wake/claim, heartbeat, and stale reconciliation. |
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
    participant K as kernel-stdio child
    participant H as Host services
    U->>T: vantari
    T->>K: spawn same executable
    K->>H: compose scheduler, buffer, agents, executor
    T->>K: framed JSON-RPC
    K-->>T: response and session/event notifications
    U->>T: exit
    T->>K: close stdin
    T->>K: wait without timeout
    K->>H: stop services and in-process pool
~~~

The final two steps are the settings-hang failure class: [LocalClient.deinit](../../apps/backend/src/host/stdio_client.zig#L211) waits on the child without a deadline, and [waitForResponse](../../apps/backend/src/host/stdio_client.zig#L321) waits indefinitely unless a response or reader close arrives. This is a proven unbounded wait. The exact settings request that triggers the operator's hang still needs a captured RPC trace.

### Turn execution

1. session/send admits a session.
2. The context builder compiles system/runtime context, latest checkpoint, and raw transcript suffix.
3. The selected provider adapter emits live deltas and reconstructs tool calls.
4. Tool definitions are reviewed against the active capability set.
5. Tool output and effect evidence append to the event and message ledgers.
6. Overflow rebuilds through the context compiler.
7. The turn closes with a typed turn payload, terminal assistant response, output projection, and summary freshness gate.

The turn pipeline is coherent. The unsafe boundary is host concurrency: session admission uses separate isRunning and setRunning operations in [stdio_rpc.zig](../../apps/backend/src/host/stdio_rpc.zig#L605), so two concurrent requests can pass the check before either sets the flag.

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

The current Supervisor owns a process-local std.Thread.Pool ([supervisor.zig](../../apps/backend/src/core/agents/supervisor.zig#L164)) and dispatches work with pool.spawn ([supervisor.zig](../../apps/backend/src/core/agents/supervisor.zig#L379)). Cold recovery explicitly turns initialized or running receipts into StaleAgentOwner ([service.zig](../../apps/backend/src/core/agents/service.zig#L925)). The hidden run-session command exists ([cli.zig](../../apps/backend/src/clients/cli.zig#L643)), but no runtime caller launches it. Closing the TUI closes the kernel and cancels or waits for the same in-process pool.

Child completion currently reaches the parent through convergence-specific
messages and control events. There is no general peer mailbox, group delivery,
restart-safe unread cursor, or model-selected queue/wake path. The accepted
direction for moves 21–30 is selective awareness: one sequence-addressed
direct/group/parent mailbox over the same session/event owner, canonical
summaries and artifact references on demand, and no shared transcript or topic
broker. Codex supplies queued versus wake-bearing delivery pressure; Claude Code
teams supplies independent contexts plus direct mail; AutoGen supplies typed
target scope. VANTARI must add cold-start replay and fewer concepts.

### Ticket execution

Assignment is correctly modeled as queue admission. The scheduler claims assigned tickets only when AgentService reports capacity. This preserves one capacity owner and avoids a second worker registry.

The persistence claim is incomplete. [tryAcquireLease](../../apps/backend/src/core/scheduler/store.zig#L266) reads lease.json, checks expiry, then atomically replaces the file. Atomic replacement prevents torn files; it does not make the read/check/write sequence mutually exclusive. Two kernels can both read an absent or expired lease and both report success.

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

The replay contract is currently weaker than the UI text suggests. SessionEventNotification omits the stored event sequence ([types.zig](../../apps/backend/src/shared/protocol/types.zig#L68)); the TUI therefore deduplicates by timestamp, event type, and message ([tui_chat.zig](../../apps/backend/src/clients/tui_chat.zig#L666)). Identical same-millisecond events can disappear.

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
| P0-3 | Agent persistence and collaboration are process-local | The fixed pool is in-process; restart reconciliation marks work stale. run-session is advertised but never launched. Completion has a special parent convergence path, but peers lack durable directed/group/parent mail and unread replay. | Make a daemon or detached worker the execution owner while preserving AgentService, Supervisor admission, receipts, and ledgers. Route completion and ordinary bounded mail through one sequence-addressed session/event mailbox. Do not add a second scheduler, shared transcript, or generic broker. |
| P0-4 | Scheduler leader lease can split-brain | [tryAcquireLease](../../apps/backend/src/core/scheduler/store.zig#L266) performs read/check/write with no inter-process lock or CAS. Two kernels can claim leadership. | Claim with a Windows-safe exclusive lock or create/replace protocol that verifies the owner generation after write before dispatch. |
| P0-5 | Summary ledger loses concurrent updates | **Closed 2026-08-12.** The keyed v1 object was last-writer-wins and rewrote the full live ledger. | `summaries.jsonl` v2 appends stable sequenced revisions under one host-process owner, projects the greatest sequence per session, isolates poisoned suffixes, and imports the legacy object once. One hundred concurrent writers retained 100 rows and unique sequences. |
| P0-6 | Broad tests write into live runtime state | **Closed 2026-08-12.** The invalid broad run and a later direct-test wrapper bypass reached the live root. | Six build artifacts and both direct wrappers now assign generated cache-owned homes plus the cache-root guard. The 129-session broad incident and exact 21-session direct incident are backed up/quarantined with manifests and rollback. The 1,929-test graph and direct rerun leave live state unchanged. |
| P0-7 | Secret-shaped legacy state is unignored | **Closed 2026-08-12.** Seven backend runtime-shaped owners existed outside canonical ownership. | All 2,252 files were archived reversibly without merging fixtures into live state. Automatic todo/changelog sync now writes direct workspace `.var` paths; no fallback reader was added. |

### P1 — capability truth and deterministic replay

| ID | Concern | Evidence and effect | Smallest durable correction |
|---|---|---|---|
| P1-1 | Event sequence is dropped before clients | Stored SessionEvent includes seq, but stdio emits only timestamp/type/message/status. Replay suppression is therefore probabilistic. | Define one versioned event notification carrying ledger seq and optional byte payload; make every client cursor seq-based. |
| P1-2 | Message append was O(N²) and not serialized | **Closed 2026-08-12.** Every message role now routes through one per-session ledger state. Cold start scans backward from a 4 KiB tail window and expands only when no complete valid row exists; append failure invalidates the cached cursor. | The removed whole-transcript sequencer and empty-file rewrite stay deleted. Multi-process writer authority remains part of the persistent-host boundary, not a second message lock. |
| P1-3 | eval advertises a capability it does not provide | eval claims persistent Python/Bun, but creates and destroys a kernel per call; Bun is one-shot and ignores timeout. Pipe draining can deadlock. | Gate only the unsafe execution point while keeping the implementation obligation. Rebuild it on the canonical process supervisor and a session-owned kernel registry. |
| P1-4 | DAP calls are non-composable | dap_attach destroys its client before returning; stacktrace and variables spawn fresh unattached adapters, despite usage hints that they continue the attach session. Reads have no deadline. | Make one session-scoped DAP client with request IDs, timeouts, cancellation, and teardown evidence. |
| P1-5 | TTSR does not abort mid-stream | rule_abort_requested is set by a delta callback, but the callback returns normally and correction happens only after provider completion. | Give provider streaming an explicit abort result and prove the network/read loop stops before terminal completion. |
| P1-6 | Shadow owners are documented as shipped | Provider capability cache has no runtime consumer; write-intent reserve/commit is test-only; memory quota counters are not updated. | Wire each through its canonical consumer or label it frontier. Do not preserve dead schemas as pretend capability. |
| P1-7 | Ticket policy knobs do not govern execution | tickets.auto_assign, proactive_workpool, close_authority, and reopen_with_reasoning are parsed and documented but do not drive the scheduler state machine. Default help also says assignment starts an agent, contradicting queue admission. | Remove unused knobs or wire them into the one ticket state machine. Correct help before claiming policy. |
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
| 035 provider cost and compat | 035a-f archived; 035g-h pending | Cost/telemetry client code exists and source tests cover it. No current live provider event plus installed /status proof; installed hash is stale. | Implemented in source, not closed. Keep 035g/h pending. |
| 036 ticket pool and repair | 036a-g archived; parent remains in pending with status complete | In-process queue and UI projection exist. Process survival and inter-process lease safety are unproven and contradicted by source. | Historical closeout is overclaimed. Reopen through P0 findings before parent archival. |
| PLUG plugin socket | Parent and PLUGa-h pending; no archived units | Unstarted chain. Built-ins remain the only default capability surface. | Open, lower priority than integrity findings. |
| Full access mode | Default false; one shared resolver and ExecutionContext projection | Source tests are green. Installed `config/set` flipped the key to true in an isolated workspace and returned `var1.config_set.v1` in 5 ms. | Installed and source proof complete for the setting path. |
| TUI footer and child summary | Source implements compact telemetry, surface tint hierarchy, Agents completed/total, and bounded child summary | Focused TUI tests pass 58/58 and the current source binary is installed. | Functional source proof complete; installed visual matrix remains pending. |
| Settings hang | Settings state tests cover open, apply, close, reopen, timeout, and remote errors. | Local RPC calls have method deadlines and retired late IDs; server admission, session ownership, buffer projection, shutdown cancellation, child exit/tree termination, and reader drain are bounded. Installed transport proof completed in 1.1 s with zero surviving process. | Closed with moves 5–11 and finding 10. |

## Proof ledger

| Probe | Result |
|---|---|
| apps/backend ReleaseFast build | 9/9 steps succeeded. |
| Canonical isolated graph | 19/19 steps; 1,931/1,931 tests across integration, executable, TUI, memory, chain 035, and host lanes. |
| Backend TUI lane | 58/58 passed, including settings open/apply/close/reopen/timeout and remote-error handling. |
| Host lifecycle lane | 224/224 passed, including atomic same-session admission, session-keyed buffer projection, cancellation-before-join shutdown, deadlines, and Job Object ownership. |
| Admission and buffer races | 100 contenders produced one turn owner and 99 non-starters; a losing prompt was retained as a steer. A→B buffer switching rejected late A state. |
| Summary concurrency | 100 synchronized upserts retained every session with unique sequences; latest-row projection, poisoned-suffix continuation, v1 import, and shared JSONL append passed. Dupe audit found zero candidate pairs across summary/store/fsutil owners. |
| Message append concurrency | 100 synchronized mixed-role appends retained 100 unique monotonic rows. A 32,768-line poisoned prefix followed by valid seq 900 continued at seq 901 through bounded tail initialization. The 37-segment GGUF audit found zero candidate pairs across store and summary owners. |
| Installed session ledgers | Disposable `VANTARI_HOME` imported 1,176/1,176 legacy summary rows, appended one terminal summary through `session/send`, retained 1,177 unique summary sequences, wrote contiguous unique `user,assistant` messages, preserved the live legacy SHA-256, and exited with zero VANTARI processes. |
| Active shutdown | A real blocked provider request observed cancellation before join, persisted exactly one `session_cancelled` event, returned `cancelled`, fenced late starts, and passed 20 repeats. |
| Direct-test isolation | Wrapper rerun kept 99,960 files / 693,051,144 bytes and config/auth hashes unchanged; one generated cache-owned home; zero VANTARI processes. |
| git diff --check | Exit 0; line-ending warnings only. |
| Built and installed ReleaseFast SHA-256 | `3E1B87D8AFD02FA37AE08396B89288E95DB7329D35C1683725B087E2929F124A`; exact match. |
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
3. Carry one versioned event envelope from disk to every client. Delete timestamp/text replay heuristics.
4. Move hidden kernel and worker process entries out of the user CLI switch into narrow host entry modules.
5. Remove model-facing todo_slice and session_record lifecycle duplication. Keep tickets as work truth and summaries as handoff truth.
6. Stop rendering the full tool catalog into every prompt when native tool definitions are already sent. Demand-load examples and unavailable-dependency detail.
7. Gate eval and DAP at their unsafe mutation point until their session-owned runtimes exist. Preserve the implementation obligations in the findings ledger.
8. Split large files only along existing owners. Do not add registries, services, or plugin layers to organize code.

## Ordered closure

1. Protect state: **closed** — tests are isolated, incident rows are quarantined, and legacy runtime-shaped owners are archived without merge.
2. Fix host lifetime: **closed** — bounded executor, deadlines, atomic session admission, synchronized buffer routing, cancellation-before-join stress, and child-process cleanup all pass.
3. Fix persistent arbitration: one crash-surviving worker owner and inter-process scheduler lease claim.
4. Fix ledgers and replay: **summary and message mutation closed**; sequence-bearing RPC events, exact client cursors, and common prefix salvage remain.
5. Restore capability truth: persistent eval, composable DAP, real TTSR abort, one search executable identity, and removal of dead policy surfaces.
6. Close existing chains in order: 021 frontier, 035 live installed proof, reopened 036 re-review, then PLUG.
7. Promote only after isolated broad tests, adversarial multi-process tests, installed source-hash equality, live provider/tool evidence, and clean child/process exit.

## Residual boundary

This audit proves the current checkout, atomic same-session admission, active
request shutdown, ReleaseFast installed binary, disposable summary migration,
per-session message append contention/tail initialization, isolated settings
transport, and Windows child cleanup on this machine. It does not prove a clean
clone, another host, a live multi-kernel scheduler race, a multi-process session
writer, or a live external-provider turn on this ReleaseFast binary. Those remain
explicit promotion gates, not implied success.
