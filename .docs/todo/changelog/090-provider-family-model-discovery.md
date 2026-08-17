## 090 — One-family model discovery + OAuth token refresh

- **Commit**: `a515d7c`
- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `744f1a31906403d7` at `/usr/local/bin/vantari`

### Research (three parallel scouts, all source-cited)

- **ACP**: the agent owns model truth; clients see one flat catalog with
  provider as internal attribute. Config-options (`category: "model"`)
  expose selection post-session. No provider fields in the protocol.
- **models.dev**: MIT registry, `https://models.dev/api.json`, 188
  providers / 6,667 models with `limit.context/output`, cost, tool/reasoning
  capabilities. opencode consumes it as its catalog base; vendored snapshot
  is the same pattern codex uses for its bundled models.json.
- **codex-rs**: real discovery endpoint `GET {base}/codex/models` (Bearer +
  ChatGPT-Account-ID, `{models:[{slug, context_window, visibility,…}]}`,
  visibility=="list" filter). API-key auth has NO codex models surface
  (openai/codex#3716).

### Shipped

1. **`models.discoverModels`** — one entry point, one precedence: live
   endpoint per transport → vendored snapshot → configured model. The RPC
   handler and every caller lost per-provider branching.
2. **`models_snapshot.zig` + `models_snapshot.json`** — 39 KB embedded
   subset (10 providers / 620 models), `snapshotRegistryId` family aliases,
   `enrichFromSnapshot` fills missing context windows on live results.
   Regenerate: `scripts/gen-models-snapshot.py`.
3. **Codex live discovery** (`listCodexModels`) — reverse-engineered
   `/codex/models` with visibility filtering and slug→descriptor mapping.
4. **OAuth refresh at resolve time** — `readActiveProvider` /
   `readProviderById` refresh tokens inside the 60s-expiry window through
   the codex OAuth owner, persist rotated tokens, keep stale records on
   failure so the 401 class surfaces. `postTokenForm` rebuilt on the raw
   TCP+TLS transport (the std.http fetch binding was never exercised in
   production); `RequestHeaders.content_type` added for the token form.

### Live evidence (deployed binary, real ledger)

- Expired codex token refreshed + persisted: expiry
  `1786753928395 → 1787243764071`.
- Family sweep: `openai-codex` 47 models (snapshot tier via openai alias —
  the ChatGPT edge rejects `/codex/*` because the account's subscription
  lapsed 2026-08-03, an account-level blocker independent of the client),
  `opencode`/`opencode-go`/`zai-coding-plan` 91 each with context windows,
  `zai` 9 via live discovery.

### Verification

Debug gate 19/19, 2,241/2,245 (4 platform skips). New tests: discovery
family resolution, codex parser visibility filter, snapshot fallback for
unreachable endpoints, last-resort configured model, snapshot lookup
across providers.
