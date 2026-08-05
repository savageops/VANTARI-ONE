---
id: 020-vantari-one-monorepo-root-normalization
type: parent
protocol_version: "2.0"
spec_status: approved
category: refactor
status: done
epic_boundary: "Normalize the VANTARI-ONE root into a truthful monorepo control plane by fixing canonical ownership docs, stale imported paths, and root/app boundary language without physically moving the live VAR1 runtime."
subtodo_start: /todo/changelog/020a-vantari-one-monorepo-root-normalization.md
subtodo_final: /todo/changelog/020d-vantari-one-monorepo-root-normalization.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
---
# 020 VANTARI-ONE Monorepo Root Normalization

## Objective

Make the repo root truthful as a monorepo without introducing a risky physical runtime move. The outcome should let a cold-start operator understand what the root owns, what the app owns, where live state really lives, and which current docs are canonical.

## Rationale

The runtime itself is already coherent and validated under `apps/backend/variant-1`. The remaining drift is at the repo root: stale pre-import paths, ambiguous root-vs-app `.harness` language, and missing root-facing monorepo documentation. Fixing that control plane is a high-value low-blast-radius refactor.

## Scope

**In scope:**
- add a root repo README
- update canonical root docs and research to use `apps/backend/variant-1`
- update app operator docs that still reference the old standalone checkout path
- clean script-local cache/toolchain labels that still carry the old repo name
- add a cold-start monorepo structural snapshot

**Out of scope:**
- physically moving `apps/backend/variant-1`
- adding pnpm/turbo/nx workspace files before they are operationally justified
- rewriting all historical snapshots that intentionally preserve old evidence paths
- changing `VAR1` runtime semantics

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | `refactor` only. No new product/runtime feature is introduced. |
| Blast radius ceiling | medium - doc, path, and operator-wrapper cleanup only. |
| Runtime boundary | `apps/backend/variant-1/.harness/tasks/<task-id>/` remains the live runtime truth. |
| Governance boundary | repo root remains the monorepo control plane. |
| Parallel systems | forbidden - root docs must not imply a second app-runtime ledger. |

## Invariants

- I1: `apps/backend/variant-1` remains the only live code surface in this slice.
- I2: Root `.harness/` does not become the runtime task owner for `VAR1`.
- I3: Canonical docs point to the current `VANTARI-ONE` path, not the imported pre-monorepo checkout.
- I4: Empty `apps/frontend`, `apps/www`, and `packages` remain valid reserved lanes, not accidental clutter.
- I5: Validation of the existing Zig runtime must stay green after path/script cleanup.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/020-vantari-one-monorepo-root-normalization.md` | parent | Chain root | archived |
| `/todo/changelog/020a-vantari-one-monorepo-root-normalization.md` | a | Baseline / boundary lock | archived |
| `/todo/changelog/020b-vantari-one-monorepo-root-normalization.md` | b | Root docs and structural snapshot | archived |
| `/todo/changelog/020c-vantari-one-monorepo-root-normalization.md` | c | App doc and script cleanup | archived |
| `/todo/changelog/020d-vantari-one-monorepo-root-normalization.md` | d | Verification / closeout | archived |

## Next todo
`NONE`
