---
type: technical-summary
id: docs/technical-summary
status: current
updated: 2026-08-14
owner: apps/backend/src
---

# VANTARI technical summary

VANTARI is a local agent kernel. `apps/backend` is the application/runtime
owner; tracked `packages/tui` is its vendored terminal dependency and owns no
session or executor state. The Zig runtime owns transcript compilation,
provider turns, typed tool spans, process supervision, ticket admission,
child-agent execution, and recovery evidence. TUI and CLI render kernel
projections. `apps/frontend` is an ignored local prototype, not a shipped
tracked client.

## Current operator input correction — 2026-08-13

The tracked TUI now has one focused input path for the three reported
regressions. Settings draws into the normal Vaxis frame and calls `vx.render`
before flushing, so opening the overlay cannot leave the previous frame on
screen. The parser accepts the terminal-standard `CSI Z` encoding for Shift+Tab
and maps it to the existing session-local `PromptMode` cycle.

The composer projects a transient command palette from the executable
`command_registry`. It matches only the first single token by
prefix, accepts bare names such as `set` while retaining slash compatibility,
uses a bounded five-row window with keyboard scrolling, and routes Enter through
the existing command registry. It disappears for prose or no matches. Typed
child phase and elapsed evidence remains in the event spine; the visible child
row is only `agent - state "latest summary"` at the available one-line width.
No second command registry, poller, chat-bubble event, or TUI-owned status bus
was added. Debug `19/19` and `2,102/2,102` pass; focused `test-tui` is `9/9`
and `120/120`; ReleaseFast/install is `9/9`; source and installed SHA-256
match `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Installed smoke typed bare `s` then `e`, rendered the popup, opened settings
with Enter, moved `runtime → provider → runtime` with Right and `CSI Z`,
returned with Escape, exited with Ctrl+C, and the final exact VANTARI process
census was zero. Settings now uses Tab/Right forward and Shift+Tab/Left
reverse navigation and displays compiled defaults when persisted config is
missing or invalid.
The explicit footer campaign is separate and small: `clients/footer_effects.zig`
animates only the `orchestrate` token every three seconds, requests timed wakes
only during its bounded sweep, and leaves the other prompt modes static.

## Current question input lifecycle and event-loop correction — 2026-08-14

The question panel now has a terminal ownership boundary in `ChatState`. A
missing session owner clears an orphaned panel, `session/send` transport or
terminal failure clears the projection, and a successful returned turn clears it
even if the final notification races the RPC response. While the panel is active,
Ctrl-C routes through the existing `input/respond` cancellation path; it does not
fall into the run-cancel path and cannot leave the TUI trapped behind a stale
question.

Both key ingress paths now call one `ChatState.handleQuestionKey` boundary.
Controller, allocation, serialization, and `input/respond` failures stay inside
the TUI loop, add one bounded recovery message when possible, and leave the
question panel available for retry or explicit cancellation. The controller is
still the one settings-style horizontal-row owner; no question poller or second
input loop was added.

The settings-style batch surface remains one controller: one horizontal row per
question, horizontal options, and one review/submit boundary. `orchestrate`,
`build`, `align`, and `plan` share it; root normal is the catalog/profile name,
not a fifth `PromptMode`. Focused TUI Debug and ReleaseFast both pass `135/135`;
full Debug passes `19/19` steps and `2,165/2,165` tests; source ReleaseFast
build passes `9/9`. The current source binary SHA-256 is
`D22A6E617DEF01BDF323F4F4500C1F53AD54C1221CFE6A8A6413FCA6D7D1EDFE`.
Installed promotion and provider-driven live question proof remain deferred;
the preserved installed owner remains on
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.

## Current context-compile recovery boundary — 2026-08-14

Move 69 keeps `apps/backend/src/core/context/builder.zig` as the only
provider-window compiler. Each compile returns a small `CompileReport` with
counts for synthesized interrupted tool results and skipped orphan,
missing-id, or mismatched rows. The durable `messages.jsonl` transcript is not
rewritten.

`core/executor/loop.zig` emits one
`var1.context_compile_diagnostic.v1` event through the existing `events.jsonl`
writer only when a report is non-empty. `provider_overflow` compaction then
rebuilds from the latest checkpoint plus durable suffix and retries once; no
executor-local durable tool batch is appended into the retry payload. The TUI
suppresses this mechanics row in silent/normal posture and formats its counts
in full logs.

Debug passes `19/19` build steps and `2,163/2,163` tests. Source ReleaseFast
passes `9/9` with SHA-256
`898CAF97FD90F14B0FF3C202887467F7FFDDAC670583BEFB8B4491C2F6909DD6`.
Installed promotion remains deferred. Research and receipt:
`.docs/research/2026-08-14-context-compile-diagnostics-move69.md` and
`.docs/todo/changelog/060-context-compile-diagnostics-move69.md`.

## Current ticket and scheduler policy boundary — 2026-08-14

Move 63 adds no scheduler registry or quota layer. The four retired
`tickets.*` execution-policy keys remain rejected, `assigned` remains queue
admission without launch, and `agent_routes.max_concurrency` is the only
configured capacity key. `AgentService` applies it to the single fixed
`Supervisor` pool; scheduler admission observes the resulting capacity. Lease
TTL, heartbeat window, and dispatch limit remain private scheduler protocol
constants. Agent `max_steps`, `max_tool_calls`, and `max_children` remain
specialist execution budgets, while token/cost/wall-time/turn quotas stay in
the later usage-ledger move.

Debug passes `19/19` build steps and `2,154/2,154` tests; source ReleaseFast
passes `9/9` with SHA-256
`2530D80C6B8129960C131F85B9508896BBA332423EC64FD2506061770E5E042D`.
Installed promotion remains deferred. Research and receipt:
`.docs/research/2026-08-14-ticket-quota-scheduler-policy.md` and
`.docs/todo/changelog/054-ticket-quota-scheduler-policy.md`.

## Current frontier — Move 55a source closure, Moves 56-57, 57a, and Moves 62-63

Move 34 closes the Codex subscription transport slice. `core/auth/store.zig`
remains the single credential owner for workspace `.var/auth.json` and installed
`$VANTARI_HOME/auth.json`; `core/auth/openai_codex.zig` owns the named provider
descriptor, PKCE, localhost callback, redirect parsing, token exchange/refresh
hooks, and JWT claim extraction. `VAR1 auth status --json` exposes only provider,
model, account, plan, expiry, and verification metadata. `core/providers/dispatch.zig`
routes typed OAuth `openai-codex` records to `core/providers/openai_codex.zig`,
which builds `/codex/responses`, carries account/originator metadata, parses
Responses/SSE into the canonical completion result, and rejects missing/expired
auth, entitlement, rate-limit, and transport capability failures explicitly.
API-key records remain on the existing OpenAI-compatible `wire_api` path; there is
no runtime fallback from Codex OAuth to `/v1/chat/completions`.

Move 34 proof: Debug `19/19` build steps and `1,963/1,963` tests pass with zero
leaks; ReleaseFast install is `9/9`; the installed binary, pointed at a
disposable local OAuth fixture, posts to `/codex/responses`, sends the account,
originator, OpenAI-beta, and SSE headers, includes `stream:true` and `store:false`,
returns `ok`, never requests `/v1/chat/completions`, emits no bearer token, and
exits after the fixture response. The persistent owner/kernel pair was explicitly
torn down and the final installed process census was zero. The Move 34
checkpoint SHA-256 was
`9CEE55BE3DCCBE858EF3418B955249AFE036CD9FB989756D4487096D8ED1E73D`.

Move 35 closes the operator documentation slice. Root/backend README,
architecture, AGENTS, SKILL, llms, auth-persistence research, findings,
workspace, roadmap, index, and changelog now describe installed
`$VANTARI_HOME/auth.json` versus workspace `.var/auth.json`, `.env` bootstrap
semantics, the explicit Codex route, and redacted status metadata. IX returned
27 route references and zero fake fixture-token matches in the scoped operator
docs/research search. Move 36 closes the auth-chain verification; no real
provider entitlement was claimed.

Move 36 closes the full 021 auth chain. Units 021a through 021f and the parent
are archived with evidence. The final built-binary fixture checks returned
health `ok:true` and secret-free OAuth status metadata; the auth ownership,
explicit route, OAuth endpoint, and scoped redaction IX probes all returned
status `ok`. The persistent owner/kernel pair was explicitly torn down after
the checks. The auth chain has no pending continuation.

Move 37 closes the cost-model consumer gate. A real installed Z.AI turn with
the known zero-price `glm-5.2` model persisted measured prompt, completion, and
cached tokens plus `cost_total_usd:0`; a provider-accepted `glm-5.1` model not
present in the compiled table persisted the same measured fields with
`cost_total_usd:null`. After the TUI row-owner fix, installed `/status` visibly
rendered workspace, model, effort, session, token totals, and cost on separate
lines. Source tests pass `19/19` and `1,964/1,964`; ReleaseFast/install is
`9/9`; current source/installed SHA-256 is
`09758F2AFE34AC5DCD94F786B5A307F8BB0DF9A11E5DA65B743A6EBB62354834`; final
installed VANTARI process census is zero.

Move 39 closes 035h terminal QC. The provider lane has one Usage value type,
one compiled pricing owner, one compat detector, one terminal payload builder,
and one TUI read model. Anthropic, Responses, and OpenAI-compatible usage
pressure covers priced, cached, missing-cache, stream, and tool-call shapes;
the added Responses-stream cache-default probe closes the promised 035c test
floor. The full provider-to-event-to-TUI chain passes 19/19 build steps and
1,964/1,964 tests. No cost database, price service, event type, or parallel
executor was added.

Move 40 closes the PLUG decision as deferred-delete. Recon across the local
Codex, pi, oh-my-pi, Eve, KrillClaw, nullclaw, and Flue references plus the
canonical tool owners found no installed plugin consumer. The default-visible
`manage_plugin` builtin had a TODO-only enable/disable path, while manifest,
isolation, and socket types were contract scaffolding with no catalog or
dispatch consumer. The manager file, registry/availability/dispatch branches,
and two wrapper-only tests were removed; matrix-backed contract namespaces
remain intact for a future concrete need. The installed `tools --json` catalog
returns 24 tools and excludes `manage_plugin`. Debug passes 19/19 build steps
and 1,962/1,962 tests; ReleaseFast/install passes 9/9; current source and
installed SHA-256 is
`279A112A1D7CD94BF2C5678C961E83A3458951CB9D48E9C5CC21A6D01DF409AF`; the final
installed VANTARI process census is zero. No plugin runtime capability is
claimed.

Move 41 closes the TUI projection boundary. `ChatState` now renders activity
only from contiguous sequence-bearing parent events; sequence-less legacy
activity rows are ignored during cold hydration, while transcript messages
remain the transcript source. The supervisor's `assistant_response` projection
continues to read the bounded canonical child row from `summaries.jsonl`, so
tool phases remain typed state markers rather than visible child conclusions.
Live application and contiguous cold replay now prove identical keyed group/item
rows, state, text, and cursor.

Move 41 also bounds the existing `session/list` owner response when a caller
supplies `limit`; `vantari -c` requests one latest summary instead of
serializing every workspace session. This repaired the installed continuation
failure reproduced with 19,213 sessions and an 8 MiB owner response cap without
adding a second session selector or registry. The persistent owner still
survives presentation detach by design; the installed proof explicitly tore
down the exact owner tree after exercising `vantari -c` and the blank TUI.
Debug passes `19/19` build steps and `1,967/1,967` tests; ReleaseFast/install
passes `9/9`; current source and installed SHA-256 is
`C65C98363F8DDD9A31F39FAB36F4A280972DCE5E69475AE29DA01FB80A7ABF54`; final
installed VANTARI process census is zero.

Move 42 closes the composer hierarchy and conditional-cancellation boundary.
`styles.surface`, `styles.meta_surface`, and `styles.composer` remain the sole
TUI background tokens; the composer is the focused first row, metadata is the
quieter row below it, and `colorLevel` proves strict lightness order. The
steady-state row carries no cancellation shortcut. `formatFooterStatus` emits
`cancelling` only while `waiting && cancel_requested`; terminal events clear the
intent, Escape/Ctrl-C retain the generation-bound request path, and an active
`/cancel` interjection shares that owner while idle `/cancel` is truthful. Exact
wide and width-40 metadata projections cover the narrow/wide operator states.
The seven-source harvest and compression decision are recorded in
`.docs/research/2026-08-13-tui-composer-move42.md`.

Move 42 proof: the complete Debug graph passes 19/19 steps and 1,991/1,991
tests; the focused TUI lane passes 75/75; ReleaseFast/install passes 9/9.
Installed ANSI inspection observed transcript `(8,17,15)`, metadata
`(10,22,20)`, and composer `(16,34,31)`; blank TUI startup/exit and
`vantari -c` continuation passed. Source and installed SHA-256 match
`A6E93FA6671256E2755C5DC397747F5E350C6ED7D3DE4BF242AC557B96953072`; exact
owner-tree teardown leaves zero VANTARI processes.

Move 43 closes the prompt-mode control boundary. `PromptMode` is one typed,
session-local prompt lens with the fixed cycle `orchestrate -> build -> align
-> plan -> orchestrate`; the default is `orchestrate`. Shift+Tab is owned by
the TUI and the next `session/send` carries the exact lower-case label. The
host rejects unknown labels before session lookup or provider execution. The
executor carries the typed value through initial prompt assembly, interjection,
compaction, child parking/convergence, wake, and provider-overflow rebuilds.
`core/prompts/builder.zig` inserts one provider-visible layer; mode selection
does not change the executor, tool catalog, access policy, model, or agent
capacity. Other clients retain the compatibility default.

Move 43 proof: Debug passes `19/19` build steps and `1,996/1,996` tests;
ReleaseFast/install passes `9/9`; installed TUI startup accepted Shift+Tab and
blank startup/exit completed. Source and installed SHA-256 match
`145F08FF38FA94D325006B4CC78A8C0EFD83A885E9A2F8DBA6152CFA20BFC1EC`; the
proof-owned owner/kernel tree was explicitly torn down and the final installed
VANTARI process census is zero. The seven-source harvest and rejected
registry/executor complexity are recorded in
`.docs/research/2026-08-13-prompt-mode-move43.md`.

Move 44 closes the compact TUI status row. `formatFooterMetaWithPool` remains
the single projection owner and emits status, active `PromptMode`, model,
effort, context used/capacity/percent, and remaining context in one
non-wrapping row. Existing `ChatState.status` values map to `ready`, `working`,
`cancelling`, or `failed`; no second state machine or event bus was added.
Context values remain sourced from typed turn telemetry: unknown or zero
capacity renders `ctx —`; estimated used/capacity/percent/remaining values carry
`~`, and unknown used values do not produce a numeric remaining value. Exact
provider usage is separate from the compiler estimate. Candidate fitting uses
codepoint width, keeps status/mode/model ahead of optional agent/queue detail,
and ends with a bounded codepoint-safe truncation.

Move 44 proof: Debug passes `19/19` build steps and `1,998/1,998` tests;
focused TUI passes `9/9` steps and `77/77` tests; ReleaseFast/install passes
`9/9`. Installed TUI rendered `ready · orchestrate · glm-5.2 · max · ctx — /
500k` and exited after exact owner-tree teardown. Source and installed SHA-256
match `F569105E0845F6F6F23282C3C3C697EE8B3939CAC5515E111AC29A5CEAF754C2`;
the final installed VANTARI process census is zero. The eight-source harvest
and rejected gauge/registry complexity are recorded in
`.docs/research/2026-08-13-status-row-move44.md`.

Move 45 closes the signal-bearing footer policy. `formatFooterMetaWithPool`
keeps existing active/max agent and queue pressure conditional, then reuses
the same lower-signal segment for a known session total formatted as
`cost $0.######`. The value is projected only from finite, nonnegative
`turn_terminal.cost_total_usd`; unknown provider pricing stays omitted and
`/status` remains the detailed cost surface. No cost poller, event, registry,
second row, or status bus was added.

