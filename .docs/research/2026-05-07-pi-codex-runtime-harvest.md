# 2026-05-07 Pi/Codex Runtime Harvest

## Scope

Reference pass over `.refs/badlogic__pi-mono` and `.refs/openai__codex` for VAR1 runtime hardening. The objective is not framework mimicry. The objective is smaller kernel invariants with stronger evidence.

## Reference Findings

| Reference | Durable invariant | VAR1 decision |
| --- | --- | --- |
| Pi agent context flow | Runtime state can include UI-only messages, but provider context must pass through one conversion boundary before every model call. | Keep VAR1's context builder as the single owner of model-visible messages; do not let host, CLI, or adapters assemble history. |
| Pi event flow | Message, tool, turn, and agent events are progress surfaces; tool-result persistence still follows assistant source order even when execution completion order differs. | Preserve `messages.jsonl` as the source-order transcript and `events.jsonl` as append-only progress evidence. Add a multi-tool pipeline test before any future parallel tool execution. |
| Pi continue guard | A continuation is valid only when the model-visible tail is actionable, not an unresolved assistant tool request. | Keep stale running-session reconciliation as the runtime gate; do not auto-resume orphaned tool-call turns without explicit user input and transcript evidence. |
| Codex app-server | Thread, turn, and item are typed lifecycle boundaries; clients consume `item/started`, `item/completed`, and terminal turn state rather than inferring state from partial text. | Keep VAR1 session summaries status-derived and event-backed. Do not introduce broad item graphs until a client needs them. |
| Codex in-process client | Bounded queues return overload behavior instead of unbounded growth. | Treat future bridge streams as bounded transport contracts; no invisible queue growth or background fanout. |
| Codex rollout trace | Hot-path code writes ordered raw events and payload references; semantic reduction happens later. | Keep `.var/sessions/<id>/events.jsonl` and message/context ledgers append-only; avoid hot-path graph builders or diagnostic systems fatter than execution. |

## Adopt / Adapt / Reject

Adopt:
- Source-order persistence for assistant tool batches.
- Explicit progress evidence before and after side effects.
- One context-builder boundary for provider messages.
- Bounded transport behavior for future streaming clients.

Adapt:
- Pi's event taxonomy maps to VAR1's smaller event names, not a copied agent event hierarchy.
- Codex thread/turn/item maps to VAR1 session/message/event/checkpoint primitives until the UI requires finer-grained item objects.
- Rollout-trace reduction maps to offline diagnostics only; the runtime path remains append-only writes.

Reject:
- Parallel tool execution as a default runtime feature today. It requires cancellation, idempotency, side-effect isolation, and source-order transcript proof under concurrent completion.
- Large plugin or app-server surfaces without immediate customer-facing leverage.
- Any compatibility reader for pre-`.var/sessions` storage.

## Shipped Hardening

Added `loop persists multi-tool batches in assistant source order before follow-up context`. The test forces a single assistant response to request two tools, verifies the follow-up provider payload contains tool messages in assistant source order, verifies durable transcript order, and verifies progress events precede the final assistant response.

This is the current highest-leverage correction because it pins the invariant that protects future tool execution upgrades without adding architecture mass.
