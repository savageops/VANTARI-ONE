---
type: roadmap
id: roadmap/06-parent-child-delegation
status: active
priority: P0
updated: 2026-08-07
phase: p0_7_complete_p1_active
research: ../research/2026-08-06-agent-scale-reset.md
---

# 06 — Role-routed agent execution

## Gate decision

**Priority: P0.** Correct the orchestration control plane before adding more named agents.

VANTARI keeps one runtime and three execution kinds:

```text
deterministic invariant -> kernel
bounded typed model transform -> model_task
iterative specialist with tools/state -> agent_session
```

Every model-backed kind resolves a role through one provider/model route owner. Every full specialist is a normal VAR1 child session. No agent receives a parallel transcript, tool runtime, event bus, or provider stack.

## Shipped truth

- `core/agents/spec.zig` owns seven stable specialist ids and binds each to one immutable execution kind, capability profile, route role, budget, and output contract.
- `core/providers/routes.zig` resolves each role to provider, model, wire API, thinking mode, and budgets without exposing credentials to the model-visible task socket.
- `core/agents/supervisor.zig` runs admitted work through one fixed `std.Thread.Pool`, indexes groups and parents in memory, signals completion through a condition, and scans session ledgers only during explicit cold recovery.
- `core/agents/service.zig` persists a secret-free execution receipt before dispatch, admits `{ context, tasks[] }`, restores recoverable groups, and converges one group exactly once.
- `core/executor/loop.zig` parks a parent on the group condition with zero provider dispatches, compiles convergence once, then performs one synthesis turn.
- `core/tools/runtime.zig` consumes the resolved capability profile at catalog construction and dispatch. Unsupported tool classes fail before side effects.
- parent `events.jsonl` receives bounded child control events. Assistant and reasoning deltas remain in the child ledger instead of flooding the parent event spine.
- `clients/tui_chat.zig` renders Search, Explore, Agents, and To-dos through one stable group/item grammar with status markers, nested rails, and cold-replayed terminal state.
- `core/prompts/builder.zig` owns bounded action bursts, durable checkpoint summaries, and continuation after checkpoints or first-child convergence. Project prompt overrides cannot remove this runtime contract.

P0 is complete. P1 remains active for normalized provider usage and routing existing compaction/title/classification owners through the model-task lane.

P0-7 reopens the control-plane boundary for operator-editable specialist personas. It does not add another execution kind, transcript owner, tool runtime, or provider resolver.

## Reference pressure

### Oh My Pi

Keep:

- one batch fan-out call with per-item agent id and output contract
- named agent definitions backed by centrally remappable model roles
- bounded concurrency
- progress on one stable tool span
- recursion and capability policy at admission

Reject:

- the lifecycle/registry/URL/isolation/plugin forest as a prerequisite
- raw model/provider names in the model-facing task schema
- a full agent session for deterministic compaction, scheduling, classification, or merge mechanics

### Vercel Eve

Keep:

- child = durable session
- parent cancellation propagates to active children
- child control events project into the parent stream
- waiting work parks without holding compute
- use a skill when specialist identity is unchanged

Reject:

- Workflow SDK as a second execution owner
- separate remote stream subscription as the only way to see ordinary local child progress

### Runtime primitives

The Zig 0.16 `std.Io.Group` spike failed the repository dependency gate because the current dependency graph still consumes removed `std.io` APIs. The shipped Zig 0.15.1 implementation uses one fixed `std.Thread.Pool` plus `std.Thread.Condition`; it preserves parent-owned admission, bounded concurrency, wait, cancellation, and terminal reconciliation without a toolchain fork. Revisit `std.Io.Group` only after dependencies compile unchanged on Zig 0.16.

Full evidence and source ledger: [`2026-08-06-agent-scale-reset.md`](../research/2026-08-06-agent-scale-reset.md).

## Target ownership

| Contract | Owner | Invariant |
|---|---|---|
| `RouteRole` | `core/providers/routes.zig` | role resolves provider, model, wire API, thinking, and budgets without exposing credentials |
| `AgentSpec` | `core/agents/spec.zig` | specialist id resolves instruction capsule, enforced capability profile, route role, budget, spawn policy, and output contract |
| `ExecutionReceipt` | `shared/types.zig` + `core/sessions/store.zig` | every model task or child persists the resolved secret-free execution contract before dispatch |
| `ChildGroup` | `core/agents/supervisor.zig` | parent-owned admission, bounded concurrency, condition signal, cancellation, terminal reconciliation, and exactly-once convergence |
| admission/recovery | `core/agents/service.zig` | one batch enters the supervisor only after validation and receipt persistence; ledger scans are cold recovery only |
| batch dispatch | `core/tools/builtin/agents.zig` | one canonical `tasks[]` shape for one or many children |
| wait/park | `core/executor/loop.zig` | pending children cause zero provider dispatches |
| child projection | parent `events.jsonl` + clients | one versioned event grammar drives CLI/TUI/browser read models |

## P0-7 contract: hot-loaded specialist registry

