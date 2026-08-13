---
id: 021e-codex-subscription-auth
parent: 021-codex-subscription-auth
type: execution-unit
protocol_version: "2.0"
category: feature
phase: e
status: done
patch_scope: "Document and harden operator-facing Codex auth status, fixtures, and changelog evidence after runtime support exists."
blast_radius: medium
blast_radius_justification: "This changes operator docs, status examples, and test fixtures consumed by humans and scripts but does not modify auth execution internals."
idempotency_contract: idempotent
idempotency_notes: "Documentation and fixture edits are deterministic and can be re-applied safely."
acceptance: "README, architecture docs, and fixtures describe installed `$VANTARI_HOME/auth.json`, workspace `.var/auth.json`, `.env` bootstrap semantics, Codex subscription login, logout, status redaction, and API-key parity without exposing real secrets."
exit_criterion: "`.\scripts\zigw.ps1 build test --summary all` and docs searches both prove the new auth surface is documented and secret-free."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "Docs: root README, backend README, architecture, AGENTS, SKILL, llms, auth-persistence research, technical summary, index, findings, workspace, roadmap, and changelog all describe the shipped provider/auth boundary. Sanitized status example contains provider/account/plan/expiry metadata and no credential values. `ix.exe search --max-hits 40 \"lit:/codex/responses\" README.md apps/backend/README.md apps/backend/architecture.md .docs` -> status `ok`, 27 matches; `ix.exe search --max-hits 20 \"lit:fake-access-token || lit:fake-refresh-token || lit:fake-id-token\" README.md apps/backend/README.md apps/backend/architecture.md .docs/research` -> status `ok`, zero matches. Move 34 records the prior installed transport checkpoint: 19/19 build steps, 1,963/1,963 tests, ReleaseFast/install 9/9, SHA-256 `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`, installed `/codex/responses` fixture success, no bearer output, zero final processes. The current installed artifact is recorded by the later Move 37/39 closeout."
conflict_surface: ""
invariants:
  - "I1: Installed credentials live in `$VANTARI_HOME/auth.json`; workspace-scoped credentials live in `.var/auth.json`; each is the canonical durable auth ledger for its runtime boundary."
  - "I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures."
  - "I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`."
entry_state: "The `021d` unit is archived with evidence, and Codex subscription credentials can be resolved and consumed by a dedicated provider transport in fake and installed local fixtures."
rollback_surface: "Before rollback, verify no unrelated user edits exist. Revert README/architecture/research fixture changes and remove only changelog lines written by this unit."
dependencies: "021a-codex-subscription-auth, 021b-codex-subscription-auth, 021c-codex-subscription-auth, 021d-codex-subscription-auth"
next_todo: /todo/pending/021f-codex-subscription-auth.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/021e-codex-subscription-auth.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021e Docs, Fixtures, and Operator Status Hardening

## Execute Now
Sync operator documentation and status fixtures to the shipped Codex subscription auth contract without adding new runtime behavior.

## Why This Execution Unit Exists

Auth features fail operationally when the operator surface is ambiguous. This slice is separate from implementation so docs and fixtures can describe the final behavior after the schema, CLI, and transport are real. It also gives verification a stable redaction and command-contract surface to assert.

## Pre-flight Checklist

- [x] `021a` through `021d` are archived in `/todo/changelog/` with evidence-bearing closure notes.
- [x] `VAR1 auth status --json` exists and can be run against fake or sanitized auth state.
- [x] `conflict_surface` is empty or cross-chain dependency is resolved.
- [x] Rollback procedure is populated for blast_radius medium.
- [x] If re-executing after partial failure: idempotency_contract is read and direct re-execution is safe.

## Entry State

- `$VANTARI_HOME/auth.json` supports installed API-key and OAuth records; `.var/auth.json` is the workspace-scoped auth ledger.
- Codex auth commands exist and do not print secrets.
- Codex provider routing exists and is tested through fake transport.

