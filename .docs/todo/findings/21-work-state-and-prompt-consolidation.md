---
type: finding
id: harness-finding-21
status: pending
priority: P1
owner: apps/backend/src/core/prompts
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Work-state and prompt consolidation

## Finding

Tickets are named as canonical work state, but todo_slice, session_record, .var/todos, and changelog remain independent model-facing lifecycle surfaces. Ticket config includes policy knobs that do not govern scheduler behavior. The prompt also renders a full text tool catalog while native provider schemas carry the same tools.

## Evidence

- The isolated broad failure expects todo_slice to be absent, but it is present in the provider payload.
- default.json documents auto_assign as starting a specialist on assignment, contradicting queue-only admission.
- auto_assign, proactive_workpool, close_authority, and reopen_with_reasoning have no execution-state consumer.
- [prompts/builder.zig:84](../../../apps/backend/src/core/prompts/builder.zig#L84) renders the text catalog.
- [loop.zig:1017](../../../apps/backend/src/core/executor/loop.zig#L1017) also sends native tool definitions.

## Required mechanism

Make tickets the only work lifecycle. Keep summaries as handoff state and plans/research/changelog as ticket-linked artifacts. Remove dead policy keys or wire them into the one scheduler state machine. Keep native tool schema as API truth and inject only compact policy deltas; demand-load examples, availability detail, and skill capsules.

## Acceptance

- One work item has one ticket identity and one terminal state.
- Assignment remains side-effect-free queue admission.
- No provider payload contains todo_slice or session_record lifecycle tools.
- Prompt size drops measurably without reducing tool-call success.
- Schema-repair and file-role guidance tests assert current behavior rather than stale prose.
- No config key is documented without a runtime consumer.

## Source and salvage

- [pi](https://github.com/earendil-works/pi): demand-loaded skills and code-owned context lifecycle.
- [OpenAI Codex](https://github.com/openai/codex): segment-per-concern context and compact plan state.

## Out of scope

Do not remove durable research, plan, summary, or changelog artifacts; remove only parallel lifecycle ownership.
