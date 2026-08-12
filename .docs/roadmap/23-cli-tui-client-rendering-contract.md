---
type: architecture-contract
id: roadmap-23-cli-tui-client-rendering-contract
status: active
updated: 2026-08-12
owner: apps/backend/src/clients
---

# 23 — CLI/TUI Client Rendering Contract

**Priority: P0**

**Current delta (2026-08-12):** The tracked TUI now uses the exact persisted
`events.jsonl` sequence as its only render/replay identity. Public `LocalClient`
is now a reconnecting facade over one project-local execution owner; private
`ChildClient` alone spawns `kernel-stdio`. Contiguous live events
perform no replay read; gaps and the turn-completion boundary request only the
durable suffix through existing `session/get`. The one-shot CLI has no event
replay surface. The HTTP bridge still exposes a transport-local SSE id for ignored
browser prototypes, so the broader multi-client/browser contract remains open.

## The seam

> CLI/TUI/browser clients never assemble provider context, infer tool state, or maintain their own transcript truth. They render kernel-owned state.

VAR1 owns the causal chain — transcript, context checkpoints, event spine, tool spans, provider turns, session lifecycle. Every client surface (interactive TUI, one-shot CLI, HTTP bridge for a browser, future desktop shell) is a thin read model over that owned state. TUI and CLI use exact owner-only loopback JSON-RPC; the owner forwards to the sole kernel through private Content-Length stdio. Clients subscribe to a monotonic notification stream and render frames. No client is allowed to become a second kernel.

This theme is the contract that keeps the kernel the only truth. It is what separates "a terminal that happens to show agent output" from "a terminal whose picture of the agent is provably the kernel's picture." Every frontier capability — live deltas, typed tool spans, cancellation, cold-start replay — is only real if the client renders it from kernel-owned evidence rather than from its own speculation.

## What exists today

- **Stdio JSON-RPC kernel host** (`apps/backend/src/host/stdio_rpc.zig`).
  - LSP-style framing: `Content-Length: <n>\r\n\r\n` header + JSON body (`writeFrame`/`readFrame`, lines 1401-1453). This is the same base protocol LSP and MCP use over stdio.
  - One `initialize` handshake (`handleInitialize`, line 594) returns `server_version` + a `Capabilities` struct advertising the full method surface (`apps/backend/src/shared/protocol/types.zig`, lines 25-44).
  - Request/response with string `id` correlation; fire-and-forget notifications carry no `id` (`processRequest`, lines 490-541).
  - Methods are slash-namespaced and version-stable: `initialize`, `session/create`, `session/resume`, `session/send`, `session/compact`, `session/cancel`, `session/get`, `session/list`, `tools/list`, `events/subscribe`, `health/get`, `models/list`, `schedule/get`, `schedule/list` (`methods` struct, `types.zig` lines 8-23).
  - Exactly one notification method today: `session/event` (`notification_methods.session_event`, `types.zig` line 5).

- **Reconnectable public `LocalClient`** (`apps/backend/src/host/owner_client.zig`). Resolves one workspace owner, validates its live generation/protocol/executable identity, and calls exact token-gated loopback routes. Deinit owns no process and does not stop execution.

- **Private `ChildClient`** (`apps/backend/src/host/stdio_client.zig`). The resident owner alone spawns the same binary with `kernel-stdio`, owns the stdin mutex, runs the response/notification reader, and supervises one Windows Job Object. `waitForNotificationAfter(after_sequence, timeout_ms)` drains that owner-local queue; the versioned payload carries the separate durable per-session sequence.

- **Typed event spine with stable IDs** (`apps/backend/src/shared/protocol/events.zig`, `apps/backend/src/core/executor/loop.zig` lines 725-849). Every tool lifecycle event carries a `schema` (`var1.tool_started.v1`, `var1.tool_output_delta.v1`, `var1.tool_finished.v1`) and a stable `tool_call_id`. The event grammar floor is `tool_requested -> tool_reviewed -> tool_started -> tool_output_delta* -> tool_finished -> tool_completed` (AGENTS.md §IV).

