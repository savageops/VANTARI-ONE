# VAR1 — VANTARI Agent Kernel

VAR1 is a deterministic Zig agent-session kernel where prompts compile into session state, provider turns, typed tool spans, context checkpoints, command I/O, and recoverable evidence. It is not a chat wrapper — it is an execution substrate that treats every agent interaction as a state-machine transition through a durable, append-only, cold-start-recoverable pipeline.

## The Thesis: Prompt as Steering Surface

VANTARI drives the AI model. VANTARI is the pilot in the cockpit; the model is the plane. The prompts are what steer the plane.

The harness is capable of anything — chatbot, parallel multi-agent orchestrator, silent background worker, Telegram bot. But the harness does not decide which. **The prompt does.** The system prompt is the ignition: it determines whether VAR1 behaves as a chatty assistant, a ruthless delegating orchestrator, a quiet long-running researcher, or a hybrid that speaks little and fans out wide. Every behavioral dimension — reasoning depth, verbosity, delegation aggressiveness, tool preference, response cadence — is a prompt-level control, not a code-level switch.

This makes VAR1 a **bring-your-own-prompt** system. The shipped default prompt (`builder.zig`) is one opinion — a senior engineering operator that weighs solo work, inspection, messaging, challenge, delegation, queueing, and wake intent from current evidence. An operator can replace it entirely via `.var/prompts/system.md` and the same harness becomes a different product. The kernel guarantees the mechanics (durable state, tool safety, recovery, streaming); the prompt determines the behavior. Refine the prompting and VAR1 does whatever you want, however you want.

The default prompt embodies this philosophy: it makes the model *act* as the orchestrator without ever explaining the machinery underneath. The strategy lives in the behavior, not in the prose.

## The Pipeline

```text
user input → draft compilation (glm-5-turbo, optional)
           → append-only transcript (messages.jsonl)
           → context compiler (checkpoints + recent suffix)
           → provider turn (with effort/temperature/thinking controls)
           → assistant deltas / tool calls (streamed live)
           → tool review gate → tool dispatch → effect evidence
           → typed events (events.jsonl)
           → concurrent buffer speculation (navigation previews)
           → durable terminal state
```

Write-capable file tools use the existing session ledger as a two-phase
evidence boundary: reserve the provider tool-call ID and before-hash before the
mutation, commit the measured after-hash/bytes after it, and append one
`abandoned` row for an unresolved reservation at safe cold start. The ledger
does not claim rollback; it preserves the exact boundary needed by later repair
work.

Every retained subsystem reduces ambiguity at the call site while increasing guarantees in the core. A session is correct only when the operator can observe the same causal chain the kernel will replay after cold start.

### Persistent Execution Owner

TUI and CLI use `host/owner_client.zig` as a reconnecting facade. The facade
resolves one workspace owner from `.var/runtime/execution-owner.json`, validates
workspace, protocol, generation, and executable identity through a live
loopback handshake, then forwards the existing JSON-RPC contract. Client exit
does not stop the owner.

The owner process holds one crash-released workspace lease and one private
`ChildClient`. That child starts the sole `kernel-stdio` process, which retains
the existing `AgentService`, fixed pool, scheduler, buffer, sessions, tools, and
event spine. Foreground `serve` and automatic `execution-owner` startup acquire
the same lease; they cannot create parallel kernels. Browser routes stay
redacted while owner routes are exact and token-gated.

## What Makes VAR1 Different

### Cockpit Orchestration (Context Preservation)

VAR1 never holds full child context. The orchestrator operates from a **metadata-only cockpit** — it holds session ids, group ids, child SITREPs, evidence paths, and file locations, never raw child transcripts. Children run in isolated sessions with bounded context windows. The parent parks signal-driven on the supervisor condition variable and resumes exactly once when a ready child result arrives. This allows indefinite orchestration without context-window saturation.

### Synthetic Drafting (Cognitive-Level Speculative Decoding)

When `draft.enabled` is true, a lightweight model (glm-5-turbo) **restructures the user's raw input into a compiled prompt** before the heavyweight model's first turn. The draft model extracts intent, scope, and context pointers, producing a clean structured prompt that reduces the heavyweight's ambiguity and improves first-token latency. This is prompt compilation — the BPO (Black-Box Prompt Optimization) pattern lifted into the runtime. Failures fall back gracefully to the raw prompt; the session is never blocked.

### Buffer Speculation (Subconscious Layer)

A concurrent buffer model runs at configurable intervals, producing **navigation previews**: next steps, directions, risks, and insights. The preview populates the TUI reasoning dock when the heavyweight is idle and acts as advisory context. This is inspired by Lookahead Reasoning (NeurIPS 2025) — speculative decoding lifted from the token level to the cognitive/reasoning level. The buffer is the "message from the future": pre-computed guidance the heavyweight verifies or refines.

### Burst System (Bounded Action Discipline)

The agent reasons in **bounded action bursts**: choose one observable step, state its objective and next action, act through tools or delegation, inspect the evidence, emit a compact checkpoint, then continue. No front-loaded hidden plans, no spending the turn narrating private reasoning. Checkpoints are operator-visible work narration — changed state, proof, blocker, next action — not hidden chain-of-thought. A checkpoint is continuation evidence, not a terminal answer.

