---
id: 023f-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: f
role: "Settings parser fidelity"
depends_on: [023e-agent-loop-contract-hardening]
next_todo: /todo/pending/023g-agent-loop-contract-hardening.md
---
# 023f Settings Parser Fidelity

## Objective

Make the small `.var/config/settings.toml` parser truthful for the supported subset instead of pretending blind line splitting is TOML.

## Patch Surface

- `apps/backend/variant-1/src/core/config/settings.zig`
- `apps/backend/variant-1/tests/core_store_test.zig`

## Contract

- `#` starts a comment only outside a quoted string.
- Prompt path values are quoted TOML strings with basic escape handling.
- Unknown policy keys remain fail-closed.
- Absolute prompt paths remain rejected.

## Validation

- Add tests for a quoted prompt path containing `#`.
- Existing context and prompt policy tests remain green.
