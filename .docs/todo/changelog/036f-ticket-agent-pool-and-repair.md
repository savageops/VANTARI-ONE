---
id: 036f-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: f
status: done
patch_scope: "Carry the ticket/pool projection through the installed CLI, add integrated adversarial checks for buffered assignment and recovery, and prove the ReleaseFast Windows consumer path with child cleanup."
blast_radius: high
blast_radius_justification: "The slice crosses the canonical CLI health projection, ticket/scheduler integration tests, pinned ReleaseFast build, installed binary, workspace/config resolution, and process supervision evidence."
idempotency_contract: read-only
idempotency_notes: "Health and installed smoke probes are read-only; test fixtures use isolated workspace roots; installation uses the existing staged replacement and backup path."
acceptance: "Assignment remains queue-only through the runtime entrypoint; stale and terminal ticket recovery remain durable and replayable; health --json and the TUI expose the same canonical pool/ticket projection; the installed Windows binary serves the changed health path and leaves no child process behind."
exit_criterion: "Pinned ReleaseFast build and installed %LOCALAPPDATA%\\Vantari\\bin\\vantari.exe probes pass for help, health JSON, config validation, and a noninteractive TUI boundary; focused adversarial tests and process cleanup checks pass; unrelated broad-graph failures remain explicitly bounded."
validation: "C:\\Users\\Savage\\AppData\\Local\\Programs\\zig\\0.15.1\\zig.exe build --summary all; focused ticket/scheduler/RPC/TUI/CLI probes; apps/backend/scripts/install_windows.ps1; installed vantari.exe --help, health --json, config validate; exact-process cleanup check; git diff --check"
expected_exit_code: 0
expected_output_pattern: "Build Summary: 9/9 steps succeeded|focused adversarial probes passed|installed health JSON contains pool/ticket fields|no Vantari child remains|no whitespace errors"
evidence: "2026-08-10: pinned Zig 0.15.1 Debug build passed with Build Summary: 9/9 steps succeeded; canonical TUI artifact passed 53/53 tests; broad canonical test graph reached 1681/1684 with three unrelated pre-existing failures in runtime-loop/tool-prompt/schema-repair tests and a workspace-resolution child-process termination boundary. Added CLI health projection coverage, Supervisor-unavailable health coverage, queue-only session absence coverage, and replay-loser session failure evidence. The final ReleaseFast install_windows.ps1 run exited 0, installed C:\\Users\\Savage\\AppData\\Local\\Vantari\\bin\\vantari.exe, and reported matching built/installed SHA256 54496C7479C99C7E021247DC9D9F487541DCABF48FD9DC5BC41D4F24A082D179. Final installed --help, health --json, and config validate exited 0; health JSON parsed all 12 additive pool/ticket fields; health text showed agent_pool 0/6 and ticket pressure; noninteractive TUI exited 1 with typed TerminalUnavailable and left 0 exact-path VANTARI processes."
conflict_surface: "036e-ticket-agent-pool-and-repair; 035-provider-cost-compat-model"
invariants:
  - "I1: the real log_ticket path appends queue admission only; it does not create a session, provider request, or supervisor execution before scheduler claim."
  - "I5: stale lease recovery and terminal reconciliation append durable evidence that survives a fresh projection read."
  - "I7: installed CLI JSON and TUI values are projections of the same typed health response, not locally inferred ticket state."
  - "I8: user-facing proof runs through pinned Zig 0.15.1 and the installed Windows binary; WSL or source-only success is not promotion evidence."
  - "I11: health failure or poisoned ticket suffix is visible as an unhealthy/unknown boundary, never as a fabricated healthy zero."
  - "I12: a losing or replayed ticket claim cannot leave an initialized child session or duplicate Supervisor task; the loser is terminal with session_failed evidence."
source_message_anchor: "U1-U7"
source_message_excerpt: "setting to assigned shouldnt trigger an agent.; have config and a \"pool\" of engineers ready and waiting (agents); context size used, remaining, etc. model effort, etc. amount of agents running, etc.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Prove the new queue and operator telemetry through the real CLI/runtime boundary, retain recovery evidence, preserve the minimal footer, and leave no unverified installed-process residue."
entry_state: "036e is archived with typed health/RPC and bounded TUI projection; the CLI health parser still drops the additive pool/ticket fields and installed proof is outstanding."
rollback_surface: "Revert only the CLI health projection, integrated proof fixtures, and f-specific docs; preserve the 036a-036e ticket, supervisor, scheduler, RPC, and TUI owners."
dependencies: "036e-ticket-agent-pool-and-repair"
next_todo: /todo/pending/036g-ticket-agent-pool-and-repair.md
continuation: "On completion: capture exact outputs, set status done, move this file to /todo/changelog/036f-ticket-agent-pool-and-repair.md, continue immediately to 036g."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036f Integrated adversarial and installed proof

## Execute Now