Move 45 proof: focused TUI passes `9/9` steps and `77/77` tests; Debug passes
`19/19` build steps and `1,998/1,998` tests; ReleaseFast/install passes `9/9`.
Installed TUI rendered `ready · orchestrate · glm-5.2 · max · ctx — / 500k`
and blank startup/exit passed. Source and installed SHA-256 match
`D83E9A843286E79861FD5FA25514DD18C17B3307DDEC7A2842216B9DA3AB38EA`; the
exact owner-tree teardown leaves zero VANTARI processes. The seven-source
harvest and rejected status-registry/poller complexity are recorded in
`.docs/research/2026-08-13-agent-queue-cost-move45.md`.

Moves 46–48 close the next TUI projection slice without adding a read-model
owner. The existing footer keeps context unknown as `ctx —` after compaction or
zero/incomplete capacity accounting. The keyed activity group remains
`Agents completed/total`; `○` means queued/running and `◉` means complete, with
failure/cancel markers preserved. Each child row now renders its lifecycle
label plus the latest canonical summary as a bounded quoted suffix. Later tool
or terminal events update the same keyed row without replacing that summary;
`tool_completed` is not a visible conclusion. Whitespace compaction, UTF-8
boundary handling, and one-row display-width truncation are covered by focused
tests. No chat-bubble event, poller, heartbeat, TUI ledger, or status registry
was added.

