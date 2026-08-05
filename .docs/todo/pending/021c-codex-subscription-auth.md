---
id: 021c-codex-subscription-auth
parent: 021-codex-subscription-auth
type: execution-unit
protocol_version: "2.0"
category: feature
phase: c
status: pending
patch_scope: "Add Codex subscription login, logout, and status CLI surfaces backed by the auth resolver without touching provider transport."
blast_radius: high
blast_radius_justification: "This introduces operator-facing auth commands and local OAuth persistence; failure could expose secrets or store unusable credentials."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Source edits are idempotent. Manual login execution is non-idempotent against real provider state and must not run in tests; tests must use fake callback/device responses."
acceptance: "`VAR1 auth login openai-codex`, `VAR1 auth logout openai-codex`, and `VAR1 auth status --json` exist, use fake fixtures in tests, and never print raw tokens."
exit_criterion: "`.\scripts\zigw.ps1 build test --summary all` exits 0 and `.\zig-out\bin\VAR1.exe auth --help` lists login, logout, and status."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all; .\\zig-out\\bin\\VAR1.exe auth --help"
expected_exit_code: 0
expected_output_pattern: "login"
evidence: "PLACEHOLDER - replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata."
  - "I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures."
  - "I7: Tests use fake JWTs, fake refresh responses, and local fixtures only; no real OpenAI, ZAI, or ChatGPT credentials are used."
entry_state: "The `021b` unit is archived with evidence, and `auth_resolver.zig` exposes a typed auth resolution and sanitized status boundary."
rollback_surface: "Before rollback, verify no unrelated user edits exist. Revert `apps/backend/src/clients/cli.zig`, remove the Codex OAuth helper module added by this unit, and remove CLI auth tests added by this unit."
dependencies: "021a-codex-subscription-auth, 021b-codex-subscription-auth"
next_todo: /todo/pending/021d-codex-subscription-auth.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/021c-codex-subscription-auth.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021c Codex OAuth Login and CLI Surfaces

## Execute Now
Add operator auth commands and a fake-testable OpenAI Codex OAuth helper that persists subscription credentials through the auth resolver.

## Why This Execution Unit Exists

Login is a separate patch surface from the ledger because it introduces local browser callback/device-code behavior and operator prompts. Keeping it independent lets the auth data model remain testable without network concerns and prevents transport code from depending on partially wired CLI state. This unit creates credentials; it does not consume them for model completions.

## Pre-flight Checklist

- [ ] `021a` and `021b` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] `auth_resolver.zig` exposes the entry-state credential/status functions named by `021b`.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius high.
- [ ] If re-executing after partial failure: verify whether a real `.var/auth/auth.json` provider record was written; if yes, restore it from backup before re-running manual login.

## Entry State

- API-key and OAuth record parsing exists in `auth_store.zig`.
- The resolver can persist sanitized subscription metadata and can omit secrets from status output.
- No `VAR1 auth` command exists in `cli.zig` before this unit.

## Patch Surface

**Modifies:**
- `apps/backend/src/clients/cli.zig` - add `auth` command parsing, help text, login/logout/status handlers, and JSON status output.
- `apps/backend/src/root.zig` or `src/core/index.zig` - export the new auth helper only if required by tests.
- `apps/backend/tests/**` - add CLI auth command tests with fake OAuth responses.

**Adds:**
- `apps/backend/src/core/auth/openai_codex.zig` - implement browser PKCE, device-code contract parsing, token exchange abstraction, and fakeable HTTP hooks.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/providers/openai_compatible.zig` - Codex request execution is `021d`.
- `apps/frontend/var1-client/**` - browser client remains non-authoritative for secrets.
- `.var/auth/auth.json` - tests must operate against temporary workspace roots.

## Detailed Requirements

- R1: Add `VAR1 auth status [--json]` that prints active provider id, model, base URL, auth type, plan label, subscription status, and last verification timestamp with no raw secrets.
- R2: Add `VAR1 auth login openai-codex` using browser PKCE callback on `127.0.0.1:1455/auth/callback` and a manual redirect paste fallback for headless/Windows failures.
- R3: Add a device-code helper contract matching official Codex endpoints, but keep it fakeable and optional if browser PKCE is the first shipped login path.
- R4: Add `VAR1 auth logout openai-codex` that removes only that provider record or clears it as active if it was active; do not delete unrelated providers.
- R5: Use OpenAI Codex OAuth constants behind a named provider descriptor; do not inline magic strings throughout CLI code.
- R6: Store successful login output through `auth_store`/`auth_resolver`, not direct file writes in `cli.zig`.
- R7: Ensure CLI success messages say where credentials were saved but never print tokens.
- R8: Tests must use fake callback/device responses and fake JWT payloads with plan/account claims.

## Invariants This Unit Must Preserve

- I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata.
- I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures.
- I7: Tests use fake JWTs, fake refresh responses, and local fixtures only; no real OpenAI, ZAI, or ChatGPT credentials are used.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\zig-out\bin\VAR1.exe auth --help` | `0` | `login` | yes |
| 3 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 20 "refresh_token" apps/backend/src apps/backend/tests` | `0` | `refresh_token` | yes |

**Evidence to capture:** Zig test stdout, `auth --help` output, and source search excerpt showing token fields are confined to auth surfaces.

## Exit State (Handoff Contract)

- `VAR1 auth status`, `VAR1 auth login openai-codex`, and `VAR1 auth logout openai-codex` exist and are covered by tests.
- Successful fake login writes an OAuth provider record through the canonical auth store.
- Secret redaction is proven for CLI status and help output.
- The `021d` unit may consume resolved Codex OAuth credentials for transport without adding login behavior.

## Rollback Procedure

1. Verify the listed files contain no unrelated user edits.
2. Remove `apps/backend/src/core/auth/openai_codex.zig`.
3. Revert the `auth` command branches and help text from `apps/backend/src/clients/cli.zig`.
4. Revert any export additions in `root.zig` or `core/index.zig`.
5. Remove CLI auth tests added by this unit.
6. Run `.\scripts\zigw.ps1 build test --summary all`.

## Next todo
`/todo/pending/021d-codex-subscription-auth.md`

## Completion

- [ ] Pre-flight passed.
- [ ] All validation commands executed.
- [ ] Post-flight: all Exit State claims are verifiable.
- [ ] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/021c-codex-subscription-auth.md /todo/changelog/021c-codex-subscription-auth.md` - verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch.
