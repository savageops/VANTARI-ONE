# 02 — Token-Minimal Context Compilation

**Priority: P0**

## The seam

The context compiler is the only owner allowed to turn session storage into provider messages (`apps/backend/src/core/context/builder.zig`). The north star demands this compiler emit the **least-token window possible**: a checkpoint + one branch, never the whole history. Token efficiency is a cost center, not an aesthetic.

## What exists today

- `builder.zig` reads the latest checkpoint, prepends the summary prefix, then appends raw messages from `first_kept_seq`.
- `budget.zig` computes `context_window_tokens`, `reserve_output_tokens`, `compact_at_ratio_milli`, `auto_compaction`.
- `compactor.zig` writes typed checkpoints.
- `overflow.zig` detects provider overflow patterns and rebuilds once.

## What the competitor does (Eve)

Eve's token accounting is heuristic and per-call:

- `estimateTokens` (`packages/eve/src/harness/token-estimate.js`) is a char/4 heuristic; the *only* real token count comes from `usage` on the last model response, stored as `lastKnownInputTokens` + `lastKnownPromptMessageCount` on session state.
- `getInputTokenCount` recomputes `prior + estimateTokens(messages.slice(priorCount))` — an estimate stacked on an estimate.
- `shouldCompact` adds a fixed `COMPACTION_PROMPT_OVERHEAD_TOKENS` (computed once at module load) to the estimate.
- Compaction prompt building (`compaction-prompt.ts`) renders the transcript verbatim, then *degrades oldest entries* (caps at `DEGRADED_TEXT_LIMIT = 2_000` chars) only when the rendered prompt exceeds budget — a post-hoc patch, not a budget-aware builder.
- `selectRecentWindowSize` walks backward accumulating `estimateTokens` against a `COMPACTION_SUMMARY_RESERVE_TOKENS` reserve.

**Limitation:** Eve's token model is a heuristic that never proves itself against the provider's real tokenizer. It is built for one linear conversation, not for sharded windows, and it re-estimates from scratch on every step.

## What the competitor does (Codex / pi-mono)

- Codex uses a real tokenizer (`openai__codex` memory pipeline and prompt assembly) with explicit token accounting.
- pi-mono (`badlogic__pi-mono`) tracks context budget explicitly in its agent loop.

## Why VANTARI does it better

1. **Ledger-addressed, not array-positional.** VANTARI's budget/compaction reads `context.jsonl` checkpoints (sequence-addressed) and a stable `first_kept_seq`; it never depends on in-memory array position that changes between steps. Eve's `lastKnownPromptMessageCount` is exactly that fragile position.
2. **One compiler, one window.** VANTARI's builder is the single owner of the provider window. Eve's harness composes messages ad hoc across `tool-loop.ts`, `compaction.ts`, `workflow-steps.ts` — the window is assembled in several places.
3. **Exact tokenizer is admissible when proven.** AGENTS.md permits exact tokenizer integration when tests prove the heuristic misclassifies real provider windows. VANTARI's contract is proof-gated; Eve's is heuristic-by-default, forever.

## Pipeline items under this theme

### P0-2a: Shard assembly budget
- **Contract:** the compiler can assemble a window as `checkpoint + branch` where the branch is budgeted independently of the parent checkpoint.
- **Mechanism:** extend `builder.zig` with a branch-mode window: parent checkpoint summary + branch transcript suffix, both bounded by `context_window_tokens` with `reserve_output_tokens` held aside.
- **Test:** for a given parent checkpoint, assembling any branch costs fewer tokens than assembling the full parent window; the delta is measured in the test.
- **Proof:** byte-accurate provider payloads captured in tests, not estimates.

### P0-2b: Measured token telemetry
- **Contract:** per-window token counts (checkpoint + branch + suffix) recorded as typed diagnostics on `turn_started`/`assistant_response` events.
- **Mechanism:** the builder records `window_input_tokens`, `checkpoint_tokens`, `branch_tokens` on the event spine.
- **Test:** a window that exceeds `context_window_tokens` by construction is caught at compile time (builder returns a typed `ContextWindowExceeded` error, not a provider failure).
- **Proof:** the telemetry is replayed from `events.jsonl` after cold start.

### P0-2c: Exact tokenizer probe (deferred, proof-gated)
- **Contract:** only if tests prove the heuristic misclassifies a real provider window do we integrate an exact tokenizer. Candidate: C ABI tokenizer probe (roadmap item 5 in AGENTS.md) — a narrow `extern` boundary, not a runtime dependency.
- **Test:** a corpus of real provider payloads where heuristic vs exact differ by >N%; then and only then is the probe added.
- **Proof:** the probe is a build-time optional, off by default.

## North-star link
Every shard is a fresh context window. The cost of the whole harness is the sum of shard windows. Token-minimal compilation is the economic engine of the north star: cheaper shards → more branches per token → higher value per turn.

## Definition of done
- One compiler, one window, with measured token accounting on the event spine.
- Branch windows are provably cheaper than parent windows.
- No provider failure can result from a window the compiler should have caught.