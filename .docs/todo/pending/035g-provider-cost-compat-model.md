---
id: 035g
title: "TUI pipeline proof — telemetry parse v2 + session cost in /status"
parent: 035
status: pending
priority: medium
blast_radius: low
category: feature
dependencies: [035d]
next_todo: /todo/pending/035h-provider-cost-compat-model.md
source_message_anchor: pipeline-qc
source_message_excerpt: "goal is not done until QC of both, and QC of entire pipeline."
source_message_proof_obligation: Proves the cost model end-to-end by making the operator-visible TUI surface render measured tokens and accumulated session cost from the typed event stream — the pipeline's final consumer.
idempotency_contract: idempotent — TUI state additions; re-application overwrites the same struct/function regions.
blocked_reason: "The source implementation, pinned Debug/ReleaseFast graph, focused TUI graph, and hash-matched installed artifact are present. The remaining gate is one real installed provider consumer run: priced and unpriced turns, event-ledger readback, and /status totals."
unblock_action: "Using the current installed ReleaseFast binary, run one priced and one unpriced live provider turn, read the unified turn_terminal.v1 payload from events.jsonl, confirm the measured fields and accumulated /status projection, then execute 035h QC."
resumption_point: "Post-flight validation of the existing recordTurnTelemetry and renderStatus implementation; do not reimplement the source slice."
---

## Execute Now

Extend `recordTurnTelemetry` in `tui_chat.zig` to parse the v2 `turn_finished` payload (tokens + cost), accumulate session totals in `ChatState`, and render a cost line in `/status` (`commands.zig renderStatus`).

## Better-than-before

The operator can SEE what the session cost from inside the terminal — the cost model's canonical consumer path is closed (event spine → TUI read model → user-visible value). Structural delta: telemetry stays a single-keyed read-model row (no new event bus, no parallel status channel — per AGENTS.md §IV "TUI progress is a read model over events.jsonl").

## Entry State

Audit update 2026-08-12: the required source fields, parser, accumulation, status
rendering, and focused tests are present. Resume at validation and installed
consumer proof, not at implementation.

- `tui_chat.zig:573-588` — `recordTurnTelemetry`: parses `TurnTelemetry {window_tokens}` with ignore_unknown_fields; `self.context_used_tokens = parsed.value.window_tokens` — called for both turn_started and turn_finished
- `tui_chat.zig:138` — `context_window_tokens` field (health-provided ceiling)
- `commands.zig` — `renderStatus` (workspace/model/session info, called by `/status`)

## Patch Surface

**Modifies:**
- `src/clients/tui_chat.zig` — `TurnTelemetry` struct + accumulation fields + accumulation in recordTurnTelemetry
- `src/clients/commands.zig` — `renderStatus` cost/token line

**Must not touch:**
- Kernel, providers, events (all prior slices)

## Detailed Requirements

1. **`ChatState` fields** (near `context_used_tokens`):
   ```zig
   session_prompt_tokens: u64 = 0,
   session_completion_tokens: u64 = 0,
   session_cached_tokens: u64 = 0,
   session_cost_usd: f64 = 0,
   has_session_cost: bool = false,
   ```

2. **`recordTurnTelemetry`** — extend the local struct:
   ```zig
   const TurnTelemetry = struct {
       window_tokens: u64 = 0,
       prompt_tokens: u64 = 0,
       completion_tokens: u64 = 0,
       cached_tokens: u64 = 0,
       cost_total_usd: ?f64 = null,
   };
   ```
   On `turn_finished` only: accumulate tokens + cost (`if (parsed.value.cost_total_usd) |cost| { self.session_cost_usd += cost; self.has_session_cost = true; }`). `window_tokens` still updates on both event types (existing behavior).

3. **`renderStatus`** (commands.zig) — add a telemetry line after the session line, rendered through the existing formatting helpers (match the file's output style, e.g. `renderStatus` builds a string via allocPrint):
   `Cost: $0.001234 · 12.3k in / 34.5k out / 0 cached` — when `has_session_cost`; tokens-only line otherwise (`Tokens: 12.3k in / 34.5k out / 0 cached`). Format token counts with k-suffix helper if one exists in tui_chat.zig, else a local minimal formatter. Find `renderStatus`'s current signature — it may need the ChatState pointer or the fields passed in; thread the minimal fields (do not pass the whole ChatState if the current signature takes discrete args — preserve the existing call contract).

## Rollback Procedure

Revert the two client files. Purely additive UI read-model.

## Exit State / Handoff Contract

- `/status` shows session tokens + cost (or tokens-only for unpriced models)
- 035h QC reviews the full pipeline including this consumer

## Validation

```bash
cd apps/backend && zig build test
```

**New tests (≥4 blocks):**
1. `test "recordTurnTelemetry parses v2 payload tokens and cost"`
2. `test "turn_finished accumulates session cost across turns"` (two events → summed)
3. `test "cost_total_usd null leaves has_session_cost false"`
4. `test "renderStatus includes cost line when present and tokens-only when absent"`

Test access: follow the existing pattern used for TUI unit tests — check how `commands.zig`/`tui_chat.zig` internals are tested today (grep for existing test blocks in those files); if the files have no test blocks, place the tests in the file that owns the function being tested (or `tests/all_tests.zig` style) using the same direct-call approach as the codebase's other client tests.

**Manual proof (pipeline QC):** run the installed owner/TUI flow against the z.ai provider, complete a turn, verify `var1.turn_terminal.v1` carries the cost fields in `events.jsonl`, and `/status` shows the cost line.

## Source evidence (installed provider proof pending, refreshed 2026-08-13)

- Source gate cleared on committed HEAD `5323166`: the broad graph passes 19/19
  steps and 1959/1959 tests. This does not clear the installed-provider proof
  required by this unit.
- The cost telemetry is wired through the move-19 unified terminal event: `loop.zig:771/835` call `turn_payload.completedTerminalInput(step, messages, model, completion.usage, output_bytes)`, so measured `usage` reaches `var1.turn_terminal.v1`.
- TUI parses the unified terminal payload: `recordTurnTelemetry` captures `prompt_tokens/completion_tokens/cached_tokens/cost_total_usd` (tui_chat.zig); `/status` renders the session cost line (commands.zig `renderStatus`).
- New TUI telemetry tests pass: priced-cost accumulation across two turns (0.0001 + 0.0002 = 0.0003), null-cost leaves `has_session_cost` false, `turn_started` refreshes window estimate without accumulating cost.

**Remaining gate:** run one priced and one unpriced provider turn through the
current installed ReleaseFast binary, read the unified terminal payload from
`events.jsonl`, and confirm the accumulated `/status` projection. The binary
hash and process-cleanup gate are already closed; do not archive on source-test
evidence alone.