Moves 46–48 proof: focused TUI passes `9/9` steps and `78/78` tests; Debug
passes `19/19` build steps and `2,000/2,000` tests; ReleaseFast/install passes
`9/9`. Installed TUI rendered `ready · orchestrate · glm-5.2 · max · ctx — /
500k`; source and installed SHA-256 match
`C7B3EE8E4B41D12D486D7C73F3E209834EEE91619364FE0ABE5A676E8C7EA9B7`; the
proof-owned owner/kernel tree was torn down and the final process census was
zero. The source harvest and subtractive decision are recorded in
`.docs/research/2026-08-13-agent-summary-bubble-move47-48.md`.

Move 49 closes the keyed child phase/elapsed projection. The supervisor reuses
its task timestamps to add optional `elapsed_ms` to the existing
`var1.child_event.v1` envelope and emits typed phase labels at child start,
waiting, tool, response, and completion boundaries. `ChatState` renders the
phase and elapsed snapshot on the same child row, drops lower-signal metadata
before the canonical quoted summary when narrow, and never adds a timer,
poller, heartbeat, chat-bubble event, or second ledger.

Move 49 proof: focused TUI passes `9/9` steps and `78/78` tests; Debug passes
`19/19` build steps and `2,000/2,000` tests; ReleaseFast/install passes `9/9`.
Installed TUI showed the keyed child activity projection with `○ Agents 0/1`
and `· session`; source and installed SHA-256 match
`6D7F72DD3E1C03DF3A6FA71C07CD6DEA6A020391C8F85A0B1B395C9670DE93BF`; exact
proof-owned owner/kernel teardown leaves zero VANTARI processes. The harvest and
subtractive decision are recorded in
`.docs/research/2026-08-13-child-phase-elapsed-move49.md`.

Move 50 closes the Agent Hub decision by narrowing it to the existing keyed
child row. The parent supervisor recognizes the already-durable `tool completed:
update_session_summary` boundary, reads the canonical child summary, and emits
the existing `child_progress` envelope with phase `summary`; `ChatState`
refreshes the same quoted row while the child is running. The change adds no
Agent Hub registry, unread state, poller, websocket, chat-bubble event,
transcript copy, or second ledger.

Move 50 proof: focused TUI `9/9` and `78/78`; full Debug `19/19` and
`2,000/2,000`; ReleaseFast/install `9/9`; source/installed SHA-256
`6814396B7E2A134E9ECAED9DA5B6567FEAA01824DAC948CC54DC725EFC3DF178`;
installed TUI rendered `○ Agents 0/1` and persisted child rows; exact
owner-tree teardown left zero VANTARI binaries. The installed smoke session
did not emit a summary-tool completion, so it correctly rendered `· session`;
the focused TUI test proves the bounded quoted-summary path.

A full Agent Hub is deferred until a measured operator need requires per-agent
drill-down beyond the existing row and canonical `session/get`/summary owners.
Move 51 is closed: `agents/supervisor.zig:childExecutionContext` now carries
the resolved route access flag into the shared child context, and all ten
file/search/LSP/shell entrypoints remain on `fsutil.resolveWithAccessMode`.
Move 52 is closed in source: `full_access_mode` is persisted on the session,
projected through `SessionSummary`, copied into the effective turn config, and
shown as `scope workspace` or `scope full` in the footer. `.var` and session
ledgers remain canonical. Debug is `19/19` steps and `2,023/2,023` tests;
ReleaseFast/install is `9/9`; source and installed SHA-256 match
`739F0D10D366738D01CEB3879D5B9487F7C99FB7CDB4D7FF9DB3418386A0DEED`;
installed health and root tool catalog are green; the proof-owned process
census is zero.

The root interactive-input slice is source-complete. `ask_user` is the only
root question tool; it emits bounded `var1.input_requested.v1` data, the TUI
controller uses Enter/Space and inline `f / Other`, and `input/respond` wakes
the session-scoped host broker. Child profiles omit the tool and fail with
`InputUnavailable`. Session cancel, owner shutdown, terminal replay, duplicate
cross-session request ids, empty answers, and Other serialization are covered by
the same Debug graph. The installed catalog exposes `ask_user`; a real
installed provider-driven question response remains the next consumer probe,
not an unclaimed proof.

The follow-on question-panel repair is source-complete. `ask_user` and response
serialization free only initialized slices, removing the late-invalid batch
crash. `question_view.State` renders one bounded horizontal row per visible
question with clamped question/option focus and a review/submit state; malformed
`input_requested` data produces one bounded system message and direct run
cancellation instead of unwinding TUI replay. Vaxis-borrowed question text now
stays in State, static literals, or one frame arena until `vx.render`; the
display projection also rejects invalid UTF-8/control text, preserves original
response ids behind static `a`–`f` labels, and guards clipped header/divider/row
slots. `orchestrate`, `build`, `align`, and `plan` share the controller. Root
  normal, root-agent, and orchestrator-only catalogs all retain `ask_user`; child
  profiles remain headless. Both idle and streaming key paths now use one
  `ChatState.handleQuestionKey` recovery boundary for controller and
  `input/respond` errors. Focused TUI is `135/135`, full Debug is
  `2,165/2,165`, and source ReleaseFast exits `0` at SHA-256
  `D22A6E617DEF01BDF323F4F4500C1F53AD54C1221CFE6A8A6413FCA6D7D1EDFE`;
  installed promotion remains intentionally deferred. Research:
  `.docs/research/2026-08-14-root-question-review-panel.md`,
  `.docs/research/2026-08-14-question-panel-consumer-hardening.md`, and
  `.docs/research/2026-08-14-question-panel-runtime-contract.md`,
  `.docs/research/2026-08-14-question-panel-input-lifecycle.md`, and
  `.docs/research/2026-08-14-question-panel-event-loop-recovery.md`.

## Current question modal boundary — 2026-08-14

The question controller now owns the complete Vaxis frame while an
`input_requested` request is active. It uses the existing settings/autocomplete
visual hierarchy and keeps one horizontal row per visible question, inline
`Other` input, and one review/submit state. Transcript, reasoning-dock,
status-bar, and composer layout are not calculated until the modal settles, so
a long batch or a cramped viewport cannot collide with the normal footer.

