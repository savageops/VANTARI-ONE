---
id: 035e
title: "Compat auto-detection — WireApi.auto, compat.zig, dispatch resolution, thinking shapes"
parent: 035
status: done
priority: high
blast_radius: high
category: feature
dependencies: [035a]
next_todo: /todo/pending/035f-provider-cost-compat-model.md
source_message_anchor: compat-auto-detection
source_message_excerpt: "#10 Compat auto-detection	⚠️ Hardcoded chat_completions"
source_message_proof_obligation: Implements prime's detectCompat/getCompat precedence (URL detection floor + explicit config override) as the concrete WireApi + ThinkingFormat resolution VANTARI actually dispatches on, replacing the hardcoded chat_completions default and the z.ai-only thinking emission.
idempotency_contract: conditionally-idempotent — multi-file signature change (buildRequestJson gains thinking_format param). On PARTIAL recovery, grep `buildRequestJson(` call sites; the two callers (`completeWithTransportAndHooks`, `testing.requestJson`) must both be updated before tests run.
---

## Execute Now

Add `WireApi.auto`, `core/providers/compat.zig` (detectWireApi + ThinkingFormat + detectThinkingFormat), resolve `.auto` in dispatch, and key request thinking emission to the detected format (zai `enable_thinking` / deepseek nested `thinking` + reasoning_content forwarding / standard none).

## Better-than-before

The provider request is no longer shaped like z.ai for every endpoint. DeepSeek gets its nested `thinking:{type}` convention and `reasoning_content` echo (prime `requiresReasoningContentOnAssistantMessages` — without it DeepSeek errors or degrades), LM Studio/Ollama/OpenAI stop receiving an invalid `enable_thinking` field, and the config default stops pretending chat_completions is universal. Structural delta: one compat module owns the detection truth; dispatch stays the single resolution point; the active z.ai path is byte-identical (detection maps api.z.ai → chat_completions + zai format → enable_thinking).

## Entry State

- `shared/types.zig:14-30` — `WireApi` enum 3 variants + `fromString` + `label`
- `dispatch.zig:32-36` — exhaustive switch on `config.wire_api` (only switch site)
- `openai_compatible.zig:246-262` — unconditional `enable_thinking` emission; `buildRequestJson` signature `(allocator, model, request, stream, thinking_mode, effort, temperature)`
- `openai_compatible.zig:1187` — `writeMessageJson` does NOT forward `message.reasoning`
- `config/file.zig:168` `loadWireApi` + `:563-566` role override validation — both route through `WireApi.fromString`
- `routes.zig:227` — `override.wire_api orelse parent.wire_api`

## Patch Surface

**Modifies:**
- `src/shared/types.zig` — add `auto` variant to `WireApi` + `fromString("auto")` + label
- `src/core/providers/compat.zig` (new) — `ThinkingFormat` enum, `detectWireApi(base_url)`, `detectThinkingFormat(base_url)`
- `src/core/providers/dispatch.zig` — resolve `.auto` against `config.openai_base_url` before the switch
- `src/core/providers/openai_compatible.zig` — `buildRequestJson` gains `thinking_format` param; thinking emission per format; `writeMessageJson` gains format param + deepseek reasoning_content forwarding; `completeWithTransportAndHooks` computes format via compat
- `src/core/index.zig` — export `compat`

**Must not touch:**
- `anthropic.zig`, `responses.zig`, pricing, loop events, config defaults (035f)

## Detailed Requirements

1. **`WireApi.auto`** (`shared/types.zig`): `fromString("auto")` → `.auto`; `label` → `"auto"`. All existing validation paths (`loadWireApi`, `validateAgentRoute`) accept it automatically via fromString.

2. **`compat.zig`** — detection truth, harvested from prime `openai-completions.ts:1075-1165` (provider-over-URL precedence adapted to config-over-URL since VANTARI has no provider enum — explicit `wire_api` config always beats detection; detection only fires on `.auto`):
   ```zig
   pub const ThinkingFormat = enum { zai, deepseek, standard };
   pub fn detectWireApi(base_url) WireApi
   // api.anthropic.com -> .anthropic_messages
   // else -> .chat_completions  (z.ai, deepseek, openai, LM Studio, Ollama all speak chat_completions;
   //                             responses is opt-in via explicit config for LM Studio 0.3.29+)
   pub fn detectThinkingFormat(base_url) ThinkingFormat
   // api.z.ai -> .zai        (enable_thinking top-level; prime openai-completions.ts:564-565)
   // deepseek.com -> .deepseek (nested thinking:{type}; prime :573-577)
   // else -> .standard
   ```

