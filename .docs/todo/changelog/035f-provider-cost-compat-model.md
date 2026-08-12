---
id: 035f
title: "Config default wire_api auto + docs + changelog"
parent: 035
status: done
priority: medium
blast_radius: low
category: feature
dependencies: [035e]
next_todo: /todo/pending/035g-provider-cost-compat-model.md
source_message_anchor: compat-auto-detection
source_message_excerpt: "#10 Compat auto-detection	⚠️ Hardcoded chat_completions"
source_message_proof_obligation: Makes auto-detection the shipped default (default.json is the compiled floor every new workspace starts from) and records the runtime truth in public docs + changelog per AGENTS.md §XVII.
idempotency_contract: idempotent — text/config edits; re-application overwrites the same lines.
---

## Execute Now

Switch `default.json` provider.wire_api to `"auto"` with updated `_help`, and update `architecture.md` + `README.md` + `.docs/todo/changelog/_log.md` to describe measured token telemetry, the pricing model, and compat auto-detection as shipped runtime truth.

## Better-than-before

The compiled default stops hardcoding chat_completions (the chain's gap #10 closes at the config floor). Docs stop omitting cost/usage entirely (architecture.md's provider section currently describes only wire_api selection). Structural delta: docs describe the measured-evidence contract, not aspirational behavior.

## Entry State

- `default.json:29-33` — `"provider": {"_help": {...}, "wire_api": "chat_completions"}`
- `config/file.zig` validation accepts "auto" (035e)
- `architecture.md` — find the provider/wire_api section (search `wire_api`); `README.md` — provider/telemetry mentions

## Patch Surface

**Modifies:**
- `src/core/config/default.json` — `wire_api: "auto"` + `_help` text: auto-detects from base_url (api.anthropic.com → anthropic_messages; all other OpenAI-compat endpoints → chat_completions; explicit values override detection)
- `apps/backend/architecture.md` — provider section: compat auto-detection + thinking-format resolution + measured usage → turn_finished v2 telemetry + pricing model (compiled table, null for unknown models)
- `apps/backend/README.md` — one-line telemetry/cost mention if a provider/feature list exists
- `.docs/todo/changelog/_log.md` — chain entry per AGENTS.md §XVII

**Must not touch:**
- Kernel code (035a-e own it), TUI (035g)

## Detailed Requirements

1. **default.json**: `"wire_api": "auto"`; `_help` text ≤2 sentences describing detection precedence (explicit config > URL detection > chat_completions fallback) and the affected endpoints.

2. **architecture.md**: locate the provider/wire_api narrative (grep `wire_api`), extend with: `auto` resolution (compat.detectWireApi), ThinkingFormat (zai/deepseek/standard) request-shape contract, and the cost/telemetry contract: `turn_finished` v2 carries `prompt_tokens/completion_tokens/cached_tokens/cost_total_usd` (null when the model has no compiled price); price table in `core/providers/pricing.zig` (harvested provenance: prime-agent models.generated.ts + published rates); Usage measured per wire protocol (chat_completions prompt_tokens_details.cached_tokens / anthropic cache_* / responses input_tokens_details.cached_tokens).

3. **README.md**: only if a provider/telemetry feature list exists — add one line: cost + token telemetry on turn_finished and auto wire detection.

4. **changelog `_log.md`**: append the standard chain bullet (match existing entries' format — date, chain, files, behavior).

## Rollback Procedure

Revert the four text/config files. No runtime state affected.

## Exit State / Handoff Contract

- Fresh config floor ships `wire_api: "auto"`; docs describe shipped truth; changelog records the chain
- 035g proceeds with TUI parsing (works against v2 events regardless of config default)

## Validation

```bash
cd apps/backend && zig build test
```

**New tests (≥3 blocks):**
1. `test "default.json validates with wire_api auto"` — config load/validate against the compiled default (find the existing config validation test entry — `config/file.zig` tests or `all_tests.zig`; use the same fixture pattern)
2. `test "loadWireApi returns auto"` — file.zig:168 path with a temp workspace config
3. `test "role override wire_api auto validates"` — validateAgentRoute with "auto"

**Manual/doc proof:** `grep -n "wire_api" default.json` shows `"auto"`; `grep -n "turn_finished" architecture.md` shows the v2 telemetry contract.

## Evidence

- default.json provider.wire_api = "auto" with _help; architecture.md gained "Wire protocol auto-detection and thinking format" + "Per-turn cost and token telemetry" sections; README module list not touched (no provider list section); changelog _log.md appended.
- 3 new config validation tests + 5 pre-existing file.zig tests now EXECUTE via the new src-rooted test harness `src/chain035_tests.zig` + 5th test binary in build.zig (Zig 0.15 test-discovery investigation: a file's tests run only when its module value is referenced inside a test block of the ROOT module's own file tree; external -M modules never contribute tests — verified with 6 minimal fixtures).
- Found + fixed: validateDocumentShape never validated the provider.wire_api VALUE (only load-time caught it) — added document-shape validation so config/set validation-before-write rejects invented values.
- Found + fixed (pre-existing WIP defects surfaced by fresh compiles, preserved at evidence): tickets/index.zig:300 local `snapshot` shadowing the method (renamed to result); shell_exec drains-pipe test fixture had a 10s timeout vs ~15s measured fixture runtime on loaded Windows hardware (raised to 30s — assertions under test are cap+drain, not the timeout bound).
- Final suite: 1245/1494 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression); chain035 binary 45 tests passing (2 SkipZigTest skips).
