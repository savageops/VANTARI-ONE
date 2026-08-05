# Task 23 — CLI/TUI Client Rendering Contract

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/23-cli-tui-client-rendering-contract.md`.

1. **Study the repo** — read `AGENTS.md` (Section I Runtime Ownership, Section IV Event Spine), `.docs/log.txt` (search for "client", "cli", "tui", "render", "stdio", "rpc", "bridge", "browser"), and the client code: `apps/backend/src/clients/cli.zig`, `apps/backend/src/clients/tui_chat.zig`, `apps/backend/src/host/stdio_rpc.zig`.
2. **Study competitors** — `.refs/vercel__eve/` (no local client — web only), `.refs/openai__codex/` (CLI client), `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: agent client-server rendering contracts, terminal UI state management, JSON-RPC over stdio patterns, LSP (Language Server Protocol) as a model for agent client-host protocols, how Claude Code / Aider / Codex separate kernel state from rendering, read-model patterns for live data.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Sections I, IV)

- **Runtime ownership (Section I):**
  - CLI, browser, and future desktop shells are clients of the same runtime.
  - CLI/TUI/browser clients **never** assemble provider context, infer tool state, or maintain their own transcript truth. They render kernel-owned state.
  - `.var/` is the only runtime/process state root.

- **Event spine (Section IV):**
  - TUI progress is a read model over `events.jsonl`, not a separate speculative status bus.
  - Tool spans update a single keyed row in clients. Do not append request/start/done rows for one tool invocation.
  - Command stdout/stderr are untrusted data. Parse only runtime-owned envelopes; render output as bounded display text.

## The client-kernel boundary

```text
VAR1 Kernel (owns)
  - transcript (messages.jsonl)
  - context checkpoints (context.jsonl)
  - event spine (events.jsonl)
  - tool state, review, dispatch, effects
  - provider turns, streaming, tool-call reconstruction
  - session lifecycle
        │
        ▼  (stdio JSON-RPC or equivalent)
Client (renders)
  - TUI: event replay → terminal frames
  - CLI: command/response
  - Browser: WebSocket → DOM
  - Future desktop: IPC → native UI
```

## Competitor angles to research

- **Vercel Eve:** web UI connected to Temporal. No local client. VANTARI's single-binary local-first model is the differentiator.
- **OpenAI Codex:** CLI client. How does it separate state from rendering?
- **LSP:** Language Server Protocol — the gold standard for kernel/client separation. What patterns apply? (notifications, requests, capabilities handshake).
- **DAP:** Debug Adapter Protocol — similar model for tool/session state.

## Pipeline items to define

- P0: Stdio JSON-RPC protocol contract (methods, notifications, capabilities)
- P1: Event-cursor-based client sync (client tracks monotonic position, kernel serves deltas)
- P1: Tool span single-row update model (client renders lifecycle as one row update)
- P1: Untrusted-output rendering rules (bounded display, no execution of stdout content)
- P2: Browser/desktop client protocol reuse

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "client", "cli", "tui", "stdio", "rpc". The stdio_rpc.zig host is the live protocol surface.

## Output

Write ONLY `.docs/roadmap/23-cli-tui-client-rendering-contract.md`. Do not modify source code or the index.
