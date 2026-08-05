---
id: 023c-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: c
role: "Durable tool transcript"
depends_on: [023b-agent-loop-contract-hardening]
next_todo: /todo/pending/023d-agent-loop-contract-hardening.md
---
# 023c Durable Tool Transcript

## Objective

Persist assistant tool-call turns and tool-result turns as first-class `messages.jsonl` rows, then teach the context builder to replay them into provider-ready messages.

## Patch Surface

- `apps/backend/variant-1/src/shared/types.zig`
- `apps/backend/variant-1/src/core/sessions/store.zig`
- `apps/backend/variant-1/src/core/context/builder.zig`
- `apps/backend/variant-1/src/core/executor/loop.zig`
- `apps/backend/variant-1/tests/runtime_loop_test.zig`

## Contract

- Durable message roles include `tool`.
- Assistant tool-call records preserve the model-emitted call id, tool name, and raw arguments JSON.
- Tool-result records preserve `tool_call_id` and exact content returned to the model.
- Context replay must restore assistant tool calls before their corresponding tool results.

## Validation

- Tool-loop test reads `messages.jsonl` and asserts the sequence includes `assistant(tool_calls)`, `tool`, and final `assistant`.
- Resume/context payload continues to contain provider-visible `role:"tool"`.
