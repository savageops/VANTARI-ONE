---
type: changelog
id: 037-provider-selection-prism
status: complete
updated: 2026-08-13
owner: apps/backend/src/core/providers/profile.zig
---

# Provider-scoped login and model selection

## Outcome

Promoted the Prism harvest into the canonical provider profile and auth path.
The harness now persists provider-scoped API-key records, selects an active
provider, enumerates secret-free provider/model metadata, and accepts a
per-turn provider/model override through `session/send` and `run`.

Supported paths:

- OpenAI-compatible Chat Completions, including OpenRouter.
- OpenAI Responses for the existing `openai-codex` subscription OAuth path.
- Direct Anthropic Messages with `x-api-key` and `anthropic-version` headers.
- Explicit custom OpenAI-compatible endpoints with bearer, API-key, or no-auth
  header selection.

## Evidence

- `apps/backend/scripts/zigw.ps1 build test --summary all`: `19/19`,
  `2,008/2,008` passed.
- ReleaseFast and installed binary SHA-256:
  `0C15D5DAEECF8879ECDFDA3E47BB5EF515550E0158284C0B7CE2FD76426833E5`.
- Disposable installed proof logged Anthropic, OpenRouter, and custom records;
  `auth use anthropic`, `providers/list`, and `providers --json` returned the
  expected metadata with no fixture secret leakage.
- Final proof-owned installed process census: zero.

## Boundary

The backend/CLI/RPC selection contract is complete. The active TUI owner still
needs to bind a picker to `providers/list` and `session/send.provider_id`.
Arbitrary custom headers and non-Codex OAuth extensions remain explicit future
provider-auth work.