## Patch Surface

**Modifies:**
- `apps/backend/README.md` - document auth commands and installed/workspace auth ownership.
- `apps/backend/architecture.md` - document auth resolver and provider transport boundaries.
- `.docs/research/2026-04-24-auth-persistence-study.md` - add a short implementation follow-up note if the shipped contract differs from the initial recommendation.
- `.docs/todo/changelog/_log.md` - append the execution summary when this unit completes.
- `apps/backend/tests/**` - add or update sanitized status fixtures.

**Adds:**
- None. Existing fake auth fixtures in `apps/backend/tests/auth_store_test.zig` and the disposable installed fixture are the canonical proof surfaces; a second snapshot system would duplicate ownership.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/auth/store.zig` - runtime auth internals belong to prior units.
- `apps/backend/src/core/providers/openai_compatible.zig` - transport belongs to `021d`.
- Live `.var/auth/auth.json` values.

## Detailed Requirements

- R1: Document installed `$VANTARI_HOME/auth.json` and workspace `.var/auth.json` as the canonical provider credential and subscription metadata ledgers for their respective runtime boundaries.
- R2: Document `.env` as bootstrap/operator configuration, not the authoritative store after the installed `$VANTARI_HOME/auth.json` or workspace `.var/auth.json` exists.
- R3: Document `VAR1 auth login openai-codex`, `VAR1 auth logout openai-codex`, and `VAR1 auth status --json`.
- R4: Include a redacted example auth status payload with no token-shaped or key-shaped values.
- R5: Document that Codex subscription transport is explicit and separate from OpenAI-compatible chat completions.
- R6: Add fixtures proving status output redacts `api_key`, `access_token`, and `refresh_token`.
- R7: Append one concise line to `.docs/todo/changelog/_log.md` with the validation commands and outcomes after execution.

## Invariants This Unit Must Preserve

- I1: Installed credentials live in `$VANTARI_HOME/auth.json`; workspace-scoped credentials live in `.var/auth.json`; each is the canonical durable auth ledger for its runtime boundary.
- I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures.
- I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix.exe search --max-hits 40 "lit:/codex/responses" README.md apps/backend/README.md apps/backend/architecture.md .docs` | `0` | `ix.result.v1` status `ok`; 21 matches | yes |
| 3 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix.exe search --max-hits 20 "lit:fake-access-token || lit:fake-refresh-token || lit:fake-id-token" README.md apps/backend/README.md apps/backend/architecture.md .docs/research` | `0` | `ix.result.v1` status `ok`; zero matches | yes |

**Evidence to capture:** Zig test stdout plus documentation search output proving canonical auth docs exist and docs do not contain raw token labels except where intentionally explaining redaction.

## Exit State (Handoff Contract)

- Operator docs explain Codex subscription auth, API-key parity, `.env` bootstrap, and installed/workspace auth ownership.
- Sanitized fixtures prove `auth status` and docs avoid raw secrets.
- `.docs/todo/changelog/_log.md` contains the execution summary line for this feature.
- The terminal `021f` unit can run full regression and archive the chain.

## Rollback Procedure

1. Verify the listed files contain no unrelated user edits.
2. Revert docs changes in README, architecture, and research files.
3. Remove the snapshot added by this unit if it exists.
4. Remove only the `_log.md` line added by this unit.
5. Revert sanitized fixture changes added by this unit.
6. Run `.\scripts\zigw.ps1 build test --summary all`.

## Next todo
`/todo/pending/021f-codex-subscription-auth.md`

## Completion

- [x] Pre-flight passed.
- [x] All validation commands executed.
- [x] Post-flight: all Exit State claims are verifiable.
- [x] Evidence captured in the `evidence` field.
- [x] Status set to `done`.
- [x] `mv /todo/pending/021e-codex-subscription-auth.md /todo/changelog/021e-codex-subscription-auth.md` - verified.
- [x] Continue immediately to `next_todo`.
