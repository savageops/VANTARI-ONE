# 12 — Binary-Safe Event Spine

**Priority: P0**

## The seam

The event spine (`events.jsonl`) is the runtime's only durable nervous system. Every turn, tool span, cancellation, failure, and (under the north star) every branch and convergence must be reconstructible from this one ledger after a cold start, a crash mid-write, or a poisoned trailing row. Two properties make that possible, and neither is optional:

1. **Binary safety.** Event payloads carry command stdout/stderr, file contents, and tool arguments — arbitrary byte sequences that may include embedded NULs, invalid UTF-8, BOMs, or Unicode line separators (U+2028/U+2029) that are legal *inside* a JSON string but illegal as JSONL frame boundaries. A spine that round-trips these bytes through `std.json` lossily is a spine that silently corrupts evidence.
2. **Monotonic causal order with a replay cursor.** An observer must resume from a durable position — not a wall-clock timestamp. Same-millisecond bursts (AGENTS.md §IV) make timestamp cursors ambiguous; only a writer-assigned, monotonically increasing sequence number gives a resumable, dedupable tail.

This theme owns the **storage substrate**: the frame format, the sequence contract, the torn-write/BOM/invalid-UTF-8 recovery, and the payload-externalization seam. It is the layer that theme 03 (typed event grammar) writes onto. Theme 03 owns the *shapes* of events; theme 12 owns the *durable, binary-safe ledger* those shapes are persisted to.

## What exists today

- **Typed event structs exist** (`apps/backend/src/shared/protocol/events.zig`): `ToolStarted`, `ToolFinished`, `ToolOutputDelta` (with `chunk_b64` — already binary-safe via base64), `ToolReview`. Each carries a `schema = "var1.*.v1"` version tag. This is the grammar floor, not the spine.
- **`SessionEvent` is the durable row** (`apps/backend/src/shared/types.zig:149`): only `event_type: []const u8`, `message: []const u8`, `timestamp_ms: i64`. **There is no `seq` field.** The durable event row has no monotonic position.
- **`store.appendEvent`** (`apps/backend/src/core/sessions/store.zig:262`) renders `SessionEvent` to one JSONL line and calls `appendJsonlRecord`. The "message" is a free-form string; rich payloads are flattened into it, not carried as canonical JSON + base64 byte fields.
- **`appendJsonlRecord`** (`store.zig:727`) does pre-write repair of *one* failure mode: if the file's last byte is not `\n`, it inserts one before appending. That is the entire integrity story. There is no torn-write detection, no BOM handling, no invalid-UTF-8 rejection, no duplicate-seq guard, and no poisoned-row quarantine.
- **`readEvents` / `readLatestEvent`** (`store.zig:318`, `:279`) parse line-by-line and `catch continue` on any unparseable line. A poisoned row is **silently dropped and invisible** — the exact anti-pattern AGENTS.md §XIV item 1 ("invalid checkpoint rows do not poison the latest valid checkpoint") forbids, because there is no signal that a tear happened.
- **A monotonic cursor exists, but it is non-durable.** `stdio_rpc.zig:227` keeps `next_notification_sequence: u64 = 1` in `ClientState`, assigns one per notification (`:273`), caps the backlog at 512 (`:29`), and tails via `takeNotificationAfter(after_sequence)` (`:1277`). This is the correct cursor shape — but it lives only in process memory, resets on restart, and is decoupled from `events.jsonl`. The durable log has no cursor; the cursor has no durability. They never meet.
- **`messages.jsonl` already has the right shape** (`types.zig:183`): `SessionMessage` carries `seq: u64`, and `nextSessionMessageSeq` (`store.zig:821`) scans for `max_seq + 1`. The transcript ledger is monotonic; the event ledger is not. The pattern to copy already exists in-repo.

**Gap:** the durable event spine is a timestamp-keyed, string-payload, silently-lossy log. The monotonic cursor is in-memory. AGENTS.md §IV ("Event cursors use monotonic ledger position plus replay suppression") and §XVIII item 2 are **aspirational against the current code**, not implemented. Theme 03 (line 12) already asserts the cursor exists; this theme makes the assertion true.

