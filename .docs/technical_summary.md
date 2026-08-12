---
type: technical-summary
id: docs/technical-summary
status: current
updated: 2026-08-12
owner: apps/backend/src
---

# VANTARI technical summary

VANTARI is a local agent kernel. `apps/backend` is the application/runtime
owner; tracked `packages/tui` is its vendored terminal dependency and owns no
session or executor state. The Zig runtime owns transcript compilation,
provider turns, typed tool spans, process supervision, ticket admission,
child-agent execution, and recovery evidence. TUI and CLI render kernel
projections. `apps/frontend` is an ignored local prototype, not a shipped
tracked client.

## Behavior plane

The model chooses the next eligible action. The prompt envelope controls voice,
pace, initiative, delegation posture, work intensity, narration, and
interaction cadence. The kernel limits that choice to executable capabilities
and owns durability, budgets, evidence, recovery, and explicit
irreversible-action gates.

`core/prompts/builder.zig` supplies the default identity and burst loop when no
workspace system prompt exists. `.var/prompts/system.md` or an explicit
`prompts.system_prompt_file` replaces that default identity. Internal runtime
guardrails remain a separate kernel-owned layer. Developer prompt, persona,
operator guardrails, and operator context are hot-loaded on every prompt rebuild
so behavior changes on the next turn without another executor path.

Behavior changes require prompt-profile proof before runtime policy. The
minimum matrix covers terse/detailed, solo/orchestrated,
conservative/aggressive, and low/high update cadence. Runtime logic is valid
only when prompting cannot enforce the capability boundary.

## Durable execution

```text
input
  -> messages.jsonl transcript
  -> context compiler and checkpoint ledger
  -> provider turn
  -> assistant deltas / reviewed tool spans
  -> events.jsonl event spine
  -> terminal session state and output
```

The full transcript stays append-only. `context.jsonl` is model-visible
projection state, never a second transcript. `sessions/summaries.jsonl` v2 is
the bounded summary ledger used by session navigation and child-agent activity.
Each update appends one stable sequence; readers project the greatest sequence
per session. One host-process mutex owns mutation, and the former keyed v1
object is a one-time migration input only.

## Buffered ticket execution

```text
log_ticket create/transition
  -> durable ticket ledger
  -> assigned queue admission
  -> scheduler lease and claim
  -> AgentService route validation
  -> Supervisor fixed-pool slot
  -> child session and typed evidence
  -> completed/failed/blocked ticket projection
```

Assignment is queue admission. It does not launch a child session directly.
The scheduler claims only when configured capacity is available, then uses the
existing `AgentService` and `Supervisor` owners. There is no second worker
registry or background status bus. Current execution remains process-local:
closing the kernel stops the fixed thread pool, cold recovery marks running
receipts stale, and scheduler leader acquisition is not an inter-process
compare-and-swap. Chain 036 is therefore reopened by the current findings.

## TUI projection contract

- The footer is one compact metadata row: model, effort, context used/capacity/percentage, remaining capacity, active agents, pool pressure, and assigned queue pressure when non-zero. `Esc cancel` is intentionally omitted from the persistent row.
- A child group row is `Agents completed/total`. The old `waiting on N` filler is removed from the visible structure; terminal failure/cancellation evidence may remain as a suffix.
- A child row is keyed by `group_id + task_id`. Tool lifecycle events update its state marker but do not become the row label.
- At the child `assistant_response` boundary, the supervisor reads the canonical session summary and sends it as the row detail. The TUI compacts whitespace and truncates the summary to the available one-line width, so the visible row is `agent-name - summary…`, not `agent-name - tool_completed`.
- The projection is replayable from typed parent events. It does not scan child transcripts or create a second activity registry.

## Agent access boundary

`runtime.full_access_mode` is `false` by default. The setting propagates from validated config through route/executor copies into `ExecutionContext`; file, search, LSP, and process tools resolve through `fsutil.resolveWithAccessMode`. Restricted mode enforces workspace containment. Explicit full access permits absolute paths and `..` traversal for intended external directories while keeping relative paths anchored at the active workspace. `.var` runtime state, session ledgers, and configured prompt files retain their canonical owners.

## Self-repair boundary

The runtime exposes the evidence needed for repair: typed failures, bounded command output, session ledgers, ticket leases, pool health, and replayable child events. The repair loop is deliberately gated:

```text
trace -> diagnose -> approve exact change -> rerun canonical path -> persist regression evidence
```

Health and TUI telemetry are observability. They do not claim an autonomous patcher or silently mutate code.

