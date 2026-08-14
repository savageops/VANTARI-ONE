# VANTARI-ONE Agent Rules

## Mission

VANTARI is a local agent kernel. The product is not a chat wrapper; it is a deterministic execution substrate where prompts compile into session state, provider turns, typed tool spans, context checkpoints, command I/O, and recoverable evidence. `VAR1` is the Zig kernel underneath every client surface.

The objective is frontier-agent parity by mechanical proof, not by UI mimicry. A session is correct only when the operator can observe the same causal chain the kernel will replay after cold start:

```text
input -> append-only transcript -> context compiler -> provider turn
      -> assistant deltas / tool calls -> reviewed effects
      -> typed events -> durable terminal state
```

Every retained subsystem must reduce ambiguity at the call site while increasing guarantees in the core. If a feature cannot identify its owner, state machine, failure class, and recovery evidence, it is not a feature yet.

Roadmap 24 loads the applied prompt-led-autonomy, subtractive-capability,
sequence-addressed-agent-mailbox, and prompt-mode-profile extractions in
`AGENTS.d/extractions/`. The model and prompt envelope own behavioral decisions;
the kernel owns capability truth, durability, budgets, evidence, recovery, and
explicit irreversible-action gates. Evaluate every roadmap item, but add code
only when consolidation or deletion cannot close the canonical consumer path.

## I. Runtime Ownership

- `apps/backend` is the only application/runtime owner. `packages/tui` is a
  tracked vendored platform dependency consumed directly by the backend build;
  validate it through its own test lane, but do not let it own session,
  protocol, or executor state. `apps/frontend` is an ignored local prototype,
  not a shipped client lane in the tracked checkout.
- `VAR1` is the Zig agent-session kernel. CLI, browser, and future desktop shells are clients of the same runtime.
- `.var/` is the only runtime/process state root. Do not add old runtime roots, old storage ownership, or fallback storage readers.
- Project-local `.var/sessions/<session-id>/` is canonical. Do not copy global home-scoped Codex/Claude project-directory session IDs into this repo.
- CLI/TUI/browser clients never assemble provider context, infer tool state, or maintain their own transcript truth. They render kernel-owned state.
- `apps/backend/src/host/owner_client.zig` is the presentation-facing `LocalClient`. It resolves one project-local execution owner, validates its live workspace/generation/protocol/executable identity, and never owns or terminates a kernel child.
- `execution-owner` and foreground `serve` acquire the same crash-released workspace lease and publish one atomic projection at `.var/runtime/execution-owner.json`. Only `apps/backend/src/host/http_bridge.zig` may construct the private `ChildClient` from `stdio_client.zig`; do not add another daemon, pool, scheduler, or reconnect transport.
- `run --session-id` submits through `LocalClient` and `session/send`. Do not reintroduce the deleted per-session `run-session` process or another executor path around the owner.
- An explicit execution-owner workspace is authoritative through `config.loadDefaultForExplicitWorkspace`; inherited `VANTARI_WORKSPACE`, `.env` `WORKSPACE`, and config workspace entries must not redirect its config, auth, ledgers, or owner projection.
- Owner RPC/event/shutdown routes remain loopback-only, token-gated, generation-bound, and exact. Browser routes remain separately token-gated and redacted. A presentation client exit must not change owner lifetime.
- `apps/backend/src/core/tickets/` is the canonical ticket ledger and queue projection. `assigned` admits work; it does not launch a child session.
- Tickets are the only work-lifecycle owner. `sessions/summaries.jsonl` is bounded handoff state; plans, research, advice, roadmap, and changelog entries are ticket-linked artifacts. Do not restore the retired `todo_slice`/`session_record` tools, `.var/todos/` tree, or per-session `session.md` projection.
- `apps/backend/src/core/auth/store.zig` is the sole credential/provider ledger owner. Installed credentials live at `$VANTARI_HOME/auth.json`; workspace credentials live at `.var/auth.json`; nested/AppData paths are migration inputs only. `VAR1 auth status --json` is secret-free, `auth login openai-codex` owns PKCE persistence, and `auth logout <provider-id>` removes one provider without touching unrelated records. OAuth `openai-codex` records route through `apps/backend/src/core/providers/openai_codex.zig` before `wire_api`; API-key records retain the existing OpenAI-compatible path, and no Codex fallback may call `/v1/chat/completions`.
- Ticket execution semantics are not configurable. `agent_routes.max_concurrency`
  is the sole capacity setting; do not restore `tickets.auto_assign`,
  `tickets.proactive_workpool`, or another assignment-to-launch branch.
- `AgentCapacitySnapshot.fromCounts` is the sole pool-count arithmetic owner.
  `running` is active work, `idle = max - running`, `queued` is admitted backlog,
  and `available = idle - queued` saturated at zero. Do not clamp `running` or
  use `idle` as ticket admission headroom.
