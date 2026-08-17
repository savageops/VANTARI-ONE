## 094 — Real OpenCode Zen gateways + honest client identity

- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `314ad611` at `/usr/local/bin/vantari`

### Root cause of the "opencode never works" reports

Two stacked defects, found by comparing against omp's working registry:

1. **Wrong gateway host.** The opencode import and the provider-profile
   fallback hardcoded `https://api.opencode.ai/v1` — a host that answers
   `200 "Not Found"` to every path. The real gateways (from omp's registry)
   are `https://opencode.ai/zen/v1` (opencode / opencode-zen /
   zai-coding-plan) and `https://opencode.ai/zen/go/v1` (opencode-go). The
   import also defaulted every record to model `opencode-go` — a provider
   id, not a model.
2. **Missing client identity.** The provider HTTP writers sent no
   `User-Agent`; Cloudflare's edge bans that signature (`403 error code:
   1010`) on the Zen host. omp/curl pass because they identify themselves.

### Shipped

- `auth/import.zig::importOpenCode`: go-tier vs zen-tier base URL by provider
  id, with real tier defaults (`glm-5.2` on go, `claude-sonnet-5` on zen);
  import test asserts the gateway and model.
- `providers/profile.zig::defaultBaseUrl`: same mapping for the fallback.
- `providers/openai_compatible.zig`: both request-head writers
  (`writeRequestHead`, `writeGetHead`) now send `user-agent: vantari/0.1` on
  every provider request and model discovery call.
- Live ledger repaired: opencode/opencode-go/zai-coding-plan records moved to
  their real gateways with tier-real default models.

### Proof

- Gate 19/19, 2,285/2,289, 0 failed, 0 leaked.
- Live on installed `314ad611`: `models/list-all` returns the REAL Zen
  catalogs through the kernel (opencode: claude-fable-5/opus/sonnet…;
  opencode-go: minimax-m3/kimi-k3/glm…; all five providers status ok — live
  lists, not snapshot ids).
- A real `session/send` against opencode-go reaches the origin and surfaces
  the API's own answer: `BadStatus status=429 … GoUsageLimitError: Monthly
  usage limit reached. Resets in 19 days` — the pipeline is correct; the go
  plan is exhausted until reset (or balance usage is enabled per the error's
  link). Active provider restored to `zai/glm-4.5` afterward.
