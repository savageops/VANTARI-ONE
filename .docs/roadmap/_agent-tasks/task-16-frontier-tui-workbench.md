# Task 16 — Frontier TUI Workbench

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/16-frontier-tui-workbench.md`.

1. **Study the repo** — read `AGENTS.md` (Section IV, Section XVI, Section XVIII item 10), `.docs/log.txt` (search for "tui", "terminal", "render", "frame", "ui", "chat", "client"), and the client code under `apps/backend/src/clients/` (especially `tui_chat.zig`, `cli.zig`).
2. **Study competitors** — `.refs/vercel__eve/` (no TUI — web-based), `.refs/openai__codex/` (CLI/TUI), `.refs/badlogic__pi-mono/` (terminal UI).
3. **Web research** — search for: Rust/Zig TUI frameworks (ratatui, bubbletea, zig-tui), live data streaming in terminals, terminal rendering performance, scrollback under live updates, item graph / tree visualization in terminal, how Claude Code / Aider / Codex render tool spans and streaming output.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XVIII item 10)

- **Frontier TUI workbench:** terminal renders:
  - Live item graph (tool calls, branches, convergence)
  - Assistant token stream (live deltas)
  - Tool spans (start → output → finish lifecycle)
  - Command output (bounded stdout/stderr)
  - Cancellation affordance (operator can interrupt)
  - Session navigation (list/switch/resume sessions)
  - Optional raw event inspection (for debugging)

## Key contract (AGENTS.md Section IV)

- TUI progress is a read model over `events.jsonl`, not a separate speculative status bus.
- Tool spans update a single keyed row in clients. Do not append request/start/done rows for one tool invocation.
- The interface must preserve transcript comprehension under live updates.

## Competitor angles to research

- **Claude Code:** rich terminal rendering with tool spans, streaming deltas. How does it handle scroll?
- **OpenAI Codex CLI:** rendering model, spinners, tool output.
- **Aider:** git-integrated TUI.
- **ratatui / bubbletea:** best patterns for live-updating, scroll-preserving, multi-panel layouts.
- **Vercel Eve:** web UI only — VANTARI's single-binary TUI is the un-served operator surface.

## Pipeline items to define

- P1: Event-driven render loop (read model over events.jsonl with monotonic cursor)
- P1: Tool span single-row update model (not append-per-lifecycle-stage)
- P1: Live assistant delta streaming with scrollback preservation
- P2: Item graph visualization for branch/shard convergence
- P2: Raw event inspector panel

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "tui", "render", "frame", "scroll", "terminal". This connects to the "every message is a new context window" north star — the TUI must render shard branching and convergence visibly.

## Output

Write ONLY `.docs/roadmap/16-frontier-tui-workbench.md`. Do not modify source code or the index.
