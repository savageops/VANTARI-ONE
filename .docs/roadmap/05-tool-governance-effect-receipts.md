# 05 — Tool Governance & Effect Receipts

**Priority: P0**

## The seam

Tool capability truth is contractual. Branch execution (the north star) makes per-tool side-effect evidence the currency of convergence: a branch is only trustworthy if every side effect it performed is evidenced and reviewable. The launch-of-branch is a delegating tool; the merge decision must reason over reviewed effect receipts.

## What exists today

- **Compiled review gate** (`apps/backend/src/core/tools/review.zig`, `registry.zig`, `runtime.zig`, `module.zig`). Pre-dispatch review from `ToolDefinition.review_risk` — not prompting, not a reviewer agent, not heuristics.
- **5 risk classes:** `read_only`, `write_capable`, `command_execution`, `delegating`, `unknown_high_impact` (blocked before dispatch).
- **Effect receipts** `var1.tool_effect.v1`: `operation`, `requested_path`, `resolved_path`, `before`/`after` (exists, bytes, sha256).
- **Tool spans** on the event spine: `tool_requested → tool_reviewed → tool_started → tool_output_delta* → tool_finished → tool_completed`.
- **Catalog-first** discovery: model-visible catalog carries availability, examples, review risk, exact JSON fields.

## What the competitor does (Eve)

Eve (`packages/eve/src/harness/tool-loop.ts`, `tools.ts`, `runtime/`) has a sophisticated tool model:

- **Tool approval (`buildToolApproval`)** — per-tool approval gating, with `authorization` challenges and `toolApproval` in the AI SDK agent settings.
- **Sandbox** (`workflow-sandbox.ts`, `attachment-staging.ts`) — filesystem and command execution can be sandboxed; attachments are staged to the sandbox.
- **Runtime actions** (`runtime-actions.ts`) — a parallel channel for driver-internal actions (authorization, subagent dispatch) that are not model-visible tools.
- **Dynamic tools / subagents** — tools can be added at runtime from resolvers.
- **Tool-result capping** during compaction.

**Limitation:** Eve's governance is layered on the AI SDK's approval hooks and its own runtime-action channel. It is rich but sprawling, and it does not have a single, compiled, review-risked **effect receipt** contract for file mutations. Its tool-result handling is about capping for compaction, not about proving side effects.

## What the competitor does (Gemini CLI / pi-mono)

- Gemini CLI: explicit approval for mutators, model-visible discovery.
- pi-mono: explicit tool execution lifecycle, terminal completion signal.

## Why VANTARI does it better

1. **Compiled review gate, not runtime hooks.** VANTARI classifies from the compiled `ToolDefinition` catalog. Eve's approval is a runtime hook layer over the AI SDK. VANTARI's fails closed at the binary for unknown tools; Eve's model depends on the harness wiring.
2. **Effect receipts are deterministic proof.** `var1.tool_effect.v1` with before/after bytes + SHA-256 is proof a client can verify independently. Eve has no equivalent deterministic file-effect receipt; it has sandbox staging and tool-result capping.
3. **One boundary, one failure class.** VANTARI's tool module is the single capability boundary; unknown tools, context-unavailable tools, invalid args, unsupported profiles fail before side effects. Eve's runtime-action channel is a second, parallel dispatch path.
4. **Effect receipts enable shard convergence.** A branch's effects are its receipts; the merge decision reads them. This is the missing piece Eve's compaction model lacks.

## Pipeline items under this theme

### P0-5a: Structural effect diffing (roadmap item 8)
- **Contract:** file mutation tools emit compact effect records with before/after metadata, byte counts, hashes, and optional localized hunks.
- **Mechanism:** extend `var1.tool_effect.v1` with an optional `hunks` field; keep the receipt compact.
- **Test:** a replace-in-file produces a hunk that, applied to `before`, reproduces `after` byte-for-byte.
- **Proof:** the receipt is replayed from the event spine and the hunk is verified.

### P0-5b: Write-intent ledger (roadmap item 9)
- **Contract:** write-capable tools reserve an intent record before mutation, commit an effect record after mutation, and reconcile abandoned intents at cold start.
- **Mechanism:** a `write_intent` ledger entry precedes the effect; cold start reconciles intents without a matching commit.
- **Test:** kill a process mid-mutation; cold start marks the intent abandoned and the file state is reprised for the next branch.
- **Proof:** intent + effect records replay the full write lifecycle.

### P0-5c: Branch-scoped capability profiles
- **Contract:** a branch launched by the parent inherits a bounded capability profile (which tools, which review risk, which workspaces). The parent cannot grant tools the parent itself lacks.
- **Mechanism:** the `launch_agent` scope fields already exist; extend them to carry the branch's tool profile.
- **Test:** a branch cannot call a tool outside its inherited profile; the denial is a `tool_blocked` event with the profile boundary as evidence.
- **Proof:** event spine shows the denial with the capability owner.

## North-star link
Every branch performs side effects. The only way to converge branches safely is to prove and review those effects. Effect receipts are the evidence; the compiled review gate is the authority; branch-scoped profiles are the blast-radius control. This is the trust layer of shard-and-converge.

## Definition of done
- Effect receipts carry verifiable structural diffs.
- Write intent is reserved, committed, and reconciled at cold start.
- Branches run under bounded capability profiles, enforced at the binary.