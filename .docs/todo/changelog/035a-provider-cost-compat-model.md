---
id: 035a
title: "Usage measurement substrate — types.Usage + chat_completions usage parse"
parent: 035
status: done
priority: high
blast_radius: medium
category: feature
dependencies: []
next_todo: /todo/pending/035b-provider-cost-compat-model.md
source_message_anchor: cost-model
source_message_excerpt: "#8 Cost model	⚠️ Gap — VANTARI doesn't track per-model cost."
source_message_proof_obligation: Implements the measurement substrate — provider-reported token counts must be captured before any cost can be derived; every later cost slice consumes CompletionResponse.usage.
idempotency_contract: idempotent — pure parser + struct additions; re-execution re-applies the same edits. Usage parse is additive (missing usage → zeros).
---

## Execute Now

Add `types.Usage` and parse provider-reported usage in the chat_completions adapter (non-stream response + streaming final-chunk capture), carried on `CompletionResponse.usage`.

## Better-than-before

The event spine's token telemetry stops being purely estimated. `turn_finished` currently reports `window_tokens` (compile-time estimate via `context_builder.budget.estimateChatMessages`); after this slice the provider's measured `prompt_tokens/completion_tokens/cached_tokens` exist in the canonical response type and flow to the loop. Structural delta: one measured-truth field on the shared response type, zero new event surfaces.

## Entry State

- `shared/types.zig:479-498` — `CompletionResponse {model, content, tool_calls, reasoning}`, no usage
- `core/providers/openai_compatible.zig:35-58` — `ParsedResponse {choices, model}`, no usage field
- `core/providers/openai_compatible.zig:330-415` — `parseStreamCompletionResponse`/`parseStreamEventInto` skip chunks with `choices.len == 0` (drops the final `{"choices":[],"usage":{...}}` chunk)
- `core/providers/openai_compatible.zig:60-82` — `ParsedStreamChunk {choices}`, no usage field

## Patch Surface

**Modifies:**
- `src/shared/types.zig` — add `Usage` struct (value type, no allocation) + `usage: Usage = .{}` on `CompletionResponse`
- `src/core/providers/openai_compatible.zig` — `ParsedResponse.usage`, `ParsedStreamChunk.usage`, usage extraction in `parseCompletionResponse` + `parseStreamEventInto`

**Must not touch:**
- `anthropic.zig`, `responses.zig` (035c)
- `pricing.zig` (035b), loop events (035d), request building (035e)

## Detailed Requirements

1. **`types.Usage`** in `shared/types.zig` (mirrors prime `types.ts:201-214` flattened to VANTARI's measured-truth contract — all integers, value type, no deinit):
   ```zig
   pub const Usage = struct {
       prompt_tokens: u64 = 0,
       completion_tokens: u64 = 0,
       cached_tokens: u64 = 0,
       total_tokens: u64 = 0,

       /// Recompute total from the sum of measured buckets when the provider
       /// omits total_tokens (some OpenAI-compat endpoints do on stream tails).
       pub fn reconcile(self: *Usage) void {
           if (self.total_tokens == 0) {
               self.total_tokens = self.prompt_tokens + self.completion_tokens + self.cached_tokens;
           }
       }
   };
   ```
   Add `usage: Usage = .{}` to `CompletionResponse` (value field, no deinit change).

2. **Non-stream parse** (`parseCompletionResponse`, openai_compatible.zig:279): `ParsedResponse` gains:
   ```zig
   usage: ?ParsedUsage = null,
   const ParsedUsage = struct {
       prompt_tokens: u64 = 0,
       completion_tokens: u64 = 0,
       total_tokens: u64 = 0,
       prompt_tokens_details: ?PromptTokensDetails = null,
       const PromptTokensDetails = struct { cached_tokens: u64 = 0 };
   };
   ```
   In the return literal: `usage = extractUsage(parsed.value.usage)` where `extractUsage` maps `prompt_tokens_details.cached_tokens` → `cached_tokens`, calls `reconcile()`, returns `.{}` when `usage == null`. Helper lives in `openai_compatible.zig` (private) — the other two adapters get their own extraction in 035c.

3. **Stream parse**: `ParsedStreamChunk` gains `usage: ?ParsedUsage = null`. In `parseStreamEventInto` (line 395), after the `choices.len == 0` early return is hit, capture usage instead of skipping:
   ```zig
   if (parsed.value.choices.len == 0) {
       // OpenAI-compat providers attach usage on the terminal chunk
       // {"choices":[],"usage":{...}}. Capture the last non-null usage.
       if (parsed.value.usage) |usage| last_stream_usage = usage;
       return;
   }
   ```
   `parseStreamCompletionResponse` threads a `last_stream_usage: ?ParsedUsage` accumulator (pass pointer into `parseStreamEventInto`); the final return literal uses `extractUsage(last_stream_usage)`. Also capture usage when present on non-empty chunks (some providers attach usage per chunk) — assign unconditionally when non-null so the last non-null wins.

4. **Signature change**: `parseStreamEventInto` gains a `last_stream_usage: *?ParsedUsage` parameter (and `parseStreamCompletionResponse` initializes it null). The existing `testing.completionResponse` passthrough needs no change (it forwards `response_body`).

## Rollback Procedure

Remove `usage` field from `CompletionResponse`, revert ParsedResponse/ParsedStreamChunk + parse functions. Purely additive — rollback restores prior behavior byte-for-byte.

## Exit State / Handoff Contract

- `types.Usage` + `CompletionResponse.usage` exist in `shared/types.zig`
- `provider.testing.completionResponse` returns usage for non-stream + stream bodies with usage
- Missing/absent usage → zeros (never error)
- 035b consumes `Usage`; 035c applies the same extraction to the other two adapters

## Validation

```bash
cd apps/backend && zig build test
```

**New tests in `provider_test.zig` (≥12 blocks):**
1. `test "non-stream response captures usage with cached details"` — full usage body: prompt/completion/total/cached asserted
2. `test "non-stream response with no usage field yields zeros"` — old-format body, all fields 0
3. `test "usage total recomputed from buckets when total_tokens omitted"`
4. `test "stream final chunk usage captured from choices-empty chunk"`
5. `test "stream usage attached to non-empty chunk wins over earlier chunks"` (last non-null)
6. `test "stream without any usage yields zeros"`
7. `test "stream with reasoning + usage both captured"` (GLM body: reasoning_content + usage)
8. `test "stream tool-call deltas + terminal usage chunk combined"`
9. `test "usage cached_tokens defaults 0 when details omitted"`
10. `test "Usage.reconcile keeps provider total when present"`
11. `test "parseCompletionResponse unchanged content/tool_calls with usage present"` (regression: usage does not disturb existing fields)
12. `test "stream [DONE] with trailing usage-only chunk"` (two trailing chunks)

**Existing tests must pass unchanged** — the provider request/response surface is additive.

## Evidence

- `zig build test` (apps/backend, zig 0.15.1): 1365/1618 passed, 182 skipped, 71 failed — identical failure set to pure HEAD f9e0dcc baseline (71 pre-existing environmental failures in auth/store/workspace suites reading real installed state; verified via git stash baseline runs and comm diff: zero new failures).
- 13 new provider_test.zig usage blocks pass (non-stream usage+cached, stream final-chunk capture, last-non-null wins, zeros when absent, reconcile, tool-call+usage, reasoning+usage).
- `types.Usage` + `CompletionResponse.usage` compiled and exercised through `provider.testing.completionResponse`.