- A changed `agent_routes.max_concurrency` value replaces the same physical pool
  at its next idle boundary. A busy pool drains and reports its actual prior
  ceiling; do not add a pending-capacity ledger, resizable pool, or second pool.
- `apps/backend/src/core/scheduler/` claims assigned tickets only when `apps/backend/src/core/agents/supervisor.zig` reports fixed-pool capacity, then routes through `core/agents/service.zig`. Do not add a second worker registry or direct assignment launcher.
- `apps/backend/src/shared/process_lock.zig` owns crash-released inter-process exclusion. A scheduler tick holds `.var/schedules/lease.lock`, publishes and reads back one nonzero generation in `lease.json`, and releases only after scheduled-job and ticket mutations finish. Do not restore read/check/write leadership or add a scheduler-local lock primitive.
- `apps/backend/src/core/tickets/index.zig` serializes every ticket projection and mutation through `.var/tickets/ledger.lock`. One claim row commits revision, worker generation, lease, attempt, capability hash, and deterministic child-session identity before session materialization. Do not create a child before the winning claim append or add a second admission ledger.
- `resume` is the sole expired-claim ownership transition. It replaces worker id,
  generation, lease token, and expiry while preserving ticket, attempt, active
  session, execution receipt, transcript, and mailbox cursor. Requeue an expired
  claim only when its active session is absent.
- Reconcile terminal session evidence before expired ownership. Renew heartbeat
  only while the current `Supervisor` owns the exact nonterminal session. Cold
  receipt recovery defers ticket-owned sessions to the scheduler; it must not
  convert them to `StaleAgentOwner`.
- `.docs/index.md`, `.docs/technical_summary.md`, `.docs/workspace.json`, and `.refs/index.md` are the current project-record indexes. Keep them aligned with shipped runtime truth.

## II. Session Storage Contract

Canonical session layout:

```text
.var/sessions/<session-id>/
  session.json
  messages.jsonl
  context.jsonl
  events.jsonl
  output.txt
```

### Storage Semantics

| Artifact | Owner | Invariant |
|---|---|---|
| `session.json` | session lifecycle | One durable lifecycle row for status, parent/continuation, display, and failure state. |
| `messages.jsonl` | transcript ledger | Complete append-only transcript. Never compact, truncate, or rewrite after append. |
| `context.jsonl` | context compiler / compactor | Model-visible checkpoints only. Never become a second transcript. |
| `events.jsonl` | runtime event spine | Ordered observable causality: turn, delta, tool, output, failure, cancellation. |
| `output.txt` | terminal assistant output | Latest assistant terminal projection, not source truth. |

- Every `messages.jsonl` row has a stable ID and monotonic sequence. All message roles route through one per-session append owner whose cold-start sequence is initialized from the last valid tail row; do not restore whole-transcript sequence scans or tool-specific writers.
- Manual `session/compact` is the only live compaction writer. Auto/background compaction requires proven token accounting, cancellation behavior, idempotent range marks, and cold-start recovery.
- Compaction is entry-aware. Checkpoints mark `source_seq_start`, `source_seq_end`, `first_kept_seq`, compacted entry count, and `aggressiveness_milli`.
- Bounded compaction advances over stable JSONL entries. Higher aggressiveness may recompact an already summarized range because the full transcript remains source truth.
- One shared LF-framed JSONL prefix reader owns BOM handling, strict UTF-8/JSON/schema admission, and monotonic sequence checks. Every projection stops at the first invalid row and preserves the prior valid prefix.
- JSONL append refuses a poisoned or torn current suffix before writing. Do not silently skip forward, auto-truncate evidence, or add CRC/quarantine sidecars without a measured corruption class the shared owner cannot express.

## III. Context Compiler Contract

The context builder is the only owner allowed to turn session storage into provider messages.

```text
session.json + messages.jsonl + latest valid context.jsonl
  -> system/runtime context
  -> latest compacted summary
  -> recent raw transcript suffix
  -> provider message window
```

- `loop.zig`, CLI clients, HTTP bridge, and provider adapters must not manually assemble chat history.
- Full transcript retention and model-visible context are separate control planes.
- Context overflow recovery must rebuild through the compiler after checkpoint writes. It must not append in-memory duplicates over persisted tool batches.
- Receipt-addressed child sessions may receive a transient parent projection: the exact parent checkpoint summary plus a bounded recent suffix. Keep the child `messages.jsonl` independent; shard lifecycle rows are graph/recovery evidence and never compiler checkpoints. Do not add transcript copying, a shard registry, or a second context owner.
- The context compiler may repair an orphan tool result or unresolved assistant tool-call tail only in the model-visible projection; it must preserve the append-only transcript and emit one typed `context_compile_diagnostic` with synthesized/skipped counts. Unsupported topology that cannot be repaired must fail before provider dispatch with durable evidence.
- `ContextPolicy.prompt_budget_tokens` is the single estimated system-prompt ceiling. `core/prompts/builder.zig` enforces it before provider dispatch with `PromptBudgetExceeded`; native provider tool schemas remain outside the prompt string and inside full context-window accounting.
- Prompt behavior belongs to hot-loaded layers. The source matrix proves all four modes plus terse/detailed, solo/orchestrated, conservative/aggressive, and low/high-cadence profiles across tool routes without executor branches. `shared/types.zig::TokenPrecision` carries exact provider usage, estimated compiler context, or unknown accounting through the existing turn events; do not present an estimate or partial cumulative total as exact.
- Exact tokenizer integration is admissible only when tests prove approximate heuristics misclassify real provider windows.

