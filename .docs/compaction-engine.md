# VANTARI Semantic Compaction Engine

> **The marketable difference:** VANTARI doesn't truncate your model's context — it understands it. Every competitor cuts at an arbitrary byte boundary. VANTARI scores every message by semantic relevance to the session's purpose, drops the least meaningful content first, and optionally delegates to the model itself to produce a dense knowledge-preserving summary.

## The problem with every other agent

Every competing agent (Claude Code, Cursor, Aider, Codex, Windsurf, Cline, Roo Code, Continue) handles context overflow the same way: **naive character truncation**. When a message exceeds the token budget, they cut it at an arbitrary byte offset and append `...`:

```
The function parse_stream_delta in src/core/provider.
```

That truncation just destroyed the file extension. The model no longer knows it's a `.zig` file. The path `src/core/provider` is now ambiguous. The context is corrupted.

Worse, the truncation is **value-blind**. It preserves "The function" (zero information) and destroys `parse_stream_delta` (the actual identifier the model needs). The filler survives; the signal dies.

## How VANTARI does it differently

VANTARI's semantic compaction engine is a **three-layer pipeline**:

### Layer 1: Value-weighted word selection (syntactic)

Every word is scored by information value on a 0–255 scale:

| Weight | Category | Examples |
|--------|----------|----------|
| **255** | Code identifiers (underscore, camelCase) | `parse_stream_delta`, `myFunction`, `HTTPClient` |
| **240** | File paths, URLs | `src/core/provider.zig`, `https://api.z.ai/...` |
| **220** | Numbers, hex, IDs | `404`, `0x1F`, `session-178594...` |
| **210** | Code fragments (punctuation-bearing) | `{"status":"failed"}`, `error.Code` |
| **200** | Long domain words, acronyms | `authentication`, `API`, `JSON`, `checksum` |
| **100** | Filler (articles, prepositions) | `the`, `a`, `is`, `to`, `of`, `and` |
| **60** | Single characters | `.`, `,`, `(` |

When the token budget is exceeded, the lowest-weighted words are dropped first. **Never truncates mid-word.**

### Layer 2: Semantic similarity scoring (embeddings or TF-IDF)

Each message in the compactable range is scored by **semantic relevance to the session's purpose** (the original user prompt):

- **With embeddings** (`semantic_compaction = true`, embedding provider configured): each message is embedded via `/v1/embeddings` and scored by cosine similarity to the purpose vector. Messages that share semantic meaning with the task score higher.

- **Without embeddings** (offline/fallback): TF-IDF cosine similarity (term frequency × inverse document frequency) computed locally. Real statistics — rare terms common to both the purpose and the message boost the score. No embedding endpoint needed.

Messages below the relevance threshold are **dropped from the summary entirely**. The summary stays focused on what matters for this session.

### Layer 3: Agent summarization (provider call, optional)

After value-weighted selection and semantic filtering, the compactor can optionally make a structured provider call (`compaction_summary_provider_call = true`) to produce a dense, knowledge-preserving summary:

**The summarization prompt includes:**
- The surviving high-relevance content
- The dropped low-relevance content (so the model sees what it's losing)
- Categorical instructions: preserve **completed work**, **in-progress state**, **learnings**, **workspace context**, **TODOs**

This is the "infinite compaction" guarantee: knowledge is preserved across compaction cycles because the model actively distills it, not because we hope the truncation didn't cut something important.

**The parent agent can also delegate summarization** via `launch_agent` — the same branch-and-converge shard primitive applied to context protection. The child session reads the transcript, produces a summary, and converges back into the parent.

## Configuration

```json
{
  "context": {
    "semantic_compaction": true,
    "compaction_summary_provider_call": true,
    "aggressiveness_milli": 350,
    "embedding_provider": "embeddings"
  }
}
```

| Setting | Default | Effect |
|---------|---------|--------|
| `semantic_compaction` | `false` | Enable Layer 2 (semantic similarity scoring) |
| `compaction_summary_provider_call` | `false` | Enable Layer 3 (agent summarization provider call) |
| `aggressiveness_milli` | `350` | 0-1000: controls how aggressively content is dropped |
| `embedding_provider` | `null` | Provider id in auth.json for embeddings; null falls back to active provider then TF-IDF |

## The aggressiveness knob

| Range | Behavior |
|-------|----------|
| 0–299 | Conservative: keep reasoning excerpts, include all relevant messages |
| 300–499 | Default: include reasoning excerpts, drop bottom-quartile relevance |
| 500–799 | Aggressive: drop reasoning excerpts, tighter relevance threshold |
| 800–1000 | Maximum: only top-relevance messages survive |

## Embedding model research (2026 MTEB leaderboard)

| Model | Size (quantized) | MTEB Score | Context | Status |
|---|---|---|---|---|
| **nomic-embed-text-v1.5** (GGUF Q2_K) | ~61 MB | 62+ | 8192 | Future bundled candidate |
| Qwen3-Embedding-0.6B | ~300 MB Q4 | 70+ | 32K | Top MTEB; larger |
| all-MiniLM-L6-v2 (ONNX) | ~23 MB | 56+ | 512 | Classic tiny pick |
| gte-large-en-v1.5 | ~130 MB Q8 | 65+ | 2048 | Good balance |

**Current:** Provider embeddings API (zero binary cost). **Future:** Bundled nomic-embed-text for offline operation.

## Why this is a marketable feature

1. **Semantic, not syntactic.** The compactor understands what matters to this specific session. A weather discussion is dropped; the config parsing discussion survives — because the purpose vector says so.

2. **Infinite compaction.** Agent summarization (Layer 3) preserves knowledge across unlimited compaction cycles. The model distills its own context, preserving completed work, learnings, and state.

3. **Zero context corruption.** No mid-word cuts. No broken identifiers. No ambiguous file paths. Whole words, whole messages, semantic relevance.

4. **Deterministic fallback.** TF-IDF is pure local computation — no provider call, no latency, no tokens spent. Embeddings add semantic depth when available; TF-IDF provides real statistics when they're not.

5. **Configurable.** Three layers, each independently toggleable. Conservative operators get value-weighting only; aggressive operators get the full semantic + agent summarization pipeline.

6. **Reasoning-aware.** The model's thinking trace is preserved or distilled by the same semantic pipeline, so the logical thread survives compaction.
