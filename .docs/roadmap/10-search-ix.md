# 10 — Search / IX Boundary

**Priority: P2**

## The seam

Search is the cheapest form of reconnaissance. In the sharded model, a branch uses search to gather evidence without pulling the full parent transcript. The search tool is the branch's cheapest effective context window: one search probe, one answer, zero tool calls.

## What exists today

- `search_files` tool uses `ix search --json` (the `iex` executable). `ix` is the sole search owner; VANTARI is a consumer.
- `apps/backend/src/core/tools/module.zig:69` owns the typed search-report failure class.
- `apps/backend/src/core/tools/builtin/search_files.zig:100-145` owns IX invocation, report parsing, status validation, hit projection.
- `runtime.zig:241-242` owns the provider-facing recovery hint.
- Search is availability-gated: if `iex` is unavailable, search capability is unavailable. No `rg`, `grep`, `sed`, or ad hoc readers as hidden substitutes.

## What the competitor does (Eve)

Eve (`packages/eve/src/runtime/framework-tools/`) uses `ripgrep` and framework-tool filesystem operations. It does not have a dedicated search index; it shells out to `rg` for file searching. Its search is a tool call, not a capability-gated index query.

## What the competitor does (Aider)

Aider uses a **graph-ranked repository map** under a strict token budget. It is a Rust-backed index that produces a compact, request-shaped map of the repository. The map is retrieval context, not a search tool, but its token-budget discipline is instructive.

## Why VANTARI does it better

1. **Capability-gated, not hidden.** VANTARI's search is available only when `iex` is available. No fallback to `rg`/`grep`. Eve's `ripgrep` usage is a hidden tool. VANTARI's fails closed; Eve's fails open.
2. **Structured search reports, not raw output.** `ix search --json` returns a typed envelope with `status`, `hits`, `stats`, `diagnostics`. VANTARI parses this into a typed search-report failure class. Eve's `ripgrep` output is raw text.
3. **No parallel search engine.** VANTARI does not reimplement search inside VANTARI. The IX roadmap items (warm indexes, watch mode, postings, selector admission) remain IX-owned work. This is the compression test: fewer concepts at the call site, stronger guarantees in the core.

## Pipeline items under this theme

### P2-10a: Search result token budget
- **Contract:** search results are bounded by a token budget on the search tool's review risk; the model sees a typed `search_result_truncated` note when the budget is exceeded.
- **Mechanism:** the search tool's effect receipt includes result byte count and token estimate; the model sees the truncation note.
- **Test:** a search that exceeds the budget returns a truncated result with the truncation event on the spine.
- **Proof:** the event spine records the truncation and the remaining token budget.

### P2-10b: Search-as-shard-input
- **Contract:** a branch can be launched with the results of a search probe as its first context window, without a full parent checkpoint.
- **Mechanism:** the branch input can be a search result set; the branch's compiler handles it as a "search probe" input type.
- **Test:** a branch launched with a search probe uses fewer tokens than a branch launched with a full parent checkpoint.
- **Proof:** measured token cost on the event spine.

## North-star link
A search is a shard with a zero-turn context window. The cheapest branch is the one that runs a search, reads the answer, and the answer is the branch's output. This is the token-extreme end of the sharded model: "do one search, produce one result, converge."

## Definition of done
- Search results are token-bounded.
- A branch can be launched with a search probe as its input.