### Dual-Mode Reasoning Dock

The TUI reasoning dock operates in two modes with visual distinction:
- **∞ (infinity glyph)** — live reasoning trace from the heavyweight model, shown while actively streaming
- **◊ (diamond glyph)** — buffer model navigation preview, shown when the heavyweight is idle
- The dock expands to 4 rows with a 1024-byte scan window, separated from the transcript by a gap row that collapses at short terminal sizes

### Surgical Precision Work Ethic

Every mutation is the **smallest reversible change that advances the contract**, proven before the next edit. The system prompt enforces `replace_in_file` for surgical local edits over `write_file` whole-file rewrites. Small, efficient, controlled slices compound into durable systems. **Slow is smooth, and smooth is fast.**

### Per-Turn Config Hot-Loading

Config changes (persona, guardrails, user context, effort, temperature) take effect on the **next turn**, not the next session. The prompt builder re-reads `config.json` on every `rebuildProviderBaseMessages` call — no restart, no recompilation, no seam. This enables recursive self-improvement: VAR1 observes its own behavior and tunes its configuration in real-time.

### Knowledge Scaffolding

VAR1 maintains a structured workspace knowledge surface under `.var/`:

```text
.var/
  research/     ← DOM rips, reverse-engineering, scrape results
  plans/        ← implementation plans, execution chains
  advice/       ← advisor SITREPs, coaching records, verification
  roadmap/      ← roadmap artifacts with owner + exit criteria
  tickets/      ← canonical work lifecycle and queue ledger (log_ticket)
  changelog/    ← ticket-linked completion evidence
  processes/    ← process execution ledger (shell_exec audit)
  sessions/     ← canonical session storage
  schedules/    ← durable scheduler jobs
  docs/         ← runtime contract documentation
```

Every subagent that discovers findings **must persist them** to the appropriate surface before returning its SITREP. The orchestrator holds only the artifact index — paths, titles, summaries — never the full payloads.

Tickets own work identity and terminal state. Session summaries are bounded handoff projections; plans, research, advice, roadmap, and changelog entries are ticket-linked artifacts. The runtime does not create or read parallel `.var/todos/` slices or per-session `session.md` records.

### Ticket Lifecycle (Full Work Tracking)

All todos, tasks, and work items are tracked as tickets with a full lifecycle:

```
unassigned → assigned → in_progress → blocked → completed → closed
```

The `log_ticket` tool supports `create`, `transition` (with reason), and `list`. Every non-trivial task gets a ticket before work starts. Mutations are durable records in `.var/tickets/tickets.jsonl` with schema `var1.ticket_event.v2`. Long tasks must have ticket tracking for accuracy, recovery, and audit.

Assignment is queue admission. It does not launch an agent directly. The
scheduler claims assigned tickets only when `agent_routes.max_concurrency`
projects nonzero `available` capacity, then calls the existing `AgentService` and
fixed-pool `Supervisor` path. `running` is active work, `idle = max - running`,
`queued` is admitted backlog, and `available = idle - queued` saturated at zero.
A changed ceiling replaces the same physical pool at its next idle boundary;
active work drains and reports the actual prior ceiling. No `tickets` config
branch, second pool, or pending-capacity ledger changes this state machine.
Heartbeats, leases, stale-owner requeue, terminal reconciliation, and repair
evidence remain durable scheduler/ticket state.

Scheduler leadership is inter-process exclusive in source. One shared OS-owned
lock spans the full tick; `lease.json` carries a random nonzero generation that
is read back before dispatch. The native Windows proof starts two complete
`kernel-stdio` processes against one due job and one assigned ticket. It records
one unique schedule attempt, one ticket claim, and one deterministic child
session. `.var/tickets/ledger.lock` serializes ticket read/validate/append across
processes; the claim row commits worker generation, lease, attempt, capability,
and child identity before `AgentService` materializes or submits the child. After
claim and session creation are durable, the child sends one parent wake through
the same sequence-addressed mailbox used for normal agent collaboration.

Run `scripts/prove-ticket-lifecycle.ps1 -BinaryPath zig-out/bin/vantari.exe` for
the composed Windows process mesh. It proves queue-only assignment, client
detach, exact owner/kernel tree loss, lease expiry, a new owner generation,
same-session resume, nested direct/group/parent delivery, one terminal ticket,
and zero proof-owned processes. Installed promotion requires the same tracer
against a source-hash-matched installed binary.

### Definition-owned tool capability

`ToolDefinition.availability` carries each built-in dependency declaration.
`core/tools/registry.zig` probes that selected definition and emits live
availability; it does not maintain a parallel name-keyed table. The same
definition slice supplies the native provider schema, operator catalog, review
risk, and dispatch path. `search_files` declares and probes the installed `ix`
executable; when `ix` is absent, the operator catalog reports `unavailable` and
dispatch fails closed. The provider prompt receives the native schema only;
examples and dependency detail remain demand-loaded at the operator/tool
surface.
`eval` declares Python with the platform-correct Bun executable as an
alternative; the catalog exposes both names while dispatch selects one
persistent kernel per workspace and session. `core/tools/process.zig` is the
shared bounded child owner for eval and `shell_exec`: it owns pipe draining,
timeouts, session teardown, and Windows tree receipts.

### Interjection Protocol (Speak While Working)

