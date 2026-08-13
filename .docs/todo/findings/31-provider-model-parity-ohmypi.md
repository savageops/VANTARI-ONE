---
type: finding
id: harness-finding-31
status: closed
priority: P1
owner: apps/backend/src/core/providers/profile.zig
source: ../../refs/can1357__oh-my-pi/docs/providers.md
---

# Provider and model parity against oh-my-pi

## Finding

VANTARI already has the stronger kernel boundary for provider turns: one auth
ledger, explicit wire adapters, provider-scoped OAuth/API-key records, role
routing, and separate model/provider fields on the RPC contract. The missing
piece was the model identity that operators use to choose a backend. A model
string such as `openrouter/anthropic/claude-sonnet` was previously treated as a
literal model id instead of selecting `openrouter` while preserving the nested
gateway id `anthropic/claude-sonnet`.

The smallest durable improvement is a shared, allocation-free selector in the
provider profile owner. CLI `--model provider/model` and role route `model`
values now resolve through the same rule. The protocol continues to carry
separate `provider_id` and `model_override` fields, so the kernel does not gain
another identity grammar or a second registry.

## Harvest receipt

The comparison covered these twelve reference surfaces:

1. oh-my-pi provider catalog and credential-aware availability;
2. oh-my-pi model registry and layered catalog;
3. oh-my-pi runtime model discovery and SQLite cache;
4. oh-my-pi model resolver and provider-prefix precedence;
5. oh-my-pi role models, tags, provider order, and cycle order;
6. oh-my-pi disabled-provider gating;
7. oh-my-pi capability and endpoint metadata;
8. oh-my-pi session model persistence and auth-aware switching;
9. pi-mono provider-scoped login and `provider/model` selection;
10. OpenAI Codex app-server per-turn model selection and auth split;
11. nullclaw longest-prefix model references and provider aliases;
12. Flue, KrillClaw, Scion, Eve, and pi custom endpoint/auth patterns.

The local oh-my-pi and pi-mono trees are source references without installed
dependencies in this checkout. Their unit-test files were inspected as test
contracts; they were not executed here. VANTARI tests and installed proof are
the executable acceptance boundary.

## Pattern decisions

| Harvested pattern | VANTARI decision |
| --- | --- |
| Canonical `provider/model` identity | Adopted. Known prefixes select the provider. The longest known prefix wins, and the remaining model id may contain `/`. |
| Explicit provider plus namespaced model | Adopted. `--provider openrouter --model anthropic/claude-sonnet` preserves the gateway namespace; only a matching `anthropic/` prefix is stripped for Anthropic. |
| Provider-scoped login and auth precedence | Already canonical in `core/auth/store.zig`; retain one ledger and one `auth login` owner. |
| Role-scoped model routing | Already canonical in `core/providers/routes.zig`; the role model field now accepts the same selector identity. |
| Bundled/custom/discovered model catalog | Deferred. VANTARI has live `/v1/models` discovery but no durable cache or custom catalog owner. Add one only with a named consumer and stale/authoritative evidence. |
| Disabled-provider availability | Deferred as an explicit allow/deny policy. Do not infer it from missing credentials; current auth failure is fail-closed. |
| Capability-rich model metadata | Deferred. `core/providers/capability.zig` is currently not on the runtime path; promoting it requires adapter-backed evidence, not a speculative registry. |
| Provider/model cycle order | Deferred to the client/protocol owner. The next slice should add one explicit cycle order over the resolved provider/model list, not a TUI-only list. |
| Extension OAuth providers | Deferred. Current `openai-codex` PKCE is a proven special flow; a generic OAuth extension point needs a security and persistence contract first. |
| Automatic fallback chains | Rejected for now. Hidden fallback can change model identity, billing, and tool behavior. If added later, it must be an explicit route policy with terminal evidence. |

## Implemented mechanism

- `profile.zig` owns `ModelReference`, built-in provider prefix matching,
  canonical built-in casing, and matching-prefix stripping.
- `cli.zig` resolves `--model provider/model` before the RPC boundary while
  preserving existing separate wire fields.
- `routes.zig` resolves the same identity for role routes and retains nested
  gateway model ids.
- Tests cover nested OpenRouter ids, case normalization, explicit-provider
  preservation, and matching-prefix stripping.

This is the compression win from the harvest: one provider identity primitive
serves CLI and role routing without importing oh-my-pi's extension forest,
SQLite registry, provider descriptor generator, or fallback machinery.

## Remaining parity backlog

1. Add a cached model catalog only when `models` has a real latency/freshness
   consumer. Store provider id, model id, source, fetched time, and stale state;
   never make stale discovery silently authoritative.
2. Add provider disable/allow policy to the existing config owner and expose
   the effective availability snapshot through `providers --json`.
3. Promote capability metadata only from concrete adapter behavior: streaming,
   tools, context limits, and request compatibility must each have a probe or
   static contract.
4. Add an explicit model-cycle command/protocol request that cycles a durable
   ordered list and emits the chosen provider/model in the next turn evidence.

## Acceptance boundary

The selector closed with the canonical Debug lane at `19/19` build steps and
`2,018/2,018` tests, post-change duplicate audit at `59` mixed segments with
zero candidate pairs and zero exact duplicates, and ReleaseFast/install at
source/installed SHA-256
`B0C5C681BF56C5C015F1FEC855C04B73FA8C33BE8D3B1D972A5A75B0A20DB897`. The
installed selector proof passed `run --help` checks for both flags and a
disposable no-credential `anthropic/claude-sonnet` run failed closed at the
provider/auth boundary. The proof-owned installed process census was zero.
The concurrent `ask_user` lane was green in the same full test run.

## Sources

- [oh-my-pi providers](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md)
- [oh-my-pi models](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md)
- [oh-my-pi settings](https://github.com/can1357/oh-my-pi/blob/main/docs/settings.md)
- [pi-mono models](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/models.md)
- [OpenAI Codex app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- `.refs/can1357__oh-my-pi/packages/coding-agent/src/config/model-registry.ts`
- `.refs/can1357__oh-my-pi/packages/coding-agent/src/config/model-resolver.ts`
- `.refs/can1357__oh-my-pi/packages/coding-agent/src/config/role-models.ts`
- `.refs/nullclaw-main/src/model_refs.zig`
- `.refs/withastro__flue/packages/sdk/src/roles.ts`
