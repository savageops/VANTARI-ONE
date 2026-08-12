---
type: finding
id: harness-finding-22
status: pending
priority: P1
owner: .docs
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Documentation and WIP truth

## Finding

Public docs and planning records mix shipped, source-present, installed-proven, frontier, and local-only states. Chain 036 claims complete despite source-level lifecycle defects; chain 035 has source implementation but no installed consumer proof; the browser client is ignored; backend docs claim write intents, probing, DAP, eval, TTSR, and quota behavior beyond runtime truth.

## Required mechanism

Keep one current technical summary and one findings index. Mark every capability as shipped, source-only, installed-proven, frontier, local prototype, or unavailable. Preserve historical receipts but attach a superseding current finding rather than rewriting the original evidence. Generate source count, test totals, and hashes during release instead of hand-maintaining them.

## WIP ledger

- 021: a-b archived; c-f pending; current frontier 021c.
- 035: a-f archived; g-h pending; source implementation present; installed proof missing.
- 036: a-g archived; parent remains pending. Findings 10 and 13 are closed;
  finding 11 and roadmap moves 21–30 are its sole current repair frontier.
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
