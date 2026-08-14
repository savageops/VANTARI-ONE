---
type: research
id: research/2026-08-14-context-shard-projection-move70
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/core/context/builder.zig + apps/backend/src/core/agents/service.zig + apps/backend/src/core/sessions/store.zig
---

# Move 70 — bounded task-branch context projection

## Objective

Give a child session enough parent evidence to make an independent decision
without copying the parent transcript or creating a second context owner. The
parent checkpoint identity must remain durable, the provider projection must be
bounded, and terminal branch output must return as an evidence-bearing parent
checkpoint through the existing supervisor/mailbox path.

## Owner census

- `AgentService.launchBatch` is the canonical launch path. It already resolves
  the latest compiler checkpoint, creates the child session, persists the
  immutable execution receipt, appends the open shard row, and submits one
  `Supervisor` task.
- `Supervisor.runTaskEntry` is the canonical child execution path. The child
  is a normal VAR1 session; no shard worker or second executor is required.
- `SessionStore` owns the append-only parent `context.jsonl` ledger. Shard
  lifecycle rows are graph/recovery evidence, not compiler checkpoints.
- `ContextBuilder` is the only provider-window compiler. It now projects the
  exact receipt-addressed parent checkpoint and a bounded recent suffix into
  the child provider request without writing those rows to the child ledger.
- `Supervisor.commitTask` remains the terminal convergence owner. It reserves
  each child terminal state once, appends one bounded shard result checkpoint,
  and delivers the bounded summary through the existing mailbox boundary.

## Reference pressure

- `.refs/badlogic__pi-mono` branches carry a bounded branch summary into the
  resumed session context instead of treating a branch as a second transcript.
- `.refs/openai__codex` treats thread/fork history and typed items/events as
  durable session evidence; replay is tied to stored identity rather than
  timestamps or UI rows.
- `.refs/can1357__oh-my-pi` keeps sessions, branching, subagents, and typed
  event/RPC boundaries in the same engine/TUI/runtime family.
- `.refs/prime-intellect__prime-agent` is named by the project contract but is
  not present in this checkout. That is a local corpus boundary, not evidence
  that its daemon or RLM mechanism was inspected or copied.

## Compression decision

Keep the mechanism in the existing receipt, compiler, session ledger, and
Supervisor owners. Do not add a shard registry, child transcript copier,
group-level synthetic transcript, polling loop, or new worker pool. A branch is
an execution receipt plus a transient provider projection. Its own
`messages.jsonl` begins with the branch prompt and remains the child source of
truth.

## State machine

```text
launchBatch
  -> parent checkpoint identity in execution receipt
  -> parent open shard lifecycle row
  -> child provider compile: checkpoint summary + <= 64 KiB recent suffix
  -> normal child session/tool loop
  -> Supervisor terminal reservation
  -> <= 16 KiB shard result checkpoint + mailbox summary
  -> parent convergence/wake through existing event/mailbox owners
```

The parent ledger is never copied into the child ledger. A missing or legacy
checkpoint falls back to a bounded recent parent suffix. The fallback preserves
the branch boundary without inventing a parallel summary owner.

## Applied source slice

- `readLatestContextCompileCheckpoint` excludes `shard_checkpoint` lifecycle
  rows when selecting compiler state.
- `readContextCheckpointById` resolves the exact checkpoint named by the child
  receipt.
- `appendParentShardContext` supplies the checkpoint summary and bounded recent
  parent suffix only while compiling the child provider window.
- Raw child context selection remains compiler-owned and normal sessions retain
  their existing unbounded behavior; only the parent projection is bounded.
- Shard checkpoint rows preserve the parent range/token metadata and cap result
  summaries at a UTF-8-safe 16 KiB.
- The adversarial regression proves exact checkpoint evidence, exclusion of an
  old transcript, recent-suffix bounds, and a child ledger containing only the
  branch prompt.

## Proof

- `apps/backend/scripts/zigw.ps1 build test --summary all` — `19/19` steps,
  `2166/2166` Debug tests passed.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` —
  `9/9` source steps passed; source artifact SHA-256 is
  `1E5AFD64D502514FAFC473FA8DD0B8E7B80C905EC52074AB629B1ACAD0157BFE`.
- `zig fmt --check` passes for all four changed Zig owners and the new test;
  `git diff --check` reports no whitespace errors.
- The preserved live installed owner remains SHA-256
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692` with
  execution-owner PID `29908` and kernel-stdio PID `22152`; no install or
  process replacement was performed.

## Boundary

Move 70 is source-complete. The canonical implementation emits one bounded
evidence row per terminal branch, not a new group-level transcript. Installed
promotion and provider-driven live child proof remain deferred by the operator
boundary. Automatic compaction, arbitrary external-effect certainty, and any
future worktree isolation remain separate gates.