## IV. Event Spine And Streaming Mechanics

Typed events are the runtime's nervous system. String breadcrumbs may exist only as legacy read models; new behavior uses versioned event payloads.

### Event Grammar Floor

| Phase | Required Event Shape |
|---|---|
| Turn ingress | `turn_started` / `session_started` with session and prompt boundary evidence. |
| Assistant text | `assistant_delta` chunks before final `assistant_response`. |
| Tool lifecycle | `tool_requested -> tool_reviewed -> tool_started -> tool_output_delta* -> tool_finished -> tool_completed`. |
| Command output | bounded stdout/stderr deltas with stream id, cap marker, and byte-safe payload. |
| Interactive input | `input_requested` persists the bounded question request; `input/respond` resolves one broker wait and the normal tool/terminal span supplies completion evidence. |
| Context compile | `context_compile_diagnostic` with schema `var1.context_compile_diagnostic.v1` when the compiler repairs or skips malformed tool rows. |
| Terminal | exactly one `turn_terminal` with schema `var1.turn_terminal.v1`, the exact `session_started.seq`, and outcome `completed`, `failed`, `timed_out`, or `cancelled`. |

### Directives

- Provider streaming is a kernel contract. If a provider supports SSE deltas, deltas must persist before the final assistant response.
- TTSR stream matches use one `StreamHooks.shouldAbortFn` through the existing provider reader. Check before reads and after delta callbacks; a match must stop terminal settlement, persist the correction plus `rule_injected` evidence, and retry through `loop.zig`. Do not add a provider-specific stream manager or prompt-only retry.
- Interactive `session/cancel` carries `expected_run_seq` equal to the exact observed `session_started.seq`. Missing, unobserved, or stale generations are typed no-ops; shutdown may cancel without a generation only after it fences new admission.
- TUI progress is a read model over `events.jsonl`, not a separate speculative status bus.
- Tool spans update a single keyed row in clients. Do not append request/start/done rows for one tool invocation.
- Child activity uses one keyed `group_id + task_id` row. Tool phases update its typed state marker; the `assistant_response` or existing `update_session_summary` boundary supplies the bounded child turn summary from `sessions/summaries.jsonl`.
- Child group rows show `Agents completed/total` with `○` for queued/running and `◉` for complete; each child row renders only the state, agent name, and latest canonical summary as a bounded quoted suffix. Typed phase and elapsed data remain event evidence, not visible row filler. Later tool/terminal events update the keyed state without replacing the summary. Do not render the removed `waiting on N` filler, expose `tool_completed` as the child's visible summary, or add a chat-bubble event, poller, second ledger, or TUI-owned summary bus.
- Command stdout/stderr are untrusted data. Parse only runtime-owned envelopes; render output as bounded display text.
- Raw command bytes use only `var1.tool_output_delta.v1.chunk_b64` with `tool_call_id`, stream, and cap evidence. Encode through the shared typed protocol serializer; do not add top-level byte fields, raw JSON interpolation, or a payload store while the bounded inline envelope satisfies the runtime cap.
- Event cursors use monotonic ledger position plus replay suppression. Timestamp-only cursors are insufficient under same-millisecond bursts.
- `var1.session_event_notification.v1` carries the exact stored event `seq`. Persist before emission; clients must not replace ledger identity with a transport-local ordinal.
- A client uses stored `seq` as its sole render identity. A transport ordinal drains only its process-local queue; a sequence gap requests the durable `session/get` suffix. Do not add timestamp/text caches or periodic full-event polling.
- Cold TUI hydration renders activity only from sequence-bearing events. A `seq == 0` legacy activity row is ignored; transcript messages remain the cold transcript source.
- TUI footer surfaces use the canonical `styles.surface`, `styles.meta_surface`, and `styles.composer` tokens in strict lightness order. The persistent row carries no cancellation shortcut; `cancelling` is rendered only while `waiting && cancel_requested`, and terminal events clear that transient intent.
- `apps/backend/src/clients/tui_chat.zig::formatFooterMetaWithPool` is the sole footer metadata projection. Its one non-wrapping row orders `status · prompt mode · model · effort · context used/capacity/percent · remaining`; it maps existing `ChatState` status only, marks estimated context with `~`, keeps `ctx — / capacity` for unknown used values, uses codepoint-safe width fitting, and drops lower-signal agent/queue detail before truncating. Do not add a footer registry, gauge, second row, or status bus.
- The same footer owner renders active/max agents, queue pressure, and session cost only when those values carry signal: active/max and queue are nonzero/known or unhealthy, and cost is finite/nonnegative exact `turn_terminal.cost_total_usd`; unpriced or incomplete usage stays omitted. `/status` refuses cumulative totals after an unaccounted completed turn. Do not add a poller, cost registry, event, or second telemetry surface.
- `runtime.log_level` is the chat projection posture and defaults to `silent`; `normal` exposes concise operational checkpoints and `full` permits diagnostic lifecycle detail. It changes TUI filtering and prompt guidance only; `events.jsonl`, `messages.jsonl`, and session recovery evidence remain complete. `config/set` is validated and hot-loaded for the next turn.
- The TUI composer owns a transient registry-backed command palette above the input. It matches the first single token by prefix, accepts bare names while retaining slash compatibility, supports Up/Down/Escape/Tab/Enter, and disappears for prose or no matches. The popup is bounded and uses the existing executable command registry; do not add a second command registry, async scanner, or slash-only requirement. Settings uses the normal Vaxis render/flush boundary, Tab/Right advances, Shift+Tab/Left reverses, and unavailable workspace config falls back to visible compiled defaults.
- `core/config/file.zig::TuiPolicy` owns the finite renderer controls `theme` (`vantari`, `midnight`, `high_contrast`, `amber`) and `status_bar_position` (`bottom`, `top`). `tui_chat.zig` is the sole consumer: it applies the named palette and moves the existing compact status row without adding a menu/layout registry. Settings writes through `config/set` and refreshes the renderer after a successful save; do not add arbitrary per-cell color maps, per-client layout state, or a second config owner.
- `apps/backend/src/clients/footer_effects.zig` owns the optional orchestrate-only footer campaign. It reuses the prompt-mode label, wakes the loop only while the bounded sweep is active, and remains a small renderer/controller rather than a plugin runtime or global animation bus.
- `core/prompts/builder.zig::PromptMode` owns the session-local `orchestrate -> build -> align -> plan` prompt lens. Shift+Tab is a TUI control; the next `session/send` carries its exact lower-case label, omission defaults to `orchestrate`, and unknown labels fail before session/provider execution. `agent_routes.prompt_modes` may select a provider/model and turn budget for one mode through the existing route shape; explicit `session/send` overrides win. The mode must not branch the executor, tool catalog, access policy, or agent capacity.
- `core/sessions/store.zig::commitTurnTerminal` is the only current run-settlement writer. Commit under the event-ledger lock; repeat of the same outcome is idempotent, a stale generation or conflicting outcome fails before append, and session status remains a projection. Treat `turn_finished`, `session_failed`, `session_cancelled`, and related turn-specific names as read-only legacy inputs.
- `ask_user` is a root-only interactive tool. It emits one bounded `input_requested` event, normalizes options to `a`–`f` with `f = Other`, and resolves through `input/respond`; root normal, root-agent, and orchestrator-only catalogs retain it while child profiles remain headless and fail with `InputUnavailable` instead of hanging. The host `InputBroker` is process-local wake state only, keyed by session plus request id; session cancellation and shutdown broadcast to pending waits. Do not add a question overlay, polling loop, resolved-event bus, or child-specific input system.
- `clients/question_view.zig::State` is the one question projection: render bounded batches as settings-style horizontal rows with clamped question/option focus and an explicit review/submit state. `orchestrate`, `build`, `align`, and `plan` share this controller; root normal is a catalog/profile name, not another prompt mode. Vaxis-borrowed question text must remain in State-owned, static, or frame-owned storage until `vx.render`; the display projection sanitizes invalid UTF-8/control text, uses static display keys while preserving response ids, and guards clipped rows. Malformed `input_requested` data is recoverable client input, so report it once and cancel the waiting run without unwinding the TUI event loop. Missing ownership, transport failure, terminal replay, and settled-turn boundaries clear stale input state; active Ctrl-C uses `input/respond` cancellation.

