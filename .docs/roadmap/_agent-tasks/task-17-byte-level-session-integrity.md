# Task 17 — Byte-Level Session Integrity

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/17-byte-level-session-integrity.md`.

1. **Study the repo** — read `AGENTS.md` (Section II, Section XIV testing integrity, Section XVIII item 14), `.docs/log.txt` (search for "jsonl", "integrity", "torn", "bom", "utf", "poisoned", "prefix", "salvage"), and the session/context storage code: `apps/backend/src/core/sessions/store.zig`, `apps/backend/src/core/context/`, `apps/backend/src/shared/fsutil.zig`.
2. **Study competitors** — `.refs/vercel__eve/` (Temporal event sourcing durability), `.refs/openai__codex/` (session persistence), `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: JSONL torn write recovery, append-only log integrity, LMDB/SQLite write atomicity, BOM handling in JSON parsers, invalid UTF-8 recovery, duplicated ID detection in append-only logs, prefix-valid reads over corrupted suffixes, how Kafka/Redis Streams handle corrupted segments.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XVIII item 14, Section II, Section XIV)

- **Byte-level session integrity:** JSONL append/read paths detect:
  - Torn writes (partial line from crash mid-append)
  - BOMs (byte order marks in file headers)
  - Invalid UTF-8 (malformed bytes)
  - Duplicated sequence IDs
  - Poisoned trailing rows
  - ...without corrupting valid prefix state.

- **Storage contract (Section II):** JSONL readers must preserve valid prefix state across poisoned suffixes, torn writes, BOMs, duplicated sequence IDs, and malformed trailing rows.

- **Testing (Section XIV):** corrupted JSONL suffixes, stale running sessions, duplicate context after provider overflow.

## Competitor angles to research

- **Vercel Eve / Temporal:** Temporal stores events in a database with transactions — no torn-write risk. VANTARI uses file-based JSONL. What is the tradeoff? (VANTARI: zero-dependency single binary, no DB server).
- **SQLite WAL:** how does SQLite detect and recover from torn writes? (journal/checksum).
- **Kafka:** segment corruption recovery, checksum-CRC.
- **OpenTelemetry logs:** how do they handle malformed entries?

## Pipeline items to define

- P0: Torn-write detection (partial trailing line, no newline terminator)
- P0: Valid-prefix preservation (reader stops at first poison, returns what it has)
- P1: BOM stripping on file open
- P1: Invalid UTF-8 byte-level recovery (skip/replacement)
- P1: Duplicate sequence ID detection (keep first, flag second)
- P1: Checksum/CRC per line for tamper detection

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "jsonl", "integrity", "torn", "prefix", "salvage", "poisoned". Sessions at 402 mentions — a heavily exercised subsystem with critical integrity requirements.

## Output

Write ONLY `.docs/roadmap/17-byte-level-session-integrity.md`. Do not modify source code or the index.
