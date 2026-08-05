# 17 — Byte-Level Session Integrity

**Priority: P0**

## The seam

AGENTS.md §II states the contract verbatim: *"JSONL readers must preserve valid prefix state across poisoned suffixes, torn writes, BOMs, duplicated sequence IDs, and malformed trailing rows."* §XVIII item 14 names byte-level session integrity as a frontier item. §XIV lists "corrupted JSONL suffixes" as the first adversarial test every probe suite must exercise. The `.docs/log.txt` "Session Integrity and Recovery Gate" entry (2026-05-06) made this the foundational hardening pass: *"session files survive corruption and partial-write cases… no new runtime root, transcript, registry, or fallback path appears."*

This theme owns the **byte contract of the four append-only ledgers** (`messages.jsonl`, `context.jsonl`, `events.jsonl`, plus the `memories.jsonl` sibling): what a durable frame is, how a torn append is detected, how a poisoned suffix is quarantined without rewriting the valid prefix, how a BOM is rejected at the gate, how invalid UTF-8 is refused before parse, and how a duplicate `seq` is flagged without dropping the earlier row. It is the layer that theme 12 (binary-safe event spine) declares and that themes 01/02/04 depend on: a shard is replayable only if its ledger survives a crash mid-write and a corrupted tail.

It is explicitly **not** a new storage system. The append-only files already exist; this theme hardens the single owner of their read/append paths so the invariants AGENTS.md already asserts become mechanically true rather than aspirational.

## What exists today

- **Four append-only JSONL ledgers** under `.var/sessions/<session-id>/`: `messages.jsonl` (transcript, `seq`-addressed), `context.jsonl` (checkpoints), `events.jsonl` (spine), `memories.jsonl`. `messages.jsonl` already carries writer-assigned monotonic `seq` (`types.zig:183`, `SessionMessage.seq: u64`); `nextSessionMessageSeq` (`store.zig:821`) scans `max_seq + 1`. The monotonic primitive exists in-repo for the transcript; the other three ledgers have no sequence.
- **One append path, one integrity repair.** `appendJsonlRecord` (`store.zig:727`) is the single writer for all four ledgers. Its entire integrity story is four lines (`:742-750`): read the last byte; if it is not `\n`, `pwriteAll("\n", end_position)` before the new record. That fixes exactly one failure mode — a prior append that lost its terminator. Everything else is undefended.
- **No `fsync`/`sync` on the append path.** `appendJsonlRecord` calls `file.pwriteAll(jsonl, end_position)` (`:752`) and then `defer file.close()`. There is no `file.sync()` call. Writes sit in the OS page cache until the kernel flushes them; a power-loss or hard crash can lose the most recent appends entirely (not merely tear them). The Zig stdlib exposes `File.sync` (`lib/std/fs/File.zig:217`) — the primitive is available, it is simply not called.
- **Readers `catch continue` on every malformed line.** `readEvents` (`store.zig:344`) and `readSessionMessagesFromPath` (`store.zig:664`) both parse line-by-line with `std.json.parseFromSlice(...) catch continue`. A poisoned row is **silently dropped and invisible** — the exact anti-pattern §XIV forbids, because there is no signal that a tear happened, no quarantine, no reconciliation event. `readLatestContextCheckpoint` (`:534`) and `readLatestEvent` (`:300`) walk backward and `catch`-skip bad lines the same way: the latest *valid* row is returned, but the operator never learns a row was lost.
- **No BOM handling.** None of the readers strip or reject a leading UTF-8 BOM (`EF BB BF`). `std.json.parseFromSlice` will fail on a BOM-prefixed first line (per RFC 8259 strict parsers reject it), and that failure is swallowed by `catch continue` — so a BOM at the head of a ledger silently zeros out the entire file from the reader's perspective.
- **No invalid-UTF-8 gate.** `readTextAlloc` (`fsutil.zig:58`) calls `std.fs.cwd().readFileAlloc`, which returns a byte slice; nothing runs `std.unicode.utf8ValidateSlice` (`lib/std/unicode.zig:231`) on it. A single `0x80` continuation byte without a lead byte, or a `0xFF` byte, will make `std.json.parseFromSlice` fail on that line — again silently swallowed.
- **No duplicate-`seq` detection.** `nextSessionMessageSeq` takes `max(seq) + 1`, so a duplicate `seq` does not corrupt the *next* allocation; but `appendRawMessages` (`builder.zig:68`) iterates messages positionally and a duplicate `seq` inside the `first_kept_seq` window would emit two rows for one sequence, confusing the context compiler and the compactor's `buildPlan` (`compactor.zig:99`), which keys off `seq` ranges.
- **Self-healing already exists at the semantic layer.** `builder.zig` synthesizes interrupted tool results (`interrupted_tool_result`, `:23`) and skips orphan tool results (`:107`, `:111`). This is the right instinct at the transcript-structure layer; this theme provides the byte-layer guarantee that makes that self-healing evidence-trustworthy rather than built on silently-dropped rows.
- **The BOM failure class is real, not hypothetical.** `.docs/log.txt` entry 261 (2026-05-06) literally begins its `message` field with `\u00ef\u00bb\u00bf` — the JSON-escaped UTF-8 BOM `EF BB BF`. The project's own history exhibits the exact byte sequence this theme must handle at the gate.