`orchestrate`, `build`, `align`, and `plan` still share the same controller and
broker path. Multi-select Enter/Space toggles in place until review; deselecting
`Other` clears its custom text. The existing idle/streaming
`ChatState.handleQuestionKey` boundary remains the only input error boundary.
Focused TUI Debug and ReleaseFast are both `137/137`, including 14/4/1-row
modal rendering and the maximum 60-question batch at 1/2/4/20 rows. Full
Debug is `19/19` steps and `2,178/2,178` tests; source ReleaseFast is `9/9`
at SHA-256
`27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
Installed promotion and provider-driven live response remain deferred; the
preserved installed owner remains on
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
The request envelope rejects empty, wrong-schema, wrong-kind, and oversized
payloads before rendering; prompt and option display truncation uses terminal
cell width. Receipt: `.docs/todo/changelog/065-question-modal-batch-boundary.md`.

## Current failure receipt boundary — 2026-08-14

Move 71 embeds one bounded `var1.failure_receipt.v1` payload in the existing
failed or timed-out `turn_terminal` event. The receipt normalizes class, phase,
and detail, derives a deterministic `failure-<sha256>` ID, and stays absent on
completed or cancelled turns. Session cold projection and scheduler terminal
reconciliation preserve the same ID in the existing ticket receipt; expired
requeue uses the same normalization owner and idempotency boundary.

Focused TUI Debug and ReleaseFast remain `137/137`; full Debug is `19/19`
steps and `2,178/2,178` tests; source ReleaseFast is `9/9` at SHA-256
`27BBEB05623899CB5D35A33EF523250A26C469644372C809C130A536DBAD7BAF`.
Installed promotion remains deferred. Receipt:
`.docs/todo/changelog/064-failure-receipts-move71.md`.

## Move 72 immutable replay receipt boundary — 2026-08-14

Move 72 appends one `var1.repair_receipt.v1` event to the existing
`events.jsonl` ledger at root-turn admission, before context compilation or
provider dispatch. It retains the exact original input and selected model,
records `replay_input_immutable: true`, and hashes the transient effective
config, canonical tool catalog, tracked environment, and source baseline.
The source baseline is `git:<commit>` when Git is available and `unavailable`
otherwise. Raw config, tool, and environment snapshots are not durable. A
regression embeds an API-key-like value in a config snapshot and proves it is
absent from the stored receipt.

Full Debug and ReleaseFast are `19/19` steps and `2,180/2,180` tests. The
source ReleaseFast build is `9/9` at SHA-256
`8E15F5ED22631B232EFF2F5FE2FF1E6B336250D22C61E0313645A6BEAB256639`.
Installed promotion remains deferred; the preserved installed owner remains
on `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Receipt: `.docs/todo/changelog/066-repair-receipts-move72.md`.

## Current causal diagnosis boundary — 2026-08-14

Move 73 keeps diagnosis inside the existing failed or timed-out
`turn_terminal.failure` payload. `shared/protocol/events.zig` maps normalized
failure class and phase to one fixed invariant label, derives a deterministic
`diagnosis-<sha256>` ID, and records the exact causal span from
`session_started.seq` through `turn_terminal.seq`. The record is
`var1.repair_diagnosis.v1`; it contains no model-generated cause or free-form
telemetry. Completed and cancelled turns remain diagnosis-free.

Full Debug and ReleaseFast are `19/19` steps and `2,180/2,180` tests. The
source ReleaseFast build is `9/9` at SHA-256
`F0D19C0BE1E92EFD59986437731B2B96884CE81F7E8703137C45B0046E861137`.
Installed promotion remains deferred; the preserved installed owner remains
on `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Receipt: `.docs/todo/changelog/067-repair-diagnosis-move73.md`.

## Current repair-candidate boundary — 2026-08-14

Move 74 composes the candidate proposal into the existing tool registry/runtime
and `events.jsonl` owner. `repair_candidate` resolves the target through shared
access mode, requires an existing inspected file, captures its before hash,
hashes the operation/path/patch descriptor, and records expected/current source
baselines. It never writes, reserves a write intent, stores patch body, or
allows mutation. A drift mismatch appends `baseline_conflict` evidence and
returns typed `RepairBaselineConflict`; a matching baseline returns `ready` but
still reports `mutation_allowed:false`. Moves 75–80 own approval, application,
exact-input replay, evaluation, rollback, and promotion.

Full Debug and ReleaseFast are `19/19` steps and `2,182/2,182` tests. The
source ReleaseFast build is `9/9` at SHA-256
`E92BD7C72EBF06D2D6B43F0ECF85B90AD6E0C34605D72833B96CBD5F0B7BB0FD`.
The existing full-frame question modal is source-verified across all prompt
modes; installed promotion remains deferred and the preserved installed owner
remains on `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Receipt: `.docs/todo/changelog/068-repair-candidate-baseline.md`.

## Current task-branch context boundary — 2026-08-14

Move 70 keeps the existing execution receipt, context compiler, session ledger,
Supervisor, and mailbox as the complete branch mechanism. `launchBatch` records
the exact parent compiler checkpoint in the immutable child receipt. The child
compiler projects that checkpoint's summary plus a recent parent suffix capped
at 64 KiB into the provider window; it does not copy parent rows into the
child `messages.jsonl` ledger. Missing or legacy checkpoint identity uses the
same bounded suffix fallback.

`SessionStore` excludes `shard_checkpoint` lifecycle rows from compiler
checkpoint selection, resolves receipt-addressed checkpoints by identity, and
preserves parent source/token ranges on terminal shard rows. Shard summaries
are capped at a UTF-8-safe 16 KiB. `Supervisor` remains the one terminal
convergence owner and commits one evidence-bearing result per child through the
existing mailbox path. No shard registry, child transcript copier, group-level
synthetic transcript, poller, or worker pool was added.

The adversarial regression proves exact parent checkpoint evidence, exclusion
of an old transcript, bounded recent-suffix selection, and child-ledger
independence. Debug passes `19/19` steps and `2,166/2,166` tests; source
ReleaseFast passes `9/9` with SHA-256
`1E5AFD64D502514FAFC473FA8DD0B8E7B80C905EC52074AB629B1ACAD0157BFE`.
Installed promotion and provider-driven live child proof remain deferred; the
preserved installed owner remains
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
Research and receipt: `.docs/research/2026-08-14-context-shard-projection-move70.md`
and `.docs/todo/changelog/062-context-shard-projection-move70.md`.

Move 60 is source-complete. The provider stream reader checks one typed abort
hook before and after SSE/delta processing, adapters forward the hook, and the
executor persists a correction plus `rule_injected` evidence before retrying
through the existing turn loop. A post-completion guard covers adapters that
ignore the callback. Debug is `19/19` and `2,151/2,151`; source ReleaseFast is
`9/9` at the same SHA-256 above. Installed TTSR/provider proof remains deferred.
Research: `.docs/research/2026-08-14-ttsr-abort-move60.md`.

## Sandbox capability boundary

Move 53 is closed by consolidation. `agents/profile.zig:CapabilityProfile`
already owns branch/tool-class permissions, `ExecutionContext` carries the
profile beside `full_access_mode`, `tools/runtime.zig` derives the model
catalog from it and rechecks it before dispatch, and `supervisor.zig` copies it
at the child handoff. `recon` is read-only least privilege; it is not an
OS/process sandbox. `workspace-contained` is path containment and
`full_access_mode` is explicit path scope.

