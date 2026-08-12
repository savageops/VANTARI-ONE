---
id: 036g-ticket-agent-pool-and-repair
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: g
status: done
patch_scope: "Perform the terminal ownership, regression, installed-proof, documentation, and source-message audit for the buffered ticket pool and repair projection chain."
blast_radius: high
blast_radius_justification: "Review spans every changed owner in the chain, the installed Windows consumer, durable planning records, and the explicit broad-test boundary."
idempotency_contract: read-only
idempotency_notes: "QC reads source, ledgers, docs, hashes, process state, and existing test outputs; it does not mutate runtime state or install a new binary."
acceptance: "Every original user obligation has a canonical owner and proof; no parallel pool/status bus or prompt-only behavior exists; the installed client and TUI expose truthful state; residual failures are named with next probes; the chain can close cold-start ready."
exit_criterion: "All 036a-036g artifacts are archived, the parent is complete, changed source owners pass audit and diff check, installed binary hash/process proof remains valid, docs/changelog carry exact evidence, and no unresolved 036 defect remains."
validation: "ix ownership/source audit; pinned build/test evidence readback; installed hash and process check; git diff --check; parent/changelog readback"
expected_exit_code: 0
expected_output_pattern: "036a-036g archived|no duplicate ticket/pool/status owner|installed hash matches|0 exact installed processes|diff check exit 0|status complete"
evidence: "2026-08-10: terminal QC passed. `ix` found one canonical `.var/tickets/tickets.jsonl` source owner under `core/tickets`; capacity remains owned by the existing AgentService/Supervisor path; RPC, CLI, and TUI consume the additive typed health projection; `Esc cancel` appears only in negative tests and not in production copy. Pinned Zig 0.15.1 app build passed 9/9, canonical TUI passed 53/53, and the broad graph reached 1681/1684 with only the three named pre-existing runtime-loop/tool-prompt/schema-repair failures. Installed `C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe` health exposed all 12 additive fields, pool 0/6 with 6 available, and a healthy ticket ledger; help, health, and config validation exited 0. Correct noninteractive TUI invocation `vantari -c` exited 1 with typed `TerminalUnavailable`; exact installed process count was 0; built and installed SHA256 matched `54496C7479C99C7E021247DC9D9F487541DCABF48FD9DC5BC41D4F24A082D179`; `git diff --check` exited 0 with only line-ending warnings; no temporary probe remained."
conflict_surface: "036f-ticket-agent-pool-and-repair; 035-provider-cost-compat-model"
invariants:
  - "I1: assignment is queue admission only; provider/session execution begins at scheduler claim."
  - "I4: all ticket execution enters through the configured AgentService and existing Supervisor."
  - "I5: stale, terminal, repair, and claim-replay boundaries have durable evidence."
  - "I7: RPC, CLI, and TUI render canonical projections rather than inventing ticket state."
  - "I8: installed Windows proof and process cleanup remain part of completion."
source_message_anchor: "U1-U7"
source_message_excerpt: "setting to assigned shouldnt trigger an agent.; have config and a \"pool\" of engineers ready and waiting (agents); context size used, remaining, etc. model effort, etc. amount of agents running, etc.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Review the complete implementation against queue-only assignment, buffered configured capacity, expertise routing, persistent lifecycle/recovery, operator telemetry, and the quality ratchet."
entry_state: "036f is archived with pinned build, TUI, broad boundary, installed health/config/TUI proof, exact hash, and process cleanup evidence; the parent still needs terminal QC."
rollback_surface: "No implementation rollback is expected. If QC finds a defect, create a focused repair unit that names the exact owner and preserves all archived evidence."
dependencies: "036f-ticket-agent-pool-and-repair"
next_todo: NONE
continuation: "Closed: this QC record is archived; the parent chain remains complete with stop condition NONE and no next todo."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036g Terminal QC and closeout

## Execute Now

Audit the implementation as a skeptical maintainer. Read the archived 036a-036f records, parent manifest, changed owner files, installed proof, and current worktree boundary. Confirm that each user request maps to one canonical mechanism and one durable evidence path.

## Review Gates

- `core/tickets` is the only ticket lifecycle owner; `log_ticket` is a thin adapter.
- `assigned` creates no session/provider/supervisor evidence; scheduler claim does.
- `AgentService` and the existing `Supervisor` remain the only execution/capacity authority.
- Scheduler lease, heartbeat, stale requeue, terminal reconciliation, and repair gate survive cold-start projection.
- RPC, CLI, and TUI share additive typed health fields; pool/ticket failure is explicit, not a healthy zero.
- TUI hierarchy remains transcript < metadata < composer, and no `Esc cancel` filler returns.
- Installed `%LOCALAPPDATA%\\Vantari\\bin\\vantari.exe` proof, hash equality, typed noninteractive boundary, and exact process cleanup remain evidenced.
- All original message anchors U1-U7 appear in the unit records and final conclusion.
- `.docs/todo/changelog/_log.md` and the parent manifest point to the same completed state.

## Required Readback

| Evidence | Expected |
|---|---|
| Chain manifest | 036a-036f archived; only 036g pending. |
| Build/test | Pinned 0.15.1 app build 9/9; TUI 53/53; broad 1681/1684 with only named unrelated failures. |
| Installed consumer | Health JSON has 12 additive fields; config/help pass; TUI returns `TerminalUnavailable`; zero exact installed processes. |
| Worktree | `git diff --check` exit 0; no temporary probe; no new duplicate owner. |
| Documentation | Research, changelog, parent, and archived unit evidence are readable and exact. |

## Completion

- [x] Ownership and duplicate-system audit passes.
- [x] User-message anchor and evidence audit passes.
- [x] Installed/hash/process proof readback passes.
- [x] Docs/changelog/parent readback passes.
- [x] Status set to `done`.
- [x] Moved to `/todo/changelog/036g-ticket-agent-pool-and-repair.md`.
- [x] Parent marked complete with `Stop Condition: NONE`.

## Original User Message Proof

- U1: “setting to assigned shouldnt trigger an agent.”
- U2: “have config and a \"pool\" of engineers ready and waiting (agents)”
- U3: “an agent that is most relevant expertise/skill should pick up the task”
- U4: “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.”
- U5: “agents that pick up a ticket, may use explore, tools, and research/plan agents.”
- U6: “context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.”
- U7: “Apply this to vantari. leave the code better than you find it. whenever you look at it”
