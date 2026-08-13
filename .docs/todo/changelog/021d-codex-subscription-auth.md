---
id: 021d-codex-subscription-auth
parent: 021-codex-subscription-auth
type: execution-unit
protocol_version: "2.0"
category: feature
phase: d
status: done
patch_scope: "Add explicit Codex subscription provider transport and route resolved OAuth credentials through it without changing OpenAI-compatible API-key transport semantics."
blast_radius: high
blast_radius_justification: "Provider transport is the model execution boundary. Failure can break completions, tool-call parsing, or authenticated runtime requests."
idempotency_contract: idempotent
idempotency_notes: "Source and fixture edits can be re-applied deterministically. Network behavior is tested through fake transport hooks only."
acceptance: "A provider record with `provider_id: openai-codex` and `auth_type: oauth` routes to Codex-specific request construction, while existing API-key providers still route to `/v1/chat/completions`; the installed local consumer path is proven with a disposable OAuth fixture."
exit_criterion: "`.\scripts\zigw.ps1 build test --summary all` exits 0 with Codex transport routing tests and existing provider tests passing."
validation: "Set-Location E:\\Workspaces\\01_Projects\\01_Github\\VANTARI-ONE\\apps\\backend; .\\scripts\\zigw.ps1 build test --summary all"
expected_exit_code: 0
expected_output_pattern: "tests passed"
evidence: "Source: `scripts/zigw.ps1 build test --summary all` -> Build Summary: 19/19 steps succeeded; 1963/1963 tests passed; test success; zero leaks. Routing: `ix.exe search --max-hits 20 -n 6 \"lit:/v1/chat/completions\" .` -> matches are confined to the OpenAI-compatible adapter, shared wire documentation/tests, and the Codex explanatory comment; no Codex request builder uses the suffix. ReleaseFast: `zig build -Doptimize=ReleaseFast --summary all` -> 9/9 steps succeeded; installer installed `C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe`; built and installed SHA-256 `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`. Installed disposable OAuth fixture: `run --prompt \"reply with exactly ok\" --json --no-agent-tools` -> exit 0; request `POST /codex/responses`; account/originator/OpenAI-beta/SSE headers present; `stream:true`; `store:false`; response `ok`; no `/v1/chat/completions`; no bearer output; owner/kernel pair explicitly torn down; final installed process census zero. No live provider entitlement or credential was used."
conflict_surface: ""
invariants:
  - "I3: Existing `auth_type: \"api_key\"` records remain readable and continue to serve ZAI/OpenAI-compatible providers."
  - "I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures."
  - "I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`."
  - "I7: Tests use fake JWTs, fake refresh responses, and local fixtures only; no real OpenAI, ZAI, or ChatGPT credentials are used."
entry_state: "The `021c` unit is archived with evidence, and Codex OAuth credentials can be persisted and resolved without provider transport consumption."
rollback_surface: "Before rollback, verify no unrelated user edits exist. Revert `provider.zig`, `config.zig` if changed, remove the Codex transport module, and remove transport tests added by this unit."
dependencies: "021a-codex-subscription-auth, 021b-codex-subscription-auth, 021c-codex-subscription-auth"
next_todo: /todo/pending/021e-codex-subscription-auth.md
continuation: "On completion: record evidence, set status done, move this file to /todo/changelog/021d-codex-subscription-auth.md, continue immediately to next_todo. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 021d Codex Subscription Provider Transport

## Execute Now
Add a Codex-specific provider transport path that consumes resolved OAuth credentials and leaves existing OpenAI-compatible API-key requests untouched.

## Why This Execution Unit Exists

Codex subscription auth does not complete the feature until a model request can use the stored credentials. This slice is separate because Codex backend requests are not the same contract as OpenAI-compatible chat completions. A parallel or hidden fallback would corrupt provider semantics, so the routing boundary must be explicit and test-backed.

## Pre-flight Checklist

- [x] `021a`, `021b`, and `021c` are archived in `/todo/changelog/` with evidence-bearing closure notes.
- [ ] `VAR1 auth login openai-codex` can create a fake OAuth record in a temporary workspace during tests.
- [ ] `conflict_surface` is empty or cross-chain dependency is resolved.
- [ ] Rollback procedure is populated for blast_radius high.
- [ ] If re-executing after partial failure: idempotency_contract is read and direct re-execution is safe.

