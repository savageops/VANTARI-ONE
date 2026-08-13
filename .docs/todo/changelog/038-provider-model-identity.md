---
id: 038
title: "Provider-prefixed model identity"
category: feature
status: done
priority: high
created: 2026-08-13
---

# Provider-prefixed model identity

## Change

Harvested the provider/model selection invariant from oh-my-pi, pi-mono, Codex,
and nullclaw into VANTARI's existing provider profile owner. CLI `--model` and
role route `model` values accept `provider/model`. Explicit provider selection
continues to win, and gateway model ids such as
`openrouter/anthropic/claude-sonnet` retain their nested model namespace.

## Owner shape

- `apps/backend/src/core/providers/profile.zig` owns prefix parsing and
  canonical built-in provider identity.
- `apps/backend/src/clients/cli.zig` resolves the user-facing selector before
  the existing RPC fields.
- `apps/backend/src/core/providers/routes.zig` applies the same selector to
  role routes.

No model registry, hidden fallback chain, second auth ledger, or client-owned
provider state was introduced.

## Proof boundary

Debug `19/19` and `2,018/2,018` tests passed. The post-change duplicate audit
reported `59` mixed segments, zero candidate pairs, and zero exact duplicates.
ReleaseFast/install passed through the canonical Windows installer; source and
installed SHA-256 match
`B0C5C681BF56C5C015F1FEC855C04B73FA8C33BE8D3B1D972A5A75B0A20DB897`.
`apps/backend/scripts/verify_installed_provider_model_selector.ps1` verified
installed help, fail-closed provider/model selection without credentials, and
zero proof-owned installed processes.