## V. Tool Runtime Contract

Tool capability truth is contractual. Module-owned definitions are the only source for provider schema, catalog JSON, availability, review risk, and dispatch.

```text
definition + availability + review_risk + execute
  -> catalog
  -> provider tool schema
  -> review gate
  -> runtime dispatch
  -> effect/event evidence
```

- Built-in tools are the shipped capability surface. Plugin manifest, isolation, and socket types are contract-only; no plugin tool is model-visible until a concrete future mount path traverses the same definition, availability, review, and dispatch boundary.
- `ToolDefinition.availability` is the module-owned dependency declaration. `core/tools/registry.zig` probes the selected definition and renders live state; it does not maintain a second name-keyed availability table. The same selected definition supplies provider schema, catalog metadata, review risk, and dispatch eligibility.
- `eval` owns one workspace-plus-session persistent Python or Bun kernel. Its bounded line protocol, output cap, timeout termination, and cross-session isolation are runtime invariants; platform-specific executable alternatives belong to the same definition and must be visible in the catalog. `core/tools/process.zig` is the shared bounded child owner for eval and `shell_exec`; do not add call-local evaluators, a second dependency registry, or a parallel process owner.
- `builtin/dap.zig` owns the seven risk-correct DAP sockets, but its adapter client is session-scoped process-local state and must use `core/tools/process.zig::PersistentProcess`; exact Content-Length framing, bounded caps, timeout teardown, and host-join cleanup are mandatory. Do not add a fresh adapter per query, a debugger manager, or a second process owner.
- Tool sockets use lowercase snake_case names and JSON-object parameter schemas.
- Tool discovery is definition-first. The native provider tool schemas are the model-facing API; the operator catalog remains the explicit read model for availability, examples, usage hints, review risk, and exact JSON fields. Do not embed a second human catalog in the prompt or imply hidden tool names or backend-only escape hatches.
- Agent-facing tools and backend-only primitives share one module-owned capability boundary. A primitive becomes agent-reachable only through a registered tool definition, availability contract, review risk, and dispatch path.
- Unknown tools, context-unavailable tools, invalid arguments, and unsupported capability profiles fail before side effects.
- Write-capable tools must emit effect evidence: resolved path, byte counts, hashes where available, operation counts, and error class.
- `write_file`, `append_file`, and `replace_in_file` reserve the session/tool-call identity plus resolved path and before-hash before mutation, then append the measured commit after mutation. Executor/host cold-start reconciliation closes unresolved reservations exactly once as `abandoned`; detached tool calls without a session ledger remain diagnostic-only and do not claim durable effect certainty.
- `shell_exec` is command execution, not shell-shaped convenience. It must preserve argv mode, timeout, output budgets, process termination, and stdout/stderr draining. Its cwd and every agent-facing file/search/LSP path stay workspace-contained unless the explicit `runtime.full_access_mode` setting is true; full access never relocates `.var` runtime state or session ledgers.
- `runtime.full_access_mode` defaults to `false` in `core/config/default.json`. `fsutil.resolveWithAccessMode` is the shared resolver and `ExecutionContext.full_access_mode` is the runtime projection; resolved child routes must carry the same flag into the child execution context so file/search/LSP/shell tools behave consistently; do not add tool-local bypasses or a second access policy.
- `ExecutionContext.capability_profile_id` is the single branch/tool-class permission boundary. `recon` is read-only least privilege, not an OS sandbox; do not add a `sandbox` alias or claim process isolation until a verified Windows-native/container backend provides mounts, lifecycle cleanup, and installed-path proof.
- Search is IX-backed. `search_files` uses the native IX expression contract (`lit:needle`, `re:TODO|FIXME`, `lit:a || lit:b`) through the `ix` executable dependency. If that executable is unavailable, search capability is unavailable; do not add `rg`, `grep`, `sed`, or ad hoc readers as hidden substitutes.

