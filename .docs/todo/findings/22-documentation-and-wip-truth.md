---
type: finding
id: harness-finding-22
status: closed
priority: P1
owner: .docs
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Documentation and WIP truth

## Finding

Public docs and planning records previously mixed shipped, source-present,
installed-proven, frontier, local-only, and unavailable states. The current
records preserve historical receipts while naming the live boundary: the 021
auth chain, 035 provider/cost chain, and 036 lifecycle chain are archived after
installed proof, browser routes remain non-shipped, and frontier scaffolds
remain explicitly labeled.

## Required mechanism

Keep one current technical summary and one findings index. Mark every capability as shipped, source-only, installed-proven, frontier, local prototype, or unavailable. Preserve historical receipts but attach a superseding current finding rather than rewriting the original evidence. Generate source count, test totals, and hashes during release instead of hand-maintaining them.

## WIP ledger

- 021: a-f and parent archived; chain closed; no active frontier.
- 035: a-h and parent archived; installed priced/unknown provider turns,
  multiline `/status`, current hash equality, and terminal QC are closed.
- 036: a-h and parent archived; findings 10, 11, and 13 are closed; roadmap
  moves 21–39 are closed.
- PLUG: parent and a-h archived as superseded by Move40 deferred-delete; no active
  plugin runtime frontier. Reopen only with a concrete need and a new owner-mapped
  recon.

## Acceptance

- No pending parent says complete.
- Every active chain has one executable frontier and valid next_todo.
- Root README, backend README, architecture, AGENTS, docs index, technical summary, workspace record, and changelog agree on current truth.
- Local ignored browser files are never called shipped.
- Installed claims carry exact current hash and process-cleanup evidence.

## Source-message proof

- “Make sure all docs, readmes, agents.mds etc are updated”
- “assume full responsibility for any in progress work and make sure it is complete/accounted for”

## Out of scope

Do not erase historical closeout records or fabricate proof to make a chain green.

## Closure receipt — Move 32 (2026-08-13)

- Filesystem reconciliation confirms `021a` through `021d` are in
  `.docs/todo/changelog/`; `021e` is the sole active 021 frontier.
- The 036 parent and 036h terminal review are in `.docs/todo/changelog/`;
  finding 11 and the installed owner/ticket lifecycle gates are closed.
- At Move 32 close, `.docs/workspace.json` parsed with source/installed
  SHA-256 `F1CAE59A9562A9610478D74AF6D7EF8F2C68E9764BBE91A7E277491958AAA727`,
  `installed_hash_matches: true`, and an empty installed process census.
- Move 34 supersedes that historical artifact. The current source/installed
  SHA-256 is `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`;
  Debug is 19/19 with 1,963/1,963 tests and zero leaks; the installed Codex
  fixture reached `/codex/responses` and the final process census is zero.
- Public README, backend README, architecture, technical summary, docs index,
  roadmap, research, findings, and changelog now state the same boundaries.
- Dedicated installed eligibility/capacity snapshot probes are not inferred
  from the composed ticket lifecycle proof; the docs name them as unrun.

## Closure receipt — Move 34 (2026-08-13)

- `021d` is archived after source and installed consumer proof. OAuth
  `openai-codex` dispatch is explicit; API-key transport remains unchanged.
- The installed disposable fixture captured `/codex/responses` with the account,
  originator, OpenAI-beta, and SSE headers, `stream:true`, and `store:false`.
  It returned `ok`, never requested `/v1/chat/completions`, emitted no bearer
  token, and left zero processes after explicit owner-tree teardown.
- Move 34 source/installed SHA-256 was
  `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`.

## Closure receipt — Move 35 (2026-08-13)

- `021e` is archived after the canonical regression: `19/19` build steps and
  `1,963/1,963` tests passed.
- Operator records now distinguish installed `$VANTARI_HOME/auth.json` from
  workspace `.var/auth.json`; `.env` is documented as bootstrap configuration,
  not the durable auth owner.
- IX route search returned `status: ok` with 21 `/codex/responses` matches;
  the scoped operator-docs/research fake-token search returned `status: ok`
  with zero matches.