No `sandbox` alias, second resolver, or backend-less Boolean was added. A real
sandbox is deferred until a supported Windows-native/container provider can
prove workspace mounts, command/file parity, timeout and cancellation, process
tree teardown, cold-start reconciliation, and installed consumer behavior.
Research and source comparison live in
`.docs/research/2026-08-13-sandbox-capability-move53.md`.
Move 53 proof is Debug `19/19` and `2,023/2,023`, fresh ReleaseFast/install
`9/9`, source/installed SHA-256
`B6804F1D865315DEE49D4E5B8620599A089C1D640B63C931483BBA01B3E094E4`,
installed `health --json` and `tools --json` exit `0`, and the exact two
health/catalog owner processes were stopped before a final VANTARI/VAR1
process census of `0`. The installed catalog truthfully reported `search_files`
unavailable because the required dependency was absent in that earlier proof;
Move 54 then closed the executable identity and TUI input repair boundaries,
and Move 55 closed the definition-owned manifest. Moves 56-58 now close the
source eval-kernel and process-supervisor seam; Move 59 closes the DAP lifecycle
seam and Move 60 is the next frontier.

Move 55 closes the capability-manifest drift seam. `ToolDefinition.availability`
now carries each module-owned dependency declaration. `core/tools/registry.zig`
probes the selected definition and renders live availability; it no longer owns
the 15-entry name-keyed `availability_entries` table. The same selected
definition slice supplies the native provider schema, operator catalog, review
risk, and dispatch path. The legacy `availabilitySpec(name)` helper remains a
thin compatibility scan, but runtime catalog and execution paths pass the
definition directly. An unavailable `ix` probe marks `search_files` unavailable
while native `list_files` remains available. The provider prompt receives the
native schema only; examples, availability detail, and repair guidance remain
explicit operator/tool surfaces. The installed `tools --json` proof reports 25
tools and `search_files -> ix -> available`.

Move 55 proof is Debug `19/19` and `2,102/2,102`, focused TUI `120/120`,
ReleaseFast/install `9/9`, source/installed SHA-256
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`, and
exact installed process census `0`. Research and the local execution receipt
are `.docs/research/2026-08-13-capability-manifest-move55.md` and
`.docs/todo/changelog/042-capability-manifest-move55.md`. The next frontier is
Move 55a is source-complete and intentionally not installed-promoted. It adds
the default-silent `runtime.log_level` posture (`silent`, `normal`, `full`) to
the config, prompt envelope, health projection, child execution context,
settings cycle, and TUI event filter while retaining complete durable ledgers.
It also adds `agent_routes.prompt_modes` as a reuse of the existing provider
route shape for `orchestrate`, `build`, `align`, and `plan`; explicit
`session/send` provider/model fields win. Source proof is Debug `19/19` and
`2,119/2,119`, focused TUI `9/9` and `123/123`; no installed hash is claimed.
The harvest and decision record is `.docs/research/2026-08-13-mode-routing-ui-oauth.md`.

Moves 56-57 are source-complete. `builtin/eval.zig` now keeps one persistent
kernel per workspace+session for Python or Bun, preserves variables across
calls, isolates sessions, and bounds output. `ToolDefinition.availability`
reports one Python-or-Bun capability, and Windows uses the real `bun.exe`
executable rather than a PowerShell wrapper.

Move 58 is source-complete. `core/tools/process.zig` is the single bounded child
owner for `shell_exec` and persistent eval. It owns serialized worker writes,
post-cap response draining, timeout/session teardown, Windows Job Object tree
termination, bounded waits, and `PersistentTerminationReceipt` evidence.
Eval retains only its protocol and session registry. Debug proof is `19/19` and
`2,137/2,137`; focused TUI is `9/9` and `129/129`; source ReleaseFast is `9/9`.
Installed promotion remains deferred.

Move 59 is source-complete. `core/tools/builtin/dap.zig` now traverses the
normal catalog/dispatch path with seven risk-correct sockets. One adapter client
is retained per workspace plus session and uses the shared
`core/tools/process.zig::PersistentProcess` owner. Exact Content-Length framing
preserves event/response boundaries, and host teardown releases the registry
after request workers join. A real Python stdio adapter proves initialize,
attach, pause, stackTrace, scopes, variables, and continue on one process;
recon profiles do not receive command-class DAP tools. Debug is `19/19` and
`2,141/2,141`; focused TUI remains `9/9` and `130/130`; source ReleaseFast is
`9/9`; source SHA-256 is
`20D9B9001719F891DF984CAD480B0DFCB712E6197FAF27F6907CE8B205F97D8D`.
Installed promotion remains deferred. Research and receipt are
`.docs/research/2026-08-14-dap-move59.md` and
`.docs/todo/changelog/048-dap-move59.md`.

Move 57a closes the renderer-backed TUI settings seam. `core/config/file.zig`
owns `TuiPolicy` with four named palettes and `bottom`/`top` status placement;
`settings_view.zig` writes both values through `config/set`, and `tui_chat.zig`
reloads the policy after a successful save. Named palettes preserve the strict
transcript surface < metadata surface < focused composer surface hierarchy.
Top placement reserves one status row while the composer remains at the bottom.
The policy is read at startup and after mutation, not in the stream frame loop,
so existing coalescing and adaptive rendering remain the responsiveness path.
Focused TUI proof is `9/9` and `126/126`; current Debug is `19/19` and
`2,129/2,129`; source ReleaseFast is `9/9`; installed promotion is deferred.
Arbitrary color maps and menu/layout registries remain YAGNI until a real
consumer or measured friction justifies them. Research and receipt are
`.docs/research/2026-08-14-tui-theme-status-settings.md` and
`.docs/todo/changelog/045-tui-theme-status-settings.md`.

## Behavior plane

The model chooses the next eligible action. The prompt envelope controls voice,
pace, initiative, delegation posture, work intensity, narration, and
interaction cadence. The kernel limits that choice to executable capabilities
and owns durability, budgets, evidence, recovery, and explicit
irreversible-action gates.

`core/prompts/builder.zig` supplies the default identity and burst loop when no
workspace system prompt exists. `.var/prompts/system.md` or an explicit
`prompts.system_prompt_file` replaces that default identity. Internal runtime
guardrails remain a separate kernel-owned layer. Developer prompt, persona,
operator guardrails, and operator context are hot-loaded on every prompt rebuild
so behavior changes on the next turn without another executor path.

Behavior changes require prompt-profile proof before runtime policy. The
minimum matrix covers terse/detailed, solo/orchestrated,
conservative/aggressive, and low/high update cadence. Runtime logic is valid
only when prompting cannot enforce the capability boundary.

The assembled provider-facing system prompt also has one estimated budget:
`context.prompt_budget_tokens` defaults to `8,192` and fails before provider
dispatch with `PromptBudgetExceeded` rather than silently dropping prompt
layers. Native provider tool schemas remain outside that string and inside the
full context-window accounting. Move 66 proves the four prompt modes and the
named behavior matrix across root, recon, and orchestrator tool routes through
the same builder without executor branches. Move 68 now carries
`TokenPrecision.exact`, `.estimated`, and `.unknown` through the existing turn
events. Provider usage is exact only when the wire supplies evidence; compiler
context arithmetic is marked estimated; omitted usage stays unknown. The
footer marks estimates with `~`, and `/status` suppresses cumulative totals
after an unaccounted completed turn.

The accepted prompt-mode contract names `orchestrate`, `build`, `align`, and
`plan`, with `orchestrate` as the default. Shift+Tab cycles the session-local
selection and the next `session/send` applies one hot-loaded provider-visible
layer. A mode changes guidance only, not executor, tool capability, access
policy, or agent capacity. The source behavior matrix is closed; Move 67 owns
stable message IDs and explicit compaction ranges, and Move 68 owns
token-accounting precision.

Move 68 source proof is Debug `19/19`, `2,159/2,159`; source ReleaseFast
`9/9`; SHA-256
`41C90C2BDF0CB6350E9056EC361E8280FB8EF423AC941A8F4015B88B71695E15`.
Installed promotion remains deferred. The research and receipt are
`.docs/research/2026-08-14-token-accounting-precision-move68.md` and
`.docs/todo/changelog/059-token-accounting-precision.md`.

## Durable execution

```text
input
  -> messages.jsonl transcript
  -> context compiler and checkpoint ledger
  -> provider turn
  -> assistant deltas / reviewed tool spans
  -> events.jsonl event spine
  -> terminal session state and output
