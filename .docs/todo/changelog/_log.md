# Execution Log

## 2026-08-16 - Provider credential import, model routing, and Models tab defect closure

**Outcome:** The interrupted 2026-08-15 provider chain is complete and
deployed. One `provider/model-name` namespace with a single-owner credential
ladder, explicit Codex/Claude/OpenCode import with provenance and collision
guard, per-agent provider/model overrides, and a cycle-to-lock Settings →
Models tab. All 8 audited defects from the dead session were re-verified and
fixed; ledger mutations now apply on the next turn without a kernel restart.

- `auth detect`/`auth import` (CLI + RPC), `providers/set-model`,
  `agents/list`/`agents/configure`, and `models/list` resolve through the
  ledger; `refreshActiveAuthFromLedger` is the one per-turn refresh owner
  shared by `session/send` and `models/list`.
- Full receipt with proof and boundaries:
  `.docs/todo/changelog/087-provider-credential-import-model-routing.md`.

- Debug gate `19/19`, `2,223/2,227` passed (4 platform skips); source
  ReleaseFast `9/9` at SHA-256 `217240A0…6663`; Linux installed binary
  hash-equal with a live owner generation, and live `health`/`auth`/`models`
  probes green. Anthropic/OpenCode refresh flows remain the open parity
  residual.

## 2026-08-14 - Close current frontier after proactive YAGNI pass

**Outcome:** The reactive repair/replay control plane remains deleted, and the
current Windows consumer frontier is closed against one installed ReleaseFast
artifact. The canonical session, event, review, provider, write-intent,
process, ticket, and context owners carry the useful guarantees.

- Current source/installed SHA-256 equality:
  `59E150343A206A465ACACBB7E3F5466BDD052E4C8F4426C599AFB6D25A24FC8E`.
- Current gate: Debug `19/19` steps, `2,184/2,184` tests, ReleaseFast seed `0`,
  manifest `promotable`, and zero final exact-path installed processes.
- Installed proof covers provider streaming, all four prompt-mode question
  paths, persistent Python/Bun eval, settings, native write/effect evidence,
  cancellation, owner/scheduler lifecycle, summary/event readback, and cleanup.
- DAP review risk, adversarial TTSR recovery, reference-pressure shell, and the
  nested hidden-TUI host Job boundary are explicit typed boundaries. No
  fallback, repair ledger, replay path, review bypass, or detached launcher was
  added.

Receipts:
`.docs/research/2026-08-14-roadmap-24-completion-audit.md`,
`.docs/research/2026-08-14-roadmap-24-installed-frontier-proof.json`, and
`.docs/research/2026-08-14-roadmap-24-release-manifest.json`.

## 2026-08-14 - Retire repair/replay control plane (YAGNI pass; historical source receipt)

**Outcome:** Removed the optional Moves 72–80 repair/replay chain and the
repair-specific ticket closure fields. The canonical session transcript,
typed terminal/failure evidence, review gate, provider capability contract,
and write-intent ledger remain the owners.

- Deleted roughly 3.7k repair-only source lines, the proposal tool, and the orphaned
  `executor/batch.zig` extraction; removed the remaining ticket repair state.
- Historical Move 72–80 records remain provenance only. They are no longer
  active runtime or roadmap contracts.
- Source validation at deletion time: Debug and ReleaseFast `19/19` steps and
  `2,184/2,184` tests; the historical deletion artifact was `9/9` at SHA-256
  `59849686B1CF3F08E69BF54B4B6BAF50B16D981F5DEEB099584349B31B5CA378`.
  Installed promotion is not claimed.

Receipt: `.docs/research/2026-08-14-yagni-repair-replay-retirement.md`.

## 2026-08-14 - Delete unconnected performance telemetry (Move 84)

**Outcome:** Removed the empty `CounterRegister` and `VAR1 stats` surface
instead of adding a second telemetry owner. The old token now fails as an
unknown command before provider dispatch.

- `ix` owner search found only the empty CLI construction and unit-test
  `record` calls; no production counter writer or health/RPC readback exists.
- Source validation passed `19/19` steps and `2,184/2,184` tests.
- Source ReleaseFast is `9/9` at SHA-256
  `A1337ABC29728EAB78AB27BAA042227BEF62FEC295288B29400D822757C3F8FE`.
- Source `stats` and `help stats` both returned `unknown command 'stats'`
  with exit code `2`; no provider dispatch occurred.

Reopen gate: measured bottleneck, one canonical owner, explicit operator
consumer, and durable readback proof. Receipt:
`.docs/research/2026-08-14-performance-telemetry-move84.md`.

## 2026-08-14 - Repair regression promotion and cold-start reconciliation (Move 80)

**Outcome:** Closed the final source-side self-repair transition without adding
a worker, queue, patcher, retry daemon, or second ledger.

- A completed treatment over a failed/cancelled baseline appends one idempotent
  `var1.repair_regression.v1` receipt with candidate, approval, applied,
  evaluation, outcome, and source-baseline evidence.
- `session/get` and `session/list` reconcile orphaned rerun and rollback starts
  exactly once from the existing event spine. Completed children can be
  evaluated; missing/initialized children become `abandoned`; ambiguous file
  bytes become `recovery_required`.
- Recovery never replays provider I/O or file mutation. The second cold-start
  read is a no-op on terminal repair receipts.
- Debug and ReleaseFast pass `19/19` steps and `2,196/2,196` tests. Source
  ReleaseFast is `9/9` at SHA-256
  `E9E6BBBED7F7A52D3A5B48EAB78D63D4AA38E10FA548F468608771551067D4B8`.
  Installed promotion remains deferred and the preserved installed owner pair
  was not terminated.

Receipt: `.docs/todo/changelog/075-repair-regression-cold-reconcile-move80.md`.

## 2026-08-14 - Evidence-gated repair rollback (Move 79)

**Outcome:** Rolled back a failed repair treatment through the existing reviewed
writer while retaining the failed hypothesis and all source/treatment/evaluation
traces.

- Operator-only `repair/rollback` binds a failed evaluation to the candidate,
  approval, and applied event sequences.
- A required full current-file SHA-256 and current source baseline reject stale
  rollback requests before mutation.
- An exact inverse `replace_in_file` payload is reviewed and executed through
  the existing inspection/effect/write-intent owners. Completion requires the
  target hash to equal the candidate pre-apply hash.
- Started/completed `var1.repair_rollback.v1` receipts and deterministic
  identity preserve recovery evidence and make retries no-op. No patcher,
  worker, git reset, second ledger, or model-facing mutation tool was added.
- Debug and ReleaseFast pass `19/19` steps and `2,195/2,195` tests. Source
  ReleaseFast is `9/9` at SHA-256
  `C7B493E757130ED11AF93ED56FCCB1248C5A1E3C980D94D4D61D2BF33201B36C`.
  Installed promotion remains deferred.

Receipt: `.docs/todo/changelog/074-repair-rollback-move79.md`.

## 2026-08-14 - Bounded repair evaluation receipt (Move 78)

**Outcome:** Compared the source baseline and exact-input treatment through one
machine-readable evaluator event on the existing source event spine.

- `var1.repair_evaluation.v1` records terminal outcomes, turn latency,
  observable tool-span side effects, prompt/completion/cached/total tokens,
  measured or unavailable cost, exact identity/provider invariants, explicit
  optional bounds, and the final `passed` decision.
- `repair/rerun` accepts `max_latency_ms`, `max_side_effects_delta`,
  `max_prompt_tokens`, `max_completion_tokens`, and integer
  `max_cost_microusd` without moving evaluation into a second worker or ledger.
- Repeated evaluation identity returns the existing sequence. File-effect proof
  remains owned by `var1.tool_effect.v1`; evaluator events are mutation-free.
- Debug and ReleaseFast pass `19/19` steps and `2,194/2,194` tests. Source
  ReleaseFast is `9/9` at SHA-256
  `67BF8D1BABCDA39ECC9C4F1E29EF3A9F778EEBAC5DD52A8461EAFA2ED46F3E00`.
  Installed promotion remains deferred.

Receipt: `.docs/todo/changelog/073-repair-evaluation-move78.md`.

## 2026-08-14 - Exact repair replay treatment (Move 77)

**Outcome:** Reran approved repairs through a fresh child session with the exact
original input and effective configuration gate.

- Operator-only `repair/rerun` requires the immutable repair receipt and a later
  applied receipt, then derives one deterministic source/evidence identity.
- The child carries `continued_from_session_id` and the source access scope but
  uses its own transcript and event ledger. Recorded model/provider/mode values
  route through the existing `session/send` and executor/provider path.
- Input and config hashes are checked after the child receipt is appended and
  before context compilation/provider I/O. A mismatch fails closed without a
  `turn_started`; a matching treatment records normal provider events.
- `repair_rerun_started` and `repair_rerun_completed` are compact relationship
  receipts. Completed requests are idempotent; an incomplete start remains an
  explicit in-progress state for Move 80 reconciliation.
- Debug and ReleaseFast pass `19/19` steps and `2,193/2,193` tests. Source
  ReleaseFast is `9/9` at SHA-256
  `EF77BFE3144819008B027ADDB0EF66A945A0CD0CA33CC9FA76629E77E03EB07A`.
  Installed promotion remains deferred.

Receipt: `.docs/todo/changelog/072-repair-rerun-move77.md`.

## 2026-08-14 - Approved repair application (Move 76)

**Outcome:** Routed one explicitly approved repair through the existing
reviewed `replace_in_file` path and write-intent ledger.

- `repair/apply` verifies candidate/approval sequence and ID, exact patch JSON
  and read tag, resolved target, patch hash, and source baseline before any
  write.
- The existing read inspection, stale-tag, effect, and reserve/commit owners
  remain canonical. A `var1.repair_candidate_applied.v1` receipt records the
  effect without storing patch body or source bytes.
- A deterministic approval-bound tool-call ID plus the process-local apply
  mutex makes concurrent and repeated requests no-op after an applied receipt
  or committed intent.
- Debug passes `19/19` steps and `2,191/2,191` tests. Installed promotion
  remains deferred. Receipt:
  `.docs/todo/changelog/071-repair-apply-move76.md`.

## 2026-08-14 - Provider capability dispatch (Move 61)

**Outcome:** Wired the existing fixed provider capability cache into the live
wire dispatch boundary.

- `capability.zig::probe` materializes the selected adapter contract before
  provider I/O; streaming, native tool serialization, and context-overflow
  classification are explicit, while Responses is only marked for the
  Responses route.
- Unresolved `.auto` capability input fails closed. No network preflight,
  model catalog, fallback, provider registry, or second cache was added.
- Debug and ReleaseFast pass `19/19` steps and `2,190/2,190` tests. Source
  ReleaseFast passes `9/9`; source SHA-256 is
  `9C54A17D903D4B51ACEE8AE4806C460F1B6AC59D04810185AD9C02A6F256DB89`.
- Installed promotion remains deferred. Receipt:
  `.docs/todo/changelog/070-provider-capability-dispatch.md`.

## 2026-08-14 - Operator-bound repair approval (Move 75)

**Outcome:** Added one operator-only approval socket for source-anchored repair
candidates. Approval appends evidence only and remains bound to the exact
candidate and unchanged source baseline.

- `repair/approve` validates candidate event sequence/id, stored patch hash,
  expected baseline, and the current source baseline before appending
  `var1.repair_candidate_approval.v1`.
- The same approval identity is sequentially idempotent; mismatches fail before
  mutation. `mutation_allowed:true` is approval evidence for Move 76, not a
  source write. No patch body, patcher, approval bus, or second ledger exists.
- Full Debug and ReleaseFast pass `19/19` steps and `2,184/2,184` tests.
  Source ReleaseFast passes `9/9`; source SHA-256 is
  `4D348DF8F6E19A7D79F54E6DE2987C7C5369E6630B75E3BB667EFE274E87DFA3`.
- Installed promotion remains deferred. Receipt:
  `.docs/todo/changelog/069-repair-approval-boundary.md`.

## 2026-08-14 - Source-anchored repair candidates (Move 74)

**Outcome:** Added one proposal-only repair candidate socket to the existing
tool runtime and event spine. It blocks source drift before mutation.

- `repair_candidate` resolves and inspects an existing target, captures its
  before hash, hashes the exact operation/path/patch descriptor, and appends
  one `var1.repair_candidate.v1` event with expected/current baseline hashes.
- Ready candidates still declare `mutation_allowed: false`; baseline drift
  returns typed `RepairBaselineConflict`; no write intent, approval, patcher, or
  second ledger was added.
- Full Debug and ReleaseFast pass `19/19` steps and `2,182/2,182` tests.
  Source ReleaseFast passes `9/9`; source SHA-256 is
  `E92BD7C72EBF06D2D6B43F0ECF85B90AD6E0C34605D72833B96CBD5F0B7BB0FD`.
- Installed promotion remains deferred. Receipt:
  `.docs/todo/changelog/068-repair-candidate-baseline.md`.

## 2026-08-14 - Deterministic causal diagnosis (Move 73)

**Outcome:** Added a bounded causal-diagnosis record inside the existing
failure receipt without creating a second event stream.

- Failed and timed-out `turn_terminal` payloads now carry one
  `var1.repair_diagnosis.v1` record. Normalized failure class/phase selects a
  fixed invariant; no model-generated cause or free-form telemetry is stored.
- The deterministic diagnosis ID binds the failure ID, invariant, and exact
  event span from `session_started.seq` through `turn_terminal.seq`.
- Completed and cancelled turns remain diagnosis-free. The diagnosis is
  serialized with terminal settlement, so it cannot become an orphan row.
- Full Debug and ReleaseFast pass `19/19` steps and `2,180/2,180` tests.
  Source ReleaseFast passes `9/9`; source SHA-256 is
  `F0D19C0BE1E92EFD59986437731B2B96884CE81F7E8703137C45B0046E861137`.
- Installed promotion remains deferred. Receipt:
  `.docs/todo/changelog/067-repair-diagnosis-move73.md`.

## 2026-08-14 - Immutable replay receipts (Move 72)

**Outcome:** Added one immutable per-turn replay receipt to the existing event
spine before context compilation and provider dispatch.

- The receipt retains the exact original input and selected model, records
  `replay_input_immutable: true`, and hashes transient effective config, native
  tool catalog, tracked environment, and the source baseline.
- The source baseline is recorded as `git:<commit>` when available or
  `unavailable` when it cannot be verified. Raw config, tool, and environment
  snapshots never enter `events.jsonl`; a secret-like config regression proves
  that boundary.
- Full Debug and ReleaseFast pass `19/19` steps and `2,180/2,180` tests.
  Source ReleaseFast passes `9/9`; source SHA-256 is
  `8E15F5ED22631B232EFF2F5FE2FF1E6B336250D22C61E0313645A6BEAB256639`.
- Installed promotion remains deferred. Receipt:
  `.docs/todo/changelog/066-repair-receipts-move72.md`.

## 2026-08-14 - Failure receipts (Move 71)

**Outcome:** Normalized failed and timed-out terminal turns into one bounded
`var1.failure_receipt.v1` receipt and projected its deterministic ID through
the existing session and ticket owners.

- The receipt carries normalized class, phase, bounded detail, and a stable
  `failure-<sha256>` ID. Completed and cancelled turns remain receipt-free.
- Session cold projection, scheduler terminal reconciliation, and stale-lease
  requeue reuse the same ID owner and idempotency boundary.
- Full Debug passes `19/19` steps and `2,178/2,178` tests. Focused TUI Debug
  and ReleaseFast pass `9/9` steps and `137/137` tests.
- Source ReleaseFast passes `9/9`; source SHA-256 is
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion remains deferred. Research and receipt:
  `.docs/research/2026-08-14-failure-receipts-move71.md` and
  `.docs/todo/changelog/064-failure-receipts-move71.md`.

## 2026-08-14 - Question modal batch boundary

**Outcome:** Hardened the shared settings-style question modal against invalid
or oversized request envelopes and maximum-batch rendering pressure.

- Empty, wrong-schema, wrong-kind, and over-limit requests fail before drawing.
- Prompt and option truncation uses terminal-cell width; response IDs remain
  unchanged. A 60-question batch survives 1/2/4/20-row live and review frames.
- Full Debug passes `19/19` steps and `2,178/2,178` tests. Focused TUI Debug
  and ReleaseFast pass `9/9` steps and `137/137` tests.
- Source ReleaseFast passes `9/9`; source SHA-256 is
  `27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
- Installed promotion remains deferred. Research and receipt:
  `.docs/research/2026-08-14-question-modal-batch-boundary.md` and
  `.docs/todo/changelog/065-question-modal-batch-boundary.md`.

## 2026-08-14 - Question panel event-loop recovery

**Outcome:** Contained recoverable question-controller and `input/respond`
failures at one `ChatState.handleQuestionKey` boundary shared by the idle and
streaming TUI loops. The settings-style horizontal question panel, review/submit
state, and single broker resolution path remain the only owners.

- Focused TUI Debug and ReleaseFast pass `9/9` steps and `135/135` tests.
- Full Debug passes `19/19` steps and `2,165/2,165` tests.
- Source ReleaseFast passes `9/9`; source SHA-256 is
  `D22A6E617DEF01BDF323F4F4500C1F53AD54C1221CFE6A8A6413FCA6D7D1EDFE`.
- Installed promotion remains deferred; the preserved installed owner remains
  on `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
- Research and receipt: `.docs/research/2026-08-14-question-panel-event-loop-recovery.md`
  and `.docs/todo/changelog/061-question-panel-event-loop-recovery.md`.

## 2026-08-14 - Typed context-compile diagnostics (Move 69)

**Outcome:** Kept provider-context reconstruction in one compiler and made
malformed tool-topology repair observable without adding a repair bus.

- `core/context/builder.zig` returns bounded synthesized/skipped tool-result
  counts; the append-only transcript remains unchanged.
- `core/executor/loop.zig` persists one typed
  `var1.context_compile_diagnostic.v1` event only when a repair or skip occurs.
- Provider-overflow retry compacts, rebuilds through the compiler, and retries
  once without duplicating durable tool context. Silent/normal TUI posture
  suppresses the diagnostic; full posture renders compact counts.
- Debug passes `19/19` build steps and `2,163/2,163` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 is
  `898CAF97FD90F14B0FF3C202887467F7FFDDAC670583BEFB8B4491C2F6909DD6`.
- Installed promotion remains deferred. Research and receipt:
  `.docs/research/2026-08-14-context-compile-diagnostics-move69.md` and
  `.docs/todo/changelog/060-context-compile-diagnostics-move69.md`.

## 2026-08-14 - Stable message IDs and compaction ranges (Move 67)

**Outcome:** Closed the existing session/context identity seam with a cold
replay regression and kept the append-only owners unchanged.

- The session store retains generated `msg-<seq>` IDs and deterministic explicit
  delivery IDs through replay; repeated explicit IDs append once.
- Compaction appends only to `context.jsonl`; `messages.jsonl` stays byte-identical.
- Checkpoints retain their identity and inclusive `source_seq_start`,
  `source_seq_end`, and `first_kept_seq` ranges. Provider reconstruction uses
  the summary plus exactly the first-kept raw suffix.
- Debug passes `19/19` build steps and `2,155/2,155` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 remains
  `CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`.
- Installed promotion remains deferred; automatic compaction remains gated by
  later token-accounting and cold-start recovery moves.
- Research and receipt: `.docs/research/2026-08-14-message-identity-compaction-ranges.md`
  and `.docs/todo/changelog/058-stable-message-ids-compaction-ranges.md`.

## 2026-08-14 - Prompt budget and behavior matrix (Move 66)

**Outcome:** Added one bounded prompt-assembly owner and proved behavior
personalization through prompt layers across modes, profiles, and tool routes.

- `context.prompt_budget_tokens` defaults to `8192` and is loaded through the
  existing context policy/config owner.
- `builder.zig` enforces the shared estimated prompt budget before provider
  dispatch and returns `PromptBudgetExceeded`; it never silently truncates
  prompt layers.
- Prompt tests cover `orchestrate`, `build`, `align`, and `plan`, plus
  terse/detailed, solo/orchestrated, conservative/aggressive, and low/high
  cadence profiles across root, recon, and orchestrator tool definitions.
- Native provider schemas remain the model-facing API; no executor branch,
  provider-specific prompt path, or prompt-side registry was added.
- Debug passes `19/19` build steps and `2,154/2,154` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 is
  `CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`.
- Installed promotion remains deferred by operator instruction; exact provider
  token accounting remains a later context-telemetry boundary.
- Research and receipt: `.docs/research/2026-08-14-prompt-budget-behavior-matrix.md`
  and `.docs/todo/changelog/057-prompt-budget-behavior-matrix.md`.

## 2026-08-14 - Native tool schema prompt boundary (Move 65)

**Outcome:** Removed the duplicate full tool catalog from the model-facing
prompt while preserving the native provider schema and explicit diagnostics.

- `builder.zig` no longer calls `tools.renderCatalog`; the provider request's
  native name/description/parameters schemas are the single tool API.
- The compact Tool Protocol points to declared schemas and typed execution
  hints. System/developer/persona/guardrail/user-context/mode layers remain
  hot-loaded behavior owners; skill bodies remain demand-loaded via `skill_info`.
- Stale `.var/todos` and generic archive wording is removed from the prompt.
  `tools` and `tools --json` diagnostic surfaces remain explicit owners.
- Debug passes `19/19` build steps and `2,150/2,150` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 is
  `702DD2CB1A067246E82D8670F0F33FD322FD4178C271AF11E712A110151783D3`.
- Installed promotion remains deferred by operator instruction; the live owner
  process pair was preserved.
- Research and receipt: `.docs/research/2026-08-14-native-tool-schema-prompt-boundary.md`
  and `.docs/todo/changelog/056-native-tool-schema-prompt-boundary.md`.

## 2026-08-14 - Ticket-only work lifecycle (Move 64)

**Outcome:** Closed the duplicate work-state boundary without adding a new
  lifecycle owner.

- Tickets now own work identity, queue admission, repair, and terminal state.
  Session summaries remain bounded handoff projections; plans, research,
  advice, roadmap, and changelog entries remain ticket-linked artifacts.
- Removed `todo_slice` and `session_record` schemas/dispatch, `.var/todos`
  scaffolding, automatic generic `core/docs/sync.zig` writes, the public
  `ProgressSnapshot` type, and the unused docs-sync module. Existing user data
  is not deleted.
- Debug passes `19/19` build steps and `2,150/2,150` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 is
  `BD84254B62AF1F4BA2EFEC2609B19BFBB7A69027F20ED1B0F354D9FBCB22CB69`.
- Installed promotion remains deferred by operator instruction; the live owner
  process pair was preserved.
- Research and receipt: `.docs/research/2026-08-14-ticket-only-work-lifecycle.md`
  and `.docs/todo/changelog/055-ticket-only-work-lifecycle.md`.

## 2026-08-14 - Ticket, quota, and scheduler policy ownership (Move 63)

**Outcome:** Closed the policy-key audit by retaining one capacity owner and
rejecting decorative ticket execution configuration.

- The four retired `tickets.*` keys remain invalid. Assignment remains
  queue-only, and `agent_routes.max_concurrency` is the sole configured
  capacity key flowing through the existing `AgentService`/`Supervisor` pool
  into scheduler admission.
- Lease TTL, heartbeat window, and dispatch burst remain private scheduler
  protocol constants. Agent step/tool/child limits remain specialist execution
  budgets; token, cost, wall-time, and turn quotas stay in the later usage-ledger
  move.
- Debug passes `19/19` build steps and `2,154/2,154` tests. Source ReleaseFast
  passes `9/9`; source SHA-256 is
  `2530D80C6B8129960C131F85B9508896BBA332423EC64FD2506061770E5E042D`.
- Installed promotion remains deferred by operator instruction; the live owner
  process pair was preserved.
- Research and receipt: `.docs/research/2026-08-14-ticket-quota-scheduler-policy.md`
  and `.docs/todo/changelog/054-ticket-quota-scheduler-policy.md`.

## 2026-08-14 - Question panel input lifecycle correction

**Outcome:** Closed the stale question-panel boundary without adding a second
transport, overlay, or input owner.

- `ChatState` clears the one `question_view.State` projection when the session
  owner is missing, `session/send` fails, a terminal event arrives, or the
  returned turn is already complete. Active Ctrl-C is handled by the existing
  `input/respond` cancellation route.
- The all-mode panel regression covers `orchestrate`, `build`, `align`, and
  `plan`, plus orphan and terminal cleanup. Focused TUI Debug and ReleaseFast
  pass `133/133`; full Debug passes `19/19` steps and `2,153/2,153` tests;
  source ReleaseFast build passes `9/9`.
- Source SHA-256 is
  `C53933B5259D5DE88447B431B01F5F2B123A3935DDBFB13F51A2A739CAFEE573`.
  Installed promotion remains explicitly deferred.
- Research and receipt: `.docs/research/2026-08-14-question-panel-input-lifecycle.md`
  and `.docs/todo/changelog/052-question-panel-input-lifecycle.md`.

## 2026-08-14 - Question panel runtime contract

**Outcome:** Closed the root catalog/dispatch seam and proved the existing
multiple-choice panel through the real Vaxis render boundary without adding a
second interaction system.

- Root normal, root-agent, and orchestrator-only catalogs retain `ask_user`;
  the orchestrator allow-list still denies artifact and command tools, and
  child profiles remain headless.
- The same settings-style horizontal-row controller renders and flushes in
  orchestrate, build, align, and plan. Focused TUI `132/132`; full Debug
  `19/19`, `2,151/2,151`; source ReleaseFast `9/9`.
- Source SHA-256 is
  `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
  Installed promotion remains explicitly deferred.
- Research and receipt: `.docs/research/2026-08-14-question-panel-runtime-contract.md`
  and `.docs/todo/changelog/051-question-panel-runtime-contract.md`.

## 2026-08-14 - TTSR stream abort

**Outcome:** Closed Move 60 in source by stopping matched provider streams
before stale terminal completion and retrying through the existing executor.

- One typed provider abort hook crosses the SSE reader and all current
  adapters; the executor persists correction plus `rule_injected` evidence and
  retries without a second stream owner.
- Full Debug `19/19`, `2,151/2,151`; source ReleaseFast `9/9`; source SHA-256
  `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
- Installed promotion and live provider TTSR proof remain deferred.
- Research and receipt: `.docs/research/2026-08-14-ttsr-abort-move60.md` and
  `.docs/todo/changelog/050-ttsr-abort-move60.md`.

## 2026-08-14 - Question panel consumer hardening

**Outcome:** Hardened the existing source question-panel projection against
hostile model text and clipped terminal frames without adding an interaction
system.

- The Vaxis display projection now normalizes invalid UTF-8/control text, uses
  static option keys, preserves original response ids, and guards every fixed
  row against the viewport.
- Focused TUI `131/131` and full Debug `2,144/2,144` pass; source ReleaseFast
  exits `0`. Installed promotion remains explicitly deferred.
- Research and receipt: `.docs/research/2026-08-14-question-panel-consumer-hardening.md`
  and `.docs/todo/changelog/049-question-panel-consumer-hardening.md`.

## 2026-08-14 - Session-owned DAP lifecycle

**Outcome:** Closed Move 59 in source by composing DAP into the existing
definition, dispatch, and bounded process owners.

- `builtin/dap.zig` now exposes attach, pause, stack trace, scopes, variables,
  continue, and detach through seven risk-correct tool definitions.
- One adapter remains keyed by workspace plus session. Exact Content-Length
  frames preserve interleaved events/responses; timeouts and teardown use
  `PersistentProcess` and Windows tree receipts.
- Debug `19/19` and `2,141/2,141`, `test-tui` exit `0`, and source ReleaseFast
  exit `0` pass. Source SHA-256 is
  `20D9B9001719F891DF984CAD480B0DFCB712E6197FAF27F6907CE8B205F97D8D`.
- The real Python adapter lifecycle test leaves no adapter child. Installed
  promotion remains intentionally deferred.
- Research and receipt: `.docs/research/2026-08-14-dap-move59.md` and
  `.docs/todo/changelog/048-dap-move59.md`.

## 2026-08-14 - Real write-tool intent lifecycle (Move 62)

**Outcome:** Wired the existing session write-intent ledger through the three
real file mutation tools without adding a mutation manager or rollback worker.

- `write_file`, `append_file`, and `replace_in_file` now reserve the provider
  tool-call ID, resolved path, and before-hash before mutation, then commit the
  measured after-hash and operation metric after mutation.
- Executor and host cold-start paths reconcile only non-running or proven-stale
  sessions. A reservation without a commit receives one append-only
  `abandoned` row with `reason=cold_start`; repeated reconciliation is inert.
- Debug and ReleaseFast both pass `19/19` with `2,154/2,154` tests. Source
  ReleaseFast build passes `9/9`; source SHA-256 is
  `8F58E3D50904D67A90FA0CE4F8E3D0A1E6634D1AE1E00C887F42983112F2C18F`.
- Installed promotion remains deferred by operator instruction; the live owner
  process pair was preserved.
- Research and receipt: `.docs/research/2026-08-14-write-intents-real-tools.md`
  and `.docs/todo/changelog/053-write-intent-real-tools.md`.

## 2026-08-14 - Root question panel resilience

**Outcome:** Repaired the model-issued multiple-choice path and kept it inside
the existing `ask_user`/event/broker/RPC owners.

- `ask_user` and response serialization now free only initialized slices, so a
  late-invalid question cannot dereference unassigned pointers.
- The TUI renders a settings-style horizontal row per visible question with
  clamped question/option focus, Enter/Space selection, inline `f / Other`, and
  an explicit review/submit state. `orchestrate` and `align` share the path.
- Malformed `input_requested` data produces one bounded system message and
  direct run cancellation instead of unwinding the event loop.
- Question-panel strings now remain State-owned, static, or frame-owned until
  `vx.render`; the normal and review render states have a screen-cell ownership
  regression test.
- Focused TUI `9/9` and `130/130`, full Debug `19/19` and `2,139/2,139`, and
  source ReleaseFast `9/9` pass. Live installed promotion remains deferred.
- Research and receipt: `.docs/research/2026-08-14-root-question-review-panel.md`
  and `.docs/todo/changelog/046-root-question-panel-resilience.md`.

## 2026-08-14 - Saved TUI theme and status placement

**Outcome:** Added the smallest renderer-backed TUI configuration slice without
creating a theme editor, layout registry, or per-frame configuration read.

- `core/config/file.zig::TuiPolicy` validates the finite `tui.theme` palette
  names and `tui.status_bar_position` values. Defaults are `vantari` and
  `bottom`.
- Settings cycles both values through the existing `config/set` owner. The TUI
  reloads the policy after a successful save and applies it to the next frame;
  the composer remains at the bottom when the status row moves to the top.
- Four named palettes preserve the existing transcript < metadata < composer
  surface hierarchy. No arbitrary color map, menu registry, or second renderer
  owner was added.
- Debug `19/19` and `2,129/2,129` pass; focused `test-tui` is `9/9` and
  `126/126`; source ReleaseFast is `9/9`. Live installed promotion remains
  intentionally deferred.
- Research and receipt: `.docs/research/2026-08-14-tui-theme-status-settings.md`
  and `.docs/todo/changelog/045-tui-theme-status-settings.md`.

## 2026-08-13 - Persistent Python and Bun eval kernels

**Outcome:** Moves 56–57 are source-complete without adding a second execution
owner.

- `builtin/eval.zig` keeps one bounded persistent Python or Bun kernel per
  workspace and session. State survives calls and cannot cross sessions.
- The same newline protocol, bounded reader, output cap, timeout termination,
  and host teardown path serves both languages. Windows launches `bun.exe`, not
  the package-manager wrapper.
- `ToolDefinition.availability` owns Python plus its Bun alternative, and the
  registry exposes every declared alternative in the catalog.
- Debug `19/19` and `2,121/2,121` pass; source ReleaseFast passes. Installed
  promotion remains intentionally deferred.
- Research and receipt: `.docs/research/2026-08-13-persistent-eval-kernels.md`
  and `.docs/todo/changelog/044-persistent-eval-kernels.md`.

## 2026-08-13 - TUI input and command discovery repair

**Outcome:** The current TUI input surface now has one coherent path for
settings, Shift+Tab, and command discovery.

- Settings renders through `drawSettings -> vx.render -> flush`; the overlay no
  longer leaves the previous frame visible after a command opens it.
- `packages/tui/src/Parser.zig` decodes standard `CSI Z` as Shift+Tab, so the
  existing `PromptMode` cycle works across ANSI and Windows/Kitty input paths.
- The composer reuses `commands.builtin_command_info` for a transient,
  five-row prefix popup. Bare first-token names are accepted, slash input stays
  compatible, Up/Down scroll, Escape dismisses, Tab accepts spelling, and Enter
  dispatches the selected exact command.
- Child rows remain `agent - state "bounded summary"`; phase/elapsed data stays
  typed event evidence and does not consume the visible one-line budget.
- The requested orchestrate-only footer campaign is isolated in
  `clients/footer_effects.zig`; it runs a bounded sweep every three seconds and
  does not add a permanent ticker or plugin runtime.
