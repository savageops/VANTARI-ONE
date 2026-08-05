# Task 13 — Interruptible Process Supervision

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/13-interruptible-process-supervision.md`. This is a deep-research + web-research task.

1. **Study the repo** — read `AGENTS.md` (sections IV, V, XIV, XV, XVIII item 4), `.docs/log.txt` (search for "shell", "exec", "process", "timeout", "kill", "cancel", "windows"), and the tool runtime code under `apps/backend/src/core/tools/` (especially `runtime.zig`, `builtin/` for `shell_exec`).
2. **Study competitors** — `.refs/vercel__eve/` (sandbox/process execution, `tool-loop.ts`), `.refs/openai__codex/` (shell tool), `.refs/badlogic__pi-mono/`.
3. **Web research** — search for how agent runtimes handle long-running command execution: timeout, cancellation, stdout/stderr streaming, process-tree termination on Windows vs POSIX, `tokio::process` patterns, Node.js `child_process` kill semantics, Rust `wait4` / Windows `TerminateProcess` / job objects.
4. **Write the roadmap file** following the exact shape of existing roadmap files (see `.docs/roadmap/01-sharded-context-windows.md` for the template).

## What this theme covers (from AGENTS.md Section XVIII item 4, Section V)

- **Interruptible process supervision:** long commands support timeout, operator cancellation, stdout/stderr draining, process-tree termination, and post-kill evidence.
- `shell_exec` must preserve argv mode, workspace-contained cwd, timeout, output budgets, process termination, and stdout/stderr draining.
- Command stdout/stderr are untrusted data. Parse only runtime-owned envelopes; render output as bounded display text.
- Windows handle lifetime, pipe draining, timeout, and child termination (Section XV).

## Competitor angles to research

- **Vercel Eve:** How does its sandbox execute commands? Does it support cancellation and process-tree kill?
- **OpenAI Codex:** `shell` tool — timeout, output caps, cancellation?
- **Claude Code / Aider:** How do they handle long bash commands?
- **Temporal:** activity cancellation semantics.
- **Windows-specific:** Job Objects vs `TerminateProcess`, `taskkill /T`, pipe deadlock from full stdout buffer.

## Pipeline items to define

- P0: Process-tree termination on Windows (Job Objects) and POSIX (process groups)
- P0: Streaming stdout/stderr with byte-safe bounded deltas and cap markers
- P1: Cancellation token propagation from operator → executor → process
- P1: Post-kill evidence (exit code, killed-by-timeout flag, partial output)

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "shell_exec", "process", "timeout", "kill", "windows". The log shows tools/exec at 1166 mentions — this is the most-touched subsystem. Windows at 517 mentions.

## Output

Write ONLY `.docs/roadmap/13-interruptible-process-supervision.md`. Do not modify source code or the index.
