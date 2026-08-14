---
type: changelog
id: changelog/069-repair-approval-boundary
status: source-complete
date: 2026-08-14
owner: apps/backend/src/host/stdio_rpc.zig + apps/backend/src/core/evaluation/events.zig
---

# Operator-bound repair approval (Move 75)

Move 75 adds one operator-only `repair/approve` RPC over the existing event
spine. It binds approval to the exact candidate event sequence, candidate ID,
stored patch hash, and expected source baseline. The event owner rechecks the
current source baseline before appending one
`var1.repair_candidate_approval.v1` receipt.

- Repeating the same approval identity returns the existing approval sequence.
- A mismatched candidate, patch hash, or source baseline fails before any
  source mutation.
- The approval receipt reports `mutation_allowed: true` as permission evidence;
  it stores no patch body and does not write files or reserve a write intent.
- Move 76 will apply the approved candidate through existing reviewed write
  tools. No model-facing approval tool, patcher, approval bus, or second ledger
  was added.

Full Debug and ReleaseFast pass `19/19` steps and `2,184/2,184` tests. The
source ReleaseFast build passes `9/9` at SHA-256
`4D348DF8F6E19A7D79F54E6DE2987C7C5369E6630B75E3BB667EFE274E87DFA3`.
Installed promotion remains deferred; the preserved installed owner is not
changed.
