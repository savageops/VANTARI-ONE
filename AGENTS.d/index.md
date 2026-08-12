---
type: module-index
id: project-agent-modules
status: current
version: 1.1.0
---

# Project module index

`E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\AGENTS.md` is the governing project contract. Load the owner below when work touches its surface.

| Surface | Canonical owner | Load when |
|---|---|---|
| Runtime and proof | `../AGENTS.md` | Any code, runtime, process, or release change |
| Session and context | `apps/backend/architecture.md` and `apps/backend/src/core/sessions/` | Transcript, summary, checkpoint, replay, or recovery work |
| Agents and tickets | `apps/backend/src/core/agents/`, `apps/backend/src/core/tickets/`, `apps/backend/src/core/scheduler/` | Delegation, queue admission, pool capacity, leases, repair, or child projection work |
| TUI | `apps/backend/src/clients/tui_chat.zig` and `apps/backend/README.md` | Terminal layout, activity rows, footer metadata, streaming, or input work |
| Docs and records | `.docs/index.md`, `.docs/technical_summary.md`, `.docs/todo/AGENTS.md`, `.docs/changelog/AGENTS.md` | Documentation, planning, changelog, or handoff work |
| References | `.refs/index.md` | Research, competitor harvest, or reference implementation work |
| Active roadmap doctrine | `AGENTS.d/extractions/2026-08-12-prompt-led-autonomy.md`, `AGENTS.d/extractions/2026-08-12-subtractive-capability.md`, `AGENTS.d/extractions/2026-08-12-sequence-addressed-agent-mailbox.md`, and `AGENTS.d/extractions/2026-08-12-prompt-mode-profiles.md` | Every roadmap 24 decision until each extraction is graduated or retired |

## Loading rule

Use the nearest scoped `AGENTS.md` in the touched subtree. The current scoped records are `.docs/todo/AGENTS.md` and `.docs/changelog/AGENTS.md`; their formats are subordinate to the root contract and the planning chain already present in `.docs/todo/pending/` and `.docs/todo/changelog/`.

Do not create a second runtime owner, status bus, ticket pool, transcript, or documentation index. Add a module only when it carries an active invariant, owner, and proof surface.
