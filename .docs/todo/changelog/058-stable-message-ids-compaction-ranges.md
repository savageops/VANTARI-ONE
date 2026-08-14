---
type: changelog
id: 058-stable-message-ids-compaction-ranges
status: completed
---

# 058 — Stable message IDs and compaction ranges

Move 67 is source-complete. The existing session ledger already assigned stable
message IDs and the context ledger already recorded explicit compaction ranges;
this slice added the missing end-to-end regression instead of introducing a
parallel identity system.

The proof preserves byte-identical `messages.jsonl` across compaction, retains
generated `msg-<seq>` and explicit delivery IDs across cold replay, suppresses
the second append for the same explicit ID, preserves checkpoint identity and
`source_seq_start`, `source_seq_end`, and `first_kept_seq`, and verifies that the
provider context builder uses the summary plus the exact raw suffix.

Proof: Debug `19/19` build steps and `2,155/2,155` tests passed; source
ReleaseFast `9/9`; source SHA-256
`CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`.
Installed promotion remains deferred. Automatic compaction remains gated by
later token-accounting and recovery moves.
