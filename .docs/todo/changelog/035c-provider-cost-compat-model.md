---
id: 035c
title: "anthropic + responses usage extraction"
parent: 035
status: done
priority: high
blast_radius: low
category: feature
dependencies: [035a]
next_todo: /todo/pending/035d-provider-cost-compat-model.md
source_message_anchor: cost-model
source_message_excerpt: "#8 Cost model	⚠️ Gap — VANTARI doesn't track per-model cost."
source_message_proof_obligation: Closes the measurement gap for the two non-primary adapters so every wire protocol that VANTARI speaks reports measured tokens through the same Usage contract.
idempotency_contract: idempotent — additive parser changes; missing usage → zeros, no behavior change for usage-less bodies.
---

## Execute Now

Extract provider-reported usage in `anthropic.zig` (Messages API: input/output/cache_creation/cache_read) and `responses.zig` (Responses API: input/output + cached details), mapping into `types.Usage` on `CompletionResponse`.

## Better-than-before

The cost model covers all three wire protocols VANTARI speaks, not just chat_completions. Structural delta: each adapter owns its extraction mapping (Anthropic folds cache_creation into prompt; cache_read into cached) against one shared `Usage` contract — no duplicated struct shapes.

## Entry State

- `types.Usage` + `CompletionResponse.usage` exist (035a)
- `anthropic.zig` non-stream parse at :179 uses `std.json.Value` root; stream parse at :244
- `responses.zig` non-stream parse at :179 uses `std.json.Value` root; stream parse at :264

## Patch Surface

**Modifies:**
- `src/core/providers/anthropic.zig` — non-stream usage extraction from root `usage` object; stream capture from `message_start` (`message.usage`) + `message_delta` (`usage.output_tokens`)
- `src/core/providers/responses.zig` — non-stream usage from root `usage`; stream capture from `response.completed.delta.usage`

**Must not touch:**
- `openai_compatible.zig` (035a owns it), `pricing.zig`, loop events

## Detailed Requirements

1. **anthropic non-stream** (`parseCompletionResponse` return literal): read `root.get("usage")` object:
   - `input_tokens` → `prompt_tokens`
   - `output_tokens` → `completion_tokens`
   - `cache_read_input_tokens` → `cached_tokens`
   - `cache_creation_input_tokens` → ADD to `prompt_tokens` (Anthropic bills cache creation at input rate)
   - `total_tokens` absent → `reconcile()` sums buckets
   - Missing usage object → zeros (never error; `std.json.Value` dynamic access)

2. **anthropic stream** (`parseStreamResponse` / `parseAnthropicSseEvent`): Anthropic SSE emits `message_start` (`{"message":{"usage":{"input_tokens":N,"cache_creation_input_tokens":N,"cache_read_input_tokens":N}}}`) and terminal `message_delta` (`{"usage":{"output_tokens":N}}`). Accumulate: `input_tokens` from message_start into `prompt_tokens`; `cache_creation_input_tokens` into `prompt_tokens`; `cache_read_input_tokens` into `cached_tokens`; `output_tokens` from message_delta into `completion_tokens`; reconcile at return. Inspect the existing event-type dispatch in `parseAnthropicSseEvent` (:316) and add usage capture at the message_start/message_delta branches.

3. **responses non-stream**: `root.get("usage")`:
   - `input_tokens` → `prompt_tokens`
   - `output_tokens` → `completion_tokens`
   - `input_tokens_details.cached_tokens` → `cached_tokens`
   - `total_tokens` → keep; reconcile when absent

4. **responses stream** (`parseSseEvent` :337): terminal `response.completed` event carries `delta.usage` with the same shape as non-stream. Capture at the completed branch; reconcile at return.

5. Both adapters keep `ignore_unknown_fields=true` dynamic parsing — no struct changes needed, only extraction helpers (`extractUsageValue(root)` style private fn per adapter).

## Rollback Procedure

Revert the two parser files. Additive — usage-less bodies behave identically.

## Exit State / Handoff Contract

- `anthropic.testing.completionResponse` (or equivalent test surface) returns usage; same for responses
- All three adapters now fill `CompletionResponse.usage`
- 035d prices it in `turn_finished`

## Validation

```bash
cd apps/backend && zig build test
```

**New tests (≥8 blocks):**
1. `test "anthropic non-stream usage: input/output/cache_read/cache_creation"`
2. `test "anthropic cache_creation folds into prompt_tokens"` (creation 100 + input 200 → prompt 300)
3. `test "anthropic stream message_start + message_delta usage accumulation"`
4. `test "anthropic response without usage yields zeros"`
5. `test "responses non-stream usage with cached details"`
6. `test "responses stream completed event usage"`
7. `test "responses response without usage yields zeros"`
8. `test "anthropic tool_use + usage both parsed"` (usage does not disturb content/tool extraction)

Test access: use the adapters' public parse entry points — check existing test pattern for anthropic/responses parse tests in `provider_test.zig` and extend identically.

## Evidence

- `zig build test` (apps/backend, zig 0.15.1): 1235/1484 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression). One transient flake (core_store docs-sync) observed in one run, passed on re-run — known environmental family.
- 8 new tests pass: anthropic non-stream usage (cache_creation folds into prompt: 100+5=105), anthropic stream message_start+message_delta accumulation, anthropic no-usage zeros, anthropic tool_use+usage, responses non-stream usage+cached details, responses stream response.completed usage, responses stream usage defaults cached tokens to zero when details are omitted, and responses no-usage zeros.
- captureAnthropicUsage + captureResponsesUsage wired into all 4 parse surfaces (non-stream + stream per adapter).
- core/index.zig now exports provider_anthropic + provider_responses for canonical test access.
