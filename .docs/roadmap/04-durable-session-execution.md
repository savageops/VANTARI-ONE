# 04 — Durable Session Execution & Cold-Start Recovery

**Priority: P0**

## The seam

A session is a durable execution unit. Shards make this harder: a parent session now has branches that must survive process death, and cold-start recovery must reconcile the whole shard graph, not just one linear session. The canonical contract is `session.json` (lifecycle) + `messages.jsonl` (transcript) + `context.jsonl` (checkpoints) + `events.jsonl` (spine) + `output.txt` (terminal projection).

## What exists today

- `.var/sessions/<session-id>/` with the five canonical artifacts.
- Sessions survive restarts, overflow, provider failure.
- Prefix salvage of torn/poisoned JSONL (AGENTS.md §II).
- Stale-owner reconciliation (a dead process leaves truthful state for the next client).
- `session/create`, `session/send`, `session/get`, `session/compact`, `session/send (follow-up)`.

## What the competitor does (Eve)

Eve is built on **Temporal** (`packages/eve/src/execution/workflow-runtime.ts`, `turn-workflow.ts`, `workflow-steps.ts`). This is its most significant architectural investment:

- Every turn is a durable Temporal workflow; every step is a `"use step"` boundary that commits session state atomically.
- `turnWorkflow` loops: `turnStep` → `cursor.adopt(result)` → next step, with `park`/`done`/`cancelled`/`dispatch-workflow-runtime-actions` terminal actions.
- `TurnExecutionCursor` carries `serializedContext` + `sessionState` across the durable boundary.
- Cancellation settles as parking, never as failure.
- `durable-session-store.ts` reads/writes durable session state.

**Limitation:** Temporal is a heavyweight external dependency (a workflow engine + server-orchestrated durability). Eve pays for it with a large runtime surface and an external operational model. VANTARI's entire premise is **one binary, zero runtime dependencies**. Temporal gives Eve durable steps; VANTARI gives itself the same guarantee with filesystem JSONL ledgers and no orchestrator.

## Why VANTARI does it better

1. **Zero-dependency durability.** Eve needs Temporal (a workflow engine). VANTARI gets durable steps from append-only JSONL + sequence-addressed checkpoints. The AGENTS.md remote-deployment boundary keeps the relay a thin client; the kernel owns recovery.
2. **Prefix salvage, not replay.** VANTARI's JSONL readers preserve valid prefix state across poisoned suffixes, torn writes, BOMs, duplicated sequence IDs, malformed trailing rows. Eve relies on Temporal's replay of workflow history.
3. **Stale owner reconciliation.** VANTARI reconciles sessions whose process owner died. Eve's model assumes the Temporal server stays up.
4. **Shard graph cold start.** VANTARI can reconcile the whole shard graph (parent + branches) from `session.json` + `context.jsonl` + `events.jsonl` after a crash. Eve's Temporal handles one workflow's history, not a branch topology.

## Pipeline items under this theme

### P0-4a: Fix the scheduler shutdown segfault (blocking)
- **Contract:** `VAR1 health --json` and `VAR1 tools --json` emit payload then segfault from the scheduler thread during shutdown (`std.Thread` deadlock). This blocks every CLI command that uses the stdio kernel bridge.
- **Mechanism:** repair child-kernel/scheduler shutdown ownership; the scheduler thread must be drained and joined before process exit.
- **Test:** a cold-start process test runs `VAR1 health --json` and `VAR1 tools --json` and asserts clean exit (exit code 0, no segfault).
- **Proof:** installed binary proof on Windows (`%LOCALAPPDATA%\Vantari\bin\vantari.exe`).
- **This is the current top blocker** per `2026-07-13` research.

### P0-4b: Shard-graph recovery
- **Contract:** cold start reconciles a parent session + N branches. Open branches are marked `abandoned` if their owner is dead; converged branches are immutable.
- **Mechanism:** `session.json` lifecycle + `shard_checkpoint` status fields; stale-owner reconciliation extends to branches.
- **Test:** kill a process mid-branch, cold-start, and the branch is marked `abandoned` while the parent is recoverable.
- **Proof:** session/event evidence of the reconciliation.

### P0-4c: Byte-level session integrity
- **Contract:** JSONL append/read paths detect torn writes, BOMs, invalid UTF-8, duplicated sequence IDs, poisoned trailing rows — without corrupting valid prefix state (AGENTS.md roadmap item 14).
- **Mechanism:** the append/read path is the single owner; tests cover each corruption class.
- **Test:** an adversarial suite writes each corruption class and asserts the valid prefix survives.
- **Proof:** the same suite runs on the installed binary.

## North-star link
Shards are worthless if they cannot survive a crash. Durable execution is what makes a branch "resume-safe" — the exact property the north star's "each window is a checkpoint" requires. Cold-start recovery of the whole shard graph is the guarantee that makes branch-and-converge trustworthy.

## Definition of done
- Scheduler shutdown segfault repaired and proven on installed Windows.
- Cold start reconciles the full shard graph.
- Byte-level integrity: every corruption class is caught, valid prefix survives.