- **TUI as read model** (`apps/backend/src/clients/tui_chat.zig`).
  - Hydrates from `session/get` (transcript + events) on load, then drains live `session/event` notifications by transport queue position while rendering only contiguous durable event sequences. A gap or completed turn requests `session/get { after_seq, events_only }`; the normal contiguous path performs no replay RPC.
  - **Single keyed-row tool rendering is already implemented.** `addToolProgress` (lines 454-477) upserts by `tool_call_id`: `tool_started` creates the row, `tool_output_delta` appends bounded output to the same row (`appendToolProgress`, lines 505-526), `tool_finished` rewrites the same row with duration/error. One tool invocation = one row that mutates. This is the exact behavior AGENTS.md §IV mandates and the exact behavior log entry 342 (2026-05-09) demanded: stop emitting "Running tool / Running start / Running done" as three rows.
  - **Assistant streaming is a single growing row.** `addAssistantDelta` (lines 528-551) reallocs the last assistant message in place; the "thinking" placeholder (`startAssistantPlaceholder`) is replaced by the first delta, not appended beside it.
  - **Untrusted output is bounded.** `max_tool_output_payload_bytes = 180`, `max_tool_output_preview_bytes = 180`, `max_progress_message_bytes = 220`; `compactOutputPreview`/`normalizeTerminalChunk` decode base64 `chunk_b64` and render a truncated, sanitized preview. The client never executes stdout content — it decodes a kernel-owned envelope and renders display text.
  - **Replay identity is exact.** `last_event_seq` is the sole per-session render cursor. Equal timestamp/type/message payloads remain distinct when their stored sequences differ; an already consumed sequence cannot render twice. The removed 512-entry content-key cache owns no fallback identity.

- **One-shot CLI** (`apps/backend/src/clients/cli.zig`). `executeRunViaKernel`/`executePromptTurn` (lines 712-838) drive the same `LocalClient` through `initialize` -> `session/create` -> `session/send`, render terminal output as bounded text, and emit `VAR1_STATUS`/`VAR1_ERROR` envelopes to stderr. The CLI never reconstructs context; it reads `session.output`.

- **Persistent owner plus browser bridge** (`apps/backend/src/host/http_bridge.zig`). Exact `/owner/rpc` and `/owner/events` routes serve TUI/CLI behind a separate owner token and generation. Redacted `POST /rpc` and `GET /events` retain the ignored browser prototype contract. Both forward to the same private `ChildClient`; no tracked browser consumer ships in this checkout.

**Gap:** the protocol is real and the tracked TUI now renders by kernel-published durable sequence, but capability negotiation remains static. `initialize` advertises a default `Capabilities{}`; clients cannot negotiate event schemas, notification methods, or streaming behavior. Tool spans are single-row in the TUI but still key on provider `tool_call_id`; the kernel does not publish a span id that survives provider id gaps. The ignored browser prototypes long-poll by transport cursor instead of resuming by per-session ledger sequence.

## What the competitor does

### OpenAI Codex — `codex app-server` (the closest analog)

Codex splits the world into an **app-server** (the kernel) and clients (TUI, exec CLI, VS Code extension) over JSON-RPC 2.0. Reference: `.refs/openai__codex/codex-rs/app-server/README.md`.