```

The full transcript stays append-only. `context.jsonl` is model-visible
projection state, never a second transcript. `sessions/summaries.jsonl` v2 is
the bounded summary ledger used by session navigation and child-agent activity.
Each update appends one stable sequence; readers project the greatest sequence
per session. One host-process mutex owns mutation, and the former keyed v1
object is a one-time migration input only.

`shared/jsonl.zig:PrefixReader` owns one LF-framed valid-prefix boundary for
events, messages, context checkpoints, write intents, and summaries. It handles
a leading BOM, validates UTF-8 and JSON before typed schema parsing, rejects
duplicate or non-monotonic sequences, and stops every projection at the first
defect. `fsutil.appendJsonlRecord` checks the current bounded tail through the
same owner and refuses poison without truncating or appending behind it.

Move 62 closes the write-intent path through the real file tools. The runtime
copies each provider tool-call ID into the session-scoped execution context;
`write_file`, `append_file`, and `replace_in_file` append `reserved` before the
filesystem mutation and `committed` after the measured after-hash and byte
metric. A non-running or proven-stale session appends one `abandoned` terminal
row for each reservation with no commit at cold start. No rollback simulator or
second mutation manager is implied: an abandoned row records indeterminate
effect state for the later repair loop.

## Persistent execution owner

```text
TUI / CLI LocalClient facade
  -> .var/runtime/execution-owner.json
  -> live workspace + generation + protocol + executable handshake
  -> exact token-gated loopback RPC/events
  -> one execution owner
  -> one private ChildClient
  -> one kernel-stdio process and fixed agent pool
```

`host/owner_client.zig` is presentation-facing and owns no kernel process.
`host/http_bridge.zig` is the resident workspace owner and is the only module
that constructs `stdio_client.ChildClient`. Automatic `execution-owner` startup
and foreground `serve` hold the same crash-released lifetime lease. Client
deinit leaves the owner alive; owner shutdown drains accepted connections before
closing the child transport. Browser routes remain redacted and separate from
the exact owner route/token.

The owner projection is project-local and is published only after a real kernel
health response. Clients reject stale state, protocol drift, workspace mismatch,
generation mismatch, and another executable. This source path survives
presentation detach and recovers once after graceful stop or owner crash. It
now reconstructs one persisted ticket child on the same session after lease
expiry; Move 30 proves that path through source and installed forced-kill runs.

## Buffered ticket execution

```text
log_ticket create/transition
  -> durable ticket ledger
  -> assigned queue admission
  -> process-serialized scheduler claim + lease + child identity
  -> AgentService route validation
  -> Supervisor fixed-pool slot
  -> child session and typed evidence
  -> sequence-addressed parent/child notice
  -> completed/failed/blocked ticket projection
