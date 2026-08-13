---
type: finding
id: harness-finding-22
status: closed
priority: P1
owner: .docs
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Documentation and WIP truth

## Finding

Public docs and planning records previously mixed shipped, source-present,
installed-proven, frontier, local-only, and unavailable states. The current
records preserve historical receipts while naming the live boundary: 021c is
the next auth unit, 035g/035h still require installed provider consumer proof,
036 is archived after installed lifecycle proof, browser routes remain
non-shipped, and frontier scaffolds remain explicitly labeled.

## Required mechanism

Keep one current technical summary and one findings index. Mark every capability as shipped, source-only, installed-proven, frontier, local prototype, or unavailable. Preserve historical receipts but attach a superseding current finding rather than rewriting the original evidence. Generate source count, test totals, and hashes during release instead of hand-maintaining them.

## WIP ledger

- 021: a-b archived; c-f pending; current frontier 021c.
- 035: a-f archived; g-h pending; source implementation present; installed proof missing.
- 036: a-h and parent archived; findings 10, 11, and 13 are closed; roadmap
  moves 21–32 and 38 are closed.
- PLUG: parent and a-h pending; unstarted; lower priority than P0 integrity work.

## Acceptance

- No pending parent says complete.
- Every active chain has one executable frontier and valid next_todo.
- Root README, backend README, architecture, AGENTS, docs index, technical summary, workspace record, and changelog agree on current truth.
- Local ignored browser files are never called shipped.
- Installed claims carry exact current hash and process-cleanup evidence.

## Source-message proof

- “Make sure all docs, readmes, agents.mds etc are updated”
- “assume full responsibility for any in progress work and make sure it is complete/accounted for”

## Out of scope

Do not erase historical closeout records or fabricate proof to make a chain green.

## Closure receipt — Move 32 (2026-08-13)

- Filesystem reconciliation confirms `021a` and `021b` are in
  `.docs/todo/changelog/`; `021c` is the sole active 021 frontier.
- The 036 parent and 036h terminal review are in `.docs/todo/changelog/`;
  finding 11 and the installed owner/ticket lifecycle gates are closed.
- `.docs/workspace.json` parses with the current source/installed SHA-256
  `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`,
  `installed_hash_matches: true`, and an empty installed process census.
- Public README, backend README, architecture, technical summary, docs index,
  roadmap, research, findings, and changelog now state the same boundaries.
- Dedicated installed eligibility/capacity snapshot probes are not inferred
  from the composed ticket lifecycle proof; the docs name them as unrun.