`config.json.agents.definitions` is the only editable specialist registry. A definition is a fixed conditional persona over one compiled capability floor:

```text
compiled base id
  + enabled / description / when_to_use / instruction
  + route_role / bounded budgets / output_contract
  -> hot-loaded AgentSpec
  -> immutable execution receipt at admission
```

- Built-in ids may be edited or disabled. Removing their config row resets them to the compiled floor.
- New ids must `extends` one built-in id. Inheritance fixes `execution_kind` and `capability_profile_id`; config cannot add arbitrary tools, code, credentials, or provider endpoints.
- `agents {}` returns only route-resolved eligibility, capacity/team aggregates, communication choices, and a deterministic receipt. It never injects instruction capsules or child transcripts into the parent context.
- `launch_agent` resolves the selected id from a fresh registry read. A launched child keeps its receipt even when config changes afterward.
- `configure_agent` performs an atomic config mutation and validates the full effective registry before commit.
- `agents.orchestrator_only = true` limits the root catalog to agent-control tools and requires one current `agents {}` snapshot before launch or config mutation; it does not require discovery as the first turn action. Child profiles keep their inherited capability floors.
- Child sessions receive only explicit shared context, one finite task, their private instruction capsule, and the output contract. They never inherit the parent transcript.
- Each terminal child result converges exactly once. The parent condition wakes on the first unconsumed terminal child, rebuilds through the context compiler, and may synthesize, delegate more work, or park again while siblings continue.

### P0-7a — Registry and discovery

- [x] Add the editable `agents` config section and strict schema validation.
- [x] Resolve built-in overrides and custom inherited personas from a fresh config read.
- [x] Add compact `agents {}` discovery and remove the hard-coded launch enum.
- [x] Add atomic `configure_agent` upsert/reset/disable capability with effect evidence.
- [x] Prove malformed ids, unknown bases, capability escalation, empty registries, and stale selection failure.

### P0-7b — Orchestrator isolation

- [x] Add the root-only orchestrator catalog and discovery-before-dispatch gate.
- [x] Keep child tool catalogs bound to the inherited profile, not root policy.
- [x] Prove the parent transcript is absent from every child prompt unless explicitly supplied in `context`.
- [x] Prove config edits hot-load on the next discovery and launch without restarting the kernel.

### P0-7c — First-result continuation

- [x] Move convergence consumption from whole-group state to per-child state.
- [x] Wake the parked parent when any unconsumed child becomes terminal.
- [x] Compile ready child results exactly once while unfinished siblings remain active.
- [x] Prevent terminal parent completion while supervised children remain active.
- [x] Prove completion, failure, cancellation, cold recovery, and simultaneous completion races.

### P0-7d — Burst checkpoint harness

- [x] Require bounded think/act/observe/checkpoint bursts instead of one front-loaded reasoning pass.
- [x] Persist operator-visible checkpoint summaries in transcript/context history without requesting private chain-of-thought.
- [x] Treat a checkpoint as continuation evidence, not terminal output; continue until proof or a named blocker.
- [x] Keep the burst/checkpoint contract runtime-owned so custom system/developer prompt files cannot remove it.
- [x] After a child returns, checkpoint what converged and route the next bounded slice immediately when work remains.

## State machine

```text
group_created
  -> child_admitted*
  -> child_queued*
  -> child_running*
  -> child_waiting_review | child_waiting_input | child_terminal
  -> child_convergence_ready
  -> child_convergence_committed
  -> parent_running
  -> group_terminal
  -> parent_synthesis_terminal
```

The parent moves `running -> waiting_children -> compiling_convergence -> running`. `waiting_children` performs no provider call.

## Pipeline

### P0-6a — Falsify the current path

- [x] Prove parent waiting performs provider dispatch today, then lock the target at zero dispatches.
- [x] Prove two child groups cannot duplicate or cross-consume completed children.
- [x] Prove runtime profile denial, not profile metadata.
- [x] Instrument live status lookup and set the target at zero session-directory scans.
- [x] Preserve the failing evidence before replacing the path.

### P0-6b — Route role, AgentSpec, execution receipt

- [x] Reuse `auth.readProviderById()`; do not add another credential owner.
- [x] Resolve `role -> provider/model/wire/thinking/budgets` once per run.
- [x] Persist the secret-free receipt in `session.json` before dispatch.
- [x] Enforce the AgentSpec profile at tool catalog, dispatch, delegation, and budget boundaries.
- [x] Prove two provider ids, two wire APIs, and two models without changing the active provider.

### P0-6c — Group identity and exactly-once convergence

- [x] Add `group_id`, parent checkpoint id, and monotonic branch sequence to every child receipt and event.
- [x] Converge only terminal, unconsumed members of one group.
- [x] Append one idempotent convergence receipt and bounded parent-context projection.
- [x] Remove hard-coded convergence `branch_seq = 1`.
- [x] Prove overlapping groups finish, fail, cancel, and converge independently.

### P0-6d — Structured supervisor

