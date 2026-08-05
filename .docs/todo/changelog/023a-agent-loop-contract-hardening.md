---
id: 023a-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: a
role: "Baseline and contract lock"
depends_on: []
next_todo: /todo/pending/023b-agent-loop-contract-hardening.md
---
# 023a Baseline And Contract Lock

## Objective

Freeze the implementation boundary before edits: only the live backend lane under `apps/backend/variant-1` is in scope, and the five findings are addressed without introducing a second transcript, second tool registry, second bridge, or second settings source.

## Patch Surface

- `.docs/todo/pending/023*.md`
- No runtime code in this slice.

## Evidence

- `apps/backend/variant-1/src/shared/types.zig` currently has provider `MessageRole.tool` but durable `SessionMessageRole` only has `user` and `assistant`.
- `apps/backend/variant-1/src/core/executor/loop.zig` appends tool turns only to the in-memory provider array before final output persistence.
- Tool builtin parsers use `std.json.parseFromSlice(..., .{ .ignore_unknown_fields = true })`.
- `apps/backend/variant-1/src/host/http_bridge.zig` accepts a connection and calls `handleConnection` inline.
- `apps/backend/variant-1/src/core/config/settings.zig` strips comments with a blind first-`#` slice.

## Completion Criteria

- Parent and all lettered execution units exist.
- The next implementation slice can proceed without further architectural discovery.
