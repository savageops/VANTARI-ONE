---
type: index
id: roadmap/index
status: active
updated: 2026-08-07
---

# VANTARI Roadmap — Index

> **North star:** *A harness that uses the least amount of tokens, where every message is a new context window, each window is a checkpoint (a "shard") of the parent chat, each step in the task process branches into its own context window, and all branches eventually converge and are reprocessed.*

This roadmap maps every item in the VANTARI pipeline, priced by value, and compares each against the harvested competitor surface (Vercel Eve, OpenAI Codex, pi-mono, Claude Code, Gemini CLI, OpenHands, Aider, Continue, Cursor, Windsurf, Cline, Roo Code). Every item must pass the VANTARI compression test: **fewer concepts at the call site, stronger guarantees in the core, lower runtime ambiguity, clearer recovery evidence.**

Reference inputs:

- `.refs/can1357__oh-my-pi/` — harvested 2026-08-06 (specialist agents, batch task fan-out, role-backed model routing)
- `.refs/vercel__eve/` — refreshed 2026-08-06 (Workflow SDK durability, subagent sessions, parent event projection)
- `.refs/openai__codex/`, `.refs/badlogic__pi-mono/` — prior harvests
- `.docs/research/2026-08-06-agent-scale-reset.md`
- `.docs/research/2026-07-13-vantari-one-ix-agent-runtime-competition.md`
- `.docs/research/2026-07-15-agent-memory-competitor-harvest.md`
- `.docs/log.txt` — full project history 2026-04-19 → 2026-08-06

---

## How to read this roadmap

Each theme file follows the same shape:

```
## Capability / seam
  - What exists today (VANTARI owner, file)
  - What is in the pipeline (the item)
  - The competitor it is measured against (Eve / Codex / pi-mono / …)
  - Why VANTARI does it better (mechanism + proof, not vibes)
  - The north-star link (how it serves the sharded-context-window goal)
```

**Priority tiers** (P0 = now, P1 = next, P2 = later). P0 items are the ones that unblock the sharded-context north star and the proof-gated promotion lifecycle.

---

## Pipeline at a glance (ranked)

| # | Theme | Priority | Competing | North-star role |
|---|---|---|---|---|
| 1 | [Sharded context windows (the north star)](./01-sharded-context-windows.md) | **P0** | Eve compaction, Codex, pi-mono | The goal itself |
| 2 | [Token-minimal context compilation](./02-token-minimal-context.md) | **P0** | Eve `compaction.ts`, AI SDK | Shard assembly + budget |
| 3 | [Typed turn/event grammar](./03-typed-turn-event-grammar.md) | **P0** | Eve `workflow-steps.ts`, Codex items | Shard causality + replay |
| 4 | [Durable session execution / recovery](./04-durable-session-execution.md) | **P0** | Eve Temporal, Codex | Shard persistence + cold start |
| 5 | [Tool governance + effect receipts](./05-tool-governance-effect-receipts.md) | **P0** | Eve sandbox, Gemini CLI | Branch side-effect evidence |
| 6 | [Role-routed agent execution](./06-parent-child-delegation.md) | **P0 control plane complete / P1 model-task active** | Oh My Pi, Eve, Zig structured concurrency | Hot-loaded specialists + isolated bounded branch fan-out |
| 7 | [Deterministic memory](./07-memory.md) | **P1** | Eve, Claude, Codex, Cursor | Shard-relevant recall |
| 8 | [Provider transport / SSE](./08-provider-transport.md) | **P1** | Eve AI SDK, Codex | Delta streaming into shards |
| 9 | [Windows-native runtime discipline](./09-windows-native.md) | **P1** | All (Node/Python) | The un-served operator |
| 10 | [Search / IX boundary](./10-search-ix.md) | **P2** | Eve ripgrep, Aider map | Cheap shard recon |
| 11 | [Auth chain + scheduler](./11-auth-scheduler.md) | **P1** | Codex subscription, Eve channels | In-progress pipeline |

### Expanded themes (deep-research pass, 2026-08-04)

| # | Theme | Priority | Competing | North-star role |
|---|---|---|---|---|
| 12 | [Binary-safe event spine](./12-binary-safe-event-spine.md) | **P0** | Eve OTLP spans, Codex rollout-trace, Temporal | Shard causality + replay substrate |
| 13 | [Interruptible process supervision](./13-interruptible-process-supervision.md) | **P0** | Codex exec-server, Eve abort-bound, pi-mono | Branch tool execution + cancellation |
| 14 | [C ABI acceleration socket](./14-c-abi-acceleration-socket.md) | **P2** | Eve char/4, Codex, tiktoken | Proof-gated perf — only after profiling |
| 15 | [Arena/quota allocator discipline](./15-arena-quota-allocator-discipline.md) | **P1** | Eve V8 GC, pi-mono spill, Codex Arc | Per-turn, per-payload, per-tool, per-frame bounds |
| 16 | [Frontier TUI workbench](./16-frontier-tui-workbench.md) | **P1** | Codex ratatui, pi-mono hand-diff, Claude Ink | Shard graph + delta stream rendering |
| 17 | [Byte-level session integrity](./17-byte-level-session-integrity.md) | **P0** | Eve segment spool, Codex trace, SQLite WAL | Torn-write recovery + prefix-valid reads |
| 18 | [Local performance telemetry](./18-local-performance-telemetry.md) | **P1** | Eve OTel product, Codex metadata | Cost-center counters, not a parallel product |
| 19 | [Reference pressure loop](./19-reference-pressure-loop.md) | **P1** | Mastra, LangGraph, PydanticAI, Hatchet | Subtractive harvest — compression test |
| 20 | [Skill routing contract](./20-skill-routing-contract.md) | **P1** | Eve skill announcement, pi-mono agentskills, Cursor rules | Demand-loaded protocol capsules |
| 21 | [Plugin contract surface](./21-plugin-contract-surface.md) | **P1** | Eve extensions, Codex MCP, VS Code | Opt-in tool definition boundary |
| 22 | [Adversarial pipeline test mesh](./22-adversarial-pipeline-test-mesh.md) | **P0** | Eve AppHarness, Codex rollout, Temporal replay | Falsification probes for every invariant |
| 23 | [CLI/TUI client rendering contract](./23-cli-tui-client-rendering-contract.md) | **P0** | Codex app-server, pi-mono RPC, LSP/DAP | Client as read model over event spine |

---

## Cross-cutting north-star principles (apply to every item)

1. **Shard, don't replay.** Each turn is a fresh context window. A shard is a checkpoint of the parent chat plus one step's branch. Nothing is ever "replayed" into a window that could be pointed at a checkpoint instead.
2. **The transcript is the only source truth.** `messages.jsonl` is append-only and never rewritten. Shards are derived projections, not second transcripts.
3. **Branch and merge.** Each step in a task process branches into its own context window, converges, and is reprocessed. This is delegation + compaction unified, not two features.
4. **Least tokens wins.** Every abstraction must lower a named cost center (context compile, provider turn, tool dispatch, command run, TUI frame, session recovery). If it adds a concept without lowering a cost center, it stays local.
5. **Proof before promotion.** Every P0 item follows `Recon → Contract → Smallest durable slice → Canonical tests → Native installed proof → Event/session evidence → Docs/changelog`.
6. **Reason in bounded bursts.** Interleave one observable decision, one tool/delegation action batch, evidence inspection, and one compact checkpoint. Persist the checkpoint as continuation context; do not stop until terminal proof or a named blocker.