## VI. Parent/Child Agent Orchestration

Sub-agents are normal VAR1 sessions launched by a parent and supervised through typed child-run tools. Delegation exists to reduce latency and increase recon breadth; it is not a parallel authority layer.

- Launch child agents only for branchable work that can progress independently from a self-contained prompt: parallel external research, independent directory/codebase reconnaissance, file-level audits, validation probes, or isolated comparison passes.
- Keep the parent on critical-path synthesis: decide whether delegation is useful, launch children with finite scope, continue any non-overlapping local work, collect child SITREPs, reconcile contradictions, and publish one parent-owned conclusion.
- Child prompts must specify objective, path/scope bounds, allowed evidence, expected SITREP shape, blocker protocol, and terminal success criteria.
- Child SITREPs must return findings, evidence paths/commands, uncertainty, blockers, and residual risk. They do not mutate parent conclusions directly.
- Use `list_agents` for inventory, `agent_status` for non-blocking progress, and `wait_agent` with explicit bounded `timeout_ms` when the parent is ready to collect a result. Avoid repeated tiny wait loops.
- Do not delegate the immediate edit or decision if the parent needs that result before its next local action.
- Child lifecycle state is append-only session/event evidence. Parent supervision must preserve heartbeat, terminal status, failure class, and resume-safe reconciliation.
- Canonical child launch persists parent checkpoint identity in the immutable execution receipt. `Supervisor` owns terminal reservation and returns one bounded branch result through the existing shard checkpoint and mailbox owners; do not add a branch worker, group transcript, or parallel convergence bus.
- Ticket assignment, scheduler claims, leases, live-owner heartbeat, generation-fenced same-session resume, absent-session requeue, terminal reconciliation, and repair gating remain one typed queue-to-agent state machine; health fields are a read projection only.
- Ticket assignment remains side-effect-free. A winning process-serialized claim reserves one deterministic child identity; only that winner may materialize and submit the child through the existing `AgentService`/`Supervisor` path.
- `agents {}` is the sole model-facing eligibility snapshot: route-resolved specialists, fixed-pool pressure, current-team aggregates, communication choices, and a deterministic SHA-256 receipt. Treat it as evidence, not an instruction to delegate. Require it before launch or agent-configuration mutation, but never mandate it as the first action of a turn.
- Agent collaboration uses one sequence-addressed mailbox through the existing session/event owners. Permit direct-session, parent, and current-group targets; do not add a generic topic broker, shared global transcript, or second teammate runtime.
- Mailbox messages carry bounded information and references. Tickets remain the only work lifecycle: a message never silently assigns, claims, or launches work.
- Let the prompt envelope choose communication density, challenge posture, wake intent, and nested delegation. The kernel validates sender/recipient scope, capacity, depth, contact budget, ordering, delivery, replay, and acknowledgement.
- Give each session selective awareness through agent inventory, canonical summaries, artifact references, and unread mailbox rows. Do not copy sibling transcripts into provider context.
- Treat same-session resume as exactly one durable work identity and delivery
  position, not exactly-once arbitrary external effects. `core/tools` write-intent
  and effect reconciliation remains the owner of effect certainty.
