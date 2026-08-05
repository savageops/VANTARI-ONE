---
id: 023d-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: d
role: "Independent tool budgets"
depends_on: [023c-agent-loop-contract-hardening]
next_todo: /todo/pending/023e-agent-loop-contract-hardening.md
---
# 023d Independent Tool Budgets

## Objective

Split provider turn budgeting from tool-effect budgeting so one assistant response cannot compress unbounded side effects into a single step.

## Patch Surface

- `apps/backend/variant-1/src/shared/types.zig`
- `apps/backend/variant-1/src/core/config/resolver.zig`
- `apps/backend/variant-1/src/core/executor/loop.zig`
- `apps/backend/variant-1/tests/core_store_test.zig`
- `apps/backend/variant-1/tests/runtime_loop_test.zig`

## Contract

- Config exposes `max_tool_calls_per_turn` and `max_tool_calls_per_session`.
- Defaults are explicit and conservative enough for the existing six-operation adherence benchmark.
- Budget exhaustion fails before executing side effects and marks the session failed with `ToolBudgetExceeded`.

## Validation

- Env parser reads both new budget keys.
- A runtime-loop test proves a batch over the per-turn budget fails before tool execution.
