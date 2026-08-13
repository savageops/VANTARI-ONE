---
type: technical-summary
id: docs/technical-summary
status: current
updated: 2026-08-13
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

## Current frontier — Move 45

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
capacity renders `ctx —`, while known capacity preserves exact used/capacity,
rounded percent, and remaining tokens. Candidate fitting uses codepoint width,
keeps status/mode/model ahead of optional agent/queue detail, and ends with a
bounded codepoint-safe truncation.

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

The accepted prompt-mode contract names `orchestrate`, `build`, `align`, and
`plan`, with `orchestrate` as the default. Shift+Tab cycles the session-local
selection and the next `session/send` applies one hot-loaded provider-visible
layer. A mode changes guidance only, not executor, tool capability, access
policy, or agent capacity. Broader behavior-profile proof remains a later
roadmap boundary.

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

- The footer is one compact metadata row: model, effort, context used/capacity/percentage, remaining capacity, active agents, pool pressure, and assigned queue pressure when non-zero. `Esc cancel` is intentionally omitted from the persistent row.
- The footer background tokens are ordered `styles.surface < styles.meta_surface < styles.composer`; the composer is the focused input row above metadata, and `cancelling` is emitted only while an active run is waiting on cancellation.
- A child group row is `Agents completed/total`. The old `waiting on N` filler is removed from the visible structure; terminal failure/cancellation evidence may remain as a suffix.
- A child row is keyed by `group_id + task_id`. Tool lifecycle events update its state marker but do not become the row label.
- At the child `assistant_response` boundary, the supervisor reads the canonical session summary and sends it as the row detail. The TUI compacts whitespace and truncates the summary to the available one-line width, so the visible row is `agent-name - summary…`, not `agent-name - tool_completed`.
- The projection is replayable from typed parent events. It does not scan child transcripts or create a second activity registry.

## Agent access boundary

`runtime.full_access_mode` is `false` by default. The setting propagates from validated config through route/executor copies into `ExecutionContext`; file, search, LSP, and process tools resolve through `fsutil.resolveWithAccessMode`. Restricted mode enforces workspace containment. Explicit full access permits absolute paths and `..` traversal for intended external directories while keeping relative paths anchored at the active workspace. `.var` runtime state, session ledgers, and configured prompt files retain their canonical owners.

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
- The complete graph passes 19/19 steps and 1,998/1,998 tests with zero skips.
  The reduced total is intentional: one registry loop executes all 53 declared
  cases and replaces 45 one-case wrappers that left ten cases undiscovered.
  Its host lane executes the stdio child, owner state/client, shared process
  lock, bridge, and process-tree contracts; the integration lane includes
  exact owner route, lease, stalled-loopback deadline, and explicit-workspace
  precedence probes. The backend
  TUI lane passes 77/77.
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
