---
type: architecture-decision
id: roadmap-21-persistent-execution-owner
status: in_progress
source_state: complete
updated: 2026-08-13
owners:
  - apps/backend/src/host/http_bridge.zig
  - apps/backend/src/host/owner_client.zig
  - apps/backend/src/host/owner_state.zig
  - apps/backend/src/host/stdio_client.zig
  - apps/backend/src/host/stdio_rpc.zig
  - apps/backend/src/core/config/workspace.zig
  - apps/backend/src/core/agents/service.zig
  - apps/backend/src/core/agents/supervisor.zig
roadmap_move: 21
---

# Persistent execution owner

## Objective

Detach presentation lifetime from execution lifetime. Keep one owner tree, one
`agents.Service`, one `Supervisor` pool, one scheduler, and one descendant
process boundary per workspace. Closing a TUI or short-lived CLI client must not
cancel claimed work.

Move 21 does not add a daemon framework, second scheduler, agent proxy, work
queue, session store, or provider executor. Moves 22-30 consume the same owner.

## Repository truth

### Process ownership

Evidence: `apps/backend/src/clients/cli.zig:623-640`,
`apps/backend/src/host/stdio_rpc.zig:354-532`.

Observation: `kernel-stdio` constructs exactly one `agents.Service`, then the
stdio host constructs the scheduler and buffer services around that handle.

Impact: this composition root already owns every long-lived execution
primitive. Moving pool or scheduler construction would create a parallel
runtime.

Confidence: high.

Action: keep kernel composition unchanged and place one reconnectable owner in
front of it.

### Client lifetime

Evidence: `apps/backend/src/host/stdio_client.zig:167-305`,
`apps/backend/src/shared/process_tree.zig:50-89`.

Pre-change observation: every `LocalClient` spawned `kernel-stdio`, assigned it to a
kill-on-close Windows Job Object, and terminates that process tree during
client deinitialization.

Pre-change impact: TUI exit was execution exit. Separate CLI invocations created
separate process-local pools.

Confidence: high.

Implemented action: the process-spawning type is now private `ChildClient`;
public `LocalClient` is a reconnecting owner facade.

### Existing reconnect seam

Evidence: `apps/backend/src/host/http_bridge.zig:20-181` and
`apps/backend/src/host/bridge_access.zig`.

Observation: the loopback bridge already fronts one kernel client with generic
RPC and event delivery. It is the smallest existing inter-process seam.

Impact: promoting it reuses the kernel protocol and preserves all downstream
service owners. A new named-pipe protocol or file request ledger would duplicate
working transport semantics.

Confidence: high.

Action: add an owner-only exact RPC lane and make the public client facade
connect to it.

### Dead detached-session claim

Evidence: `apps/backend/src/clients/cli.zig:643-725,1674-1692`.

Observation: the former `run-session` command described itself as a detached
launcher primitive, but no launcher called it. It executed directly without
`AgentService`, so a launched session would also lose nested delegation and
shared capacity.

Impact: the help text overstates capability and points toward a second
execution owner.

Confidence: high.

Action: move 22 deleted the dead launcher-shaped path. `run --session-id` already
submits through `LocalClient` and owner `session/send`.

### Arbitration gap at the move-21 boundary — closed by move 23

Evidence: `apps/backend/src/core/scheduler/store.zig:266-290` and
`.docs/todo/findings/11-persistent-agent-worker-and-scheduler-arbitration.md`.

Historical observation: scheduler leadership was read/check/write and could not
exclude a second process. Move 23 replaced it with the shared crash-released
process lock plus a read-back nonzero generation fence.

Impact: scheduler leadership and ticket admission are now process-exclusive in
source. Reconnect must still not be treated as exactly-once ticket execution
until move 29 reconciles owner death.

Confidence: high.

Action: move 21 establishes one owner tree; moves 23 and 24 close scheduler and
ticket arbitration; move 29 closes recovery before move 30 promotion.

