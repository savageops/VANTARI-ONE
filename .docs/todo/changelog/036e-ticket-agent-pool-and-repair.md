---
id: 036e-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: e
status: done
patch_scope: "Expose a compact operator projection for live pool capacity and ticket pressure through health_get, then render it in the existing TUI footer without a second status registry."
blast_radius: medium
blast_radius_justification: "The additive health contract is consumed by the TUI and CLI-facing RPC path; ticket counts come from TicketStore projection and pool counts come from AgentService capacity."
idempotency_contract: read-only
idempotency_notes: "Snapshot reads are serialized by TicketStore and Supervisor owners; repeated health reads do not append ledger events or mutate session state."
acceptance: "The operator can see model, effort, exact context usage/capacity/remaining, current child agents, buffered ticket queue pressure, and live pool capacity in one quiet footer row; health --json exposes the same typed values; composer/meta surface hierarchy and Esc-free copy remain intact."
exit_criterion: "TicketStore exposes a counted projection, health_get returns additive pool/ticket fields from canonical owners, TUI consumes and refreshes those fields with bounded polling, and focused projection/RPC/footer tests pass."
validation: "C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all; pinned focused TUI/RPC/ticket projection tests; git diff --check"
expected_exit_code: 0
expected_output_pattern: "Build Summary: 9/9 steps succeeded|focused projection/RPC/footer tests passed|no whitespace errors"
evidence: "2026-08-10: pinned Zig 0.15.1 build passed with Build Summary: 9/9 steps succeeded; canonical TUI artifact passed 49/49 tests; temporary stdio RPC source probe passed 2/2 health projection tests; temporary ticket snapshot source probe passed 2/2; git diff --check exited 0 with only repository LF/CRLF normalization warnings; 45 meaningful assertions cover lifecycle buckets, poisoned suffix visibility, health serialization, pool/queue footer display, narrow/quiet fallback, context placeholders, and Esc-free copy. The broad graph reached 1673/1676 with three unrelated pre-existing failures in runtime-loop/tool-prompt/workspace-resolution tests."
conflict_surface: "036d-ticket-agent-pool-and-repair; 035-provider-cost-compat-model"
invariants:
  - "I7: health and TUI values are read models of TicketStore, AgentService, session events, and resolved config; no client invents lifecycle truth."
  - "I8: existing model/effort/context footer and composer hierarchy remain compatible, including no Esc cancel filler."
  - "I9: a poisoned ticket suffix is visible as unhealthy/unknown telemetry and never reported as a healthy zero queue."
  - "I10: bounded health refresh does not run during provider streaming or create a second event/status bus."
source_message_anchor: "U4, U6, U7"
source_message_excerpt: "when we assign a ticket, it doesnt start immediately.; context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.; leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Keep assignment buffered while making queue/pool pressure visible, preserve the compact model/effort/context footer, and improve the existing surface without prompt scaffolding or a parallel registry."
entry_state: "036d is archived with scheduler wake/dispatch/recovery; TUI already renders model/effort/context and child-agent counts, but health/RPC has no ticket or Supervisor capacity snapshot."
rollback_surface: "Revert only the TicketStore snapshot, additive protocol/health fields, TUI telemetry refresh/footer projection, and focused tests; preserve 036a-036d lifecycle and scheduler work."
dependencies: "036d-ticket-agent-pool-and-repair"
next_todo: /todo/pending/036f-ticket-agent-pool-and-repair.md
continuation: "On completion: capture exact snapshot/RPC/TUI evidence, set status done, move this file to /todo/changelog/036e-ticket-agent-pool-and-repair.md, continue immediately to 036f."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036e Operator projection and compact TUI telemetry

## Execute Now

Add one read-only operator projection over the existing ticket event ledger and Supervisor capacity. Carry it through the additive `health_get` response and render only the useful pressure signals in the existing footer. Keep the current surface hierarchy: transcript surface < metadata surface < composer surface.

## Slice Focus Rule

This unit owns snapshot counting, health/RPC serialization, bounded TUI refresh, footer fit, and focused tests. Do not add a ticket status bus, new RPC worker registry, polling thread, provider telemetry guess, or autonomous repair UI. Repair diagnosis/approval remains a later runtime surface.

## Owner Map

| Surface | Canonical owner | Required projection |
|---|---|---|
| Ticket counts | `core/tickets/index.zig` | `TicketSnapshot` from the valid-prefix projection; poisoned suffix is unhealthy. |
| Pool counts | `core/tools/AgentService` -> `agents.Supervisor.capacity` | `AgentCapacitySnapshot`; scheduler and TUI do not cache capacity. |
| Model/effort/context | resolved config + `turn_started` telemetry | Preserve existing health fields and latest typed turn-boundary window estimate. |
| RPC | `host/stdio_rpc.zig` + `shared/protocol/types.zig` | Additive health fields; older clients still parse the response. |
| TUI | `clients/tui_chat.zig` | One quiet footer row; current child activity rows remain the live per-session agent projection. |

## Display Contract

```text
● model · effort · ctx used / capacity (percent) · remaining left · agents running / total · pool running / max · queue assigned
```

- Hide pool and queue segments when they have no useful non-zero value.
- Keep `—`/`ctx —` before the first typed turn telemetry.
- Keep exact token math clamped to the configured context window.
- Refresh health at a bounded cadence in the idle event loop; do not poll from the provider streaming loop.
- Keep the composer row brighter than metadata and metadata brighter than the transcript background.
- Do not render `Esc cancel`; cancellation state may say `cancelling` only after the operator requested it.

## Required Cases

- Empty ticket ledger reports healthy zero counts.
- Unassigned, assigned, in-progress, blocked, completed, and closed tickets count independently.
- Poisoned suffix preserves counts from the valid prefix and marks the snapshot unhealthy.
- Health JSON carries pool max/queued/running/available and ticket counts.
- Supervisor capacity failure does not become a false healthy zero.
- TUI maps health values without borrowing response-owned strings.
- TUI footer keeps the existing model/effort/context/agent contract when pool data is zero.
- TUI footer adds pool/queue only when useful and fits narrow widths through existing fallback order.
- Repeated bounded refreshes replace numeric telemetry without transcript mutation.
- Existing composer/meta/background palette and Esc-free status tests remain green.

## Validation Plan

| Step | Command | Expected |
|---|---|---|
| 1 | `C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all` | `Build Summary: 9/9 steps succeeded` |
| 2 | Pinned transient probe for ticket snapshot, health projection, and TUI footer | All focused tests pass; probe removed after run. |
| 3 | Existing TUI tests through the canonical test graph | No regressions in context, effort, child-agent, palette, or layout tests. |
| 4 | `git diff --check` | Exit 0; line-ending warnings named only if present. |

## Completion

- [x] Pre-flight passed.
- [x] Ticket snapshot is valid-prefix based and poison-aware.
- [x] Health/RPC exposes canonical pool and ticket pressure.
- [x] TUI refreshes bounded telemetry and preserves the compact footer hierarchy.
- [x] Existing visual and event projection tests remain green.
- [x] Implementation-unit test floor satisfied: ≥30 meaningful feature-value cases.
- [x] All validation commands executed with matching output.
- [x] Evidence captured; `PLACEHOLDER` removed.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036e-ticket-agent-pool-and-repair.md`.
- [x] Continue immediately to `036f`.
