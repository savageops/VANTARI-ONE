---
type: research
id: repair-rerun-move77-2026-08-14
status: source-complete
---

# Move 77 — exact replay treatment

## Question

Can VANTARI rerun an approved repair with the exact original input and
effective configuration through the existing session/executor/provider lane,
without a replay prompt, a second runner, or a hidden provider path?

## Reference pressure

- `E:\Workspaces\02_Obsidian\Library\Clippings\Your Agent Harness Should Repair Itself 1.md`
  defines the causal order: trace, diagnose, propose, approve, apply, rerun the
  original input, then lock the regression.
- `.refs/openai__codex/codex-rs/app-server/README.md` preserves the useful
  session invariant: a resumed or forked treatment retains history and runtime
  configuration while an isolated child gives the treatment its own lifecycle.
- The existing VANTARI receipt, event, session, and executor owners already
  provide the durable state. No repair framework or second ledger is needed.

## Decision

`repair/rerun` is one operator-only control-plane socket. It admits only a
non-running source session with:

- one valid immutable `var1.repair_receipt.v1` event;
- one later `var1.repair_candidate_applied.v1` event;
- exact source receipt and applied-event sequence numbers;
- original input, model, provider identity when available, prompt mode, and
  configuration hash.

The handler derives a deterministic rerun ID from the source session and the
two evidence sequences, creates one fresh child treatment session linked by
`continued_from_session_id`, and sends the recorded model/provider/mode through
the existing `handleSessionSend` and executor path. The child inherits only the
source access scope; it does not copy the parent transcript.

The executor appends the child replay receipt and compares the exact original
input and effective configuration hash before context compilation or provider
I/O. A mismatch fails the child with `repair_replay_identity_mismatch` and
reports `provider_dispatched:false`. A matching treatment records the normal
`turn_started`, assistant, tool, and terminal events. The source session stores
compact `repair_rerun_started` and `repair_rerun_completed` relationship
receipts; a completed rerun is idempotent, while an interrupted started rerun
is explicitly reported as in progress for the later cold-start reconciliation
move.

Rejected designs: a substituted replay prompt, raw secret-bearing config
snapshots, a replay-specific provider client, a background repair worker, a
second transcript ledger, or automatic retry after identity mismatch.

## Proof

- Debug: `19/19` build steps, `2,193/2,193` tests passed.
- ReleaseFast: `19/19` build steps, `2,193/2,193` tests passed; source
  ReleaseFast build `9/9`, SHA-256
  `EF77BFE3144819008B027ADDB0EF66A945A0CD0CA33CC9FA76629E77E03EB07A`.
- The host regressions prove both boundaries: a changed effective config
  completes without `turn_started` or provider dispatch, while a matching
  receipt uses the normal fake provider transport, records `turn_started`,
  completes, and persists the replayed assistant output.
- Installed promotion is intentionally deferred. The preserved installed
  owner remains on SHA-256
  `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Residual boundary

Move 77 proves exact treatment admission and identity gating. Moves 78–80 still
own invariant/effect/latency comparison, conflict or regression rollback, and
regression promotion plus cold-start reconciliation. No autonomous unapproved
mutation is enabled.