## Competitor harvest

Retrieved 2026-08-12. Each source contributes an invariant, not an architecture
to copy.

| Source | Proven mechanism | Harvest | VANTARI exceed axis |
|---|---|---|---|
| [Prime Agent architecture](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/architecture.md), [daemon](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/daemon.md), and [long-running agents](https://github.com/PrimeIntellect-ai/prime-agent/blob/main/packages/coding-agent/docs/long-running-agents.md) | Client is presentation; a resident owner retains workers, descendant kernels, generation/sequence state, and directed messages across detach. | Detach presentation from execution; use ready handshakes and generation identity. | Keep one workspace owner tree instead of supervisor/worker forests; retain stronger append-only session/event integrity. |
| [OpenAI Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md) and [app-server daemon](https://github.com/openai/codex/blob/main/codex-rs/app-server-daemon/README.md) | Typed RPC server plus serialized, idempotent daemon start with readiness and bounded stop. | Reuse one RPC contract; start returns only after verified readiness. | Prove the lifecycle on Windows, where the cited daemon remains Unix-oriented. |
| [OpenHands agent server](https://docs.openhands.dev/sdk/guides/agent-server/overview) and [runtime](https://docs.openhands.dev/openhands/usage/architecture/runtime) | Local HTTP/WebSocket server keeps the client API stable and exposes one action/observation event stream. | Preserve the existing client contract while moving execution behind loopback IPC. | Keep the kernel event spine as source truth; do not add a second runtime event model. |
| [Temporal worker performance](https://docs.temporal.io/develop/worker-performance) and [`sdk-go/worker`](https://github.com/temporalio/sdk-go/blob/master/worker/worker.go) | Long-lived workers own polling, concurrency, and backpressure. | Capacity belongs to the resident worker, not each client or ticket assignment. | Reuse `Supervisor.capacity`; avoid a general workflow platform. |
| [Scion daemon](../../.refs/savageops__scion/pkg/daemon/daemon.go) at pinned commit `2fad47cf` | Same executable starts a background component, persists PID/log state, and exposes start/stop/restart/status. | Use the current executable and a small lifecycle projection. | Add a real readiness handshake, generation, serialized start, and process-tree proof instead of PID plus delay. |
| [NullClaw daemon](../../.refs/nullclaw-main/src/daemon.zig) | One process owns gateway, heartbeat, scheduler, channels, atomic shutdown, joins, and a state projection. | One composition owner and explicit join order. | Reuse VANTARI's existing kernel services; do not recompose them in a daemon module. |

Transferable invariant: presentation may reconnect; execution ownership does
not move. Start is serialized and idempotent. Readiness proves workspace,
generation, protocol, and executable identity. The resident owner controls
capacity, descendants, and shutdown.

Dominance target: fewer owner concepts than Prime Agent, Windows-native
lifecycle proof beyond Codex's current daemon, stronger byte-level ledgers than
all six, and no new pool, queue, scheduler, transcript, or event bus.

## Alternatives

| Candidate | Decision | Reason |
|---|---|---|
| Promote the existing loopback bridge into the persistent owner tree. | Commit | Reuses generic RPC/events and preserves the sole kernel composition root. |
| Add an agent-only daemon and proxy `AgentService`. | Reject | Duplicates every service method, splits live status/cancellation/event sinks, and creates two execution authorities. |
| Keep `kernel-stdio` alive after stdin EOF. | Reject | No reconnect endpoint; the next client still creates a second kernel. |
| Spawn one detached `run-session` process per session. | Reject | Loses shared pool capacity, scheduler ownership, nested delegation, and live supervision. |
| Add a file request queue under `.var`. | Reject | Creates a second queue and lifecycle beside tickets, RPC, and events. |
| Install an OS service or scheduled task. | Reject | Adds privilege, installer, and global lifecycle scope before a project-local owner is proven. |
| Copy Prime Agent's supervisor plus per-root workers. | Reject | More processes, protocols, and recovery owners than the fixed-pool product needs. |
| Rebuild the bridge as an in-process kernel. | Defer | Removes one child process but duplicates the proven stdio composition path now; reconsider only after profiling or lifecycle proof shows the child boundary is the bottleneck. |

## S3 decision

Promote `http_bridge` as the one persistent owner process for a workspace. It
owns one private child-kernel client; that kernel continues to own the sole
`AgentService`, `Supervisor`, scheduler, buffer, sessions, tools, and event
spine. This is one owner tree even though the proven stdio isolation boundary
retains one supervised child process.

Rename the current process-spawning `stdio_client.LocalClient` implementation
to `ChildClient`. Introduce a public `LocalClient` facade that resolves or starts
the workspace owner and uses the existing RPC and event contracts. The bridge
must instantiate `ChildClient`, never the facade; a structural test locks this
recursion boundary.

The owner writes an atomic projection under project-local `.var` only after the
listener and child kernel answer a readiness probe. The projection carries a
versioned schema, workspace identity, PID, port, random owner token, generation,
protocol version, executable path, and start time. Clients
trust the projection only after a live handshake returns matching workspace and
generation.

Browser bridge access remains redacted. The owner facade uses a separate
loopback route and token that return exact kernel JSON; assistant output must
never pass through browser redaction.

Falsifier: reject this decision if the tracer constructs a second
`AgentService`, a second scheduler/pool, a second work ledger, leaks the browser
token as owner authority, redacts an exact RPC result, or kills the owner when a
client deinitializes.

## Method gates

### Harvest reflex — passed

Six current or pinned implementations were decomposed above. The selected
mechanism inherits only lifecycle invariants and reuses VANTARI owners.

### Wrap Method

Characterize the existing child client first. Preserve its framing, deadlines,
notification sequencing, Job Object cleanup, and kernel diagnostics. Wrap it
behind the bridge; do not rewrite it while changing ownership.

### Tracer code

1. Start an owner in the foreground against an isolated workspace.
2. Bind an ephemeral loopback port.
3. Construct one private `ChildClient`; wait for real kernel `health/get`.
4. Write the generation projection atomically.
5. Connect one public facade and call the same real `health/get`.
6. Destroy the facade and prove the owner plus kernel remain alive.
7. Connect a second facade and prove the same generation and kernel session
   inventory are returned.

Do not implement detach/restart policy until this path passes.

## Hazard review

| Hazard | Required guard |
|---|---|
| Facade/bridge recursion | `Bridge.initLocal` accepts only `ChildClient`; compile-time or focused structural test. |
| Duplicate startup | One cross-process lifecycle lock plus generation-checked live handshake. |
| Stale state or PID reuse | Never trust PID alone; require matching workspace, generation, protocol, and live health. |
| Exact data redacted | Separate owner-only exact routes from browser routes. |
| Detached connection thread outlives bridge | `OwnerLifecycle` admits at most 64 connections, counts every detached job, rejects work after stop, wakes accept, and drains to zero before bridge deinit. |
| Owner dies mid-turn | Existing session/event ledgers retain causality; move 23 supplies exclusive scheduler leadership, move 24 supplies serialized claim/child identity, and move 29 adds reconciliation. |
| New client binary speaks to old owner | Protocol/version and executable identity mismatch returns a typed restart-required result; never silently mix. |
| Installed binary locked by active operator pair | Build and prove in an isolated workspace; do not replace or terminate operator-owned processes. Promote installed proof only after their natural exit. |

## Implementation receipt

- `owner_client.LocalClient` resolves the shared workspace policy, validates one
  ready owner outside the startup lock, and lets losing concurrent starters poll
  the projection instead of serializing behind a lock convoy.
- Windows owner spawn uses `CreateProcessW` with handle inheritance disabled,
  breakaway-from-job requested, and a pre-resume Job Object probe. This removes
  the inherited PowerShell capture pipe that caused Settings/CLI hangs.
- `owner_state` owns one start lock, one lifetime lease, and the atomic
  `.var/runtime/execution-owner.json` projection. The operating system releases
  the lease on crash; stale files are identity hints only.
- `http_bridge` owns exact `/owner/health`, `/owner/rpc`, `/owner/events`, and
  generation-bound `/owner/shutdown` routes. Browser `/rpc` and `/events` retain
  redaction and separate authority.
- Foreground `serve --port <port>` and automatic `execution-owner` startup hold
  the same lifetime lease. `--host` was removed: owner control remains loopback
  and no remotely bound second owner surface is retained.
- `stdio_client.ChildClient` remains the sole child process transport. Its
  shutdown closes stdin under the same mutex as calls/notifications, keeps the
  reader alive for terminal responses, and drains the Job-owned child tree.

## Proof ledger

| Gate | State | Required evidence |
|---|---|---|
| Six-source competitive harvest | passed | Matrix and source links above. |
| Repository ownership recon | passed | Existing host/client/service paths above. |
| Foreground tracer | passed | `prove-owner-tracer.ps1` passes for both `execution-owner` and `serve`: real kernel health, one generation, two reconnects, owner/kernel alive after client detach. The hidden-owner tracer injects a conflicting inherited `VANTARI_WORKSPACE`; explicit `--workspace .` remains authoritative. Final roots: `.zig-cache/owner-proofs/c7ac3f1fb3634ae6b2fb5e8787eb01b4` and `.zig-cache/owner-proofs/568e7e6675f04b338820e88807762b95`. |
| Detached reuse | passed | Source clients exit while the exact owner PID, child PID, generation, and state hash remain live. |
| Duplicate-start pressure | passed | `prove-owner-lifecycle.ps1` reports 20/20 clients against one first owner/kernel; foreground `serve` rejects a duplicate with `code=AlreadyRunning`. Final lifecycle root: `.zig-cache/owner-proofs/a9035dcbf5e945c7942a46885c896458`. |
| Stale-owner recovery | passed for owner lifecycle | Graceful stop and forced owner death each produce one new generation. Forced crash leaves the owner and Job-owned kernel at zero before recovery. Running-turn exactly-once reconciliation remains move 29. |
| Shutdown cleanup | passed | Connection jobs drain, child stdin closes, Job cleanup completes, and the lifecycle tracer reports `final_zero_processes: true`. |
| Canonical graph | passed | Pinned Zig 0.15.1: current graph 19/19 steps and 1,976/1,976 tests, including stalled-owner socket-deadline, explicit-workspace precedence, retired-launcher, owner-submission, shared process-lock, scheduler race, ticket-ledger exclusion, and deterministic-session falsifiers; final ReleaseFast 9/9. |
| Duplicate ownership | passed | GGUF audit inspected 110 segments across nine owner-adjacent files: two import/declaration adjacency candidates, zero exact duplicates, and no second lifecycle, workspace, transport, or process-tree owner. |
| Source artifact | passed | Current `zig-out/bin/vantari.exe` SHA-256 is `DF57FB34112E0D1125D50620995EDF2683711D546B359226F504D2C4A03C6C00`; hidden-owner tracer root `.zig-cache/owner-proofs/9de64f4dbfe9483684875605ad39de10` remains the owner-path proof, and scheduler/ticket root `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` proves the current two-kernel admission slice. |
| Installed Windows proof | blocked | Installed SHA-256 remains `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`. Operator-owned installed TUI PID 12028 and kernel PID 14452 remain active; replacement is move 38 after natural exit. |

## Rollback

Keep `ChildClient` behavior intact. If the tracer fails, remove only the public
facade, owner routes, lifecycle projection, and command surface; restore the
`LocalClient` export alias to `ChildClient`. No session, event, ticket, agent,
provider, or scheduler schema changes are permitted in this slice.