- **Three core primitives: Thread / Turn / Item** (README "Core Primitives"). A thread holds turns; a turn holds items; an item is the unit the UI renders. This is the codex equivalent of session / turn / tool-span.
- **JSON-RPC over stdio, websocket, or unix socket** (README "Protocol"). Default stdio is newline-delimited JSON; the `"jsonrpc":"2.0"` header is omitted on the wire. VANTARI keeps the header and uses LSP `Content-Length` framing — stricter, binary-safe, and the same framing LSP and MCP standardized.
- **Item lifecycle is `item/started` -> item-specific deltas -> `item/completed`** with a stable `item.id` (README "Turn events", "Items", lines 1046-1112). `item/agentMessage/delta` appends to the agent message; `item/commandExecution/outputDelta` streams stdout/stderr; the UI concatenates deltas for the same `itemId`. This is exactly VANTARI's single-keyed-row model — codex calls the key `item.id`, VANTARI calls it `tool_call_id`.
- **Capability negotiation is real but coarse.** `initialize.params.capabilities.optOutNotificationMethods` lets a client suppress exact method names (e.g. `item/agentMessage/delta`) per connection (README "Notification opt-out", lines 1003-1015). `clientInfo.name` identifies the client for compliance logging. There is no per-schema version negotiation.
- **Server-initiated requests for approvals** (README "Approvals", lines 1135-1187). The kernel sends a JSON-RPC *request* to the client to approve a command/file change; the client responds with a `decision`. This is bidirectional JSON-RPC — the same model LSP uses for `window/showMessage`.
- **In-process typed fast path.** `app-server-client/README.md` documents that the TUI and `codex-exec` share typed channels (`ClientRequest`/`ServerNotification`) and JSON is materialized at external transport boundaries. VANTARI chooses a persistent loopback owner instead: client exit cannot destroy the fixed pool, while private stdio preserves the same typed kernel boundary.
- **Backpressure is explicit.** Saturated ingress returns JSON-RPC `-32001 "Server overloaded; retry later."`; bounded queues; `Lagged` events when a client falls behind (app-server-client README "Backpressure and shutdown"). VANTARI's `max_notification_backlog = 512` (`stdio_rpc.zig` line 29) is the same idea but currently drops silently from the head rather than signaling lag.

### Vercel Eve — web only, no local client

Eve is a server-side Temporal harness behind a Next.js docs app. Reference: `.refs/vercel__eve/apps/docs/app/api/chat/route.ts` delegates to `@vercel/geistdocs/routes/chat`; the harness lives in `.refs/vercel__eve/packages/eve/src/harness/`. There is no local client binary, no stdio protocol, no terminal surface. The "client" is a browser hitting an HTTP chat route that streams from a cloud-hosted harness. State ownership and rendering are coupled to the deployment: there is no local-first kernel for the client to be a read model over.

### badlogic pi-mono — RPC over stdin/stdout

pi-mono exposes a `--mode rpc` JSONL protocol over stdin/stdout (`.refs/badlogic__pi-mono/packages/coding-agent/docs/rpc.md`, `src/modes/rpc/rpc-types.ts`). Commands (`prompt`, `steer`, `abort`, `compact`, `get_state`, ...) get `type: "response"` acks; agent events stream asynchronously as JSONL. The protocol is custom (not JSON-RPC), framing is strict LF-delimited JSONL (the docs explicitly warn that Node `readline` is non-compliant because it splits on `U+2028`/`U+2029`), and there is no capability handshake — the surface is fixed. It proves the "headless kernel + separate UI" split is the right shape, but it lacks the negotiation, framing rigor, and bidirectional request model that LSP/DAP/codex standardized on.

## Why VANTARI does it better

1. **Local-first single binary, one durable owner, one RPC method set.** Codex ships app-server, TUI, and exec as separate Rust crates that can also run in-process; Eve has no local client at all. VANTARI is one Zig binary: `vantari` (TUI), `run` (CLI), foreground `serve`, hidden `execution-owner`, and private `kernel-stdio` share one protocol definition. TUI/CLI exact routes and redacted browser routes call the same private kernel method set. Twenty concurrent clients converge on one source-built owner/kernel generation; client exit cannot destroy it.

2. **LSP-grade framing, not ad-hoc JSONL.** pi-mono's docs spend a section warning that `readline` corrupts its stream on Unicode line separators. VANTARI's `Content-Length` framing (`stdio_rpc.zig` `writeFrame`/`readFrame`) is byte-exact and binary-safe — the same framing LSP, DAP, and MCP chose. A base64 `chunk_b64` field in `tool_output_delta` carries arbitrary stdout bytes through the same frame without escaping concerns. This is why the TUI can render live command output without a parallel raw-pipe channel.

3. **The owned-state contract is already mechanically enforced for tools.** The single-keyed-row rule from AGENTS.md §IV is not aspirational — it is code. `addToolProgress` upserts by `tool_call_id`; `tool_started`/`tool_output_delta`/`tool_finished` all route through it; one invocation produces one mutating row. Codex achieves the same with `item.id` but bundles it into a much larger item taxonomy (agentMessage, reasoning, commandExecution, fileChange, mcpToolCall, collabToolCall, webSearch, ...). VANTARI's narrower, schema-versioned event structs (`var1.tool_started.v1`) keep the client renderer small while remaining forward-compatible.