## Current proof boundary

- Pinned Zig 0.15.1 ReleaseFast build succeeds: 9/9 steps.
- Six Zig test artifacts receive generated child-process `VANTARI_HOME` values.
  `VANTARI_TEST_ROOT` rejects paths outside `apps/backend/.zig-cache`; 31
  obsolete environment skip guards are removed.
- The complete graph passes 19/19 steps and 1,931/1,931 tests with zero skips.
  Its 224-test host lane executes the formerly dormant stdio client/server and
  shared process-tree tests; the backend TUI lane passes 58/58.
- Parent-shell production-home probes kept 99,960 files, 693,051,144 bytes,
  config/auth hashes, and process inventory unchanged across graph and direct
  proof.
- The broad prompt/tool gate is closed: retired `todo_slice` policy no longer
  leaks into the normal provider payload, duplicate file-inspection prose is
  removed, and tests protect the semantic guardrail instead of capitalization.
- The invalid first broad run is repaired reversibly: 129 generated sessions,
  16 changelog directories, 18 summary keys, and 64 known test rows are held in
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-test-isolation-incident`
  with snapshot, manifest, rollback, and retained-state readback.
- Seven legacy backend runtime-shaped owners are archived without merge under
  `.var/backup/2026-08-12-legacy-backend-runtime`; automatic todo/changelog
  projections now write direct workspace `.var` owners.
- A direct-test wrapper gap created 21 audit-owned shutdown-probe sessions. The
  exact 84 files / 19,401 bytes had zero summary or changelog projection hits;
  matching backup and quarantine payload digest
  `67CAC4665502DE0ABEC1FA59783DDE09F792DF6BE684CEBBEBBC24868FFA7B2F`
  plus rollback are retained. `zigw.ps1` and `zigw.sh` now isolate direct
  `zig test` invocations as well as the build graph.
- `Server` owns one bounded four-worker/32-request executor. Local RPC calls use
  method deadlines and discard late responses. One shared Windows Job Object
  owns child trees; graceful exit, forced termination, and reader drain are
  bounded.
- Same-session admission is one atomic transition; losing prompts become bounded
  steer messages. Buffer identity and preview share one session-keyed projection.
  Shutdown fences late starts, signals active turns before join, and persisted
  exactly one cancellation terminal event under a blocked provider request.
- Session summaries are append-only v2 rows with stable sequence identity,
  latest-row projection, poisoned-suffix continuation, and one-time v1 import.
  One hundred concurrent writers retained all 100 rows; the local GGUF dupe
  audit found zero candidate pairs across the summary, store, and fsutil owners.
- Every session message role now routes through one per-session append owner.
  One hundred mixed concurrent writers retained 100 unique monotonic rows, and
  cold-start sequence initialization reads the valid bounded tail instead of the
  full transcript.
- Built and installed ReleaseFast SHA-256 both equal
  `3E1B87D8AFD02FA37AE08396B89288E95DB7329D35C1683725B087E2929F124A`.
- Installed `session/send` against a disposable local provider imported all
  1,176 legacy summary rows, appended one terminal v2 row, retained 1,177
  unique sequences, wrote contiguous unique `user,assistant` message rows,
  preserved the live legacy hash, and left zero process.
- The installed settings smoke flips `runtime.full_access_mode` to `true` in a
  disposable workspace, receives `var1.config_set.v1` in 5 ms, removes the
  isolated runtime, preserves the complete live root, and leaves zero process.
- Moves 5–13 and finding 10 are closed. Finding 13 is narrowed to exact event
  transport/replay identity and shared byte-integrity work; persistent agent
  execution and inter-process scheduler arbitration remain P0.
- The hive direction is assigned to moves 21–30 and finding 11. The target is
  one durable direct/group/parent mailbox over session/event ownership,
  selective summary/artifact awareness, and nested normal sessions. No general
  mailbox, restart-safe unread cursor, or peer wake path is shipped yet.
- `git diff --check` exits 0 with line-ending warnings only.

See [`research/2026-08-12-full-harness-sitrep.md`](research/2026-08-12-full-harness-sitrep.md)
for the complete evidence and [`todo/findings/00-INDEX.md`](todo/findings/00-INDEX.md)
for the executable closure order. The value-ranked implementation order is
[`roadmap/24-harness-capability-next-90.md`](roadmap/24-harness-capability-next-90.md).
[`workspace.json`](workspace.json) carries
the machine-readable boundary and [`../AGENTS.md`](../AGENTS.md) remains the
normative contract.
