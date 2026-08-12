---
type: contract
id: docs/todo-agent-rules
status: normative
updated: 2026-08-12
---

# Planning-chain contract

VANTARI uses planning-spec v3 execution chains. Active parent and lettered
units live in `.docs/todo/pending/`. Completed units move once, with proof, to
`.docs/todo/changelog/`. Audit findings live in
`.docs/todo/findings/`: `00-INDEX.md` owns priority and numbered files own
evidence, smallest durable correction, acceptance, salvage source, and explicit
out-of-scope. There is no `.docs/todo/done/` owner in this project.

## Required unit fields

Each parent or execution unit carries YAML frontmatter for `id`, `type`,
`protocol_version`, `status`, `category`, `acceptance`, `exit_criterion`,
`validation`, `expected_exit_code`, `expected_output_pattern`, `evidence`,
`dependencies`, `next_todo`, and source-message proof. The body names entry
state, exit state, owner paths, invariants, rollback surface, and residual risk.

## Execution rules

- Read the current parent and its dependency chain before editing a unit.
- Read `.docs/todo/findings/00-INDEX.md` before starting a lower-priority
  chain. P0 integrity findings outrank new feature or polish work.
- Keep one canonical owner per state or side effect; reject parallel pools,
  registries, ledgers, and status buses.
- Make the smallest durable slice, run canonical tests, then run the required
  installed or consumer-path proof.
- Keep a failed probe and its residual boundary. Do not move a unit to the
  changelog because a build or partial test happens to pass.
- Update the parent continuation, `next_todo`, and
  `.docs/todo/changelog/_log.md` when a unit closes.
- Preserve historical receipts, but let current source/runtime evidence reopen
  a parent. Add a superseding finding; do not edit old evidence into a pass.
