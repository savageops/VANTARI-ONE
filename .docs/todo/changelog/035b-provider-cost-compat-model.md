---
id: 035b
title: "Compiled pricing engine — pricing.zig table + calculateCost"
parent: 035
status: done
priority: high
blast_radius: low
category: feature
dependencies: [035a]
next_todo: /todo/pending/035c-provider-cost-compat-model.md
source_message_anchor: cost-model
source_message_excerpt: "#8 Cost model	⚠️ Gap — VANTARI doesn't track per-model cost."
source_message_proof_obligation: Implements the per-model cost derivation (prime `models.ts:51-62` formula: $/1M × tokens) against the harvested price table, with capability truth for unknown models.
idempotency_contract: idempotent — pure functions + const table; re-execution re-applies the same file content.
---

## Execute Now

Add `core/providers/pricing.zig` with a compiled model price table (harvested from prime-agent `models.generated.ts`) and `calculateCost(model_id, usage) ?Cost` implementing prime's formula, exported via `core/index.zig`.

## Better-than-before

Cost becomes a derivable, operator-inspectable fact instead of an absence. The table carries provenance comments so prices are verifiable against the harvest. Structural delta: one pure module owning the price truth; the event spine gains a priced quantity in 035d without duplicating math.

## Entry State

- `types.Usage` exists (035a): `{prompt_tokens, completion_tokens, cached_tokens, total_tokens}`
- `core/index.zig` exports provider modules (pattern: `provider_runtime`, `agent_routes` etc.)

## Patch Surface

**Adds:**
- `src/core/providers/pricing.zig` — `ModelPrice`, `Cost`, `lookupModelPrice`, `calculateCost` + tests
- Export in `src/core/index.zig` (`pub const provider_pricing = @import("providers/pricing.zig");`)

**Must not touch:**
- Provider adapters, loop, events (035d consumes this)

## Detailed Requirements

1. **`ModelPrice`** — dollars per 1,000,000 tokens:
   ```zig
   pub const ModelPrice = struct {
       input_usd: f64,        // prompt + cache_creation tokens
       output_usd: f64,       // completion tokens
       cache_read_usd: f64,   // cached prompt tokens
   };
   ```

2. **Compiled table** — const slice of `{prefix, price}` pairs, ordered longest-prefix-first. Entries harvested from prime `models.generated.ts` (provenance in comments):
   - `deepseek-v4-flash` 0.14 / 0.28 / 0.0028 (models.generated.ts:4040-4058)
   - `deepseek-v4-pro` 0.435 / 0.87 / 0.003625 (:4059-4077)
   - `deepseek-chat` 0.27 / 1.10 / 0.014, `deepseek-reasoner` 0.55 / 2.19 / 0.014 (published DeepSeek API rates)
   - `glm-5.2` 0 / 0 / 0 — z.ai tier listed free in prime's table (:20364-20381); also covers `glm-5.2-highspeed`, `glm-5-turbo`, `glm-4.7` (same zai 0/0 block)
   - `gpt-4.1` 2.0 / 8.0 / 0.5 (gpt-4.1 family :7627-7653; mini 0.4/1.6/0.1)
   - `claude-` handled by exact entries: `claude-sonnet-4-` 3 / 15 / 0.3, `claude-opus-4-` 15 / 75 / 1.5, `claude-haiku-4-` 0.8 / 4 / 0.08, `claude-3-5-sonnet` 3 / 15 / 0.3 (Anthropic published rates)
   - `o3-mini` 1.1 / 4.4 / 0.55, `o4-mini` 1.1 / 4.4 / 0.55 (OpenAI published rates)
   - Unknown models → `null` (token accounting still works; cost is never fabricated)

3. **`lookupModelPrice(model_id) ?ModelPrice`** — longest-prefix match over the table (exact match implied by full-prefix entries); case-sensitive; unknown → null.

4. **`Cost`** — derived, priced quantities:
   ```zig
   pub const Cost = struct {
       input_usd: f64,
       output_usd: f64,
       cached_usd: f64,
       total_usd: f64,
   };
   ```

5. **`calculateCost(model_id, usage) ?Cost`** — prime formula verbatim (`models.ts:56-60`): `(price / 1_000_000) * tokens` per bucket; `total = input + output + cached`. Null when `lookupModelPrice` is null.

## Rollback Procedure

Delete `pricing.zig`, revert `core/index.zig` export. No other code references it until 035d.

## Exit State / Handoff Contract

- `pricing.zig` with `ModelPrice`, `Cost`, `lookupModelPrice`, `calculateCost` + exported via index
- 035d imports `provider_pricing` to price `CompletionResponse.usage`

## Validation

```bash
cd apps/backend && zig build test
```

**New tests in `pricing.zig` (≥10 blocks):**
1. `test "exact model id match"` — deepseek-v4-flash returns harvested price
2. `test "longest prefix wins"` — `glm-5.2-highspeed` resolves via `glm-5.2` entry; `deepseek-v4-flash-extra` would match deepseek-v4-flash over deepseek-v4-pro
3. `test "unknown model returns null"` — "custom-local-model" → null
4. `test "calculateCost applies $/1M formula"` — deepseek-v4-flash: 1,000,000 prompt + 500,000 completion + 100,000 cached → 0.14 + 0.14 + 0.00028 = 0.28028 total
5. `test "calculateCost zero usage yields zero cost"`
6. `test "calculateCost unknown model returns null"`
7. `test "glm-5.2 zero price yields zero cost with tokens tracked"` — cost 0 but usage non-zero (tokens are the evidence on free tier)
8. `test "small token counts price correctly"` — 1,234 prompt / 5,678 completion on gpt-4.1 → 0.002468 + 0.045424
9. `test "table integrity"` — every entry has non-negative prices; prefixes are sorted longest-first (const-comptime check)
10. `test "cache_read buckets priced at cache rate"` — cached tokens cheaper than prompt on deepseek
## Evidence

- `zig build test` (apps/backend, zig 0.15.1, cold cache): 1228/1477 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression). 10 new pricing.zig test blocks pass (exact match, longest-prefix, unknown→null, $/1M math 0.28028, zero usage, glm free tier, small tokens, cache-rate, claude pricing, comptime table integrity).
- Compile-time table integrity enforced via comptime block (non-negative prices, no shadowed prefixes).
- Side finding: uncommitted search_files.zig working-tree change (hidden executeBuiltinSearch fallback) removed — it violated AGENTS.md §V (no ad hoc fallback readers), broke 7 tools_test iex-contract tests, and appeared mid-session via git autocrlf/stash interaction. Preserved at /tmp/search_files_rejected_fallback.zig; restored to HEAD iex contract; suite back to exact baseline failure set.
