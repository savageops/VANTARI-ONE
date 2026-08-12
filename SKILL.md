---
type: skill
name: vantari
description: Operate and validate the VANTARI local agent kernel through its canonical owner, CLI, TUI, session, tool, and evidence surfaces.
---

# VANTARI operator skill

Use this skill to run, inspect, configure, or validate VANTARI without creating a
second runtime owner.

## Start

1. Resolve the project root and read `AGENTS.md`, `.docs/technical_summary.md`,
   and `.docs/workspace.json`.
2. Run commands from `apps/backend` through `scripts/zigw.ps1` or the installed
   `vantari.exe`.
3. Call `vantari health --json` before a provider turn. Treat unavailable tools,
   auth, or provider routes as capability boundaries.

## Execute

```powershell
.\scripts\zigw.ps1 build test --summary all
.\zig-out\bin\vantari.exe health --json
.\zig-out\bin\vantari.exe run --prompt "Inspect the workspace and return a SITREP."
.\zig-out\bin\vantari.exe serve --port 4310
```

- TUI and CLI attach to one project-local execution owner.
- Foreground `serve` is the visible form of that same owner. Do not start a
  separate bridge, pool, scheduler, or `kernel-stdio` process.
- `.var/sessions/<id>/` is source truth. Read `messages.jsonl`, `context.jsonl`,
  `events.jsonl`, `session.json`, and `output.txt` as separate owners.
- Assignment admits ticket work to the queue. It does not launch an agent.
- Change behavior through prompt layers. Keep kernel logic for capability truth,
  durability, budgets, evidence, recovery, and irreversible-action gates.

## Validate owner lifecycle

```powershell
.\scripts\prove-owner-tracer.ps1 -BinaryPath .\zig-out\bin\vantari.exe -EntryPoint serve
.\scripts\prove-owner-lifecycle.ps1 -BinaryPath .\zig-out\bin\vantari.exe -ConcurrentClients 20
```

Require one generation, one owner/kernel pair, duplicate-start rejection,
graceful/crash recovery, and zero proof-owned processes. Installed promotion also
requires source/installed SHA-256 equality and the installed consumer path.

## Boundaries

- `runtime.full_access_mode` defaults to `false`; enable it explicitly for
  intended cross-directory work. It never relocates `.var`.
- `search_files` requires `iex`. Do not hide an `rg`, `grep`, or `sed` fallback.
- Browser routes are redacted prototypes. Owner routes are loopback-only and
  token/generation gated.
- Scheduler leadership is source-proven with one crash-released lock and
  generation fence across two kernels. Mid-turn owner-crash reconciliation,
  serialized ticket claim/lease issuance, and durable agent mailboxes remain
  roadmap work. Do not infer them from the leadership proof.

Read `README.md`, `apps/backend/architecture.md`, and
`.docs/roadmap/24-harness-capability-next-90.md` for deeper contracts.