## Entry State

- `openai_compatible.zig` currently builds `/v1/chat/completions` requests from `config.openai_base_url`, `config.openai_model`, and `config.openai_api_key`.
- The auth resolver can distinguish API-key and OAuth credential kinds.
- Codex login state can exist in temporary auth fixtures without touching live `.var/auth/auth.json`.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/providers/openai_compatible.zig` - add header-capable transport hooks while preserving OpenAI-compatible behavior.
- `apps/backend/src/core/providers/dispatch.zig` - route resolved OAuth records before `wire_api` selection.
- `apps/backend/src/core/config/resolver.zig` - carry provider/auth type metadata only if required by the transport boundary.
- `apps/backend/src/shared/types.zig` - add request/response structs only if Codex transport cannot reuse existing completion types safely.
- `apps/backend/tests/**` - add fake transport tests for OpenAI-compatible and Codex routing.

**Adds:**
- `apps/backend/src/core/providers/openai_codex.zig` - own Codex request headers, endpoint construction, response parsing, and provider-specific error mapping.

**Deletes:**
- None.

**Must not touch (out of scope for this unit):**
- `apps/backend/src/clients/cli.zig` - login/status behavior remains owned by `021c`; only production transport construction gains the shared header hooks.
- `apps/frontend/var1-client/**` - frontend remains a thin bridge client.
- `.var/auth/auth.json` - tests must use temp workspaces and fixtures.

## Detailed Requirements

- R1: Route `provider_id: "openai-codex"` with OAuth credentials to a dedicated Codex provider implementation.
- R2: Preserve the current OpenAI-compatible request path for `auth_type: "api_key"` records.
- R3: Build Codex requests with provider-owned headers and account id metadata from the OAuth record where required.
- R4: Map missing entitlement, expired auth, and bad status errors to explicit operator-safe errors.
- R5: Parse Codex responses into the existing `CompletionResponse` contract only at the transport boundary.
- R6: Do not add a runtime fallback from Codex transport to `/v1/chat/completions`.
- R7: Keep all tests local by injecting fake transport responses.
- R8: Ensure logs and errors never echo bearer tokens.

## Invariants This Unit Must Preserve

- I3: Existing `auth_type: "api_key"` records remain readable and continue to serve ZAI/OpenAI-compatible providers.
- I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures.
- I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`.
- I7: Tests use fake JWTs, fake refresh responses, and local fixtures only; no real OpenAI, ZAI, or ChatGPT credentials are used.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|------|---------|-------------------|------------------------|-----------|
| 1 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE\apps\backend; .\scripts\zigw.ps1 build test --summary all` | `0` | `tests passed` | yes |
| 2 | `Set-Location E:\Workspaces\01_Projects\01_Github\VANTARI-ONE; ix.exe search --max-hits 20 -n 6 "lit:/v1/chat/completions" .` | `0` | `ix.result.v1` status `ok`; no Codex request-builder hit | yes |

**Evidence to capture:** Zig test stdout plus routing search excerpt proving Codex transport is not using the OpenAI-compatible suffix.

## Exit State (Handoff Contract)

- API-key providers still execute through the existing OpenAI-compatible chat-completions path.
- `openai-codex` OAuth providers execute through `openai_codex.zig`.
- Transport tests prove route selection, redacted errors, and Codex response mapping.
- The `021e` unit may document the feature and add operator-facing status fixtures.

## Rollback Procedure

1. Verify the listed files contain no unrelated user edits.
2. Remove `apps/backend/src/core/providers/openai_codex.zig`.
3. Revert provider routing changes in `apps/backend/src/core/providers/openai_compatible.zig`.
4. Revert transport metadata changes in `config.zig` and `types.zig` if this unit added them.
5. Remove fake Codex transport tests added by this unit.
6. Run `.\scripts\zigw.ps1 build test --summary all`.

## Next todo
`/todo/pending/021e-codex-subscription-auth.md`

## Completion

- [x] Pre-flight passed.
- [x] All validation commands executed.
- [x] Post-flight: all Exit State claims are verifiable.
- [x] Evidence captured in the `evidence` field.
- [x] Status set to `done`.
- [x] `mv /todo/pending/021d-codex-subscription-auth.md /todo/changelog/021d-codex-subscription-auth.md` - verified.
- [x] Continue immediately to `next_todo`.
