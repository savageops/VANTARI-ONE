---
id: 036h-ticket-agent-pool-and-repair-terminal-review
parent: 036-ticket-agent-pool-and-repair
type: execution-unit
protocol_version: "3.0"
category: feature
phase: h
status: done
patch_scope: "Perform the post-reopen terminal review of the ticket pool, persistent owner, scheduler recovery, mailbox, operator projection, and installed Windows consumer path."
blast_radius: high
blast_radius_justification: "Review spans every reopened 036 owner, the installed binary, durable ledgers, source graph, process cleanup, and current planning records; it makes no runtime mutation."
idempotency_contract: read-only
idempotency_notes: "The review rereads durable evidence and reruns bounded validation probes; proof roots are isolated and the installed artifact is already hash-matched."
acceptance: "The reopened 036 chain has one canonical owner per capability, source and installed hashes match, the installed lifecycle mesh proves no lost or duplicate delivery, all terminal and repair boundaries are evidenced, the source graphs are green, and no unresolved 036 defect remains."
exit_criterion: "The installed lifecycle, owner lifecycle, owner tracer, source graph, focused TUI graph, duplicate audit, process census, parent manifest, finding ledger, roadmap, and changelog all read back as complete; 036h is archived and the parent is archived immediately after it."
validation: "prove-ticket-lifecycle.ps1 against the installed binary; prove-owner-lifecycle.ps1; prove-owner-tracer.ps1; zig build test; zig build test-tui; SHA-256/process census; ix ownership audit; git diff --check; JSON/docs readback"
expected_exit_code: 0
expected_output_pattern: "artifact_kind=installed|post_shutdown_readback=true|final_zero_processes=true|20/20|1953/1953|61/61|hash match|zero exact duplicates|diff check exit 0"
evidence: "2026-08-13/14 terminal review: installed ticket lifecycle proof passed at `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9` with artifact_kind=installed, binary SHA-256 `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`, one claim, one resume, one completion, two nested children, one direct/group/parent message each, six unique received messages, zero transcript copies, post_shutdown_readback=true, and final_zero_processes=true. Installed owner lifecycle passed 20/20 clients, graceful and forced recovery, three generations, and final_zero_processes=true at `.zig-cache/owner-proofs/9cc5d7b8a1624e49937cb3b78716e1bb`. Installed owner tracer passed reconnect_same_generation=true and owner_alive_after_two_clients=true at `.zig-cache/owner-proofs/65df1918745748ae9736cd9ba438fb13`. Debug graph passed 19/19 steps and 1953/1953 tests; focused TUI graph passed 9/9 steps and 61/61 tests. The 10-file/139-segment GGUF audit found six candidates and zero exact duplicates. Source and installed hashes match; installed VANTARI process census is zero."
conflict_surface: "035-provider-cost-compat-model; future Moves 32-90"
invariants:
  - "I1: assignment is queue admission only; provider/session execution begins at scheduler claim."
  - "I2: one serialized claim owns ticket revision, lease, generation, attempt, capability, and child identity."
  - "I4: all ticket execution enters through the configured AgentService and existing Supervisor."
  - "I5: stale, terminal, repair, and claim-replay boundaries have durable evidence."
  - "I6: completed and closed remain distinct; repair closure requires approval, exact rerun, and regression evidence."
  - "I7: RPC, CLI, and TUI render canonical projections rather than inventing ticket state."
  - "I8: installed Windows proof and process cleanup remain part of completion."
source_message_anchor: "U1-U7"
source_message_excerpt: "setting to assigned shouldnt trigger an agent.; have config and a \"pool\" of engineers ready and waiting (agents); context size used, remaining, etc. model effort, etc. amount of agents running, etc.; Apply this to vantari. leave the code better than you find it. whenever you look at it"
source_message_proof_obligation: "Re-review the complete implementation through the real installed owner path and close only when buffered admission, configured persistence, agent communication, recovery, terminal repair evidence, operator visibility, and the quality ratchet are all undeniable."
entry_state: "036g is historical and the parent is reopened; Move 30 source proof is complete; the current ReleaseFast artifact is installed only after the operator-owned pair exits; installed/source hash equality is required before this review."
rollback_surface: "No implementation rollback is expected. If any review gate fails, leave 036h pending, record the exact failing owner and evidence, add the smallest focused fix/re-review unit, and preserve all prior proof roots."
dependencies: "036g-ticket-agent-pool-and-repair; roadmap moves 21-30"
next_todo: NONE
continuation: "Archive 036h immediately after evidence readback; then mark the 036 parent complete and archive it. Continue at roadmap Move 32 only after the parent filesystem state is verified."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---
# 036h Terminal Review — Installed Ticket Pool and Repair

## Execute Now

Perform the final post-reopen review across the canonical ticket, supervisor, scheduler, session/event, TUI, owner, and installed binary paths.

## Review Verdict

**PASS — 036 is complete.** The source and installed ReleaseFast artifacts are
the same binary. Assignment remains queue-only; one process-serialized claim
materializes one deterministic child; owner loss produces one generation-fenced
same-session resume; nested agents communicate through the existing event-spine
mailbox; terminal failure/cancellation remains repair-required; and the installed
consumer leaves no proof-owned process behind.

No second ticket registry, worker pool, scheduler, mailbox, status bus, prompt
executor, or repair owner was found. The only new Move 30 artifact is a composed
proof tracer; the runtime remains owned by the existing modules.

## Required Readback

| Gate | Result |
|---|---|
| Installed lifecycle | PASS: one claim/resume/complete; two nested children; direct/group/parent delivery; six unique receipts; no transcript copies; cold readback; zero processes. |
| Installed owner lifecycle | PASS: 20/20 clients; graceful stop; forced tree loss; two replacement generations; zero processes. |
| Installed owner tracer | PASS: explicit workspace wins; reconnect preserves generation; two clients share one owner. |
| Source graph | PASS: 19/19 steps; 1,953/1,953 tests. |
| Focused TUI graph | PASS: 9/9 steps; 61/61 tests. |
| Hash boundary | PASS: source and installed SHA-256 `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`. |
| Process boundary | PASS: installed VANTARI process census is zero after every proof. |
| Ownership audit | PASS: 10 lifecycle files, 139 segments, six candidates, zero exact duplicates. |
| Repair boundary | PASS: failed/cancelled terminal children become `repair_required`; closure rejects missing approval, exact rerun, or regression evidence. |

## Residual Boundaries

- 035 remains a separate provider/cost chain and is not falsely archived by this
  036 review.
- Move 62 still owns arbitrary external-effect certainty.
- Moves 71–80 still own the causal self-repair promotion loop.
- The user-requested prompt-mode and ideation control plane remains a later
  roadmap capability; no executor branch was added to 036.

## Original User Message Proof

- U1: “setting to assigned shouldnt trigger an agent.”
- U2: “have config and a \"pool\" of engineers ready and waiting (agents)”
- U3: “an agent that is most relevant expertise/skill should pick up the task”
- U4: “proceed to fulfill the complete ticket cycle to complete status. runing persistently until completed.”
- U5: “agents that pick up a ticket, may use explore, tools, and research/plan agents.”
- U6: “context size used, remaining, etc. model effort, etc. amount of agents running, etc. still clean minimal, but elegant and User friendly.”
- U7: “Apply this to vantari. leave the code better than you find it. whenever you look at it”