**Gap:** AGENTS.md §II's "preserve valid prefix state across poisoned suffixes, torn writes, BOMs, duplicated sequence IDs, and malformed trailing rows" is, against the current code, **five invariants asserted and zero enforced**. A torn tail is silently truncated; a BOM silently zeros the file; invalid UTF-8 is silently dropped; a duplicate `seq` is silently accepted; a poisoned row produces no signal. Theme 04 P0-4c and theme 12 P0-12d both reference this theme as the deep expansion. This file is that expansion.

## What the competitor does

### OpenAI Codex — rollout-trace (the closest spine design)

Codex ships a dedicated `rollout-trace` crate (`codex-rs/rollout-trace/README.md`). Its design is the substrate VANTARI's event spine (theme 12) is modeled on:

- **Append-only raw event spine ordered by writer-assigned `seq`.** *"`trace.jsonl`: append-only raw events ordered by writer-assigned `seq`."* The `TraceWriter` *"assigns seq and writes payloads before events"* — sequence is allocated at write time, not derived from timestamps.
- **Observe first, interpret later.** *"Hot-path Codex code does not try to build the final graph while the session is running… The offline reducer then decides which events became model-visible conversation."* The raw spine is source of truth; the semantic graph is a deterministic offline read model.
- **Reducer invariants are strict:** *"raw events are replayed in `seq` order; payload files must exist before events refer to them; reduced object IDs are stable within one replay."*
- **Best-effort, never-fatal:** *"Rollout tracing must never make a Codex session fail just because diagnostic recording failed."*

**Limitations directly relevant to byte-level integrity:** (1) Codex's `rollout-trace` is an *opt-in diagnostic* (`CODEX_ROLLOUT_TRACE_ROOT`), not the canonical execution ledger — it does not gate recovery or context compilation. (2) The README specifies the *shape* of the spine (`seq`, payload externalization, replay order) but is silent on torn-write, BOM, invalid-UTF-8, and duplicate-`seq` handling — those byte-level questions are left to whatever writes the JSONL, and Codex offers no published contract for them.

### Vercel Eve — defensive span spool + Temporal durability

Eve persists execution through a vendored **Temporal Workflow World** (`.eve/.workflow-data`) and observability through an **immutable OTLP/JSON span spool** (`.eve/traces/v1/<traceId>/segments/`).

- **The span spool is the durable, defensive layer.** `local-trace-reader.ts:7`: *"one directory per trace under `.eve/traces/v1/<traceId>/segments/`, one immutable OTLP/JSON file per span… Parsing is defensive end to end — malformed or oversized segments are skipped so a partial write never breaks a view."* `MAX_SEGMENT_BYTES = 8 MiB` (`:21`). Segment names are span ids, so *"the order is stable across reads and a caller can treat names it has seen as parsed"* (`:92`).
- **Per-segment isolation is the integrity unit.** `readLocalTraceSegment` (`:117`): *"An oversized, unreadable, or malformed segment yields none, so a partial write never breaks a view."* One bad segment file cannot poison the trace; the reader returns `[]` for that one file and continues.
- **Dedup by span id, not by sequence.** `readLocalTrace` (`:153`) keeps a `Map<string, LocalTraceSpan>` keyed by `spanId` — *"if (!spans.has(span.spanId)) spans.set(span.spanId, span)"* — so a duplicate segment file is silently deduplicated, last-write-wins, with no signal.
- **Event reads are time-windowed, not seq-tailed.** `logs-events.ts` queries `DevSessionEventWindow { from: Date; to: Date }` and sorts by `at` string (`localeCompare`). This is the timestamp-cursor model AGENTS.md §IV rejects.

