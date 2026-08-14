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
- `messages.jsonl` is append-only and every row has a durable generated or
  explicit deterministic ID. `context.jsonl` checkpoints retain inclusive
  source ranges and `first_kept_seq`; compaction must rebuild from those
  ledgers and never rewrite transcript rows.
- The context compiler is the only provider-window builder. It may synthesize
  interrupted tool results or skip orphan rows in the projection, preserves
  the transcript, and emits `var1.context_compile_diagnostic.v1` counts through
  `events.jsonl`; provider-overflow retry rebuilds through that same compiler.
- Assignment admits ticket work to the queue. It does not launch an agent.
- `agent_routes.max_concurrency` is the sole ticket execution capacity knob.
  `running` is active, `idle = max - running`, `queued` is admitted backlog, and
  `available = idle - queued` saturated at zero. Config changes apply to the same
  physical pool at its next idle boundary. Do not invent a second pool, pending
  capacity ledger, or restore a `tickets` execution-policy section.
- Tickets own work identity and terminal state. Use `update_session_summary` for
  bounded handoff and knowledge/changelog tools for ticket-linked artifacts; do
  not create parallel `todo_slice`/`session_record` lifecycle records or a
  `.var/todos/` tree.
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
- `context.prompt_budget_tokens` is the single estimated system-prompt ceiling;
  the builder fails before provider dispatch when it is exceeded. Native tool
  schemas stay on the provider API path. `TokenPrecision` distinguishes exact
  provider usage, estimated compiler context, and unknown accounting; never
  report a partial cumulative total as exact. Prompt tests must prove named
  modes and behavior profiles through one builder, not executor branches.
- Use the root-only `ask_user` tool when an operator choice materially changes
  the result. Batch related multiple-choice questions; the TUI renders one
  settings-style horizontal row per visible question, uses Up/Down for question
  focus, Left/Right for option focus, Enter to select, Space to check, and
  `f / Other` for inline text, then presents one review state before one
  `input/respond` call. The frame projection must sanitize invalid UTF-8/control
  text and guard clipped rows. Malformed requests must cancel safely, not crash
  the renderer; terminal/error boundaries clear any stale panel, and active
  Ctrl-C uses the same input cancellation route. Child profiles are headless and must continue or report
  `InputUnavailable`; never create a polling question loop.
- `ask_user` must appear in the root normal, root-agent, and orchestrator-only
  catalogs and pass the same dispatch allow-list. Child profiles must not gain
  operator-input capability. Prompt modes reuse the one question controller.
- In the TUI, Shift+Tab cycles the session-local prompt lens
  `orchestrate -> build -> align -> plan`; the next `session/send` applies one
  provider-visible layer and defaults to `orchestrate`. It does not change
  tools, access, model, capacity, or executor behavior.
- The single TUI footer row projects `status · prompt mode · model · effort ·
  context used/capacity/percent · remaining` without wrapping; unknown context
  stays `ctx — / capacity`, estimated context carries `~`, and narrow fitting
  drops lower-signal detail before codepoint-safe truncation. Active/max agents
  and queue pressure appear only when nonzero or unhealthy; priced session cost
  appears only for finite, nonnegative exact terminal telemetry. Keep it a read
  model, not a settings registry, cost poller, or status bus.
- Agent activity reuses the keyed `group_id + task_id` row and canonical child
  summary boundary: groups show `Agents completed/total`, `○` means
  queued/running, `◉` means complete, and the child row keeps a bounded quoted
  summary. The existing `update_session_summary` completion refreshes that quote
  while the child is running; later tool/terminal phases retain it. When present,
  the same row also
  shows a typed phase and elapsed snapshot; lower-signal metadata yields to the
  summary width. Do not add a bubble event, summary poller, transcript copy, or
  second activity ledger.
- Use `vantari auth status --json` for secret-free provider/account/plan state.
  Run `vantari auth login openai-codex` for the browser PKCE path or its manual
  redirect fallback; use `vantari auth logout <provider-id>` for one-record
  removal. Never inspect or print token-bearing auth fields.
- Provider-scoped API-key login accepts `--api-key-stdin` or `--api-key-env`;
  Anthropic uses the native Messages adapter, OpenRouter uses the shared
  OpenAI-compatible adapter, and custom records require explicit base URL,
  model, wire API, and bearer/API-key/no-auth scheme. Use `auth use <id>`,
  `providers --json`, `models --provider <id>`, and `run --provider <id>` for
  selection. The per-turn RPC field is `session/send.provider_id`.
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
  intended cross-directory work. Resolved child routes carry the flag into the
  shared execution context used by file, search, LSP, and shell tools. It never
  relocates `.var`.
- `search_files` requires `ix`. Do not hide an `rg`, `grep`, or `sed` fallback.
- TTSR matches use the provider reader's typed abort hook. Source proof requires
  the read to stop before terminal completion, durable correction plus
  `rule_injected` evidence, and retry through the existing executor; installed
  provider proof remains a separate promotion gate.
- Real file tools reserve a session/tool-call write intent before mutation and
  commit the measured effect afterward. Cold-start reconciliation appends one
  `abandoned` terminal row for unresolved reservations; it never claims a
  rollback that was not observed. Move 62 remains source-only until installed
  promotion is explicitly scheduled.
- The gated repair path is `repair_candidate` → operator-only `repair/approve`
  → operator-only `repair/apply`. The candidate patch is the exact
  `replace_in_file` JSON payload, including its `read_file` tag. Apply verifies
  candidate/approval sequence and ID, target, patch hash, and source baseline,
  then dispatches the existing reviewed writer. The applied receipt and
  committed intent make repeated requests no-op; Moves 77–80 still own exact
  rerun, evaluation, rollback, and regression promotion. Never expose repair
  approval as a model tool or add a patcher.
- Move 77 now owns operator-only `repair/rerun`: require the immutable replay
  receipt and later applied receipt, create a fresh linked treatment child, and
  send the recorded input/model/provider/mode through `session/send`. Gate
  input/config hashes before provider I/O; changed identity must not emit
 `turn_started`. Keep relationship receipts in the existing event spine and
  leave interrupted starts for Move 80 reconciliation.
- Move 78 now appends one idempotent `var1.repair_evaluation.v1` receipt to the
  source event spine. Compare baseline/treatment outcomes, turn latency,
  conservative observable tool-span side effects, token/cost evidence, exact
  identity/provider invariants, and optional bounds. Keep file-effect certainty
  in `var1.tool_effect.v1`; do not add an evaluator worker, ledger, or mutation
  path. Moves 79–80 own rollback and regression promotion.
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
