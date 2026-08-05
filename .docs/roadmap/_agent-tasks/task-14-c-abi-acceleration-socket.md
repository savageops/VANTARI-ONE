# Task 14 — C ABI Acceleration Socket

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/14-c-abi-acceleration-socket.md`.

1. **Study the repo** — read `AGENTS.md` (Section XVIII item 5, Section X cost model, Section VIII future-first), `.docs/log.txt` (search for "token", "simd", "abi", "profiling", "performance", "scan"), and the context scanning code under `apps/backend/src/core/context/` (especially JSONL scanning in `builder.zig`, `compactor.zig`).
2. **Study competitors** — `.refs/vercel__eve/` (token estimation, any native acceleration?), `.refs/openai__codex/` (tokenizer), `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: Zig C ABI / `export fn` patterns, SIMD JSONL scanning (simdjson, rapidjson), tokenizer acceleration (tiktoken Rust bindings, HuggingFace tokenizers), terminal width/grapheme clustering performance, when native acceleration is justified vs premature.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XVIII item 5)

- **C ABI acceleration socket:** add a narrow `extern` boundary only after profiling identifies a real bottleneck. Candidate domains:
  - Tokenizer probes (exact token counting)
  - SIMD search (JSONL scanning, needle matching)
  - JSONL scanning (parsing performance for large transcripts)
  - Terminal width/grapheme kernels

## Key constraint (AGENTS.md Section X)

Before adding abstraction, name which cost center it lowers. The answer must NOT be "organization." A dynamic worker / native acceleration is admissible only when it calls the same proven primitive and adds measurable capability. This is explicitly DEFERRED until profiling proves a bottleneck (Section VIII, Section XVIII item 5).

## Competitor angles to research

- **Vercel Eve:** `estimateTokens` is char/4 — no native acceleration at all. VANTARI could prove whether a tokenizer probe is worth it.
- **OpenAI Codex:** uses `tiktoken` (Rust via Python). How is it called? FFI overhead?
- **pi-mono:** any native perf paths?
- **simdjson:** what are the real-world JSONL scan speedups?
- **Zig extern fn:** best practices for `export fn` boundary, calling convention, allocator passing.

## Pipeline items to define

- P2 (proof-gated): Profiling harness that measures JSONL scan, context compile, event replay, terminal frame render, process spawn, tool dispatch latencies
- P2 (conditional): Exact tokenizer probe via C ABI — only if profiling proves >N% misclassification
- P2 (conditional): SIMD JSONL scanner — only if profiling proves scan is a bottleneck

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "token" (200 mentions), "performance", "profiling", "simd", "abi". The token theme is significant — exact tokenization is a recurring question.

## Output

Write ONLY `.docs/roadmap/14-c-abi-acceleration-socket.md`. Do not modify source code or the index.