The operator can send messages while the agent is actively working. Messages are:
1. **Silently queued** (bounded at 5, nothing visible)
2. **Injected at the next step boundary** as `USER_STEER_MESSAGE: {text} (DO NOT IGNORE)`
3. **Naturally acknowledged** by the model's reasoning trace (visible in the ∞ dock)
4. **Responded to** in the normal chat flow

This is non-interrupting (never cancels the current step), non-destructive (nothing is lost), and more responsive than Claude Code (step boundary, not turn boundary). The reasoning dock shows genuine model reasoning triggered by the tagged format — no synthetic text.

Synthesized from 8 competitor patterns (oh-my-pi, Eve, Scion, nullclaw, OpenClaw, Claude Code, Cursor, pi-mono). Simpler, more durable, more responsive than all of them.

### Bounded branch context

The canonical child launch stores the parent checkpoint identity in the
immutable execution receipt. `core/context/builder.zig` projects that summary
and a bounded recent parent suffix into the child provider window; it never
copies parent rows into the child `messages.jsonl` ledger. `core/sessions/store.zig`
keeps shard lifecycle rows out of compiler checkpoint selection and preserves
parent range/token metadata on bounded terminal results. `Supervisor` remains
the one convergence owner and returns the result through the existing mailbox.
No shard registry, transcript copier, polling loop, or second worker pool was
added. Move 70 is source-complete; installed promotion remains deferred.

### Root interactive questions

The root model may call `ask_user` when an operator choice changes the result. It accepts a bounded batch of related questions, normalizes options to `a`–`e` plus `f / Other`, and persists the exact `var1.input_requested.v1` request in the session event spine. Root normal, root-agent, and orchestrator-only catalogs retain this capability; the orchestrator allow-list still denies artifact and command tools. The TUI gives the existing question controller the complete Vaxis frame and renders a settings-style modal with one horizontal row per visible question, Up/Down question focus, Left/Right option focus, Enter select, Space toggle, inline Other text, and an explicit review/submit state. Long batches cannot collide with transcript, reasoning-dock, status-bar, or footer geometry. Multi-select Enter/Space stays on the question until review. `orchestrate`, `build`, `align`, and `plan` use the same controller. Question text stays borrowed from State-owned, static, or frame-owned storage until `vx.render`; the display projection rejects invalid UTF-8/control text, uses static option keys while preserving original response ids, and guards clipped viewports. Malformed requests are reported and cancel the waiting run without unwinding the TUI. Both idle and streaming key paths now share one recovery boundary for controller and `input/respond` errors, keeping the panel available for retry or explicit cancellation. `input/respond` is the only resolution method. Cancellation and owner shutdown wake the same broker wait. Child profiles are headless and fail closed with `InputUnavailable`, so a background agent cannot hang waiting for a terminal that it does not own.

### Deferred plugin socket

The plugin socket is not a shipped runtime capability. Move40 removed the
default-visible `manage_plugin` placeholder because its enable/disable path was
not connected to discovery or dispatch. The remaining manifest, isolation, and
socket types are contract-only scaffolding: they do not scan `.var/plugins/`,
change the model-visible catalog, or execute plugin code. Reopen only for a
concrete user-facing need through the existing tool definition, availability,
review, dispatch, process, and event owners.

## Configuration Surface

All config lives in `~/.vantari/config.json` (non-secret) and `~/.vantari/auth.json` (credentials). Workspace-local auth uses `.var/auth.json`; nested and AppData auth paths are migration inputs only. The config is hot-loaded per-turn.

Use `vantari auth status --json` for a secret-free active-provider projection, `vantari auth login openai-codex` for the browser PKCE flow with a pasted redirect fallback, and `vantari auth logout <provider-id>` to remove one provider record. The login helper persists OAuth tokens and subscription metadata through the canonical auth store. OAuth `openai-codex` turns use `core/providers/openai_codex.zig` and `POST /codex/responses`; API-key providers keep the existing OpenAI-compatible dispatch. The dedicated route carries `chatgpt-account-id`, `originator`, `OpenAI-Beta`, and SSE headers, sets `store:false`, and fails explicitly when its transport or entitlement is unavailable. Status, health, logs, and docs never print API keys or OAuth tokens.

Provider-scoped API-key login and selection are also available:

```powershell
vantari auth login anthropic --api-key-stdin --model claude-sonnet-4-20250514
vantari auth login openrouter --api-key-env OPENROUTER_API_KEY --model openai/gpt-4o-mini
vantari auth login private-gateway --base-url http://127.0.0.1:43199/v1 --model custom-model --wire-api chat_completions --auth-scheme none
vantari auth use anthropic
vantari providers --json
vantari models --provider anthropic --json
vantari run --provider anthropic --model claude-sonnet-4-20250514 --prompt "..."
```

`session/send.provider_id` provides the equivalent per-turn provider override;
`auth use` changes the active ledger selection. Inventory and status are
secret-free. Anthropic uses the native Messages adapter and headers; OpenRouter
and custom OpenAI-compatible records use the shared adapter with explicit
base URL, wire API, and bearer/API-key/no-auth selection.

`.env` is bootstrap configuration, not the durable credential owner. Installed runs
read `$VANTARI_HOME/auth.json`; workspace runs read `.var/auth.json`. Use the
secret-free projection to inspect provider state:

```json
{"provider_id":"openai-codex","auth_type":"oauth","model":"gpt-5.4-mini","account_id":"acct-...fixture","subscription_plan_label":"ChatGPT Pro","subscription_status":"active","expires_at_ms":2000000000000}
```

The projection omits `access_token`, `refresh_token`, API keys, and ID tokens. A
successful OAuth provider turn is the dedicated `/codex/responses` route; a
missing entitlement, expired record, or unavailable header-capable transport is a
typed failure, not a downgrade to `/v1/chat/completions`.

### Agent filesystem and process access

```json
{
  "runtime": {
    "full_access_mode": false
  }
}
```

`runtime.full_access_mode` is the explicit cross-directory switch. `false` is the default and keeps file, search, LSP, and `shell_exec` paths inside the active workspace. Set it to `true` only when the operator intends to work in another directory; relative paths stay workspace-rooted, while explicit absolute paths and `..` traversal are accepted. Resolved child routes inherit the flag into the same execution context, so child agents use the identical boundary. This setting is exposed by the Settings panel and validated `config/set` flow, then applies on the next turn. It does not move the canonical `.var`/session runtime state or relax configured prompt-file paths.

### Prompt Layers (configurable, hot-loaded)

```json
{
  "prompts": {
    "persona": "Direct, technical, concise. Senior systems engineer vocabulary.",
    "guardrails": null,
    "user_context": null,
    "system_prompt_file": null,
    "developer_prompt_file": null
  }
}
```

The system prompt is assembled in ordered layers: internal guardrails → operator guardrails → system prompt → persona → developer prompt → operator context → tool contract.

The TUI's session-local prompt lens sits in that same builder. Shift+Tab cycles
`orchestrate`, `build`, `align`, and `plan`; the next `session/send` carries the
exact label and the kernel hot-loads one provider-visible guidance layer.
`orchestrate` is the default. Unknown labels fail before execution. This lens
does not select tools, change access, alter the executor, or change model/agent
capacity; prompts remain the behavior control plane.

The assembled provider-facing system prompt has one context-policy guard:

```json
{
  "context": {
    "prompt_budget_tokens": 8192
  }
}
```

The value is an estimated char/4 ceiling. Exceeding it fails before provider
dispatch instead of silently rewriting prompt layers. Native provider tool
schemas are sent through the provider API separately and remain governed by the
full context-window budget. The source matrix proves the four modes and named
behavior profiles across root, recon, and orchestrator routes through one
builder; no mode-specific executor branch exists. Move 68 carries
`exact` provider usage, `estimated` compiler context, and `unknown` omitted
usage through the existing turn events; the footer marks estimates with `~`
and `/status` suppresses partial cumulative totals.

The same footer projection displays `status · prompt mode · model · effort ·
context used/capacity/percent · remaining` in one non-wrapping row. Estimated
context is marked with `~`; unknown used/remaining context remains
`ctx — / capacity`. Width fitting is codepoint-safe and drops lower-signal
agent/queue detail before final truncation.

### Per-Agent Effort & Temperature

```json
{
  "runtime": { "effort": "low", "temperature": 0.3 },
  "agent_routes": {
    "roles": {
      "recon": { "effort": "max", "temperature": 0.1 },
      "planner": { "effort": "high", "temperature": 0.5 }
    }
  }
}
```

Effort controls reasoning depth (low/medium/high/max). Temperature controls sampling heat. Per-agent route overrides take precedence over global defaults.

### Draft & Buffer (cognitive speculation)

```json
{
  "draft": {
    "enabled": false,
    "model": "glm-5-turbo",
    "effort": "low",
    "temperature": 0.2
  },
  "buffer": {
    "enabled": false,
    "model": "glm-5-turbo",
    "effort": "low",
    "temperature": 0.4,
    "interval_ms": 5000
  }
}
```

Both default to `false`. When enabled, they create a two-tier cognitive pipeline: draft pre-processes input, buffer produces concurrent navigation previews.

## Agent Delegation Architecture

### Role-Routed Specialists

Twelve built-in specialist identities with enforced tool-class profiles, each routable to independent provider/model/wire configurations:

| Profile | Capability | Role |
|---|---|---|
| `general` | subagent | Bounded general-purpose |
| `recon` | read-only | Repository/evidence reconnaissance |
| `planner` | model_task (1 turn, no tools) | Plan synthesis |
| `spec` | model_task | Contract and boundary synthesis |
| `compactor` | model_task | Dense summary |
| `implementer` | write | Bounded implementation |
| `doc_writer` | write | Large document persistence |
| `scaffold` | subagent | Proof-gated chain decomposition |
| `orchestrator_parent` | subagent | Prompt-selected high-fanout coordination |
| `harvester` | read-only | Competitive evidence harvest |
| `reviewer` | model_task | Findings-first review |
| `validator` | recon | Independent validation probes |

### Model-Selected Eligibility

`agents {}` hot-loads the effective registry and asks the existing
`AgentService` to resolve every route before advertising it. The returned
`var1.agent_eligibility.v1` payload contains sorted eligible and unavailable
specialists, fixed-pool pressure, current-team aggregates, depth/contact bounds,
communication targets, queue/wake modes, and a SHA-256 receipt over the exact
snapshot. Private instruction capsules and child transcripts stay out of the
parent context. The snapshot does not select an agent or reserve capacity;
`launch_agent` and `send_agent_message` revalidate at the side-effect boundary.
Prompt profiles choose whether the model remains quiet, inspects, messages,
challenges, launches, queues, or wakes without a second executor branch.

