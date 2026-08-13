---
id: 021f-codex-subscription-auth
parent: 021-codex-subscription-auth
type: verification-closeout
protocol_version: "2.0"
category: feature
phase: f
status: done
patch_scope: "No artifact change. This unit validates, verifies invariants, and terminates the chain."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only. Re-execution from any point is safe."
acceptance: "All Codex subscription auth units are archived with evidence, full Zig regression passes, API-key auth parity remains intact, Codex auth status is sanitized, and docs describe the installed `$VANTARI_HOME/auth.json` plus workspace `.var/auth.json` contract."
exit_criterion: "Full regression commands exit 0, all invariant assertions pass, and parent archival protocol can move `021-codex-subscription-auth.md` to `/todo/changelog/`."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all; .\\zig-out\\bin\\vantari.exe health; .\\zig-out\\bin\\vantari.exe auth status --json"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "2026-08-13 closeout: `scripts/zigw.ps1 build test --summary all` -> exit 0, 19/19 build steps succeeded, 1,963/1,963 tests passed, zero leaks. With disposable `VANTARI_HOME=apps/backend/.zig-cache/codex-installed-proof`, built `vantari.exe health --json` -> exit 0, `ok:true`, `auth_provider:openai-codex`, `context_window_tokens:131072`, healthy six-worker pool, zero queued/running tickets; `vantari.exe auth status --json` -> exit 0, provider/model/account/plan/expiry metadata only, no credential values. IX auth ownership search -> status `ok`, 69 matches; explicit `/codex/responses` search -> status `ok`, 27 matches; OAuth endpoint ownership search -> status `ok`, 3 matches; scoped fake-token search -> status `ok`, zero matches. Existing API-key parity and OAuth refresh/redaction paths are covered by the same 1,963-test graph. The persistent built owner/kernel pair was explicitly torn down; final built-binary process census was zero. Move 34 is the prior installed proof checkpoint at SHA-256 `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`; the current installed artifact is recorded by the later Move 37/39 closeout. No live provider entitlement or credential was used."
conflict_surface: ""
invariants:
  - "I1: Installed credentials live in `$VANTARI_HOME/auth.json`; workspace-scoped credentials live in `.var/auth.json`; each is the canonical durable auth ledger for its runtime boundary."
  - "I2: `.env` may bootstrap auth but does not replace an active record in the applicable installed or workspace ledger."
  - "I3: Existing API-key records remain readable and continue through the OpenAI-compatible provider path."
  - "I4: OAuth refresh persistence and provider metadata remain covered by fake local fixtures."
  - "I5: Raw secrets are never printed by health, auth status, RPC health, logs, docs, or test fixtures."
  - "I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`."
  - "I7: Tests use fake credentials and local fixtures only; no live provider entitlement is required."
entry_state: "All implementation units from `021a` through `021e` are archived. All exit states from `021b` through `021e` are provably true. System is in a state where full regression can run cleanly."
rollback_surface: "None. This unit introduces no artifact changes. If validation fails, create a new bug-category chain naming the responsible implementation unit and do not archive this verification unit."
dependencies: "021a-codex-subscription-auth, 021b-codex-subscription-auth, 021c-codex-subscription-auth, 021d-codex-subscription-auth, 021e-codex-subscription-auth"
next_todo: NONE
continuation: "On completion: record evidence, set status done, archive this unit, then execute Parent Archival Protocol. Chain is fully terminated when parent is in /todo/changelog/."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021f Verification, Regression, and Closeout

## Execute Now
Run the full regression suite, assert all chain invariants, verify all acceptance criteria, record aggregate evidence, archive this unit, and archive the parent.

## Pre-flight Checklist

