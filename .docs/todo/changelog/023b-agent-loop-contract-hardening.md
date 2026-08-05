---
id: 023b-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: b
role: "Strict tool ingress"
depends_on: [023a-agent-loop-contract-hardening]
next_todo: /todo/pending/023c-agent-loop-contract-hardening.md
---
# 023b Strict Tool Ingress

## Objective

Make runtime tool JSON parsing enforce the same closed-object contract advertised through every tool schema that declares `additionalProperties: false`.

## Patch Surface

- `apps/backend/variant-1/src/core/tools/builtin/*.zig`
- `apps/backend/variant-1/src/core/tools/workspace_runtime.zig`
- `apps/backend/variant-1/src/core/tools/runtime.zig`
- `apps/backend/variant-1/tests/tools_test.zig`

## Contract

- Unknown tool arguments must fail before side effects.
- Tool error payloads must classify unknown fields as schema-repair failures and include the declared schema.

## Validation

- Add a test that `write_file` with an undeclared field returns an unknown-field parse error.
- Existing file-tool and workspace-state tests remain green.
