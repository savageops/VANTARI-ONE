# Flue Framework Harvest for VAR1

Date: 2026-05-04

Target:

- Upstream site: [flueframework.com](https://flueframework.com/)
- Upstream repository: [withastro/flue](https://github.com/withastro/flue)
- Local fork clone: `.refs/withastro__flue`

## Scope

Objective: extract architecture primitives from Flue that improve VAR1 session-runtime correctness, portability, and compaction behavior without importing incidental TypeScript/runtime complexity.

Non-goals:

- No direct code transplant from Flue into Zig.
- No parallel runtime lane next to `apps/backend`.
- No migration readers for historical store layouts.

## Primary Signals (Evidence)

1. Experimental volatility is explicit (`README.md` marks APIs as under active development).
2. Session/runtime split is explicit: agent runtime owns sandbox scope; session owns durable conversation state and metadata.
3. Child delegation uses detached sessions with shared filesystem and isolated message history (`session.task()` path).
4. Session history object models compaction as append-only entries with `firstKeptEntryId` boundary semantics.
5. Context build path is compaction-aware: latest summary checkpoint + kept transcript suffix.
6. Runtime has strict single-operation exclusivity guard (`activeOperation`) to prevent in-session concurrency races.
7. Compaction has dual triggers: threshold and overflow-retry; overflow removes failed assistant tail, compacts, then retries.
8. Compaction token budgeting starts with heuristics (chars/4) and upgrades only when needed.
9. Connector contract is explicit and typed (`SandboxApi` + `SandboxFactory` + `createSessionEnv`) with cleanup lifecycle.
10. Build pipeline deliberately excludes AGENTS/skills from bundles and discovers them from runtime cwd.
11. Cloudflare roadmap reinforces portable ownership invariant: conversation/session model remains framework-owned, not substrate-owned.

## Adopt / Adapt / Reject Matrix

### Adopt (high-value, low-risk)

1. Detached-child-session delegation semantics.
2. Compaction boundary contract as explicit checkpoint marker over immutable transcript.
3. Overflow-aware recovery loop (compact + retry once) with deterministic guard.
4. Operation exclusivity guard per live session to prevent interleaved state mutation.
5. Runtime discovery of AGENTS/skills from cwd instead of build-time embedding.
6. Typed connector/socket contract with explicit cleanup callable.

### Adapt (worthwhile, but reshape for VAR1)

1. Entry IDs in Flue are random UUID slices; VAR1 should keep monotonic `seq` as canonical compaction boundary and treat opaque IDs as secondary labels.
2. Flue history supports branch summary entries; VAR1 should remain linear append-only until branching has a concrete operator surface and test contract.
3. Flue default Node persistence is in-memory unless custom store supplied; VAR1 must remain `.var/sessions` durable-by-default.
4. Flue connector spec allows shell fallbacks for missing provider methods; VAR1 should keep fail-closed capability gates where privileged operations are unavailable.
5. Flue compaction tracks file-op details from tool calls; VAR1 can mirror this but should reuse existing `var1.tool_effect.v1` receipts to avoid dual evidence formats.

### Reject For Now

1. Direct adoption of Flue’s TypeScript SDK architecture.
2. Cloudflare/DO-specific runtime substrate assumptions.
3. Any branch-tree/session-graph semantics before explicit product need.
4. Build-time roles/agent manifest flow; VAR1 currently benefits from runtime-first ownership.

## Direct Applicability to Current VAR1 Invariants

1. Session transcript immutability:
   Flue compaction appends checkpoints and rebuilds model context from latest checkpoint + kept suffix. This aligns with VAR1 `messages.jsonl` immutable transcript plus `context.jsonl` checkpoint ledger.
2. Manual-first compaction:
   Flue shows threshold and overflow paths; VAR1 can keep manual `session/compact` canonical and add overflow retry as the first autonomous upgrade after explicit tests.
3. Delegation boundary:
   Flue task sessions share filesystem but isolate message history. This maps directly to VAR1’s parent/child session orchestration goals without introducing a second durable registry.
4. Capability boundaries:
   Flue connector spec keeps a hard typed seam (`SandboxApi`). This supports VAR1’s socket-first rule for tools/plugins/connectors.

## Recommended VAR1 Harvest Backlog (Ordered)

1. Add `context_overflow_recovery` event schema:
   include `{ session_id, attempt, compacted_checkpoint_id, retry_started_at_ms }`.
2. Implement one-shot overflow recovery in executor:
   on provider overflow classification, compact once, retry once, then emit terminal overflow failure if unresolved.
3. Enforce strict per-session operation mutex at command/RPC entry:
   return explicit conflict diagnostics for concurrent mutate-capable operations.
4. Extend checkpoint metadata:
   persist `compacted_entry_count`, `aggressiveness_milli`, and compacted range bounds by `seq`.
5. Add connector contract doc under `.docs/research` or `.docs/architecture`:
   mirror Flue’s typed shape but mapped to Zig interfaces and `.var` auth/audit requirements.
6. Add delegation conformance tests:
   verify child session has isolated transcript but shared workspace side effects and bounded depth.

## Risk Notes

1. Flue is marked experimental; treat upstream contracts as design probes, not stability guarantees.
2. Feature parity pressure can induce architecture drift; preserve VAR1 single-runtime ownership and avoid dual-store or dual-session abstractions.
3. Overflow retry must remain idempotent with clear audit events; silent retries without markers reduce postmortem quality.

## Extraction Verdict

Verdict: worthwhile harvest.

Highest-value primitives to transfer now:

1. checkpoint-bound compaction context rebuilding
2. overflow-triggered compact+retry once
3. detached child sessions with shared filesystem
4. explicit connector socket contracts and cleanup semantics

These primitives are structurally compatible with VAR1’s `.var/sessions` ledger model and future-first kernel invariants.

## Sources

- [flueframework.com](https://flueframework.com/)
- [withastro/flue](https://github.com/withastro/flue)
- `.refs/withastro__flue/README.md`
- `.refs/withastro__flue/packages/sdk/src/session.ts`
- `.refs/withastro__flue/packages/sdk/src/session-history.ts`
- `.refs/withastro__flue/packages/sdk/src/compaction.ts`
- `.refs/withastro__flue/packages/sdk/src/types.ts`
- `.refs/withastro__flue/packages/sdk/src/context.ts`
- `.refs/withastro__flue/packages/sdk/src/build.ts`
- `.refs/withastro__flue/docs/sandbox-connector-spec.md`
- `.refs/withastro__flue/packages/cloudflare/ROADMAP.md`
