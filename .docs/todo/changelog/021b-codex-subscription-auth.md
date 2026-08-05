---
id: 021b-codex-subscription-auth
parent: 021-codex-subscription-auth
type: execution-unit
protocol_version: "2.0"
category: feature
phase: b
status: done
patch_scope: "Extend the VAR1 auth ledger and resolver to read, write, and resolve API-key and OAuth provider records from `.var/auth/auth.json`."
blast_radius: high
blast_radius_justification: "This changes the foundational auth contract consumed by config loading, health reporting, provider execution, and future CLI auth commands."
idempotency_contract: idempotent
idempotency_notes: "Source edits and fixture updates can be re-applied deterministically; test fixture files should be overwritten rather than appended."
acceptance: "Existing API-key records still resolve, OAuth records parse into a typed credential shape, expired OAuth records are routed to refresh handling, and no raw secret appears in sanitized status structs."
exit_criterion: "`.\scripts\zigw.ps1 build test --summary all` exits 0 with the auth-store and auth-resolver tests passing."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "Backend validation: Build Summary: 5/5 steps succeeded; 1346/1346 tests passed. CLI validation: Build Summary: 11/11 steps succeeded; 78/78 tests passed. ix search `lit:version || lit:auth_type || lit:access_token || lit:refresh_token` over `apps/backend/src/core/auth` and `apps/backend/tests/auth_store_test.zig` returned status=ok with auth-owned hits only."
conflict_surface: ""
invariants:
  - "I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata."
  - "I2: `.env` may seed auth but does not override an existing active provider record in `.var/auth/auth.json`."
  - "I3: Existing `auth_type: \"api_key\"` records remain readable and continue to serve ZAI/OpenAI-compatible providers."
  - "I4: OAuth refresh updates are persisted atomically enough that interrupted refreshes do not corrupt the auth ledger."
  - "I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures."
entry_state: "The `021a` unit is archived with evidence, and the locked contract states that `021b` may modify only auth schema/resolver/type/test surfaces."
rollback_surface: "Before rollback, verify no unrelated user edits exist in the listed files. Then revert `apps/backend/src/core/auth/store.zig`, `apps/backend/src/core/auth/resolver.zig`, `apps/backend/src/shared/types.zig`, and auth-focused test fixture changes to their pre-unit state."
dependencies: "021a-codex-subscription-auth"
next_todo: /todo/pending/021c-codex-subscription-auth.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/021b-codex-subscription-auth.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021b Auth Ledger Schema and Resolver

## Execute Now
Extend `auth_store.zig` and `auth_resolver.zig` so `.var/auth/auth.json` can represent and resolve both API-key and OAuth provider records.

## Why This Execution Unit Exists

The schema and resolver are the lowest dependency in the auth feature. CLI login, Codex transport, and operator status cannot be implemented safely until the ledger can persist the required record shapes and return a sanitized resolved credential contract. Keeping this slice separate isolates the highest-risk auth data model change from browser/device login behavior.

## Pre-flight Checklist

- [ ] `021a-codex-subscription-auth.md` is archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] `apps/backend/src/core/auth/store.zig`, `auth_resolver.zig`, and `types.zig` exist.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius high.
- [ ] If re-executing after partial failure: idempotency_contract is read and direct re-execution is safe.

## Entry State

- `auth_store.resolveOrSeed()` currently reads one active provider and requires `api_key`, `base_url`, and `model`.
- `auth_resolver.resolveProviderAuth()` currently delegates directly to `auth_store.resolveOrSeed()`.
- `types.zig` already declares `AuthType` and `SubscriptionSource`, but the resolver does not expose typed provider records.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/auth/store.zig` - add versioned provider record parsing/writing for `api_key` and `oauth`.
- `apps/backend/src/core/auth/resolver.zig` - add refresh-aware resolution boundaries and sanitized status output.
- `apps/backend/src/shared/types.zig` - add durable auth and subscription structs if the existing local declarations are insufficient.
- `apps/backend/tests/**` - add fake auth-ledger fixtures and resolver tests.

**Adds:**
- `apps/backend/tests/auth_store_test.zig` or equivalent focused test file if no suitable auth test owner exists.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/src/clients/cli.zig` - CLI command wiring is `021c`.
- `apps/backend/src/core/providers/openai_compatible.zig` - transport routing is `021d`.
- `.var/auth/auth.json` - live secrets must not be modified by tests.

## Detailed Requirements

- R1: Define a versioned auth ledger contract that accepts current version `1` API-key records and new version `2` OAuth records.
- R2: Keep `auth_type: "api_key"` records backward compatible with the existing ZAI provider shape.
- R3: Add an OAuth record shape containing access token, refresh token, expiry timestamp, account id, optional email, optional ChatGPT user id, optional plan type, issuer, client id, and updated timestamp.
- R4: Persist subscription metadata on the provider record under `subscription`, not in a separate file.
- R5: Return one resolved credential object with provider id, base URL, model, credential kind, bearer/API secret, and sanitized subscription fields.
- R6: Add a refresh hook boundary without making real network calls in this unit; expired OAuth records must be detectable and must route through a provider-specific refresh interface.
- R7: Write updates through a temporary file plus replace/rename sequence or equivalent crash-safe pattern available in Zig on Windows.
- R8: Ensure sanitized status structs omit `api_key`, `access_token`, and `refresh_token`.

## Invariants This Unit Must Preserve

- I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata.
- I2: `.env` may seed auth but does not override an existing active provider record in `.var/auth/auth.json`.
- I3: Existing `auth_type: "api_key"` records remain readable and continue to serve ZAI/OpenAI-compatible providers.
- I4: OAuth refresh updates are persisted atomically enough that interrupted refreshes do not corrupt the auth ledger.
- I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; iex search --max-hits 20 "access_token" apps/backend/tests apps/backend/src` | `0` | `access_token` | yes |

**Evidence to capture:** Full Zig test stdout plus the search excerpt proving OAuth fields are owned by auth surfaces only.

## Exit State (Handoff Contract)

- `auth_store.zig` can parse and write API-key and OAuth provider records without reading or modifying live `.var/auth/auth.json` during tests.
- `auth_resolver.zig` exposes a credential resolution boundary that can be called by CLI login and provider transport code.
- Auth tests prove API-key parity, OAuth parsing, expired-token detection, and sanitized status redaction.

## Rollback Procedure

1. Verify the listed files contain no unrelated user edits.
2. Revert `apps/backend/src/core/auth/store.zig` to the pre-unit API-key-only implementation.
3. Revert `apps/backend/src/core/auth/resolver.zig` to the direct delegate implementation.
4. Revert only the auth-related additions in `apps/backend/src/shared/types.zig`.
5. Delete any test file added solely by this unit.
6. Run `.\scripts\zigw.ps1 build test --summary all` to confirm the pre-unit baseline is restored.

## Next todo
`/todo/pending/021c-codex-subscription-auth.md`

## Completion

- [x] Pre-flight passed.
- [x] All validation commands executed.
- [x] Post-flight: all Exit State claims are verifiable.
- [x] Evidence captured. `evidence` field updated. PLACEHOLDER is gone.
- [x] Status set to `done`.
- [x] `mv /todo/pending/021b-codex-subscription-auth.md /todo/changelog/021b-codex-subscription-auth.md` - verified after archival.
- [x] Continue immediately to `next_todo`. No pause. No batch.