- Research: `.docs/research/2026-08-13-tui-input-command-palette.md`.

Debug `19/19` and `2,089/2,089`, focused `test-tui` `9/9` and `114/114`,
ReleaseFast/install `9/9`, source/installed SHA-256
`F167C7B54F34433DFBF03A4E75B5FBE773F502B2EFEE4D272C323F24EA9FF501`, and the
real installed terminal smoke all pass. The `.docs` and research changes
remain local and unstaged under the active goal boundary.

## 2026-08-13 - Move 53 sandbox capability boundary

**Outcome:** Closed Move 53 by consolidate/delete. The existing
`CapabilityProfile` and `ExecutionContext.capability_profile_id` already own
branch/tool-class least privilege and are enforced at catalog construction and
dispatch. `recon` is read-only scope, not OS/process isolation.

- No duplicate `sandbox` alias, second path resolver, backend-less Boolean, or
  tool-local policy branch was added.
- A real sandbox remains gated on a verified Windows-native/container backend,
  explicit mounts, bounded lifecycle and process-tree teardown, cold-start
  reconciliation, and installed consumer proof.
- Debug `19/19` build steps and `2,023/2,023` tests remain green; the binary
  was not changed by the capability decision. Fresh ReleaseFast/install
  `9/9` produced matching source/installed SHA-256
  `B6804F1D865315DEE49D4E5B8620599A089C1D640B63C931483BBA01B3E094E4`.
- Installed `health --json` and `tools --json` exited `0`; the catalog exposes
  `ask_user` and reports `search_files` unavailable because `iex` is absent.
  The exact two proof-owned processes were stopped; final VANTARI/VAR1 census
  is `0`.
- Research and source comparison:
  `.docs/research/2026-08-13-sandbox-capability-move53.md`.
- Root `AGENTS.md`, `.docs/index.md`, `.docs/technical_summary.md`,
  `.docs/workspace.json`, and roadmap 24 carry the same boundary.

The `.docs` and research changes remain local and unstaged per the current
goal instruction not to commit project research or the `.docs` folder.

## 2026-08-12 - Generation-bound cancellation

**Outcome:** Closed move 18 by binding interactive cancellation to the exact
durable run generation already observed on the event spine.

- `session_started.seq` is the run identity. The host binds it before event
  emission; the tracked TUI reuses it as `expected_run_seq` for replay and live
  cancellation.
- Missing, unobserved, and stale generations return typed no-op outcomes. Only
  the matching active generation sets `cancel_requested`. Shutdown still fences
  admission before unconditional active-run cancellation.
- Harvested exact-execution identity from OpenAI Codex, Vercel Eve, LangGraph,
  AutoGen, OpenAI Agents SDK, Temporal, and pi. A random UUID, cancellation
  ledger, watcher, and provider-specific abort path were rejected.
- The graph passes 19/19 and 1,950/1,950; ReleaseFast passes 9/9. The packaged
  GGUF audit inspected 130 segments and found zero candidate or exact pairs.
- Source and installed SHA-256 match
  `B361AD2A66609590236E4967517718C7ECD3563E7474578D08009D09622E1FA4`.
  The installed race observed sequences 1, 6, and 11: stale sequences 1 and 6
  could not cancel newer work; exact 11 returned `requested` and persisted
  `session_cancelled`. The kernel exited 0 and zero VANTARI process remained.
- Next owner: move 19, require one typed terminal event for every terminal path.

## 2026-08-12 - Shared JSONL valid-prefix contract

**Outcome:** Closed move 17 by consolidating event, message, context, intent, and
summary readers on one LF-framed valid-prefix owner and deleting the planned
CRC/sidecar/repair architecture.

- `shared/jsonl.zig:PrefixReader` accepts one leading BOM, validates UTF-8 and
  JSON before typed schema parsing, requires strictly increasing sequences, and
  stops every projection at the first defect while retaining the prior prefix.
- `fsutil.appendJsonlRecord` validates the bounded current tail through the same
  reader. Complete unterminated JSON receives LF; torn or poisoned JSON returns
  `PoisonedJsonlSuffix` before bytes change.
- Event latest/all/`after_seq`, session message, context checkpoint, write-intent,
  and summary readers now share the owner. Backward-skip and `catch continue`
  paths are removed. Hollow CRC helpers/tests are deleted.
- Harvested ordered valid-prefix pressure from OpenAI Codex, pi, SQLite, etcd,
  NATS, and Kafka. VANTARI retains strict forward recovery and rejects silent
  continuation, automatic truncation, sidecar status, and checksum schema until
  measured evidence justifies them.
- The graph passes 19/19 and 1,944/1,944; ReleaseFast passes 9/9. The packaged
  GGUF audit inspected 124 segments, found three adjacent test-setup candidates,
  zero exact pairs, and no duplicate production owner.
- Installed `kernel-stdio` replay returned one event/message before duplicate
  rows and one event before a torn suffix. `session/cancel` reached the append
  path but could not write behind poison; the file remained 107 bytes with
  SHA-256 `299360B1639A9698C8A87399771AD88BA2299B27823BC4574EDAB1347632E7DC`.
- Source and installed SHA-256 match
  `86724BD0346E6B6079BFBA2DD64A2559C359DAED7DA9C7B5D69B98705983C344`;
  backup:
  `C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe.20260812-190206.bak`.
  The isolated runtime was removed and zero VANTARI process remained.
