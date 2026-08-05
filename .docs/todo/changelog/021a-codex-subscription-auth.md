---
id: 021a-codex-subscription-auth
parent: 021-codex-subscription-auth
type: execution-unit
protocol_version: "2.0"
category: feature
phase: a
status: done
patch_scope: "Interpretation freeze and invariant declaration. No artifact change."
blast_radius: low
blast_radius_justification: "Read-only recon and scope lock. No runtime files are modified."
idempotency_contract: idempotent
idempotency_notes: "The baseline commands are read-only and can be re-run safely."
acceptance: "The Codex subscription auth contract is locked to `.var/auth/auth.json`, API-key parity, browser/device OAuth options, and explicit Codex transport before implementation begins."
exit_criterion: "Baseline evidence names the current API-key-only auth boundary, the Pi OAuth reference boundary, the official Codex storage boundary, and the files each later unit may modify."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE; iex search --max-hits 30 \"auth_store\" apps/backend/src; iex search --max-hits 30 \"openai-codex\" .refs/badlogic__pi-mono/packages .refs/openai__codex"
expected_exit_code: 0
expected_output_pattern: "auth_store"
evidence: "ix search --max-hits 30 \"auth_store\" apps/backend/src -> ix.result.v1 status=ok, matches=6, including apps/backend/src/core/auth/store.zig through apps/backend/src/core/index.zig and apps/backend/src/core/auth/resolver.zig; ix search --max-hits 30 \"openai-codex\" .refs/badlogic__pi-mono/packages .refs/openai__codex -> ix.result.v1 status=ok, matches=203, including .refs/badlogic__pi-mono/packages/ai/src/utils/oauth/openai-codex.ts, openai-codex-responses provider tests, and official Codex app-server auth modes `chatgpt` and `chatgptDeviceCode` in .refs/openai__codex/codex-rs/app-server/README.md:1477-1557."
conflict_surface: ""
invariants:
  - "I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata."
  - "I3: Existing `auth_type: \"api_key\"` records remain readable and continue to serve ZAI/OpenAI-compatible providers."
  - "I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`."
entry_state: "The parent spec exists at `/todo/pending/021-codex-subscription-auth.md` with `spec_status: approved`, and no `021*` units have been archived."
rollback_surface: "None. This unit introduces no artifact changes."
dependencies: ""
next_todo: /todo/pending/021b-codex-subscription-auth.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/021a-codex-subscription-auth.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021a Baseline and Contract Lock

## Execute Now
Freeze the Codex subscription-auth interpretation and source evidence before implementation touches runtime auth code.

## Why This Execution Unit Exists

This chain crosses auth persistence, transport, and CLI surfaces. The baseline unit prevents later slices from reinterpreting Codex auth as a generic API-key feature or from introducing a second auth ledger outside `.var`. It also locks the distinction between Pi's OpenAI Codex browser-PKCE path and official Codex's browser plus device-code storage model.

## Pre-flight Checklist

- [ ] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] All `entry_state` claims are verifiable on the current filesystem.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius medium or high.
- [ ] If re-executing after partial failure: idempotency_contract is read and the correct recovery path is determined.

## Entry State

- `/todo/pending/021-codex-subscription-auth.md` exists and declares this chain as a `feature`.
- `apps/backend/src/core/auth/store.zig` exists and currently reads active providers from `.var/auth/auth.json`.
- `.docs/research/2026-04-24-auth-persistence-study.md` exists and records the prior Pi/VANTARI auth persistence study.

## Patch Surface

**Modifies:**
- None.

**Adds:**
- None.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/src/**` - implementation begins in `021b`.
- `.var/auth/auth.json` - live secrets are never read or modified by planning/baseline work.

## Interpretation Locks

- R1: Treat `.var/auth/auth.json` as the only durable runtime auth ledger.
- R2: Treat OS keyring persistence as a future hardening layer, not a phase-one dependency.
- R3: Preserve existing API-key provider records and `.env` bootstrap behavior.
- R4: Implement Codex subscription auth as OAuth credentials plus subscription metadata, not as a fake static API key.
- R5: Keep Codex backend transport separate from OpenAI-compatible `/v1/chat/completions`.
- R6: Use fake tokens and local fixtures for tests; never call real auth providers in the test suite.

## Invariants This Unit Must Preserve

- I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata.
- I3: Existing `auth_type: "api_key"` records remain readable and continue to serve ZAI/OpenAI-compatible providers.
- I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 30 "auth_store" apps/backend/src` | `0` | `auth_store.zig` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 30 "openai-codex" .refs/badlogic__pi-mono/packages .refs/openai__codex` | `0` | `openai-codex` | yes |

**Evidence to capture:** Exact stdout from both source-mapping commands.

## Exit State (Handoff Contract)

- The implementation contract is locked: `.var/auth/auth.json` is canonical, API-key parity is mandatory, and Codex subscription auth requires OAuth credential records plus explicit transport.
- The `021b` unit may change only auth schema/resolver/type/test surfaces needed to represent and resolve API-key plus OAuth records.

## Rollback Procedure

1. No rollback required; no files are modified.

## Next todo
`/todo/pending/021b-codex-subscription-auth.md`

## Completion

- [x] Pre-flight passed.
- [x] All validation commands executed.
- [x] Post-flight: all Exit State claims are verifiable.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [x] `mv /todo/pending/021a-codex-subscription-auth.md /todo/changelog/021a-codex-subscription-auth.md` - verified after archival.
- [x] Continue immediately to `next_todo`. No pause. No batch.
