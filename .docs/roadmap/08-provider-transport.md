# 08 — Provider Transport & SSE Delta Reconstruction

**Priority: P1**

## The seam

Provider streaming is a kernel contract. Assistant deltas must persist before the final response. In the sharded model, a branch's provider turn is a first-class event: the deltas are evidence the branch made progress, and the final response is the branch's output that the parent converges.

## What exists today

- Three provider wires: Chat Completions, OpenAI Responses, Anthropic Messages — all through SSE streaming.
- Provider SSE delta reconstruction: text fragments, tool calls, reasoning, and cache markers are reconstructed from streamed chunks before the terminal event.
- Deltas persist to `events.jsonl` before the final `assistant_response`.
- Provider capability probing (roadmap item 11) on the frontier.

## What the competitor does (Eve)

Eve (`packages/eve/src/harness/tool-loop.ts`) uses the **AI SDK** (`ToolLoopAgent` from `"ai"`). The AI SDK handles provider abstraction, SSE streaming, tool-call reconstruction, and delta emission. Eve's `emitStreamContent` wraps the AI SDK's `fullStream` and projects it into Eve's own event protocol.

**Key strengths:**
- AI SDK abstracts multiple providers behind one `ToolLoopAgent` interface.
- `emitStreamContent` in `tool-loop.ts` handles the full stream: text, tool calls, reasoning, authorization inline results.
- Provider tool normalization (`provider-tools.ts`, `provider-tool-history.ts`) handles provider-specific tool shapes.

**Limitation:** Eve depends on the AI SDK — a 500KB+ TypeScript dependency that abstracts provider transport. Eve does not own the provider wire; it consumes it. VANTARI owns the wire directly with three native transports, no intermediary SDK.

## Why VANTARI does it better

1. **Own the wire, own the contract.** VANTARI's provider transports are first-class Zig code, not a third-party SDK. When a provider changes its SSE format (e.g., Anthropic's cache discovery headers, OpenAI's `responses` API), VANTARI adapts at the kernel level, not by waiting for an SDK release.
2. **No SDK overhead.** The AI SDK is a large dependency that adds telemetry, stream abstractions, and property getters. VANTARI's provider transport is a compiled primitive that parses SSE chunks, emits typed deltas, and terminates — no runtime overhead, no SDK bugs.
3. **Deltas before the final response.** VANTARI's provider transport persists deltas to `events.jsonl` *as they arrive*, before the terminal `assistant_response`. This is a kernel contract. Eve's per-step emissions are durable per Temporal step, but the deltas cross the SDK boundary first.
4. **Provider capability probing.** VANTARI's roadmap item 11 caches verified streaming, tool-call shape, max payload, refusal/error envelopes, and context overflow signatures. Unknown capability fails closed. Eve relies on the AI SDK's provider abstraction, which is one-size-fits-most.

## Pipeline items under this theme

### P1-8a: Provider capability probe cache
- **Contract:** each provider adapter caches verified capability (streaming support, max tokens, tool-call shape, context overflow signature, refusal envelope) on first use. Unknown capability fails closed.
- **Mechanism:** a probe call runs on first provider connect; cache is persisted to `$VANTARI_HOME/provider_cache.json` or similar.
- **Test:** a provider that advertises a capability it does not support is caught by the probe, not by a late runtime crash.
- **Proof:** the probe result is a typed event on the event spine.

### P1-8b: Shard-aware provider dispatch
- **Contract:** a branch's provider turn is dispatched with the branch's context window; the turn's provider metadata (model, usage, tokens) is recorded on the branch's event spine.
- **Mechanism:** the provider transport is called from the branch's executor loop; usage is accumulated on the branch's session state, not the parent's.
- **Test:** a branch's provider usage is attributable to that branch after cold start.
- **Proof:** `events.jsonl` replay attributes every token to the correct branch.

## North-star link
Each shard is a fresh context window and therefore a fresh provider turn. The provider transport must be shard-aware: a branch's tokens are the branch's cost, not the parent's. Owning the wire directly (not through an SDK) is the only way to make this attribution deterministic.

## Definition of done
- Provider capability probes are cached and fail-closed.
- Branch provider turns are attributable to the branch, not the parent.