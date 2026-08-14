---
type: changelog
id: changelog/050-ttsr-abort-move60
status: source-complete
date: 2026-08-14
owner: apps/backend/src/core/executor/loop.zig; apps/backend/src/core/providers/openai_compatible.zig
---

# TTSR stream abort

## Shipped in source

- Provider streaming exposes one abort callback and checks it before and after
  SSE/delta processing, so a matched rule stops the read before normal terminal
  completion.
- Anthropic, Responses, OpenAI-compatible, and Codex adapters forward the same
  hook; no provider-specific cancellation owner was added.
- The executor persists the correction message and `rule_injected` evidence,
  catches the typed abort, and retries through the existing turn loop. A
  post-completion guard covers adapters that fail to stop at the callback.

## Evidence and boundary

- Full Debug: `19/19` steps, `2,151/2,151` tests passed.
- Source ReleaseFast: `9/9` steps; SHA-256
  `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
- Installed promotion and live provider TTSR proof remain deferred by the
  explicit operator boundary. Research:
  `.docs/research/2026-08-14-ttsr-abort-move60.md`.