- Move 34 is the prior installed consumer checkpoint: SHA-256
  `9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`, local
  `/codex/responses` fixture success, no bearer output, and zero final
  processes. The current artifact is recorded by Move 37/38/39.
- The active auth frontier was `021f` at this historical receipt; no real
  entitlement proof is implied.

## Closure receipt — Move 36 (2026-08-13)

- `021f` and the `021` parent are archived; the auth chain has no pending
  continuation.
- Final regression passed: `19/19` build steps and `1,963/1,963` tests with
  zero leaks.
- Disposable built-binary health returned `ok:true` with the expected model,
  context, pool, and ticket projections. Disposable auth status returned only
  provider/model/account/plan/expiry metadata and no credential values.
- IX ownership, explicit route, OAuth endpoint, and scoped fake-token checks
  returned `status: ok`; the scoped fake-token result was zero matches.
- The owner/kernel pair was explicitly torn down and the final built-binary
  process census was zero. The next active boundary was Move 37 / 035g.

## Closure receipt — Moves 37–39 (2026-08-13)

- 035g installed consumer proof is closed. A real Z.AI `glm-5.1` turn persisted
  measured prompt/completion/cached tokens with `cost_total_usd:null`; a known
  zero-price `glm-5.2` turn persisted the same fields with `cost_total_usd:0`.
  The installed TUI `/status` block rendered workspace, model, effort, session,
  token totals, and cost after the multiline system-row fix.
- Move 38 verified ReleaseFast installation and built/installed SHA-256 equality
  at `09758F2AFE34AC5DCD94F786B5A307F8BB0DF9A11E5DA65B743A6EBB62354834`.
  The installed owner was reconciled and the final VANTARI process census was
  zero.
- Move 39 terminal QC passed the structure, provider-contract, test-pressure,
  code-quality, and provider-to-event-to-TUI criteria. One missing 035c
  Responses-stream cache-default pressure test was added; the current graph is
  `19/19` steps and `1,964/1,964` tests with zero leaks. 035a through 035h and
  the parent are archived. The next active boundary was Move 40.

## Closure receipt — Move 40 (2026-08-13)

- The PLUG chain is archived as superseded, not shipped. Reference harvest and
  owner recon found no installed plugin consumer; the default-visible
  `manage_plugin` builtin had a TODO-only enable/disable path.
- Move40 removed the manager file, registry/availability/dispatch branches, and
  two wrapper-only tests. Contract-only manifest/isolation/socket namespaces
  remain because the matrix tests still own those contracts; no plugin tool is
  model-visible and no plugin discovery or dispatch capability is claimed.
- The installed `tools --json` catalog returned 24 tools and no
  `manage_plugin`. Debug passed `19/19` build steps and `1,962/1,962` tests;
  ReleaseFast/install passed `9/9`; source and installed SHA-256 matched
  `279A112A1D7CD94BF2C5678C961E83A3458951CB9D48E9C5CC21A6D01DF409AF`; the
  final installed process census was zero.
- The next active boundary is Move 41. PLUG move 86 is conditional on a new
  concrete need and owner-mapped recon.

## Closure receipt — Move 41 (2026-08-13)

- Move 41 closes the TUI projection owner. Cold hydration ignores sequence-less
  legacy activity; contiguous sequence-bearing parent events are the only
  activity source; canonical child summaries remain sourced from
  `summaries.jsonl`; live and cold keyed-row projections match.
- The existing `session/list` endpoint now accepts optional `limit`;
  the TUI requests `limit: 1` for latest-session selection. This repaired
  installed `vantari -c` against a 19,213-session workspace without a new
  registry or selector path.
- Source proof is 19/19 build steps and 1,967/1,967 tests; the focused TUI lane
  is 63/63; ReleaseFast/install is 9/9. Source and installed SHA-256 match
  `C65C98363F8DDD9A31F39FAB36F4A280972DCE5E69475AE29DA01FB80A7ABF54`.
  Installed continuation and blank TUI startup/exit passed; the exact
  persistent-owner tree was torn down for proof and final process census is
  zero.