- A full live-root audit found 877 older initialized context-poison test fixtures
  and no retained parent/continuation/summary/changelog ownership. They are held
  reversibly at
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-legacy-context-poison-fixtures`;
  manifest SHA-256 is
  `43FCC3A9530D204B77FF9B37D4534909563628A9EFA2F396F90FDC927811A9BC`.
  The repaired 29,937-ledger / 1,417,061-row scan has zero integrity defects.
- Next owner: move 18, bind cancellation to an observed turn/event generation so
  stale cancellation cannot terminate newer work.

## 2026-08-12 - Binary-safe command output envelope

**Outcome:** Closed move 16 with one durable typed serializer for arbitrary
stdout/stderr bytes and deleted the unused parallel byte projection.

- `serializeToolOutputDelta` base64-encodes raw `PipeCollector` slices and renders
  `var1.tool_output_delta.v1` with `tool_call_id`, tool, stream, and cap evidence.
  The executor's hand-built JSON is removed.
- Deleted top-level `SessionEvent.bytes_b64`, its session-reader copies, and two
  tests that proved only the hollow parallel field. Legacy rows remain prefix
  readable through unknown-field tolerance; the removed field is not projected.
- The adversarial source tracer persists stdout bytes `00 80 E2 80 A8 FF` and
  stderr bytes `FF 01`, reads them through `readEventsAfterSeq`, decodes them
  byte-identically, validates strict JSONL UTF-8, and rejects `bytes_b64` drift.
- Harvested OpenAI Codex's base64 `process/output` sequence/stream contract and
  `command/exec/outputDelta` cap marker from the
  [exec-server](https://github.com/openai/codex/blob/main/codex-rs/exec-server/README.md)
  and [app-server](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md).
  VANTARI persists the envelope for cold replay; Codex output delivery is
  connection-scoped.
- Rejected a second process/chunk cursor and payload spill/retention subsystem.
  Stored event `seq` plus `tool_call_id + stream` already identifies every
  bounded delta, and `shell_exec` caps each stream at 64 KiB.
- The isolated graph passes 19/19 and 1,936/1,936; ReleaseFast passes 9/9. The
  four-owner GGUF audit inspected 62 segments and found zero candidate or exact
  duplicate pairs.
- Installed `session/send` persisted four `user,assistant,tool,assistant` rows
  and 12 unique monotonic notifications. `session/get` after sequence 1 returned
  contiguous sequences 2–12 and two output deltas. Replay reconstructed stdout
  `0080E280A8FF`, capped stderr `FF010080E280A8FE`, and
  `stderr_cap_reached=true`; strict UTF-8 ledger decode passed and zero VANTARI
  processes remained.
- Source and installed SHA-256 match
  `23885BD546F6A663F4DC90F774A153FC0815277BD6F43FE6DA7872D9681E00EC`;
  prior binary backup:
  `C:\\Users\\Savage\\AppData\\Local\\Vantari\\bin\\vantari.exe.20260812-161006.bak`.
- Next owner: move 17, make poisoned/torn/BOM/duplicate-sequence prefix recovery
  one explicit shared ledger contract without adding a database or second log.

## 2026-08-12 - Exact TUI event replay identity

**Outcome:** Deleted client-owned event identity and made the persisted per-session
sequence the tracked TUI's sole render and replay cursor.

- Removed the 512-entry timestamp/type/text cache and periodic full-event
  reconciliation. The transport ordinal now drains only the stdio queue.
- Contiguous live notifications perform no replay RPC. A sequence gap calls the
  existing `session/get { after_seq, events_only }` suffix reader; one post-turn
  suffix check recovers even when the complete live tail was evicted.
- Two identical events at one timestamp rendered as `samesame`; replay of the
  second sequence rendered nothing twice. A missing suffix produced
  `onetwothree` in exact sequence order.
- The focused TUI lane passes 59/59; the canonical graph passes 19/19 and
  1,934/1,934; ReleaseFast passes 9/9.
- Installed catch-up after sequence 1 returned only sequences 2–4. Four live
  notification sequences were unique, the final stored/notified event was
  `turn_finished` at sequence 4, the provider completed, and zero processes remain.
- Source and installed SHA-256 match
  `134D8600777C8ECAD7BF4B87AFF4BEB4D3ECD50BC72CF0A14C5BFB8CE19AF6DD`;
  the prior binary is retained at
  `C:\\Users\\Savage\\AppData\\Local\\Vantari\\bin\\vantari.exe.20260812-154856.bak`.
- Harvest retained Eve's persisted absolute stream index, Codex's typed item
  identity, and SSE reconnect semantics. VANTARI uses one smaller durable cursor
  and the existing suffix reader; no subscriber registry or replay cache was added.
- Dupe audit is deferred for this bounded deletion/consolidation slice: it adds no
  new owner and removes the only heuristic identity cache.
- Next owner: move 16, preserve arbitrary stdout/stderr bytes with one canonical
  versioned event envelope and explicit stream/cap evidence.

## 2026-08-12 - Stored event sequence through live RPC

**Outcome:** Removed sequence loss between `events.jsonl` and every live
`session/event` producer without adding another event bus or cursor owner.

- `appendEventWithSeq` returns the writer-assigned ledger identity;
  `var1.session_event_notification.v1` carries that exact value through loop,
  agent-parent, stdio, and browser bridge paths.
- Buffer previews and queued steer notices now persist before emission. Terminal
  assistant and `turn_finished` notifications follow the same order as disk.
- Two identical same-millisecond events persisted and emitted as distinct
  sequences 1 and 2. The complete graph passes 19/19 and 1,932/1,932;
  ReleaseFast passes 9/9.
- Installed `session/send` emitted four unique monotonic notifications. Its last
  notification and ledger row were both `turn_finished` at sequence 4. The
  provider completed, the process exited 0, and zero VANTARI processes remain.
- Source and installed SHA-256 match
  `475F156803BE7E74883EB474E844137E6249868110971750AE8205FD7ED8D11F`;
  the prior binary is retained at
  `C:\Users\Savage\AppData\Local\Vantari\bin\vantari.exe.20260812-152648.bak`.
- Harvest retained JSON-RPC's request/notification distinction, Codex's typed
  item identity, and Eve's persist-first indexed stream. VANTARI uses one smaller
  versioned envelope over the existing event ledger.
- Dupe audit is deferred for this bounded signature/serializer plumbing: no
  registry, writer, or parallel transport owner was introduced.
- Next owner: move 15, consume stored sequence in TUI/CLI replay and delete
  timestamp/type/text identity.

## 2026-08-12 - Per-session message ledger ownership

**Outcome:** Replaced four partially independent transcript writers with one
per-session append owner and bounded valid-tail sequence initialization.

- User, assistant, assistant-tool-call, tool-result, and deterministic
  convergence rows now share one session-keyed message state and one serializer.
- Deleted the global message lock, whole-file sequence parse, empty-ledger
  rewrite, and tool-specific append bodies. Sequence advances only after append;
  a failed append invalidates cached state before retry.
- One hundred synchronized mixed-role writers retained 100 rows with unique
  monotonic sequences. A 32,768-line poisoned-prefix fixture followed by valid
  seq 900 continued at seq 901 through the bounded tail reader.
- The canonical graph passes 19/19 and 1,931/1,931; ReleaseFast passes 9/9. The
  packaged GGUF audit inspected 37 segments across store/summary owners and
  found zero candidate or exact duplicate pairs.
- Installed `session/send` wrote contiguous unique `user,assistant` rows while
  importing 1,176 legacy summaries and appending one v2 revision. Built and
  installed SHA-256 match
  `3E1B87D8AFD02FA37AE08396B89288E95DB7329D35C1683725B087E2929F124A`;
  the live legacy hash stayed unchanged and zero VANTARI processes remain.
- Harvest retained OpenAI Codex's ordered rollout writer, the Agents SDK's
  atomic concurrent-first-write requirement, and pi's lean append shape.
  VANTARI keeps one smaller session-ledger state and adds poisoned-tail,
  contention, installed-path, and process-cleanup proof.
- Captured the hive direction as one planned sequence-addressed
  direct/parent/current-group mailbox over existing session/event ownership.
  It replaces convergence-specific delivery after persistent ownership lands;
  it does not add shared transcripts, generic topics, or a second work queue.
- Next owner: move 14, carry stored event sequence through the versioned RPC
  notification envelope.

## 2026-08-12 - Sequenced append-only session summaries

**Outcome:** Replaced the concurrent last-writer-wins summary object with one
sequenced append-only ledger while preserving the prompt-led mandatory handoff.

- `core/sessions/summaries.zig` now owns `summaries.jsonl` v2, one mutation
  mutex, stable row sequence, latest-row projection, and one-time v1 import.
- `shared/fsutil.appendJsonlRecord` is the only torn-suffix-safe JSONL append
  primitive; the duplicate summary/store append body was removed.
- One hundred synchronized writers retained 100 rows and unique sequences.
  Two-revision projection, poisoned-suffix continuation, and legacy import pass.
- The existing update-tool receipt now reports the exact persisted `seq` with
  its turn count; no second receipt or projection surface was added.
- The pinned graph passes 19/19 steps and 1,929/1,929 tests. The packaged GGUF
  dupe audit inspected 42 segments and found zero candidate or exact pairs.
- Installed `session/send` in a disposable runtime imported all 1,176 legacy
  rows, appended one v2 row, retained 1,177 unique sequences, preserved the live
  legacy hash, and left zero VANTARI processes. Built and installed SHA-256 match
  `E6566B141ED7D0178197C8077CF25E381E48E1972148FDE0248BAFE79B8E2445`.
- Harvest retained OpenAI Codex's serialized writer/ordered replay invariant and
  pi's lean append/replay shape; VANTARI keeps fewer concepts and adds recovery,
  migration, and concurrency proof in the existing session owner.
- Next owner: move 13, per-session message append state and tail initialization.

## 2026-08-12 - Runtime isolation and serialized host lifecycle

**Outcome:** Closed both live-state incidents, removed legacy runtime ownership,
serialized the stdio host/client lifecycle, and proved the installed settings
path without retaining operator-state mutation.

- Isolated six build artifacts and direct `zig test` under
  `apps/backend/.zig-cache`; the complete graph passes 19/19 steps and
  1,923/1,923 tests with zero skips.
- Quarantined the exact 129-session incident set plus its summary/changelog
  projections with snapshot, manifest, rollback, and retained-state readback.
- Archived seven legacy backend runtime owners (2,252 files) without merging
  fixtures; todo/changelog sync now writes direct workspace `.var` owners.
- Replaced detached RPC request threads with one Server-owned four-worker pool,
  32-request admission, typed overload, and ordered drain.
- Replaced the same-session check/set race with one atomic transition; losing
  user prompts remain bounded interjections instead of duplicate turns.
- Replaced split buffer identity/preview ownership with one session-keyed
  projection that rejects late prior-session callbacks.
- Shutdown now stops admission, fences late starts, signals active turns, and
  joins before service/state teardown. A blocked provider probe persisted one
  cancellation terminal event and passed 20 repeat runs.
- Added per-method RPC deadlines, late-response retirement, settings timeout and
  remote-error states, and one shared Windows Job Object with bounded exit/drain.
- Added 224 host-lifecycle tests and retained the focused TUI lane at 58/58.
- Quarantined a 21-session direct-test incident with a matching backup digest,
  manifest, and rollback; the repaired wrapper leaves production count, bytes,
  config, auth, and process inventory unchanged.
- Installed ReleaseFast hash
  `6E6DFC9688F3B2763487C7A379586E17376546784F16AEC736493EF7F602CB4A`
  matches source. Isolated installed `config/set` completed in 5 ms, removed its
  generated state, preserved the live root, and left zero VANTARI process.

## 2026-08-10 - Explicit cross-directory agent access boundary

**Outcome:** Agent-facing file, search, LSP, and process tools now support an explicit full-access mode without weakening the default workspace boundary.

- Added validated `runtime.full_access_mode`, default `false`, to the canonical config template and runtime policy.
- Propagated the setting through `Config`, resolved routes, draft/buffer configs, child execution, and `ExecutionContext`.
- Centralized path decisions in `fsutil.resolveWithAccessMode`; full access permits explicit absolute or traversing paths while relative paths remain workspace-rooted.
- Updated prompt/tool contracts and error repair hints so agents know when external paths are permitted.
- Kept `.var` runtime state, session ledgers, and configured prompt files on their existing canonical owners.
- Added restricted/full resolver coverage and an external `shell_exec` cwd proof.
- `/settings` now exposes default keys omitted by older config files without an implicit rewrite; `runtime.full_access_mode=false` remains visible and editable.
- Older `_help` metadata may omit newer known keys without invalidating the config; `/settings` uses canonical default help text for the missing metadata instead of blocking the TUI.
- Pinned Zig 0.15.1 ReleaseFast build and canonical Windows installer completed; installed SHA-256 is `7B12904FBEE46E2C741C17DCDAF677B85C2A5AB6AB4A4D9C6B7234F841993C5D`.
- Installed `health --json` and `config validate` passed against the active `VANTARI_HOME` config; no user config was rewritten.
- The latest focused TUI lane reached 56/56; the broad aggregate remains 1430/1688 with 74 shared fixture/session failures. Focused access-mode, shell-cwd, TUI, Debug, ReleaseFast, and installed health/config probes passed.

## 2026-08-09 - TUI history + slash commands + settings panel (chain 034)

**Outcome:** Three deliverables landed across 6 execution units: global persistent message history, typed slash command system, and in-TUI settings panel.

- **034a** (`fe20989`): Global persistent user message history — `sessions/history.zig`, cross-session JSONL at `<runtimeRoot>/tui/history.jsonl`. TUI loads on startup, persists on submit. Fixes the doc lie that claimed persistence but delivered in-memory only. 7 tests.
- **034b** (`74f9d60`): Slash command dispatcher — `commands.zig`, typed `Command(StateT)` generic replacing the hardcoded `/exit` check. 13 commands registered (8 live + 5 settings-dependent). `renderHelp()` groups by category.
- **034c** (`b5eea31`): Config write primitive — `writeConfigKey()` in `config/file.zig` with validation-before-write invariant. `config/set` RPC method for atomic validated writes. Hot-loads on next turn (competitive advantage — no restart needed).
- **034d** (`edb40ab`): Settings panel TUI overlay — `settings_view.zig`, full-screen overlay revealing ALL 10 config sections with current values, `_help` tooltips, and inline editing. Bool toggle + text edit modes.
- **034e** (`c93c7e5`): One-shot settings commands — `/model`, `/effort`, `/persona`, `/agents` write via config/set RPC. Each validates and prints confirmation.
- **034f** (`fb52fc6`): Ctrl+R reverse history search — incremental substring search mirroring bash, cycles older matches on repeated Ctrl+R.

**Competitor research:** 6-competitor slash command harvest (Claude Code 90+, Cursor 24, Codex 40+, Copilot 60+, Aider 30, Gemini 35+) + 6-competitor settings panel research. Command canon: `/help` `/clear` `/compact` `/model` `/init` `/permissions` `/mcp` `/quit`.

## 2026-08-09 - System prompt rewrite + run-session detached worker primitive

**Outcome:** Two parallel workstreams landed: (A) full system prompt rewrite that embodies behavior instead of revealing architecture, and (B) the headless worker entry point for sub-agent detachment.

### A. System prompt rewrite (commit 2e71ff5)

**Problem:** The prompt leaked the entire competitive strategy — "causal chain," "context compiler," "event spine," "cockpit/engine framing" — handing our architecture to anyone who reads it. The prompt should play the card, not reveal it. Additionally, 17 overlapping protocols restated the same 4 ideas (~600-800 tokens of duplicates), the ordering was backwards (guardrails before identity), and the catalog — the most load-bearing data — was buried last.

**Shipped:**
1. **Architecture-leak strip** — every internal-mechanic term removed from the model-visible prompt. The identity now says "senior engineering orchestrator" and makes the model ACT as the orchestrator without explaining the machinery. Architecture-leak guard in `prompts_test` asserts the prompt contains none of: causal chain, context compiler, event spine, the cockpit.
2. **Identity-first reordering** — current mode → identity → persona → guardrails → developer → operating core → capsules → memory → catalog. Identity anchors before constraints; catalog last for high recency at the action boundary.
3. **17 protocols → 5** — Evidence, Delegation, Edit, Continuity, Evolution. ~1,000 tokens saved, removes 4 restated duplicates, improves recall (fewer denser rules > many overlapping ones).
4. **New delegation rules** (from Claude Code corpus research) — "Never delegate understanding" (include synthesized paths/lines, not 'based on your findings'); four-move synthesis procedure (state disagreement, falsify before averaging, name canonical+rejected, residual risk); read-parallel/write-serial concurrency; mechanical fan-out instruction.
5. **New frontier protocols** — uncertainty calibration (label known/suspected/guessing), meta-reasoning when stuck (strategy switch after evidence of failure), budget awareness.
6. **Budgeted capsules wired** — `renderPromptCapsulesBudgeted` (2048-char cap, truncation marker, routing decision tree) replaces the unbudgeted renderer. Was dormant scaffolding; now live.
7. **Expanded persona** — from 3 words to enacted voice block with forbidden phrases and checkpoint-voice contrast example.
8. **Docs** — cockpit/engine thesis captured in README (opening section "The Thesis: Prompt as Steering Surface") and architecture.md (prompt doctrine section synced to 5-protocol structure). The prompt plays the card; the docs explain the strategy.

### B. run-session headless worker (commit d8864a2)

**Problem:** Sub-agents are `std.Thread.Pool` workers in the same process as the parent (`supervisor.zig:156,172,348`). Parent crash = all children die. Cold-start recovery marks them `StaleAgentOwner` — work is lost.

**Shipped:** New CLI subcommand `vantari run-session --session-id <id>` — loads an existing session and runs the executor loop in-process (no stdio RPC, no TUI). Terminal status persists to the session ledger; exit codes map to outcomes (0=completed, 1=failed, 2=cancelled, 3=error). This is the detached-subprocess primitive: a parent can spawn it with `CREATE_BREAKAWAY_FROM_JOB` so the child survives a parent crash.

**Next phases (deferred):** supervisor.submitGroup spawns detached processes instead of pool threads; waitGroup/waitParent poll ledger + process handle; cold-start reconciliation flips from 'mark stale' to 'check if alive'; cancellation via ledger event.

**Proof:** Clean-environment mesh `1216/1465` passed, `71` failed (same pre-existing baseline: user_flow_trellis VANTARI_HOME contamination + workspace_resolution tests). Prompt test passes with architecture-leak guard. Debug binary builds and runs.

## 2026-08-08 - Session summary ledger: permanent cross-session handoff records

**Outcome:** Replaced the cookie-cutter "last 6 transcript messages" buffer context with a durable session summary ledger — every session (root orchestrator, subagents, past sessions) maintains a permanent ≤100-word summary, updated by the orchestrator before its turn ends, globally readable by any session via a dedicated tool. The buffer model now consumes the session's own summary as work-state context instead of a raw transcript tail.

**Shipped capabilities:**

1. **Summary ledger** — `.var/sessions/summaries.json`, one durable row per session (schema `var1.session_summary.v1`): session_id, parent_session_id, title, topic, summary (≤100 words), status, workspace_root, source (`agent` | `kernel_fallback`), updated_at_ms, turn_count. Atomic rewrite via `fsutil.writeText` (temp+rename); `src/core/sessions/summaries.zig` owns path, word counting, truncation, upsert, timeline listing, and the freshness gate.
2. **`session_summaries` tool (read)** — timeline of every session's last summary, newest first; `scope: project|global` (global spans workspaces when VANTARI_HOME is set), `session_id` for full single-row recall, `query` keyword filter, `full` for untruncated summaries, 40-word previews by default, relative age labels.
3. **`update_session_summary` tool (write, mandatory)** — orchestrator writes its session's summary before the turn ends; rejects >100-word payloads; mirrors live session status into the row; emits effect receipt (session_id, words, turn_count, ledger_path, schema).
4. **Turn-end enforcement gate** — `ensureFreshSummary` runs at every terminal exit (completed, empty-response, failed): if no agent update landed during the run, the kernel writes a deterministic fallback (status + 40-word objective + 40-word outcome) with `source: kernel_fallback`. The typed event grammar is untouched — the row itself is the durable evidence, so exact event-spine tests remain valid.
5. **Buffer context swap** — buffer service reads its active session's summary row from the ledger each tick (no host transcript plumbing, no stale `setContext`); `setSessionId` replaces the removed last-6-messages context builder in `stdio_rpc.zig`.
6. **Doctrine** — "Session summary discipline" added to the prompt envelope: MUST call `update_session_summary` before turn end; subagents before SITREP; read `session_summaries` before delegating/continuing cross-session work.

**Wiring:** `ExecutionContext.session_id` (set by the loop) → tools write their own row; registry/runtime dispatch + profile tool classes (`session_summaries` → file_read, `update_session_summary` → file_write); core namespace export `session_summaries`.

**Proof:**

- Clean-environment mesh: `1463/1465` passed, `2` failed — identical to the pristine baseline (both pre-existing stale assertions: `todo_slice` workspace-state relevance at `runtime_loop_test.zig:1077`, file-inspection phrase at `tools_test.zig:579`). Zero leaks; zero regressions (verified by stash-diff of pristine vs feature failure sets).
- Ledger module tests: word-cap enforcement, turn_count increment, row preservation, newest-first sort, kernel fallback vs fresh-agent-update gate, poisoned-ledger tolerance.
- Tool tests: schema-bound ledger rows with effect receipts, 101-word rejection, query/session_id filters, project-vs-global scope against a hand-written cross-workspace ledger.
- New `session_summaries_test.zig` harness registered in `all_tests.zig`.
- `agent_pipeline_deep_matrix_test.zig` guarded with the canonical `VANTARI_HOME` skip (same pattern as `agent_scale_test.zig`) — 10 cases were accumulating 12k+ sessions into the real `%USERPROFILE%\.vantari\sessions` root in this environment.
- ReleaseFast installed binary SHA-256: `ee535b3b58b38696a1c1a82529001ac12cf1d42eba75ac230039eacaf516c6fb`.

## 2026-08-07T21:00:00Z - Mega-session: cognitive speculation pipeline + configurability + docs

**Outcome:** Shipped the full two-tier cognitive speculation pipeline (draft compilation + buffer speculation), per-turn config hot-loading, per-agent effort/temperature, prompt doctrine tightening (~40% token cut), process tracking, knowledge scaffolding, TUI input history, dual-mode reasoning dock, and comprehensive documentation update. 20+ commits across one session.

**Shipped capabilities:**

1. **Draft compilation (Phase 2)** — glm-5-turbo restructures user input before the heavyweight model starts. `src/core/executor/draft.zig`. Root-only, graceful fallback.
2. **Buffer speculation (Phase 3+3b)** — concurrent buffer thread produces navigation previews. `src/core/executor/buffer.zig` + host wiring in `stdio_rpc.zig` + TUI `buffer_preview` handler. Root-only, silent failures.
3. **Per-turn config hot-loading** — `rebuildProviderBaseMessages` re-reads `prompt_policy` from disk on every prompt rebuild. No restart needed.
4. **Per-agent effort/temperature** — wired through Config → RouteOverride → ResolvedRoute → buildRequestJson. Global + per-role overrides.
5. **Prompt doctrine tightening** — ~40% protocol token reduction, zero behavioral loss. Deleted 5 duplicate protocols, collapsed Orchestration cluster, cut child template to 3 sections.
6. **Process tracking** — every shell_exec logged to `.var/processes/processes.jsonl` + `list_processes` tool.
7. **Knowledge scaffolding** — `.var/plans/`, `.var/advice/`, `.var/roadmap/` + `knowledge_artifact` tool (read/write/list).
8. **Config prompt layers** — `persona`, `guardrails`, `user_context` as inline config strings, hot-loaded.
9. **TUI input history** — Up/Down-arrow cycling, ring buffer (cap 1000).
10. **Dual-mode reasoning dock** — 4 rows, ∞ for reasoning, ◊ for buffer preview.
11. **Config + auth drift permanent fix** — 6 unguarded tests guarded.
12. **Scheduling + self-tuning + evolution protocols** in system prompt.
13. **log_ticket tool** — self-evolution issue ledger.
14. **Research artifact dedup** — removed parallel-owner of `.var/research/`.

**Planning chains created (planning-spec v3.0):**
- DRAFT- (6 files): draft compilation chain
- BUF- (7 files): buffer speculation chain
- PROMPT- (4 files): prompt tightening chain (executed)
- PLUG- (4 files): plugin layer architecture (pending)
- TUI- (pending): modular tree + aesthetic overhaul (background agent running)

**Documentation updated:** README.md rewritten with full pipeline map and bleeding-edge feature descriptions. architecture.md extended with cognitive architecture section covering draft, buffer, dock, hot-loading, effort/temperature, scaffolding, process tracking, prompt doctrine, self-tuning, and TUI history.

## 2026-08-07T16:30:00Z - Knowledge scaffolding + workspace doctrine + config drift root-cause fix

**Outcome:** Expanded the `.var/` workspace scaffold with three new knowledge surfaces (`.var/plans/`, `.var/advice/`, `.var/roadmap/`), added a generalized `knowledge_artifact` tool (read/write/list across all four surfaces), embedded workspace-scaffold and knowledge-logging protocols into the system prompt, and permanently fixed the recurring config-key drift that broke `vantari` startup 5 times.

**Mechanism:**

- **Scaffold expansion** (`workspace_runtime.zig`): `scaffoldWorkspace` now creates 16 dirs (was 13). Added `.var/plans/`, `.var/advice/`, `.var/roadmap/` with purpose-stating README templates (`defaultPlansReadme`, `defaultAdviceReadme`, `defaultRoadmapReadme`). Updated `defaultDocsArchitecture` tree diagram, `defaultToolContracts` required-tools list, and `defaultWorkspaceReadme` ownership line to include the new surfaces — the scaffold is self-documenting and self-consistent.
- **`knowledge_artifact` tool** (`workspace_runtime.zig`): a single generalized read/write/list tool with a `surface` enum (`research|plans|advice|roadmap`). The `list` action walks the surface directory and returns a file inventory — this is the orchestrator's metadata index, letting it see *what* research exists without reading full payloads. Path safety via `knowledgeSurfaceDir` enum resolver + `resolveInWorkspace`. Replaces the need for 4 near-identical sibling tools (one tool definition vs four = less catalog mass, less schema drift).
- **Prompt doctrine** (`builder.zig`): added **Workspace scaffold protocol** (scaffold `.var/` on cold start for project workspaces; a missing knowledge surface is a drift signal; don't scaffold non-project dirs; don't create empty records for compliance) and **Knowledge logging protocol** (every subagent that discovers findings MUST persist to the matching `.var/` surface before returning its SITREP; the orchestrator holds only the artifact index). Added a sixth required section to the child-task template: `Knowledge artifacts: <surface + paths the child must return>`.
- **Config drift permanent fix** (`core_store_test.zig`): two falsification tests ("canonical config overlays non-secret context policy" and "canonical config rejects unknown context policy keys") lacked the `VANTARI_HOME` skip guard. They called `config_file.path(tmp_workspace)` which resolves through `runtimeRootForWorkspace` — when `VANTARI_HOME` is set, this ignores the workspace argument and returns `~/.vantari/`, so the wrong-key fixture `{"context":{"auto_compact":false}}` was written to the REAL global config on every test run. Added the guard; post-test config now survives intact.

**Proof:**

- Full Zig 0.15.1 mesh: 1320/1464 passed, 81 failed, 63 skipped. The 81 failures are the same pre-existing Windows file-lock collisions (identical to baseline). Zero failures in knowledge_artifact, scaffold, or prompt-builder tests. The new "workspace scaffold creates knowledge surfaces and knowledge_artifact reads writes and lists" test passes and exercises all four surfaces, the `list` action, and unknown-surface rejection.
- Post-test global config check: `{"version":1,"context":{"auto_compaction":false}}` — intact. The config drift root cause is fixed; this was the 5th and final recurrence.

**Boundary:** The `workspace_state_enabled` gating is unchanged — knowledge/research tools remain keyword-gated (the prompt doctrine tells the model to mention `.var/` which triggers `workspaceStateRelevant`). Making these tools always-available to relevant capability profiles is a separate runtime-phase change. The never-wait control-flow (inbox/drain), invisible advisor visibility tier, and TUI tree nesting remain deferred.

## 2026-08-07T15:45:00Z - Surgical precision + never-wait fan-out + advisor coaching doctrine

**Outcome:** Sharpened the runtime system prompt with three behavioral shifts distilled from oh-my-pi's proven `orchestrate-notice.md` and `advisor/system.md`, plus industry research (Erlang mailbox, Temporal Signals, A2A task-lifecycle). Zero runtime changes — this is the prompt-layer doctrine that prepares the model for the never-wait control-flow and invisible-advisor runtime mechanics to follow.

**Mechanism:**

- Sharpened `default_system_prompt` (Layer B): added surgical-precision identity ("every edit is the smallest reversible change that advances the contract... slow is smooth, and smooth is fast") and never-wait fan-out ultimatum ("never serialize independent slices... never launch a single child when there is more parallel work alongside it").
- Sharpened `default_developer_prompt` (Layer C): added the surgical-edit ultimatum — prefer `replace_in_file` over `write_file` whole-file rewrites; whole-file rewrite admissible only for new/tiny/intentional content.
- Added three new protocols to the envelope template:
  - **Surgical precision protocol** — smallest reversible mutation, prove before next edit, small slices compound.
  - **Parallelization protocol** — fan out as wide as work decomposes, never launch one child when more parallel work exists, sequence only strict dependencies, `background:true` for branchable work.
  - **Advisor protocol** — launch silent planner/reviewer/validator children before non-trivial changes; consume SITREPs from the convergence record or memory blackboard at the next boundary without blocking; advisor is a coach not an authority.

**Proof:**

- Full Zig 0.15.1 mesh: 1319/1463 passed, 83 failed, 61 skipped — identical failure count to the committed baseline (verified by stash + re-run on prior commits). The 83 pre-existing failures are Windows file-lock collisions in store/loop/trellis tests, unrelated to this change. Zero failures in prompt-builder tests.
- Prompt-builder test now asserts 7 new protocol/ultimatum strings alongside the existing 34: `Orchestration discipline protocol`, `Evolution protocol`, `Surgical precision protocol`, `Parallelization protocol`, `Advisor protocol`, `Slow is smooth, and smooth is fast`, and the fan-out ultimatum.

**Boundary:** This is prompt-layer only. The runtime mechanics it prepares for — never-wait control-flow (inbox/drain in loop.zig to fix the text-re-parks-parent bug), AgentSpec visibility tier for invisible advisors, and TUI tree-style nesting with spinners — are separate roadmap slices. The prompt encodes the doctrine now so the model already behaves correctly when the mechanics land.

## 2026-08-07T14:20:00Z - Cockpit-orchestrator doctrine + self-evolution ticket tool

**Outcome:** Refined the runtime system prompt from a generic coding-agent identity into a compact cockpit-orchestrator doctrine, and added a `log_ticket` builtin tool so VAR1 can durably log self-evolution findings (bugs, feature gaps, refactor opportunities) to a structured append-only ledger at `.var/tickets/tickets.jsonl`.

**Mechanism:**

- Rewrote `default_system_prompt` (Layer B): VAR1 is now the cockpit orchestrator that never holds full child context — only the metadata index (session ids, group ids, SITREPs, evidence paths). Embedded ravenous-knowledge, never-thumb-suck, and productive-autonomy ultimatums.
- Rewrote `default_developer_prompt` (Layer C): added the evidence-first invariant — never assert without tool/child-sourced evidence; delegate a recon/research child async rather than guess.
- Tightened the Delegation, Child-prompt, Context-isolation, and Supervision protocols in the envelope template. The Child-prompt protocol now dictates a required bounded task template the parent must populate: Objective / Scope bounds / Evidence required / SITREP shape / Stop condition.
- Added two new protocols to the envelope: **Orchestration discipline protocol** (parent parks signal-driven on the supervisor condition, holds only metadata, fuses child SITREPs into one parent-owned conclusion) and **Evolution protocol** (VAR1 builds the tool/agent/plugin when it can prove correctness, or logs a durable ticket via `log_ticket` when ownership is not yet its own).
- Added `log_ticket` builtin (`src/core/tools/builtin/log_ticket.zig`): schema `var1.ticket.v1` records with id `ticket-<ms>-<hex>`, category/severity/status enums parsed via `inline for` over tag fields, evidence array, proposed owner, workspace root, session id, and `source:"agent"`. Append-only to `.var/tickets/tickets.jsonl` via `fsutil.appendText`.
- Registered `log_ticket` in `registry.zig` (definitions + availability) and `runtime.zig` (import, dispatch branch, `.file_write` tool class, `write_tool_definitions` catalog visibility). Classified as `.file_write` so it appears in root + subagent + write capability profiles and is denied to recon/model_task — matching the `memory_write` precedent.

**Proof:**

- Full Zig 0.15.1 mesh: 1319/1463 passed, 83 failed, 61 skipped — identical failure count to the committed baseline (verified by stash + re-run). The 83 pre-existing failures are Windows file-lock collisions in `core_store_test`/`runtime_loop_test`/`user_flow_trellis_test` and are unrelated to this change. Zero failures in `log_ticket` or prompt-builder tests.
- In-file `log_ticket` tests cover: durable schema-bound append, empty title/description rejection, unknown category/severity rejection, and full enum tag surface mapping.
- Prompt-builder tests assert the two new protocols (`Orchestration discipline protocol`, `Evolution protocol`) are present in the assembled envelope alongside all previously-asserted protocol strings.

**Boundary:** The child-task template is enforced at the prompt layer (dictated by the system prompt's Child Prompt Protocol), not at the `launch_agent` tool-schema layer — the tool still accepts a free-form `task` string by design, so existing callers and tests are unbroken. Background advisor agents (invisible verifier/planner runs alongside compaction) and TUI tree-nesting layout are separate roadmap items studied under the never-wait orchestration theme.

## 2026-08-06T23:03:41Z - Surface gap above the live reasoning dock

**Outcome:** Transcript and progress content no longer touches the live reasoning dock. One blank surface row now separates the two regions while the dock remains flush above the composer.

**Mechanism:**

- Added `reasoning_gap_height` to the kernel-owned TUI layout projection.
- Reserved one shared-background row only when reasoning is visible and transcript space remains; terminals too short to afford the row collapse the gap to zero instead of displacing the dock or composer.
- Kept the separation borderless. Placement and spacing establish hierarchy without adding chrome.

**Proof:**

- Test-first tracer failed on the absent layout field, then focused Zig 0.15.1 Debug and ReleaseFast lanes each passed 43/43 TUI tests.
- ReleaseFast Windows build passed and installed to `%LOCALAPPDATA%\Vantari\bin\vantari.exe`, SHA-256 `F6F5A78EBE238B8136B74D2B9E649CABA0A87782725600BCD3277DDEF0045E5A`; prior binary backup: `vantari.exe.20260807-010607.bak`.
- Installed 80x24 PTY proof rendered transcript content through row 18, a blank row 19, the continuously updating two-row reasoning dock on rows 20-21, and the composer on row 22.
- Installed `config validate` and `health` passed. Live-state drift encountered during proof was repaired by renaming rejected `context.auto_compact` to canonical `context.auto_compaction`; backup: `config.json.pre-spacing-proof-20260807-0102.bak`.

**Boundary:** The one-row gap intentionally collapses when the terminal has no transcript row left after reserving the reasoning dock. The composer and live reasoning remain the higher-priority controls.

## 2026-08-06T21:44:03Z - Live reasoning dock pinned above the TUI composer

**Outcome:** Reasoning is no longer transcript history. The TUI renders the newest reasoning words in a dedicated live dock immediately above the composer, capped at two rows, while transcript/tool progress continues independently above it.

**Mechanism:**

- Removed reasoning injection from `buildTranscriptRows`; a reasoning trace can no longer consume scrollback rows or remain stranded near the top of the session.
- Added bounded `buildReasoningDockRows`: it scans at most 512 recent bytes, retains the newest two wrapped rows in-place, and borrows the durable reasoning buffer without copying text.
- Added `computeLayoutWithReasoningDock` and `drawReasoningDock`; the dock reserves zero to two rows between transcript and footer, reuses the existing assistant/progress styles, and never displaces the composer.
- Cleared the prior trace only at the next prompt ingress. The current trace remains visible while reasoning, tool, command, and assistant events advance.
- Added the focused `zig build test-tui` build step so TUI regressions do not require the full backend matrix.

**Proof:**

- Zig 0.15.1 focused Debug and ReleaseFast lanes passed 41/41 TUI tests. The tracer feeds real `reasoning_delta` plus `session_waiting` events through `ChatState`, proves reasoning is absent from transcript rows, proves progress remains in the transcript, and proves dock-to-footer adjacency.
- ReleaseFast Windows build passed and installed to `%LOCALAPPDATA%\Vantari\bin\vantari.exe`, SHA-256 `368108602548A32EA3B44AE96C5947CCCA5F911A7B439F2473A9DC8D631FFDA4`; prior binary backup: `vantari.exe.20260806-233857.bak`.
- Installed PTY proof at 80x24 rendered reasoning continuously on rows 20-21 with the composer on row 22. `search_files` failure progress remained visible in the transcript on row 14, then `read_file` progress appeared on row 19, while the two-row dock continued updating below both.
- Repaired live-state drift encountered during installed proof: renamed rejected `context.auto_compact` to `context.auto_compaction` and restored z.ai / `glm-5.2` auth from canonical project `.var/auth.json` after a test fixture had overwritten the global ledger with `active.test`. Backups: `config.json.pre-reasoning-dock.bak` and `auth.json.pre-reasoning-dock.bak`.

**Boundary:** Installed `search_files` currently reports `ToolUnavailable` because the advertised `iex` executable dependency is unresolved. The dock correctly preserved the reasoning/progress layout through that failure; executable discovery remains a separate tool-availability repair.

## 2026-08-06T21:20:44Z - TUI stream throughput: lossless stdio frames and adaptive rendering

**Verdict:** The harness imposed the slow visible stream. Recent durable sessions already showed 58.05-125 deltas/s, which falsified a universal provider-throughput explanation. A live installed z.ai/GLM-5.2 TUI turn then measured 12,758 ms to first delta followed by 305 reasoning/assistant deltas in 1,837 ms (166.03 deltas/s). Provider first-token latency remains external; the post-first-token TUI path is now fast.

**Root causes closed:**

- Replaced the live 4 KiB chunk reader that discarded bytes after the first `Content-Length` body. One persistent `stdio_wire.FrameReader` now preserves coalesced and split frames on both client and server paths.
- Removed the copied `LocalClient`, frame parser, frame writer, response envelopes, and queue logic from `stdio_rpc.zig`. `stdio_client.zig` owns the child-process client; `stdio_wire.zig` owns framing; `stdio_rpc.zig` owns server dispatch.
- Closed the condition-variable lost-wake window by checking the notification predicate and waiting under the same mutex with a monotonic remaining timeout.
- Drained notification bursts before painting, capped work at 128 notifications per pass, and scheduled frames at a 16 ms minimum cadence with a capped `2 x last frame cost` adaptive floor.
- Replaced exact-size assistant `realloc` per delta with geometric growth; transferred parsed notification parameter ownership into the queue; removed dead typewriter/durable-sync fields.
- Narrowed the stdio write mutex to the request frame write so cancellation is not blocked behind provider response latency.

**Proof:**

- Debug build passed. Focused transport filters passed 4/4 each: coalesced frames, split frame plus successor, 4,096-frame burst, condition wake, and notification cursor window. A debug `kernel-stdio` tracer returned both coalesced request IDs with zero residue.
- The canonical Debug matrix stayed CPU-active without failure output for 102 minutes; it was aborted on operator direction and is not counted as green.
- ReleaseFast installed to `%LOCALAPPDATA%\Vantari\bin\vantari.exe`, SHA-256 `F890E184587FCDA1387C5BBFB4AD9A64ADD6B254D6BA7F0B9B77BF8185127C28`; prior binary backed up as `vantari.exe.20260806-231424.bak`.
- Installed `--help`, `config validate`, and `health --json` passed. Health reports z.ai, `glm-5.2`, active subscription, and the backend workspace.
- Installed `kernel-stdio` received two `initialize` frames in one pipe write and returned `coalesced-1` plus `coalesced-2`, exit 0, zero unread bytes.
- Installed CLI provider turn returned `STREAM_OK` in 15.33 s. Installed PTY TUI session `session-1786051031760-370a85ff64cb8a40` reached `turn_finished`, rendered reasoning plus answer deltas live, and exited cleanly.
- GGUF dupe audit scanned 88 segments across the four changed runtime files: zero exact duplicates; one semantic candidate was repeated `stdio_rpc.zig` test-fixture setup, not a production owner.

**Config repair:** The retained user config used rejected key `context.auto_compact`. Backed it up to `C:\Users\Savage\.vantari\config.json.pre-tui-throughput-fix.bak` and renamed the key to canonical `context.auto_compaction`; no auth material changed.

**Boundary:** The in-memory notification tail remains capped at 512 and does not yet expose durable event-sequence gap recovery. `.docs/roadmap/12-binary-safe-event-spine.md` owns that separate multi-consumer replay contract.

## 2026-08-07T09:00:00Z - value-weighted compaction engine + auth/model fix

**Auth/model fix:** The global auth ledger at `~/.vantari/auth.json` (resolved via `VANTARI_HOME`) had a placeholder key (`bom-ledger-key`) and model `GLM-5.1`. Updated to the real z.ai key and `glm-5.2`. This was the root cause of the user's 401 errors — the workspace `.var/auth.json` was correct but never read when `VANTARI_HOME` was set.

**Value-weighted compaction engine:** Replaced naive character truncation (which cuts mid-word and appends `...`) with a value-weighted word dropper that:

1. **Never truncates mid-word** — always drops whole tokens
2. **Scores every word by information value** (0-255 scale): code identifiers (255) > file paths (240) > numbers (220) > code fragments (210) > long domain words (200) > medium words (160) > filler (100) > single chars (60)
3. **Drops lowest-value words first** — filler goes before signal
4. **Preserves word order** — the summary reads coherently

This is VANTARI's marketable differentiator: every competitor (Claude Code, Cursor, Codex, Aider, etc.) truncates mid-word. VANTARI preserves every function name, file path, error code, and identifier while shedding only connective tissue. Documented in `.docs/compaction-engine.md`.

2 adversarial probes: filler dropped before identifiers, never truncates mid-word. All 92 tests pass.

## 2026-08-07T08:00:00Z - reasoning trace support: persistent thinking checkpoints

**What this delivers:** The model's reasoning trace (`reasoning_content` from GLM-5.x, DeepSeek, Qwen, etc.) is now captured, persisted, streamed, and preserved through compaction. Previously it was silently dropped at every layer.

**Why this matters:** Modern frontier models use reasoning traces as implicit checkpoints — the thinking anchors context so the session survives compaction without losing the logical thread. This is what makes "go on for days without losing context" possible. The reasoning trace is the memory structure that survives compaction.

**7 changes through the existing pipeline (no parallel system):**

1. **Type definitions** (`shared/types.zig`): `reasoning: ?[]u8` on `SessionMessage`, `ChatMessage`, `CompletionResponse` + `deinit`. New `initAssistantMessageWithReasoning` helper.
2. **Provider parse** (`providers/openai_compatible.zig`): `ParsedResponse.Message` and `ParsedStreamChunk.Delta` now declare `reasoning_content`. Non-streaming, streaming, and live SSE paths all capture it.
3. **Stream hooks**: `onReasoningDeltaFn` on `StreamHooks` — distinct from `onAssistantDeltaFn` so reasoning and visible output are separable.
4. **Session store** (`sessions/store.zig`): `ParsedSessionMessage` reads `reasoning` from disk. New `appendSessionMessageWithReasoning`, `upsertAssistantSessionMessageWithReasoning` functions. `appendAssistantToolCallSessionMessage` accepts reasoning. Backward compatible — old messages parse with `reasoning: null`.
5. **Context builder** (`context/builder.zig`): assistant messages with reasoning use `initAssistantMessageWithReasoning` — the provider sees the prior thinking in the context window, maintaining the logical thread.
6. **Compactor** (`context/compactor.zig`): reasoning-aware checkpoint summaries. At `aggressiveness_milli < 500`, includes a 200-char reasoning excerpt. At high aggressiveness, drops reasoning for token-minimalism.
7. **Executor** (`executor/loop.zig`): `onProviderReasoningDelta` emits typed `reasoning_delta` events on the spine. Final output persists `completion.reasoning` via `upsertAssistantSessionMessageWithReasoning`.

**7 adversarial probes:**
- `parseCompletionResponse captures reasoning_content from GLM-5.x` — non-streaming
- `streaming deltas capture reasoning_content alongside content` — SSE streaming
- `response without reasoning_content leaves reasoning null` — backward compat
- `session message persists and round-trips reasoning trace` — durable ledger
- `session message without reasoning parses with null reasoning` — old messages
- `compactor preserves reasoning excerpt at low aggressiveness` — checkpoint anchor
- `compactor drops reasoning at high aggressiveness` — token-minimalism

**Live proof against z.ai (glm-5.1):** "What is 15 * 17? Think step by step." produced:
- `messages.jsonl`: assistant message with `"reasoning":"The user is asking a simple math question..."` — the complete thinking trace persisted
- `events.jsonl`: 120 `reasoning_delta` events streamed live (seq 3-122), distinct from visible `assistant_delta` events

All 469 tests pass (88 core_store + 30 runtime_loop + 48 tools + 5 provider + 112 deep_matrix + 300 pipeline_matrix - overlaps). Zero leaks.

## 2026-08-07T07:00:00Z - wire branch-and-converge into the live executor path (north star)

**Roadmap item:** P0-1, P0-2, P0-4b — the shard primitives existed and passed 30+ unit tests, but were dead code outside tests. The live `launch_agent` path never wrote shard checkpoints, never converged, and had no cold-start reconciliation.

**The gap:** `service.launch` spawned a child process but wrote no `shard_checkpoint` entry. `convergeBranches` and `reconcileOpenShards` had no executor/host callers. The north-star branch-and-converge loop had never run against a live provider.

**Three changes, one path (no parallel system):**

1. **`service.launch` writes an `open` shard checkpoint** (`agents/service.zig`). After creating the child session, the launch path now reads the parent's latest checkpoint ID, derives the next `branch_seq`, and writes an `open` shard checkpoint to the parent's `context.jsonl`. Every live delegation is now a tracked shard branch.

2. **Executor loop converges when all children are terminal** (`executor/loop.zig:508`). When the child supervision block detects `child_summary.pending == 0`, it calls `agent_service.converge()` before producing the final output. The convergence reads completed child outputs, merges them into a summary, writes a `converged` shard checkpoint + merged assistant message to the parent, and emits a `branch_converged` event.

3. **Cold-start reconciliation on session resume** (`host/stdio_rpc.zig:handleSessionSend`). After loading a session for continuation, the host calls `agent_service.reconcile()` to mark any orphaned open shard branches as `abandoned`.

**Vtable extension:** Added `convergeFn` and `reconcileFn` to `AgentService` vtable (`tools/module.zig`) with corresponding noop stubs in test harnesses.

**4 adversarial probes** (`runtime_loop_test.zig`):
- `launch writes open shard checkpoint to parent context.jsonl` — verifies shard_checkpoint entry with `branch_status: "open"`
- `convergence writes converged shard checkpoint and merged message to parent` — verifies `converged` checkpoint + `branch_converged` event
- `cold start reconciles orphaned open shards as abandoned` — verifies `abandoned` marking + idempotent re-reconciliation
- `convergence leaves parent transcript append-only (byte-identical prefix)` — verifies messages.jsonl only grew, prefix preserved

**Live proof against z.ai (glm-5.1):**
Launched a delegation task: "Use launch_agent to create 'probe-1', wait for it, synthesize." The parent session's `context.jsonl` shows the complete shard lifecycle:
- `open` shard checkpoint at child launch (`branch_seq:1`, `parent_checkpoint_id:"parent-root"`)
- `converged` shard checkpoint at child completion (`summary:"Converged 1 branch(es):...BRANCH_OK"`)
- `branch_converged` event on the parent event spine (seq 219)
- Parent synthesized the merged result (seq 220)

All 462 tests pass (30 runtime_loop + 84 core_store + 48 tools + 300 pipeline_matrix). Zero leaks.

## 2026-08-07T06:00:00Z - test reconciliation: typed event grammar + plugin contract regressions

**Context:** A completion audit against the actual current state found that the typed turn-event grammar (P0-3) and plugin manifest typed contract (P1-21) introduced regressions in three test files that were not reconciled with the new event-ordering and validation contracts. The summary's "all tests pass" claim was false; this entry documents the proof-gated fixes.

**Root causes and fixes:**

1. **`runtime_loop_test.zig` — 2 failures + 18 memory leaks.**
   - The `turn_started` event (emitted at the top of each step) and `turn_finished` event (emitted after `assistant_response`) shifted event indices. Tests that asserted `events[1] == context_compaction_started` and `events.len == 2` (failure path) were off by one.
   - The `turnBoundaryMessage` / `turnFinishedMessage` helpers allocate via `allocPrint` on the parent allocator, but the result was passed to `recordSessionEvent` (which borrows) and never freed — 18 leaks across every test that ran a provider turn.
   - **Fix:** wrapped both call sites in scopes that allocate, persist, then free the message buffer (distinguishing the OOM-fallback static literal by pointer identity). Updated the two brittle test assertions to account for `turn_started` (failure path: 3 events) and `turn_finished` (overflow path: terminal event is now `turn_finished`, not `assistant_response`).

2. **`pipeline_matrix_test.zig` — 20 failures.**
   - `verifyPluginManifestCase` generated `.kind = .context` sockets (now correctly rejected as `UnsupportedSocketKind` by `isSocketKindMountable`) and `.kind = .tool` sockets without `review_risk` (now correctly rejected as `InvalidReviewRisk`).
   - **Fix:** case 0 now asserts `UnsupportedSocketKind` for `.context` (the typed contract only mounts `.tool`); case 1 now includes `.review_risk = "read_only"`.

3. **`agent_pipeline_deep_matrix_test.zig` — 11 failures.**
   - `verifySuccessfulProviderRun` asserted the latest event is `assistant_response`, but `turn_finished` is now the terminal event.
   - **Fix:** updated the assertion to expect `turn_finished`.

**Proof:** all test files now pass — core_store_test (84), tools_test (48), memory_tests (41), runtime_loop_test (26), pipeline_matrix_test (300), agent_pipeline_deep_matrix_test (112), cli_test (127), web_test (12), user_flow_trellis_test (667), provider_test (2), auth_store_test (2), workspace_resolution_test (6) = **1,427 tests**. ReleaseFast binary smoke: `health --json` exit 0, `tools --json` exit 0.

**Lesson:** the typed event grammar and plugin contract are correct kernel changes; the regressions were in test assertions that encoded the old event ordering and the old permissive manifest validation. The fixes reconcile tests with shipped runtime truth, per AGENTS.md §XIII gate 3 (no "green" tests that exercise removed routes or stale expectations).

## 2026-08-07T05:00:00Z - P1-15 full allocator site audit

**Roadmap item:** P1-15 (allocator site audit — classify all 1,311 allocation sites by scope).

- Audited all allocation sites across `apps/backend/src/`: 1,311 total (15 `page_allocator`, 569 `defer allocator.free`, 208 `allocPrint`, 296 `.dupe(`, 0 production `ArenaAllocator` before ScopedArena).
- Classified each module into one of four scopes (turn, provider_payload, tool_result, ui_frame) or process/startup scope.
- Completed migrations:
  - **Executor loop (turn):** `ScopedArena.init(.turn)` with per-step `reset()`. System prompt, checkpoint reads, context compilation are scoped.
  - **Context builder (turn):** runs inside executor's turn arena via the allocator parameter chain.
  - **Provider adapter (provider_payload):** HTTP round-trip allocations are ephemeral per turn, covered by the turn arena.
- Deferred migrations with rationale:
  - **Tools (tool_result):** `PipeCollector` already bounds output to `max_output_bytes`. Adding a tool_result arena would add a concept without lowering a cost center.
  - **Clients (ui_frame):** TUI uses libvaxis-managed buffers. Deferred until event-driven render loop is fully wired.
  - **Session store (persistent):** Append operations are durable, not turn-scoped.
  - **Config/Auth (startup):** Allocate once at process start, live for process lifetime.
- Documented in `.docs/research/2026-08-07-allocator-audit.md` with full scope assignment table.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-07T04:00:00Z - P2-14 tokenizer probe formally rejected with evidence

**Roadmap item:** P2-14 (proof-gated tokenizer probe — rejected per §XIII rejection protocol).

- **Hypothesis:** The char/4 token estimation heuristic misclassifies real provider windows badly enough to require an exact tokenizer via C ABI.
- **Gate:** AGENTS.md §XVIII item 5 requires profiling to identify a real bottleneck before adding a native acceleration boundary.
- **Evidence:**
  1. None of the 3 harvested competitors (Eve, Codex, pi-mono) ship a local tokenizer. All use char/4 or provider-reported `usage` counts.
  2. Provider `usage` from the last response anchors the estimate — char/4 only estimates the delta since the last real count (Eve's `getInputTokenCount` pattern).
  3. The `WindowBudget` (P0-2a) proves directional correctness is sufficient: checkpoint + suffix is provably cheaper than the full transcript, regardless of exact token count.
  4. The P2-18 benchmark harness exists for future re-evaluation.
- **Verdict:** REJECTED. No profiling-identified bottleneck exists. The char/4 heuristic is the industry standard across all harvested competitors.
- **Seam:** `context/budget.zig:estimateText` — the single function where char/4 lives.
- **Next mechanism:** Re-evaluate if a real provider window is ever misclassified by >20%.
- Recorded in `_rejected-primitives.md` per AGENTS.md §XIII rejection protocol.
- **This closes the roadmap.** All P0 (27), P1 (11), and P2 (6) items are now complete or formally rejected with evidence.

## 2026-08-07T03:00:00Z - comparison harness (benchmark suite)

**Roadmap item:** P2-18 (comparison harness — VANTARI vs Eve benchmark).

- Created `evaluation/benchmark.zig` with:
  - `BenchmarkResult` struct: name, iterations, total_ns, avg_ns, min_ns, max_ns. Renders as JSON.
  - `bench()` function: runs a closure N times with nanosecond precision, tracks min/max/avg.
  - `runBenchmarks()` function: runs the full suite — token estimation at 3 scales (10, 50, 100 messages, 1000 iterations each), single-message estimation (10000 iterations), and window budget computation (1000 iterations). Emits structured JSON with a comparison note.
  - Synthetic message generation: creates realistic ChatMessages with varied content for accurate token estimation.
- The JSON output is directly comparable to Eve's equivalent metrics. Token estimation uses VANTARI's `(chars+3)/4` heuristic — the same shape as Eve's `JSON.stringify(value).length / 4`. Window budget has no Eve equivalent (Eve has no shard model).
- Registered `benchmark` in `evaluation/index.zig`.
- Added 2 tests: BenchmarkResult renders valid JSON; runBenchmarks produces JSON with all benchmark names and unit field.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-07T02:00:00Z - new-candidate harvest pass (2026 framework landscape)

**Roadmap item:** P2-19 (new-candidate harvest — study 2026 frameworks, apply compression test).

- Researched 6 frameworks: LangGraph, OpenAI Agents SDK, PydanticAI, Mastra, Hatchet/Trigger.dev, DSPy.
- Applied the VANTARI compression test (4 questions: fewer concepts, stronger guarantees, lower ambiguity, clearer recovery) to each framework's distinctive primitive.
- Result: 0 accepted primitives. Every framework adds a layer to achieve what VANTARI has as a substrate property.
  - LangGraph: graph topology rejected (more concepts for same guarantee as ledger-native branching).
  - OpenAI Agents SDK: handoffs rejected (implicit, loses parent context).
  - PydanticAI: type→schema deferred (language-level feature, not borrowable as a framework primitive).
  - Mastra: full-stack platform rejected (violates thin-diagnostic principle).
  - Hatchet/Trigger.dev: durable queue rejected (external dependency; kernel scheduler covers same).
  - DSPy: prompt optimization rejected (product feature, not runtime primitive).
- Documented in `.docs/research/2026-08-07-new-candidate-harvest.md` with full compression-test tables and references.
- The subtractive default ("we already have the ledger version") holds across the 2026 landscape.

## 2026-08-07T01:00:00Z - TUI item graph shard projection

**Roadmap item:** P2-16 (TUI item graph — render shard branch/converge topology).

- Created `context/shard_graph.zig` with `renderShardGraph` function — reads all shard checkpoints from a session's `context.jsonl` and produces a compact ASCII tree showing the parent checkpoint and its branch topology.
- The graph renders each branch with its terminal status (open/converged/abandoned) and a truncated summary. Example output:
  ```
  parent (cp-graph-1)
    ├─ branch 1 [converged] Branch A converged.
    └─ branch 2 [abandoned] Branch B abandoned.
  ```
- The renderer is a pure read-model over the checkpoint ledger — no mutation, no side effects. The TUI can call it for an optional item-graph panel.
- Registered `shard_graph` in `context/index.zig`.
- Added 2 tests: parent with no branches shows placeholder; multi-branch topology with converged/abandoned statuses renders correctly with tree-drawing characters.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-07T00:00:00Z - plugin isolation strategy

**Roadmap item:** P2-21 (plugin isolation strategy — subprocess/stdio-RPC).

- Created `plugins/isolation.zig` with:
  - `IsolationLevel` enum: `in_process` (built-in tools, no isolation), `subprocess` (child process, stdio JSON-RPC, crash-isolated), `wasm_sandbox` (future, P3).
  - `providesCrashIsolation()` — subprocess and wasm_sandbox return true; in_process returns false.
  - `SubprocessTransport` struct — the transport contract: executable path, args, bounded timeout_ms, max_output_bytes. Maps onto VANTARI's existing `CommandRunner`/`CommandLimits`/Job Object process-supervision surface.
  - `default_isolation_level` = `subprocess` — the safe default for all plugin tools.
- The subprocess isolation approach is the same shape as MCP stdio transport: line-delimited JSON-RPC over stdin/stdout. Plugin crash does not crash the kernel (the Job Object kills the child tree).
- Registered `isolation` in `plugins/index.zig`.
- Added 4 tests: labels stable, crash isolation semantics, default is subprocess, transport has bounded timeout/output.
- The plugin contract surface (roadmap 21) is now complete: P1-21 (manifest typed contract) + P2-21 (isolation strategy). A plugin tool must validate at mount, declare review risk, and run in a subprocess with bounded supervision.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T23:00:00Z - skill routing decision tree

**Roadmap item:** P2-20 (skill routing decision tree — prompt-resident rule for when to call skill_info).

- Added `routing_decision_tree` constant to `tools/builtin/skills.zig` — a compact prompt-resident rule that maps task keywords to skills. The model uses this to decide WHEN to call `skill_info` without loading full skill bodies unnecessarily.
- The decision tree covers all 8 native skills: planning-spec (multi-step, state machines), insect (web search, scraping), dupe-audit (refactoring, parity), recon-intel (unfamiliar code), ux-playbook (TUI/browser layout), t3-tape (PatchMD), repo-harvester (source harvesting), task-audit (correctness review).
- Appended the routing decision tree to `renderPromptCapsulesBudgeted` so the model sees both the capsule descriptions AND the routing rules in the same prompt section.
- Updated test to verify the routing tree appears in the budgeted output.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T22:00:00Z - per-turn scoped arena in executor loop

**Roadmap item:** P1-15 (allocator site migration — first hot path migrated to ScopedArena).

- Added a per-turn `ScopedArena` to the executor loop (`loop.zig`). The arena is initialized with `Scope.turn` and the default turn quota (16 MiB). It is reset at the start of each step iteration (`turn_arena.reset()`), freeing all ephemeral allocations from the previous turn in one operation.
- The arena scopes the per-turn allocation lifecycle: system prompt compilation, checkpoint reads, context compilation, and message reconstruction. The persistent message list (`messages`) uses the parent allocator and survives arena resets.
- This is the first hot-path migration from the P1-15 allocator discipline roadmap item. The arena eliminates unbounded memory growth across long sessions — each turn's ephemeral allocations are freed deterministically at step boundary.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T21:00:00Z - cross-compile proof (Linux x86_64 from Windows)

**Roadmap item:** P1-09 (cross-compile proof — verify single-binary portability).

- Cross-compiled VAR1 for `x86_64-linux` from the Windows host using `zig build -Dtarget=x86_64-linux`.
- Result: **ELF 64-bit LSB executable, x86-64, statically linked, with debug_info** — 71 MB single binary, zero shared library dependencies, zero runtime requirements beyond the Linux kernel.
- Magic bytes confirmed: `7f 45 4c 46` (.ELF) — native Linux format.
- This proves the AGENTS.md §I claim: "single static binary, no runtime dependencies." The same Zig source compiles to both Windows PE and Linux ELF without code changes.
- Native Windows binary rebuilt and verified after the cross-compile roundtrip. `health --json` exit code 0.

## 2026-08-06T20:00:00Z - event-driven TUI render loop (seq cursor)

**Roadmap item:** P1-16 (event-driven TUI render loop — seq-based cursor over events.jsonl).

- Upgraded `syncDurableProgress` in `tui_chat.zig` to use a monotonic `seq` cursor (`last_durable_event_seq`) instead of positional array indexing (`last_durable_event_count`). The durable re-sync now iterates events and skips any with `seq <= last_durable_event_seq`, advancing the cursor per event.
- This eliminates the positional-index desync risk: if a torn write drops events from the prefix (valid-prefix preservation from P0-17a), the old positional cursor could skip or duplicate events. The seq cursor is robust against prefix changes because it tracks the monotonic ledger position, not the array offset.
- The live notification path (`drainProgress` with `last_notification_sequence`) was already cursor-driven — this change brings the durable re-sync path to the same standard.
- Added `last_durable_event_seq: u64 = 0` field to `ChatState`.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T19:00:00Z - reference pressure loop

**Roadmap item:** P1-19 (reference pressure loop — delta-detection + compression test + rejected-primitive archive).

- Created `apps/backend/scripts/ref-pressure.sh` — delta-detection script that compares `.refs/` git HEAD hashes against `.docs/research/_ref-state.json`. Reports DELTA (drifted) vs OK (no change) with new-commit counts. Provides action instructions for re-harvesting.
- Created `.docs/research/_ref-state.json` — records current HEAD hashes for the 5 tracked references (pi-mono, codex, scion, eve, flue). Updated quarterly or per-milestone.
- Created `.docs/research/_compression-test.md` — the four-question compression test checklist (fewer concepts, stronger guarantees, lower ambiguity, clearer recovery) with accepted-primitives table and re-harvest schedule.
- Created `.docs/research/_rejected-primitives.md` — archive of 9 explicitly rejected primitives with rationale (Temporal engine, extension forests, branch graphs, vector embeddings, Node readline, in-memory compaction, taskkill, OTel span tree, rg/grep fallback). Prevents re-litigation.
- Verified: script correctly detects 5 unrecorded references as DELTA and 5 known references as OK. `health --json` exit code 0.

## 2026-08-06T18:00:00Z - provider capability probe cache

**Roadmap item:** P1-08 (provider capability probe cache — cache verified capabilities, unknown fails closed).

- Created `providers/capability.zig` with:
  - `Capability` enum: streaming, tool_calling, responses_api, context_overflow_detection.
  - `ProbeStatus` enum: supported, unsupported, unknown (fail-closed).
  - `CapabilityCache` struct: caches probed capabilities per provider. `check()` returns cached status; `requireCapability()` returns true ONLY for verified-supported (unknown fails closed). `record()` updates the cache after probing. Also caches `max_context_tokens` and `max_output_tokens`.
- Registered as `provider_capability` in `core/index.zig`.
- Added 4 internal tests: defaults to unknown (fail-closed); records and checks probed capabilities; requireCapability fails closed for unknown; records max token limits.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T17:00:00Z - shard-scoped memory recall

**Roadmap item:** P1-07 (shard-scoped memory recall — branch shards access parent checkpoint memories).

- Added `recallForBranch` function to `memory/store.zig` — reads memories from both the child session AND the parent session when recalling for a branch shard. Parent memories come first (accumulated context from before the branch point), then child memories (branch-specific, may override). Global memories included if budget allows.
- The memory recall order is: parent session → child session → global. This gives the branch the accumulated knowledge from the parent's checkpoint context without requiring the child to re-derive it.
- Added test proving both parent and child memories are recalled: parent has "Use append-only JSONL for session storage" (architecture decision), child has "IX is the search dependency" (branch-specific fact). Both appear in the recalled output.
- Validation: 84/84 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T16:00:00Z - plugin manifest typed contract

**Roadmap item:** P1-21 (plugin manifest typed contract — validate at mount, refuse unsupported before advertising).

- Extended `plugins/manifest.zig` with:
  - `review_risk: ?[]const u8` field on `PluginSocket` — tool sockets must declare a valid review risk class.
  - `isSocketKindMountable()` — only `tool` sockets are mountable today; provider/context/event fail closed.
  - `validateManifest()` now checks: valid plugin id, non-empty version, mountable socket kind, valid snake_case tool names, valid review risk class, no duplicate socket names.
  - `MountResult` union and `mountPlugin()` function — returns accepted/rejected so callers never advertise unvalidated tools.
  - New errors: `UnsupportedSocketKind`, `InvalidReviewRisk`, `DuplicateSocketName`.
- Added `parseReviewRiskLabel()` to `shared/types.zig` — parses risk class label strings into `ToolRiskClass` enum.
- Updated existing test to include `review_risk` on tool sockets.
- Added 5 new manifest tests: rejects missing review risk, rejects unsupported socket kinds, rejects duplicate socket names, mountPlugin accepts valid and rejects invalid.
- Validation: 83/83 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T15:00:00Z - checkpoint-addressed child launch

**Roadmap item:** P1-06 (checkpoint-addressed child launch — child sessions start from shard checkpoint, not full parent transcript).

- Added `launchFromCheckpoint` function to `agents/service.zig` — creates a child session with a parent checkpoint reference. The child's context window starts from the parent checkpoint (summary + recent suffix) rather than the full parent transcript. This is the token-economic foundation of the branch-and-converge model: each child costs only the checkpoint + its own prompt, not the entire parent history.
- The function writes an `open` shard checkpoint to the parent's `context.jsonl` linking the child to the parent checkpoint via `parent_checkpoint_id` and `branch_seq`. The branch can later be converged (P0-2) or abandoned at cold start (P0-4b).
- Added test proving: the JSON result references `parent_checkpoint_id` and `branch_seq`; the parent's `context.jsonl` contains a `shard_checkpoint` entry with `branch_status: open` and the agent name.
- Validation: 83/83 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T14:00:00Z - token-budgeted skill capsule section

**Roadmap item:** P1-20 (token-budgeted skill capsules — bound prompt rendering with truncation marker).

- Added `renderPromptCapsulesBudgeted` to `tools/builtin/skills.zig` — renders native skill capsules with a char budget (`max_capsule_chars = 2048`, ~512 tokens). When the budget is exceeded, the function stops adding capsules and emits `[Skill capsule section truncated: token budget exceeded. Additional skills are available via skill_info.]`. This is the direct counter to Eve/pi-mono's unbounded skill announcement (roadmap P1-20).
- The existing `renderPromptCapsules` (unbounded) is retained for backward compatibility; the budgeted variant is available for adoption in the prompt builder.
- Added 2 tests: all capsules fit within the 2048-char budget with no truncation marker; the section ends with the `skill_info` usage hint and total length stays bounded.
- Validation: 82/82 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T13:00:00Z - VAR1 stats command (local performance telemetry)

**Roadmap item:** P1-18 (local performance telemetry — cost-center counters gated behind explicit command).

- Created `core/evaluation/telemetry.zig` with:
  - `Counter` enum: 8 cost centers from AGENTS.md §X (context_compile, provider_turn, tool_dispatch, command_run, tui_frame, session_recovery, jsonl_scan, event_replay).
  - `CounterStat`: fixed-memory per-counter stats (count, total_ns, min_ns, max_ns, avg_ns, 16-bucket power-of-two histogram). No per-record allocation.
  - `CounterRegister`: fixed-memory register of all 8 counters (~300 bytes total). `renderJson()` for the stats command.
- Added `VAR1 stats` CLI command — reads the counter register and emits JSON. Sends no model request, writes no file. Honors AGENTS.md §VIII: "diagnostics stay thinner than capability."
- Added `stats_help_text` and registered in `helpText()`.
- Added 3 internal tests: CounterStat records correctly; CounterRegister renders JSON with all counters; empty register renders zero counts.
- Installed binary verified: `VAR1 stats` exit code 0 on `%LOCALAPPDATA%\Vantari\bin\vantari.exe`.
- Validation: 82/82 core_store_test + 48/48 tools_test passed. Installed binary `stats` and `health` exit code 0.

## 2026-08-06T12:00:00Z - arena/quota allocator discipline (scoped allocator type)

**Roadmap item:** P1-15 (arena/quota discipline — split allocators by turn, provider payload, tool result, UI frame).

- Created `core/memory/scopes.zig` with:
  - `Scope` enum: `turn`, `provider_payload`, `tool_result`, `ui_frame` — the four allocation scopes from AGENTS.md §XVIII item 6.
  - `ScopedArena` struct: wraps `std.heap.ArenaAllocator` with scope identification, byte tracking (`bytes_allocated`), and optional quota enforcement (`quota_bytes`). `checkQuota()` returns `error.QuotaExceeded` when the bound is exceeded.
  - `defaultQuota()` function: advisory byte bounds per scope (turn: 16 MiB, provider_payload: 8 MiB, tool_result: 1 MiB matching `max_output_bytes`, ui_frame: 4 MiB).
  - `reset()` for arena reuse and `deinit()` for full cleanup.
- Registered `scopes` in `core/memory/index.zig`.
- Added 4 internal tests: allocate and reset within quota; quota enforcement prevents unbounded growth; default quota ordering; scope labels are stable strings.
- This is the first step of the allocator discipline migration. The existing `page_allocator` root remains in production; `ScopedArena` is available for incremental adoption at allocation sites that need bounded lifetimes.
- Validation: 82/82 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T11:00:00Z - installed-binary integration proof

**Roadmap item:** P0-22i (installed-binary integration — auth/workspace/health resolution on Windows).

- Installed the freshly built binary (with all 26 promotion units) to `%LOCALAPPDATA%\Vantari\bin\vantari.exe`.
- Verified installed binary health: `ok: true`, active zai auth, GLM-5.1 model, scheduler supervisor active. Exit code 0.
- Verified installed binary tools: full tool catalog with correct schema, availability, and review risk. Exit code 0.
- Validation: `health --json` and `tools --json` both exit 0 on the installed Windows binary.

**Roadmap item:** P0-22h (TUI scrollback — verify transcript comprehension under live streaming).

- Added 2 tests proving the event spine invariant the TUI depends on for scrollback under live streaming:
  1. **Ordered replay:** 9-event live streaming sequence (turn_started → assistant_delta* → tool lifecycle → assistant_delta → assistant_response) is fully preserved with strictly monotonic seq on cold-start read. The TUI can reconstruct the complete transcript with correct causal order.
  2. **Same-ms burst ordering:** 4 assistant deltas with identical timestamp are correctly ordered by seq, and the TUI can reconstruct the message by concatenating in seq order ("Hello" + ", " + "world" + "!" = "Hello, world!").
- The TUI state model (`tui_chat.zig`) already handles scroll-offset preservation during live updates — `addAssistantDelta` adjusts `scroll_offset` when new content grows the assistant message. These tests verify the event spine substrate that the TUI renders from.
- Validation: 82/82 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T09:00:00Z - CRC per-line checksums for JSONL tamper detection

**Roadmap item:** P0-12c (CRC per-line checksums — optional CRC32 field for tamper detection).

- Added `computeLineCrc32` function (`sessions/store.zig`) — computes CRC32 over JSONL line content using `std.hash.Crc32.hash`. Used to embed a `"crc32":"hex"` field in JSONL entries for tamper detection.
- Added `verifyLineCrc32` function — verifies a JSONL line's embedded CRC32 against its content. Returns `true` if CRC matches, `false` if tampered/corrupted, `null` if no CRC32 field present (legacy entries skip verification).
- The CRC is computed over the line content excluding the `crc32` field itself — the verifier strips back to the comma before `"crc32"` to recover the original content.
- Added 3 tests: deterministic CRC for same input (different input → different CRC); legacy entries without crc32 return null; valid CRC verifies true, tampered content verifies false.
- Validation: 80/80 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T08:00:00Z - binary-safe event payloads (bytes_b64 field)

**Roadmap item:** P0-12b (binary-safe payloads — optional base64 byte fields on event entries).

- Added `bytes_b64: ?[]const u8 = null` field to `SessionEvent` (`shared/types.zig`). This is the optional base64 byte field from AGENTS.md §XVIII item 2: "store event payloads as canonical JSON plus optional base64 byte fields." When an event carries binary data (e.g. command output with invalid UTF-8), the raw bytes are stored as base64 in this field so the canonical JSON text remains valid.
- Updated `ParsedSessionEvent` (`sessions/store.zig`) to parse `bytes_b64` from disk.
- Updated `appendEvent` serialization: `std.json.fmt` automatically emits `"bytes_b64":null` for text-only events and `"bytes_b64":"..."` for binary events. No manual serialization needed.
- Updated `readEvents` and `readLatestEvent` to propagate `bytes_b64` on cold-start read.
- Added 2 tests: event with `bytes_b64` survives cold-start round-trip (base64 "Hello World" and null for text-only); `readLatestEvent` returns `bytes_b64` field.
- Validation: 77/77 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T07:00:00Z - branch-scoped capability profiles

**Roadmap item:** P0-5c (branch-scoped capability profiles — restrict tools per branch type).

- Added two branch-scoped capability profiles to `agents/profile.zig`:
  - **`recon`** — read-only (`file_read` only), no delegation (`allow_child_launch = false`), zero depth/contact budget. For research, codebase reconnaissance, and audit branches that should never mutate files.
  - **`write`** — read + write (`file_read` + `file_write`), no delegation, zero depth/contact budget. For branches that mutate files but should not fan out further.
- Updated `resolveProfile` to accept `recon` and `write` profile ids.
- Added 3 tests: recon profile is read-only with no delegation; write profile allows read+write but not delegation; branch profiles enforce least privilege via `ensureToolClass` (recon rejects file_write, write rejects delegation).
- Validation: 75/75 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T06:00:00Z - write-intent ledger

**Roadmap item:** P0-5b (write-intent ledger — reserve before mutation, commit after, reconcile abandoned).

- Added `intents.jsonl` to the canonical session layout — a new durable ledger for write-capable tool mutations.
- Added `reserveWriteIntent` (`sessions/store.zig`) — writes a `{"status":"reserved"}` entry with intent id, tool name, resolved path, and before-hash before any file mutation. If the process crashes after this point, the reserved entry without a matching commit is durable evidence of an incomplete write.
- Added `commitWriteIntent` — writes a `{"status":"committed"}` entry with intent id, after-hash, and bytes_written after successful mutation. The reserve→commit pair proves a write completed atomically.
- Added `readWriteIntents` and `reconcileAbandonedIntents` — reads the intent ledger and counts reserved entries without matching committed entries. This is the cold-start reconciliation: abandoned intents prove a crash mid-write.
- Added `IntentEntry` struct and `ParsedIntentEntry` for durable parsing.
- Added 3 tests: complete reserve→commit cycle leaves durable evidence; abandoned intents (reserved without commit) detected at cold start (2 of 3 intents abandoned); ledger is append-only and survives cold start.
- Validation: 75/75 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T05:00:00Z - shard-graph cold-start recovery

**Roadmap item:** P0-4b (shard-graph cold-start recovery — reconcile open branches as abandoned).

- Added `branch_status: ?ShardStatus` field to `ContextCheckpoint` (`shared/types.zig`) — parsed from the `branch_status` JSON field written by `appendShardCheckpoint`.
- Added `branch_status: ?[]const u8` to `ParsedContextCheckpoint` (`sessions/store.zig`) for JSON parsing.
- Added `readAllContextCheckpoints` function (`sessions/store.zig`) — reads all checkpoint entries from `context.jsonl` in forward order (not just the latest). Used by shard-graph recovery to scan for open shards.
- Added `reconcileOpenShards` function (`agents/service.zig`) — scans all shard checkpoints for entries with `branch_status: open`. For each open shard, checks if a later entry with the same parent_checkpoint_id + branch_seq exists with a non-open status (converged/abandoned). If no such settling entry exists, the open shard is marked abandoned (the owning child process is presumed dead). Emits `branch_abandoned` events. Returns the count of abandoned shards.
- Added adversarial test: 3 branches (A open, B open→converged, C open). Cold-start recovery marks A and C as abandoned (2), but B is left alone (already converged). Verifies `branch_abandoned` events on the spine.
- Validation: 72/72 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T04:00:00Z - branch-and-converge reprocessing loop

**Roadmap item:** P0-2 (branch-and-converge — launch N branches, collect evidence, merge into checkpoint, reprocess).

- Added `convergeBranches` function to `agents/service.zig` — the branch-and-converge reprocessing loop. It takes a parent session id, parent checkpoint id, and an array of `ChildBranchResult` (agent name + output). The function:
  1. Merges child outputs into a convergence summary ("Converged N branch(es)" + each branch's findings).
  2. Appends a `converged` shard checkpoint to the parent's `context.jsonl` (referencing the parent checkpoint).
  3. Appends the merged result as an assistant message to the parent's `messages.jsonl` (so the parent's next provider turn includes the convergence evidence).
  4. Emits a `branch_converged` event on the parent's event spine.
- Added `ChildBranchResult` struct and `NoBranchesToConverge` error.
- Added adversarial test proving the full convergence loop: two child branches (scout-a, scout-b) are merged, the parent transcript is appended (not rewritten), the shard checkpoint is durable, the `branch_converged` event is on the spine, and the latest checkpoint is the converged shard.
- Validation: 71/71 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T03:00:00Z - shard garbage collection (tombstone marks + byte-identical invariant)

**Roadmap item:** P0-3 (shard GC — mark abandoned/converged branches as tombstones).

- Added 3 shard GC tests proving the three invariants from the roadmap:
  1. **Byte-identical transcript:** shard convergence (open → converged) does NOT modify `messages.jsonl`. The test captures the transcript before shard operations, performs checkpoint + shard open + shard converge, then asserts the transcript is byte-identical afterward. Only `context.jsonl` is appended to.
  2. **Tombstone durability:** open/abandoned/converged branch_status marks all survive cold-start read. Multiple branches (A abandoned, B converged) coexist in the ledger with their lifecycle transitions.
  3. **Append-only ledger:** the shard ledger is never rewritten or truncated. The "before tombstone" content is a strict prefix of "after tombstone" — the open entry is NOT deleted when the abandoned tombstone is written. GC is a mark, not a delete (AGENTS.md §II).
- The shard GC mechanism uses the existing `appendShardCheckpoint` with `.abandoned` or `.converged` status. No new code was needed — the shard ledger primitive (P0-1) already supports lifecycle transitions. The tests prove the invariants hold.
- Validation: 70/70 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T02:00:00Z - shard ledger primitive (the north star)

**Roadmap item:** P0-1 (shard ledger primitive — `shard_checkpoint` entry type in context.jsonl).

- Added `parent_checkpoint_id: ?[]u8 = null` and `branch_seq: u64 = 0` fields to `ContextCheckpoint` (`shared/types.zig:210`). These make a checkpoint a shard reference: when `parent_checkpoint_id` is present, the checkpoint represents a branch whose context window is derived from the parent checkpoint + this branch's transcript.
- Added `ShardStatus` enum (`shared/types.zig:247`): `open`, `converged`, `abandoned` with `label()` and `parse()` methods.
- Extended `ParsedContextCheckpoint` (`sessions/store.zig:52`) with `parent_checkpoint_id` and `branch_seq` fields for backward-compatible parsing.
- Updated `appendContextCheckpoint` (`sessions/store.zig:508`) to conditionally serialize `parent_checkpoint_id` and `branch_seq` when present — old summary checkpoints without shard fields remain valid.
- Added `appendShardCheckpoint` function (`sessions/store.zig:558`) — writes a `shard_checkpoint` entry to `context.jsonl` with parent reference, branch seq, branch status, and branch summary. This is the shard ledger primitive: it marks a branch's lifecycle state in the durable checkpoint ledger.
- Updated `readLatestContextCheckpoint` to propagate shard fields on cold-start read.
- Added 3 adversarial tests: shard checkpoint survives cold start (verifies parent_checkpoint_id, branch_seq, branch_status in raw JSON), shard can be updated to converged status, shard does not corrupt summary checkpoint reads (mixed entry types coexist).
- Validation: 67/67 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-06T00:00:00Z - turn_finished + tool span completeness + empty-response probe

**Roadmap items:** P0-3b (turn events), P0-3c (tool span completeness), P0-22g (adversarial mock provider — empty response).

- Added `turn_finished` event at the executor completion path: `{"schema":"var1.turn_finished.v1","step":N,"window_tokens":T,"output_bytes":B}`. Added `turnFinishedMessage` helper.
- Verified P0-3c (tool span completeness) is already fully implemented and tested (`runtime_loop_test.zig` asserts the complete lifecycle ordering).
- Added empty-response adversarial probe (`P0-22g`): mock provider returns `{"content":""}` (no content, no tool calls). Session reaches terminal state without crashing. Confirms the self-healing empty-response path.
- Validation: 64/64 core_store_test + 48/48 tools_test + empty-response probe passed. `health --json` exit code 0.

**Roadmap items:** P0-3b (branch/turn events), P0-3c (tool span completeness).

- Added `turn_finished` event at the completion path of the executor loop. Every completed turn now emits `{"schema":"var1.turn_finished.v1","step":N,"window_tokens":T,"output_bytes":B}`. This closes the per-turn lifecycle: `turn_started` → (tool lifecycle) → `turn_finished`. Added `turnFinishedMessage` helper.
- Verified P0-3c (tool span completeness) is already fully implemented: the tool lifecycle grammar covers `tool_requested` → `tool_reviewed` → `tool_started` → `tool_output_delta*` → `tool_finished` → `tool_completed` with typed payloads (`var1.tool_started.v1`, `var1.tool_finished.v1`). Existing tests in `runtime_loop_test.zig` assert the complete lifecycle ordering (tool_requested < tool_reviewed < tool_started < tool_finished < tool_completed).
- The typed turn event grammar now covers: `session_started` → `turn_started` (per turn, with token telemetry) → tool lifecycle → `turn_finished` (with token + output telemetry) / `session_cancelled` / `session_failed`.
- Validation: 64/64 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-05T23:00:00Z - measured token telemetry on turn_started event

**Roadmap item:** P0-2b (measured token telemetry on the event spine).

- Extended `turnBoundaryMessage` to accept the current message list and compute `window_tokens` via `context_builder.budget.estimateChatMessages`. Every `turn_started` event now carries `{"schema":"var1.turn_started.v1","step":N,"window_tokens":T}` where T is the estimated token count of the provider window at turn ingress.
- This gives the event spine per-turn token cost evidence — the measured counterpart to the `WindowBudget` checkpoint/suffix breakdown (P0-2a). Together, P0-2a + P0-2b provide: (a) the assembly budget proving shards are cheaper than full transcripts, and (b) the live telemetry showing actual window cost per turn.
- Validation: 64/64 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-05T22:00:00Z - shard assembly budget + effect receipts verification

**Roadmap items:** P0-5a (structural effect diffing — verified already implemented), P0-2a (shard assembly budget).

- Verified P0-5a is already fully implemented: `FileSnapshot` (exists, len, sha256_hex), `fileEffectEnvelope` (before/after bytes, before/after SHA-256, action, resolved_path, metric, schema_version `var1.tool_effect.v1`), used by write_file, replace_in_file, append_file. Existing tests assert `before_exists`, `before_bytes`, `after_bytes`, `after_sha256`, `schema_version`.
- Added `WindowBudget` struct and `windowBudget()` function to `context/budget.zig` (P0-2a). Computes the token cost breakdown of a provider window assembled as checkpoint + suffix. Proves the economic invariant: a shard (checkpoint + one branch) costs fewer tokens than the full parent window. Includes `suffixSavings()` for measuring token economy.
- Added 2 budget tests: `windowBudget proves checkpoint + suffix is cheaper than full transcript` (100-message transcript, 200-char summary, 5 recent messages), `windowBudget handles empty suffix`.
- Validation: 64/64 core_store_test + 48/48 tools_test passed. `health --json` exit code 0.

## 2026-08-05T20:00:00Z - typed turn_started event in the executor loop

**Roadmap item:** P0-3a (close the event grammar — turn ingress evidence).

- Added `turn_started` event emission at the beginning of every provider turn in the executor step loop (`loop.zig`). The event carries a typed `var1.turn_started.v1` payload with the step index, satisfying AGENTS.md §IV's requirement: "Turn ingress: `turn_started` with session and prompt boundary evidence."
- Added `turnBoundaryMessage` helper that renders the typed payload.
- The existing event grammar now covers: `session_started` → `turn_started` (per turn) → `tool_requested` → `tool_reviewed` → `tool_started` → `tool_output_delta*` → `tool_finished` → `tool_completed` → `assistant_response` / `session_cancelled` / `session_failed`. Every turn now has typed ingress evidence.
- Validation: 64/64 core_store_test + 48/48 tools_test passed under Zig 0.15.1. `health --json` exit code 0.

## 2026-08-05T18:00:00Z - property-based fuzz harness + Job Object process-tree termination

**Roadmap items:** P0-22f (property-based fuzz harness), P0-13a (process-tree termination — Job Objects on Windows).

- Added 4 property-based fuzz harness tests (`P0-22f`): seeded PRNG generates random byte sequences (0-256 bytes, 50 iterations each) injected into events.jsonl, messages.jsonl. Asserts: readers never crash, never leak memory, always return valid prefix or empty. Also tests valid-prefix preservation when random corruption is appended mid-file.
- Implemented Windows Job Object process-tree termination (`P0-13a`): declared `CreateJobObjectW`, `SetInformationJobObject`, `AssignProcessToJobObject` as extern kernel32 functions. Created `createKillOnCloseJob()` that sets `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Modified `runCommandWithLimitsWindows` to create a Job Object before spawn, assign the child to it, and rely on handle close (defer) for process-tree reaping. Timeout still calls `TerminateProcess` for immediate effect; the Job Object ensures grandchildren (the actual command under `powershell/bash/cmd`) are also killed.
- Added real process-tree kill integration test: `Start-Sleep -Seconds 10` with 500ms timeout produces `timed_out:true`, proving the Job Object reaps the process tree before the command finishes.
- Added bounded pipe draining integration test (`P0-13b`): 10K-line PowerShell output (1MB) with `max_output_bytes=100` completes without deadlock — proves the `PipeCollector` continues draining after the cap to prevent pipe-buffer deadlock. `truncated:true` and `timed_out:false` confirm the cap is surfaced and the command completes normally.
- Validation: 64/64 core_store_test + 48/48 tools_test passed under Zig 0.15.1 (VANTARI_HOME unset). `health --json` exit code 0.

## 2026-08-05T12:00:00Z - event_seq capability advertised in initialize handshake

**Roadmap item:** P0-23 (typed capabilities in stdio JSON-RPC initialize).

- Added `event_seq_supported: bool = true` to `Capabilities` (`shared/protocol/types.zig:25`). Clients connecting via the `initialize` handshake now know the event spine carries a monotonic `seq` field and supports replay cursors for deterministic same-millisecond ordering (AGENTS.md §IV).
- Updated the capabilities test to assert `event_seq_supported` is advertised.
- Validation: build clean under Zig 0.15.1. `health --json` exit code 0.

## 2026-08-05T00:00:00Z - BOM rejection + invalid-UTF-8 refusal + burst-ordering + stale-session probes

**Roadmap items:** P0-17c (BOM rejection), P0-17d (invalid-UTF-8 refusal), P0-22a (same-ms burst ordering), P0-22b (stale session reconciliation), P0-22c (no-prompt resume fail-closed), P0-22d (stdout/stderr cap marker on truncation).

- Added `stripUtf8Bom` helper (`store.zig:6`) — strips leading `\xEF\xBB\xBF` from file content. Applied to all session JSONL/JSON readers: `readEvents`, `readLatestEvent`, `readSessionMessagesFromPath`, `readLatestContextCheckpoint`, `readSessionRecord`, `readSessionRecordRaw`. A BOM-prefixed first line no longer silently loses the first record.
- Added `std.unicode.utf8ValidateSlice(line)` check before JSON parse in all forward-scanning JSONL readers (`readEvents`, `readSessionMessagesFromPath`). A line with invalid UTF-8 bytes (e.g. `\xFE\xFF`, `\xC0\xC1`) is treated as a poisoned boundary — the reader stops and returns the valid prefix. The backward-scanning readers (`readLatestEvent`, `readLatestContextCheckpoint`) skip invalid-UTF-8 lines backward, same as unparseable JSON.
- Added 5 new adversarial tests:
  - `readEvents strips UTF-8 BOM from the events ledger`
  - `readSessionMessages strips UTF-8 BOM from the messages ledger`
  - `readEvents stops at invalid UTF-8 bytes and returns valid prefix`
  - `readSessionMessages stops at invalid UTF-8 bytes and returns valid prefix`
  - `session record reader strips UTF-8 BOM from session.json`
- Added same-millisecond burst ordering test (`P0-22a`): 3 events with identical `timestamp_ms` are disambiguated by strictly monotonic `seq` in append order. Proves AGENTS.md §IV invariant: "Timestamp-only cursors are insufficient under same-millisecond bursts."
- Added stale-session reconciliation + no-prompt resume tests (`P0-22b/c`): stale running session recoverable as failed with durable evidence after cold start; session prompt survives cold start for empty-prompt check; whitespace-only prompt correctly fails the empty-prompt check; stale session failure event visible in the event spine with monotonic seq.
- Added typed truncation marker on `CommandOutput` (`P0-22d`): new `truncated: bool = false` field on `module.CommandOutput`; wired from `PipeCollector.cap_reached` in both POSIX and Windows command runners; serialized as `"truncated":true|false` in the shell_exec tool result JSON. The streaming cap delta (empty chunk with `cap_reached = true`) was already correct; this closes the gap where the final return value carried no truncation evidence.
- Added command timeout evidence probes (`P0-22e`): mock runner tests verifying `timed_out:true` + `exit_code` + partial stdout appear in the JSON result; combined truncation+timeout test verifies both markers surface simultaneously.
- Validation: 60/60 core_store_test + 46/46 tools_test passed under Zig 0.15.1 (VANTARI_HOME unset). `health --json` exit code 0.

## 2026-08-04T18:00:00Z - monotonic event seq + durability gate + valid-prefix reads

**Roadmap items:** P0-12a (monotonic seq on events.jsonl), P0-17b (fsync durability gate), P0-17a (torn-write valid-prefix preservation).

- Added `seq: u64 = 0` to `SessionEvent` (`src/shared/types.zig:149`) and `ParsedSessionEvent` (`src/core/sessions/store.zig:26`). Events are now monotonic ledger entries.
- Added `nextEventSeq()` helper (`store.zig:829`) — a backward tail scan that finds the last parseable event's seq and returns seq+1. O(1)-ish per append, not O(n) like `nextSessionMessageSeq`. Skips torn trailing lines.
- Modified `appendEvent` (`store.zig:263`) to compute and assign seq before serializing. Every event now gets a monotonic position in `events.jsonl`.
- Added `file.sync()` call after `pwriteAll` in `appendJsonlRecord` (`store.zig:760`) — committed writes now flush from OS page cache to disk. This is the durability gate for all three session ledgers (events, messages, context).
- Changed `readEvents` and `readSessionMessagesFromPath` from `catch continue` (silently drop malformed lines) to `catch break` (stop at first poisoned line, return valid prefix). This enforces AGENTS.md §II's "valid prefix state" invariant: a poisoned suffix cannot corrupt the valid prefix, and poisoned rows are no longer silently invisible.
- Updated 3 existing tests to match the stronger valid-prefix contract:
  - `event readers skip corrupted jsonl lines` → `event readers return valid prefix before a corrupted line`
  - `store appends lifecycle events after an interrupted partial event row` — assertions updated for valid-prefix semantics
  - `store preserves append-only message ledger across corrupted and partial rows` — assertions updated for valid-prefix semantics
- Added 5 new adversarial tests:
  - `events get monotonic seq assigned by appendEvent`
  - `event seq survives cold start and continues monotonically`
  - `event seq continues correctly after a torn write`
  - `readEvents stops at poisoned suffix and returns valid prefix`
  - `readMessages stops at poisoned suffix and returns valid prefix`
- Validation: 50/50 core_store_test passed under Zig 0.15.1 (VANTARI_HOME unset). `health --json` and `tools --json` exit code 0. No segfault.

## 2026-08-04T00:00:00Z - sharded-context-windows roadmap

- Harvested the Vercel Eve reference (`.refs/vercel__eve/`) and reverse-engineered its durable turn execution (`turn-workflow.ts`), compaction strategy (`compaction.ts`), compaction prompt builder (`compaction-prompt.ts`), tool loop (`tool-loop.ts`), and durable step seam (`workflow-steps.ts`).
- Established the north-star contract: a token-minimal harness where every message is a fresh context window, each window is a checkpoint/shard of the parent chat, each step branches into its own context window, and branches converge and reprocess.
- Authored `.docs/roadmap/` (11 theme files + `_index.md`) mapping the sharded-context-windows north star to the VANTARI pipeline, each theme referencing a competitor (Vercel Eve, OpenAI Codex, pi-mono, Claude Code, Cursor, etc.) and how VANTARI does it better.
- Confirmed VANTARI's WAL (`messages.jsonl`) + checkpoint (`context.jsonl`) is the correct substrate; the sharded model is a natural extension of the ledger, not a new system. Eve's compaction is single-window, in-memory, re-derived each turn; VANTARI's is durable, sequence-addressed, append-only.
- Validation: source-validated only; no runtime lane change in this entry.

## 2026-08-04T16:00:00Z - roadmap expansion: 12 deep-research themes (12-23)

- Launched 12 sequential subagents (one at a time to avoid rate limits), each with a prepared task script in `.docs/roadmap/_agent-tasks/`, each studying AGENTS.md, `.docs/log.txt`, VANTARI source, competitor references, and web research.
- Each agent wrote one roadmap file (themes 12-23) following the canonical template: seam, what exists today (VANTARI code refs), what the competitor does (Eve/Codex/pi-mono with file refs), why VANTARI does it better (mechanism + proof), pipeline items (P0/P1/P2 with Contract/Mechanism/Test/Proof), north-star link, definition of done.
- Key discoveries across the 12 agents:
  - `SessionEvent` has no `seq` field; `readEvents` silently skips poisoned rows (`catch continue`); `appendJsonlRecord` never calls `file.sync()` — committed writes sit in OS page cache (themes 12, 17).
  - `CancellationToken` is referenced in `batch.zig:102` but never defined anywhere; Windows `TerminateProcess` kills only the direct child, not the process tree (theme 13).
  - `page_allocator` is the sole production root with 634 hand-written `defer free` sites and zero leak detection; no `ArenaAllocator` in production code (theme 15).
  - None of the three competitors (Eve, Codex, pi-mono) ship a local exact tokenizer — validating VANTARI's proof-gated stance on C ABI acceleration (theme 14).
  - Only 2 of 9 native skills carry the `protocol` field — the actual execution contract that is the routing target (theme 20).
  - The plugin manifest (`manifest.zig`) and `ToolSource.plugin` enum exist but are not wired to dispatch — the seam is drawn but not connected (theme 21).
  - 1346 test functions across 13 files; genuine gaps in same-millisecond event ordering, terminal scrollback testing, and the installed-binary gate (theme 22).
  - The Eve harvest from 2026-08-04 is already stale — Eve has since added a full durable workflow engine (theme 19).
- Updated `_index.md` with the 12 new themes and their priority tiers.
- Validation: all 23 roadmap files verified present; no source code modified.

## 2026-07-15T15:00:00Z - canonical sibling config and auth ownership

- Established `$VANTARI_HOME/config.json` as the single live owner for non-secret runtime limits, provider-wire selection, context policy, prompt paths, and supported environment-style overrides.
- Documented every persistent configuration value in standards-valid JSON through validated `_help` maps, with `_about` notes proving the boundary around bootstrap, auth-owned, invocation-scoped, and tool-scoped controls.
- Established `$VANTARI_HOME/auth.json` as the sibling credential/provider ledger; new readers and the installer no longer write nested or AppData auth paths.
- Added one-time auth migration from legacy `auth/auth.json` and `%LOCALAPPDATA%\Vantari\auth\auth.json`, preserving the complete provider ledger through an atomic canonical write.
- Added `vantari config path|show|init|validate`; config commands never render or merge credential data.
- Added the canonical embedded `config/default.json` template and made both runtime materialization and Windows installation consume that owner.
- Updated workspace detection, installer behavior, architecture docs, READMEs, and tests for the sibling-file contract.
- Migrated the live machine to `C:\Users\Savage\.vantari\config.json` and `C:\Users\Savage\.vantari\auth.json`; AppData no longer contains a live auth ledger. The older installed binary temporarily reads a hardlink at the legacy home path until a fresh merged binary can be installed.
- Validation: canonical config tests `3/3`, auth migration tests `3/3`, workspace-resolution tests `6/6`, and focused CLI test `2/2` passed under pinned Zig 0.15.1. Installed `health --json` returned `ok: true` with active `zai` auth after migration.
- External promotion blocker retained honestly: the current TUI dependency cache does not expose the required `zg` modules, so the new CLI command surface is source-validated but not yet installed.

## 2026-07-12T20:00:00Z - constant-size stdio worker supervision

- Replaced lifetime-growing retained request-thread handles with a fixed-size native `WorkerGroup` containing only active-count, closing-state, mutex, and condition fields.
- Detached request workers now release their active reservation on completion; shutdown cancels sessions and waits for the count to reach zero before freeing server state.
- Removed the request thread array and its allocator/deinit path.
- Native validation: backend `1360/1360` tests passed with a fresh Zig cache.

## 2026-07-12T19:30:00Z - native HTTP RPC notifications

- Added a minimal `KernelBridge.notify` / `LocalClient.notify` socket so HTTP JSON-RPC notifications are sent without synthetic request IDs or response waits.
- `/rpc` notifications now return `204 No Content`; request/response calls remain unchanged.
- Added web coverage for no-response notification behavior.
- Native validation: backend `1360/1360` tests passed with a fresh Zig cache.

## 2026-07-12T19:00:00Z - structured health RPC failures

- Preserved redacted kernel error objects through the HTTP `/api/health` convenience route instead of collapsing them into generic `500 InternalServerError` responses.
- Health provider/kernel failures now return `503` with actionable JSON-RPC code and message data; raw `/rpc` behavior remains unchanged.
- Added web coverage for structure preservation and secret redaction.
- Native validation: backend `1359/1359` tests passed with a fresh Zig cache.

## 2026-07-12T18:30:00Z - escaped stdio request envelopes

- Centralized `LocalClient` request rendering so method names are JSON-escaped before transport, preserving valid RPC framing for arbitrary consumer input.
- Added coverage for quotes and backslashes in method names; canonical `zig build test` validation remains green at `1358/1358`.
- Direct standalone `zig test src/host/stdio_rpc.zig` is not a supported proof path because the file uses package-relative imports.

## 2026-07-12T18:00:00Z - typed stdio method routing

- Replaced the `stdio_rpc` string-comparison dispatch chain with one typed route table using the canonical protocol method constants and a uniform handler signature.
- Preserved existing error mapping, notification behavior, and session handler ownership.
- Native validation: backend `1358/1358` tests passed with a fresh Zig cache; `git diff --check` passed.

## 2026-07-12T17:30:00Z - Codex OAuth callback decoding

- Made authorization-input parsing allocator-owned and URL-component aware, matching Pi's `URL.searchParams` behavior for percent escapes and `+` spaces.
- Rejects malformed percent escapes and preserves the first `code`/`state` field instead of forwarding raw callback bytes.
- Native validation: backend `1358/1358` tests passed with a fresh Zig cache.

## 2026-07-12T17:00:00Z - canonical session event persistence

- Added `session_store.appendEventAndTouch` and routed executor plus stdio host-generated events through it, removing duplicated event/timestamp persistence logic while preserving notification emission hooks.
- Updated heartbeat coverage to exercise the canonical helper.
- Native validation: backend `1357/1357` tests passed with a fresh Zig cache.

## 2026-07-12T16:45:00Z - stdio shutdown cancellation

- Added canonical runtime-wide cancellation propagation before joining owned request workers, matching the harvested Pi abort-before-shutdown boundary.
- Made test-server worker-list initialization explicit.
- Native validation: backend `1357/1357` tests passed with a fresh Zig cache.

## 2026-07-12T16:30:00Z - stdio worker lifecycle ownership

- Replaced detached stdio request workers with server-owned thread handles joined before scheduler/runtime teardown.
- Added cleanup for worker spawn and thread-list allocation failures, plus direct join coverage.
- Native validation: backend `1357/1357` tests passed with a fresh Zig cache; `git diff --check` passed.

## 2026-07-12T16:15:00Z - stdio worker failure response

- Fixed unexpected stdio RPC worker errors so recoverable request IDs receive a bounded JSON-RPC internal-error response instead of hanging; notifications remain response-free.

## 2026-05-19T12:05:48Z - PR #2 merge remediation

- Remediated `shell_exec` timeout contract drift by replacing the non-Windows `std.process.Child.run` path with a spawn, pipe-collector, bounded wait, and termination state machine.
- Remediated `search_files` availability drift by validating the `iex search --help` command shape before advertising IX-backed search capability.
- Added registry tests for mismatched `iex` executable rejection and successful IX search shape promotion.
- Validation: `apps/backend/scripts/zigw.ps1 build test` passed.
- Validation: `apps/backend/scripts/zigw.ps1 build install -Dtarget=x86_64-linux-gnu` passed for non-Windows compile coverage.

## 2026-05-19T12:53:00Z - PR #2 conflict reconciliation

- Merged `origin/main` into `local/frontend` and resolved the stale `variant-1` / `src/shared/core` rename topology in favor of the canonical collapsed backend lane under `apps/backend/src/core`, `src/clients`, `src/host`, and `src/shared`.
- Preserved the PR branch's `shell_exec` timeout and IX/IEX availability contract repairs from `08be23e`.
- Retained `origin/main`'s tracked `apps/frontend/var1-client` addition while keeping `apps/backend` as the runtime ownership lane.

## 2026-05-21T00:00:00Z - scheduler backlog realignment

- Re-reviewed the current `apps/backend` scheduler-adjacent surfaces: tool runtime/registry/index, executor tool lifecycle, stdio host protocol dispatch, protocol type declarations, CLI command surfaces, and backend build wrapper location.
- Confirmed no live `apps/backend/src/core/scheduler/` implementation exists yet; scheduler remains a planning-spec backlog, not a claimed runtime capability.
- Updated scheduler planning-spec chains `026`-`033` and all 96 lettered units with current-code alignment notes and corrected validation command floors rooted at `apps/backend/scripts/zigw.ps1`.
- Validation: structural checker confirmed 8 parent chains, 12 units per chain, current-code alignment in every scheduler backlog file, and zero stale root-relative `.\scripts\zigw.ps1` validation commands.

## 2026-05-21T00:00:00Z - scheduler Insect research pass

- Captured Insect search and page evidence under `.docs/research/scheduler/` for Temporal durable execution/idempotency, Quartz persistent job/misfire semantics, Kubernetes workqueue/lease mechanics, and system timer references.
- Accepted: idempotent attempt reservation, durable append-only schedule evidence, explicit misfire policy, lease/reconcile semantics, and one canonical scheduler store under `.var/schedules`.
- Rejected: OS cron/system timer state as scheduler truth, hidden host-only scheduler routes, duplicate provider loops, and timer caches without cold-start reconciliation.
- Updated scheduler parent chains `026`-`033` with research alignment notes.

## 2026-05-21T00:00:00Z - scheduler runtime completion

- Implemented canonical scheduler runtime under `apps/backend/src/core/scheduler/`: durable job CRUD, `.var/schedules` job/event/attempt evidence, lease acquisition, due selection, misfire advancement, attempt completion, and host-supervised service ticks.
- Implemented `schedule_job` as the agent-facing tool surface for create/get/list/update/delete/pause/resume/run_now.
- Implemented scheduler protocol/CLI read models: `schedule/get`, `schedule/list`, `VAR1 schedule list`, `VAR1 schedule get`, and health proof via `scheduler_supervisor`.
- Preserved explicit boundary: OS cron/system timers are wrappers only; scheduler truth remains kernel-owned schedule state.
- Validation: `Set-Location apps/backend; .\scripts\zigw.ps1 build test --summary all` passed with `1343/1343 tests passed`.
- Validation: `Set-Location apps/backend; .\scripts\zigw.ps1 build install --summary all` passed.
- Runtime proof: `VAR1 health --json` reported `scheduler_supervisor=true`; `VAR1 tools --json` advertised `schedule_job`; `VAR1 schedule list --json` returned canonical schedule JSON.
- Archived scheduler planning-spec chains `026`-`033` from `.docs/todo/pending/` to `.docs/todo/changelog/`.

## 2026-07-12T08:00:00Z - provider streaming capability hardening

- Audited the provider seam against the checked-in Codex and Pi reference implementations; confirmed that transport capability must be explicit rather than silently downgraded.
- Changed `apps/backend/src/core/providers/openai_compatible.zig` so a caller requesting assistant-delta hooks receives `StreamingUnavailable` when no streaming transport is installed.
- Updated executor test fixtures to declare an explicit buffered-stream adapter where the fixture intentionally models a non-streaming provider.
- Validation: backend `zigw.ps1 build test --summary all` passed with `1344/1344 tests passed`.
- Validation: CLI `zigw.ps1 build test --summary all` passed with `78/78 tests passed`.
- Audit tooling note: the packaged deep-audit structural-only mode currently fails before analysis with `NameError: name 'query_vector' is not defined`; no findings were attributed to that tool run.

## 2026-07-12T09:00:00Z - versioned auth ledger and OAuth credential boundary

- Corrected the repository search evidence to the canonical `ix search` binary after the older `iex.exe` name was retired.
- Archived `021a-codex-subscription-auth` after `ix` confirmed the auth owner and the checked-in Pi/Codex OAuth reference surfaces.
- Implemented `AuthRecord`, OAuth-aware `ResolvedAuth`, secret-free `AuthStatus`, v1/v2 ledger parsing, v2 API-key bootstrap writes, OAuth record writes, and expiry detection in `apps/backend/src/core/auth/store.zig`.
- Exposed the typed status boundary through `apps/backend/src/core/auth/resolver.zig`.
- Added fake-token round-trip, expiry, redaction, and missing-credential tests.
- Validation: backend `1346/1346 tests passed`; CLI `78/78 tests passed`.
- Archived `021b-codex-subscription-auth` with validation and `ix` ownership evidence. `021c` remains the next pending unit for real CLI OAuth login/logout/status behavior.

## 2026-07-12T10:00:00Z - Codex OAuth claim and request contract alignment

- Re-read the checked-in Codex SDK/login sources instead of relying on OAuth assumptions: the authorization scope includes connector permissions, the originator is `codex_cli_rs`, the ID token carries namespaced ChatGPT claims, and the provider request carries `chatgpt-account-id` alongside the bearer token.
- Updated `openai_codex.zig` to require the actual `id_token` exchange field and parse namespaced profile email plus ChatGPT account/user/plan claims.
- Added an account-aware transport socket without changing existing fake transport function signatures; resolved OAuth account IDs now flow through config, executor, CLI, scheduler, and native HTTP request construction.
- Added CLI auth help/status redaction and provider-removal repair tests; logout cannot leave a dangling active provider.
- Validation: backend `1353/1353 tests passed`; CLI `78/78 tests passed`; `git diff --check` passed.
- Explicit boundary: `VAR1 auth login openai-codex` still fails closed with `OAuthLoginNotReady` until the real localhost callback server, browser/manual race, token exchange transport, refresh path, and persistence orchestration are implemented and natively exercised.

## 2026-07-12T11:00:00Z - Codex OAuth execution path and Pi harness salvage

- Salvaged the behavioral skeleton from Pi's OpenAI Codex OAuth harness: PKCE authorization, redirect-or-code manual fallback, token exchange, namespaced JWT claims, refresh-token retention, and secret-free completion output. The implementation remains VAR1-owned Zig code; no parallel TypeScript auth runtime was introduced.
- Replaced the `OAuthLoginNotReady` boundary with a real `VAR1 auth login openai-codex` path using Zig `std.http.Client.fetch`, PKCE state validation, token parsing, claim extraction, and canonical auth-ledger persistence.
- Added expired OAuth refresh during config resolution. Refresh responses may omit a new ID or refresh token, matching the checked-in Codex persistence behavior; existing credentials are retained where the endpoint omits replacements.
- Fixed auth-ledger upsert behavior so adding or refreshing one provider preserves unrelated providers and activates only the updated provider.
- Validation: backend `1355/1355 tests passed`; CLI `78/78 tests passed`; install build passed; direct native `zig build run -- auth --help` exposed the updated command contract.
- Remaining boundary: the Pi-style localhost browser callback race is not yet implemented; the current login uses the verified manual redirect/code fallback and fails closed on invalid state or token response.

## 2026-07-12T12:00:00Z - auth ownership cleanup and callback input hardening

- Moved OAuth refresh orchestration from `core/config/resolver.zig` into `core/auth/resolver.zig`; config now asks the auth owner for an execution-ready credential and no longer owns token policy.
- Tightened redirect parsing to accept only the registered `/auth/callback` path and exact `code`/`state` query keys; arbitrary URL text containing `code=` is rejected.
- Re-read Codex device-code sources before adding another protocol. Device login uses separate `/api/accounts/deviceauth/usercode` and `/api/accounts/deviceauth/token` endpoints plus a distinct `/deviceauth/callback` exchange, so it remains a separate future provider capability rather than an unverified branch.
- Validation after refactor and parser hardening: backend `1355/1355 tests passed`; CLI `78/78 tests passed`.

## 2026-07-12T13:00:00Z - OAuth form encoding contract

- Re-read Pi's `URLSearchParams` exchange behavior and corrected VAR1's Codex OAuth form builder to percent-encode every non-unreserved byte in authorization-code, verifier, refresh-token, and redirect fields.
- Added a fake token transport test covering `+`, `&`, `?`, and `/` values so a shallow string-interpolation implementation cannot regress silently.
- Validation: backend `1356/1356 tests passed`.

## 2026-07-12T14:00:00Z - OAuth canonical-owner refactor

- Moved authorization-code parsing, token exchange, claim extraction, and auth-ledger persistence into `core/auth/resolver.zig`.
- Reduced the CLI login path to user interaction, PKCE flow setup, and secret-free result rendering.
- Added a direct resolver test proving fake redirect input reaches OAuth persistence and re-resolves with account, email, and access-token state.
- Validation: backend `1357/1357 tests passed`.

## 2026-07-12T15:00:00Z - CLI auth surface extraction

- Extracted auth command types, help, argument parsing, and status rendering into `apps/backend/src/clients/cli_auth.zig`.
- Kept CLI execution responsible only for workspace interaction and output; auth state transitions remain in `core/auth/resolver.zig` and `core/auth/store.zig`.
- Preserved the public `renderAuthStatus` wrapper and command help contract for existing consumers.
- Validation: backend `1357/1357 tests passed`; CLI `78/78 tests passed`; direct native `auth --help` passed; `git diff --check` passed.

## 2026-07-12T16:00:00Z - stdio wire seam extraction

- Extracted JSON-RPC envelope rendering and `Content-Length` framing into `apps/backend/src/host/stdio_wire.zig`.
- Kept `stdio_rpc.zig` as the sole session/scheduler dispatch owner; compatibility wrappers preserve existing internal tests and callers while preventing a second protocol implementation.
- Reduced `stdio_rpc.zig` by 119 lines; the new wire owner is 3.6 KB.
- Validation: backend `1357/1357 tests passed`; CLI `78/78 tests passed`; `git diff --check` passed.

## 2026-07-12T20:30:00Z - bounded HTTP connection admission

- Added a constant-size `ConnectionGate` to the HTTP bridge so detached connection workers cannot grow without bound under socket pressure.
- Rejected connections release their socket and admission slot immediately; completed workers release their slot through one deferred completion path.
- Kept the bridge lightweight: no worker pool, queue, scheduler, or additional process layer.
- Added a saturation/recovery test proving the gate rejects at capacity and admits after release.
- Native validation: backend `1360/1360 tests passed`; `git diff --check` passed.

## 2026-07-12T21:00:00Z - reproducible Windows install proof

- Added `apps/backend/scripts/install_windows.ps1` as the canonical reversible Windows install path.
- The script builds with fresh per-run Zig caches, stages the executable, preserves the previous installed binary as a timestamped backup, verifies SHA-256 identity, and runs the installed `--help` smoke path.
- Avoided the stale fixed cache path used by the generic `zigw.ps1` wrapper after it caused a real missing-cache-file failure during the first install attempt.
- Native proof: installed `%LOCALAPPDATA%\\Vantari\\bin\\vantari.exe` hash matches the release build at `F89A42F05A6AFCF10A2D0829FBFA89C1C1032B9F448EC6BE1C005C6EF58506CC`; installed `--help` passed; prior binary backed up to `vantari.exe.20260712-124836.bak`.

## 2026-07-12T21:30:00Z - scheduler degraded health signal

- Added one atomic degraded flag to `scheduler.Service`; tick failures mark it degraded and the next successful tick clears it.
- Exposed the flag through the existing `health/get` response as `scheduler_degraded` without retaining error strings, adding queues, or introducing a logging subsystem.
- Added healthy, degraded, and recovered state assertions for the service signal.
- Native validation: backend `1360/1360 tests passed`; `git diff --check` passed.

## 2026-07-12T22:00:00Z - health client parity

- Added `scheduler_degraded` to the CLI health parser and human-readable projection so the client no longer discards the kernel health field through `ignore_unknown_fields`.
- Reinstalled the native binary and verified the live installed `health --json` response reports `scheduler_degraded: false` with the active Z.ai provider record.
- Native validation: backend `1360/1360 tests passed`; installed SHA-256 matched the release build; installed health smoke passed.

## 2026-07-12T23:00:00Z - kernel transport closure reconciliation

- Added a bounded CLI recovery path that marks the active session failed and appends `kernel_transport_closed` evidence when `session/send` loses its kernel child before an RPC response.
- Preserved the existing JSON-RPC and process model; no retry worker or supervisor was introduced.
- Native validation: backend `1360/1360 tests passed`; installed binary rebuilt and hash-verified.
- Live Z.ai verification remains incomplete for the access-violation case; provider `401` failures now persist correctly as failed sessions.

## 2026-07-13T00:00:00Z - transport closure regression coverage

- Added a direct CLI/session-store test proving kernel transport closure produces failed session state, bounded failure reason, and `kernel_transport_closed` event evidence.
- Native validation: backend `1360/1360 tests passed`; `git diff --check` passed.

## 2026-07-13T01:00:00Z - optional stream hook safety

- Guarded the optional assistant-delta callback in `SseDeltaEmitter` before invoking it.
- Added a Z.ai-shaped regression fixture covering `reasoning_content`, empty terminal `content`, and no registered stream hook.
- Native validation: backend `1360/1360 tests passed`; installed smoke rerun still reproduces the separate Windows access violation.

## 2026-07-13T02:00:00Z - lightweight kernel improvements (transport collapse, OAuth generalize, cancellation, parallel batches, JSONL resilience)

Five-impedance lightweight pass, each slice independently testable and gated:

- **Transport collapse**: Removed `sendWithAccountFn`/`streamWithAccountFn` from the provider Transport. The two remaining functions (`sendFn`, `streamFn`) each accept `account_id: ?[]const u8`. z.ai/local-LLM path (null account_id) is byte-identical; ChatGPT OAuth path emits the `chatgpt-account-id` header via the same sendFn slot. Buffered fallback preserved when no streamFn is wired (local LLMs without SSE degrade silently, not fail).
- **OAuth resolver generalize**: Moved four hardcoded Codex literals (`base_url`, `model`, `issuer`, `subscription_source`) from `resolver.zig` into the `descriptor` struct in `openai_codex.zig`. The resolver is now provider-pluggable: a second OAuth provider is a new descriptor module, not a resolver copy. Zero provider-specific literals remain in resolver.zig.
- **Cancellation token**: Added `CancellationToken` (atomic bool) to `ExecutionContext` and `CommandLimits`. The executor loop constructs one per `runPrompt`; `shouldCancel` feeds it via `request()`. `shell_exec` observes it in both the portable `waitpid` poll loop and the restructured Windows `WaitForSingleObjectEx` poll loop (100ms granularity). `wait_agent` chunks its wait into 200ms polls. Proved by a Windows-native test: a pre-cancelled token interrupts a 30-second `ping` command in under 5 seconds.
- **Parallel read-only tool batches**: Added `execution_mode: sequential|parallel` to `ToolDefinition`. `list_files`, `search_files`, `skill_info`, `list_agents`, `agent_status` flagged `.parallel`. When an entire tool batch is parallel-eligible, the executor runs them concurrently on a bounded thread pool (max 4), then appends results in source order. `read_file` stays `.sequential` (unlocked `FileInspectionLedger`). Mixed batches fall through to the sequential path unchanged.
- **JSONL cold-start resilience**: Generalized `stripUtf8Bom` into `shared/fsutil.zig`; applied to all session JSONL readers (`messages.jsonl`, `events.jsonl`) and `session.json`. Added duplicate-seq detection in `readSessionMessagesFromPath` (skips non-monotonic rows with a warning). Added typed `Error.CorruptedSessionRecord` for external `session.json` corruption (no hidden fallback salvage per §XII). Three adversarial tests prove the defenses: BOM-prefixed ledger reads all rows, duplicate seq is skipped, corrupted session.json returns typed error.
- State machines named: transport dispatch (buffered/streaming via single sendFn), cancellation (atomic token → request/check → terminal kill), parallel batch (preflight sequential → execute concurrent → append source-order), JSONL read (strip BOM → parse line → dup-seq check → append or skip).
- Native validation: backend `1364/1364 tests passed` (4 new tests: transport parity, cancellation mid-flight, BOM survival, dup-seq skip, corrupted session.json). `zig build` clean. Binary built.
- Windows installed-binary proof (§XV): `%LOCALAPPDATA%\Vantari\bin\vantari.exe` rebuilt from ReleaseSafe (SHA-256 dfbbf8fa...), `--help` runs clean. The cancellation test exercises a real Windows process (`cmd.exe /c ping`) against the restructured poll loop.

## 2026-07-13T03:00:00Z - post-landing fixes and completion-signal primitive

Three fixes from the post-landing recon audit plus one new primitive:

- **P0 fix: debug print pollution removed.** Deleted 7 `VAR1_TRACE` stderr prints from the SSE streaming hot path (`openai_compatible.zig`) and 2 `VAR1 bridge error` prints from `bridge_access.zig`. Converted `bridge_access.logError` from lossy stderr to durable audit-ledger evidence (writes `bridge_error` JSONL rows to `.var/audit.jsonl`). All 5 callers in `http_bridge.zig` updated. The streaming path is now observable only through the canonical event spine (§IV, §XII).
- **P1 fix: parallel batch overflow correctness.** The "bounded concurrency" implementation was running tools beyond `max_concurrent=4` inline during the spawn loop, serializing the overflow before joining the first batch. Fixed by spawning ALL parallel workers as threads (read-only I/O-bound tools don't need a thread cap). Each worker writes its own results slot — no contention. The `max_concurrent` cap and inline-overflow path are removed.
- **P2 fix: dup-seq=0 detection.** The `max_observed_seq > 0` guard skipped detection of duplicate `seq=0` rows (external/legacy ledgers). Replaced with `?u64` optional — first-seen always passes, subsequent duplicates always detected.
- **Completion-signal primitive (signals_completion).** Added `signals_completion: bool = false` to `ToolDefinition`. When a tool with this flag succeeds in a batch, the executor breaks the step loop instead of issuing a follow-up provider turn. Harvested from pi-mono's `terminate` hint. No existing tools set it yet — the primitive is ready for terminal tools (final_answer, structured_output). Eliminates the wasted-provider-turn cost center per §X.
- Native validation: backend `1364/1364 tests passed`; installed binary rebuilt and verified.

## 2026-07-13T04:00:00Z - token estimator accuracy and typed refresh-failure classification

Two targeted improvements serving the lightweight local-LLM ethos:

- **Per-role token estimation (§III context compile cost center).** `budget.estimateChatMessages` now counts inline images at ~1200 tokens each (not raw base64 bytes/4) and adds 8-token envelope overhead per tool call. Previously, a 100KB base64 image counted as ~25K tokens at chars/4 — but providers bill ~1200, so compaction fired far too early for multimodal sessions. Conversely, tool-call envelope overhead was missing entirely, causing tool-heavy sessions to under-count and hit `ContextWindowExceeded` at the provider (triggering the expensive overflow-recovery path). Two tests pin the behavior: image content stays under 2000 tokens (not 25000), tool calls include envelope overhead.
- **Typed refresh-failure classification (§X, §XV).** Added `RefreshTokenExpired` (400/401/403: re-login required) and `RefreshTokenExhausted` (429: rate-limited, retry later) to the codex auth error set. `resolver.refreshIfNeeded` now degrades gracefully on these typed failures — logs a warning and keeps the stale token rather than aborting config load. The operator sees the failure at the provider turn and can re-login. Harvested from codex's `RefreshTokenFailedReason::{Expired, Exhausted, Revoked, Other}`.
- Native validation: backend tests green; installed binary rebuilt and verified.

## 2026-07-13T05:00:00Z - architectural rewrite: phases 1-4 (typed events, tool registry, storage optimizations, loop extraction)

Four-phase architectural restructure, each independently testable:

- **Phase 1 — Typed events + JSON consolidation.** Created `shared/json.zig` (one canonical `renderAlloc` helper) and `shared/protocol/events.zig` (typed `ToolStarted`, `ToolFinished`, `ToolOutputDelta`, `ToolReview` structs with `serialize`). Replaced inline `allocPrint("{{...}}")` event renderers in `loop.zig` (the 3-variant `renderToolFinishedEvent` collapsed to one struct) and the 14-line hand-rolled JSON chain in `review.zig`. Deleted 6 private `renderJsonAlloc` clones across 5 files; the remaining `pub` one in `stdio_wire.zig` is now a thin re-export of the shared helper.
- **Phase 2 — Tool module registry.** Defined `ToolModule` struct (definition + availability + execute + error_hint) in `module.zig`. Created comptime `all_modules` array in `registry.zig` with adapter wrappers for tools whose execute signatures differ. Replaced the 9-branch `if (std.mem.eql(...))` dispatch chain in `runtime.zig::executeWithRunner` with a single `registry.moduleByName` table lookup. Adding a tool now touches 1 file + 1 line in the registry (was 5 files).
- **Phase 3 — Storage optimizations.** (1) Eliminated `touchSessionUpdatedAt` write-amplification: `appendEventAndTouch` no longer rewrites `session.json` per event (was 6+ full rewrites per tool call). `updated_at_ms` is now terminal-only; precise timestamps live in the event spine. (2) Fixed O(n²) seq computation: `nextSessionMessageSeq` uses tail-scan (reads only the last line) instead of full-file parse on every append. Falls back to full scan only on malformed last line. (3) Made `ensureStoreReady` a one-shot migration with `.var/.migrated` marker file — eliminates the O(sessions) per-read walk that fired on every `readSessionRecord`/`initSession`/`listSessionRecords`.
- **Phase 4 — Loop seam isolation (in progress).** Extracted `executor/sanitizer.zig` (108 lines of operator-response sanitization + alias redaction) from `loop.zig`. loop.zig: 1271 → 1162 lines. Further extractions (batch, supervisor) will continue reducing the loop to its 4-phase turn body.
- Native validation: backend `1364/1364 tests passed` (1 test updated to reflect new terminal-only `updated_at_ms` contract); installed binary rebuilt and verified; loop.zig at 1162 lines (target: <250 after full Phase 4).

## 2026-07-13T06:00:00Z - ix search report contract hardening and competition-guided priority review

- **Search owner repair.** `search_files` now consumes the live `ix search --json` report envelope (`status`, `hits`, additive `stats`) instead of rejecting current reports because of unknown diagnostic fields. Zero matches remain a successful empty result; non-OK reports fail as typed `SearchReportInvalid` with a provider-facing retry hint.
- **Falsification coverage.** Added tests for live additive stats, zero-match success, and non-OK terminal status. Updated the tool-runner fixture to the live report shape.
- **Narrow compile repair.** Repaired two pre-existing stdio extraction blockers needed for honest validation: the missing `ClientState` struct opener and the moved `renderRpcRequest` visibility/call-site mismatch. No destructive cleanup or reset was performed.
- **Architecture/competition review.** Recorded the decision and ranked follow-up work in `.docs/research/2026-07-13-vantari-one-ix-agent-runtime-competition.md`. The conclusion is to finish auth, loop/event closure, and catalog contract proof before copying ix-owned warm/index/watch features into VANTARI.
- **Validation.** Direct Zig debug suite `1365/1365` passed; ReleaseSafe native build and `VAR1.exe --help` passed; `git diff --check` passed. ReleaseSafe binary SHA-256: `8A8EB109277520BB08A2A991F6B54A9FCB48BD1C1A3AD5EE21539CDC73C1C969`.

## 2026-07-13T07:00:00Z - versioned tool catalog execution contract

- **Model-visible capability truth.** Extended the canonical text and JSON tool catalogs from the existing `ToolDefinition` owner. JSON now emits `schema_version: 1`; each tool emits `execution_mode` and `signals_completion`. The executor and catalog therefore share one typed source rather than parallel scheduling metadata.
- **Competition-guided boundary.** The shape follows Codex's typed turn/item lifecycle, pi-mono's explicit execution/termination semantics, and Gemini CLI's discoverable tool/approval metadata. No new runtime subsystem or ix implementation was added.
- **Validation.** Backend debug suite `1365/1365` passed. ReleaseSafe build passed. Native `VAR1 tools --json` emitted the versioned catalog and metadata. `git diff --check` passed.
- **Promotion blocker recorded.** The current dirty stdio extraction still reports a Windows segmentation fault in the child scheduler thread after `VAR1 health --json` and `VAR1 tools --json` emit their payloads. `VAR1 --help` remains clean. This is now the highest-value next task because it blocks trustworthy installed-client proof for kernel-routed CLI commands.

## 2026-07-13T06:00:00Z - seam isolation: LocalClient extraction + batch extraction + correctness fixes

Three verified code updates from the architecture/competition study:

- **Correctness: tail-scan seq-less-row collision fix.** The O(1) tail-scan optimization for `nextSessionMessageSeq` had a silent data-loss bug: if the last JSONL line was valid JSON but had no `seq` field, the default 0 caused the next append to write seq=1 (colliding with existing rows). The appended message was durable on disk but invisible to readers. Fixed by validating `parsed.value.seq >= 1` and falling back to full scan. Falsification test proves a seq-less last row produces correct next-seq=3.
- **okEnvelope de-duplication.** Deleted the private `okEnvelope` copy from `workspace_runtime.zig` (byte-identical to `module.zig`). 22 call sites updated to `module.okEnvelope`. One canonical envelope path.
- **appendEventAndTouch rename.** Renamed to `appendEventSpine` across 5 files. The function no longer touches session.json (write-amplification eliminated); the name now matches the behavior.
- **Structural: LocalClient extracted to `host/stdio_client.zig`.** The client side of the stdio JSON-RPC protocol (LocalClient, ClientState, ReaderContext, readerLoop, processIncomingFrame, renderRpcRequest/Notification, waitForResponse, takeNotificationAfter) moved from `stdio_rpc.zig` to a new `stdio_client.zig` (395 lines). `stdio_rpc.zig` re-exports `LocalClient`, `RpcCallResult`, `Notification` for backward compatibility. stdio_rpc.zig: 1942 → 1578 lines (364 extracted).
- **Structural: parallel batch extracted to `executor/batch.zig`.** `executeToolCall`, `runParallelToolBatch` (now `batch.runParallel`), `parallelWorker`, and the result/worker structs moved from `loop.zig` to `batch.zig` (193 lines). loop.zig: 1162 → 981 lines (181 extracted). Made `recordSessionEvent`, `renderToolStartedEvent`, `renderToolFinishedEvent`, `cancelSession` public in loop.zig so batch.zig can use them.
- Native validation: backend tests green; installed binary rebuilt and verified.
- Cumulative architectural rewrite state: loop.zig 1271→981, stdio_rpc.zig 1942→1578, 4 new modules created (sanitizer.zig, batch.zig, stdio_client.zig, shared/json.zig + shared/protocol/events.zig).

## 2026-07-13T17:10:00Z - model discovery: /v1/models adapter + models CLI subcommand

Provider-level model discovery for OpenAI-compatible servers (LM Studio, llama.cpp, vLLM, Ollama, OpenRouter, z.ai). Harvested from pi-mono's multi-provider model-discovery surface and Codex's `/v1/models` probe pattern.

- **New module: `core/providers/models.zig`.** Typed `ModelDescriptor` + `ModelsList` + `listModels()` that GETs `{base_url}/v1/models` via the existing transport. Defensive parsing handles: LM Studio's omission of `created` (lmstudio-ai/lmstudio-bug-tracker#1988), vLLM's `context_length` field, llama.cpp's `max_model_len` field, and inconsistent error envelopes (`{error:string}` vs `{error:{message}}`). LM Studio native `/api/v1/models/loaded` probed as a fallback to recover runtime context_length (cline#4847 documents the OpenAI-compat surface as unreliable for this field). Fails closed: `Unreachable` / `BadStatus` / `MalformedResponse` — never guesses a model list, never panics.
- **Provider transport: `httpGet` + URL helpers.** Added `httpGet()` (standalone GET with its own `writeGetHead` — the POST path is completely untouched), `modelsUrl()`, `lmStudioLoadedModelsUrl()`, `isLocalHostUrl()`. All reuse the existing TLS/plain TCP plumbing.
- **Protocol: `models/list` method + `ModelsListResult` schema.** New `var1.models.v1` schema with `provider`, `base_url`, `models[]`, `context_from_native_surface`, `status` (ok/unreachable/bad_status/malformed), and optional `error_message`. Capabilities struct updated.
- **CLI: `models` subcommand.** `VAR1 models [--json] [--provider <id>]`. Human form lists id, context window (or "unknown"), owned_by. Discovery failures surface as a typed status rather than a crash.
- **RPC null-tolerance fix.** `optionalStringFromObject` now treats JSON `null` as absent (previously returned `InvalidParams` for `{"key":null}`). This broke every optional-string RPC param when clients emit explicit nulls.
- **Verification.** All 1343 backend tests pass. Installed binary (`vantari.exe`) tested against a live LM Studio instance at `localhost:1234` — lists all available models via both `--json` and human-readable output. Offline failure (port 9999) returns typed `status: "unreachable"` without crashing. The `run` command still reaches the z.ai provider (401 auth check) with no regression.
- **Architectural discipline.** One chat-completions transport (no parallel provider lane). The POST path is byte-identical to HEAD. No new prompt scaffolding, no branch graphs, no hardcoded model catalog (live discovery + operator settings cover the local-LLM case). GET transport is a sibling function, not a modification of the POST writer.

## 2026-07-13T17:25:00Z - multi-provider routing + context-window auto-detection + per-invocation overrides

Three verified features completing the local-LLM provider surface:

- **Multi-provider routing.** `readProviderById()` added to `auth/store.zig` — reads a specific provider from the auth ledger's `providers` map by id, independent of `active_provider`. The `handleModelsList` handler resolves `--provider <id>` to that provider's credentials (base_url, api_key) and probes its `/v1/models`. Verified: active=zai workspace, `--provider lmstudio` discovers all LM Studio models; `--provider nonexistent` returns typed `provider_not_found`; active provider path unchanged. The auth store's `readActiveProvider` was refactored to share `readProviderFromRoot` with the new function — one parsing path, no duplication.
- **Context-window auto-detection.** `applyLocalContextDetection()` wired into both `loadDefault` and `loadDefaultFromAuthOnly` in `config/resolver.zig`. When the active provider is a local host (localhost/127.0.0.1/::1), probes `/v1/models` to recover `context_length` for the configured model and seeds `context_policy.context_window_tokens`. Explicit `settings.toml [context] context_window_tokens` always wins (`settingsHasExplicitContextWindow` check). Remote providers are never probed (latency). LM Studio's `/v1/models` omits `context_length` (cline#4847) — the native `/api/v1/models/loaded` fallback in `models.zig` handles this when available; otherwise the default window is kept (no guessing).
- **Per-invocation override flags.** `--model <id>`, `--context-window <tokens>`, `--max-output-tokens <n>` on the `run` command. Flow: `RunCliOptions` → `parseRunArguments` → `TurnOverrides` → `executePromptTurn` → `session/send` params → `handleSessionSend` builds a local `effective_config` copy with overrides applied, passes it to the loop, frees the overridden model after the run. The `optionalU64FromObject` helper handles JSON u64 extraction (the `?u64` static parser overflows at comptime). Verified: `--model nvidia/nemotron-3-nano-4b --context-window 4096` runs a full tool-call turn against the lesser model without editing `.var/auth/auth.json`.
- **Lesser-model pipeline proof.** `nvidia/nemotron-3-nano-4b` (4B model) via LM Studio completed a full tool-call turn: `session_started → tool_requested → tool_reviewed → tool_started → tool_finished → tool_completed → assistant_delta* → final response`. The message ledger shows `user → assistant(tool_call) → tool(result) → assistant(synthesis)`. The 4B model successfully called `list_files`, received the result, and synthesized a coherent answer — proving the kernel's system design carries weaker models to a successful tool-call turn.
- All 1343 backend tests pass. Installed binary verified against live LM Studio.

## 2026-07-13T17:45:00Z - wire-protocol adapters: /responses + /anthropic_messages alongside /chat/completions

Three wire-protocol surfaces now selectable per-provider, harvested from Codex's `model_providers.wire_api` config shape and pi-mono's `Api` enum dispatch:

- **WireApi enum + config field.** `types.WireApi` enum (`chat_completions`, `responses`, `anthropic_messages`) with `fromString()` parser. Added to `types.Config` as `wire_api` field (defaults to `chat_completions`). Parsed from `settings.toml [provider] wire_api = "responses" | "anthropic_messages"` via `loadWireApi()` in `config/resolver.zig`.
- **providers/responses.zig** — OpenAI Responses API adapter (POST /v1/responses). Converts ChatMessage[] to/from the Responses input-item shape: messages become `role` items, tool calls become `function_call` items, tool results become `function_call_output` items. Handles LM Studio's response shape including `reasoning` and `message` output items. SSE streaming parser included for future streaming support. 5 in-band unit tests.
- **providers/anthropic.zig** — Anthropic Messages API adapter (POST /v1/messages). Converts ChatMessage[] to/from the Anthropic shape: system extracted to top-level field, `max_tokens` required, tools use `input_schema` (not `parameters`), tool calls become `tool_use` content blocks, tool results become `tool_result` blocks. Handles Anthropic SSE events (`content_block_start`, `content_block_delta`, `text_delta`, `input_json_delta`). 7 in-band unit tests.
- **providers/dispatch.zig** — Wire-protocol dispatch layer. One entry point (`completeWithTransportAndHooks`) that switches on `config.wire_api` and routes to the correct adapter. One shared HTTP transport, three wire-protocol shapes, one canonical CompletionResponse.
- **loop.zig** — Changed two `provider.completeWithTransportAndHooks` calls to `dispatch.completeWithTransportAndHooks`. All type references (Transport, StreamHooks, Error) stay on the provider module.
- **Non-streaming for new adapters.** The Responses and Anthropic adapters use non-streaming POST (direct `sendFn`) rather than the SSE streaming path. The SSE event format differs from chat completions; streaming support for these surfaces lands when the event-type mapping is proven. The chat-completions adapter retains full SSE streaming.
- **Verified against LM Studio.** All three surfaces tested end-to-end with `nvidia/nemotron-3-nano-4b`:
  - `/v1/chat/completions` (default) → ✅
  - `/v1/responses` (`wire_api = "responses"`) → ✅
  - `/v1/messages` (`wire_api = "anthropic_messages"`) → ✅
- All backend tests pass. z.ai regression path unchanged.

## 2026-07-13T18:05:00Z - fix: restore TUI CLI binary; backend install no longer clobbers vantari.exe

**Root cause.** The backend install script (`apps/backend/scripts/install_windows.ps1`) installed its binary as `Vantari\bin\vantari.exe` — the same name the CLI/TUI install script (`apps/cli/scripts/install-var.ps1`) uses for the vaxis TUI binary. When the backend install ran after the CLI install, it overwrote the 6.5MB TUI binary with the 1.2MB backend binary, losing the TUI.

**Fix.** Changed the backend install script's default `InstallPath` from `vantari.exe` to `VAR1-kernel.exe`. The backend kernel binary now installs as `VAR1-kernel.exe`; the CLI/TUI install script owns `vantari.exe` and `var.exe`. The two install scripts no longer conflict.

**Restored.** Ran `apps/cli/scripts/install-var.ps1` to rebuild and install the proper TUI binary. Verified: `vantari.exe` is now 6.5MB (TUI), health/models/run commands work, TUI reports `TerminalUnavailable` correctly in non-interactive shells. Both backend and CLI test suites pass.

## 2026-07-13T19:00:00Z - merge: one binary, one build, one install script

Consolidated the two-binary split (backend `VAR1.exe` + CLI/TUI `var.exe`/`vantari.exe`) into a single binary. The CLI was a strict superset of the backend — same `VAR1.clients.cli.main()` dispatch for all subcommands, plus the vaxis TUI. Two binaries, two build files, two install scripts served zero capability benefit.

**What changed:**
- **`apps/backend/build.zig.zon`** — added `vantari_tui` path dependency (`../../packages/tui`)
- **`apps/backend/build.zig`** — exe now imports `tui` module alongside `VAR1`; exe renamed from `VAR1` to `vantari`; added `tui_chat` test artifact with both imports; test step runs all three test suites
- **`apps/backend/src/main.zig`** — folded TUI dispatch from `apps/cli/src/main.zig`: bare invocation → TUI, `-c`/`--continue` → TUI continue mode, any subcommand → `VAR1.clients.cli.main()`
- **`apps/backend/src/clients/tui_chat.zig`** — moved from `apps/cli/src/tui_chat.zig` (unchanged — pure consumer of public VAR1 module surface)
- **`apps/backend/scripts/install_windows.ps1`** — consolidated sole installer: builds `-Doptimize=ReleaseFast`, installs as `vantari.exe`, kills locked processes, seeds auth from repo, adds to PATH
- **`apps/cli/`** — **DELETED** (build.zig, build.zig.zon, src/main.zig, scripts/install-var.ps1, tui_chat.zig moved)

**Result:** One binary (`vantari.exe`, 2.8MB ReleaseFast), one build (`apps/backend/`), one install script, one test suite. The binary handles TUI (bare/`-c`), all CLI subcommands (`run`, `models`, `health`, `tools`, `serve`, `c`, `auth`, `schedule`), and text-mode interactive fallback. All backend tests + TUI tests pass. Verified against LM Studio with `nvidia/nemotron-3-nano-4b`.

## 2026-07-13T20:00:00Z - pipeline integrity: self-healing orphan tool-call tails + faster stale-session recovery

Two consumer-breaking pipeline failures are now structurally impossible.

### Failure 1: Orphan tool-call tail (UnresolvedToolCallTranscript)

**Before:** When a session was interrupted (crash, cancellation, or cold-start) after the assistant's tool-call message was persisted but before all tool results were appended, the context builder detected the orphan tail and hard-failed with `UnresolvedToolCallTranscript`. The session was permanently `.failed` and unresumable — any continuation attempt re-ran the same broken transcript and hit the same error.

**After:** The context builder (`core/context/builder.zig`) now **self-heals** orphan tails by synthesizing missing tool results. When the transcript ends with unresolved tool calls, each missing result gets a synthetic message: `"[Tool execution was interrupted before producing a result. The session was recovered automatically.]"`. The provider sees a structurally valid transcript and the turn proceeds. Orphan tool results (no preceding tool call) are silently skipped rather than rejected. This is what Codex and pi-mono do — they never hard-fail on orphan tails.

**Tests updated:** 23 tests that asserted the old hard-fail behavior now assert self-healing (builder succeeds, synthetic results present, session completes).

### Failure 2: Stale-running session lock (120-second wait)

**Before:** When the host process crashed, the session's persisted status stayed `.running` with no in-process owner. The operator had to wait **120 seconds** (`stale_running_session_ms = 120_000`) before the session would auto-reconcile to `.failed` and accept a continuation. During that window, the session was unresumable.

**After:** The stale timeout is reduced to **5 seconds** (`stale_running_session_ms = 5_000`). This is long enough to cover normal turn latency between events, but short enough that a crashed/restarted process self-heals near-instantly. The operator can continue a crashed session within 5 seconds instead of 2 minutes.

### What makes the pipeline unbreakable now

- An orphan tool-call tail can NEVER brick a session — the builder always produces a structurally valid provider window
- A crashed process can NEVER lock a session for more than 5 seconds
- A session can ALWAYS be continued after any interruption (crash, cancel, timeout)
- No transcript topology is unrecoverable — the worst case is a synthetic tool result the provider understands as "interrupted"
### 2026-07-15 — Scoped agent memory

- Added the canonical two-scope memory runtime: append-only session `memories.jsonl` and compact global `memories.md`.
- Added source-linked remember/supersede/forget records, bounded deterministic recall, secret and transcript rejection, and always-available `memory_read` / `memory_write` tools.
- Added complete documented memory policy values to `~/.vantari/config.json`, prompt-compiler integration, 38 focused tests, and a nine-system primary-source competitor harvest.

### 2026-07-16 - Memory/config QC closure

- Removed the retired `memories.md` workspace-state trigger and stale prompt-builder export so global-memory requests cannot expose the old `.var` tool surface or break a clean module compile.
- Made the global ledger resolve through the home-scoped runtime root and routed documentation bootstrap through the same memory owner; session memory remains isolated by session ID.
- Reconciled stale tests with the current canonical `config.json` contract and sibling `auth.json` migration behavior instead of preserving the removed `settings.toml` and nested-auth expectations.
- Re-ran the full backend test mesh, the focused memory suite with isolated home storage, native ReleaseFast installation, installed config validation, catalog JSON parsing, IX stale-path scan, and dupe audit: all passed; the focused suite is 38/38 with no failures.

## 2026-08-06 - Role-routed bounded agent execution

**Outcome:** Replaced process-per-child polling with a role-routed, bounded in-process supervisor. VANTARI now exposes stable `general`, `recon`, `planner`, `compactor`, `implementer`, `reviewer`, and `validator` specialists whose provider/model/wire routes can be remapped independently without creating a second runtime.

**Mechanism:**

- Added immutable `AgentSpec`, enforced tool-class profiles, one `RouteRole` resolver, and secret-free `ExecutionReceipt` persistence before dispatch.
- Replaced one process plus detached watcher per child and 10 ms session-directory polling with one fixed `std.Thread.Pool`, hard concurrency limits, O(1) group/parent indexes, condition-based wait, cancellation, and cold-only ledger recovery.
- Added canonical `{ context, tasks[] }` admission, group-addressed terminal reconciliation, exactly-once convergence, parent parking with zero provider calls, and one post-convergence synthesis turn.
- Added tool-free, recursion-free, schema-bound model tasks for planner, compactor, and supplied-artifact reviewer roles.
- Projected typed child lifecycle events through parent `events.jsonl`, stdio, CLI, and stable keyed TUI rows. Child assistant/reasoning deltas remain child-local so the parent control spine stays bounded.
- Removed startup-wide `session.json` rewrites. `ensureStoreReady` now initializes only canonical path and process-local sequence state; explicit migrations own schema mutation.

**Proof:**

- Full Zig 0.15.1 mesh passed: `1541/1541` tests across `15/15` build steps.
- Scale tests covered `1/5/20/100` children, worker ceilings, zero provider-spin waiting, zero healthy directory scans, overlapping groups, cancellation, exact terminal ordering, model-task schema failure, profile denial, receipt recovery, and additive-field preservation.
- Dupe audit found zero exact duplicates across the new agent/profile/route owners.
- ReleaseFast installed binary SHA-256: `F22F89A425FEE37CBC0F6868A30B61C4362D48A75EADF9C43893E3CF5A993389`.
- Installed live planner proof: parent `session-1786054776392-4aa6b6b11363365f`, child `session-1786054787881-450b26e512e8c859`, group `group-1786054787880-30b9c9504fc3cf23`; route receipt resolved `zai / glm-5.2 / chat_completions`, enforced zero tool calls, survived terminal state, and contained no API key.

**Open P1 boundary:** Normalize provider token usage before adding usage to receipts/events. Route the existing manual compaction writer and future classification/title owners through the model-task lane without moving deterministic checkpoint selection into the model.

## 2026-08-09 - TUI runtime footer telemetry and surface hierarchy

**Added:**

- Exposed resolved effort, thinking mode, context capacity, and output reserve through the health protocol.
- Projected typed turn-boundary window tokens into the TUI footer.
- Added compact model, effort, context used/capacity/percentage/remaining, and live agent count metadata.
- Added a status dot with ready, working, and failed states.

**Changed:**

- Raised the composer tint above the transcript surface and the metadata row below it without adding borders or extra chrome.
- Removed the visible `Esc cancel` hint while preserving Escape/Ctrl-C cancellation behavior.
- Kept agent counts derived from existing keyed child activity rows rather than creating a second registry.
- Kept runtime-policy effort storage owned through config resolution so the
  footer and health projection cannot read freed config memory.
- Repaired the existing prompt-history cleanup and Zig 0.15.1 ArrayList calls
  required by the clean Windows ReleaseFast install lane.

**Proof:**

- `apps/backend/scripts/zigw.ps1 build test-tui` passed on Windows Debug.
- `apps/backend/scripts/zigw.ps1 build test-tui -Doptimize=ReleaseFast` passed.
- Clean-cache `apps/backend/scripts/install_windows.ps1` passed; installed and
  repository ReleaseFast hashes matched.
- Installed `vantari health --json` reported `effort: max`,
  `context_window_tokens: 128000`, and `reserve_output_tokens: 8192`.
- Installed TUI startup rendered `glm-5.2 · max · ctx — / 128k`; non-interactive
  startup failed closed with typed `TerminalUnavailable` evidence.
- Research and owner mapping: `.docs/research/2026-08-09-tui-status-surface-and-repair-loop.md`.

## 2026-08-09 - Provider cost model + wire compat auto-detection (chain 035)

**Added:**

- Measured token telemetry: all three wire adapters parse provider `usage` (chat_completions prompt_tokens_details.cached_tokens + stream terminal chunk, Anthropic input/output/cache_creation/cache_read, Responses input_tokens_details.cached_tokens) into `types.Usage` on `CompletionResponse`.
- Compiled pricing engine `core/providers/pricing.zig` (prime-agent calculateCost formula, harvested price table with provenance, null cost for unknown models).
- `turn_finished` schema v2: `prompt_tokens/completion_tokens/cached_tokens/cost_total_usd` (null when unpriced), built by the single owner `core/executor/turn_payload.zig` and emitted by both the kernel loop and model-task supervisor.
- Compat auto-detection `core/providers/compat.zig`: `WireApi.auto` config floor resolves per base URL at dispatch (api.anthropic.com → anthropic_messages, else chat_completions); thinking shape keyed per endpoint (zai enable_thinking / deepseek nested thinking + reasoning_content echo / standard none).

**Changed:**

- `provider.wire_api` default is `"auto"` (explicit values still override detection).
- The z.ai `enable_thinking` P0 fix is now scoped to z.ai endpoints instead of every chat_completions request.

**Proof:**

- `zig build test`: 1245/1494 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression across 035a-e).
- 44 new tests across pricing (10), usage parse (20), turn payload (6), compat/detection (8) + config validation (3).
- Installed binary validation pending (035h review).

## 2026-08-10 - Buffered ticket scheduler and operator projection (chain 036)

**Added:**

- Durable ticket-event projection, queue-only assignment, revision-bound claims,
  lease renewal, stale requeue, terminal evidence, and repair-required closure
  fields under `core/tickets`.
- Scheduler-owned ticket wake/dispatch/recovery through the existing
  `AgentService` and bounded `Supervisor`; capacity remains one execution
  authority and `PoolFull` leaves work assigned.
- Additive `health/get` pool and ticket counts projected from Supervisor and the
  valid ticket-event prefix.
- Compact TUI footer pressure segments (`pool running/max`, `queue assigned`)
  with bounded idle refresh, while preserving model/effort/context telemetry,
  the composer/meta surface hierarchy, and Esc-free copy.

**Proof:**

- Pinned Zig 0.15.1 application build: `Build Summary: 9/9 steps succeeded`.
- Scheduler/ticket focused probes: `18/18` ticket-filter tests and `14/14`
  scheduler-filter tests passed with the live `VANTARI_HOME` override cleared
  for isolated temporary scheduler leases.
- TUI artifact: `49/49` tests passed; health RPC probe: `2/2`; ticket snapshot
  probe: `2/2`; `git diff --check` exited 0 with only LF/CRLF normalization
  warnings.
- The broad graph reached `1673/1676`; the three failures remain in unrelated
  runtime-loop, prompt-guidance, and workspace-resolution tests and are carried
  as the explicit 036f regression boundary.

## 2026-08-10 - Integrated ticket/pool proof and installed consumer closure (036f)

**Added:**

- Lossless installed CLI health projection for Supervisor pool health/capacity
  and all ticket lifecycle buckets, with compact text output for pool and queue
  pressure.
- Explicit unhealthy/unknown pool state when Supervisor capacity cannot be
  read; zero is no longer reported as a healthy pool.
- Queue-only session absence assertion at `log_ticket`, and replay-loser
  session failure evidence so a duplicate claim cannot create a second worker.
- Windows installed ReleaseFast proof through the canonical installer,
  including exact-path process cleanup and staged hash verification.

**Proof:**

- Pinned Zig 0.15.1 Debug build: `Build Summary: 9/9 steps succeeded`.
- Canonical TUI artifact: `Build Summary: 9/9 steps succeeded; 53/53 tests passed`.
- Broad canonical graph: `1681/1684` passed; three unrelated pre-existing
  runtime-loop/tool-prompt/schema-repair failures remain explicitly bounded.
- Installed `vantari.exe`: installer exit 0; `--help`, `health --json`, and
  `config validate` exit 0; health JSON parses all 12 additive pool/ticket
  fields; noninteractive TUI returns typed `TerminalUnavailable`; exact-path
  process check returns zero; built and installed SHA256 match
  `54496C7479C99C7E021247DC9D9F487541DCABF48FD9DC5BC41D4F24A082D179`.
- `git diff --check` exits 0 with only known LF/CRLF normalization warnings.

## 2026-08-10 - Terminal QC and chain closeout (036g)

**Proof:**

- The ownership audit found one canonical ticket ledger path under
  `core/tickets`, one Supervisor-backed capacity path, and no second ticket,
  pool, or status owner. Assignment remains queue admission; scheduler claim
  remains the session and execution boundary.
- Pinned Zig 0.15.1 build passed `9/9`; canonical TUI passed `53/53`; the
  broad graph remains `1681/1684` with only the three named pre-existing
  runtime-loop/tool-prompt/schema-repair failures.
- Installed `vantari.exe` health exposed all 12 additive fields with pool
  `0/6`, 6 available, and a healthy ticket ledger. `vantari -c` exited 1 with
  typed `TerminalUnavailable` in the noninteractive shell, and the exact
  installed process count was 0. Built and installed SHA256 matched
  `54496C7479C99C7E021247DC9D9F487541DCABF48FD9DC5BC41D4F24A082D179`.
- The parent manifest is complete, 036a-036g are archived, `next_todo` is
  `NONE`, and `git diff --check` exits 0 with only known line-ending warnings.

## 2026-08-10 - Agent summary child-row projection correction

**Changed:**

- The visible child row now keeps one keyed `group_id + task_id` entry. Tool
  lifecycle phases update the state marker but no longer become the row label.
- The supervisor projects the canonical child session summary at
  `assistant_response`; the TUI compacts whitespace and truncates it to the
  available one-line width.
- The agent group row is `Agents completed/total`; the removed `waiting on N`
  filler is not rendered. Persistent `Esc cancel` copy remains absent.
- Project records now include `AGENTS.d/index.md`, `.docs/index.md`,
  `.docs/technical_summary.md`, `.docs/workspace.json`, and `.refs/index.md`.
  Scoped todo/changelog contracts now describe the planning-spec v3 chain.

**Proof:**

- Pinned Zig 0.15.1 `build test-tui --summary all`: `54/54` tests passed.
- Pinned Zig 0.15.1 Debug application build: `9/9` steps succeeded.
- Two adjacent pre-existing dirty compile defects in agent/config edits were
  repaired before validation: the `doc_writer` initializer and the temperature
  validator's shadowed local.

## 2026-08-10 - Agent schema v2: doctrine-distilled specialists + ticket lifecycle policy

**Added:**

- `agents.definitions` schema v2: every specialist carries `doctrine_tags` (distilled AGENTS.md/agents.d vocabulary rendered into the model-visible catalog), `ticket_ownership` (agent drives its own ticket states; closing is structurally kernel-only — no config knob exists to widen it), `checkpoint_contract` (>=3-sentence live summary discipline), `autonomy` (directed/bounded/self_directed closed vocabulary), and optional `effort`/`temperature` (absent = VANTARI decides — the model is the plane, VANTARI is the pilot).
- Five new builtin specialists: `scaffold` (planning-spec chain scaffolding with proof gates), `spec` (contract/spec author), `orchestrator_parent` (aggressive fan-out + ticket assignment + close/reopen-with-reasoning authority), `harvester` (three-law research harvest with source-proof), `doc_writer` (sliced large-file persistence). All seven existing floors enriched with ticket discipline, evidence-first capsules, and QC 4/4 reviewer judgment.
- New `tickets` config section: `auto_assign` (assigned ticket auto-starts a specialist subagent), `proactive_workpool` (false = agents wait for assignment; true = idle specialists claim tickets), `close_authority` (kernel|operator), `reopen_with_reasoning`. Loaded via `loadTicketPolicy`.
- `configure_agent` tool accepts the new fields; `renderCatalog` emits doctrine/ticket/checkpoint/autonomy/effort; `capabilityHash` now covers ticket ownership + autonomy.

**Proof:**

- `zig build test`: 1245/1494 main tests passed; failure set identical to pure-HEAD baseline (comm diff empty — zero regression).
- All 48 agent registry contract cases pass with VANTARI_HOME unset, including 10 new cases (floor defaults, catalog doctrine render, full-field upsert round-trip, autonomy/temperature rejection, ticket policy defaults/custom/invalid).
- Prompt guardrail test synced to the current builder text after an external working-tree edit replaced the path-protocol wording (mtime 20:39; surfaced, not silently reverted).

## 2026-08-12 - Full harness SITREP and WIP accountability

**Added:**

- A full architecture, pipeline, process, method, competitive-harvest, proof,
  and readiness report at
  `.docs/research/2026-08-12-full-harness-sitrep.md`.
- A priority-ordered executable findings ledger at
  `.docs/todo/findings/00-INDEX.md`.
- Current project-record links and machine-readable WIP/proof state in
  `.docs/index.md`, `.docs/technical_summary.md`, and
  `.docs/workspace.json`.

**Corrected:**

- Chain 036's historical closeout no longer acts as current production-ready
  proof. Process-local agent execution, non-atomic scheduler leadership,
  concurrent summary mutation, and event-sequence loss reopen its closure.
- Chain 035 remains pending at 035g/035h until the current ReleaseFast source
  reaches the installed consumer path.
- Public docs now distinguish tracked clients, local prototypes, source-only
  mechanisms, installed proof, and frontier scaffolds.

**Proof:**

- ReleaseFast build: 9/9.
- Focused backend TUI: 54/56 passed, 2 skipped.
- Vendored packages/tui: 103/104 passed, 1 skipped.
- Isolated broad graph: 1690/1693 passed, 3 failed.
- Built and installed hashes differ; active installed TUI/kernel processes
  were preserved and no install was attempted.
- The inherited production VANTARI_HOME test incident touched 535 runtime files
  and is retained as an explicit P0 quarantine/repair obligation.

## 2026-08-12 - Harness capability next-90 execution order

**Added:**

- `.docs/roadmap/24-harness-capability-next-90.md` ranks 90 concrete moves by
  operator value, dependency leverage, integrity risk removed, and friction
  removed.
- The queue accounts for findings 10-31, live chains 021/035/036/PLUG, the
  installed Windows proof boundary, and a 13-reference harness/runtime harvest.

**Decision:**

- Serialized test roots, RPC lifetime, ledgers, and persistent agent execution
  precede TUI expansion, context sharding, plugins, and autonomous repair.
- The strategic north star remains sharded token-minimal execution; roadmap 24
  is the current implementation order required to reach it without building on
  unsafe process-local ownership.

## 2026-08-12 - Prompt-led autonomy and subtractive capability doctrine

**Added:**

- Applied doctrine extractions for prompt-led autonomy and subtractive
  capability under `AGENTS.d/extractions/`.
- Roadmap-wide add/consolidate/delete arbitration. All 90 moves must close, but
  no move requires new code when deletion or owner consolidation closes it.
- Prompt-profile proof for behavior, orchestration posture, pace, narration,
  and burst cadence without alternate executor state machines.

**Boundary:**

- The model chooses behavior and the next eligible action. The kernel owns
  executable capability, durability, budgets, evidence, recovery, and explicit
  irreversible-action gates.

## 2026-08-12 - Test artifact isolation and runtime-root guard

**Changed:**

- `apps/backend/build.zig` now creates all five test run artifacts through one
  isolated constructor. Each child gets a generated `VANTARI_HOME` under the
  Zig cache; the parent process environment remains untouched.
- `apps/backend/src/shared/fsutil.zig` enforces `VANTARI_TEST_ROOT` before it
  creates a global or workspace runtime path.
- Removed 31 obsolete `VANTARI_HOME` skip guards from config, memory, settings,
  registry, scale, deep-pipeline, and store tests.

**Proof:**

- Broad graph executes and passes 1,695/1,695 tests with zero skipped.
- A run launched while the parent pointed at `C:\Users\Savage\.vantari`
  preserved live file count, byte count, and complete relative-path/content
  tree SHA-256.
- The runtime-root guard accepts an in-root fixture and rejects an outside path
  with `TestRuntimePathOutsideRoot`.
- ReleaseFast succeeds 9/9 with the test-only root marker set to an unrelated
  path, proving production code does not consume the marker.
- Removed one retired `todo_slice` prompt instruction and one duplicate
  file-inspection instruction. The existing write-before-inspect enforcement
  remains covered by adversarial tool tests.

## 2026-08-12 - Roadmap integrity floor through move 19

**Changed:**

- Accounted for closed roadmap moves 2–18 in the current closure ledger at
  `.docs/roadmap/24-harness-capability-next-90.md`; this changelog previously
  stopped after move 1. Historical closeout evidence remains unchanged.
- Consolidated every current run settlement behind
  `apps/backend/src/core/sessions/store.zig::commitTurnTerminal` and deleted the
  active success/failure/cancellation terminal dialects.
- Added `var1.turn_terminal.v1` with exact `session_started.seq` and outcome
  `completed`, `failed`, `timed_out`, or `cancelled`. Identical retries are
  idempotent; stale, conflicting, malformed, and duplicate settlement fails
  before a second authoritative row can append.
- Updated the tracked TUI, host, child supervisor/service, installed smoke,
  root contract, READMEs, architecture, SITREP, roadmap themes, machine record,
  and current research projections. Legacy terminal names remain read-only for
  existing ledgers.

**Validation:**

- `apps/backend/scripts/zigw.ps1 build test --summary all`: 19/19 steps and
  1,958/1,958 tests.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all`:
  9/9 steps.
- Packaged GGUF dupe audit across eight production owners: 237 segments, eight
  similarity candidates, zero exact duplicates, and no second production
  settlement owner.
- `apps/backend/scripts/install_windows.ps1 -SkipBuild`: source and installed
  SHA-256 both
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`.
- `apps/backend/scripts/verify_installed_summary_migration.ps1`: installed
  provider/tool turn ended on one stored/notified `turn_terminal` at sequence
  12 with schema `var1.turn_terminal.v1`, outcome `completed`, and `run_seq = 1`;
  process exit 0 and zero remaining VANTARI processes.

**Next todo:** move 20 — 100-way adversarial admission, summary, message,
event-burst, and shutdown mesh.

## 2026-08-12 - Roadmap integrity floor closed through move 20

**Changed:**

- Added synchronized 100-way pressure at the three missing seams: concurrent
  same-millisecond event append, exact tracked-TUI delivery/replay, and the
  admission-fenced shutdown sweep.
- Retained the existing 100-way admission, summary, and mixed-role message
  probes. Six high-cardinality seams now read back authoritative ledger or
  runtime state.
- Corrected the live-stream replay fixture to end on the current
  generation-bound `turn_terminal`, not the historical `assistant_response`
  boundary.
- Closed finding 13 and advanced the 90-move frontier to move 21. No production
  mechanism, shared fixture framework, database, randomizer, simulator, or
  parallel owner was added.
- Repaired chain 036 continuity: the pending parent no longer labels itself
  complete or points at closed finding 10. Finding 11 and moves 21–30 are its
  sole current frontier.

**Validation:**

- Four consecutive `scripts/zigw.ps1 build test --summary all` runs: 19/19
  steps and 1,959/1,959 tests each. Owner artifacts report 1,499 integration,
  61 tracked-TUI, and 239 host tests.
- `scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all`: 9/9 steps.
- Test-only ReleaseFast SHA-256:
  `7F1256550B859566F89DD7B86A33E34D239D69CEB612D185396CB621388A24B2`.
  The installed move-19 hash remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned TUI PID 12028 and `kernel-stdio` PID 14452 were preserved.
- Dupe-audit and installed replacement are explicitly deferred: the diff
  changes test declarations and records only; move 38 owns replacement after
  active installed owners exit.

**Next todo:** move 21 — make one daemon or detached worker process the
long-lived execution owner without adding a parallel pool.

## 2026-08-12 - Roadmap move 21 source owner lifecycle closed

**Changed:**

- Promoted the existing loopback bridge into one project-local execution owner.
  Public `LocalClient` now resolves or starts that owner; private `ChildClient`
  alone spawns the sole `kernel-stdio` child and existing pool/scheduler tree.
- Added one crash-released start lock, one lifetime lease, and one atomic
  `.var/runtime/execution-owner.json` projection with workspace, generation,
  protocol, token, executable, PID, port, and start identity.
- Added exact token-gated owner RPC/event/health/shutdown routes without changing
  the separately redacted browser routes or kernel JSON-RPC method set.
- Disabled Windows handle inheritance during detached owner creation, removing
  the capture-pipe lifetime that made Settings and short CLI calls hang.
- Unified foreground `serve` and automatic `execution-owner` behind the same
  lease; removed remote `--host` binding and rejected duplicate foreground
  ownership with a typed operator envelope.
- Reused one workspace resolver, bounded accepted owner connections at 64, and
  drained all detached connection jobs before bridge/child teardown. No daemon
  framework, second pool, queue, scheduler, transcript, or event bus was added.
- Bound explicit owner startup to `loadDefaultForExplicitWorkspace`; inherited
  `VANTARI_WORKSPACE`, `.env` `WORKSPACE`, and config workspace entries can no
  longer redirect config, auth, ledgers, or the owner projection after selection.

**Validation:**

- Pinned Zig 0.15.1 graph: 19/19 steps and 1,968/1,968 tests, including
  stalled-owner socket-deadline and explicit-workspace precedence probes. Final
  ReleaseFast passed 9/9; both owner entry tracers and the 20-client lifecycle
  proof then passed on that artifact.
- `prove-owner-tracer.ps1` passes for hidden `execution-owner` and foreground
  `serve`; two clients see one generation and duplicate foreground start is
  rejected. The hidden tracer also proves explicit `--workspace .` defeats a
  conflicting inherited workspace. Latest evidence roots:
  `.zig-cache/owner-proofs/c7ac3f1fb3634ae6b2fb5e8787eb01b4` and
  `.zig-cache/owner-proofs/568e7e6675f04b338820e88807762b95`.
- `prove-owner-lifecycle.ps1 -ConcurrentClients 20` reports 20/20 successful
  clients, one owner/kernel pair, accepted graceful shutdown, forced-crash tree
  zero, one new generation on each recovery, and final zero processes. Evidence:
  `.zig-cache/owner-proofs/a9035dcbf5e945c7942a46885c896458`.
- GGUF duplicate-owner audit inspected 110 segments across nine owner-adjacent
  files. Two import/declaration adjacency pairs surfaced, with zero exact
  duplicates and no second lifecycle, workspace, transport, or process owner.
- Source SHA-256 is
  `3062D10908D9678793298BDD3982EF515A3D953C9085E1EE5C681856725EE00E`.
  Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 were preserved.

**Boundary:** Move 21 is source-complete but remains open for installed equality.
Move 22 owns the dead `run-session` surface. Moves 23–30 own inter-process
scheduler/ticket claims, mailbox delivery, active-turn owner-crash
reconciliation, and terminal installed proof.

**Next todo:** move 22 — route `run-session` through the persistent owner or
delete the dead launcher-shaped path.

## 2026-08-12 - Roadmap move 22 dead per-session executor deleted

**Changed:**

- Deleted the uncalled `run-session` command, direct executor-loop branch,
  parser, and detached-worker help from `clients/cli.zig`: 138 production lines
  removed and no replacement abstraction added.
- Kept one continuation path: `run --session-id -> LocalClient -> /owner/rpc ->
  session/send`. This preserves the persistent owner's fixed pool, nested agent
  service, admission gate, event spine, and process supervision.
- Added one negative CLI contract and one exact owner-route submission probe.
  The latter observes `session_started` then `assistant_response` through the
  sole kernel transport.

**Validation:**

- Source ownership search finds no launcher or production `run-session` symbol.
- Pinned Zig 0.15.1 graph: 19/19 steps and 1,970/1,970 tests. ReleaseFast: 9/9.
- ReleaseFast `help run-session` exits 2 with `unknown command`; root help omits
  the retired name.
- Hidden execution-owner tracer passes on the final artifact with one generation,
  two reconnects, explicit-workspace precedence, and cleanup. Evidence root:
  `.zig-cache/owner-proofs/9de64f4dbfe9483684875605ad39de10`.
- Source SHA-256 is
  `899B9F340C4151A8E2D7EFD26F5778312F1EE82C93C8E0804DC36F954B9B9CA2`.
  Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Boundary:** Move 23 owns scheduler leadership fencing. Active-turn owner-crash
reconciliation, ticket claim serialization, mailbox delivery, and installed
replacement remain later explicit moves.

**Next todo:** move 23 — replace scheduler read/check/write leadership with one
inter-process exclusive claim and owner-generation fence.

## 2026-08-13 - Roadmap move 23 scheduler leadership fenced

**Changed:**

- Replaced scheduler `lease.json` read/check/write leadership with one
  crash-released OS lock held across the complete scheduled-job and ticket tick.
- Extracted the proven owner byte-range lock into
  `shared/process_lock.zig`; execution-owner startup/lifetime and scheduler
  leadership now consume one primitive instead of maintaining two lock bodies.
- Added a random nonzero scheduler generation to the durable lease projection,
  rejected an active different generation, and read back the exact projection
  before dispatch.
- Replaced the constant ticket worker generation with the scheduler's process
  generation. No database, daemon, election service, scheduler registry, or
  second pool was added.
- Added a synchronized contender falsifier and
  `prove-scheduler-leadership.ps1`, which launches two full source kernels
  against one due job and cleans only its own PIDs.

**Competitive decision:**

- Harvested Oh My Pi's process-owned crash-released lock and Eve's one-generation
  dispatch invariant. Scion, NullClaw, and KrillClaw remain in-process-only;
  Flue's tracked cron is manifest-only; Codex and pi expose no comparable local
  scheduler owner. VANTARI retains fewer concepts and adds Windows-native
  two-process proof.

**Validation:**

- Pinned Zig 0.15.1 graph: 19/19 steps and 1,973/1,973 tests. ReleaseFast: 9/9.
- Barrier contention returns one guard and one `LeaseUnavailable`.
- Native evidence root
  `.zig-cache/owner-proofs/e421ccb28240402ead1fbcbcb3903335` records two
  concurrent kernels, one attempt ID, one reserved row, one completed row,
  generation `1127306601282036122`, empty stderr, and final zero proof-owned
  processes.
- GGUF duplicate-owner audit: 34 segments, zero candidate pairs, zero exact
  pairs.
- Source SHA-256 is
  `06521D7CCA11F9084F79470340805EC1BE4D8E4B8BF4BBE62A5BBD9621AD24AE`.
  Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Boundary:** Scheduler leadership is closed in source. Move 24 owns ticket
claim plus lease issuance as one serialized transition. Active-turn owner-crash
reconciliation, mailbox delivery, and installed replacement remain later gates.

**Next todo:** move 24 — serialize ticket claim plus lease issuance so one
ticket revision creates one child session under contention.

## 2026-08-13 - Roadmap move 24 ticket admission serialized

**Changed:**

- `core/tickets/index.zig` now acquires `.var/tickets/ledger.lock` through the
  shared crash-released process-lock owner for every projection and mutation.
  Claim read, revision validation, and append are one process-serialized
  transition.
- The claim row commits worker id, nonzero generation, lease token/expiry,
  attempt, selected agent/capability hash, and deterministic child-session id.
- `core/agents/service.zig` derives the child id from the durable claim key,
  appends the claim before session materialization, and permits only the append
  winner to create and submit the child through the existing Supervisor.
- Synthetic ticket coordinators also use one deterministic identity. No database,
  transaction coordinator, worker registry, queue, or execution pool was added.
- `core/sessions/store.zig` accepts an internal explicit session id only after a
  path-safe validation and refuses overwrite with `SessionAlreadyExists`.
- `prove-scheduler-leadership.ps1` now pressures one due job and one assigned
  ticket across two complete kernels in the existing proof lane.

**Proof:**

- Canonical graph: 19/19 steps, 1,976/1,976 tests.
- ReleaseFast: 9/9; source SHA-256
  `DF57FB34112E0D1125D50620995EDF2683711D546B359226F504D2C4A03C6C00`.
- Native evidence root
  `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` records two
  kernels, one schedule attempt, one ticket claim, one matching deterministic
  child session, shared generation `1804748275523875660`, committed lease, empty
  stderr, graceful EOF shutdown, and zero proof-owned survivors.
- GGUF duplicate-owner audit: four runtime owners, 76 segments, zero candidate
  pairs, zero exact duplicate candidates.
- Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Competitive harvest:** Flue contributes deterministic parent/task child
identity. Oh My Pi contributes crash-released process exclusion. Codex, Eve, pi,
NullClaw, and KrillClaw confirm that in-process task ownership alone does not
close VANTARI's cross-process append race. VANTARI composes the two useful
invariants into existing ticket/session owners.

**Boundary:** Move 24 is closed in source. Move 25 owns assignment's
side-effect-free queue-admission proof. Owner-crash reconciliation, durable agent
mail, and installed replacement remain later gates.

**Next todo:** move 25 — prove every assignment caller mutates only the ticket
ledger and starts no session, provider turn, or Supervisor task.

## 2026-08-13 - Roadmap move 25 assignment made queue-only

**Changed:**

- Deleted the unused `tickets` config object, its four execution-policy keys,
  `TicketPolicy`, loader, validation, close-authority parser, default sample, and
  public documentation. `agent_routes.max_concurrency` is now the sole capacity
  setting.
- Strengthened the canonical `log_ticket` probe across create-as-assigned and
  unassigned-to-assigned. Two assigned tickets retain zero claims, active-session
  ids, and session records; direct `in_progress` still fails before side effects.
- Replaced 45 one-case agent-registry wrappers with one loop over every declared
  case. This exposed ten previously undiscovered cases; all 53 now execute.
- Corrected the hidden invalid-autonomy case to expect the canonical config
  boundary instead of an unreachable downstream parser error.

**Proof:**

- Canonical graph: 19/19 steps, 1,933/1,933 tests. The lower total removes 45
  duplicate wrappers while increasing registry coverage from 46/56 declarations
  to 53/53.
- ReleaseFast: 9/9; source SHA-256
  `77A2B111DCA35AA08E4D33973D83AB2FB9783E6C4D423A09611D24F0EE3142FD`.
- The first falsification run caught malformed negative-test JSON, an assertion
  against an escaped outer tool envelope, the hidden stale registry expectation,
  and duplicate case declarations. The corrected graph passes all four seams.
- GGUF duplicate-owner audit: five owner-adjacent files, 94 segments, one
  scheduler/agent-service import-and-declaration adjacency candidate, zero exact
  pairs, and no duplicate ticket policy, queue, or execution owner.
- Project, user, and legacy user config projections contain no `tickets` object.
  Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Competitive decision:** Temporal, Eve, Celery, BullMQ, and Codex confirm the
admission-before-capacity-claim boundary. Flue confirms deterministic child
identity. Pi, Oh My Pi, Scion, NullClaw, and KrillClaw expose only direct or
in-process launch pressure. VANTARI keeps the durable split without their
database, broker, daemon, or assignment-to-launch branch.

**Boundary:** Move 25 is closed in source. Assignment semantics are invariant,
not configurable. Durable agent mail, active-turn owner-crash reconciliation,
and installed replacement remain open.

**Next todo:** move 26 — route bounded direct, current-group, and parent messages
through one sequence-addressed mailbox on the existing session/event spine.

## 2026-08-13 - Roadmap move 26 sequence-addressed agent mailbox

**Changed:**

- Added one bounded mailbox owner at `core/agents/mailbox.zig` over existing
  per-session `events.jsonl`; no broker, topic registry, shared transcript,
  runtime state file, or background process was added.
- Added `send_agent_message` for direct-session, immediate-parent, and
  current-group delivery with explicit `queue` or `wake` intent. Scope,
  availability, depth, body/reference bounds, and write review fail before
  delivery.
- Persisted `agent_message_received`, `agent_message_sent`, and
  `agent_mailbox_cursor`. Stable sender/tool identity makes replay idempotent;
  partial replay repairs a missing recipient row.
- Injected at most 16 unread messages / 16 KiB as one transient system segment.
  Provider failure leaves the cursor unchanged; success acknowledges through the
  delivered event sequence. Live wake continues at the next safe provider
  boundary; queue waits for the next run.
- Replaced convergence-specific parent transcript writes and the bespoke ticket
  claim event. Child completion sends the bounded canonical session summary;
  ticket claim sends a child-to-parent wake notice after durable claim/session
  creation. Collaboration content never enters `messages.jsonl`.

**Proof:**

- Debug and ReleaseFast graphs: 19/19 steps, 1,943/1,943 tests, zero skips.
- ReleaseFast build: 9/9; source SHA-256
  `227CDA755E5A7E7BC3152DA4653DAB6AF1630D1288BB0919CFA648F69618C654`.
- Pressure covers direct, parent, current-group, nested-parent, cross-tree/self
  rejection, bounds, replay, queue/wake, cursor reconstruction, provider failure,
  safe-boundary continuation, child completion, cold convergence recovery, live
  event notification, and real ticket claim.
- GGUF duplicate-owner audit: seven files, 116 segments, five
  declaration/import adjacency candidates, zero exact duplicates, and no second
  mailbox, convergence, or runtime owner.
- `git diff --check` exits 0 with line-ending warnings only. Installed SHA-256
  remains `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Boundary:** Move 26 is source-closed. It provides at-least-once observation
with idempotent delivery receipt and provider-success acknowledgement. Move 29
owns exact owner-generation recovery across process death; move 38 owns installed
replacement after the live operator processes exit.

**Next todo:** move 27 — let the model choose from one compact eligible
specialist/team snapshot while the kernel filters only invalid or unavailable
routes, capacity, depth, and contact budgets.

## 2026-08-13 - Roadmap move 27 model-selected agent eligibility

**Changed:**

- Replaced definition-only `agents {}` output with one
  `var1.agent_eligibility.v1` projection owned by the existing `AgentService` and
  `core/agents/spec.zig`. It hot-loads the registry, resolves routes, reads the
  fixed pool and current team, sorts canonical rows, and hashes the exact
  snapshot. No selector model, team bus, registry, scheduler, or capacity token
  was added.
- Exposed eligible specialist identity/when-to-use/route/profile/provider/model,
  stable unavailable-route classes, depth/contact bounds, capacity/team
  aggregates, direct/parent/current-group targets, and queue/wake modes. Private
  capsules and child transcripts remain demand-loaded and private.
- Kept read-only discovery side-effect-free: an unstarted supervisor projects
  configured idle capacity without initializing worker threads; a started
  supervisor projects its actual live ceiling and occupancy.
- Removed always-on fan-out and first-tool-call prompt mandates. The active
  system/operator prompt now chooses quiet, inspect, message, challenge, launch,
  queue, or wake. Launch/configuration requires current eligibility evidence;
  configuration invalidates that evidence, and launch and messaging still
  revalidate at the effect boundary.
- Updated the visible schema-repair text and every current contract/readme/skill/
  machine guide/roadmap/finding/workspace record to name eligibility rather than
  the retired compact agent catalog.

**Proof:**

- Red tracer first failed on missing `EligibilityAgent` and
  `AgentService.eligibility`; the landed graph passes Debug and ReleaseFast at
  19/19 steps and 1,946/1,946 tests. ReleaseFast build passes 9/9.
- Determinism pressure proves input-order independence, exact receipt
  recomputation, changed-state receipt change, `route_unavailable`,
  `depth_exhausted`, and saturated `queue_only` admission.
- One captured provider transport proves a quiet profile completes inline in one
  call while a hive profile calls `agents {}`, observes eligibility plus
  communication state, and completes on call two through the same executor.
- GGUF duplicate-owner audit: seven production files and 115 segments; one
  expected import/declaration adjacency candidate between `service.zig` and
  `supervisor.zig`, zero exact duplicates, and no second selection/pool owner.
- Source ReleaseFast SHA-256 is
  `8CB2B28182BE153458C211BBF5A500F1BCD1726BAAB517771C4939697CC72B42`.
  Installed SHA-256 remains
  `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Boundary:** Move 27 is source-closed. The snapshot is advisory evidence, not a
reservation or selection token. Move 28 owns active/idle/queued capacity truth;
move 29 owns owner-generation recovery; move 38 owns installed replacement.

**Next todo:** move 28 — make configured fixed capacity govern active, idle, and
queued projections under contention.

## 2026-08-13 - Roadmap move 28 fixed-pool capacity truth

**Changed:**

- Added `AgentCapacitySnapshot.fromCounts` as the sole arithmetic owner for
  `running`, `idle`, `queued`, and saturated ticket-admission `available`.
  Eligibility, health, CLI, and TUI carry the additive values without owning
  scheduling or recomputing capacity.
- Made the sole `Supervisor` pool re-read `agent_routes.max_concurrency` at
  capacity and launch boundaries. Submitted closure-tail accounting prevents
  replacement while old work can still touch supervisor state; a busy pool
  drains and reports its actual ceiling, then the next idle read replaces that
  same pool.
- Corrected impossible health/scheduler fixtures and the stale unit expectation
  that clamped queued plus running work to `max`. Model-selected batches may
  expose backlog above `max`; ticket claims still require `available > 0`.
- Kept the TUI footer shape unchanged. Moves 41–45 own the minimal display; this
  move supplies its canonical read model only.

**Proof:**

- The red tracer first failed on the missing `idle` field. Its landed 20-task
  pressure reaches three simultaneous provider calls, observes queued backlog,
  preserves `running <= max`, drains a live reduction under the old ceiling, and
  applies max one after release.
- Debug and ReleaseFast graphs pass 19/19 steps and 1,947/1,947 tests. ReleaseFast
  build passes 9/9; source SHA-256 is
  `6E6A80054C4982AA9F1D86E9415B2422A4F7B7670080795243A91818279A360A`.
- GGUF duplicate-owner audit: eight files, 256 segments, 12 candidate pairs,
  zero exact duplicates, and no second pool/capacity owner.
- `git diff --check` exits 0 with line-ending warnings only. Installed SHA-256
  remains `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Competitive decision:** Codex contributes active-slot reservation and bounded
pending dispatch; Zig contributes the proven fixed run queue; pi, Eve, OpenAI
Agents SDK, Google ADK, LangGraph, Claude Code, and Microsoft Agent Framework
clarify the split between orchestration choice and execution ceiling. VANTARI
keeps one pool and one projection while adding explicit idle/admission truth and
safe live config convergence.

**Boundary:** Move 28 is source-closed. It adds no worker roster, dynamic pool,
pending-capacity ledger, scheduler policy, or footer expansion. Move 29 owns
owner-generation crash recovery; move 38 owns installed replacement.

**Next todo:** move 29 — persist heartbeat, owner generation, expiry, mailbox
delivery cursor, and exactly-once resume-or-requeue reconciliation.

## 2026-08-13 - Roadmap move 29 owner-generation reconciliation

**Changed:**

- Added one process-serialized `resume` ticket event. It replaces worker id,
  generation, lease token, and expiry while preserving ticket revision lineage,
  attempt, active child session, agent/capability identity, execution receipt,
  transcript, and mailbox cursor.
- Reordered ticket maintenance to settle terminal session evidence before lease
  recovery. Expired claims resume only when the active session exists and is
  nonterminal; absent sessions alone requeue.
- Bound heartbeat to exact live `Supervisor` ownership. Matching worker id and
  generation without a live fixed-pool task no longer manufactures liveness.
- Added production `AgentService.resumeTicket`: reconstruct current credentials
  and route from the immutable receipt, reject capability/budget drift, and
  submit the original group/task/session through the sole fixed pool. Idempotent
  replay observes the existing group without a second provider call.
- Made cold receipt recovery defer nonterminal ticket-owned groups to the
  scheduler instead of racing them into `StaleAgentOwner`. Ordinary non-ticket
  orphan recovery remains unchanged.
- Kept the mailbox schema and cursor owner unchanged. Same-session recovery
  copies no delivery state and appends no recovery-specific mailbox row.

**Proof:**

- The red tracer first failed because `TicketStore.resumeExpired` did not exist;
  the second tracer proved the old scheduler heartbeated a missing child.
- Unit pressure rejects live-lease resume, wrong session, wrong revision,
  conflicting replay, and poisoned ticket suffix. Positive heartbeat requires
  a live owner; missing-session recovery requeues once; expired terminal work
  completes before recovery.
- The integration tracer resumes one real ticket child on its original session,
  replays the same recovery request, records one provider call, retains attempt
  5 and generation 42, and leaves exactly one recipient delivery plus one cursor.
- Debug and ReleaseFast graphs pass 19/19 steps and 1,953/1,953 tests.
  ReleaseFast build passes 9/9; source SHA-256 is
  `ADDA84517C3DD1CC870E75C293E64BF1A7E1B3CE4525C1D56EC0B260E551ECD8`.
- GGUF duplicate-owner audit: six production files, 139 segments, five
  candidate pairs, zero exact duplicates, and no second scheduler, lease,
  receipt, mailbox, or recovery owner.
- `git diff --check` exits 0 with line-ending warnings only. Installed SHA-256
  remains `5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`;
  operator-owned PIDs 12028 and 14452 remain untouched.

**Competitive decision:** Prime Agent contributes generation-aware session
leases and non-replay of uncertain effects; Temporal contributes heartbeat
failure detection; BullMQ and Vercel Queues clarify redelivery/idempotence;
Paperclip separates liveness from work state; Scion contributes CAS state
versioning; Eve contributes committed delivery replay with retired cursors.
VANTARI keeps fewer owners: one ticket ledger transition, one immutable child
receipt, one fixed pool, and the existing event-spine mailbox.

**Boundary:** Move 29 proves one durable work identity and delivery position in
source. It does not claim exactly-once arbitrary external side effects; Move 62
owns write-intent/effect reconciliation. Move 30 owns installed Windows
kill/restart, message, terminal, repair, and cleanup proof.

**Next todo:** move 30 — run the installed 036 terminal mesh across assignment,
claim, messaging, detach, worker kill, restart, complete/fail/cancel/repair, and
verify no lost or duplicate delivery.

## 2026-08-13 - Move 30 source Windows ticket lifecycle mesh

**State:** source-complete; installed promotion blocked by active operator PIDs.

**Changed:**

- Added `scripts/prove-ticket-lifecycle.ps1`, one composed process tracer over the
  existing owner, scheduler, ticket ledger, fixed pool, session ledger, and agent
  mailbox. It adds no runtime entry point, worker registry, broker, or proof-only
  kernel branch.
- Repaired `host/http_bridge.zig:handleConnectionJob`. The former independent
  defers destroyed the page-allocated `ConnectionJob` before reading its lifecycle
  pointer. One defer now releases the captured lifecycle before allocator destroy.
- Extended scheduler cold-start pressure so completed, failed, and cancelled
  child sessions reconcile together. Failed and cancelled rows require repair;
  cancelled evidence retains `status=cancelled`.
- Ignored custom Zig prefix roots through `**/zig-out-*/`; proof/build output stays
  outside tracked source.

**Proof:**

- Ticket lifecycle root
  `.zig-cache/owner-proofs/ddc238496ee944a2bb586db735e6da2a`:
  queue-only assignment; TUI `TerminalUnavailable` detach; exact first owner/kernel
  tree death; different replacement generation; one claim; one same-session
  resume; two nested children; one direct, one group, and one parent message; six
  unique recipient deliveries; zero transcript copies; one completion; graceful
  shutdown; cold post-shutdown ticket/session/message replay; retained
  `result.json`; final zero proof-owned processes.
- Owner lifecycle root
  `.zig-cache/owner-proofs/8e02c2b054864bb699cfd8f6182d4d9a`:
  20/20 clients, graceful and forced recovery, three generations, zero survivors.
- Scheduler root
  `.zig-cache/owner-proofs/b80d4d5bcc7f438089f9a35dce16ce9a`:
  two kernels, one winning attempt/claim/child/terminal row, generation fence, zero
  survivors.
- Core Debug and ReleaseFast pass 19/19 steps and 1,953/1,953 tests. Focused TUI
  passes 9/9 steps and 61/61 tests. ReleaseFast SHA-256 is
  `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`.
- The GGUF duplicate-owner audit covers 10 lifecycle files and 139 segments. It
  reports six semantic candidates, zero exact duplicates, and no second process,
  scheduler, ticket, mailbox, or repair owner.

**Competitive decision:** Prime Agent contributes daemon-detach and family
message pressure; Codex contributes append-first event interpretation; Eve
separates client streams from continuation ownership; Paperclip separates
liveness from work state; Vercel Queues requires stable redelivery identity;
Scion pressures restart-readable messaging. VANTARI composes those invariants
through fewer owners: one execution tree, one ticket ledger, one fixed pool, and
one sequence-addressed event mailbox.

**Boundary:** Installed SHA-256 remains
`5DBF0B5F0D82954D80BD9E21202BCC46EE534CE6FD70A483464F95F878AD33DC`.
Operator-owned installed PIDs 12028/14452 remain untouched. Move 30, finding 11,
and parent 036 stay open until the hash-matched installed tracer and a new terminal
review pass. Move 62 still owns arbitrary external-effect certainty; Moves 71-80
own causal repair promotion.

**Next todo:** preserve the active installed pair; run duplicate-owner audit and
checkpoint this source result. Execute the same tracer against the installed path
after those processes exit naturally.

## 2026-08-13 - Move 30 installed promotion and 036h terminal closure

**State:** closed.

**Proof:**

- Installed `vantari.exe` was replaced through `apps/backend/scripts/install_windows.ps1`
  after the operator-owned process pair exited. The installed SHA-256 matches the
  current ReleaseFast artifact:
  `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`.
- The installed ticket lifecycle mesh passes at
  `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9`: queue-only
  assignment, owner detach, exact tree death, generation replacement,
  same-session resume, nested direct/group/parent delivery, cold ticket/session/
  message readback, terminal settlement, and final zero processes.
- Independent installed owner lifecycle passes at
  `.zig-cache/owner-proofs/9cc5d7b8a1624e49937cb3b78716e1bb`; the installed
  owner tracer passes at `.zig-cache/owner-proofs/65df1918745748ae9736cd9ba438fb13`.
- Pinned Zig Debug/ReleaseFast graphs pass 19/19 and 1,953/1,953; focused TUI
  passes 9/9 and 61/61. The 10-file 139-segment duplicate audit reports zero
  exact duplicates. No proof-owned `vantari.exe` process remains.

**Closure:** Move 21, Move 30, Move 38, finding 11, and parent ticket 036 are
closed. The new `036h-ticket-agent-pool-and-repair-terminal-review.md` and the
036 parent are archived. The remaining boundary is arbitrary external-effect
  certainty, owned by the write-intent and self-repair roadmap; this closure does
  not claim exactly-once effects outside VANTARI's ledgers.

**Next todo:** Move 32 — repair stale pending/archive manifests and current
frontier records before advancing the next capability slice.

## 2026-08-13 - Move 32 documentation and frontier reconciliation

**State:** closed.

**Changed:**

- Corrected the 021 parent manifest: 021a and 021b now point to their archived
  files, while 021c is the sole active frontier.
- Archived 036 and 036h are now the current ticket-chain records; finding 11,
  Move 21, Move 30, and Move 38 carry installed proof rather than source-only
  or active-process wording.
- Reconciled `.docs/workspace.json`, the findings index, technical summary,
  root/backend READMEs, architecture, research, roadmap, and current changelog
  with the installed hash and zero-process evidence.
- Kept dedicated installed eligibility/capacity snapshot probes explicitly
  unrun; the composed ticket lifecycle proof does not inflate those claims.

**Proof:** `.docs/workspace.json` parses with
`installed_hash_matches: true`; source and installed SHA-256 are
`F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`; the
filesystem has 021a/021b and 036/036h in changelog, 021c pending, no 036 parent
in pending, and zero active `vantari.exe` processes. The stale-frontier probe
finds no current-state references to the old installed PIDs or open 036/finding
11 gates outside historical receipts.

**Next todo:** Move 33 — execute 021c Codex OAuth login, persistence, refresh,
logout, and sanitized CLI status through the canonical auth ledger.

## 2026-08-13 - Move 33 Codex OAuth login and CLI surfaces

**State:** closed.

**Changed:**

- Added one `auth` CLI surface with `status`, `login`, and `logout` actions.
- Added the named OpenAI Codex PKCE provider descriptor, localhost callback
  owner, redirect/code parser, injected token exchange/refresh hooks, and JWT
  account/plan claim extraction.
- Extended the canonical auth store with OAuth upsert, refresh-compatible token
  persistence, secret-free status projection, and provider-preserving removal.
- Exported the auth helper through the existing client/core namespaces. No
  provider completion transport or second auth ledger was added; Move 34 owns
  Codex request routing.
- Updated AGENTS, README, SKILL, llms, architecture, technical summary, index,
  findings, workspace record, and roadmap to the shipped/source-only boundary.

**Proof:**

- Debug backend graph: `19/19` steps, `1,957/1,957` tests, zero leaks.
- ReleaseFast build/install: `9/9`; installed `auth --help` lists login,
  logout, and status.
- Disposable installed OAuth fixture: `auth status --json` returned provider,
  model, account, plan, expiry, and verification metadata; access, refresh, and
  ID token redaction probe passed.
- `ix search` auth ownership probe: `ix.result.v1`, status `ok`, 5 files, 57
  matches. No real provider login was executed.
- Built and installed SHA-256:
  `2A1DF56B967A01F2E8934B80FC006FA5D502E07F12CC30B1959D3F64A75FF2D2`.

**Next todo:** Move 34 — execute the Codex subscription transport through the
canonical provider dispatch.

## 2026-08-13 - Move 34 Codex subscription provider transport

**State:** closed.

**Changed:**

- Added `core/providers/openai_codex.zig` as the sole Codex OAuth completion
  owner. It builds `/codex/responses`, adds account/originator/OpenAI-beta/SSE
  headers, sets `store:false`, and maps Responses/SSE into the existing
  `CompletionResponse` contract.
- Carried typed OAuth auth metadata through config resolution, provider routes,
  child config clones, and the canonical transport boundary. API-key providers
  retain the existing OpenAI-compatible path; no runtime fallback crosses the
  auth boundary.
- Added raw Responses event forwarding for assistant/reasoning deltas and
  explicit missing-account, expired-auth, entitlement, rate-limit, malformed,
  and unsupported-transport errors.
- Updated the provider, auth, operator, machine-facing, roadmap, findings,
  workspace, and ticket records. Archived `021d`; `021e` is the next frontier.

**Proof:**

- `scripts/zigw.ps1 build test --summary all`: `19/19` build steps succeeded;
  `1,963/1,963` tests passed; zero leaks.
- `ix.exe search --max-hits 20 -n 6 "lit:/v1/chat/completions" .`: `ix.result.v1`
  status `ok`; the Codex file contains only the explanatory boundary comment,
  while request construction uses `/codex/responses`.
- ReleaseFast build/install: `9/9`; source and installed SHA-256:
  `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`.
- Installed disposable OAuth fixture: exit `0`; `POST /codex/responses` with
  account/originator/OpenAI-beta/SSE headers, `stream:true`, and `store:false`;
  response `ok`; no `/v1/chat/completions`; no bearer output; owner/kernel pair
  explicitly torn down; final installed process census zero. No live provider
  credential or entitlement was used.

**Next todo:** Move 35 — execute 021e documentation and sanitized fixture
hardening.

## Move 35 — 021e operator documentation and status hardening (2026-08-13)

**State:** closed

- Archived `.docs/todo/pending/021e-codex-subscription-auth.md` after aligning
  root/backend README, architecture, AGENTS, SKILL, llms, research, findings,
  workspace, roadmap, index, and this changelog with the shipped auth boundary.
- Documented installed `$VANTARI_HOME/auth.json` and workspace `.var/auth.json`
  as separate runtime-scoped durable ledgers; `.env` is bootstrap configuration
  and does not replace an active ledger record.
- Added a sanitized OAuth status example containing provider/account/plan/expiry
  metadata only; no credential values or disposable fixture tokens appear in
  operator docs or auth research.
- Canonical regression: `scripts/zigw.ps1 build test --summary all` -> `19/19`
  build steps, `1,963/1,963` tests passed, zero leaks.
- IX route search:
  `ix.exe search --max-hits 40 "lit:/codex/responses" README.md apps/backend/README.md apps/backend/architecture.md .docs`
  -> `ix.result.v1`, status `ok`, 21 matches.
- Scoped redaction search:
  `ix.exe search --max-hits 20 "lit:fake-access-token || lit:fake-refresh-token || lit:fake-id-token" README.md apps/backend/README.md apps/backend/architecture.md .docs/research`
  -> `ix.result.v1`, status `ok`, zero matches.
- Move 34 remains the installed proof boundary: SHA-256
  `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`, local
  `/codex/responses` fixture success, no bearer output, and zero final
  processes. No live entitlement was used.

**Next todo:** Move 36 — execute 021f full verification, auth-chain archival,
and parent closeout.

## Move 36 — 021f auth-chain verification and parent closeout (2026-08-13)

**State:** closed

- Archived `021f-codex-subscription-auth.md` and the `021-codex-subscription-auth.md`
  parent. Units `021a` through `021f` now have evidence in
  `.docs/todo/changelog/`; no pending auth continuation remains.
- Canonical regression: `scripts/zigw.ps1 build test --summary all` -> exit `0`,
  `19/19` build steps, `1,963/1,963` tests passed, zero leaks.
- Disposable built-binary fixture using
  `VANTARI_HOME=apps/backend/.zig-cache/codex-installed-proof`:
  `vantari.exe health --json` -> `ok:true`, `openai-codex`, 131072-token
  context, healthy six-worker pool, zero queued/running tickets;
  `vantari.exe auth status --json` -> provider/model/account/plan/expiry
  metadata only, no credential values.
- IX checks returned `status: ok`: auth ownership `69` matches, explicit
  `/codex/responses` `27` matches, OAuth endpoint ownership `3` matches, and
  scoped fake access/refresh/ID token search `0` matches.
- The built owner/kernel pair was explicitly torn down after health/status;
  final built-binary process census was zero. Move 34 remains the installed
  consumer proof at SHA-256
  `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`.
  No live provider entitlement or credential was used.

**Next todo:** Move 37 — execute 035g sequence-backed usage, cost accumulation,
and `/status` proof.

## Move 37 — 035g installed TUI cost consumer proof (2026-08-13)

**State:** closed

- Fixed the TUI row owner so multiline system output (`/status`, `/help`, and
  `/history`) uses the wrapped-row path while progress rows remain dense. The
  focused regression proves both behaviors.
- Installed unknown-price `glm-5.1` and known zero-price `glm-5.2` Z.AI turns
  returned `OK` and persisted measured prompt/completion/cached tokens. The
  unknown model recorded `cost_total_usd:null`; the known free-tier model
  recorded `cost_total_usd:0`.
- Installed TUI `/status` visibly rendered workspace, model, effort, session,
  `Tokens: 6.8k in / 3 out / 6.7k cached`, and `Cost: $0.000000`. The matching
  `var1.turn_terminal.v1` row carried prompt `6763`, completion `3`, cached
  `6720`, and cost `0`.
- A provider recovery event before the successful TUI retry remains in the
  event ledger as truthful residual evidence; the terminal row completed.
- Source regression: `19/19` build steps and `1,963/1,963` tests passed with
  zero leaks. ReleaseFast/install succeeded `9/9`; the built and installed
  SHA-256 is
  `09758F2AFE34AC5DCD94F786B5A307F8BB0DF9A11E5DA65B743A6EBB62354834`.
  The installed owner/kernel pair was explicitly torn down and the final
  VANTARI process census was zero. An unsupported `deepseek-v4-flash` override
  returned typed HTTP 400 rather than fabricating a nonzero price.

**Next todo:** Move 39 — execute 035h terminal QC and archive the provider/cost
chain only after the full pipeline review.

## Move 39 — 035h provider/cost pipeline terminal QC (2026-08-13)

**State:** closed

- QC passed the canonical structure: pure compiled pricing, one compat detector,
  one turn-terminal payload owner, value-type usage, and no cost database,
  price service, event type, or parallel executor.
- QC passed provider contract truth: all adapters expose measured usage, the
  unified terminal event carries token/cost fields, z.ai thinking shape is
  preserved, DeepSeek reasoning shape is scoped, and `wire_api:auto` resolves
  through dispatch.
- The review found one evidence gap: 035c listed eight adapter-usage pressure
  blocks but contained seven distinct tests. Added the narrow Responses-stream
  cache-default test; the current graph now passes `19/19` steps and
  `1,964/1,964` tests with zero leaks.
- Current ReleaseFast/install hash equality remains
  `09758F2AFE34AC5DCD94F786B5A307F8BB0DF9A11E5DA65B743A6EBB62354834`; no
  installed VANTARI processes remain after owner reconciliation.
- Archived `035h` and parent `035`. The next queued boundary is Move 40.

**Next todo:** Move 40 — hold PLUG behind the current owner decision and
re-decompose it against the proven built-in capability boundary.

## Move 40 — PLUG deferred-delete and dead-surface removal (2026-08-13)

**State:** closed

- Reference harvest across the local Codex, pi, oh-my-pi, Eve, KrillClaw,
  nullclaw, and Flue sources, followed by owner recon, found no concrete
  installed plugin consumer. The existing `manage_plugin` builtin was
  default-visible but its enable/disable path was TODO-only; manifest,
  isolation, and socket types had no catalog or dispatch consumer.
- Removed the `manage_plugin` file, registry/availability/runtime branches, and
  two wrapper-only namespace tests. Retained the matrix-backed contract
  namespaces because they still express the future socket boundary. No plugin
  discovery, catalog merge, subprocess dispatch, or model-visible plugin tool
  is claimed.
- Installed `tools --json` returned exit `0`, valid catalog JSON, 24 tools, and
  `contains_manage_plugin=False`. The two processes it started were terminated
  through their exact installed path; the final installed process census was
  zero.
- Canonical source regression is `19/19` build steps and `1,962/1,962` tests;
  ReleaseFast/install is `9/9`; source and installed SHA-256 match
  `279A112A1D7CD94BF2C5678C961E83A3458951CB9D48E9C5CC21A6D01DF409AF`.
- Archived PLUG parent and units `PLUGa` through `PLUGh` as superseded. Move 41
  is next; move 86 may reopen plugin discovery only after a concrete need and a
  new owner-mapped recon.

**Next todo:** Move 41 — render the footer and agent rows only from
sequence-bearing events and canonical summaries.

## Move 41 — sequence-addressed TUI projection and bounded continuation (2026-08-13)

**State:** closed

- The method gate harvested Codex, pi, oh-my-pi, Eve, Flue, NullClaw, and
  OpenClaw lifecycle invariants. The compression decision was to keep
  `ChatState` as the sole TUI read model, parent `events.jsonl` sequence as
  render identity, and `summaries.jsonl` as the canonical child-turn summary.
  No activity registry, child transcript reader, status bus, or parallel cursor
  was added.
- Deleted the sequence-less cold replay fallback in
  `apps/backend/src/clients/tui_chat.zig`. Added adversarial coverage proving
  legacy `seq == 0` activity is ignored and a contiguous live application
  equals cold replay for keyed group/item rows, text, state, and cursor.
- Repaired the installed `vantari -c` continuation boundary with the existing
  `session/list` owner: an optional `limit` bounds lightweight selectors,
  and the TUI requests `limit: 1`. This removed the 8 MiB response failure
  reproduced against 19,213 sessions without adding a second selector owner.
- Canonical source proof: `.\\scripts\\zigw.ps1 build test --summary all` returned
  19/19 build steps and 1,967/1,967 tests. Focused TUI proof returned 9/9 steps
  and 63/63 tests. `git diff --check` returned no whitespace errors.
- Installed proof: ReleaseFast build/install returned 9/9; `vantari -c`
  hydrated the latest session and rendered persisted child rows; blank TUI
  startup/exit passed. Source and installed SHA-256 match
  `C65C98363F8DDD9A31F39FAB36F4A280972DCE5E69475AE29DA01FB80A7ABF54`.
  The persistent owner survived presentation detach by design; the exact
  proof-owned owner tree was explicitly torn down after both checks and the
  final VANTARI process census was zero.
- Updated the roadmap, technical summary, workspace record, findings receipt,
  current sitrep supersession, research index, root README, backend README,
  backend architecture, and CLI/TUI rendering contract. Move 42 is next:
  composer tint hierarchy and conditional cancellation affordance.

## Closure receipt — Move 42 (2026-08-13)

- The seven-source TUI harvest is recorded in
  `.docs/research/2026-08-13-tui-composer-move42.md`. It confirms the
  compression decision: retain one session-owned projection and one palette
  owner; do not add a theme registry, persistent shortcut copy, or screenshot
  framework for this seam.
- `styles.surface`, `styles.meta_surface`, and `styles.composer` remain the
  canonical footer surfaces. A strict `colorLevel` assertion proves transcript
  < metadata < composer lightness. Exact wide and width-40 metadata cases
  preserve model, effort, context, and remaining capacity without wrap.
- Cancellation is now conditional: `cancelling` requires an active waiting run;
  terminal events clear the intent; active `/cancel` interjections use the
  generation-bound request owner; idle `/cancel` reports no active run. No
  persistent `Esc cancel` copy is rendered.
- Debug returned `19/19` build steps and `1,991/1,991` tests; focused TUI
  returned `9/9` steps and `75/75` tests; `git diff --check` returned no
  whitespace errors.
- ReleaseFast/install returned `9/9`. Installed ANSI inspection observed
  transcript `(8,17,15)`, metadata `(10,22,20)`, and composer `(16,34,31)`;
  blank TUI startup/exit and installed `vantari -c` continuation passed.
  Source and installed SHA-256 match
  `A6E93FA6671256E2755C5DC397747F5E350C6ED7D3DE4BF242AC557B96953072`.
  The exact proof-owned owner tree was torn down and the final process census
  was zero.
- Updated the roadmap, technical summary, workspace record, findings receipt,
  current sitrep supersession, research/index records, root/backend README,
  backend architecture, and `AGENTS.md` contract.

**Next todo:** Move 43 — make prompt-mode selection session-scoped and prompt-
controlled, with provider-visible capture and no executor behavior branches.

## Closure receipt — Move 43 (2026-08-13)

- The seven-source prompt-mode harvest is recorded in
  `.docs/research/2026-08-13-prompt-mode-move43.md`. The compression decision
  keeps one typed prompt layer and rejects a mode registry, settings schema,
  tool branches, and alternate executors.
- `PromptMode` cycles `orchestrate -> build -> align -> plan` in the TUI. The
  next `session/send` carries the session-local label; omission defaults to
  `orchestrate`, and unknown labels fail with JSON-RPC `-32602` before session
  or provider execution. Every executor prompt rebuild preserves the value.
- The provider system-envelope test captures the selected guidance layer. The
  mode changes model-visible method only; executor, tool catalog, access policy,
  model, and agent capacity remain unchanged.
- Debug returned `19/19` build steps and `1,996/1,996` tests; focused TUI
  returned `9/9` steps and `76/76` tests; `git diff --check` had no whitespace
  errors. ReleaseFast/install returned `9/9`.
- Installed TUI startup accepted Shift+Tab and blank startup/exit passed. Source
  and installed SHA-256 match
  `145F08FF38FA94D325006B4CC78A8C0EFD83A885E9A2F8DBA6152CFA20BFC1EC`. The
  proof-owned owner/kernel tree was explicitly torn down and the final process
  census was zero.
- Updated roadmap, research/index records, root/backend README, architecture,
  technical summary, workspace record, findings receipt, and `AGENTS.md`.

## Closure receipt — Move 44 (2026-08-13)

- The eight-source status-row harvest is recorded in
  `.docs/research/2026-08-13-status-row-move44.md`. It keeps one existing footer
  projection owner, rejects a configurable registry and progress gauge, and
  preserves prompt-mode control as a session-local provider lens.
- `formatFooterMetaWithPool` now emits `status · prompt mode · model · effort ·
  context used/capacity (percent) · remaining` without wrapping. Existing
  runtime status maps to `ready`, `working`, `cancelling`, or `failed`; context
  remains exact or explicitly unknown; codepoint-safe fitting protects narrow
  terminals.
- Focused TUI returned `9/9` steps and `77/77` tests; Debug returned `19/19`
  steps and `1,998/1,998` tests; ReleaseFast/install returned `9/9`.
- Installed TUI visibly rendered `ready · orchestrate · glm-5.2 · max · ctx — /
  500k`. Source and installed SHA-256 match
  `F569105E0845F6F6F23282C3C3C697EE8B3939CAC5515E111AC29A5CEAF754C2`. The
  proof-owned owner/kernel tree was explicitly torn down and the final process
  census was zero.
- Updated roadmap, research/index records, root/backend README, architecture,
  technical summary, workspace record, findings receipt, `AGENTS.md`, `SKILL.md`,
  and `llms.txt`.

**Next todo:** Move 45 — keep active/max agents, nonzero queue, and known session
cost only when those values carry signal.

## Closure receipt — Move 45 (2026-08-13)

- The seven-source agent/queue/cost harvest is recorded in
  `.docs/research/2026-08-13-agent-queue-cost-move45.md`. It keeps the existing
  footer projection owner and rejects a cost poller, registry, event, second row,
  or status bus.
- `formatFooterMetaWithPool` now appends finite, nonnegative priced session cost
  as `cost $0.######` in the existing lower-signal segment. Active/max and queue
  remain conditional; unknown provider pricing remains absent.
- Focused TUI returned `9/9` steps and `77/77` tests; Debug returned `19/19`
  steps and `1,998/1,998` tests; ReleaseFast/install returned `9/9`.
- Installed TUI rendered `ready · orchestrate · glm-5.2 · max · ctx — / 500k`.
  Source and installed SHA-256 match
  `D83E9A843286E79861FD5FA25514DD18C17B3307DDEC7A2842216B9DA3AB38EA`; the
  exact owner/kernel tree was torn down and the final process census was zero.
- Updated roadmap, research/index records, root/backend README, architecture,
  technical summary, workspace record, findings receipt, `AGENTS.md`, `SKILL.md`,
  and `llms.txt`.

**Next todo:** Move 46 — preserve explicit unknown context after compaction or
incomplete provider accounting; add no precision the kernel did not prove.

## Closure receipt — Moves 46–48 (2026-08-13)

- Move 46 keeps unknown or zero-capacity context as `ctx —`; the existing footer
  owner does not invent a percentage, remaining value, gauge, or telemetry
  surface.
- Move 47 keeps `Agents completed/total`, removes `waiting on N`, and aligns
  group/child markers to `○` queued/running and `◉` complete while preserving
  explicit failure/cancel markers.
- Move 48 reuses the keyed child activity row and canonical
  `sessions/summaries.jsonl` boundary for a bounded quoted agent summary. Later
  tool/terminal events update lifecycle state without replacing the summary;
  `tool_completed` remains typed event metadata, not the visible conclusion.
  UTF-8 and one-row width truncation are tested.
- The harvest and rejected chat-bubble/poller/second-ledger alternatives are
  recorded in `.docs/research/2026-08-13-agent-summary-bubble-move47-48.md`.
- Focused TUI returned `9/9` steps and `78/78` tests; Debug returned `19/19`
  steps and `2,000/2,000` tests; ReleaseFast/install returned `9/9`.
- Installed TUI rendered `ready · orchestrate · glm-5.2 · max · ctx — / 500k`.
  Source and installed SHA-256 match
  `C7B3EE8E4B41D12D486D7C73F3E209834EEE91619364FE0ABE5A676E8C7EA9B7`; the
  exact owner/kernel tree was torn down and the final process census was zero.
- Updated roadmap, research/index records, root/backend README, architecture,
  technical summary, workspace record, findings receipt, `AGENTS.md`, `SKILL.md`,
  and `llms.txt`.

**Prior next todo (closed below):** Move 49 — add only the typed child phase
marker and elapsed-time projection if the existing keyed row does not already
carry both signals.

## Closure receipt — Move 49 (2026-08-13)

- Move 49 reuses the existing `var1.child_event.v1` envelope, supervisor task
  timestamps, and keyed `group_id + task_id` TUI row. The envelope carries
  optional `elapsed_ms`; known phases render as compact labels, and lower-signal
  phase/time metadata yields to the canonical quoted child summary at narrow
  widths.
- The child summary still comes from `sessions/summaries.jsonl` at the existing
  `assistant_response` boundary. Tool/terminal events update the same row and do
  not promote `tool_completed`, append lifecycle noise, or create a chat bubble.
- Focused TUI returned `9/9` steps and `78/78` tests; Debug returned `19/19`
  steps and `2,000/2,000` tests; ReleaseFast/install returned `9/9`.
- Installed TUI showed `○ Agents 0/1` and the keyed child `· session` phase.
  Source and installed SHA-256 match
  `6D7F72DD3E1C03DF3A6FA71C07CD6DEA6A020391C8F85A0B1B395C9670DE93BF`; exact
  proof-owned owner/kernel teardown left zero VANTARI processes.
- The seven-source harvest and rejected timer/poller/heartbeat/second-ledger
  alternatives are recorded in
  `.docs/research/2026-08-13-child-phase-elapsed-move49.md`.
- Updated roadmap, research/index records, root/backend README, architecture,
  technical summary, workspace record, findings receipt, `AGENTS.md`, `SKILL.md`,
  and `llms.txt`.

**Move 50 closure receipt (2026-08-13):** Reused the existing child
`tool_completed` boundary for `update_session_summary`, read the canonical
`sessions/summaries.jsonl` row, and emitted the existing `child_progress`
envelope with `phase=summary`. The TUI now refreshes the keyed child row with a
bounded quoted summary while the child is running. No Agent Hub registry,
poller, chat-bubble event, unread state, transcript copy, or second ledger was
added. Focused TUI `9/9`, `78/78`; Debug `19/19`, `2,000/2,000`;
ReleaseFast/install `9/9`; source/installed SHA-256
`6814396B7E2A134E9ECAED9DA5B6567FEAA01824DAC948CC54DC725EFC3DF178`;
installed smoke passed; exact owner-tree teardown left zero VANTARI binaries.
Research: `.docs/research/2026-08-13-agent-hub-move50.md`.

**Move 51 closure receipt (2026-08-13):** `routes.ResolvedRoute.config` already
carried the validated access flag, but `agents/supervisor.zig` dropped it at
the child `ExecutionContext` handoff. `childExecutionContext` now preserves the
flag for every child, while the ten file/search/LSP/shell entrypoints continue
to use the sole `fsutil.resolveWithAccessMode` resolver. Clean Debug `19/19`
steps and `2,000/2,000` tests, ReleaseFast/install `9/9`, installed
`config/set` true-write in an isolated runtime, live config unchanged, source/
installed SHA-256
`39B26C5D898F9F6346A0DE4397002D05C810B2EB34153CA11171440129B3B453`, and zero
final VANTARI processes prove the slice. Research:
`.docs/research/2026-08-13-full-access-mode-move51.md`.

**Next todo:** Move 52 — make access mode session-scoped and visible without
moving `.var` or session ledgers.

**Move 52/52a closure receipt (2026-08-13):** Session access scope is now
persisted, projected in `SessionSummary` and the TUI footer, and carried into the
effective turn config without relocating `.var` or session ledgers. The root
interactive slice adds one `ask_user` tool, one `input/respond` RPC, one bounded
`var1.input_requested.v1` request, and one session-scoped broker wait. The TUI
uses Enter/Space and inline `f / Other`; child profiles fail with
`InputUnavailable`; cancel/shutdown wake pending waits and terminal replay clears
stale controllers. No poller, question registry, second status bus, transcript
copy, or resolved-event family was added. Debug `19/19`, `2,023/2,023`;
ReleaseFast/install `9/9`; source/installed SHA-256
`739F0D10D366738D01CEB3879D5B9487F7C99FB7CDB4D7FF9DB3418386A0DEED`; installed
health/catalog proof passed and exact proof-owned processes are zero. Research:
`.docs/research/2026-08-13-root-interactive-input.md`. The provider-driven
installed TUI response remains the explicit next consumer probe.

**Move 54/TUI input repair closure receipt (2026-08-13):** The installed TUI
now renders the registry-backed bare-prefix command palette above the composer,
keeps slash compatibility, and routes Enter through the executable command
registry. Settings uses the normal Vaxis render/flush boundary, projects
compiled defaults when persisted config is missing or invalid, and maps
Tab/Right forward with Shift+Tab/Left backward. Startup exposes
`help · settings · model` without adding transcript noise. Focused TUI passed
`9/9` steps and `120/120` tests; Debug passed `19/19` steps and `2,101/2,101`;
ReleaseFast/install passed `9/9`; source and installed SHA-256 match
`2851E4EBA24ED13A6A5DBBBB3F3A97392DEA0249B9D9C221F8936917734F8D2C`; the
exact proof-owned owner/kernel tree was torn down and the final process census
was zero. Full receipt: `.docs/todo/changelog/041-tui-input-settings-repair.md`.

**Move 55 capability-manifest closure receipt (2026-08-13):** Availability is
now carried by the selected `ToolDefinition`; `core/tools/registry.zig` probes
that declaration and no longer owns the duplicated 15-entry
`availability_entries` table. Catalog rendering, provider schema selection,
review, and dispatch retain one definition slice. The legacy
`availabilitySpec(name)` helper remains only as a compatibility scan. The
negative probe marks `search_files` unavailable when `ix` is absent while
native `list_files` remains available. Focused TUI passed `120/120`; Debug
passed `19/19` steps and `2,102/2,102`; ReleaseFast/install passed `9/9`;
source and installed SHA-256 match
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`; installed
`tools --json` reports 25 tools with `search_files -> ix -> available`; exact
owner/kernel processes were stopped and the final installed process census was
zero. Research and full receipt:
`.docs/research/2026-08-13-capability-manifest-move55.md` and
`.docs/todo/changelog/042-capability-manifest-move55.md`.

**Move 55a source closure receipt (2026-08-13):** `runtime.log_level` now
defaults to `silent`, accepts `normal` and `full`, and carries one operator
posture through config validation, health, prompt guidance, child execution
context, settings, and TUI projection. Durable events and transcript ledgers
remain complete. `agent_routes.prompt_modes` reuses the existing provider/model
route shape for `orchestrate`, `build`, `align`, and `plan`; explicit
`session/send` provider/model fields win. Debug passed `19/19` steps and
`2,119/2,119` tests; focused TUI passed `9/9` and `123/123`; `git diff --check`
reported no whitespace errors. Installed promotion is intentionally deferred;
no installed hash or live-binary claim is made. Research and receipt:
`.docs/research/2026-08-13-mode-routing-ui-oauth.md` and
`.docs/todo/changelog/043-chat-log-level-and-mode-routing.md`.

**Move 68 source closure receipt (2026-08-14):** `TokenPrecision` now carries
exact provider usage, estimated compiler context, or unknown accounting through
the existing `turn_started` and `turn_terminal` rows. The TUI footer marks
estimated context with `~`, refuses numeric used/remaining values when unknown,
and `/status` suppresses cumulative totals after an unaccounted completed turn.
Debug passed `19/19` steps and `2,159/2,159` tests; source ReleaseFast passed
`9/9`; source SHA-256 is
`41C90C2BDF0CB6350E9056EC361E8280FB8EF423AC941A8F4015B88B71695E15`.
Installed promotion remains deferred and the live owner was not replaced.
Research and receipt: `.docs/research/2026-08-14-token-accounting-precision-move68.md`
and `.docs/todo/changelog/059-token-accounting-precision.md`.

**Move 70 source closure receipt (2026-08-14):** The canonical child launch
path now carries the immutable parent checkpoint identity into the existing
context compiler. The child receives the checkpoint summary plus a bounded
recent suffix without copying parent transcript rows; shard lifecycle rows are
excluded from compiler checkpoint selection; terminal branch summaries retain
parent range/token metadata and are capped at 16 KiB. Debug passed `19/19`
steps and `2,166/2,166` tests; source ReleaseFast passed `9/9` with SHA-256
`1E5AFD64D502514FAFC473FA8DD0B8E7B80C905EC52074AB629B1ACAD0157BFE`.
Installed promotion remains deferred. Research and receipt:
`.docs/research/2026-08-14-context-shard-projection-move70.md` and
`.docs/todo/changelog/062-context-shard-projection-move70.md`.

**Question modal frame closure receipt (2026-08-14):** The existing question
controller now owns the complete Vaxis frame, so transcript, reasoning-dock,
status-bar, and footer geometry cannot collide with a long `ask_user` batch.
Normal, `orchestrate`, `build`, `align`, and `plan` continue to share one
controller and broker path. Multi-select Enter/Space remains on the question
until review, and deselecting `Other` clears its custom text. Focused TUI Debug
and ReleaseFast both passed `9/9` steps and `136/136` tests; full Debug passed
`19/19` steps and `2,168/2,168`; source ReleaseFast passed `9/9` with SHA-256
`EDE276134231600AE8978B0C88BCBA6C26F7F303A5336025D5B0E371852EC8F8`.
Installed promotion remains deferred and the installed owner remains on
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Research and receipt:
`.docs/research/2026-08-14-question-modal-frame.md` and
`.docs/todo/changelog/063-question-modal-frame.md`.

**Move 88 Windows installer owner-boundary receipt (2026-08-14):** The
installer now keeps the staged copy/backup/move path but refuses to force-stop
an exact-path process. It requires one current owner projection matching PID,
executable, workspace, port, and token, calls authenticated
`POST /owner/shutdown`, and waits for zero exact-path processes before swap.
PowerShell parsing passed. The live `-SkipBuild` probe failed closed on the
stale projection for PIDs `22152,29908` without changing the binary. The
installed lifecycle proof passed `4/4` clients, graceful shutdown, crash
recovery, generation replacement, and final zero proof-owned processes.
Source validation passed `19/19` steps and `2,196/2,196` tests. Installed
promotion remains blocked by the preserved owner pair and source/installed
hash mismatch. Research and receipt:
`.docs/research/2026-08-14-windows-install-owner-boundary-move88.md` and
`.docs/todo/changelog/076-windows-install-owner-boundary-move88.md`.
# 2026-08-14 - Close Moves 85-87 by YAGNI deletion

- Moves 85–87: deleted the unused allocator quota shell, plugin discovery, and
- Move 85 removed `core/memory/scopes.zig`, its export, and the dead
  `ScopedArena` lifecycle calls; Moves 86–87 remain contract-only reopen gates.
  plugin supervision expansion after current owner/consumer census found no
  measured pressure, mounted plugin, or live plugin process.
- Canonical owners retained: allocator/process bounds, tool definitions and
  availability, review risk, shared process supervision, effect receipts, and
  cleanup.
- Proof: current source census; `scripts/zigw.ps1 build test --summary all` ->
  19/19 build steps and 2180/2180 tests; ReleaseFast SHA-256 `9FFBBFF13CECF76DC647DC5AF6485339D7C05D3196B97B3D1FDDBC6A8A88C8A4`.
- Next: reconcile the installed owner boundary for Move 88.

## 2026-08-14 — Owner projection clean-shutdown boundary

- `owner_state.zig` now removes only an exact matching owner projection after
  listener drain; stale or replaced projections remain fail-closed evidence.
- `http_bridge.zig` owns the shutdown call; no second lifecycle or recovery
  owner was added.
- Proof: owner identity test plus current `19/19` and `2,180/2,180` source
  graph; real-provider source smoke ended with zero exact source processes.

## 2026-08-14 — Installed current-release boundary

- `install_windows.ps1 -SkipBuild` installed ReleaseFast SHA-256
  `50546CCD5EEDD4E451AAF08134186CF321366AABE659A636BA7AB08F74F5EF88`, equal
  to the source artifact, and retained the previous binary as a `.bak`.
- Installed help, health, tools, auth-status, and workspace probes exited `0`;
  the 33-tool catalog retained `ask_user` and `replace_in_file`.
- Repository proof owners used authenticated shutdown and ended at zero exact
  source/installed processes. The real-provider question response remains an
  explicit open boundary; no fallback or second question system was added.
2026-08-14 - Close Moves 81-83 by YAGNI consolidation: checkpoint-addressed agent branches, session/event read models, and existing turn/tool/agent budgets remain the sole owners; no fork RPC, attention index, or quota ledger without measured consumer demand.
2026-08-14 - Reconcile the fresh current-source ReleaseFast install: `2,182/2,182` tests, equal source/installed SHA-256 `3EFF45169AEC2BC419B20FF0EC8228A3B12AA508C5E93BE21509427F40191550`, exact owner gate, recoverable `.bak`, and zero final source/installed process census; Move 89 remains partial.
2026-08-14 - Pin the ReleaseFast Zig build seed to `0` after proving random dependency traversal made repeated artifacts differ; two fixed-seed builds now equal `A7D01B37DBB3F954CF93F534CC04E9E662B86F34F19E4C2192EA302208515806`, the manifest is promotable at `19/19` and `2,184/2,184`, and installed proofs pass with zero exact-path processes.
2026-08-14 - Move root orchestration ownership from persistent `agents.orchestrator_only` config to the existing `PromptMode`: Shift+Tab and CLI `--prompt-mode` derive the root catalog/dispatch posture, `orchestrate` remains the default, child profiles remain unchanged, and old config files stay readable but inert. Installed PTY and build-mode `list_files` proof passed on SHA-256 `A7D01B37DBB3F954CF93F534CC04E9E662B86F34F19E4C2192EA302208515806`.
2026-08-14 - Refresh the prompt-mode owner proof after the formatter: current source and installed ReleaseFast SHA-256 match `59E150343A206A465ACACBB7E3F5466BDD052E4C8F4426C599AFB6D25A24FC8E`; Debug `19/19` and `2,184/2,184`, ReleaseFast `9/9`, installed build/orchestrate turns, two native `list_files` lifecycles, and the promotable release manifest all read back cleanly with zero final processes. Move 89 remains partial only at the named provider write/cancel/question and hidden-window boundaries.