- Prove owner-loss recovery with `scripts/prove-ticket-lifecycle.ps1`: queue-only
  assignment, one claim, exact owner-tree death, generation change, same-session
  resume, nested mailbox delivery, terminal reconciliation, and zero proof-owned
  processes. Source proof does not satisfy installed promotion; require the same
  tracer against the hash-matched installed binary.

## VII. Skill Routing Contract

Skills are operating protocols. Tools execute actions; skills choose method, evidence shape, validation discipline, and when to read deeper instructions.

Native high-leverage skills:

| Skill | Use When |
|---|---|
| `planning-spec` | Work requires decomposed execution chains, state-machine handoff, invariant preservation, or crash recovery. |
| `insect` / `insect-rs-runtime` | External research, crawling, scraping, search extraction, web scouting, or YouTube transcript retrieval. |
| `dupe-audit` | Large implementations, refactors, parity checks, related-code discovery, or duplicate ownership risk. |
| `recon-intel` | Unfamiliar code areas, orchestration/storage/auth/runtime changes, or stale/duplicated architecture suspicion. |
| `ux-playbook` | TUI/browser/frontend layout, hierarchy, disclosure, feedback, or operator workflow design. |
| `t3-tape` | PatchMD/T3 Tape state, patch import/export, validation, migration, or hook governance. |
| `repo-harvester` | Global source corpus harvesting and indexed repository collection work. |
| `task-audit` | Findings-first implementation correctness review. |

- The prompt may include compact native skill capsules.
- `skill_info` is the retrieval primitive for exact skill capsules. Do not inject every global `SKILL.md` into the prompt.
- Add-on skills are discoverable. Treat them as demand-loaded protocols, not always-on prompt mass.
- A skill request is not satisfied by naming the skill. The task must route into the skill's execution contract.

## VIII. Future-First Architecture

- Build the invariant that should survive later runtime scale, not the dominant implementation pattern that exists now.
- Study references for failure modes, boundary shapes, and useful invariants only. Do not reproduce incidental architecture.
- Prefer primitives that are smaller and more expressive: append-only ledgers, typed checkpoints, explicit state machines, deterministic readers, bounded allocators, and crash-recoverable writes.
- A dynamic worker is admissible only when it calls the same proven primitive as manual execution and adds measurable capability beyond scheduling.
- Health, readiness, and diagnostics stay thinner than capability. They expose enough state to operate the system; they do not become a parallel product.

## IX. Source Hierarchy

- Prefer deep, named ownership modules over flat file sprawl. Do not create empty folder theater.
- New context work belongs under `apps/backend/src/core/context/`.
- Core modules are kernel-owned capability domains such as `context`, `sessions`, `tools`, `providers`, and `agents`.
- Tool runtime contracts belong under `apps/backend/src/core/tools/`. The runtime body is `src/core/tools/runtime.zig`; do not reintroduce flat `src/tools.zig`.
- Session storage helpers live under `apps/backend/src/core/sessions/`.
- Plugin contract code belongs under `apps/backend/src/core/plugins/`. Plugin implementations must not live inside `core/`.
- Keep protocol/shared types in `shared/` only when multiple clients or hosts consume them.

## X. Mechanical Cost Model

This repository prices changes against runtime mechanics, not aesthetics.

| Mechanism | Cost Center | Required Question |
|---|---|---|
| Provider turn | network latency, stream parse, tool-call reconstruction | Does the operator see deltas before terminal output? |
| Context compile | JSONL scan, checkpoint selection, allocation, provider payload bytes | Is the window built once through the compiler and replayable after cold start? |
| Tool dispatch | review gate, schema parse, side effect, event append | Is the effect reserved, executed, and evidenced in one causal span? |
| Command run | process spawn, pipe draining, timeout, kill, output cap | Are stdout/stderr visible while the process runs and bounded at source? |
| TUI frame | event replay, wrapping, terminal render, scroll state | Does the interface preserve transcript comprehension under live updates? |
| Session recovery | prefix salvage, stale owner reconciliation, terminal status | Can a dead process leave the next client with truthful state? |