### Bounded In-Process Supervisor

Children run on a fixed `std.Thread.Pool` (default 6 workers, max 64) with hard concurrency limits, O(1) group/parent indexes, condition-based wait, cancellation, and cold-only ledger recovery. The supervisor provides idempotent mailbox-backed convergence — a child's bounded terminal summary reaches its parent once without copying the child transcript — and emits typed child phase plus elapsed snapshots through the existing child-event envelope. The same envelope refreshes the keyed parent row when `update_session_summary` completes.

### Child Prompt Protocol

Every `launch_agent` task must populate a bounded contract:

```text
Objective: <one sentence, finite, falsifiable>
Scope bounds: <paths/modules/commands; "read-only" when no mutation>
Evidence required: <exact paths/commands/artifacts to return>
```

Children never inherit the parent conversation or provider message window. They receive only explicit bounded context and return compact SITREPs.

### Sequence-Addressed Agent Mailbox

`send_agent_message` writes bounded collaboration input to the recipient's
existing `events.jsonl`. It resolves an exact session inside the sender's tree,
the immediate parent, or current-group siblings. `queue` waits for the next run;
`wake` resumes an already-running recipient at its next safe provider boundary.
The sender receives one idempotent receipt, each recipient gets a durable event
sequence, and the unread cursor advances only after provider success.

The context compiler injects at most 16 messages / 16 KiB as one transient
system segment. Mail never enters `messages.jsonl`, grants authority, assigns a
ticket, or launches work. Child completion and ticket claim use this same path;
there is no convergence-specific transcript append or claim-notice bus.

### Silent Advisors

Planners, reviewers, and validators run as **invisible background advisors** — they produce coaching, critique, and verification without appearing in the TUI. Their output is advisory context consumed at the next turn boundary. An advisor is a coach, not an authority.

## Process Tracking

Every `shell_exec` command appends a durable record to `.var/processes/processes.jsonl` with schema `var1.process.v1`: mode, cwd, argv, exit_code, timed_out, truncated, duration_ms, started_at_ms, tool_call_id, workspace_root, session_id. The `list_processes` tool queries this ledger (most recent first).

## TUI Features

- **Dual-mode reasoning dock** — 4 rows, ∞ for live reasoning, ◊ for buffer preview
- **Input history** — Up/Down-arrow cycling through previous messages (persistent ring buffer, cap 1000)
- **Agent activity tree** — nested group/item rows with tree connectors
- **Agent turn summaries** — each keyed child row shows `○` queued/running or `◉` complete, known typed phase/elapsed metadata, and a bounded quoted summary from the canonical child session summary ledger; `update_session_summary` refreshes that quote while running, tool phases update the same row, and none replace it with `tool_completed`
- **Minimal agent group rows** — `Agents completed/total`; no persistent `waiting on N` filler; failure/cancel markers remain explicit
- **Replay-safe activity** — live and cold TUI projections consume contiguous sequence-bearing parent events; legacy sequence-less activity rows are not rendered
- **Live streaming** — assistant deltas, reasoning deltas, and tool progress rendered in real-time
- **Command discovery** — the composer shows a bounded registry-backed popover for bare first-token prefixes (`s`, `set`, `settings`) and slash-prefixed input; matches disappear for prose or no results, and Up/Down, Tab, Enter, and Escape remain transient input controls
- **Settings overlay** — `settings` renders through the normal Vaxis frame boundary; Tab/Right advances sections, Shift+Tab/Left reverses them, and unavailable persisted config shows compiled defaults instead of freezing or falling through to the model
- **Saved TUI controls** — the `tui` config section persists four named palettes (`vantari`, `midnight`, `high_contrast`, `amber`) and `status_bar_position` (`bottom` or `top`). The same renderer consumes them immediately after a successful settings save; arbitrary color maps and a layout registry are intentionally absent
- **Operator metadata row** — one non-wrapping row for status, prompt mode, model, effort, context used/capacity/remaining, and signal-bearing agent/queue/cost pressure; active/max and queue appear only when useful, estimated context carries `~`, unknown used/remaining context stays `ctx — / capacity`, exact priced session cost is compact, and persistent `Esc cancel` text is omitted
- **Root question controller** — event-backed `ask_user` questions in one settings-style horizontal-row panel with clamped focus, Enter select, Space check, inline `f / Other`, review/submit, and one `input/respond` RPC; root catalogs and the orchestrator allow-list retain the capability while child profiles remain headless; malformed requests cancel safely; the Vaxis render boundary is tested across every prompt mode; no polling overlay or second status bus
- **Question lifecycle boundary** — an orphaned panel, transport failure, terminal replay, or already-settled turn clears the same controller; Ctrl-C while a question is active resolves through `input/respond` cancellation instead of trapping the TUI in a run-cancel path; controller and response errors are contained by one shared idle/streaming event-loop boundary
- **Composer hierarchy** — transcript surface < metadata surface < focused input surface; `cancelling` appears only during an active cancellation request and disappears at the terminal boundary

