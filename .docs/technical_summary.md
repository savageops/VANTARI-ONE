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
projection state, never a second transcript. `sessions/summaries.json` is the
current bounded summary projection used by session navigation and child-agent
activity. Its whole-object read/modify/write path is not concurrency-safe; the
current findings require an append-only replacement before calling it a
durable multi-agent ledger.

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
- Every Zig test artifact now receives a generated child-process
  `VANTARI_HOME`. `VANTARI_TEST_ROOT` rejects runtime paths outside the Zig
  cache root, and 31 obsolete environment skip guards are removed.
- The isolated broad graph executes and passes 1,695/1,695 tests with zero
  skips. A parent-shell production-home probe kept live file count, byte count,
  and the complete relative-path/content tree SHA-256 unchanged.
- Focused backend TUI passes 54/56 with two skipped tests.
- The tracked terminal package passes 103/104 with one skipped test.
- The broad prompt/tool gate is closed: retired `todo_slice` policy no longer
  leaks into the normal provider payload, duplicate file-inspection prose is
  removed, and tests protect the semantic guardrail instead of capitalization.
- A first broad run inherited production `VANTARI_HOME`, read live auth, and
  touched 535 runtime files. That run is invalid as proof and is recorded as a
  P0 test-isolation incident.
- Current built ReleaseFast SHA-256 is
  `ED189470EB55CF8A9333FA31CA04C155F681DEA56E364B31C1D3294FCD42243F`.
  Installed SHA-256 remains
  `7B12904FBEE46E2C741C17DCDAF677B85C2A5AB6AB4A4D9C6B7234F841993C5D`.
  The hashes do not match.
- Installed PIDs 23376 and 25192 exited without intervention. A later TUI/kernel
  pair started as PIDs 10624 and 33816; it is preserved, so live quarantine and
  reinstall remain gated.
- Full-access mode and the revised TUI/settings source lanes have focused proof
  but no current installed-binary proof.
- Settings still has an open hang boundary: the local RPC client waits without
  a response deadline and waits for child exit without a shutdown timeout.
- `git diff --check` exits 0 with line-ending warnings only.

See [`research/2026-08-12-full-harness-sitrep.md`](research/2026-08-12-full-harness-sitrep.md)
for the complete evidence and [`todo/findings/00-INDEX.md`](todo/findings/00-INDEX.md)
for the executable closure order. The value-ranked implementation order is
[`roadmap/24-harness-capability-next-90.md`](roadmap/24-harness-capability-next-90.md).
[`workspace.json`](workspace.json) carries
the machine-readable boundary and [`../AGENTS.md`](../AGENTS.md) remains the
normative contract.