## What the competitor does

### OpenAI Codex — rollout-trace (the closest design)

Codex ships a dedicated `rollout-trace` crate (`codex-rs/rollout-trace/README.md`). Its design is almost exactly the substrate VANTARI needs:

- **Append-only raw event spine ordered by writer-assigned `seq`.** "`trace.jsonl`: append-only raw events ordered by writer-assigned `seq`." The `TraceWriter` "assigns seq and writes payloads before events" — sequence is allocated at write time, not derived from timestamps.
- **Observe first, interpret later.** "Hot-path Codex code does not try to build the final graph while the session is running. It writes ordered raw events and payload references. The offline reducer then decides which events became model-visible conversation." The raw spine is the source of truth; the semantic graph is a **deterministic, offline reduced read model** — the same invariant VANTARI already states ("TUI progress is a read model over `events.jsonl`").
- **Payload externalization.** Large evidence (requests, responses, tool inputs/results, terminal output) goes to `payloads/*.json`; the spine carries references, not the bytes. This keeps the event row small and ordered while preserving exact evidence.
- **Reducer invariants are strict:** "raw events are replayed in `seq` order; payload files must exist before events refer to them; reduced object IDs are stable within one replay; runtime payloads are evidence, not proof that the model saw the same bytes."
- **Best-effort, never-fatal:** "Rollout tracing must never make a Codex session fail just because diagnostic recording failed."

**Limitation:** Codex's rollout-trace is an *opt-in diagnostic* (`CODEX_ROLLOUT_TRACE_ROOT`), not the runtime's canonical execution ledger. It does not gate recovery or context compilation. And its README does not specify torn-write/BOM/invalid-UTF-8 handling — the byte-level integrity question is left to whatever writes the JSONL.

### Vercel Eve — Workflow World + OTLP span spool