Close the remaining consumer boundary for the buffered ticket plane. First make the CLI health read model lossless for the additive pool and ticket fields. Then exercise queue-only assignment, claim/recovery, terminal reconciliation, health projection, and the installed Windows binary through focused, adversarial probes.

## Slice Focus Rule

This unit owns integration proof and the installed consumer boundary. Do not add a second scheduler, worker pool, ticket registry, status bus, or autonomous repair mutator. Do not repair the three unrelated broad-graph failures unless a focused probe proves they intersect this slice; record them as residual boundaries instead.

## Owner Map

| Surface | Canonical owner | Required proof |
|---|---|---|
| Assignment | `core/tools/builtin/log_ticket.zig` -> `core/tickets` | Runtime admission changes ticket projection only; no session/provider/supervisor evidence appears. |
| Claim/recovery | `core/scheduler/service.zig` -> `core/tickets` + `core/sessions` | Requeue, heartbeat, terminal completion, and repair-required evidence survive a fresh read. |
| Health transport | `host/stdio_rpc.zig` + `shared/protocol/types.zig` | RPC fields and unhealthy boundaries are serialized from canonical owners. |
| Installed CLI | `clients/cli.zig` | `health --json` preserves every additive pool/ticket field; text output names useful pressure without clutter. |
| Installed binary | `scripts/install_windows.ps1` -> `%LOCALAPPDATA%\\Vantari\\bin\\vantari.exe` | ReleaseFast binary responds to help/health/config and leaves no exact-path child process. |

## Required Cases

- The CLI parser preserves pool max/queued/running/available and all ticket count/health fields from `health_get` JSON.
- `health --json` remains backward-tolerant for older responses through defaults and ignores unrelated future fields.
- Assignment through the canonical ticket tool remains side-effect free before a scheduler tick.
- A scheduler tick dispatches only when the existing Supervisor reports capacity; a full pool leaves the ticket assigned and durable.
- An expired claim produces a stale requeue with the prior session identity preserved for diagnosis.
- A terminal successful session completes the ticket once; repeated reconciliation is idempotent.
- A failed/cancelled terminal session marks repair-required evidence and does not silently close the ticket.
- A poisoned ticket suffix preserves valid-prefix counts and reports unhealthy/unknown telemetry.
- Installed `vantari.exe --help`, `health --json`, and `config validate` run through the user-facing executable.
- A noninteractive installed TUI invocation fails at the typed terminal boundary and leaves no `vantari.exe` child behind.
- The installed health JSON includes pool/ticket fields and matches the local runtime schema.
- `git diff --check` remains clean apart from known line-ending normalization warnings.

## Validation Plan

| Step | Command / probe | Expected |
|---|---|---|
| 1 | Pinned source build with Zig 0.15.1 | `Build Summary: 9/9 steps succeeded`. |
| 2 | Focused ticket/scheduler/RPC/TUI/CLI source probes with isolated `VANTARI_HOME` | All selected adversarial cases pass; temporary probes are removed. |
| 3 | `apps/backend/scripts/install_windows.ps1` | ReleaseFast staged install succeeds at the canonical installed path. |
| 4 | Installed `vantari.exe --help`, `health --json`, `config validate` | Exit 0; health JSON includes pool/ticket telemetry. |
| 5 | Installed noninteractive TUI boundary and exact process-path check | Typed terminal failure is bounded; no child process remains. |
| 6 | `git diff --check` and broad graph boundary | Exit 0; exact unrelated failures are named if still present. |

## Completion

- [x] CLI health parser and text projection carry additive pool/ticket fields.
- [x] Integrated adversarial cases pass through canonical owners.
- [x] Pinned source build passes.
- [x] Installed Windows binary proof passes, including process cleanup.
- [x] Implementation-unit test floor is satisfied with 53 TUI cases plus canonical ticket/scheduler/RPC/CLI coverage.
- [x] Evidence captured; `PLACEHOLDER` removed.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036f-ticket-agent-pool-and-repair.md`.
- [x] Continued immediately to `036g`.

## Residual Boundaries

- The broad graph remains partial at 1681/1684 because three unrelated pre-existing tests fail; no 036f owner path depends on those assertions.
- The separate recursive source probe reaches const-correctness errors in `core/sessions/summaries.zig`; it was removed after proving it was broader than the canonical build path.
- The installer migrated the existing invalid user config and preserved a timestamped backup; this is an intentional installed-path mutation, not a silent overwrite.

## Original User Message Proof

- U1: “setting to assigned shouldnt trigger an agent.”
- U2: “have config and a \"pool\" of engineers ready and waiting (agents)”
- U3: “an agent that is most relevant expertise/skill should pick up the task”
- U4: “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.”
- U5: “agents that pick up a ticket, may use explore, tools, and research/plan agents.”
- U6: “context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.”
- U7: “Apply this to vantari. leave the code better than you find it. whenever you look at it”
