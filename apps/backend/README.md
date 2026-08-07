# VAR1 — VANTARI Agent Kernel

VAR1 is a deterministic Zig agent-session kernel where prompts compile into session state, provider turns, typed tool spans, context checkpoints, command I/O, and recoverable evidence. It is not a chat wrapper — it is an execution substrate that treats every agent interaction as a state-machine transition through a durable, append-only, cold-start-recoverable pipeline.

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

Every retained subsystem reduces ambiguity at the call site while increasing guarantees in the core. A session is correct only when the operator can observe the same causal chain the kernel will replay after cold start.

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
  todos/        ← bounded execution tracking (todo_slice)
  changelog/    ← completed work archive
  tickets/      ← self-evolution issue ledger (log_ticket)
  processes/    ← process execution ledger (shell_exec audit)
  sessions/     ← canonical session storage
  schedules/    ← durable scheduler jobs
  docs/         ← runtime contract documentation
  plans/        ← knowledge_artifact surface
```

Every subagent that discovers findings **must persist them** to the appropriate surface before returning its SITREP. The orchestrator holds only the artifact index — paths, titles, summaries — never the full payloads.

## Configuration Surface

All config lives in `~/.vantari/config.json` (non-secret) and `~/.vantari/auth.json` (credentials). The config is hot-loaded per-turn.

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

Seven built-in specialists with enforced tool-class profiles, each routable to independent provider/model/wire configurations:

| Profile | Capability | Role |
|---|---|---|
| `general` | subagent | Bounded general-purpose |
| `recon` | read-only | Repository/evidence reconnaissance |
| `planner` | model_task (1 turn, no tools) | Plan synthesis |
| `compactor` | model_task | Dense summary |
| `implementer` | write | Bounded implementation |
| `reviewer` | model_task | Findings-first review |
| `validator` | recon | Independent validation probes |

### Bounded In-Process Supervisor

Children run on a fixed `std.Thread.Pool` (default 6 workers, max 64) with hard concurrency limits, O(1) group/parent indexes, condition-based wait, cancellation, and cold-only ledger recovery. The supervisor provides exactly-once convergence — a child's terminal evidence is committed once, never duplicated.

### Child Prompt Protocol

Every `launch_agent` task must populate a bounded contract:

```text
Objective: <one sentence, finite, falsifiable>
Scope bounds: <paths/modules/commands; "read-only" when no mutation>
Evidence required: <exact paths/commands/artifacts to return>
```

Children never inherit the parent conversation or provider message window. They receive only explicit bounded context and return compact SITREPs.

### Silent Advisors

Planners, reviewers, and validators run as **invisible background advisors** — they produce coaching, critique, and verification without appearing in the TUI. Their output is advisory context consumed at the next turn boundary. An advisor is a coach, not an authority.

## Process Tracking

Every `shell_exec` command appends a durable record to `.var/processes/processes.jsonl` with schema `var1.process.v1`: mode, cwd, argv, exit_code, timed_out, truncated, duration_ms, started_at_ms, tool_call_id, workspace_root, session_id. The `list_processes` tool queries this ledger (most recent first).

## TUI Features

- **Dual-mode reasoning dock** — 4 rows, ∞ for live reasoning, ◊ for buffer preview
- **Input history** — Up/Down-arrow cycling through previous messages (persistent ring buffer, cap 1000)
- **Agent activity tree** — nested group/item rows with tree connectors
- **Live streaming** — assistant deltas, reasoning deltas, and tool progress rendered in real-time

## Quick Start

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
```

## Commands

```powershell
.\zig-out\bin\VAR1.exe run --prompt "..."
.\zig-out\bin\VAR1.exe run --prompt-file .\prompt.txt --json
.\zig-out\bin\VAR1.exe health --json
.\zig-out\bin\VAR1.exe tools --json
.\zig-out\bin\VAR1.exe config validate
.\zig-out\bin\VAR1.exe config show
```

## Files Worth Reading First

