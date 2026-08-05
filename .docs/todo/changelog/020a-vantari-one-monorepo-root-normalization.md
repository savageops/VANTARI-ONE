---
id: 020a-vantari-one-monorepo-root-normalization
parent: 020-vantari-one-monorepo-root-normalization
type: execution-unit
protocol_version: "2.0"
category: refactor
phase: a
status: done
patch_scope: "Lock the current monorepo-root boundary before edits so the cleanup stays on governance and path truth, not runtime relocation."
blast_radius: low
blast_radius_justification: "Read-only recon and scope lock."
idempotency_contract: idempotent
idempotency_notes: "Baseline evidence can be re-captured safely."
acceptance: "The repo root, app root, and runtime-state owner are explicitly separated before implementation begins."
exit_criterion: "The baseline evidence names the only live app, the current runtime task owner, and the main root-drift points."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; Get-ChildItem apps; Write-Host '---'; Get-Content apps\\backend\\variant-1\\README.md -First 80; Write-Host '---'; Get-Content .harness\\README.md -First 80"
expected_exit_code: 0
expected_output_pattern: "variant-1"
evidence: "Baseline lock confirmed that `apps/backend/variant-1` is the only live code surface, runtime truth remains app-local under `apps/backend/variant-1/.harness/tasks/<task-id>/`, and the primary drift was stale imported path language plus missing root-facing monorepo guidance."
conflict_surface: ""
invariants:
  - "I1: `apps/backend/variant-1` remains the only live code surface in this slice."
  - "I2: Root `.harness/` does not become the runtime task owner for `VAR1`."
  - "I3: Canonical docs point to the current `VANTARI-ONE` path, not the imported pre-monorepo checkout."
entry_state: "The runtime is validated, but root docs and operator surfaces still contain stale standalone-checkout references."
rollback_surface: "None; read-only baseline capture."
dependencies: ""
next_todo: /todo/changelog/020b-vantari-one-monorepo-root-normalization.md
continuation: "On completion: record evidence, set status done, archive this unit, continue immediately to next_todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 020a Baseline Lock

## Execute Now
Freeze the root-vs-app ownership boundary before editing so the slice does not drift into a runtime move.

## Next todo
`/todo/changelog/020b-vantari-one-monorepo-root-normalization.md`
