---
id: 021-codex-subscription-auth
type: parent
protocol_version: "2.0"
spec_status: approved
category: feature
status: pending
epic_boundary: "Add Codex subscription authentication to VAR1 by extending the canonical `.var/auth/auth.json` ledger, resolver, login flow, and provider transport without introducing a second auth store."
subtodo_start: /todo/pending/021a-codex-subscription-auth.md
subtodo_final: /todo/pending/021f-codex-subscription-auth.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive. Never pause between units."
---
# 021 Codex Subscription Auth

## Objective

Persist ChatGPT Plus/Pro Codex subscription auth beside existing API-key auth in the canonical `.var/auth/auth.json` ledger. The deliverable adds one resolver-owned path that can read API-key records, read OAuth records, refresh expired OAuth credentials, expose sanitized plan status, and route Codex subscription requests through the correct provider transport.

## Rationale

The current VAR1 runtime already persists provider API-key state under `.var/auth/auth.json`, but the active auth contract is still API-key shaped at the config and provider boundary. Pi's coding-agent reference proves the useful ownership split: caller-owned `auth.json`, provider-owned refresh, and a single resolver that returns the credential used by transport. Official Codex adds the missing browser/device-code subscription path and shows that local persistence can be file-backed or keyring-backed; VAR1 should implement the file-backed `.var` contract first.

## Scope

**In scope:**
- Extend `.var/auth/auth.json` to version `2` with `api_key` and `oauth` provider records.
- Preserve existing ZAI/API-key behavior and the current `.env` bootstrap path.
- Add OpenAI Codex subscription OAuth metadata, refresh handling, and sanitized subscription-plan fields.
- Add CLI/operator commands for login, logout, and auth status without printing raw secrets.
- Add a Codex subscription provider transport boundary instead of bending the OpenAI-compatible chat-completions path.
- Add deterministic tests with fake tokens and fake HTTP responses; no real provider calls in tests.
- Update operator docs and todo changelog once the implementation chain executes.

**Out of scope:**
- Persisting secrets in Windows Credential Manager or another OS keyring during the first implementation pass.
- Browser-local storage of provider secrets.
- Replacing existing ZAI/API-key provider behavior.
- Implementing general OAuth for every provider.
- Shipping a fallback that silently treats missing subscription auth as an API key.

## Source Language Anchors

- "`.var/auth/auth.json is perfect.`"
- "review the pi coding agent and identify the codex subscription auth"
- "see what it will take for us to implement this auth method"
- "ultimately saves to device"
- "VANTARI should persist provider auth in one canonical `.var/auth/auth.json` ledger"
- "credential storage is caller-owned; token refresh is provider-owned; API-key resolution is one canonical function"

## Constraints

| Dimension | Constraint |
|-----------|-----------|
| Category boundary | Only `feature` operations. Refactors are allowed only where they directly enable Codex subscription auth. |
| Blast radius ceiling | high - auth persistence, CLI, provider transport, and runtime config boundaries are cross-cutting. |
| Structural boundary | `.var/auth/auth.json` remains the only durable runtime auth ledger. |
| Dependency boundary | Existing API-key providers must continue to resolve through the same public runtime config fields until downstream transport contracts are intentionally renamed. |
| Rollback surface | Revert auth schema/resolver, CLI auth commands, Codex provider transport, tests, and docs as one feature chain if terminal verification fails. |
| Parallelism | No implementation units run in parallel. The resolver shape gates CLI login, and the transport shape gates regression verification. |

## Invariants

- I1: `.var/auth/auth.json` is the canonical durable auth ledger for runtime provider credentials and subscription metadata.
- I2: `.env` may seed auth but does not override an existing active provider record in `.var/auth/auth.json`.
- I3: Existing `auth_type: "api_key"` records remain readable and continue to serve ZAI/OpenAI-compatible providers.
- I4: OAuth refresh updates are persisted atomically enough that interrupted refreshes do not corrupt the auth ledger.
- I5: Raw secrets are never printed by `health`, `auth status`, RPC health, logs, docs, or test fixtures.
- I6: Codex subscription transport is explicit and does not masquerade as standard `/v1/chat/completions`.
- I7: Tests use fake JWTs, fake refresh responses, and local fixtures only; no real OpenAI, ZAI, or ChatGPT credentials are used.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/pending/021-codex-subscription-auth.md` | parent | Chain root | pending |
| `/todo/pending/021a-codex-subscription-auth.md` | a | Baseline / contract lock | pending |
| `/todo/pending/021b-codex-subscription-auth.md` | b | Auth ledger schema and resolver | pending |
| `/todo/pending/021c-codex-subscription-auth.md` | c | Codex OAuth login and CLI surfaces | pending |
| `/todo/pending/021d-codex-subscription-auth.md` | d | Codex subscription provider transport | pending |
| `/todo/pending/021e-codex-subscription-auth.md` | e | Docs, fixtures, and operator status hardening | pending |
| `/todo/pending/021f-codex-subscription-auth.md` | f | Verification / closeout | pending |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|--------|------|--------------|-----------|---------------|
| `a` | Baseline / contract lock | Interpretation freeze, source evidence capture, invariant declaration - no artifact change | - | No |
| `b` | Implementation unit 1 | `apps/backend/src/core/auth/store.zig`, `apps/backend/src/core/auth/resolver.zig`, `apps/backend/src/shared/types.zig`, auth tests | `a` | No |
| `c` | Implementation unit 2 | `apps/backend/src/clients/cli.zig`, new Codex OAuth helper module, CLI tests | `b` | No |
| `d` | Implementation unit 3 | `apps/backend/src/core/providers/openai_compatible.zig`, new Codex transport module, config bridge tests | `c` | No |
| `e` | Implementation unit 4 | README, architecture docs, research link, sanitized status fixtures, `.docs/todo/changelog/_log.md` | `d` | No |
| `f` | Verification / regression / closeout | Full deliverable validation, invariant assertion, parent archival | all prior | No |

## Validation Expectations

- Signal 1: `.\scripts\zigw.ps1 build test --summary all` exits `0` and reports all tests passed.
- Signal 2: `.\zig-out\bin\VAR1.exe auth status --json` prints provider/model/plan metadata without access tokens, refresh tokens, or API keys.
- Signal 3: Existing ZAI/API-key auth still resolves from `.var/auth/auth.json` and `.\scripts\health.ps1` reports `status: ready`.
- Signal 4: Codex OAuth tests prove login persistence, expired-token refresh, device-code parsing, and logout using only fake local fixtures.
- Evidence format expected: exact command, exit code, and stdout excerpt for each validation command.

## Next todo
`/todo/pending/021a-codex-subscription-auth.md`
