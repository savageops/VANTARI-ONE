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
- `agent_routes.max_concurrency` is the sole ticket execution capacity knob.
  `running` is active, `idle = max - running`, `queued` is admitted backlog, and
  `available = idle - queued` saturated at zero. Config changes apply to the same
  physical pool at its next idle boundary. Do not invent a second pool, pending
  capacity ledger, or restore a `tickets` execution-policy section.
- Treat `resume` as the sole expired ticket-owner transition. It preserves the
  active session, attempt, receipt, transcript, and mailbox cursor under a new
  worker generation. Requeue only when the claimed session is absent. Heartbeat
  requires exact live `Supervisor` ownership.
- Call `agents {}` when the current decision needs collaboration evidence. Read
  `var1.agent_eligibility.v1` for route-resolved specialists, pool/team pressure,
  communication choices, and its SHA-256 receipt. The snapshot is not an order:
  the active prompt may stay quiet, inspect, message, challenge, launch, queue,
  or wake. Launch/configuration still requires a current snapshot.
- `send_agent_message` writes bounded direct, parent, or current-group input to
  the recipient event spine. Use `queue` for the next run and `wake` for the
  next safe boundary of a live run. A message never assigns or launches work.
- Change behavior through prompt layers. Keep kernel logic for capability truth,
  durability, budgets, evidence, recovery, and irreversible-action gates.
- In the TUI, Shift+Tab cycles the session-local prompt lens
  `orchestrate -> build -> align -> plan`; the next `session/send` applies one
  provider-visible layer and defaults to `orchestrate`. It does not change
  tools, access, model, capacity, or executor behavior.
- Use `vantari auth status --json` for secret-free provider/account/plan state.
  Run `vantari auth login openai-codex` for the browser PKCE path or its manual
  redirect fallback; use `vantari auth logout <provider-id>` for one-record
  removal. Never inspect or print token-bearing auth fields.
- OAuth `openai-codex` records route through `core/providers/openai_codex.zig` to
  `/codex/responses` with the stored account id and Codex headers. API-key records
  stay on the existing OpenAI-compatible dispatch; a missing Codex capability is
  an explicit error, never a chat-completions fallback.

## Validate owner lifecycle

```powershell
.\scripts\prove-owner-tracer.ps1 -BinaryPath .\zig-out\bin\vantari.exe -EntryPoint serve
.\scripts\prove-owner-lifecycle.ps1 -BinaryPath .\zig-out\bin\vantari.exe -ConcurrentClients 20
.\scripts\prove-ticket-lifecycle.ps1 -BinaryPath .\zig-out\bin\vantari.exe
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
  generation fence across two kernels. Ticket claim, lease, capability, and
  deterministic child identity commit in one process-serialized row before
  child materialization. The source Windows lifecycle mesh proves queue-only
  assignment, TUI detach, exact owner-tree loss, generation replacement,
  same-session resume, nested direct/group/parent delivery, one terminal ticket,
  and zero proof-owned processes. Failure and cancellation project
  `repair_required`; closure still requires approval, exact rerun, and regression
  evidence. Installed hash-matched worker-kill/restart proof passes through the
  real binary; exactly-once external effects remain behind the write-intent
  ledger. Do not infer arbitrary external-effect certainty from lifecycle proof.

Read `README.md`, `apps/backend/architecture.md`, and
`.docs/roadmap/24-harness-capability-next-90.md` for deeper contracts.
