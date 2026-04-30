---
id: 022d-model-presentation-prompt-layers
parent: 022-model-presentation-prompt-layers
status: completed
owner: VAR1
created: 2026-04-30
---

# 022d Validation Comparison Docs Commit

## Contract

Validate the upgraded lane, compare against the main branch binary when feasible, update durable docs, archive the chain, and commit the completed slice.

## Scope

- Run Zig tests for the changed prompt/config/tool contract.
- Run at least one live model prompt designed to score tool-selection adherence.
- Build or use a main-branch binary for the same prompt when feasible.
- Update `.docs/todo/changelog/_log.md` with the execution result.
- Move completed 022 todo files from pending to changelog.
- Commit the completed slice on `develop`.

## Acceptance

- Validation output names the exact pass/fail state for tests and live comparison.
- Any baseline-build blocker is explicit and non-speculative.
- Final commit message summarizes prompt layering, descriptor hardening, and validation status.

## Evidence

- Committed the implementation checkpoint as `834a632 feat(var1): add prompt layer envelope`.
- Built upgraded `develop` and baseline `main` with separate Zig cache roots to avoid artifact contamination.
- Health passed on both lanes using active provider `zai`, model `glm-5.1`.
- Upgraded session `session-1777576359915-3cf77bc839898869` completed `write_file -> read_file -> append_file -> read_file -> replace_in_file -> read_file` and returned exactly `BENCH_OK beta=TWO gamma=three`.
- Main session `session-1777576409385-a2b609f0db4508dc` completed only `write_file`, then failed `StepLimitExceeded`.

## Exit State

This unit exits when the working tree contains the completed implementation plus archived docs and the slice is committed.
