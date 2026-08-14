---
type: research
id: repair-apply-move76-2026-08-14
status: source-complete
---

# Move 76 — approved repair through the normal write path

## Question

Can an explicitly approved repair reach the existing reviewed file tool and
the existing write-intent ledger without introducing a patcher, repair queue,
or second mutation owner?

## Reference pressure

- The VANTARI write-intent study already established the transferable
  invariant: reserve the mutation before the side effect and commit the
  observed effect after it.
- The VANTARI repair boundary established candidate, approval, and baseline
  identity as append-only event evidence.
- oh-my-pi's hashline pattern supplies the useful edit invariant: the edit
  carries the exact read tag and fails closed when the target changed.
- Vercel Eve's human-in-the-loop pattern supplies the useful retry invariant:
  bind non-idempotent effects to a stable approval identity.

The references justify the boundaries, not a new workflow framework. The
existing `replace_in_file` tool already owns exact replacement, stale-tag
rejection, effect evidence, and write-intent reserve/commit.

## Decision

`repair/apply` is one operator-only control-plane socket. It accepts the exact
`replace_in_file` JSON payload as the candidate patch, including `path`,
`old_text`, `new_text`, and the `read_file` tag. Before dispatch it verifies:

- candidate event sequence/id and operation;
- approval event sequence/id and stored patch hash;
- resolved target path and expected source baseline;
- committed intent or applied receipt for retry idempotence.

After verification it calls the existing tool dispatcher. The dispatcher
performs the read-ledger inspection and the normal `replace_in_file` tool
performs stale-tag checking and write-intent reserve/commit. The event owner
appends one `var1.repair_candidate_applied.v1` receipt after the effect. A
process-local apply mutex closes the concurrent duplicate window.

Rejected designs: a new patch language, a background repair worker, an
autonomous approval path, source bytes in the event ledger, or a second write
implementation.

## Proof

- Debug: `19/19` build steps, `2,191/2,191` tests passed.
- ReleaseFast: `19/19` build steps, `2,191/2,191` tests passed; source
  ReleaseFast build `9/9`, SHA-256
  `E57D6491A7385BAF945CA6AA7938FA15CC5B971045A3A735950F8E10EB6EB2A2`.
- The host integration test applies one approved edit, proves the reserved →
  committed intent pair, proves the applied receipt, retries the same request,
  and proves no second mutation or duplicate receipt.
- Installed promotion is intentionally deferred; the live owner pair and
  separate user-launched process were preserved.

## Residual boundary

Move 76 applies one approved `replace_in_file` candidate. Exact original-input
rerun, invariant comparison, rollback, and regression promotion remain Moves
77–80. The source binary is not the installed binary until an explicit
promotion pass is authorized.
