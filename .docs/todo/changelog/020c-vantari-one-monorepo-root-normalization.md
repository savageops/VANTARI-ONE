---
id: 020c-vantari-one-monorepo-root-normalization
parent: 020-vantari-one-monorepo-root-normalization
type: execution-unit
protocol_version: "2.0"
category: refactor
phase: c
status: done
patch_scope: "Current app README, architecture doc, canonical research references, and stale script-local naming residue."
blast_radius: medium
blast_radius_justification: "Touches the current app's operator docs and wrappers but not the executable behavior contract."
idempotency_contract: idempotent
idempotency_notes: "Path and label cleanup can be replayed safely."
acceptance: "Canonical app docs and wrappers no longer point at the old standalone repo path."
exit_criterion: "Key operator docs and wrappers resolve to the current `VANTARI-ONE\\apps\\backend\\variant-1` location."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; Select-String -Path apps\\backend\\variant-1\\README.md, apps\\backend\\variant-1\\architecture.md, apps\\backend\\variant-1\\scripts\\zigw.ps1, apps\\backend\\variant-1\\scripts\\zigw.sh -Pattern 'agent-harness-experimental' -SimpleMatch"
expected_exit_code: 0
expected_output_pattern: ""
evidence: "Updated the live app docs and wrapper labels to the current monorepo path: `README.md` and `architecture.md` now point to `VANTARI-ONE\\apps\\backend\\variant-1`, canonical research docs use the app-under-`apps/backend` path, and the Zig wrapper cache/toolchain labels no longer carry `agent-harness-experimental` residue."
conflict_surface: ""
invariants:
  - "I1: `apps/backend/variant-1` remains the only live code surface in this slice."
  - "I3: Canonical docs point to the current `VANTARI-ONE` path, not the imported pre-monorepo checkout."
entry_state: "The live app still had old operator command paths and wrapper-local naming residue from the pre-monorepo checkout."
rollback_surface: "Doc text and script-local cache/toolchain label strings only."
dependencies: "/todo/changelog/020b-vantari-one-monorepo-root-normalization.md"
next_todo: /todo/changelog/020d-vantari-one-monorepo-root-normalization.md
continuation: "On completion: record evidence, set status done, archive this unit, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 020c App Path And Wrapper Cleanup

## Execute Now
Remove stale imported-path residue from the current canonical app docs and wrappers.

## Next todo
`/todo/changelog/020d-vantari-one-monorepo-root-normalization.md`