```

Assignment is queue admission. It does not launch a child session directly.
The scheduler claims only when `agent_routes.max_concurrency` reports capacity,
then uses the existing `AgentService` and `Supervisor` owners. Ticket execution
has no policy branch; the removed `auto_assign`, `proactive_workpool`,
`close_authority`, and `reopen_with_reasoning` keys had no runtime consumer.
`AgentCapacitySnapshot.fromCounts` is the only pool arithmetic owner: `running`
is active work, `idle = max - running`, `queued` is admitted backlog, and
`available = idle - queued` saturated at zero. Ticket admission uses
`available`. A changed ceiling replaces the same physical pool only after its
submitted closures drain; busy projections retain the actual prior ceiling.
There is no second worker registry or background status bus. The fixed pool now lives in one persistent
owner tree and survives TUI/CLI exit. Scheduler leadership now holds one
crash-released OS lock through the full tick and reads back a random nonzero
generation before dispatch. Ticket mutation holds `.var/tickets/ledger.lock`
across projection, validation, and append; one claim row commits generation,
lease, attempt, capability, and deterministic child identity before the child
exists. Terminal session evidence settles before lease recovery. Heartbeat
renews only when `Supervisor` owns the exact session. An expired claim with an
existing nonterminal session appends one revision-fenced `resume`, replaces only
worker generation and lease, and submits the immutable receipt's same group,
task, session, attempt, capability, transcript, and mailbox cursor. A missing
session alone appends `requeue`. Cold receipt reconstruction defers active
ticket-owned sessions instead of writing `StaleAgentOwner`. Chain 036 is
archived after source and installed lifecycle proof.

## Agent eligibility

`agents {}` is the sole model-facing specialist/team discovery surface. The
existing `AgentService` hot-loads the effective registry, resolves every provider
route, reads one fixed-pool capacity projection, reads one non-blocking current-
session team projection, and asks `core/agents/spec.zig` to render sorted
canonical JSON. The `var1.agent_eligibility.v1` envelope binds that exact
snapshot to a SHA-256 receipt.

The snapshot carries eligible specialist identity, `when_to_use`, and route identity,
stable unavailable-route classes, depth/contact bounds, capacity and team
aggregates, direct/parent/current-group targets, and queue/wake modes. It carries
no private instruction capsule or child transcript. The prompt envelope chooses
quiet, inspect, message, challenge, launch, queue, or wake; the executor has no
behavior-profile branch. Launch and message owners revalidate all scope, route,
capacity, depth, contact, and recipient constraints before effects. A successful
`configure_agent` mutation invalidates the prior eligibility ledger; the next
agent action requires a fresh `agents {}` snapshot.

## Agent mailbox

`core/agents/mailbox.zig` owns bounded agent-to-agent information on the existing
per-session `events.jsonl` spine. `send_agent_message` resolves an exact session
inside the sender's tree, the immediate parent, or current-group siblings. A
message carries a 4 KiB body, at most eight 512-byte references, and explicit
`queue` or `wake` intent. It never assigns a ticket, launches work, grants
authority, or copies another transcript.

Each recipient receives `agent_message_received` at a durable event sequence;
the sender receives one idempotent `agent_message_sent` receipt. The context
compiler injects at most 16 messages/16 KiB as one transient `AGENT_MAILBOX`
system segment. `agent_mailbox_cursor` advances only after provider success, so
failure leaves the same bounded input unread. A live wake continues at the next
safe provider boundary. Queue delivery waits for the recipient's next run.

Child completion now sends the bounded canonical session summary to its parent
through this mailbox. Ticket claim sends a child-to-parent wake notice after the
claim and child session are durable. Neither path appends collaboration content
to `messages.jsonl`; the old convergence-specific transcript append and bespoke
`ticket_claimed` event are removed. Same-session owner recovery preserves the
existing recipient event spine and cursor; replay adds neither another delivery
nor another cursor. Move 30 passes the composed source and installed Windows
restart/delivery mesh; its hash-matched installed run passes with final
zero-process cleanup.

## TUI projection contract

- The footer is one compact metadata row: model, effort, context used/capacity/percentage, remaining capacity, active agents, pool pressure, and assigned queue pressure when non-zero. Estimated context carries `~`; unknown used/remaining values stay `ctx — / capacity`. `Esc cancel` is intentionally omitted from the persistent row.
- The footer background tokens are ordered `styles.surface < styles.meta_surface < styles.composer`; the composer is the focused input row above metadata, and `cancelling` is emitted only while an active run is waiting on cancellation.
- A child group row is `Agents completed/total`. The old `waiting on N` filler is removed from the visible structure; terminal failure/cancellation evidence may remain as a suffix.
- A child row is keyed by `group_id + task_id`. Tool lifecycle events update its state marker but do not become the row label.
- At the child `assistant_response` boundary, the supervisor reads the canonical session summary and sends it as the row detail. The TUI compacts whitespace and truncates the summary to the available one-line width, so the visible row is `agent-name - summary…`, not `agent-name - tool_completed`.
- The projection is replayable from typed parent events. It does not scan child transcripts or create a second activity registry.

## Agent access boundary

`runtime.full_access_mode` is `false` by default. The setting propagates from validated config through route/executor copies into `ExecutionContext`; `agents/supervisor.zig` explicitly preserves the flag at the child handoff. File, search, LSP, and process tools resolve through `fsutil.resolveWithAccessMode`. Restricted mode enforces workspace containment. Explicit full access permits absolute paths and `..` traversal for intended external directories while keeping relative paths anchored at the active workspace. `.var` runtime state, session ledgers, and configured prompt files retain their canonical owners.

## Self-repair boundary

The runtime exposes the evidence needed for repair: typed failures, bounded command output, session ledgers, ticket leases, pool health, and replayable child events. The repair loop is deliberately gated:

```text
trace -> diagnose -> approve exact change -> rerun canonical path -> persist regression evidence
```

Health and TUI telemetry are observability. They do not claim an autonomous patcher or silently mutate code.

## Current proof boundary

- Pinned Zig 0.15.1 ReleaseFast build succeeds: 9/9 steps.
- Six Zig test artifacts receive generated child-process `VANTARI_HOME` values.
  `VANTARI_TEST_ROOT` rejects paths outside `apps/backend/.zig-cache`; 31
  obsolete environment skip guards are removed.
- The complete graph passes 19/19 steps and 2,176/2,176 tests with zero skips.
  The reduced total is intentional: one registry loop executes all 53 declared
  cases and replaces 45 one-case wrappers that left ten cases undiscovered.
  Its host lane executes the stdio child, owner state/client, shared process
  lock, bridge, and process-tree contracts; the integration lane includes
  exact owner route, lease, stalled-loopback deadline, and explicit-workspace
  precedence probes. The backend
  TUI lane passes 137/137.
- A barrier-synchronized leadership race returns one guard and one
  `LeaseUnavailable`. Native proof root
  `.zig-cache/owner-proofs/fb0c9adc7ae1477cabc5b43d00b793f1` starts two
  complete source `kernel-stdio` processes against one due job and one assigned
  ticket. It retains one attempt ID, one ticket claim, one matching deterministic
  child session, one shared nonzero generation, and zero proof-owned processes.
  The move-24 76-segment GGUF audit reports zero candidate and exact pairs across
  ticket, agent-service, session-store, and shared-lock owners.
- Direct create-as-assigned and transition-to-assigned probes retain two queued
  tickets with zero claims, active sessions, or session records. The move-25
  94-segment audit found one import/declaration adjacency candidate, zero exact
  pairs, and no duplicate ticket policy, queue, or execution owner.
- Direct, parent, current-group, nested-parent, queue, wake, provider-failure,
  safe-boundary continuation, replay, child-completion, and real ticket-claim
  probes pass through one mailbox owner. Parent transcripts contain no mailbox
  body or convergence row. The move-26 116-segment audit found five
  declaration/import adjacency candidates, zero exact pairs, and no second
  mailbox, convergence, or runtime owner.
- Parent-shell production-home probes kept 99,960 files, 693,051,144 bytes,
  config/auth hashes, and process inventory unchanged across graph and direct
  proof.
- The broad prompt/tool gate is closed: retired `todo_slice` policy no longer
  leaks into the normal provider payload, duplicate file-inspection prose is
  removed, and tests protect the semantic guardrail instead of capitalization.
- Move 64 closes the work-state duplication: tickets are the sole work
  lifecycle; `todo_slice`, `session_record`, `.var/todos`, per-session
  `session.md`, and automatic generic docs-sync writes are removed. Summaries
  remain handoff projections and durable knowledge/changelog artifacts remain
  ticket-linked. Current source proof is Debug `19/19`, `2,150/2,150`, source
  ReleaseFast `9/9`, SHA-256
  `BD84254B62AF1F4BA2EFEC2609B19BFBB7A69027F20ED1B0F354D9FBCB22CB69`;
  installed promotion is deferred.
- Move 65 closes the prompt/tool duplication: `builder.zig` no longer embeds
  `tools.renderCatalog`; native provider tool schemas are the model-facing API,
  while hot-loaded behavior layers and demand-loaded skills remain intact.
  Prompt tests reject the old catalog markers and provider tests retain native
  schema coverage. Current source proof is Debug `19/19`, `2,150/2,150`, source
  ReleaseFast `9/9`, SHA-256
  `702DD2CB1A067246E82D8670F0F33FD322FD4178C271AF11E712A110151783D3`;
  installed promotion is deferred.
- Move 66 closes the prompt-budget and behavior-profile boundary:
  `context.prompt_budget_tokens` defaults to `8,192`; the builder fails closed
  before provider dispatch when the estimated system-prompt budget is exceeded,
  and native provider schemas remain outside the string. A single matrix proves
  all four modes plus terse/detailed, solo/orchestrated,
  conservative/aggressive, and low/high-cadence profiles across root, recon,
  and orchestrator tool routes without executor branches. Current source proof
  is Debug `19/19`, `2,154/2,154`, source ReleaseFast `9/9`, SHA-256
  `CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`;
  installed promotion is deferred. Move 68 closes the later context-telemetry
  boundary by carrying exact, estimated, and unknown precision through the
  existing turn events and TUI/status projections.
- Move 67 closes the message identity and compaction-range boundary. The
  existing session owner preserves generated and explicit deterministic IDs;
  compaction appends only `context.jsonl` with inclusive source and first-kept
  ranges, and cold replay rebuilds the summary plus exact raw suffix without
  rewriting `messages.jsonl`. Debug is `19/19`, `2,155/2,155`; source
  ReleaseFast is `9/9`, SHA-256 remains
  `CA61A2DD503C0A5A70850AB12A809DE43F471B3ED86FF46DF439A50F8B89BC0D`;
  installed promotion is deferred.
- The invalid first broad run is repaired reversibly: 129 generated sessions,
  16 changelog directories, 18 summary keys, and 64 known test rows are held in
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-test-isolation-incident`
  with snapshot, manifest, rollback, and retained-state readback.
- Seven legacy backend runtime-shaped owners are archived without merge under
  `.var/backup/2026-08-12-legacy-backend-runtime`; automatic todo/changelog
  projections now write direct workspace `.var` owners.
- A direct-test wrapper gap created 21 audit-owned shutdown-probe sessions. The
  exact 84 files / 19,401 bytes had zero summary or changelog projection hits;
  matching backup and quarantine payload digest
  `67CAC4665502DE0ABEC1FA59783DDE09F792DF6BE684CEBBEBBC24868FFA7B2F`
  plus rollback are retained. `zigw.ps1` and `zigw.sh` now isolate direct
  `zig test` invocations as well as the build graph.
