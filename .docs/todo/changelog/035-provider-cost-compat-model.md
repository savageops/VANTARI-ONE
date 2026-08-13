---
id: 035
title: "Provider cost model (per-turn usage + pricing) and wire compat auto-detection"
category: feature
status: done
priority: high
spec_status: approved
created: 2026-08-09
subtodo_start: 035a
subtodo_final: 035h
next_todo: NONE
---

# Parent: Provider Cost Model + Compat Auto-Detection

## Original User Message Proof

**Source anchors (verbatim):**

1. *"use the planning spec skill to plan and implement the following based on E:\Workspaces\01_Projects\01_Github\clide-md\.docs\research\2026-08-06-prime-agent-salvage-map.md"*

2. *"#8 Cost model	⚠️ Gap — VANTARI doesn't track per-model cost."*

3. *"#10 Compat auto-detection	⚠️ Hardcoded chat_completions"*

4. *"Ground in actual .refs/ competitor research. then implement."*

5. *"goal is not done until QC of both, and QC of entire pipeline."*

## System Boundary

The provider lane (`apps/backend/src/core/providers/`) has two proven gaps against the prime-agent salvage map:

**Gap 1 — Cost model.** VANTARI never parses `usage` from provider responses. All three adapters (`openai_compatible.zig`, `anthropic.zig`, `responses.zig`) return a `CompletionResponse` (`shared/types.zig:479`) with no usage field; the streaming parser (`parseStreamEventInto`, `openai_compatible.zig:395`) skips chunks with `choices.len == 0` — the exact final chunk where OpenAI-compat providers attach `usage`. The only token telemetry in the event spine is `window_tokens` — an *estimated* compile-time count (`context_builder.budget.estimateChatMessages`), never a *measured* provider count. `turn_finished` (`loop.zig:750`, builder at `loop.zig:1281`) emits `{schema, step, window_tokens, output_bytes}` only. prime-agent's pattern (`models.ts:51-62`): `calculateCost(model, usage, overrides)` = `(model.cost.X / 1_000_000) * usage.X` for input/output/cacheRead/cacheWrite, summed into `cost.total`; `Usage` shape at `types.ts:201-214`; prices per model in `models.generated.ts`.

**Gap 2 — Compat auto-detection.** `WireApi` (`shared/types.zig:14`) has exactly 3 variants and config defaults to `chat_completions` (`default.json` provider.wire_api). Worse: `buildRequestJson` (`openai_compatible.zig:246-262`) unconditionally emits z.ai's `enable_thinking` top-level boolean on EVERY chat_completions request — the z.ai-specific convention applied to deepseek/openai/lm-studio endpoints where it is invalid or ignored. prime-agent's pattern (`openai-completions.ts:1075-1165`): `detectCompat` resolves provider + baseUrl substring flags (isZai → enable_thinking, isDeepSeek → nested `thinking:{type}` + `requiresReasoningContentOnAssistantMessages`, others → openai default), and `getCompat` merges explicit per-model compat over a detected floor. Provider precedence over URL; explicit config beats detection.

**Canonical owners:** `core/providers/dispatch.zig` (single wire_api switch, called by loop/buffer/draft/supervisor), `core/providers/openai_compatible.zig` (chat adapter: request builder + 2 response parsers), `core/providers/anthropic.zig` + `responses.zig` (dynamic-JSON parsers), `shared/types.zig` (CompletionResponse), `core/executor/loop.zig` (turn_finished emission), `core/agents/supervisor.zig:891` (model-task turn_finished), `core/config/file.zig` (WireApi.fromString validation gate), `clients/tui_chat.zig` (`recordTurnTelemetry` at :574, `TurnTelemetry` parse), `clients/commands.zig` (`renderStatus`).

## Dependency Order and Risk Ordering

Sequence by measurement → pricing → emission → compat → config → client:

1. **035a measurement substrate** — `types.Usage` + chat_completions usage parse (non-stream + stream final chunk). Every later cost slice consumes `CompletionResponse.usage`.
2. **035b pricing engine** — compiled price table + `calculateCost`. Depends on a's Usage type.
3. **035c anthropic + responses usage extraction** — the two remaining adapters, same Usage contract.
4. **035d turn payload v2** — `turn_finished` carries measured tokens + cost; shared `turn_payload.zig` helper consumed by loop AND supervisor (model tasks are also provider turns).
5. **035e compat auto-detection** — `WireApi.auto` + `compat.zig` detection + dispatch resolution + thinking-shape emission (zai/deepseek/standard) + deepseek reasoning_content forwarding. Touches the same `openai_compatible.zig` as 035a but disjoint functions; must land after a so request-shape tests assert against the final file state.
6. **035f config + docs** — default.json `wire_api: "auto"` (requires e's `fromString("auto")` to validate) + architecture.md/README truth + changelog.
7. **035g TUI pipeline proof** — operator-visible cost: `recordTurnTelemetry` v2 parse, session accumulation, `/status` cost line.
8. **035h terminal QC** — judgment review of both features and the entire provider→event→client pipeline.

Risk: 035e changes request payloads for non-zai endpoints — but the active z.ai path (`api.z.ai` → zai format → enable_thinking) is byte-identical to today, so the primary operator lane cannot regress. 035d bumps the `turn_finished` schema label to v2; TUI parses with `ignore_unknown_fields=true` (`tui_chat.zig:580-586`) so pre-upgrade readers degrade safely.

## Research Program

**Completed (this session, all primary source — hard admission gate ≥9 refs, 11 gathered):**

| # | Reference | What it provides | file:line |
|---|-----------|------------------|-----------|
| 1 | prime-agent `models.ts` | `calculateCost` formula ($/1M × tokens) | models.ts:51-62 |
| 2 | prime-agent `openai-completions.ts` | `detectCompat`/`getCompat` per baseUrl+provider | openai-completions.ts:1075-1165 |
| 3 | prime-agent `types.ts` | `Usage` shape (input/output/cacheRead/cacheWrite/totalTokens + cost subobject) | types.ts:201-214 |
| 4 | prime-agent `models.generated.ts` | Price table: deepseek-v4-flash 0.14/0.28/0.0028, deepseek-v4-pro 0.435/0.87/0.003625, glm-5.2 family 0/0, gpt-4.1 2/8, gpt-4.1-mini 0.4/1.6 | models.generated.ts:4040-4070, 7593-7653, 20364-20381 |
| 5 | prime-agent `openai-completions.ts` | zai `enable_thinking` top-level (:564-565); deepseek nested `thinking:{type}` + `requiresReasoningContentOnAssistantMessages` (:573-577) | openai-completions.ts:548-577 |
| 6 | OpenAI chat_completions spec (standard) | `usage`: prompt_tokens/completion_tokens/total_tokens + `prompt_tokens_details.cached_tokens`; final stream chunk `{"choices":[],"usage":{...}}` | provider protocol standard |
| 7 | Anthropic Messages API (standard) | `usage`: input_tokens/output_tokens/cache_creation_input_tokens/cache_read_input_tokens | provider protocol standard |
| 8 | OpenAI Responses API (standard) | `usage`: input_tokens/output_tokens/total_tokens + `input_tokens_details.cached_tokens` | provider protocol standard |
| 9 | Codex `wire_api` config switch | VANTARI's own harvest provenance for the dispatch switch | dispatch.zig:12 |
| 10 | z.ai coding paas endpoint | Empirical: `api.z.ai/api/coding/paas/v4` accepts top-level `enable_thinking` (verified in auth.json + P0 fix f9e0dcc, GLM-5.2 reasoning restored) | ~/.vantari/auth.json, openai_compatible.zig:246-262 |
| 11 | VANTARI repo owners | Current parse/emit/config/client surfaces listed above | — |

**Design consequences of the research:**
- Cost formula mirrors prime exactly but VANTARI splits `Usage` (measured provider tokens) from `Cost` (derived, priced) — two small value types instead of one nested union; no allocation, no deinit, no JSON round-trip in the hot path.
- Unknown model ids → `calculateCost` returns null: cost is only ever *claimed* when a price is known; tokens still tracked. This is capability truth, not a fabricated number.
- Price table is compiled-only (harvested values). z.ai GLM-5.2 is listed 0/0 in prime's table (free tier) — cost is $0.000000 and tokens are the evidence. Operators with paid tiers get real numbers when the table is extended; `_help`-style provenance comment documents the source.
- Compat detection: baseUrl substring rules with explicit `wire_api` config precedence (prime's provider-over-URL rule, adapted to VANTARI's config-first doctrine). Detection output is the concrete `WireApi` + a `ThinkingFormat` (zai/deepseek/standard) — the two knobs VANTARI actually has. Prime's 17 flags are mostly N/A for VANTARI's 3 concrete adapters; we do not reproduce the flag forest (VANTARI compression test: fewer concepts at the call site, stronger guarantee in the core).

## Architectural Improvement Targets (Chain Ratchet)

1. **Estimated → measured token telemetry** — `turn_finished` carries `window_tokens` (estimated, compile-time) AND `prompt_tokens/completion_tokens/cached_tokens` (measured, provider-reported). The event spine stops lying about token cost.
2. **Provider-specific request shapes instead of one z.ai-shaped request for everyone** — `enable_thinking` (zai), nested `thinking` (deepseek), neither (standard). Removes the hardcoded-convention anti-pattern that shipped in the f9e0dcc P0 fix (correct for z.ai, wrong for everyone else).
3. **Hardcoded chat_completions → config-default auto with URL detection** — one enum variant, one resolve point in dispatch, explicit override preserved everywhere (config/role/parent paths already flow through `WireApi.fromString`).
4. **Event payload single owner** — `turn_payload.zig` becomes the one place turn boundary JSON is built; loop and supervisor both consume it (no drift between kernel and model-task emissions).

## Phase Plan

| Letter | Title | Patch Surface | Dependencies |
|--------|-------|---------------|--------------|
| a | Usage measurement substrate (types.Usage + chat_completions parse incl. stream final chunk) | `shared/types.zig`, `core/providers/openai_compatible.zig` | none |
| b | Compiled pricing engine (`pricing.zig`: table + calculateCost) | new `core/providers/pricing.zig`, `core/index.zig` export | a |
| c | anthropic + responses usage extraction | `core/providers/anthropic.zig`, `core/providers/responses.zig` | a |
| d | Turn payload v2 (shared builder + loop + supervisor wiring) | new `core/executor/turn_payload.zig`, `core/executor/loop.zig`, `core/agents/supervisor.zig` | a, b, c |
| e | Compat auto-detection (WireApi.auto, compat.zig, dispatch resolve, thinking shapes, deepseek reasoning forwarding) | `shared/types.zig`, new `core/providers/compat.zig`, `core/providers/dispatch.zig`, `core/providers/openai_compatible.zig` | a |
| f | Config default `wire_api: "auto"` + docs + changelog | `core/config/default.json`, `architecture.md`, `README.md`, `.docs/todo/changelog/_log.md` | e |
| g | TUI pipeline proof (telemetry parse v2, session cost accumulation, /status line) | `clients/tui_chat.zig`, `clients/commands.zig` | d |
| h | Terminal QC review (both features + entire pipeline) | all files | a-g |

## Global Queue Alignment

Pending queue: PLUG (plugin socket — distinct). No live chain touches
`providers/`, `shared/types.zig`, `executor/loop.zig`, or
`agents/supervisor.zig`. Changelog 034 (TUI) is archived and touches
`tui_chat.zig`; 035g touched a disjoint region
(`recordTurnTelemetry`/`renderStatus`) and the chain is now closed. No overlap
requiring cross-chain dependency remains.

## Closure audit (2026-08-13)

035a through 035g are archived after source and installed proof. 035h terminal
QC then passed the structure, provider-contract, test-pressure, code-quality,
and provider-to-event-to-TUI criteria. The missing eighth 035c adapter-usage
pressure test was added; the current graph is `19/19` steps and `1,964/1,964`
tests with zero leaks. ReleaseFast/install is `9/9`; built and installed
SHA-256 match at
`09758F2AFE34AC5DCD94F786B5A307F8BB0DF9A11E5DA65B743A6EBB62354834`; the
final installed VANTARI process census is zero. Parent and all units are
ready for archival; next queued boundary is Move 40.
