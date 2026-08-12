---
type: roadmap-closeout
id: roadmap/17-byte-level-session-integrity
status: closed
updated: 2026-08-12
owner: apps/backend/src/shared/jsonl.zig
parent: .docs/roadmap/24-harness-capability-next-90.md
decision: delete/consolidate
---

# 17 — Byte-level session integrity

## Outcome

VANTARI now has one valid-prefix contract for its append-only JSONL ledgers.
Every migrated projection reads forward, accepts only typed rows in strict byte
and sequence order, and stops at the first defect. The append owner validates
the current bounded tail before writing and returns `PoisonedJsonlSuffix`
without changing the file.

This closes roadmap move 17. It does not add a storage engine, repair daemon,
sidecar ledger, CRC schema, background scanner, or automatic truncation path.

## Canonical mechanism

`apps/backend/src/shared/jsonl.zig` owns `PrefixReader`:

1. Frame only on LF. A trailing CR is removed from a CRLF record; U+2028 and
   U+2029 remain ordinary JSON-string bytes.
2. Accept one UTF-8 BOM only at byte zero, then preserve its presence as
   `had_bom` while parsing the first row normally.
3. Refuse invalid UTF-8 before JSON validation.
4. Refuse malformed JSON before a typed consumer parses its schema.
5. Let the consumer reject an invalid typed schema.
6. Require each sequenced row to be greater than the prior sequence. A duplicate
   or regression ends the projection before the ambiguous row.
7. Preserve `valid_end`, issue kind, row, byte offset, and offending sequence in
   memory. Reads do not rewrite the ledger.

The shared owner now drives:

- event latest/all/`after_seq` projections;
- session messages;
- context checkpoints;
- write-intent reads;
- session summary migration and latest-row projection.

`apps/backend/src/shared/fsutil.zig:appendJsonlRecord` uses the same reader over
the current bounded tail. A complete final JSON object without LF receives its
terminator before the next record. A torn or poisoned final record blocks the
append and remains byte-identical.

## Competitive synthesis

| Source | Strong invariant | VANTARI decision |
|---|---|---|
| [OpenAI Codex rollout recorder](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs) | Serialize one JSONL writer. | Retain one writer boundary; reject malformed-line continuation for canonical recovery state. |
| [pi JSONL framing](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/src/modes/rpc/jsonl.ts) | Split only on LF; Unicode line separators can occur inside strings. | Adopt LF-only framing in one byte reader. |
| [SQLite WAL format](https://sqlite.org/walformat.html) | Recovery stops at the first invalid frame. | Preserve the valid prefix; do not silently advance beyond corruption. |
| [etcd WAL decoder](https://github.com/etcd-io/etcd/blob/main/server/storage/wal/decoder.go) | Track the last valid offset and distinguish torn data; strict mode stops. | Retain `valid_end` and typed issue data without a second recovery log. |
| [NATS file store](https://github.com/nats-io/nats-server/blob/main/server/filestore.go) | Length/checksum records make corruption explicit. | Keep checksums as a future measured option; current failure classes are detected without schema expansion. |
| [Kafka LogSegment recovery](https://github.com/apache/kafka/blob/trunk/storage/src/main/java/org/apache/kafka/storage/internals/log/LogSegment.java) | Validate in order and stop/truncate at the first invalid batch under an explicit recovery owner. | Stop in order; reject automatic truncation because the transcript remains evidence. |

The synthesis is smaller than every durable-log substrate above: VANTARI needs
their ordered valid-prefix invariant, not their database segment, index,
checkpoint, or checksum architecture.

## Proof

- Pinned Zig 0.15.1 graph: 19/19 steps and 1,944/1,944 tests.
- ReleaseFast: 9/9 steps.
- Adversarial tests cover BOM, LF-only framing, invalid UTF-8, malformed/torn
  JSON, invalid typed schema, duplicate/non-monotonic sequences, latest/all/suffix
  event parity, message/context/intent/summary parity, and append refusal.
- Packaged GGUF duplicate audit: 124 segments, three adjacent test-fixture
  candidates, zero exact pairs, and no duplicate production owner. The tests
  remain separate because each names a different ledger contract.
- Source and installed `%LOCALAPPDATA%\Vantari\bin\vantari.exe` SHA-256:
  `86724BD0346E6B6079BFBA2DD64A2559C359DAED7DA9C7B5D69B98705983C344`.
- Installed `kernel-stdio` proof used a disposable `VANTARI_HOME`.
  `session/get` returned exactly one event and one message before duplicate
  sequence rows, returned one event before a torn suffix, and `session/cancel`
  could not append behind that suffix. The poisoned ledger remained 107 bytes
  with SHA-256
  `299360B1639A9698C8A87399771AD88BA2299B27823BC4574EDAB1347632E7DC`.
  The isolated runtime was removed and zero VANTARI process remained.

## Production-state reconciliation

A read-only audit of `C:\Users\Savage\.vantari` inspected 31,691 targeted
ledgers, 1,421,226 rows, and 235,772,521 bytes. It found 877 malformed
`context.jsonl` files. Every affected session was an `initialized` legacy test
fixture with one of four known poison strings; none had a retained parent,
continuation, summary, or changelog owner.

The 877 whole session directories were moved reversibly to
`C:\Users\Savage\.vantari-quarantine\2026-08-12-legacy-context-poison-fixtures`.
The quarantine contains `repair.ps1`, `rollback.ps1`, `manifest.json`, and the
session payloads. Manifest SHA-256 is
`43FCC3A9530D204B77FF9B37D4534909563628A9EFA2F396F90FDC927811A9BC`;
per-tree rehash found zero mismatches and rollback syntax validation found zero
errors.

The post-repair audit inspected 29,937 ledgers, 1,417,061 rows, and 235,074,120
bytes with zero UTF-8, JSON, duplicate-sequence, or non-monotonic-sequence
defects. No operator session was merged, rewritten, or deleted.

## Explicit boundary

- Read projections currently return the valid prefix; they do not persist a
  new operator-facing corruption event. If real operation needs that surface,
  project `PrefixReader.issue` through the existing event/health owner. Do not
  add a sidecar status bus.
- Append validation is intentionally bounded to the current tail. The live root
  is fully audited and clean, and this binary cannot append behind a newly
  poisoned tail. A full scan on every append would regress move 13's bounded
  append cost.
- Multi-process writer authority remains owned by moves 21–23. Do not add a
  second file lock here.
- CRC and rolling checksums remain rejected until a byte-flip class escapes
  strict UTF-8/JSON/schema/sequence validation often enough to justify changing
  every ledger row.

## Next move

Move 18: bind cancellation to the observed turn/event generation so a stale
cancel cannot terminate a newer turn.
