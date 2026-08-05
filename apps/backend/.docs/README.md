# VAR1 Docs Plane

This directory is archival and human-readable context for `VAR1`.

Canonical runtime and process state lives under `.var/`:

- `.var/sessions/<session-id>/` for durable session records, transcripts, context checkpoints, event logs, and final output
- `.var/todos/session/<session-id>/` for active readable session slices when generated
- `.var/changelog/<session-id>/` and `.var/changelog/_log.md` for completion history
- `.var/memories/memories.md` for the local memory ledger when generated

`.docs/` is for snapshots, research, and historical notes only. It is not a second runtime state system. Historical changelog entries may still mention old task or `.harness` names; current code and docs must use session and `.var` language.