**Limitations:** (1) Eve's defensive parsing is good but **silent** — a malformed segment yields `[]` and the operator never learns evidence was lost; there is no reconciliation signal. (2) Dedup is last-write-wins with no audit trail; a duplicate is invisible. (3) The per-segment-file isolation sidesteps the torn-tail problem by making each span its own file (one file per span) — this trades the append-only-ledger model for a many-small-files model, which VANTARI rejects (one ledger per artifact, append-only, never rewritten). (4) Execution durability is delegated to Temporal, an external workflow engine — VANTARI's premise is one binary, zero runtime dependencies.

### badlogic pi-mono — full-rewrite sessions, silent malformed-line skip

- **Append uses `appendFileSync` with LF termination.** `session-manager.ts:813`: `appendFileSync(this.sessionFile, \`${JSON.stringify(e)}\\n\`);` — the LF-terminated append pattern VANTARI already uses.
- **But the canonical writer is a full rewrite.** `_rewriteFile` (`:775`): `writeFileSync(this.sessionFile, content)` rewrites the *entire* file from the in-memory `fileEntries` array. Compaction, migration, and branch edits trigger a full rewrite — the anti-pattern AGENTS.md §II forbids (*"Never compact, truncate, or rewrite after append"*).
- **Silent malformed-line skip.** `loadEntriesFromFile` (`:438`): `const lines = content.trim().split("\\n"); for (const line of lines) { try { JSON.parse(line) } catch { /* Skip malformed lines */ } }`. A torn or poisoned row is silently dropped with zero signal — the identical lossy pattern VANTARI's `catch continue` has today.
- **In-place migration on load.** `migrateV1ToV2`/`migrateV2ToV3` (`:216`, `:245`) mutate the parsed entry array in place and then `_rewriteFile` persists the migration — a load triggers a rewrite, violating append-only. VANTARI's checkpoints are version-tagged at write time and never migrated in place.
- **One sharp framing invariant worth harvesting.** `modes/rpc/jsonl.ts:5`: *"Framing is LF-only. Payload strings may contain other Unicode separators such as U+2028 and U+2029. Clients must split records on `\\n` only."* And `:17`: *"This intentionally does not use Node readline. Readline splits on additional Unicode separators that are valid inside JSON strings and therefore does not implement strict JSONL framing."* This is the LF-only framing law VANTARI must adopt.

### Industry substrates (SQLite WAL, Kafka, polarsignals/wal)