Directive: before adding abstraction, name which cost center it lowers. If the answer is "organization", keep the code local until duplication or boundary pressure becomes measurable.

## XI. Reference Discipline

- Use `ix` for repository search in this checkout.
- Before intricate kernel changes, inspect `.refs/openai__codex`, `.refs/badlogic__pi-mono`, and `.refs/prime-intellect__prime-agent`.
- Tracked competitors and harvest sources:
  - `.refs/openai__codex` — OpenAI Codex CLI. Safety-first enterprise prompt discipline; typed context segments; `apply_patch` format contract; `update_plan` plan-state primitive. Harvest: segment-per-concern architecture, AGENTS.md scope precedence.
  - `.refs/badlogic__pi-mono` — can1357's pi-mono. Maximalist power-user leanness; tool-derived guidelines; compaction token math (`reserveTokens`/`keepRecentTokens`); demand-loaded skills. Harvest: registry-driven prompt truth, minimal identity, code-owned context lifecycle.
  - `.refs/prime-intellect__prime-agent` — Prime Intellect's prime-agent (TS host + Python RLM runtime). Recursive Language Model thesis: persistent IPython kernel as tool surface; `await rlm('subtask')` delegation from inside Python; Continual Harness + `/refine` self-improvement with baseline conflict detection and rollback; daemon-backed long-running sessions with goals, heartbeats, cron schedules, agent-to-agent messaging; crash-recovery journals with tick claiming and missed-tick coalescing. **Note: the TS kernel is upstream `@earendil-works/pi-coding-agent`; Prime Intellect's original contribution is the RLM runtime + harness + daemon layer.** Harvest targets: persistent programmable tool namespace pattern, typed refinement with conflict detection, tick-claim-before-delivery idempotency. Reject: no security sandbox (model Python runs with user permissions); `chars/4` compaction heuristic (no deterministic context compiler); no byte-level session integrity hardening. VANTARI must be 2x better on: context compiler determinism, event spine + tool-span grammar, byte-level session integrity, shell/tool discipline, Windows-native installed-binary proof.
- Copy ownership patterns, not complexity. Borrow checkpoint boundaries, item lifecycle pressure, and context ownership; reject extension forests, branch graphs, and global session stores until proven necessary.
- Every reference-harvested idea must pass the VANTARI compression test: fewer concepts at the call site, stronger guarantees in the core, lower runtime ambiguity, clearer recovery evidence.
- Comparable-agent parity means live assistant deltas, typed tool lifecycle spans, bounded process I/O, resumable ledgers, cancellation semantics, and cold-start replay before decorative UI or optional extension systems.

## XII. Forbidden Anti-Patterns

- Parallel systems for the same responsibility.
- Hidden fallback readers, hidden provider paths, or late runtime crashes for unsupported capability.
- Prompt scaffolding leaking into product UI.
- Tool schema drift between template, runtime, API endpoint, and frontend optimistic state.
- Diagnostics fatter than the capability being diagnosed.
- Timestamp-only event replay.
- Background workers without cancellation, idempotent marks, measurable benefit, and cold-start reconciliation.
- Broad rewrites driven by intuition instead of a named state transition or measured bottleneck.
- "Green" tests that exercise removed routes, mocks, stale fallback paths, or non-canonical runtime lanes.
- Shell workarounds for contracts that should exist as typed kernel capability.

## XIII. Proof-Gated Promotion Lifecycle

Every non-trivial runtime change follows:

```text
Recon -> Contract -> Smallest durable slice -> Canonical tests
      -> Native installed proof -> Event/session evidence -> Docs/changelog
```

Promotion gates:

1. The changed capability is implemented end-to-end through the canonical runtime lane.
2. Tests cover the user-visible pipeline and at least one falsification pressure case.
3. No duplicate ownership, prompt-only behavior, or parallel state surface is introduced.
4. Windows-native installed binary proof exists for user-facing changes.
5. Session/event evidence proves the claimed runtime behavior when provider/tool execution is involved.
6. Public docs describe shipped runtime truth, not intended future state.

Rejection protocol:

- Record the hypothesis.
- Name the exact seam.
- Keep the failed evidence.
- Remove the rejected code path.
- State the next mechanism to investigate.

## XIV. Testing Integrity

Invoke every Zig test through `apps/backend/scripts/zigw.ps1` or
`apps/backend/scripts/zigw.sh`. Both `zig build test` artifacts and direct
`zig test` invocations must receive a generated `VANTARI_HOME` plus
`VANTARI_TEST_ROOT`; no test process may inherit the production runtime root.

Tests must behave like adversarial pipeline probes:

- corrupted JSONL suffixes
- stale running sessions
- failed no-prompt resumes
- invalid tool batches
- orphan tool results
- duplicate context after provider overflow
- command timeout and process locks
- stdout/stderr cap markers
- oversized write payloads
- cwd escape before process launch
- same-millisecond event bursts
- 100-way admission, ledger append, exact replay, and admission-fenced shutdown
- terminal scrollback under live streaming
- installed binary auth/workspace resolution

A passing test is valuable only when the assertion proves an invariant a shallow implementation would violate.

## XV. Windows-Native Runtime Discipline

- WSL or POSIX success may support analysis. It is not shipped proof for user-facing Windows behavior.
- Operator scripts must diagnose locked installed binaries and stale local processes before failing obscurely.
- Process supervision must account for Windows handle lifetime, pipe draining, timeout, and child termination.
- `apps/backend/src/shared/process_tree.zig` is the shared Windows child-tree owner. Reuse its Job Object and bounded wait/drain primitives; do not add subsystem-local Job Object bindings.
- Installed `%LOCALAPPDATA%\Vantari\bin\vantari.exe` proof is mandatory after CLI/TUI/provider/workspace/auth changes.

## XVI. Communication Standard

Every output in this repository is calibrated for experienced systems engineers.

- Say `append-only event spine with monotonic replay cursor`, not "status updates".
- Say `context compiler from transcript/checkpoint ledgers`, not "chat history".
- Say `tool span with reviewed side effect and bounded stdout/stderr deltas`, not "tool ran".
- Say `provider SSE delta reconstruction`, not "streaming response".
- Say `stale owner reconciliation`, not "session cleanup".

Capability claims carry mechanism and proof. "Works" is not a mechanism. "Fast" is not a unit. "Safer" is not an invariant.

## XVII. Definition Of Done

- Capability implemented end-to-end.
- State machine named: ingress, mutation, emission, persistence, recovery, terminal state.
- Tests cover changed contract and negative pressure.
- No architecture drift or parallel systems introduced.
- UX/state lifecycle parity preserved for operator-facing surfaces.
- Docs/changelog updated in `.docs/todo/changelog/_log.md`.
- Large implementations run dupe-audit or explicitly justify deferral.
- Native installed binary validated for user-facing changes.
- Handoff is cold-start ready from repository state.

## XVIII. Frontier Roadmap

1. Typed turn/item event grammar: extend the shipped versioned `turn_started`, `assistant_delta`, tool-span, and single `turn_terminal` grammar without reintroducing outcome-specific terminal event names; keep legacy readers read-only.
2. Binary-safe event spine: store event payloads as canonical JSON plus optional base64 byte fields, stable sequence numbers, monotonic causal order, and replay cursors.
3. Tool execution spans: every tool call gets start/end timestamps, duration, risk decision, capability owner, output caps, side-effect summary, and failure class.
4. Interruptible process supervision: long commands support timeout, operator cancellation, stdout/stderr draining, process-tree termination, and post-kill evidence.
5. C ABI acceleration socket: add a narrow `extern` boundary only after profiling identifies a real bottleneck; candidate domains are tokenizer probes, SIMD search, JSONL scanning, and terminal width/grapheme kernels.
6. Arena/quota discipline: split allocators by turn, provider payload, tool result, and UI frame.
7. Deterministic context compiler: context assembly is a replayable compiler with typed compile diagnostics before provider dispatch; unrecoverable topology remains a typed failure.
8. Tool-result structural diffing: file mutation tools emit compact effect records with before/after metadata, byte counts, hashes, and optional localized hunks.
9. Write-intent ledger: write-capable tools reserve intent records before mutation, commit effect records after mutation, and reconcile abandoned intents at cold start.
10. Frontier TUI workbench: terminal renders live item graph, bounded child turn summaries, assistant token stream, tool spans, command output, cancellation affordance, session navigation, pool/queue metadata, and optional raw event inspection.
11. Provider capability probing: adapters cache verified streaming, tool-call shape, max payload, refusal/error envelopes, and context overflow signatures; unknown capability fails closed.
12. Agent delegation supervision: parent sessions track child runs through typed edges, scoped capability profiles, heartbeat events, terminal status reconciliation, sequence-addressed direct/group/parent mail, and resume-safe wait semantics; ticket claims feed the same fixed pool without a second scheduler.
13. Deep pipeline test mesh: adversarial suites for provider recovery, tool loops, context rebuilds, TUI event consumption, installed auth/workspace resolution, and Windows process behavior.
14. Byte-level session integrity: JSONL append/read paths detect torn writes, BOMs, invalid UTF-8, duplicated sequence IDs, and poisoned trailing rows without corrupting valid prefix state.
15. Local performance telemetry: measure token compilation, JSONL scan, event replay, terminal frame render, process spawn, and tool dispatch latencies with low-noise counters gated behind explicit commands.
16. Reference pressure loop: periodically re-harvest `.refs/openai__codex`, `.refs/badlogic__pi-mono`, and `.refs/prime-intellect__prime-agent`, but land only primitives that reduce VANTARI surface complexity while increasing runtime proof strength.
