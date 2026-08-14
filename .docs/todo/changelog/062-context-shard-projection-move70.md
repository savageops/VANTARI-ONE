---
type: changelog
id: changelog/062-context-shard-projection-move70
status: complete-source-only
date: 2026-08-14
owner: apps/backend/src/core/context + apps/backend/src/core/agents + apps/backend/src/core/sessions
---

# Move 70 — bounded context shards

The canonical child launch path now carries the immutable parent checkpoint
identity already stored in the execution receipt into the existing context
compiler. Child provider windows receive the exact parent checkpoint summary
and a recent suffix capped at 64 KiB; parent transcript rows are not copied to
the child session. Missing or legacy checkpoint identity falls back to the
same bounded suffix rule.

`SessionStore` now separates compiler checkpoints from shard lifecycle rows,
preserves parent range/token metadata on shard results, and caps terminal
branch summaries at a UTF-8-safe 16 KiB. `Supervisor` remains the one terminal
convergence owner and emits one evidence-bearing shard result per child through
the existing mailbox path. No shard registry, second transcript, poller, or
worker pool was added.

Proof: Debug `19/19` steps and `2166/2166` tests; source ReleaseFast `9/9`;
source SHA-256
`1E5AFD64D502514FAFC473FA8DD0B8E7B80C905EC52074AB629B1ACAD0157BFE`.
Installed promotion remains deferred; the preserved installed owner remains
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

Research: `.docs/research/2026-08-14-context-shard-projection-move70.md`.
