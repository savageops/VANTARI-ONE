---
id: 020b-vantari-one-monorepo-root-normalization
parent: 020-vantari-one-monorepo-root-normalization
type: execution-unit
protocol_version: "2.0"
category: refactor
phase: b
status: done
patch_scope: "Root README, canonical root harness docs, root research synthesis, and a cold-start structural snapshot."
blast_radius: medium
blast_radius_justification: "Touches canonical root-facing docs but not runtime logic."
idempotency_contract: idempotent
idempotency_notes: "Doc rewrites can be reapplied safely from the current filesystem."
acceptance: "A cold-start operator can understand the monorepo root, current app ownership, and why workspace-manager files are deferred."
exit_criterion: "Root-facing docs point at `apps/backend/variant-1` and a structural snapshot exists for the current repo topology."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; Get-Content README.md -First 200; Write-Host '---'; Get-Content .harness\\docs\\architecture.md -First 220; Write-Host '---'; Get-Content .docs\\research\\vantari-one-monorepo-structural-snapshot.md -First 220"
expected_exit_code: 0
expected_output_pattern: "apps/backend/variant-1"
evidence: "Root governance is now explicit: added `README.md`, added research synthesis plus structural snapshot, and corrected canonical root docs to describe `VANTARI-ONE` as the control plane while keeping `apps/backend/variant-1` as the current live runtime owner."
conflict_surface: ""
invariants:
  - "I2: Root `.harness/` does not become the runtime task owner for `VAR1`."
  - "I3: Canonical docs point to the current `VANTARI-ONE` path, not the imported pre-monorepo checkout."
  - "I4: Empty `apps/frontend`, `apps/www`, and `packages` remain valid reserved lanes, not accidental clutter."
entry_state: "The repo lacked a root-facing README and the canonical root docs still described the imported app path too loosely."
rollback_surface: "README.md, `.harness/docs/*`, `.docs/research/*`, and index-link edits only."
dependencies: "/todo/changelog/020a-vantari-one-monorepo-root-normalization.md"
next_todo: /todo/changelog/020c-vantari-one-monorepo-root-normalization.md
continuation: "On completion: record evidence, set status done, archive this unit, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 020b Root Governance And Snapshot

## Execute Now
Make the root truthful as a monorepo control plane and save a cold-start structural snapshot.

## Next todo
`/todo/changelog/020c-vantari-one-monorepo-root-normalization.md`
