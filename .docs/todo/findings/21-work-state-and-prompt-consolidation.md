---
type: finding
id: harness-finding-21
status: completed
priority: P1
owner: apps/backend/src/core/tools/workspace_runtime.zig
source: ../../research/2026-08-14-ticket-only-work-lifecycle.md
---

# Work-state and prompt consolidation

## Finding

Tickets are now the only work lifecycle. The retired `todo_slice` and
`session_record` tools, `.var/todos` projection, per-session `session.md`
projection, and automatic generic docs-sync writer were removed. Summaries
remain bounded handoff state; plans, research, advice, roadmap, and changelog
remain durable ticket-linked artifacts. Native provider schemas remain API truth.

## Evidence

- The pre-change isolated broad failure expected `todo_slice` to be absent, but it was present in the provider payload.
- Move 25 removed `auto_assign`, `proactive_workpool`, `close_authority`, and
  `reopen_with_reasoning`, their loader/validation, and false public examples.
- Direct create-as-assigned and transition-to-assigned probes retain two queued
  tickets with zero claims, active sessions, or session records. The canonical
  graph passes 1,933/1,933.
- `workspace_runtime.zig` now exposes `log_ticket`, `update_session_summary`, and
  `changelog_ledger` without the retired lifecycle schemas.
- `loop.zig`, `agents/service.zig`, `agents/supervisor.zig`, and `executor/batch.zig`
  no longer write generic docs projections; `events.jsonl` and
  `sessions/summaries.jsonl` remain the runtime evidence/handoff owners.

## Required mechanism

Make tickets the only work lifecycle. Keep summaries as handoff state and plans/research/changelog as ticket-linked artifacts. Keep native tool schema as API truth and inject only compact policy deltas; demand-load examples, availability detail, and skill capsules. Keep the removed ticket policy deleted.

## Closure receipt

- One work item has one ticket identity and one terminal state.
- Assignment remains side-effect-free queue admission. **Current receipt:** both
  assignment paths create zero claims and zero sessions.
- No provider payload contains `todo_slice` or `session_record` lifecycle tools.
- `init_workspace` no longer creates `.var/todos`; old user data is not deleted.
- Full source proof passes `19/19` steps and `2,150/2,150` tests; source
  ReleaseFast is the remaining promotion gate for this slice.
- Schema-repair, catalog, file-role, and provider-payload tests assert current
  behavior rather than stale prose.
- No config key is documented without a runtime consumer. `agent_routes.max_concurrency`
  remains the sole capacity setting.

## Source and salvage

- [pi](https://github.com/earendil-works/pi): demand-loaded skills and code-owned context lifecycle.
- [OpenAI Codex](https://github.com/openai/codex): segment-per-concern context and compact plan state.

## Out of scope

Do not remove durable research, plan, summary, or changelog artifacts; remove only parallel lifecycle ownership.