- A full production-ledger audit then found 877 older initialized
  `context.jsonl` poison fixtures with no retained parent, continuation,
  summary, or changelog ownership. Whole-session quarantine and rollback live at
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-legacy-context-poison-fixtures`;
  manifest SHA-256 is
  `43FCC3A9530D204B77FF9B37D4534909563628A9EFA2F396F90FDC927811A9BC`.
  The repaired root reads 29,937 ledgers / 1,417,061 rows / 235,074,120 bytes
  with zero UTF-8, JSON, duplicate-sequence, or ordering defects.
- `Server` owns one bounded four-worker/32-request executor. Local RPC calls use
  method deadlines and discard late responses. One shared Windows Job Object
  owns child trees; graceful exit, forced termination, and reader drain are
  bounded.
- The source ReleaseFast owner tracer validates one live generation through
  `execution-owner` and foreground `serve`, preserves it across two client
  detach/reattach cycles, and rejects a duplicate foreground owner. A 20-client
  pressure run produced 20/20 successful clients against one owner/kernel pair.
  Graceful stop, forced owner crash, one-generation recovery, connection drain,
  and final zero proof-owned processes all pass. A conflicting inherited
  `VANTARI_WORKSPACE` cannot redirect an explicit owner root. The 110-segment
  GGUF owner audit found two declaration/import adjacency candidates, zero exact
  duplicates, and no shadow lifecycle or transport owner.
- The uncalled `run-session` direct executor is deleted with its parser and false
  detached-worker help. `run --session-id` remains the only CLI continuation
  path and submits through `LocalClient`, owner `/owner/rpc`, and kernel
  `session/send`. An exact owner-route probe observes `session_started` then
  `assistant_response`; ReleaseFast rejects `help run-session` as unknown.
- Same-session admission is one atomic transition; losing prompts become bounded
  steer messages. Buffer identity and preview share one session-keyed projection.
  Shutdown fences late starts, signals active turns before join, and persisted
  exactly one cancellation terminal event under a blocked provider request.
- Interactive cancellation binds to the durable `session_started.seq` observed by
  the client. Missing, unobserved, and stale `expected_run_seq` values are typed
  no-ops; shutdown remains unconditional only after admission is fenced.
- Every admitted run closes through one `var1.turn_terminal.v1` row bound to its
  `session_started.seq`. `commitTurnTerminal` serializes settlement with event
  append, makes identical retries idempotent, rejects stale/conflicting closure,
  and projects completed/failed/cancelled session status from the durable row;
  timeout remains distinct terminal evidence and projects to failed.
- Session summaries are append-only v2 rows with stable sequence identity,
  latest-row projection, poisoned-suffix continuation, and one-time v1 import.
  One hundred concurrent writers retained all 100 rows; the local GGUF dupe
  audit found zero candidate pairs across the summary, store, and fsutil owners.
- Every session message role now routes through one per-session append owner.
  One hundred mixed concurrent writers retained 100 unique monotonic rows, and
  cold-start sequence initialization reads the valid bounded tail instead of the
  full transcript.
- Every live `session/event` producer persists first and emits
  `var1.session_event_notification.v1` with the exact stored event sequence. Two
  identical same-millisecond events retained distinct envelope identities. The
  tracked TUI now advances only by that sequence, fetches a durable suffix only
  on a gap or turn completion, and no longer owns timestamp/type/text identity.
- Raw command stdout/stderr now routes through one typed `ToolOutputDelta`
  serializer. The hand-rendered JSON and unused top-level `bytes_b64` projection
  are deleted. Source replay preserves NUL, invalid UTF-8, U+2028 bytes, and 0xFF;
  no payload-file subsystem was added under the existing 64 KiB stream cap.
- Event latest/all/suffix, message, context, intent, and summary projections now
  share one typed valid-prefix reader. Installed replay stopped before duplicate
  and torn rows, and append refusal preserved the poisoned 107-byte ledger
  exactly. No CRC fields, sidecar quarantine ledger, auto-truncation path, or
  repair daemon was added.
- The current source ReleaseFast and installed artifact share SHA-256
  `F569105E0845F6F6F23282C3C3C697EE8B3939CAC5515E111AC29A5CEAF754C2`.
  Moves 37–44, Move 34 Codex transport, owner lifecycle, and ticket lifecycle
  promotion all pass; the installed catalog excludes `manage_plugin`, latest
  session selection is bounded, composer/cancellation/prompt-mode/status-row proof is installed, and
  the final installed process census is zero.
- Installed Codex OAuth consumer proof used a valid disposable `$VANTARI_HOME`
  fixture with a pinned context window to avoid unrelated local-model discovery.
  The captured request path was `/codex/responses`; the response was `ok`; no
  live OpenAI or ChatGPT entitlement was used.
- Installed `session/send` against a disposable local provider imported all
  1,176 legacy summary rows, appended one terminal v2 row, retained 1,177
  unique sequences, wrote contiguous unique `user,assistant,tool,assistant`
  message rows, and emitted 12 unique monotonic event notifications. Catch-up
  after sequence 1 returned sequences 2–12 and reconstructed exact stdout
  `0080E280A8FF` plus capped stderr `FF010080E280A8FE`. The final notification
  and ledger row were the same sole `turn_terminal` at sequence 12. Its payload
  was `var1.turn_terminal.v1`, `completed`, and `run_seq = 1`; the live legacy
  hash was preserved and zero process remained.
- The installed settings smoke flips `runtime.full_access_mode` to `true` in a
  disposable workspace, receives `var1.config_set.v1` in 5 ms, removes the
  isolated runtime, preserves the complete live root, and leaves zero process.
- Move 51 clean-tree proof passes Debug `19/19` build steps and `2,000/2,000`
  tests, ReleaseFast/install `9/9`, and the installed settings transport with
  `full_access_mode=true`. Source and installed SHA-256 match
  `39B26C5D898F9F6346A0DE4397002D05C810B2EB34153CA11171440129B3B453`;
  isolated state is removed, live config is unchanged, and the final process
  census is zero.
- The current session-scoped access/input slice passes Debug `19/19` and
  `2,023/2,023`, ReleaseFast/install `9/9`, and source/installed SHA-256
  `739F0D10D366738D01CEB3879D5B9487F7C99FB7CDB4D7FF9DB3418386A0DEED`.
  Installed `health --json` is healthy and installed `tools --json` exposes the
  bounded `ask_user` schema. The exact proof-owned owner/kernel processes were
  stopped and the final matching process census is zero. A provider-driven
  installed TUI response remains explicitly open.
- The move-18 installed cancellation race observed run sequences 1, 6, and 11. Delayed
  cancels for 1 and 6 returned `stale_run` while newer runs completed; exact 11
  returned `requested` and exited with zero process. Its legacy terminal name is
  retained only as historical proof; move 19 removed that writer.
- Moves 5–33 and 38 plus findings 10, 11, and 13 are closed. Six synchronized
  100-way probes cover
  admission, summary, message, event, tracked-TUI replay, and shutdown. The
  latest Debug graph passes 1,957/1,957; ReleaseFast install passes 9/9. The native two-kernel admission
  proof retains one schedule attempt, one ticket claim, and one matching child
  session under one nonzero generation. Source recovery now generation-fences the
  same durable session. The source Windows lifecycle mesh then proves queue-only
  assignment, TUI detach, exact owner/kernel tree death, lease expiry, a new
  generation, one same-session resume, nested collaboration, one completed ticket,
  and final zero processes. Arbitrary external-effect certainty remains a
  separate P0 boundary.
- Move 26 ships the hive's source mailbox: durable direct/group/parent delivery,
  selective summary/artifact references, nested normal sessions, queue/wake
  intent, and a restart-readable unread cursor. Move 27 adds route-resolved,
  receipt-bound team awareness and proves quiet/hive prompt selection through one
  executor. Move 28 adds one coherent active/idle/queued/admission projection and
  idle-boundary config refresh; its 20-task pressure reaches three concurrent
  calls without exceeding the configured ceiling. A 256-segment audit finds zero
  exact duplicates. Move 29 adds terminal-first same-session resume,
  absent-session requeue, live-owner heartbeat, and cursor-preserving replay; its
  139-segment audit finds zero exact duplicates. Move 30's source process tracer
  records one claim, one resume, two nested children, direct/group/parent delivery,
  six unique received messages, and zero transcript copies at
  `.zig-cache/owner-proofs/ddc238496ee944a2bb586db735e6da2a`; the installed
  lifecycle root is `.zig-cache/owner-proofs/825a25155fa64fe78b26a47789025ec9`.
  Failed and cancelled terminal sessions project `repair_required`; repair closure
  still requires approval, exact rerun, and regression evidence. The installed
  run passes. Move 62 retains arbitrary external-effect certainty.
- `git diff --check` exits 0 with line-ending warnings only.

See [`research/2026-08-12-full-harness-sitrep.md`](research/2026-08-12-full-harness-sitrep.md)
for the complete evidence and [`todo/findings/00-INDEX.md`](todo/findings/00-INDEX.md)
for the executable closure order. The value-ranked implementation order is
[`roadmap/24-harness-capability-next-90.md`](roadmap/24-harness-capability-next-90.md).
[`workspace.json`](workspace.json) carries
the machine-readable boundary and [`../AGENTS.md`](../AGENTS.md) remains the
normative contract.