- [x] Every execution unit from `021a` through `021e` is in `/todo/changelog/`.
- [x] No unit in `/todo/changelog/` for this chain has a placeholder evidence field.
- [x] No unit in `/todo/pending/` for this chain remains with `status: in-progress` or `status: blocked`.
- [x] All exit state claims from all prior units are verifiable on the current filesystem.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|-------------|-----------|---------------------|----------------|
| I1 | Installed credentials live in `$VANTARI_HOME/auth.json`; workspace-scoped credentials live in `.var/auth.json`; each is the canonical durable auth ledger for its runtime boundary. | `ix.exe search --max-hits 40 "lit:$VANTARI_HOME/auth.json || lit:.var/auth.json" .docs README.md apps/backend/README.md apps/backend/architecture.md` | `ix.result.v1` status `ok`; both ownership forms appear. |
| I2 | `.env` may seed auth but does not override an existing active provider record in the applicable installed or workspace ledger. | `.\scripts\zigw.ps1 build test --summary all` | Auth resolver tests pass. |
| I3 | Existing API-key records remain readable and continue to serve ZAI/OpenAI-compatible providers. | `.\zig-out\bin\vantari.exe health --json` | `ok: true` and a healthy runtime projection appear. |
| I4 | OAuth refresh updates are persisted atomically enough that interrupted refreshes do not corrupt the auth ledger. | `.\scripts\zigw.ps1 build test --summary all` | OAuth refresh persistence tests pass. |
| I5 | Raw secrets are never printed by health, auth status, RPC health, logs, docs, or test fixtures. | `.\zig-out\bin\vantari.exe auth status --json` | Output contains provider/account/plan/expiry metadata and no credential values. |
| I6 | Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`. | `ix.exe search --max-hits 40 "lit:/codex/responses" README.md apps/backend/README.md apps/backend/architecture.md .docs` | `ix.result.v1` status `ok`; explicit route appears. |
| I7 | Tests use fake JWTs, fake refresh responses, and local fixtures only. | `ix.exe search --max-hits 20 "lit:auth.openai.com" apps/backend/src apps/backend/tests` | `ix.result.v1` status `ok`; provider endpoints are source-owned and tests remain local. |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|------|---------------------|--------|
| 021a | Contract locks installed/workspace auth ledgers, API-key parity, OAuth options, and explicit Codex transport. | [x] PASS |
| 021b | API-key records resolve, OAuth records parse, expired OAuth routes to refresh, and sanitized structs omit secrets. | [x] PASS |
| 021c | `auth login`, `auth logout`, and `auth status` exist and fake tests prove secret redaction. | [x] PASS |
| 021d | `openai-codex` OAuth records route to Codex-specific transport while API-key providers keep chat-completions behavior. | [x] PASS |
| 021e | Docs and fixtures describe the final auth contract without exposing real secrets. | [x] PASS |

## Regression Surface

**Files in combined patch surface:**
- `apps/backend/src/core/auth/store.zig` - touched by `021b`.
- `apps/backend/src/core/auth/resolver.zig` - touched by `021b`.
- `apps/backend/src/shared/types.zig` - touched by `021b` and possibly `021d`.
- `apps/backend/src/clients/cli.zig` - touched by `021c`.
- `apps/backend/src/core/auth/openai_codex.zig` - added by `021c`.
- `apps/backend/src/core/providers/openai_compatible.zig` - touched by `021d`.
- `apps/backend/src/core/providers/openai_codex.zig` - added by `021d`.
- `apps/backend/README.md` - touched by `021e`.
- `apps/backend/architecture.md` - touched by `021e`.
- `.docs/research/2026-04-24-auth-persistence-study.md` - touched by `021e` if implementation follow-up is needed.
- `.docs/todo/changelog/_log.md` - touched by `021e`.
- `apps/backend/tests/**` - touched by `021b`, `021c`, `021d`, and `021e`.

## Full Regression Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern |
|------|---------|-------------------|------------------------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\zig-out\bin\vantari.exe health --json` | `0` | `ok: true` |
| 3 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\zig-out\bin\vantari.exe auth status --json` | `0` | `auth_provider` |
| 4 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix.exe search --max-hits 40 "lit:$VANTARI_HOME/auth.json || lit:.var/auth.json" .docs README.md apps/backend/README.md apps/backend/architecture.md` | `0` | `ix.result.v1` status `ok` |
| 5 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix.exe search --max-hits 40 "lit:/codex/responses" README.md apps/backend/README.md apps/backend/architecture.md .docs` | `0` | `ix.result.v1` status `ok` |

**Evidence to capture:** Full stdout from all validation commands. This is the aggregate chain evidence.

## Regression Triage (if failures occur)

1. Identify which test, status command, or search assertion failed.
2. Trace the failure to the responsible unit by patch surface.
3. Determine whether the failure is a regression, incomplete implementation, or documentation drift.
4. For regressions: create a new bug-category chain naming the responsible unit and do not archive this verification unit.
5. For incomplete implementation: block this verification unit with `blocked_reason` naming the specific failing criterion and responsible unit.

## Chain Audit

- [x] Chain manifest in parent is complete: every planned letter has a file in `/todo/changelog/`.
- [x] Parent's Phase Plan table: all letters are complete and the manifest marks every archived unit.
- [x] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [x] All invariants in Invariant Assertion Surface table show PASS.
- [x] All acceptance criteria in Acceptance Criteria Matrix show PASS.

## Next todo
`NONE`

## Completion

- [x] All pre-flight checks passed.
- [x] Full regression suite executed. All commands exit 0. All output patterns matched.
- [x] All invariants asserted: PASS.
- [x] All acceptance criteria resolved: PASS.
- [x] Chain audit complete: all rows verified.
- [x] Evidence captured. The `evidence` field is populated and contains no placeholder.
- [x] Status set to `done`.
- [x] `mv /todo/pending/021f-codex-subscription-auth.md /todo/changelog/021f-codex-subscription-auth.md` - verified.
- [x] Parent Archival Protocol: update parent status to `done`, update chain manifest, `mv /todo/pending/021-codex-subscription-auth.md /todo/changelog/021-codex-subscription-auth.md` - verified.
- [x] Chain is complete. `/todo/pending/` contains zero files for this chain.