3. **dispatch.zig**: resolve before switch:
   ```zig
   const wire_api: types.WireApi =
       if (config.wire_api == .auto) compat.detectWireApi(config.openai_base_url) else config.wire_api;
   return switch (wire_api) {
       .chat_completions => ...,
       .responses => ...,
       .anthropic_messages => ...,
       .auto => unreachable, // resolved above
   };
   ```

4. **openai_compatible.zig**:
   - `completeWithTransportAndHooks` computes `const thinking_format = compat.detectThinkingFormat(config.openai_base_url);` and passes it into `buildRequestJson`.
   - `buildRequestJson` thinking block (replaces :246-262):
     - `.zai`: current behavior verbatim — `enable_thinking:true` unless `thinking_mode == "off"` (the f9e0dcc P0 contract, now scoped to z.ai where it is valid)
     - `.deepseek`: `"thinking":{"type":"enabled"}` unless off → `"thinking":{"type":"disabled"}`
     - `.standard`: emit nothing
   - `writeMessageJson` gains `thinking_format`; when `.deepseek` and `message.reasoning != null`, emit `"reasoning_content":...` (prime `requiresReasoningContentOnAssistantMessages`). Other formats: no forwarding (z.ai handles it via enable_thinking natively).
   - `testing.requestJson` gains a `thinking_format` param (default `.zai` kept at the single test call site in provider_test.zig:29 by updating it explicitly — check each call site).
   - Capability comments above the thinking block explain the per-format contract with prime provenance.

5. **`core/index.zig`**: `pub const provider_compat = @import("providers/compat.zig");` (match existing naming style).

## Rollback Procedure (blast_radius: high — step-by-step)

1. Revert `shared/types.zig` WireApi (remove auto variant).
2. Revert `dispatch.zig` switch to the 3-arm form.
3. Revert `openai_compatible.zig` thinking block to unconditional enable_thinking + `writeMessageJson` signature; delete compat.zig.
4. `zig build test` — must be green before proceeding.
Note: nothing persists `.auto` to disk — config validation accepts it, but no file stores a resolved enum; rollback leaves no stale state.

## Exit State / Handoff Contract

- `wire_api: "auto"` is a valid config value; dispatch resolves it per base_url
- z.ai requests byte-identical to pre-chain behavior; deepseek/standard requests corrected
- 035f switches default.json to auto; 035g unaffected (TUI)

## Validation

```bash
cd apps/backend && zig build test
```

**New tests (≥12 blocks):**
1. `test "WireApi.fromString accepts auto and label round-trips"`
2. `test "detectWireApi anthropic base_url"`
3. `test "detectWireApi zai base_url stays chat_completions"`
4. `test "detectWireApi deepseek base_url stays chat_completions"`
5. `test "detectWireApi lmstudio/localhost stays chat_completions"`
6. `test "detectThinkingFormat zai / deepseek / standard"`
7. `test "zai format emits enable_thinking true when enabled"`
8. `test "zai format emits enable_thinking false when off"`
9. `test "deepseek format emits nested thinking enabled"`
10. `test "deepseek format emits thinking disabled when off"`
11. `test "standard format omits thinking fields entirely"`
12. `test "deepseek forwards reasoning_content on assistant messages"` (message with reasoning → `"reasoning_content"` present; standard → absent)
13. `test "dispatch resolves auto to chat_completions for zai config"` (end-to-end through `dispatch.completeWithTransportAndHooks` with a fake transport asserting URL/payload, or config-level resolution helper if dispatch seams require it — use the existing `testing` transport pattern in provider_test.zig)

**Existing tests**: `provider_test.zig:29` requestJson call site updated with explicit thinking_format; all other provider assertions must pass unchanged (zai default keeps enable_thinking behavior).

## Evidence

- `zig build test` (apps/backend, zig 0.15.1): 1245/1494 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression); no leaks after freeing capture buffers.
- WireApi.auto added (fromString/label); compat.zig with 8 passing detection tests (wire api: anthropic/zai/deepseek/lmstudio/unknown; thinking: zai/deepseek/standard).
- buildRequestJson now format-keyed: zai enable_thinking true/false, deepseek nested thinking enabled/disabled, standard omits both (8 request-shape tests pass).
- DeepSeek reasoning_content forwarding on assistant messages; standard does not (2 tests).
- dispatch resolves .auto per base_url before the switch (2 end-to-end dispatch tests via capture transport: zai → chat adapter with enable_thinking; anthropic → Messages adapter with max_tokens).
- z.ai operator path byte-identical: detection maps api.z.ai → chat_completions + zai format → enable_thinking (P0 fix f9e0dcc semantics preserved, now scoped correctly).
- core/index.zig exports provider_compat + provider_dispatch.