Eve persists execution through a vendored **Temporal Workflow World** (`.eve/.workflow-data`) and observability through an **immutable OTLP/JSON span spool`.

- **Event reads are time-windowed, not seq-tailed.** `logs-events.ts` queries `DevSessionEventWindow { from: Date; to: Date }` and sorts results by `at` string (`localeCompare`). This is precisely the timestamp-cursor model AGENTS.md §IV rejects: under same-millisecond bursts, a `from`/`to` window is ambiguous and a `sort by at` can reorder events that share a timestamp.
- **The span spool is the durable, immutable, defensive layer.** `local-trace-reader.ts`: one directory per trace under `.eve/traces/v1/<traceId>/segments/`, one immutable OTLP/JSON file per span, named `<16-hex>.otlp.json`. "Parsing is defensive end to end — malformed or oversized segments are skipped so a partial write never breaks a view" (`MAX_SEGMENT_BYTES = 8 MiB`). Segment names are span ids, so "the order is stable across reads and a caller can treat names it has seen as parsed."
- **In-process emission has a sequence.** `tool-loop.ts` threads `emissionState.sequence` through `emitTurnPreamble`/`emitStepActions` and stamps it onto events. But this is an in-flight stream sequence for the live transcript, not a durable replay cursor persisted to disk.

**Limitation:** Eve splits durability across two systems (Temporal Workflow World for execution, OTLP spool for observability) plus an in-memory stream sequence. There is no single monotonic, replayable event ledger the client can tail across cold start. The defensive parsing is good; the cursor model (wall-clock window) is not.

### badlogic pi-mono — in-memory bus, full-rewrite sessions

- **`event-bus.ts`** is a Node `EventEmitter` wrapper: `emit(channel, data)` / `on(channel, handler)`. It is purely in-memory — no persistence, no sequence, no replay. A crash loses every in-flight event.
- **Session persistence is `writeFileSync`, not append.** `agent-session.ts` rewrites the whole `.jsonl` on `message_end`; `session.md` documents a tree structure (`id`/`parentId`) with version migration (v1→v2→v3) on load. There is no torn-write resilience and no monotonic event spine.
- **One sharp binary-safety insight worth harvesting.** `modes/rpc/jsonl.ts` deliberately avoids Node's `readline` for framing: "Readline splits on additional Unicode separators that are valid inside JSON strings and therefore does not implement strict JSONL framing." It frames on `\n` only. This is a concrete framing-invariant VANTARI must adopt: **LF-only framing, always**, because U+2028/U+2029 are legal inside JSON strings.

### Industry substrates (Temporal, SQLite WAL, Kafka)

- **Temporal** makes a Workflow Execution a sequence of Events called an **Event History**, appended in strict monotonic order by the Temporal Service. Recovery is **deterministic replay**: the worker re-runs workflow code and the commands it produces are compared against the stored history — they must match exactly. State is reconstructed by replay, not stored alongside. ([docs.temporal.io/workflow-execution/event](https://docs.temporal.io/workflow-execution/event))
- **SQLite WAL** detects torn writes with a **rolling per-frame checksum**: each frame's checksum chains the prior frame's checksum plus the frame header and data. Recovery is a single forward pass; the first frame whose checksum fails terminates the usable WAL, and `mxFrame` is set to the last valid commit frame. ([sqlite.org/walformat.html](https://www.sqlite.org/walformat.html), [avi.im/blag/2025/sqlite-wal-checksum](https://avi.im/blag/2025/sqlite-wal-checksum/)). **Critical failure mode to reject:** SQLite *silently* truncates and drops committed entries after the tear — no error is raised. VANTARI must surface the tear, not hide it.
- **Kafka** gives every record a partition-**monotonic offset**, persists `log-start-offset-checkpoint` and `replication-offset-checkpoint`, and on crash runs `LogSegment.recover` from the last clean offset, truncating the torn tail. The offset is the cursor; the segment is the unit of recovery. ([jaceklaskowski.gitbooks.io/apache-kafka/content/kafka-log-LogSegment.html](https://jaceklaskowski.gitbooks.io/apache-kafka/content/kafka-log-LogSegment.html))
- **polarsignals/wal** captures the minimal primitive: "commit frames store a CRC of all bytes appended since the last fsync" to detect incomplete/torn writes on recovery. ([github.com/polarsignals/wal](https://github.com/polarsignals/wal))

## Why VANTARI does it better

1. **One ledger, monotonic, replayable — not split across three systems.** Eve divides durability between a Temporal Workflow World, an OTLP span spool, and an in-memory stream sequence; pi-mono has an in-memory bus and a full-rewrite session file. VANTARI already has the right primitive in-repo — `messages.jsonl`'s `seq` (`types.zig:183`, `nextSessionMessageSeq` at `store.zig:821`) — and will lift it onto `events.jsonl`. One sequence space, one append-only file, one cursor. The transcript ledger proves the pattern works; the event ledger inherits it.
2. **Durable cursor where Codex's is diagnostic-only.** Codex's `trace.jsonl` is opt-in and never gates recovery. VANTARI's spine will be the canonical execution ledger: cold-start replay, context compilation, and the TUI read model all derive from it. The cursor survives restart because it *is* the last-read `seq`, persisted in the ledger, not held in `ClientState` memory.
3. **Payload externalization with in-line base64 fallback.** Codex separates `payloads/*.json` from the spine and keeps references inline. VANTARI already does the inline variant — `ToolOutputDelta.chunk_b64` (`events.zig:26`) carries binary stdout/stderr as base64 inside the event. The spine will support both: small binary fields inline as base64 (the existing, proven pattern), large payloads externalized to a sibling payload file referenced by id. Either way the event row stays canonical JSON and ordered.
4. **Surfaced tears, not silent truncation.** SQLite WAL's rolling-checksum "valid prefix" recovery is the right mechanism, but its silent data loss is the wrong policy. VANTARI will compute a per-frame CRC over the canonical JSON bytes, recover to the last valid frame on a mismatch (the valid-prefix invariant AGENTS.md §XIV demands), and **emit a typed `spine_torn` reconciliation event** recording the tear offset and the recovered seq — so the operator and the reducer both know evidence was lost, instead of discovering it later.
5. **Strict LF-only framing, BOM/invalid-UTF-8 rejection at the gate.** pi-mono's `jsonl.ts` documents the real framing trap (U+2028/U+2029 inside strings). VANTARI's writer renders via `std.json.fmt` (which escapes structurally), and the reader will frame on `\n` only, reject a leading BOM, and reject invalid UTF-8 at parse time rather than `catch continue`-swallowing it. A poisoned row becomes a typed reconciliation signal, not an invisible gap.

### TARGET SPINE ROW

```text
events.jsonl  (append-only, LF-framed, one JSON object per line)
  {"seq":42,"schema":"var1.tool_output_delta.v1","ts":...,
   "payload":{"tool_call_id":"call-7","stream":"stdout","chunk_b64":"...","cap":false},
   "payload_ref":null,                         // or "p-0042" -> payloads/p-0042.bin
   "crc":<crc32 of the canonical line bytes>,   // rolling, chains prior frame
   "prev_seq":41}
```

- `seq` — writer-assigned, monotonic, the replay cursor.
- `schema` — versioned type tag (theme 03 owns the vocabulary).
- `payload` — canonical JSON for small/inline events; `chunk_b64` for binary.
- `payload_ref` — id of an externalized payload file for large evidence (Codex pattern).
- `crc` / `prev_seq` — rolling torn-write guard (SQLite WAL pattern); `prev_seq` also catches duplicate/out-of-order writes (Kafka offset invariant).

## Pipeline items under this theme

### P0-12a: Monotonic sequence + replay cursor on `events.jsonl`
- **Contract:** every durable event row carries `seq: u64` assigned at append time; `store.appendEvent` allocates `max_seq + 1` by scanning the file (mirroring `nextSessionMessageSeq`); `events/subscribe` and `session/get` tail by `after_seq` instead of returning an unindexed list.
- **Mechanism:** extend `SessionEvent` (`types.zig:149`) with `seq`; reuse the existing `nextSessionMessageSeq` scan pattern; replace the in-memory-only `next_notification_sequence` tail in `stdio_rpc.zig:1277` with a durable `after_seq` over `events.jsonl`. No new storage system — the file already exists.
- **Test:** same-millisecond burst of 100 events (AGENTS.md §XIV) round-trips with strictly increasing `seq` and a resumable cursor; replay from `after_seq = N` returns exactly the suffix.
- **Proof:** cold-start replay reconstructs the event order byte-identical to the live emission order.

### P0-12b: Binary-safe payload contract (canonical JSON + base64 / externalized refs)
- **Contract:** event payloads are canonical JSON; binary byte sequences (stdout/stderr, file contents) ride as base64 fields inline (the existing `chunk_b64` pattern) or as a `payload_ref` id pointing at a sibling `payloads/<id>.bin` file when they exceed a bound. No event row carries raw unescaped bytes.
- **Mechanism:** `serialize` (`events.zig:45`) is the sole emission path; add a payload-spill writer alongside `appendJsonlRecord` that, above a threshold, writes the bytes to `payloads/p-<seq>.bin` and stores only the ref. Large tool outputs already flow through `ToolOutputDelta`; route oversized ones to spill.
- **Test:** a `shell_exec` whose stdout contains a NUL byte, a 0x80 invalid-UTF-8 byte, and a U+2028 separator round-trips through the spine and reconstructs byte-identical output on replay.
- **Proof:** hex-diff of replayed command output vs. original bytes is empty.

### P0-12c: Torn-write recovery with surfaced reconciliation (valid-prefix + CRC)
- **Contract:** each frame carries a rolling CRC over its canonical bytes chained to the prior frame; on open, the reader walks forward, validates every frame, and recovers to the last valid frame. A torn tail does not corrupt the valid prefix. Unlike SQLite, a tear is **not silent**: a typed `spine_torn` event records the tear offset and recovered `seq` before normal emission resumes.
- **Mechanism:** add CRC + `prev_seq` to the frame in `appendJsonlRecord` and a validate-and-recover pass in `readEvents`/`readLatestEvent`; replace `catch continue` (`store.zig:344`) with a reconcile-and-quarantine path. Mirror SQLite WAL's single-forward-pass / first-bad-frame-terminates model, but emit the signal SQLite swallows.
- **Test (AGENTS.md §XIV):** a corrupted JSONL suffix (truncated mid-frame, then garbage) leaves the valid prefix readable, the latest valid event retrievable, and produces a `spine_torn` row on the next append; the valid prefix is byte-identical before and after recovery.
- **Proof:** adversarial suite runs the §XIV corrupted-JSONL-suffix and same-millisecond-burst probes and passes.

### P0-12d: Byte-level session integrity gate (BOM, invalid UTF-8, duplicate seq, poisoned row)
- **Contract:** the append/read paths reject (not swallow) a leading UTF-8 BOM, invalid UTF-8 in a frame, a duplicate `seq`, and a structurally poisoned trailing row — each producing a typed reconciliation event and preserving the valid prefix (AGENTS.md §XVIII item 14).
- **Mechanism:** BOM check on file open; `std.unicode.utf8ValidateSlice` on each frame before parse; duplicate-`seq` detection in the forward scan; poisoned-row quarantine to a sidecar (never rewritten into the ledger). The project's own `.docs/log.txt` already exhibits pervasive `\u00ef\u00bb\u00bf` BOM prefixes on entries — direct evidence the failure class is real, not hypothetical.
- **Test:** a session dir seeded with a BOM-prefixed `events.jsonl`, a duplicate-`seq` pair, and a trailing invalid-UTF-8 row loads its valid prefix, reports all three integrity violations in order, and leaves `messages.jsonl`/`context.jsonl` untouched.
- **Proof:** the §XIV adversarial list (corrupted JSONL suffixes, duplicate seq, poisoned rows) is exercised by a dedicated integrity suite that fails open on every regression.

### P1-12e: Payload retention and compaction
- **Contract:** externalized payload files are garbage-collected against the live event range; a payload referenced by no surviving event (after context compaction advances `first_kept_seq`) is removed, never the ledger rewritten.
- **Mechanism:** a retention pass keyed off the latest checkpoint's `source_seq_end` / `first_kept_seq` (theme 01/02), deleting unreferenced `payloads/<id>.bin`. The append-only `events.jsonl` itself is never rewritten — only derived payload files are pruned.
- **Test:** after compaction, payload files for retracted sequences are gone while payloads for the kept window survive; replay of the kept window is unchanged.
- **Proof:** byte-identical replay of the compacted window before and after retention.

## North-star link

A shard is replayable only if its causality is reconstructible from the ledger after cold start. The north star (theme 01) branches a session into many context windows and converges them; each branch's evidence must survive a crash mid-write and be tail-able by a monotonic cursor. This theme is the substrate that makes the typed grammar (theme 03) durable, the durable execution (theme 04) recoverable, and the tool effect receipts (theme 05) byte-trustworthy. Without a binary-safe, monotonic, tear-resilient spine, "replay the shard" is a string the README asserts but the code cannot honor — exactly the gap exposed by the in-memory-only cursor in `stdio_rpc.zig` today.

## Definition of done
- `events.jsonl` rows carry a writer-assigned monotonic `seq`; replay and tail use `after_seq`, not timestamps.
- Binary payloads round-trip byte-identical via inline base64 or externalized `payload_ref`; no event row carries raw unescaped bytes.
- A torn write recovers to the valid prefix and emits a surfaced `spine_torn` reconciliation event (no silent truncation).
- BOM, invalid UTF-8, duplicate `seq`, and poisoned trailing rows are detected, reported, and quarantined without corrupting valid prefix state (AGENTS.md §XVIII item 14).
- LF-only framing is enforced; U+2028/U+2029 inside strings never split a frame.
- The §XIV adversarial suite (corrupted JSONL suffix, same-millisecond burst, duplicate seq, poisoned row) passes and gates promotion.
- No second event log, no parallel storage system, no rewrite of the append-only ledger — only derived payload files are pruned.
