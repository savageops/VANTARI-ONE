---
type: research
id: fixed-pool-capacity-truth
status: accepted
date: 2026-08-13
roadmap_move: 28
---

# Fixed-pool capacity truth

## Problem

`apps/backend/src/core/agents/supervisor.zig` owns one bounded
`std.Thread.Pool`, but its current capacity projection collapses two different
quantities into `available`: idle worker slots and admission headroom after
already queued work. It exposes no idle count. The health fixture compounds the
ambiguity by reporting `max=4`, `running=1`, `queued=2`, and `available=3`, even
though only one new ticket can be admitted under the current contract.

The pool also starts once and ignores later `agent_routes.max_concurrency`
values. Because the Settings surface can mutate that key while the execution
owner remains alive, the configured fixed capacity can diverge from the actual
worker ceiling. Replacing the pool while work is running would be false and
unsafe; keeping the first value forever would make the setting inert.

## Reference pressure

| Reference | Retain | Reject |
|---|---|---|
| `.refs/openai__codex/codex-rs/core/src/agent/registry.rs` and `agent/registry_tests.rs` at `9eadff97130e074bb26cedd1c281b76ed062053f` | Reserve against one shared atomic active ceiling before spawn; release the slot on failed or terminal ownership. | Codex's separate thread registry and agent tree as a second VAR1 pool owner. |
| `.refs/openai__codex/codex-rs/core/src/tools/handlers/agent_jobs.rs` | Compute dispatch slots from `max_concurrency - active_items`, fetch only that pending prefix, and return a limit-raced item to pending. | Its separate job database and polling loop; VAR1 already has ticket and supervisor owners. |
| `.refs/badlogic__pi-mono/packages/coding-agent/examples/extensions/subagent/index.ts:27-28,556-618` at `3e0ee69b5ead441e4669b123b2f98635fee7da30` | A fixed worker loop is enough to bound execution. | Initializing every placeholder as “running”; queued and active are different states. |
| `.refs/vercel__eve/packages/eve/src/harness/workflow-subagent-limit.ts:4-60` at `5e3119b309cb92441a7a1d2bbc85dc59242dac29` | Preserve request order when a finite budget admits only a prefix. | Treating a lifetime call budget as a concurrency mechanism. |
| Zig 0.15.1 `lib/std/Thread/Pool.zig:33-67,216-303` | `n_jobs` is the physical active ceiling; submitted closures remain on one run queue and shutdown joins workers. | Replacing the standard pool with an unneeded custom worker implementation. |
| [OpenAI Agents SDK running agents](https://openai.github.io/openai-agents-python/running_agents/) | Separate model permission to emit parallel calls from the runtime ceiling that executes them. | SDK callback/config layers around VAR1's existing supervisor. |
| [Google ADK parallel workflow](https://adk.dev/agents/workflow-agents/parallel-agents/) | Keep branches independent and collect explicit results. | Starting every listed branch without one kernel-owned capacity gate. |
| [LangGraph graph API](https://docs.langchain.com/oss/python/langgraph/use-graph-api) | Apply one explicit `max_concurrency` to concurrently executing work. | Graph/superstep state as another orchestration owner. |
| [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) | Keep active contexts costly and expose idle/team state compactly; scale only when parallel work benefits. | No hard runtime ceiling and shared task-list ownership. |
| [Microsoft Agent Framework orchestrations](https://learn.microsoft.com/en-us/agent-framework/workflows/orchestrations/) | Keep sequential, concurrent, handoff, and manager behavior as orchestration choices above execution mechanics. | Pattern-specific capacity implementations. |

## Harvested invariant

One configured ceiling owns execution. Keep four quantities distinct:

```text
active/running = tasks executing provider work
idle           = max - running
queued         = admitted tasks not executing yet
available      = max - running - queued, saturated at zero
```

`running <= max` is an invariant and must be tested, not hidden by clamping.
`queued` may exceed `max` for one model-selected batch; it is backlog, not a
worker count. Ticket admission uses `available`, so assigned tickets remain in
the durable ticket queue instead of entering the supervisor behind admitted
work.

## Sprout Method

Extend the current owners only:

1. Give `AgentCapacitySnapshot` one constructor that derives `idle` and
   `available` from `max`, `queued`, and `running` without overflow.
2. Make `Supervisor.capacityLocked` and the unstarted capacity projection use
   that constructor. Do not duplicate arithmetic in RPC or clients.
3. Let `Supervisor.start` refresh the physical pool when the requested config
   differs and no submitted pool entry remains. Return the actual ceiling so a
   busy pool never reports an unapplied value.
4. Count submitted pool entries until their closures return. This closes the
   terminal-event race where a task is terminal but its worker still touches
   supervisor state.
5. Re-read config through the existing `AgentService` entrypoints. A busy pool
   drains at its actual ceiling; the next capacity/launch read applies the new
   value at the idle boundary. Add no pending-capacity ledger or worker daemon.
6. Carry `idle` through the additive health protocol and CLI/TUI read models.
   Keep the steady-state TUI footer unchanged until Moves 41-45 own its display.

## Tracer code

Before production changes, add tests that fail unless:

1. an unstarted projection reports `running=0`, `queued=0`, `idle=max`, and
   `available=max` without creating worker threads;
2. an idle started pool changes from the first configured ceiling to the next;
3. a real 20-task batch configured at three workers reaches contention while
   every sampled snapshot preserves `running <= max`, `idle=max-running`, and
   saturated admission headroom;
4. the same run exposes queued backlog separately and never exceeds three
   simultaneous provider calls;
5. terminal release returns `running=0`, `queued=0`, `idle=max`, and
   `available=max`;
6. health and CLI JSON/text projections carry the coherent idle/admission
   values instead of fixture-only arithmetic.

## Rejected shapes

- **A second logical pool:** duplicates Supervisor authority.
- **Sixty-four permanently resident worker threads:** makes hot capacity easy by
  spending idle process resources and violates the configured physical ceiling.
- **A custom resizable worker runtime:** replaces proven Zig mechanics for one
  setting transition.
- **Immediate resize while tasks run:** either kills valid work or reports a
  ceiling the physical pool cannot yet honor.
- **Clamp `running` to `max`:** conceals the exact invariant the contention test
  must falsify.
- **Use `idle` for ticket admission:** ignores already admitted queued work and
  overclaims tickets.

## Decision boundary

Move 28 changes capacity truth and safe idle-boundary reconfiguration only. It
does not add crash reconciliation, leases, a worker roster, footer expansion,
or a new scheduling policy. Move 29 owns durable owner recovery; Moves 41-45
own compact operator display.

## Landed mechanism and proof

- `AgentCapacitySnapshot.fromCounts` is the sole arithmetic owner. Supervisor,
  eligibility, health, CLI, and TUI carry its active, idle, queued, and available
  values without recomputation.
- `Supervisor.pool_entries` spans submission through closure return. Config
  changes cannot replace the pool during terminal-event persistence or queued
  execution; the next idle capacity/launch read replaces the same pool.
- The red tracer first failed because `AgentCapacitySnapshot` had no `idle`
  field. The landed 20-task run reaches three simultaneous provider calls with
  queued backlog, preserves `running <= max`, reports the old ceiling while a
  reduction drains, then reports one idle/available worker after release.
- Debug and ReleaseFast test graphs pass 19/19 steps and 1,947/1,947 tests.
  ReleaseFast build passes 9/9. Source SHA-256 is
  `6E6A80054C4982AA9F1D86E9415B2422A4F7B7670080795243A91818279A360A`.
- The packaged GGUF audit covers eight files and 256 segments: 12 candidate
  pairs, zero exact duplicates, and no second capacity owner.
- Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`.
  Operator-owned PIDs 12028 and 14452 remain untouched; Move 38 owns replacement.
