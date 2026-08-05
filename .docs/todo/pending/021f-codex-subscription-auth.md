---
id: 021f-codex-subscription-auth
parent: 021-codex-subscription-auth
type: verification-closeout
protocol_version: "2.0"
category: feature
phase: f
status: pending
patch_scope: "No artifact change. This unit validates, verifies invariants, and terminates the chain."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only. Re-execution from any point is safe."
acceptance: "All Codex subscription auth units are archived with evidence, full Zig regression passes, API-key auth parity remains intact, Codex auth status is sanitized, and docs describe the final `.var/auth/auth.json` contract."
exit_criterion: "Full regression commands exit 0, all invariant assertions pass, and parent archival protocol can move `021-codex-subscription-auth.md` to `/todo/changelog/`."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all; .\\scripts\\health.ps1; .\\zig-out\\bin\\VAR1.exe auth status --json"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "PLACEHOLDER - replace with captured final validation output. Chain cannot terminate until this is populated."
conflict_surface: ""
invariants: []
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

- [ ] Every execution unit from `021a` through `021e` is in `/todo/changelog/`.
- [ ] No unit in `/todo/changelog/` for this chain has `evidence: PLACEHOLDER`.
- [ ] No unit in `/todo/pending/` for this chain remains with `status: in-progress` or `status: blocked`.
- [ ] All exit state claims from all prior units are verifiable on the current filesystem.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|-------------|-----------|---------------------|----------------|
| I1 | `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata. | `iex search --max-hits 30 ".var/auth/auth.json" apps/backend/README.md apps/backend/architecture.md apps/backend/src` | `.var/auth/auth.json` appears in auth/store/docs surfaces. |
| I2 | `.env` may seed auth but does not override an existing active provider record in `.var/auth/auth.json`. | `.\scripts\zigw.ps1 build test --summary all` | Auth resolver tests pass. |
| I3 | Existing API-key records remain readable and continue to serve ZAI/OpenAI-compatible providers. | `.\scripts\health.ps1` | `status: ready` appears. |
| I4 | OAuth refresh updates are persisted atomically enough that interrupted refreshes do not corrupt the auth ledger. | `.\scripts\zigw.ps1 build test --summary all` | OAuth refresh persistence tests pass. |
| I5 | Raw secrets are never printed by health, auth status, RPC health, logs, docs, or test fixtures. | `.\zig-out\bin\VAR1.exe auth status --json` | Output contains no `api_key`, `access_token`, or `refresh_token` values. |
| I6 | Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`. | `iex search --max-hits 20 "openai_codex_provider" apps/backend/src apps/backend/tests` | Dedicated Codex provider surface appears. |
| I7 | Tests use fake JWTs, fake refresh responses, and local fixtures only. | `iex search --max-hits 20 "auth.openai.com" apps/backend/tests` | Tests do not require real outbound auth calls. |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|------|---------------------|--------|
| 021a | Contract locks `.var/auth/auth.json`, API-key parity, OAuth options, and explicit Codex transport. | [ ] PASS / [ ] FAIL |
| 021b | API-key records resolve, OAuth records parse, expired OAuth routes to refresh, and sanitized structs omit secrets. | [ ] PASS / [ ] FAIL |
| 021c | `auth login`, `auth logout`, and `auth status` exist and fake tests prove secret redaction. | [ ] PASS / [ ] FAIL |
| 021d | `openai-codex` OAuth records route to Codex-specific transport while API-key providers keep chat-completions behavior. | [ ] PASS / [ ] FAIL |
| 021e | Docs and fixtures describe the final auth contract without exposing real secrets. | [ ] PASS / [ ] FAIL |

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
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\health.ps1` | `0` | `status: ready` |
| 3 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\zig-out\bin\VAR1.exe auth status --json` | `0` | `auth_provider` |
| 4 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 30 ".var/auth/auth.json" apps/backend/README.md apps/backend/architecture.md apps/backend/src` | `0` | `.var/auth/auth.json` |
| 5 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 20 "openai_codex_provider" apps/backend/src apps/backend/tests` | `0` | `openai_codex_provider` |

**Evidence to capture:** Full stdout from all validation commands. This is the aggregate chain evidence.

## Regression Triage (if failures occur)

1. Identify which test, status command, or search assertion failed.
2. Trace the failure to the responsible unit by patch surface.
3. Determine whether the failure is a regression, incomplete implementation, or documentation drift.
4. For regressions: create a new bug-category chain naming the responsible unit and do not archive this verification unit.
5. For incomplete implementation: block this verification unit with `blocked_reason` naming the specific failing criterion and responsible unit.

## Chain Audit

- [ ] Chain manifest in parent is complete: every planned letter has a file in `/todo/changelog/`.
- [ ] Parent's Phase Plan table: all letters marked `archived`.
- [ ] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [ ] All invariants in Invariant Assertion Surface table show PASS.
- [ ] All acceptance criteria in Acceptance Criteria Matrix show PASS.

## Next todo
`NONE`

## Completion

- [ ] All pre-flight checks passed.
- [ ] Full regression suite executed. All commands exit 0. All output patterns matched.
- [ ] All invariants asserted: PASS.
- [ ] All acceptance criteria resolved: PASS.
- [ ] Chain audit complete: all rows verified.
- [ ] Evidence captured. `evidence` field populated with full regression stdout. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/021f-codex-subscription-auth.md /todo/changelog/021f-codex-subscription-auth.md` - verified.
- [ ] Parent Archival Protocol: update parent status to `done`, update chain manifest, `mv /todo/pending/021-codex-subscription-auth.md /todo/changelog/021-codex-subscription-auth.md` - verified.
- [ ] Chain is complete. `/todo/pending/` contains zero files for this chain.
