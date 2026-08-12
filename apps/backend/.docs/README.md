# VAR1 Docs Plane

This directory is archival and human-readable context for `VAR1`. The project
record index is [`../../.docs/index.md`](../../.docs/index.md); the current
technical summary is [`../../.docs/technical_summary.md`](../../.docs/technical_summary.md).

Canonical runtime and process state is intended to live under `.var/`:

- `.var/sessions/<session-id>/` for durable session records, transcripts, context checkpoints, event logs, and final output
- `.var/todos/session/<session-id>/` and `.var/changelog/<session-id>/` are
  legacy generated projections pending consolidation; tickets own work
  lifecycle and project `.docs/todo/` owns planning evidence
- `.var/memories/memories.md` for the local memory ledger when generated

Project `.docs/` carries records, research, active planning chains, and
completed evidence. It is not a second runtime state system. Active units live
in `../../.docs/todo/pending/`; completed units live in
`../../.docs/todo/changelog/`. Historical changelog entries may still mention
old task or `.harness` names; current code and docs must use session and `.var`
language.

The current agent path boundary is documented in `../../.docs/technical_summary.md`:
`runtime.full_access_mode` is default-off, and all widened file/process access
must pass through the shared resolver while `.var` remains canonical runtime
state.

The current full-harness readiness boundary and executable findings are
recorded in
`../../.docs/research/2026-08-12-full-harness-sitrep.md` and
`../../.docs/todo/findings/00-INDEX.md`. Older architecture notes do not
override those current records.