- **SQLite WAL — rolling per-frame checksum, valid-prefix recovery.** Each WAL frame's checksum chains the prior frame's checksum plus the frame header and data ([sqlite.org/walformat.html](https://www.sqlite.org/walformat.html)). Recovery is a single forward pass: *"The checksums are verified on each frame of the WAL as it is read. The scan stops at the end of the file or at the first invalid checksum"* ([avi.im/blag/2025/sqlite-wal-checksum](https://avi.im/blag/2025/sqlite-wal-checksum/)). The valid prefix is the durable truth; everything after the first bad frame is discarded. **Critical failure mode to reject:** SQLite *silently* truncates and drops committed entries after the tear — *"SQLite encounters a checksum error; it silently drops the frames instead of complaining"* ([thrawnca.org](https://thrawn01.org/software-internals/write-ahead-logging)). VANTARI must surface the tear, not hide it.
- **Kafka — monotonic offset, truncate to last valid offset on corruption.** Every record has a partition-monotonic offset; on crash, `LogSegment.recover` runs from the last clean offset and *"in the event corruption is detected the log is truncated to the last valid offset"* ([kafka.apache.org/43/implementation/log](https://kafka.apache.org/43/implementation/log/)). Per-record CRC validates integrity; `CorruptRecordException` is the surfaced signal ([oneuptime.com](https://oneuptime.com/blog/post/2026-01-24-kafka-corrupt-record-exception/view)). The offset is the cursor; the segment is the unit of recovery.
- **polarsignals/wal — the minimal commit-frame primitive.** *"Commit frames store a CRC of all bytes appended since the last fsync"* to detect incomplete/torn writes on recovery ([github.com/polarsignals/wal](https://github.com/polarsignals/wal)). This is the exact coupling of *CRC per frame* + *fsync as the commit boundary* that VANTARI's current append path lacks.
- **JSONL torn-write recovery convention.** The newline terminator is the commit marker: *"If a JSONL file gets corrupted mid-write, only the last (potentially incomplete) line is affected. Every previous record is recoverable"* ([jsonlines.org](https://jsonlines.org/), [SO recovery recipe](https://stackoverflow.com/questions/6685378/using-python-to-remove-incomplete-line-from-the-end-of-a-json-formatted-log-file)). POSIX line semantics: a sequence not terminated by `\n` is not a complete line — the foundation of treating a missing terminator as a torn-write marker.
- **UTF-8 self-synchronizing recovery.** UTF-8 is self-synchronizing: on an invalid byte, emit U+FFFD and resume from the next byte that could start a valid sequence (`< 0x80` or `0xC2–0xF4`) ([hsivonen.fi/broken-utf-8](https://hsivonen.fi/broken-utf-8/), [Python #8271](https://bugs.python.org/issue8271)). The number of U+FFFD emitted per invalid sequence is specified by the Unicode "Best Practices for Using U+FFFD" ([Mozilla #746900](https://bugzilla.mozilla.org/show_bug.cgi?id=746900)). VANTARI's gate is stricter than replacement: a ledger row with invalid UTF-8 is *refused* and quarantined, not lossily repaired, because the row is evidence.
- **BOM is rejected by strict JSON parsers.** RFC 8259 strict parsers reject a leading `EF BB BF`; serde-json, PHP `json_decode`, and JS `JSON.parse` all fail on it ([serde-rs/json #1115](https://github.com/serde-rs/json/issues/1115), [jsonprism.com](https://jsonprism.com/learn/json-bom-error/)). VANTARI's `std.json.parseFromSlice` inherits this strictness, so a BOM at the head of a ledger silently zeros the file under the current `catch continue` reader.

## Why VANTARI does it better

1. **Surfaced tears, not silent truncation.** SQLite WAL's rolling-checksum valid-prefix recovery is the right mechanism, but its silent data loss is the wrong policy. VANTARI will validate each frame, recover to the last valid frame on a mismatch (the valid-prefix invariant §XIV demands), and **emit a typed `ledger_torn` reconciliation event** recording the tear offset, the recovered `seq`, and the offending byte range — so the operator and the cold-start reducer both know evidence was lost, instead of discovering it later. The signal SQLite swallows, VANTARI publishes.
2. **One append path, four ledgers, one integrity discipline.** pi-mono splits persistence between `appendFileSync` and a full `_rewriteFile`; Eve splits durability between Temporal and a many-small-files span spool. VANTARI already has the right primitive — one `appendJsonlRecord` (`store.zig:727`) is the single writer for all four ledgers. This theme hardens that one function (fsync, frame-CRC, terminator check) and every reader (`readEvents`, `readSessionMessagesFromPath`, `readLatestContextCheckpoint`, `readLatestEvent`) inherits the discipline. No second storage system, no parallel writer.
3. **Append-only ledger, not many-small-files.** Eve's per-span-file isolation sidesteps the torn-tail problem by making each span its own file. VANTARI rejects that tradeoff: one append-only ledger per artifact is cheaper to scan, tail, and checkpoint than thousands of tiny files, and it is the substrate the north star's shard graph is built on. The torn-tail problem is solved at the frame layer (CRC + terminator + quarantine), not by fragmenting storage.
4. **Refuse-and-quarantine over lossy repair.** pi-mono's `catch { /* Skip malformed lines */ }` and VANTARI's current `catch continue` both silently drop evidence. Eve's U+FFFD-style replacement is correct for *display* (terminal output) and wrong for *evidence* (a ledger row). VANTARI's gate refuses a poisoned row, quarantines its bytes to a sidecar (`<ledger>.quarantine`) that the ledger never reads back, emits the reconciliation event, and preserves the valid prefix byte-identical. The transcript is evidence, not a rendering surface.
5. **Strict LF-only framing, BOM/invalid-UTF-8 rejection at the gate.** pi-mono's `jsonl.ts` documents the real framing trap (U+2028/U+2029 inside strings). VANTARI's writer already renders via `std.json.fmt` (which escapes structurally), and the reader will frame on `\n` only, reject a leading BOM at file open, and run `std.unicode.utf8ValidateSlice` on each frame before parse. A poisoned row becomes a typed reconciliation signal, not an invisible gap. The Zig stdlib exposes every primitive needed (`utf8ValidateSlice` at `lib/std/unicode.zig:231`, `Crc32` at `lib/std/hash/crc.zig:10`, `File.sync` at `lib/std/fs/File.zig:217`) — zero new dependencies.
6. **Sequence-addressed, duplicate-detected.** Kafka's monotonic offset is the cursor and the duplicate detector. VANTARI's `messages.jsonl` already has `seq`; this theme extends the forward scan to detect a duplicate `seq` (keep first, flag second, emit `ledger_duplicate_seq`) rather than silently accepting both. The same scan that computes `nextSessionMessageSeq` (`store.zig:821`) becomes the integrity scan — no second pass, no second reader.

### TARGET FRAME CONTRACT

```text
all four ledgers (messages.jsonl, context.jsonl, events.jsonl, memories.jsonl)
  append-only, LF-framed, one canonical JSON object per line, never rewritten

per-frame (when CRC is enabled, P1):
  <canonical JSON bytes>{"seq":N,...,"_crc":<crc32 of canonical bytes minus _crc>,"_prev":N-1}\n

integrity scan on open (every reader):
  1. read whole file as bytes (readTextAlloc already does this)
  2. if first 3 bytes == EF BB BF  -> record BOM, strip for parse, emit ledger_bom
  3. split on '\n' ONLY (never U+2028/U+2029)
  4. for each frame:
       a. utf8ValidateSlice(frame) -> on fail: quarantine, emit ledger_invalid_utf8, stop
       b. parseFromSlice(frame)    -> on fail: quarantine, emit ledger_poisoned_row, stop
       c. if seq seen before       -> keep first, emit ledger_duplicate_seq, continue
       d. if _crc present          -> verify; on fail: quarantine, emit ledger_torn, stop
  5. return valid prefix + reconciliation report
```

The valid prefix is byte-identical before and after recovery. The ledger file itself is never rewritten — only the sidecar quarantine receives the poisoned bytes.

## Pipeline items under this theme

### P0-17a: Torn-write detection and valid-prefix preservation
- **Contract:** a partial trailing line (no `\n` terminator, or `\n`-terminated but unparseable) is detected on read; the reader returns the valid prefix (all complete, parseable frames before the tear) and records the tear. The ledger file is never rewritten; the torn tail is left in place and overwritten by the next append only after a reconciliation signal is emitted. AGENTS.md §II "preserve valid prefix state across poisoned suffixes, torn writes, malformed trailing rows."
- **Mechanism:** the readers `readEvents` (`store.zig:318`), `readSessionMessagesFromPath` (`store.zig:644`), `readLatestContextCheckpoint` (`store.zig:511`), and `readLatestEvent` (`store.zig:279`) gain a validate-and-recover pass: frame on `\n` only, attempt parse, and on the first unparseable frame stop forward progress and return what was collected. Replace the `catch continue` at `store.zig:344` and `:664` with a reconcile-and-stop path that reports the tear offset. `appendJsonlRecord`'s existing terminator-repair (`store.zig:746`) stays as the write-side guard.
- **Test (AGENTS.md §XIV item 1):** seed a `messages.jsonl` with 5 valid frames followed by a truncated 6th (no `\n`) followed by garbage; assert `readSessionMessages` returns exactly the 5 valid frames, `readLatestContextCheckpoint` over a torn `context.jsonl` returns the last valid checkpoint, and the valid prefix is byte-identical before and after the read.
- **Proof:** adversarial suite runs the §XIV corrupted-JSONL-suffix probe and passes on the installed Windows binary.

### P0-17b: Durability gate — fsync on append commit
- **Contract:** every `appendJsonlRecord` call ends with `file.sync()` (Zig stdlib `File.sync`, `lib/std/fs/File.zig:217`) before `file.close()`, so the appended frame is flushed to the storage device and survives a power-loss or hard crash. A crash may tear the in-progress frame (caught by P0-17a) but may not lose a previously-committed frame.
- **Mechanism:** add `try file.sync()` after `file.pwriteAll(jsonl, end_position)` at `store.zig:752`. This is the polarsignals/wal commit-frame primitive: *"CRC of all bytes appended since the last fsync."* No new file, no journal — the existing append path gains one line.
- **Test:** append N frames, simulate a hard crash (kill process without graceful close), cold-start, and assert all N frames are present and parseable. Contrast with the pre-fix behavior where the tail frames are lost to the page cache.
- **Proof:** a power-loss simulation test (write, kill -9 equivalent on Windows, re-open) shows zero frame loss across 1000 trials.

### P0-17c: BOM rejection and LF-only framing at the gate
- **Contract:** a leading UTF-8 BOM (`EF BB BF`) at the head of any ledger is detected on open, recorded as a reconciliation signal, and stripped for the parse so the valid prefix is not zeroed. Framing is `\n`-only; U+2028/U+2029 inside JSON strings never split a frame (pi-mono `jsonl.ts` invariant). AGENTS.md §II "preserve valid prefix state across BOMs."
- **Mechanism:** on the first read of a ledger, check `content[0..3] == .{ 0xEF, 0xBB, 0xBF }`; if so, record `ledger_bom` and advance the parse cursor past the BOM. The readers already split on `\n` via `std.mem.splitScalar(u8, content, '\n')` (`store.zig:337`, `:657`) — LF-only framing is already in place; this item adds the assertion and the BOM gate.
- **Test:** seed a `messages.jsonl` whose first line is `\u00ef\u00bb\u00bf{"seq":1,...}` (the exact byte sequence `.docs/log.txt` entry 261 exhibits); assert all valid frames after the BOM are returned and a `ledger_bom` signal is emitted. Seed a frame containing U+2028 inside a string; assert it does not split the frame.
- **Proof:** the `.docs/log.txt` entry-261 BOM byte sequence is exercised by a dedicated gate test.

### P0-17d: Invalid-UTF-8 refusal before parse
- **Contract:** a frame containing invalid UTF-8 (e.g., a lone `0x80` continuation byte, a `0xFF` byte, an overlong encoding) is refused at the byte layer before `std.json.parseFromSlice` is attempted; the reader quarantines the frame, emits `ledger_invalid_utf8`, and preserves the valid prefix. The row is evidence and is not lossily repaired with U+FFFD (the display-layer convention is wrong for a ledger). AGENTS.md §II "preserve valid prefix state across… invalid UTF-8."
- **Mechanism:** before each `std.json.parseFromSlice` call, run `std.unicode.utf8ValidateSlice(frame)` (`lib/std/unicode.zig:231`); on `false`, quarantine and stop. The self-synchronizing property of UTF-8 ([hsivonen.fi/broken-utf-8](https://hsivonen.fi/broken-utf-8/)) guarantees the tear is bounded to the one frame.
- **Test:** seed a frame with a `0x80` byte mid-string; assert the valid prefix is returned, the poisoned frame is quarantined to the sidecar, and `ledger_invalid_utf8` is emitted with the byte offset.
- **Proof:** adversarial suite runs the invalid-UTF-8 probe and passes.

### P1-17e: Duplicate sequence ID detection (keep first, flag second)
- **Contract:** the forward scan detects a duplicate `seq` in `messages.jsonl` (and, once theme 12 lands `seq` on `events.jsonl`, there too); the first occurrence is kept, the second is flagged with `ledger_duplicate_seq`, and `nextSessionMessageSeq` continues to allocate `max_seq + 1`. The duplicate is not silently dropped and not silently accepted. AGENTS.md §II "preserve valid prefix state across duplicated sequence IDs."
- **Mechanism:** the integrity scan maintains a `std.AutoHashMap(u64, void)` of seen `seq` values; on collision, emit the signal and continue (the duplicate is informational, not a tear). Wire the same scan into `nextSessionMessageSeq` (`store.zig:821`) so the allocation and the integrity check are one pass. This mirrors Kafka's offset-monotonic invariant ([kafka.apache.org](https://kafka.apache.org/43/implementation/log/)).
- **Test:** seed a `messages.jsonl` with `seq` 1, 2, 2, 3; assert the reader returns frames for seq 1, 2, 3 (first occurrence of 2 kept), `ledger_duplicate_seq` is emitted for the second seq-2 frame, and `nextSessionMessageSeq` returns 4.
- **Proof:** adversarial suite runs the duplicate-seq probe and passes.

### P1-17f: Per-frame CRC and rolling checksum (tamper/tear detection)
- **Contract:** each ledger frame optionally carries a `_crc` field (CRC-32 over the canonical JSON bytes) and a `_prev` field (the prior frame's `seq`); the reader verifies the CRC and the `prev` chain on open. A CRC mismatch is a torn write or a tamper; the reader recovers to the last valid frame and emits `ledger_torn`. This is the SQLite WAL rolling-checksum model ([sqlite.org/walformat.html](https://www.sqlite.org/walformat.html)) applied per-line, with the signal SQLite swallows made explicit.
- **Mechanism:** add `_crc`/`_prev` to the frame in `appendJsonlRecord` using `std.hash.Crc32` (`lib/std/hash/crc.zig:10`); add a verify pass in the integrity scan. Opt-in per ledger (the transcript gains it first; `events.jsonl` inherits it from theme 12 P0-12c). Backward compatible: a frame without `_crc` skips the check.
- **Test (AGENTS.md §XIV):** flip one byte in the middle of a `messages.jsonl` frame; assert the CRC mismatch is detected, the valid prefix before that frame is returned, `ledger_torn` records the offset, and the byte-flipped frame is quarantined.
- **Proof:** adversarial suite runs the byte-flip / mid-file-corruption probe and passes.

### P2-17g: Quarantine sidecar and retention
- **Contract:** poisoned bytes (torn tail, invalid-UTF-8 frame, CRC-mismatched frame) are moved to a sidecar `<ledger>.quarantine` (append-only, never read back by the ledger) so the operator can inspect what was lost. The ledger file itself is never rewritten. Quarantine entries are retained until the session is archived; they are evidence of failure, not garbage.
- **Mechanism:** the integrity scan, on detecting a poisoned frame, appends its byte range and reason to `<ledger>.quarantine` before continuing. No reader ever opens the quarantine; it is for operator/diagnostic inspection only. This preserves AGENTS.md §II *"Never compact, truncate, or rewrite after append"* while still surfacing the lost bytes.
- **Test:** after a torn-write recovery, the sidecar contains the exact poisoned bytes and the reason; the ledger file is byte-identical to its pre-tear valid prefix; re-opening the ledger produces the same valid prefix and the same quarantine entry.
- **Proof:** byte-diff of the ledger before and after recovery is empty; the quarantine sidecar contains the poisoned tail.

## North-star link

A shard is replayable only if its ledger survives a crash mid-write and a corrupted tail. The north star (theme 01) branches a session into many context windows and converges them; each branch's evidence must survive a torn append, a BOM-prefixed file, an invalid-UTF-8 byte, and a duplicate sequence without losing the valid prefix that precedes it. Themes 02 (token-minimal context), 04 (durable execution), and 12 (binary-safe event spine) all rest on the byte contract this theme enforces: the context compiler (`builder.zig`) can only be trusted to assemble a shard's window if the `messages.jsonl` frames it reads are byte-trustworthy; the cold-start reducer can only reconcile a shard graph if the `events.jsonl` spine is tear-resilient. Without byte-level integrity, "replay the shard" is a string the README asserts but the code cannot honor — exactly the gap exposed by the `catch continue` readers and the missing `file.sync()` in `appendJsonlRecord` today.

## Definition of done
- Torn writes (partial trailing line, missing terminator) are detected; the valid prefix is preserved byte-identical; the tear is surfaced, not silently truncated (AGENTS.md §XIV item 1).
- `appendJsonlRecord` calls `file.sync()` on commit; a hard crash no longer loses committed frames to the page cache.
- A leading UTF-8 BOM is detected, recorded, and stripped at the gate; LF-only framing is enforced; U+2028/U+2029 inside strings never split a frame (pi-mono `jsonl.ts` invariant).
- Invalid UTF-8 is refused before parse (`std.unicode.utf8ValidateSlice`); the poisoned frame is quarantined, not lossily repaired.
- Duplicate `seq` is detected (keep first, flag second); `nextSessionMessageSeq` and the integrity scan are one pass.
- Per-frame CRC + `prev` chain (SQLite WAL rolling-checksum model) is opt-in per ledger, with the tear signal SQLite swallows made explicit.
- Poisoned bytes go to a sidecar quarantine; the ledger file is never rewritten (AGENTS.md §II "Never compact, truncate, or rewrite after append").
- The §XIV adversarial suite (corrupted JSONL suffix, BOM, invalid UTF-8, duplicate seq, byte-flip) passes and gates promotion; the same suite runs on the installed Windows binary.
- No second ledger, no parallel reader, no fallback parse path — the single `appendJsonlRecord` writer and the four `read*` paths are the only owners.