### Runtime chat posture and mode routes

`runtime.log_level` is a validated, hot-loaded projection setting:

| Value | Chat behavior |
|---|---|
| `silent` | Default. Suppresses internal tools, skills, memories, mailbox, waits, and repeated lifecycle noise. |
| `normal` | Shows concise operational checkpoints and useful child/tool activity. |
| `full` | Permits diagnostic lifecycle detail for inspection. |

The event and session ledgers remain complete at all three levels. Enter on the
runtime `log_level` setting cycles the value and applies it on the next turn.

`agent_routes.prompt_modes` reuses the existing route override shape for
`orchestrate`, `build`, `align`, and `plan`. It can select `provider_id`,
`model`, `wire_api`, effort, temperature, context, and output reserve. Explicit
`session/send` provider/model fields win over the configured mode; credentials
remain owned by `auth.json`. No mode-specific executor, tool registry, or
provider pipeline exists.

### Renderer configuration

```json
{
  "tui": {
    "theme": "vantari",
    "status_bar_position": "bottom"
  }
}
```

`theme` selects a complete named palette owned by `tui_chat.zig`; `status_bar_position`
moves the existing status/context row to the top while the composer remains at the
bottom. Settings cycles both values through `config/set`, and the next frame uses
the saved selection. The TUI keeps one renderer owner: there is no arbitrary
per-cell palette schema or menu-position registry.

