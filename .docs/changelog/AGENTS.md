---
type: contract
id: docs/changelog-agent-rules
status: normative
updated: 2026-08-10
---

# Changelog record contract

Completed planning units are archived in `.docs/todo/changelog/`. The index
`.docs/todo/changelog/_log.md` is the closeout ledger. Do not delete or rewrite
historical units to make a later state look cleaner.

## Required record shape

Each completed unit keeps the planning-spec frontmatter used by the active
chain: `id`, `parent`, `type`, `protocol_version`, `status`, `acceptance`,
`exit_criterion`, `validation`, `evidence`, `next_todo`, and the source-message
proof fields. The body carries the state transition, owner paths, proof, and
residual boundary.

Every closeout entry must name:

- the canonical owner changed;
- the user-visible behavior and state transition;
- the exact validation command and result;
- installed-binary or external blockers when applicable;
- the next todo, or `NONE` when the chain is genuinely closed.

## Move rule

An active unit moves from `.docs/todo/pending/` to
`.docs/todo/changelog/` only after its exit criterion and proof are satisfied.
Update `_log.md` in the same change. Preserve source-message anchors and
residual failures; never report a partial proof as green.