- The current active boundary is Move 42. Move 50 Agent Hub and the visual
  installed matrix remain later boundaries; no completion is inferred for them.

## Closure receipt — Move 42 (2026-08-13)

- The current TUI palette remains one owner in `tui_chat.zig`; the tested
  background hierarchy is transcript surface < metadata surface < composer.
  No theme registry or parallel token system was introduced.
- The steady-state footer has no cancellation shortcut. Active cancellation is
  rendered only while `waiting && cancel_requested`; terminal events clear the
  intent, active `/cancel` shares the generation-bound request path, and idle
  `/cancel` is truthful.
- Debug is `19/19` with `1,991/1,991`; focused TUI is `75/75`; ReleaseFast and
  install are `9/9`. Installed ANSI, blank TUI, and `vantari -c` continuation
  passed. Source and installed SHA-256 match
  `A6E93FA6671256E2755C5DC397747F5E350C6ED7D3DE4BF242AC557B96953072`; exact
  owner-tree teardown leaves zero VANTARI processes.
- The active boundary is Move 43. Move 50 Agent Hub and the installed visual
  matrix remain later boundaries; no completion is inferred for them.

## Closure receipt — Move 43 (2026-08-13)

- `PromptMode` is the sole owner for the session-local behavioral lens. The TUI
  cycles `orchestrate -> build -> align -> plan` on Shift+Tab; the next
  `session/send` carries the exact label and omission defaults to `orchestrate`.
- The prompt builder emits the selected mode in the provider system envelope.
  The executor carries it through initial, interjection, compaction, child,
  wake, and overflow rebuilds without a tool, access, model, capacity, or
  executor branch. Unknown labels return JSON-RPC `-32602` before execution.
- The seven-source harvest and subtraction decision are durable at
  `.docs/research/2026-08-13-prompt-mode-move43.md`. No mode registry, settings
  schema field, or prompt scaffolding was added.
- Debug is `19/19` with `1,996/1,996`; focused TUI is `76/76`; ReleaseFast and
  install are `9/9`. Installed TUI startup accepted Shift+Tab and blank startup/
  exit passed. Source and installed SHA-256 match
  `145F08FF38FA94D325006B4CC78A8C0EFD83A885E9A2F8DBA6152CFA20BFC1EC`; the
  exact owner-tree teardown leaves zero VANTARI processes.
- The active boundary is Move 44: one compact status row for prompt mode,
  model, effort, context, and remaining capacity. Agent Hub and the installed
  visual matrix remain later boundaries.

## Closure receipt — Move 44 (2026-08-13)

- The one canonical footer projection now renders `ready`/`working`/`cancelling`/
  `failed`, the active prompt mode, model, effort, exact context arithmetic, and
  remaining context without wrapping. Unknown capacity stays `ctx —`; no
  progress gauge, settings registry, or second telemetry owner was added.
- Focused TUI is `77/77`; Debug is `19/19` with `1,998/1,998`; ReleaseFast and
  install are `9/9`. Installed TUI rendered the new row and blank startup/exit
  passed. Source and installed SHA-256 match
  `F569105E0845F6F6F23282C3C3C697EE8B3939CAC5515E111AC29A5CEAF754C2`; exact
  owner-tree teardown leaves zero VANTARI processes.
- The active boundary is Move 45: agent/queue/cost signal policy. Agent Hub and
  the installed visual matrix remain later boundaries.

## Closure receipt — Move 45 (2026-08-13)

- The existing footer read model now adds known session cost only when terminal
  telemetry carries finite, nonnegative pricing. Active/max agents and queue
  pressure remain signal-gated; unpriced sessions stay quiet. No second row,
  poller, registry, event, or status bus was added.
- Focused TUI is `77/77`; Debug is `19/19` with `1,998/1,998`; ReleaseFast and
  install are `9/9`. Installed TUI rendered the compact row and blank startup/
  exit passed. Source and installed SHA-256 match
  `D83E9A843286E79861FD5FA25514DD18C17B3307DDEC7A2842216B9DA3AB38EA`; exact
  owner-tree teardown leaves zero VANTARI processes.