4. **Durable reconciliation without polling tax.** The TUI does not trust the live notification stream alone and does not reread the full event array on an interval. It advances one exact stored sequence at a time, requests only the missing suffix when a gap appears, and performs one suffix check after turn completion. A duplicate stored sequence is inert; two identical payloads with different sequences both render. Codex's app-server live stream has no equivalent durable resume read.

5. **Untrusted output stays untrusted.** `tool_output_delta` carries `chunk_b64` + `cap_reached`; the TUI decodes, normalizes (`normalizeTerminalChunk`), truncates to `max_tool_output_payload_bytes`, and renders display text. No client parses stdout as commands, control sequences, or protocol. Codex streams `commandExecution.outputDelta` similarly but also lets `aggregatedOutput` accumulate without a hard client-side cap. VANTARI's bounded-preview discipline is directly traceable to AGENTS.md §IV: "Command stdout/stderr are untrusted data."

6. **The shipped TUI cursor is ledger-native today.** `waitForNotificationAfter(sequence)` remains only a per-process queue position. `var1.session_event_notification.v1.seq` and `session/get.after_seq` are the durable per-session identity and resume request. A browser-refresh cursor remains deferred until a tracked browser consumer exists. Codex and pi-mono still expose no comparable durable client resume token.

## Pipeline items under this theme

### P0-1: Stdio JSON-RPC protocol contract — typed capabilities and versioned notification schemas
- **Contract:** `initialize` returns a negotiated `Capabilities` plus an `event_schemas` list (the `var1.*.v1` versions the kernel emits). The client sends `client_info` (name, version, surface: `tui`/`cli`/`browser`/`desktop`) and an optional `consume_event_schemas` filter. A client that does not recognize a schema version must render it as opaque bounded text, never crash, never infer.
- **Mechanism:** extend `protocol.types.Capabilities` and `InitializeResult` in `apps/backend/src/shared/protocol/types.zig`; thread `client_info` through `handleInitialize` in `stdio_rpc.zig`. No new transport, no new framing. Mirror codex's `optOutNotificationMethods` as an exact-match suppression list so a browser can opt out of `tool_output_delta` if it does not want live stdout.
- **Test:** a client declaring `consume_event_schemas: ["var1.tool_started.v1"]` receives `tool_started` notifications but receives `tool_output_delta` only if it also lists that schema; an unknown schema on the wire is rendered as a bounded `[unknown event: <type>]` row without panic.
- **Proof:** `initialize` round-trip from TUI, CLI, and a test HTTP client all report the negotiated capability set; a schema bump (`var1.tool_started.v2`) coexists with v1 without breaking an older client.

### P1-1: Event-cursor-based client sync — monotonic ledger position, resumable across connections
- **Contract:** `session/get` and the `session/event` notification both carry the kernel-published monotonic `events.jsonl` sequence. The transport notification `sequence` remains queue-local; stored `seq` is the durable resume token.
- **Mechanism:** `appendEventWithSeq` returns writer identity; `var1.session_event_notification.v1` carries it after persistence; `session/get { after_seq, events_only }` returns only the suffix. The TUI owns `last_event_seq` and has no content-keyed replay cache.
- **Test:** two identical same-millisecond events render once each; replay of the second is inert. A live jump from sequence 1 to 3 first fetches the durable 2–3 suffix and preserves order.
- **Proof:** **closed for the tracked TUI.** Source lanes pass 59/59 and 1,936/1,936. Move 15 installed catch-up after sequence 1 returned exactly sequences 2–4; move 16's tool turn returned contiguous sequences 2–12 with byte-safe output deltas. Both exited with zero processes. Browser refresh remains open because this checkout ships no tracked browser consumer.