## Quick Start

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
.\scripts\prove-owner-tracer.ps1 -BinaryPath .\zig-out\bin\vantari.exe -EntryPoint serve
.\scripts\prove-owner-lifecycle.ps1 -BinaryPath .\zig-out\bin\vantari.exe -ConcurrentClients 20
```

## Commands

```powershell
.\zig-out\bin\VAR1.exe run --prompt "..."
.\zig-out\bin\VAR1.exe run --prompt-file .\prompt.txt --json
.\zig-out\bin\VAR1.exe health --json
.\zig-out\bin\VAR1.exe tools --json
.\zig-out\bin\VAR1.exe config validate
.\zig-out\bin\VAR1.exe config show
.\zig-out\bin\VAR1.exe serve --port 4310
.\zig-out\bin\VAR1.exe -c
```

## Files Worth Reading First

- `src/core/executor/loop.zig` — the turn loop, draft injection, context rebuild
- `src/core/executor/draft.zig` — draft compilation module
- `src/core/executor/buffer.zig` — buffer speculation service
- `src/core/prompts/builder.zig` — system prompt assembly (all layers)
- `src/core/agents/service.zig` — route eligibility, launch, supervision, and convergence composition
- `src/core/agents/mailbox.zig` — sequence-addressed direct/parent/group delivery and unread cursor
- `src/core/agents/supervisor.zig` — bounded in-process delegation
- `src/core/tickets/index.zig` — canonical ticket ledger, queue projection, claims, leases, and repair evidence
- `src/core/scheduler/store.zig` — scheduled jobs, attempts, process-exclusive leadership, and generation projection
- `src/core/scheduler/service.zig` — capacity-aware ticket dispatch and stale-owner reconciliation under one leadership guard
- `src/core/sessions/summaries.zig` — bounded durable session/agent turn summaries
- `src/core/agents/spec.zig` — agent specialist definitions and canonical eligibility receipt
- `src/core/providers/routes.zig` — per-agent route resolution
- `src/core/providers/openai_compatible.zig` — transport, streaming, effort/temperature
- `src/core/tools/runtime.zig` — tool dispatch and catalog
- `src/core/tools/builtin/` — all built-in tools
- `src/core/config/file.zig` — config schema validation and loading
- `src/core/config/workspace.zig` — one workspace-resolution policy for clients and owners
- `src/core/config/default.json` — complete config template with _help
- `src/clients/tui_chat.zig` — TUI rendering, dock, input history
- `src/host/owner_client.zig` — public reconnecting client facade
- `src/host/owner_state.zig` — owner lease and atomic project-local projection
- `src/host/http_bridge.zig` — resident owner routes plus redacted browser routes
- `src/host/stdio_client.zig` — private supervised `kernel-stdio` child transport
- `src/host/stdio_rpc.zig` — kernel host, scheduler + buffer thread spawn
- `src/shared/process_lock.zig` — sole crash-released inter-process lock primitive for owner and scheduler boundaries

## Current Posture

This lane is session-native end to end with frontier cognitive capabilities:
- Cockpit orchestration with metadata-only context
- Synthetic draft compilation (prompt pre-processing)
- Buffer speculation (concurrent navigation previews + next-turn injection)
- Interjection protocol (speak while working — USER_STEER_MESSAGE at step boundary)
- Per-turn config hot-loading
- Session-local prompt-mode cycling with provider-visible guidance on the next turn
- Default-restricted agent filesystem/process boundary with explicit `runtime.full_access_mode` opt-in
- Session-scoped access projection: the selected boundary is visible in the TUI and inherited by child routes without moving `.var` ownership
- Root-only interactive `ask_user` questions through the existing event spine, broker, and `input/respond`; child profiles remain headless
- Per-agent effort/temperature/thinking controls
- Knowledge scaffolding (research/plans/advice/roadmap/tickets/processes)
- Full ticket lifecycle (create/transition/list — unassigned→assigned→in_progress→completed→closed)
- Buffered ticket execution (assignment queue, fixed pool capacity, live-owner heartbeat, generation-fenced same-session resume, absent-session requeue, terminal-first reconciliation)
- Process tracking ledger
- Dual-mode reasoning dock (4 rows, ∞/◊ glyphs, buffer preview)
- TUI Unicode glyph system (○ queued/running, ◉ complete, ✗/⊘ failure/cancel, ├──/└── connectors)
- Braille spinner (variable-speed, wall-clock derived)
- TUI input history (Up/Down cycling)
- 9-word military checkpoint contract for subagents
- Self-tuning doctrine
- Role-routed bounded delegation with silent advisors
- Route-resolved model-selected specialist/team snapshot with deterministic receipt
- Sequence-addressed direct/parent/group agent messaging with queue/wake intent
- Surgical precision work ethic
- One generation-bound `turn_terminal` settlement for completed, failed,
  timed-out, and cancelled runs
- One project-local execution owner that survives TUI/CLI detach and rejects
  duplicate foreground or automatic starts

## Deep architecture — current capability truth

VANTARI treats the agent session as a durable state machine, not a chat
interaction. The table separates mechanisms that execute through the canonical
consumer path from frontier scaffolds that still need lifecycle proof.

| Mechanism | Current state | Exact boundary |
|---|---|---|
| Append-only event spine | **Source and installed proven** | `events.jsonl` stores monotonic sequence numbers; stdio notifications carry the exact stored sequence and the tracked TUI advances only by that identity with demand-driven suffix repair. |
| Single terminal settlement | **Source and installed proven** | `commitTurnTerminal` admits exactly one `var1.turn_terminal.v1` row per `session_started.seq`; repeated identical settlement is idempotent, conflicting or stale settlement is rejected, and legacy terminal names are read-only. |
| Generation-bound cancellation | **Source and installed proven** | The tracked TUI sends the observed `session_started.seq` as `expected_run_seq`; missing, unobserved, and stale generations do not mutate a newer run. Shutdown retains an admission-fenced unconditional path. |
| Message transcript writer | **Source and installed proven** | One per-session owner serializes every message role and initializes sequence from a bounded valid tail. Multi-process writer ownership remains coupled to the persistent-host work. |
| Persistent execution owner | **Source and installed proven** | One workspace lease converges 20 concurrent clients on one owner/kernel tree. Explicit workspace selection defeats inherited/configured redirection. Client detach preserves the generation; graceful stop drains; forced owner death leaves zero descendants; the next client creates one new generation. Installed owner lifecycle evidence is retained under `.zig-cache/owner-proofs/9cc5d7b8a1624e49937cb3b78716e1bb`. |
| Session submission | **Source proven** | `run --session-id` routes through `LocalClient` and owner `session/send`; the retired per-session `run-session` process no longer bypasses shared capacity or nested delegation. |
| Prompt-mode lens | **Source and installed proven** | `PromptMode` cycles through the TUI, exact labels cross `session/send`, unknown labels fail closed, and the provider envelope changes without an executor or capability branch. Debug `19/19` / `1,996/1,996`; ReleaseFast/install `9/9`; source/installed SHA-256 `145F08FF38FA94D325006B4CC78A8C0EFD83A885E9A2F8DBA6152CFA20BFC1EC`. |
| Compact TUI status row | **Source and installed proven** | `formatFooterMetaWithPool` projects status, prompt mode, model, effort, context arithmetic/unknown, and remaining context without wrapping; focused TUI `77/77`, Debug `19/19` / `1,998/1,998`, ReleaseFast/install `9/9`; source/installed SHA-256 `F569105E0845F6F6F23282C3C3C697EE8B3939CAC5515E111AC29A5CEAF754C2`. |
| Child branch/convergence | **Source and installed proven** | Fixed-pool convergence survives presentation-client exit. The process tracer kills the exact owner/kernel tree, waits for lease expiry, then resumes the same ticket child and immutable receipt under a new generation. Ordinary non-ticket orphan receipts still become `StaleAgentOwner`. Installed ticket evidence is retained under `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9`. |
| Agent mailbox | **Source and installed proven** | Direct, parent, and current-group delivery uses recipient event sequence, sender receipt, queue/wake intent, and provider-success unread cursor. The process tracer observes nested sibling and parent context once, with zero copied transcript rows. Installed ticket evidence is retained under `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9`. |
| Agent eligibility | **Source proven** | One hot-loaded `AgentService` snapshot advertises only route-resolvable specialists with capacity/team/communication state and an exact SHA-256 receipt. Quiet and hive prompt profiles choose different actions through the same executor; the dedicated installed snapshot probe has not run. |
| Write-intent ledger | **Frontier scaffold** | Reserve/commit helpers and tests exist; write-capable tools do not call them on the canonical mutation path. |
| Byte-level session integrity | **Source and installed proven** | One LF-only reader owns BOM, invalid-UTF-8, JSON/schema, duplicate, and non-monotonic boundaries across event/message/context/intent/summary projections. Append refuses a poisoned current tail without rewriting it; operator-facing corruption events remain a later diagnostics decision. |
| Context compiler | **Source-complete; installed promotion pending** | One builder compiles transcript plus checkpoint state, reports bounded synthesized/skipped tool-row repairs through `var1.context_compile_diagnostic.v1`, rebuilds provider-overflow retries from the checkpoint plus durable suffix without duplicate tool context, and projects receipt-addressed parent checkpoint context into child windows without transcript duplication. Debug `19/19` / `2,166/2,166`; source ReleaseFast `9/9`; installed promotion deferred. |
| Compaction | **Manual writer shipped** | Entry-aware checkpoints retain stable message identity plus explicit source/kept ranges; autonomous/background compaction remains gated. |
| TTSR stream rules | **Source-complete; installed promotion pending** | One provider abort hook stops SSE reads before terminal completion, persists correction plus `rule_injected` evidence, and retries through the existing executor. Debug `2,151/2,151`; installed provider proof remains deferred. |
| Hash-anchored edits | **Shipped source path** | read_file hashes and edit preconditions reject stale content before mutation. |
| Provider capability probing | **Frontier scaffold** | Cache code exists without a runtime adapter consumer. |
| Arena/quota discipline | **Frontier scaffold** | Scoped allocators exist; quota counters are not maintained by the live turn path. |
| DAP | **Source-complete; installed promotion pending** | One workspace+session adapter uses `PersistentProcess` with exact Content-Length framing; seven risk-correct lifecycle sockets cover attach, pause, stack, scopes, variables, continue, and detach. Debug `2,141/2,141`, source ReleaseFast, and real Python adapter cleanup pass; installed promotion remains deferred. |
| eval | **Source-complete; installed promotion pending** | One workspace+session-owned persistent kernel supports Python or Bun JavaScript with bounded newline protocol, output cap, timeout termination, session isolation, and shared `core/tools/process.zig` teardown. Timeout and oversized-response tests prove reaping, drain, and framing recovery; installed promotion remains deferred. |
| Scheduler leadership | **Source and two-process proven** | One crash-released OS lock spans the tick; `lease.json` carries a nonzero generation and is read back before dispatch. Two complete source kernels produced one reserved/completed attempt and zero survivors. |

The current evidence and ordered repair ledger live in the
[full-harness SITREP](../../.docs/research/2026-08-12-full-harness-sitrep.md)
and [findings index](../../.docs/todo/findings/00-INDEX.md).

**Full deep architecture document:** [`.var/research/deep-architecture-innovations.md`](.var/research/deep-architecture-innovations.md)

## Competitive Position

No dominant coding agent does fire-and-forget background cognition today. Claude Code's Task tool is strictly blocking (issue #6854, closed not-planned). VANTARI's two-tier cognitive speculation pipeline (draft + buffer) is a **generational advance**, not a catch-up — it lifts speculative decoding from the token level to the reasoning level, inspired by Lookahead Reasoning (Hao AI Lab, NeurIPS 2025).

The one thing VANTARI has that oh-my-pi (the closest competitor with async job orchestration) lacks: **durable, cold-start-recoverable session ledgers**. oh-my-pi's jobs are process-local and expire in 5 minutes. VANTARI's sessions are append-only JSONL that survive restart with byte-level integrity guarantees.

## Engineering Stories

### The Test Runtime Drift (build and direct lanes closed)

A subtle bug let test fixtures inherit production `VANTARI_HOME` and reach the
global config/auth/session owners. Skip guards hid coverage and did not solve the
owner error. The build now assigns every one of six test artifacts a generated
home; `zigw.ps1` and `zigw.sh` do the same for direct `zig test`; and a
compile-gated `VANTARI_TEST_ROOT` rejects cache-root escape. The obsolete skip
guards are deleted; the 1,931-test graph executes every lane while the live
runtime root remains unchanged. Both audit-owned incident sets are held in
reversible quarantine with backup, manifest, and rollback.

### The Parallel-System Detection

A background reviewer caught that `knowledge_artifact(surface:"research")` duplicated `research_artifact` — two live tools with identical read/write semantics on `.var/research/`. This is the exact AGENTS.md §XII anti-pattern ("Parallel systems for the same responsibility"). Fixed by removing `research_artifact` entirely and making `knowledge_artifact` the sole owner.

### The 15-Line Secondary Provider Call

Deep recon (4 background agents) confirmed that making a secondary provider call to a different model (glm-5-turbo) from within the executor loop is a ~15-line operation, not 50. The transport is a stateless value type, thread-safe (fresh TCP+TLS per call, no connection pool), and three working precedents exist (embeddings, routes, supervisor.runModelTask). This enabled the entire draft+buffer pipeline without new infrastructure.

## Deep Documentation

- [Complete Session Inventory](.var/research/session-2026-08-07-complete-inventory.md) — every non-ordinary detail from this session
- [Architecture](architecture.md) — full cognitive architecture section with flow diagrams
- [Planning Chains](.docs/todo/pending/) — active DRAFT-, BUF-, PROMPT-, and TUI- chains; PLUG is deferred-delete and archived in [the changelog](.docs/todo/changelog/PLUG-plugin-socket.md)
- [Project records](../.docs/index.md) — current technical summary, workspace record, research, and closeout evidence
- [Reference corpus](../.refs/index.md) — local harvest sources and adoption rules
- [AGENTS.md](../AGENTS.md) — the operating contract (18 sections of runtime doctrine)
