---
id: 035d
title: "Turn payload v2 — measured tokens + cost in turn_finished (loop + supervisor)"
parent: 035
status: done
priority: high
blast_radius: medium
category: feature
dependencies: [035a, 035b, 035c]
next_todo: /todo/pending/035e-provider-cost-compat-model.md
source_message_anchor: cost-model
source_message_excerpt: "#8 Cost model	⚠️ Gap — VANTARI doesn't track per-model cost."
source_message_proof_obligation: Emits the priced, measured turn evidence into the typed event spine so the operator can observe cost per turn through the canonical event stream.
idempotency_contract: conditionally-idempotent — builder function move + payload change; on PARTIAL recovery, verify turn_payload.zig exists and loop.zig/supervisor.zig call sites are updated (grep "turnBoundaryMessage\|turnFinishedMessage" — if any old call site remains, finish the move before re-running tests).
---

## Execute Now

Move turn boundary payload building into `core/executor/turn_payload.zig` and extend `turn_finished` to schema `var1.turn_finished.v2` carrying measured `prompt_tokens/completion_tokens/cached_tokens` + priced `cost_total_usd`, wired in both `loop.zig` and `supervisor.zig`.

## Better-than-before

The typed turn terminal evidence finally carries measured (not estimated) token telemetry plus derived cost — the event spine answers "what did this turn cost" directly, for both kernel turns and model-task turns. Structural delta: one shared owner for turn payload JSON (loop + supervisor previously had two divergent turn_finished shapes — loop had telemetry, supervisor had a text message).

## Entry State

- `CompletionResponse.usage` populated by all 3 adapters (035a+035c); `pricing.calculateCost` exists (035b)
- `loop.zig:1274-1295` — private `turnBoundaryMessage` + `turnFinishedMessage`
- `loop.zig:750` — turn_finished emission with `turnFinishedMessage(allocator, step, messages, final_output.len)`
- `loop.zig:370-371` — `completion` in scope at the emission site
- `supervisor.zig:891` — `turn_finished` appendEvent with plain text message (model-task path)
- `supervisor.zig:864` — `completion` in scope

## Patch Surface

**Adds:**
- `src/core/executor/turn_payload.zig` — `turnStartedPayload` + `turnFinishedPayload` (moved from loop.zig, extended with usage+cost)

**Modifies:**
- `src/core/executor/loop.zig` — delete local builders, import turn_payload, pass `completion.model` + `completion.usage` to `turnFinishedPayload`
- `src/core/agents/supervisor.zig` — import turn_payload, emit schema-v2 payload instead of plain text
- `src/core/index.zig` — export `turn_payload` (supervisor imports via direct path like other executor imports — check existing import style)

**Must not touch:**
- Provider adapters, pricing, TUI (035g)

## Detailed Requirements

1. **`turn_payload.zig`** (module capability comment above each fn):
   ```zig
   pub fn turnStartedPayload(allocator, step, messages) ![]u8
   // var1.turn_started.v1 — unchanged shape, moved verbatim from loop.zig:1274
   pub fn turnFinishedPayload(allocator, step, messages, model, usage, output_bytes) ![]u8
   // schema var1.turn_finished.v2:
   // {"schema":"var1.turn_finished.v2","step":N,"window_tokens":N,"output_bytes":N,
   //  "prompt_tokens":N,"completion_tokens":N,"cached_tokens":N,"cost_total_usd":N|null}
   ```
   `cost_total_usd`: `pricing.calculateCost(model, usage)` → present `total_usd` when non-null, literal `null` when unknown. Emit via `std.json.fmt` for the null-safe float: format with `{d}` when known; write `null` raw otherwise.

2. **loop.zig**: replace the two local fns with imports; the emission block at :750 calls `turn_payload.turnFinishedPayload(allocator, step, messages, completion.model, completion.usage, final_output.len)`. Keep the existing `catch "Provider turn completed."` fallback pattern and the pointer-compare ownership guard (allocated payload vs static fallback).

3. **supervisor.zig:891**: replace the plain-text turn_finished with `turn_payload.turnFinishedPayload(task_allocator, 0, &.{}, completion.model, completion.usage, content.len)` — step 0 (model tasks are single-turn), empty messages list is fine (window_tokens 0 — the estimate is a kernel-window quantity, model tasks don't compile a window). The existing `syncSessionLedgers` after append stays.

4. Keep `turn_started` at v1 (no change) — only the terminal payload gains fields.

## Rollback Procedure

Revert loop.zig + supervisor.zig to local builders, delete turn_payload.zig. Payload consumers (TUI) parse with `ignore_unknown_fields` so v2 degrades gracefully — rollback safe.

## Exit State / Handoff Contract

- `turn_finished` events carry v2 schema with tokens + cost (null when unpriced model)
- `turn_payload.zig` exported; loop + supervisor consume it; no duplicate payload builders remain
- 035g parses the new fields in the TUI

## Validation

```bash
cd apps/backend && zig build test
```

**New tests in `turn_payload.zig` (≥6 blocks):**
1. `test "turn_finished v2 payload has schema and all token fields"`
2. `test "cost_total_usd present when model priced"` (deepseek-v4-flash usage → numeric)
3. `test "cost_total_usd null when model unpriced"`
4. `test "turn_started payload unchanged v1 shape"`
5. `test "window_tokens and output_bytes preserved"`
6. `test "payload parses back as JSON with expected values"` (round-trip via std.json)

**Existing tests must pass** — `runtime_loop_test.zig` / `agent_scale_test.zig` exercise the loop and supervisor turn_finished paths; any test asserting the old plain-text supervisor message or v1 shape must be updated to the v2 contract (this is the intended contract change, not a regression).

## Evidence

- `zig build test` (apps/backend, zig 0.15.1): 1235/1484 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression).
- turn_payload.zig created with 6 passing test blocks (v2 schema fields, priced cost 0.28028 for deepseek-v4-flash, null for unpriced, v1 turn_started unchanged, output_bytes preserved + glm free-tier 0 cost, JSON round-trip parse).
- loop.zig call sites :320/:743 now use turn_payload (messages.items slice form); local v1 builders deleted.
- supervisor.zig model-task turn_finished emits v2 payload with measured usage+cost, allocated payload freed after appendEvent serialization (leak-safe).
- agent_pipeline_deep_matrix_test asserts only event_type ("turn_finished") — contract change is additive, no test updates needed.