### P1-2: Tool span single-row update model — kernel-native span id, lifecycle as one row
- **Contract:** every tool invocation has one kernel-native `span_id` (distinct from the provider `tool_call_id`) that is stable across `tool_requested -> tool_reviewed -> tool_started -> tool_output_delta* -> tool_finished -> tool_completed`. Clients key the row on `span_id` and update it in place through the lifecycle; they never append a new row for the same span.
- **Mechanism:** add `span_id` to the event structs in `apps/backend/src/shared/protocol/events.zig` and the renderers in `loop.zig` (lines 755-849); default `span_id = tool_call_id` when the provider id is available, mint a kernel id when it is not. The TUI's `addToolProgress`/`appendToolProgress` already key on an id — switch the key from `tool_call_id` to `span_id`.
- **Test:** one tool invocation produces exactly one row whose text transitions `running -> <duration>ms` (or `error <name> <duration>ms`); the row count for N tool calls is N, not 3N. A tool with no provider id (kernel-internal) still gets a stable row.
- **Proof:** session/event evidence shows the full lifecycle under one `span_id`; the TUI row count equals the distinct `span_id` count.

### P1-3: Untrusted-output rendering rules — bounded display, no execution, cap markers surfaced
- **Contract:** `tool_output_delta` is the only channel for command stdout/stderr. Clients decode `chunk_b64`, render a bounded preview, surface `cap_reached` as a visible marker, and never interpret the bytes as control sequences, commands, or protocol. A configurable per-client `output_budget_bytes` caps accumulation.
- **Mechanism:** the bounds already exist in `tui_chat.zig` (`max_tool_output_payload_bytes`, `normalizeTerminalChunk`); promote them to named policy in `protocol.types` so CLI and browser apply the same limits. Add a `cap_reached` badge to the TUI row and a `--output-budget` flag to the CLI.
- **Test:** a tool that emits 1 MB of stdout produces a single bounded row with a `[cap]` marker; no ANSI escape in the output reaches the terminal as a control sequence; the CLI `--json` payload includes a truncated `output` with a `truncated: true` flag.
- **Proof:** adversarial stdout (embedded `Content-Length:` frames, ANSI bombs, NUL bytes, invalid UTF-8) renders as inert display text in TUI, CLI, and browser.

### P2-1: Browser/desktop client protocol reuse — one JSON-RPC surface, resumable SSE cursor
- **Contract:** the browser and any future desktop shell consume the identical `initialize` -> `events/subscribe` -> `session/*` protocol the TUI consumes. `GET /events` upgrades from long-poll snapshots to a resumable SSE stream keyed on `after_event_seq`; `POST /rpc` is unchanged.
- **Mechanism:** `renderEventSnapshotResponse` in `http_bridge.zig` (lines 367-384) becomes a streaming response that holds the connection open and emits `session/event` frames as they arrive, resumable by the `event_seq` cursor from P1-1. No new protocol method — the browser is just another `LocalClient` over SSE.
- **Test:** a browser tab opened mid-turn receives the full event replay from `after_event_seq=0`; a refresh resumes from the last rendered `event_seq` without loss; concurrent tabs each receive independent cursors.
- **Proof:** a minimal HTML/JS client drives a session end-to-end (create, send, stream, cancel) using only `POST /rpc` and `GET /events?after_event_seq=N`, with no client-side kernel logic.

## North-star link

This theme serves the north star (`01-sharded-context-windows.md`) by guaranteeing that every shard, branch, and convergence is observable from any client as a kernel-owned projection. Sharded context only matters if the operator can see the same causal chain the kernel will replay after cold start — and that visibility is this contract. It also serves the typed event grammar (AGENTS.md §IV, roadmap item 2), the tool execution spans (§V, item 3), the frontier TUI workbench (item 10), and the deep pipeline test mesh (item 13): none of those are real unless the client renders them from owned state rather than from its own guess. The client-kernel boundary is the seam that makes every other frontier item falsifiable.

## Definition of done
- `initialize` negotiates capabilities and event schema versions with every client surface (TUI, CLI, browser).
- Clients resume from a monotonic `event_seq` cursor; a dropped or reconnecting client receives exactly the missed events in causal order.
- One tool invocation renders as one keyed row across its full lifecycle in every client; row count equals distinct span count.
- Command stdout/stderr renders as bounded, sanitized display text in every client; no client executes or interprets output bytes.
- The browser consumes the same JSON-RPC + SSE-cursor protocol as the TUI; no second client API exists.
- No client assembles provider context, infers tool state, or maintains its own transcript truth. Cold-start replay from `events.jsonl` reproduces the live client frame sequence.
