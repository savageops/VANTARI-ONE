# Task 18 — Local Performance Telemetry

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/18-local-performance-telemetry.md`.

1. **Study the repo** — read `AGENTS.md` (Section X Mechanical Cost Model, Section XVIII item 15), `.docs/log.txt` (search for "telemetry", "perf", "latency", "measure", "profile", "benchmark", "timing"), and any timing/diagnostic code in `apps/backend/src/`.
2. **Study competitors** — `.refs/vercel__eve/` (telemetry/tracing patterns, OpenTelemetry), `.refs/openai__codex/`, `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: agent runtime performance measurement, OpenTelemetry in agent systems, low-noise performance counters, latency measurement for LLM token compilation / JSONL scanning / event replay / terminal rendering, Zig timing/benchmark patterns, how to profile without runtime overhead in production.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XVIII item 15, Section X)

- **Local performance telemetry:** measure with low-noise counters gated behind explicit commands:
  - Token compilation latency
  - JSONL scan latency
  - Event replay latency
  - Terminal frame render latency
  - Process spawn latency
  - Tool dispatch latency

- **Mechanical cost model (Section X):** every mechanism has a cost center with a required question. Telemetry must answer these questions with measured data, not vibes.

| Mechanism | Cost Center | Required Question |
|---|---|---|
| Provider turn | network latency, stream parse, tool-call reconstruction | Does the operator see deltas before terminal output? |
| Context compile | JSONL scan, checkpoint selection, allocation, provider payload bytes | Is the window built once through the compiler? |
| Tool dispatch | review gate, schema parse, side effect, event append | Is the effect reserved, executed, and evidenced? |
| Command run | process spawn, pipe draining, timeout, kill, output cap | Are stdout/stderr visible while the process runs? |
| TUI frame | event replay, wrapping, terminal render, scroll state | Does the interface preserve comprehension under live updates? |
| Session recovery | prefix salvage, stale owner reconciliation, terminal status | Can a dead process leave truthful state? |

## Competitor angles to research

- **Vercel Eve:** OpenTelemetry tracing integration (`telemetry` parameter on AI SDK calls). What does it measure? Is it local or remote?
- **OpenAI Codex:** any latency measurement?
- **Temporal:** workflow/activity timing, visibility APIs.
- **OpenTelemetry:** spans for LLM calls, tool calls, context operations.

## Key constraint

"Health, readiness, and diagnostics stay thinner than capability. They expose enough state to operate the system; they do not become a parallel product." (AGENTS.md Section VIII). Telemetry must NOT become a parallel system.

## Pipeline items to define

- P1: Core timing counters (per-turn, per-compile, per-dispatch) stored as typed events
- P2: `VAR1 stats` / `VAR1 profile` command for local measurement
- P2: Comparison harness: measure VANTARI vs Eve on equivalent workloads

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "telemetry", "perf", "latency", "measure", "profile", "benchmark".

## Output

Write ONLY `.docs/roadmap/18-local-performance-telemetry.md`. Do not modify source code or the index.