- The active boundary is Move 46: explicit unknown context after compaction or
  incomplete provider accounting. Agent Hub and the installed visual matrix
  remain later boundaries.

## Closure receipt — Moves 46–48 (2026-08-13)

- The footer preserves `ctx —` for unknown or zero-capacity context after
  compaction/accounting gaps; no fabricated precision or second telemetry owner
  was introduced.
- The existing activity group remains `Agents completed/total` without the
  removed `waiting on N` filler. Group and child rows use `○` for queued/running
  and `◉` for complete, with failure/cancel markers explicit.
- Each keyed child row renders the latest canonical summary as a bounded quoted
  suffix. Tool and terminal phases update the same row without replacing it;
  `tool_completed` is not promoted to the visible child summary. Valid UTF-8
  and one-row width truncation are covered.
- Focused TUI is `78/78`; Debug is `19/19` with `2,000/2,000`; ReleaseFast and
  install are `9/9`. Installed TUI rendered the compact unknown-context row.
  Source and installed SHA-256 match
  `C7B3EE8E4B41D12D486D7C73F3E209834EEE91619364FE0ABE5A676E8C7EA9B7`; exact
  owner-tree teardown leaves zero VANTARI processes.
- Move 49 was the next boundary: typed child phase marker and elapsed-time
  projection. Its closure and the current Move 50 boundary are recorded below.

## Closure receipt — Move 49 (2026-08-13)

- The existing `var1.child_event.v1` envelope now carries optional `elapsed_ms`,
  derived from supervisor task timestamps. Child start, session, waiting, tool,
  response, and completion phases use the same typed event path.
- `ChatState` keeps one keyed `group_id + task_id` row. It renders compact
  phase/time metadata before the canonical quoted summary, then drops the
  lower-signal metadata when width is tight. No timer, poller, heartbeat bus,
  chat-bubble event, transcript copy, or second summary ledger was added.
- Focused TUI is `78/78`; Debug is `19/19` with `2,000/2,000`; ReleaseFast and
  install are `9/9`. Installed TUI showed `○ Agents 0/1` and the child `· session`
  phase. Source and installed SHA-256 match
  `6D7F72DD3E1C03DF3A6FA71C07CD6DEA6A020391C8F85A0B1B395C9670DE93BF`; exact
  proof-owned teardown leaves zero VANTARI processes.
- Move 50 is closed: the Agent Hub proposal was narrowed to the existing keyed
  child row and canonical summary ledger. The existing
  `update_session_summary` completion now refreshes the row with a bounded
  quoted summary; no registry, poller, chat-bubble event, unread state,
  transcript copy, or second ledger was added. Proof and rationale live in
  `.docs/research/2026-08-13-agent-hub-move50.md`.
- Move 51 is closed: `agents/supervisor.zig:childExecutionContext` carries the
  resolved route access flag into the shared child context; all ten
  file/search/LSP/shell entrypoints use `fsutil.resolveWithAccessMode`; clean
  Debug `19/19` and `2,000/2,000`, ReleaseFast/install `9/9`, installed true
  config write, matching SHA-256
  `39B26C5D898F9F6346A0DE4397002D05C810B2EB34153CA11171440129B3B453`, and
  zero-process teardown pass. Move 52 is the active boundary.
- Move 52 is now closed in source: session records persist the immutable access
  scope, summaries/footer project it, and child turns inherit it without moving
  `.var`. Move 52a is source-complete: root-only `ask_user`, one
  `input/respond`, bounded `a`–`f` choices, headless-child `InputUnavailable`,
  cancellation/shutdown wake-up, terminal replay cleanup, and adversarial
  controller/broker tests. Debug is `19/19` with `2,023/2,023`; ReleaseFast/
  install is `9/9`; source/installed SHA-256 is
  `739F0D10D366738D01CEB3879D5B9487F7C99FB7CDB4D7FF9DB3418386A0DEED`.
  Installed health/catalog proof is green and zero proof-owned processes remain.
  A provider-driven installed TUI response is explicitly open.
