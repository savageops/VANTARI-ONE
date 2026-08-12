---
id: 035h
title: "Terminal QC review — both features + entire provider pipeline"
parent: 035
status: pending
priority: high
blast_radius: low
category: feature
dependencies: [035a, 035b, 035c, 035d, 035e, 035f, 035g]
next_todo: NONE
source_message_anchor: pipeline-qc
source_message_excerpt: "goal is not done until QC of both, and QC of entire pipeline."
source_message_proof_obligation: Judges the implementation as it actually exists — capability truth for cost tracking AND compat detection, ownership boundaries, test pressure, and pipeline integrity from provider response parse through event spine to TUI read model.
idempotency_contract: idempotent — review only; extends the chain only if defects are proven.
---

## Execute Now

Review the complete provider cost + compat chain as a ruthless senior maintainer, verify capability truth through the real consumer paths, then fix any proven defect by extending the chain.

## Review Criteria (QC 4/4)

### 1. Structure (maintainer-grade)
- [ ] `pricing.zig` is a pure module: const table + pure functions, no I/O, no state; provenance comments on every price row
- [ ] `compat.zig` owns ALL detection truth — no URL-substring matching scattered in `openai_compatible.zig` or dispatch
- [ ] `turn_payload.zig` is the single owner of turn boundary JSON — grep proves loop.zig and supervisor.zig contain no duplicate payload builders
- [ ] `types.Usage` is a value type with no allocation/deinit burden on `CompletionResponse`
- [ ] No file exceeds its natural ownership boundary; no parallel systems created (no new event type, no cost DB, no price service)

### 2. Contract truth (capability completion)
- [ ] All 3 providers fill `CompletionResponse.usage` (non-stream + stream)
- [ ] `turn_finished` events in `events.jsonl` carry `prompt_tokens/completion_tokens/cached_tokens/cost_total_usd` (null for unpriced models)
- [ ] z.ai requests byte-identical to pre-chain (enable_thinking top-level preserved) — the primary operator lane cannot regress
- [ ] DeepSeek gets nested thinking + reasoning_content forwarding; standard endpoints get neither
- [ ] `wire_api: "auto"` validates everywhere (config floor, role overrides) and resolves per base_url in dispatch
- [ ] `/status` shows session cost; TUI parses v2 telemetry

### 3. Test pressure (≥30 meaningful tests across the chain)
- [ ] 035a usage parse: ≥12 blocks
- [ ] 035b pricing: ≥10 blocks
- [ ] 035c anthropic/responses: ≥8 blocks
- [ ] 035d turn payload: ≥6 blocks
- [ ] 035e compat: ≥12 blocks
- [ ] 035f config: ≥3 blocks
- [ ] 035g TUI: ≥4 blocks
- [ ] Total ≥ 55 — exceeds the 30 floor; every block asserts an externally observable contract (parse output, payload JSON, request JSON, rendered status)

### 4. Code quality (anti-pattern sweep)
- [ ] No hidden fallback readers or parallel state surfaces (AGENTS.md §XII)
- [ ] Capability comments above every new/touched function (turn_payload, pricing, compat, extraction helpers)
- [ ] No inline TODO left open; comment-and-TODO discipline per slice
- [ ] JSONL/event readers unaffected (v2 payload is additive; ignore_unknown_fields proven)
- [ ] `zig build test` fully green
- [ ] No broad rewrites, no speculative abstraction (each new module has ≥2 real consumers or is the single canonical owner)

### 5. Pipeline integrity (entire chain, provider → event → client)
- [ ] Response parse → `CompletionResponse.usage` → pricing → `turn_finished` v2 → events.jsonl → TUI telemetry → `/status` — each hop evidenced by a test
- [ ] Config floor (`auto`) → dispatch resolution → request shape → provider — each hop evidenced
- [ ] Manual proof recorded: one real kernel-stdio turn against z.ai shows v2 `turn_finished` in events.jsonl with measured tokens

## Completion Checklist

- [ ] All defects found during review fixed (chain extended if any)
- [ ] Evidence recorded in every unit (no PLACEHOLDER)
- [ ] Chain archived: parent + all units in `/todo/changelog/`
- [ ] `.docs/todo/changelog/_log.md` updated
- [ ] Handoff cold-start ready from repository state

## Terminal Condition

If the review passes every criterion, this is the terminal unit — archive and execute Parent Archival. If defects are proven, extend the chain with the smallest focused fix slice + a new terminal re-review slice before closing.
