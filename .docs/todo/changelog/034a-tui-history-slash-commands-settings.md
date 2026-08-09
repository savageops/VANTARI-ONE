---
id: 034a
title: "Global persistent user message history"
parent: 034
status: pending
priority: high
blast_radius: medium
category: feature
dependencies: []
next_todo: /todo/pending/034b-tui-history-slash-commands-settings.md
source_message_anchor: history-persistence
source_message_excerpt: "the user message history needs to persist and combined globally, all sessions, and persistent. basically user mesages need to be recorded/kept"
source_message_proof_obligation: Implements the global persistent storage so user messages survive TUI restart and aggregate across all sessions.
idempotency_contract: idempotent — appending a message to JSONL is safe to retry; load reads the file fresh each startup.
---

## Execute Now

Add a global persistent user message history file at `<runtimeRoot>/tui/history.jsonl` that stores every submitted prompt across all sessions, and wire the TUI to load on startup + append on submit + navigate via Up/Down.

## Better-than-before

Fixes the `architecture.md:562-564` lie that claims persistent history but delivers in-memory only. After this slice, the doc is truthful and the code delivers durable cross-session recall.

## Entry State

- `tui_chat.zig:164-177` `appendHistory` is in-memory only (ArrayList, cap 1000, no file I/O)
- `tui_chat.zig:143-145` has `history_entries`, `history_cursor`, `history_draft` fields
- `fsutil.zig:168-179` `runtimeRootForWorkspace` resolves to `$VANTARI_HOME` or `<workspace>/.var`
- `fsutil.zig:183-189` `runtimePath` creates/returns a subsystem directory
- `fsutil.zig:42-56` `appendText` provides append-mode file writes

## Patch Surface

**Adds:**
- `src/core/sessions/history.zig` — new module: `historyFilePath`, `appendHistoryEntry`, `loadHistory`, `HistoryEntry` struct. Mirrors the `summaries.zig` pattern.
- Export in `src/core/index.zig`

**Modifies:**
- `src/clients/tui_chat.zig` — add `history_file_path` field to `ChatState`; load history in `mainWithMode` after workspace_root is resolved; flush in `appendHistory` via `history.appendHistoryEntry`; keep in-memory ring buffer for fast navigation but seed from file.
- `src/core/sessions/store.zig` — no changes needed (history is TUI-owned, not session-owned)

**Must not touch:**
- `config/file.zig`, `config/default.json` — no config keys for this
- Kernel/host code — history is TUI-local

## Detailed Requirements

1. **`HistoryEntry` struct** (`history.zig`):
   ```zig
   pub const HistoryEntry = struct {
       timestamp_ms: i64,
       text: []const u8,
       // workspace_root omitted — the file IS workspace-scoped via runtimeRoot
   };
   ```

2. **`historyFilePath(allocator, workspace_root)`** — joins `runtimeRootForWorkspace` + "tui/history.jsonl". Uses `fsutil.runtimePath` to ensure the `tui/` directory exists.

3. **`appendHistoryEntry(allocator, workspace_root, text)`** — appends one JSONL row `{"timestamp_ms":N,"text":"..."}`. Uses `fsutil.appendText`. Deduplicates consecutive identical text (don't record the same prompt twice if submitted rapidly).

4. **`loadHistory(allocator, workspace_root, max_entries)`** — reads the JSONL file, returns the last `max_entries` rows in chronological order (oldest first). Handles missing file (return empty), corrupted suffix (read valid prefix per AGENTS.md II), and BOM stripping.

5. **TUI wiring** (`tui_chat.zig`):
   - In `mainWithMode` after `state.workspace_root` is set (around line 1116), call `history.loadHistory` to seed `history_entries`.
   - In `appendHistory` (line 164), after the in-memory append, call `history.appendHistoryEntry` to persist. Fire-and-forget on the allocation (if the write fails, the in-memory history still works — don't block the TUI on a file write).
   - Cap the file at 1000 entries: if `loadHistory` returns >1000, rewrite the file with the last 1000 (trim on load, not on every append — avoids write amplification).

## Rollback Procedure

Remove `history.zig`, revert `tui_chat.zig` to in-memory-only `appendHistory`. The feature is additive — no data loss from rollback (the JSONL file is just ignored).

## Exit State / Handoff Contract

- `history.zig` exists with `HistoryEntry`, `historyFilePath`, `appendHistoryEntry`, `loadHistory`
- `tui_chat.zig` loads history on startup and persists on submit
- `architecture.md` line 562-564 is now truthful
- Next unit (034b) can proceed with the slash command dispatcher

## Validation

```bash
zig build test  # existing tests pass + new history tests
```

**New tests in `history.zig`:**
- `test "appendHistoryEntry writes JSONL row"`
- `test "loadHistory returns entries in chronological order"`
- `test "loadHistory handles missing file gracefully"`
- `test "loadHistory handles corrupted suffix (valid prefix preserved)"`
- `test "loadHistory trims to max_entries"`
- `test "consecutive duplicate text is deduplicated"`

**Manual proof:** Start TUI → send 3 messages → restart TUI → press Up → see the 3 messages from the previous session.