- `src/core/executor/loop.zig` — the turn loop, draft injection, context rebuild
- `src/core/executor/draft.zig` — draft compilation module
- `src/core/executor/buffer.zig` — buffer speculation service
- `src/core/prompts/builder.zig` — system prompt assembly (all layers)
- `src/core/agents/supervisor.zig` — bounded in-process delegation
- `src/core/agents/spec.zig` — agent specialist definitions
- `src/core/providers/routes.zig` — per-agent route resolution
- `src/core/providers/openai_compatible.zig` — transport, streaming, effort/temperature
- `src/core/tools/runtime.zig` — tool dispatch and catalog
- `src/core/tools/builtin/` — all built-in tools
- `src/core/config/file.zig` — config schema validation and loading
- `src/core/config/default.json` — complete config template with _help
- `src/clients/tui_chat.zig` — TUI rendering, dock, input history
- `src/host/stdio_rpc.zig` — kernel host, scheduler + buffer thread spawn

## Current Posture

This lane is session-native end to end with frontier cognitive capabilities:
- Cockpit orchestration with metadata-only context
- Synthetic draft compilation (prompt pre-processing)
- Buffer speculation (concurrent navigation previews)
- Per-turn config hot-loading
- Per-agent effort/temperature/thinking controls
- Knowledge scaffolding (research/plans/advice/roadmap/tickets/processes)
- Process tracking ledger
- Dual-mode reasoning dock (4 rows, buffer preview)
- TUI input history
- Self-tuning doctrine
- Role-routed bounded delegation with silent advisors
- Surgical precision work ethic

## Competitive Position

No dominant coding agent does fire-and-forget background cognition today. Claude Code's Task tool is strictly blocking (issue #6854, closed not-planned). VANTARI's two-tier cognitive speculation pipeline (draft + buffer) is a **generational advance**, not a catch-up — it lifts speculative decoding from the token level to the reasoning level, inspired by Lookahead Reasoning (Hao AI Lab, NeurIPS 2025).

The one thing VANTARI has that oh-my-pi (the closest competitor with async job orchestration) lacks: **durable, cold-start-recoverable session ledgers**. oh-my-pi's jobs are process-local and expire in 5 minutes. VANTARI's sessions are append-only JSONL that survive restart with byte-level integrity guarantees.

## Engineering Stories

### The Config/Auth Drift (5 recurrences, permanently fixed)

A subtle bug where `runtimeRootForWorkspace` ignores the workspace argument when `VANTARI_HOME` is set, causing test fixtures to write to the real global config/auth path. This manifested 5 times across the session (config key `auto_compact` vs `auto_compaction`, auth reverting from glm-5.2 to glm-5.1, test providers leaking into the global ledger). A background code-reviewer agent independently flagged the pattern, leading to a systematic audit and permanent fix: 6 tests now carry the `VANTARI_HOME` skip guard.

### The Parallel-System Detection

A background reviewer caught that `knowledge_artifact(surface:"research")` duplicated `research_artifact` — two live tools with identical read/write semantics on `.var/research/`. This is the exact AGENTS.md §XII anti-pattern ("Parallel systems for the same responsibility"). Fixed by removing `research_artifact` entirely and making `knowledge_artifact` the sole owner.

### The 15-Line Secondary Provider Call

Deep recon (4 background agents) confirmed that making a secondary provider call to a different model (glm-5-turbo) from within the executor loop is a ~15-line operation, not 50. The transport is a stateless value type, thread-safe (fresh TCP+TLS per call, no connection pool), and three working precedents exist (embeddings, routes, supervisor.runModelTask). This enabled the entire draft+buffer pipeline without new infrastructure.

## Deep Documentation

- [Complete Session Inventory](.var/research/session-2026-08-07-complete-inventory.md) — every non-ordinary detail from this session
- [Architecture](architecture.md) — full cognitive architecture section with flow diagrams
- [Planning Chains](.docs/todo/pending/) — DRAFT-, BUF-, PROMPT-, PLUG-, TUI- chains (planning-spec v3.0)
- [AGENTS.md](../AGENTS.md) — the operating contract (18 sections of runtime doctrine)