- [x] Spike Zig 0.16 `std.Io.Group`; preserve the dependency failure and reject a partial toolchain migration.
- [x] Run child executor entries through a fixed Zig 0.15.1 `std.Thread.Pool` under a hard concurrent limit.
- [x] Signal terminal transitions through the live supervisor index; rebuild that index from ledgers only at cold start.
- [x] Cascade parent cancellation to every active group member.
- [x] Delete process spawn, detached watcher, 10 ms poll, and live full-directory lookup after installed Windows proof.
- [x] Reject a worker-process isolation profile because the falsification suite did not require it.

### P0-6e — Canonical batch socket and parent park

- [x] Change the model-visible launch shape to `{ context, tasks[] }`; route one item through the same primitive.
- [x] Validate unique names, specialist ids, spawn depth, budgets, output schemas, and admission before effects.
- [x] Replace the synthetic supervision prompt with `waiting_children`.
- [x] Compile group results once and perform one synthesis provider turn.
- [x] Return typed `var1.child_group.v1` results; remove internal parsing of `AGENT_NAME ...` text.

### P1-6f — Typed child projection

- [x] Append `child_group_started`, `child_admitted`, `child_started`, `child_progress`, `child_waiting`, `child_finished`, and `child_group_finished` to the parent event spine.
- [x] Include group id, child session id, agent spec id, route role, capability profile, monotonic sequence, and terminal failure detail.
- [ ] Normalize provider usage in `CompletionResponse`, then add token usage to child receipts and terminal events.
- [x] Render one keyed child row and one group summary in the TUI.
- [x] Reuse the same marker/rail grammar for Search, Explore, Agents, To-dos, and tool-output children.
- [x] Replay the same projection after cold start without a second status bus.

### P1-6g — Model-task lane

- [x] Add a tool-free, recursion-free, schema-bound `model_task` executor over the same route resolver.
- [x] Register `planner`, `compactor`, and supplied-artifact `reviewer` model-task specs.
- [ ] Route the existing manual compaction writer plus future classification/title owners through the model-task lane without moving checkpoint selection into the model.
- [x] Keep checkpoint selection, admission, scheduling, cancellation, retry classification, and merge mechanics in deterministic kernel code.
- [x] Upgrade a model task to `agent_session` only when iterative tools, independent state, or recovery are proven requirements.

## First shipped specialists

| Id | Kind | Default capability | Default role |
|---|---|---|---|
| `general` | `agent_session` | scoped read/write/command/delegation | `general` |
| `recon` | `agent_session` | read/search, no write, no child spawn | `recon` |
| `planner` | `model_task` | supplied context, no tools | `planning` |
| `compactor` | `model_task` | supplied artifacts, no tools | `compaction` |
| `implementer` | `agent_session` | scoped read/write/command, no child spawn | `implementation` |
| `reviewer` | `model_task` | supplied artifacts, no tools | `review` |
| `validator` | `agent_session` | read/search, no write, no child spawn | `validation` |

Agent ids remain stable when the operator remaps roles to a different API or model.

## Proof gate

- [x] 1, 5, 20, and 100 fixture children respect configured admission and concurrency caps.
- [x] in-process profiles keep OS process count constant.
- [x] concurrent threads stay under the configured runtime ceiling.
- [x] parent provider-call count is independent of child wall time.
- [x] healthy status/wait is O(1); recovery scan is cold-start only.
- [x] route receipts survive resume and expose no secret.
- [x] capability denial holds at catalog and dispatch.
- [x] parent cancellation produces terminal evidence for every child.
- [x] TUI shows queued/running/waiting/failed/completed state from typed events.
- [x] Hot-load upsert/reset changes the route-eligible snapshot on the next `agents {}` call without restart.
- [x] Bounded-burst checkpoint instructions survive project-local prompt overrides.
- [ ] current eligibility receipt reproduced by installed `%LOCALAPPDATA%\Vantari\bin\vantari.exe`; move 38 owns replacement after active operator processes exit.

## Installed proof

- Full Zig 0.15.1 mesh: `1541/1541` tests passed across `15/15` build steps.
- ReleaseFast installed binary SHA-256: `F22F89A425FEE37CBC0F6868A30B61C4362D48A75EADF9C43893E3CF5A993389`.
- Live parent `session-1786054776392-4aa6b6b11363365f` launched planner child `session-1786054787881-450b26e512e8c859` in group `group-1786054787880-30b9c9504fc3cf23`.
- The persisted receipt resolved `planning -> zai / glm-5.2 / chat_completions`, enforced `model_task`, set `max_tool_calls = 0`, and contained no API key.
- Parent control evidence occupied sequences `67-78`: group start, admission, queue, start, one model-task progress row, park, child terminal, group terminal, convergence start, and one convergence commit.

## North-star link

A full child remains a shard: parent checkpoint + branch input + independently resolved execution receipt. A model task is a cheaper typed projection when a full shard is unnecessary. A kernel primitive never pretends to be an agent. All three converge through one context compiler and one event spine.
