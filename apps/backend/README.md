# VAR1 Zig Kernel

`VAR1` is the Zig kernel that runs Ventari 1 agent sessions. It owns session storage, context construction, provider transport, tool dispatch, and bridge events so the CLI and browser use the same harness behavior.

This app is the only live backend lane in the repository. Operators use the CLI, browser users talk through the bridge, and agent-session state stays inside `.var/sessions`.

## At a glance

| Surface | Current contract |
| --- | --- |
| Executable | `VAR1` |
| Hidden host | `kernel-stdio` |
| CLI owner | `src/clients/cli.zig` |
| Browser bridge | `src/host/http_bridge.zig` |
| Protocol | JSON-RPC 2.0 over stdio with Content-Length framing |
| State root | `.var/sessions/<id>/` |
| Provider boundary | `src/core/providers/openai_compatible.zig` |
| Tool runtime | `src/core/tools/runtime.zig`, `src/core/tools/registry.zig`, `src/core/tools/builtin/*.zig` |
| Capability governance | `src/core/tools/review.zig`, `src/core/agents/profile.zig`, `src/core/agents/scope.zig` |
| Memory/evaluation boundary | `src/core/memory/derivative.zig`, `src/core/evaluation/events.zig` |

## What ships

- `VAR1 run` for direct prompt execution.
- `VAR1 health` for provider and runtime readiness.
- `VAR1 tools` for the built-in schema and availability catalog.
- `VAR1 serve` for the browser-facing bridge:
  - `POST /rpc`
  - `GET /events`
  - `GET /api/health`

There is no old HTTP facade or storage migration path. New checkouts start directly on the session contract.

## Canonical session contract

Each durable run lives under `.var/sessions/<id>/`:

- `session.json`
- `messages.jsonl`
- `memories.jsonl`
- `context.jsonl`
- `events.jsonl`
- `output.txt`

`messages.jsonl` is the append-only session transcript, including assistant tool-call turns and tool-result rows. `context.jsonl` is the compact checkpoint history produced by `core/context/compactor.zig` and consumed by the context builder; it is not a second full transcript.

Session ids remain opaque. The store mints `session-...` ids for new runs.

## Layered ownership

Runtime code is physically partitioned by ownership under `src/`:

| Layer | Canonical namespace | Owners | Responsibility |
| --- | --- | --- | --- |
| `shared` | `VAR1.shared` | `shared/types.zig`, `shared/fsutil.zig`, `shared/protocol/` | contracts, filesystem helpers, wire payloads |
| `core` | `VAR1.core` | `core/config/`, `core/sessions/`, `core/executor/`, `core/providers/`, `core/tools/`, `core/agents/`, `core/auth/` | execution, state, provider transport, tools, delegation, auth resolution |
| `host` | `VAR1.host` | `host/stdio_rpc.zig`, `host/http_bridge.zig`, `host/bridge_access.zig` | stdio RPC host, HTTP bridge, local browser access policy, and durable bridge audit sink |
| `clients` | `VAR1.clients` | `clients/cli.zig`, `clients/tui_chat.zig` | protocol-backed CLI and terminal read model |

The browser client lives outside the kernel at `apps/frontend/var1-client`.

## Tool runtime

The current tool surface is compiled into the `VAR1` binary. Tool definitions use the shared `ToolDefinition` shape: name, description, `parameters_json`, optional example, and optional usage hint. Built-in file and agent tools live under `src/core/tools/builtin/`; each module exports `definition`, `availability`, and `execute`. `src/core/tools/runtime.zig` composes those modules for catalog rendering and dispatch, `src/core/tools/registry.zig` resolves availability from module-owned tool names/specs, and `src/core/tools/module.zig` owns shared execution contracts. `src/core/executor/loop.zig` injects the context-filtered definitions into provider requests; `src/core/providers/openai_compatible.zig` writes them as OpenAI-compatible function schemas. This catalog is the agent-facing tool truth: backend-only primitives become reachable only after a module-owned definition, availability contract, review risk, and dispatch path exist.

`VAR1 tools --json` and the JSON-RPC `tools/list` method expose the same catalog. That catalog includes availability metadata, so installing clients can distinguish shipped schema from currently usable capability. Runtime argument parsing rejects undeclared tool parameters, matching the advertised `additionalProperties:false` schema contract. Mutating file-tool responses preserve the stable `ok/tool/content` envelope and add a typed `effect` receipt when a workspace file changes.

File tools are split by role:

- `list_files` is native Zig workspace discovery.
- `search_files` is content search, declares an `external_command("iex")` dependency, invokes the executable as `iex search --json`, and expects native IX/IEX expressions rather than rg/grep flags.
- `read_file`, `write_file`, `append_file`, and `replace_in_file` operate on exact workspace-relative paths.

An installed runtime must provide a real `iex` executable for `search_files`. PowerShell aliases are not enough for the Zig child-process runner. If `iex` is absent, search is unavailable at the command dependency boundary, `VAR1 tools --json` reports that state, and execution fails early with `ToolUnavailable` instead of surfacing a late child-process surprise.

`write_file`, `append_file`, and `replace_in_file` return `effect.schema_version = "var1.tool_effect.v1"` with the requested path, resolved path, before/after byte counts, operation-specific counts, and SHA-256 hashes for existing file contents. Their model-visible `content` begins with `EFFECT_SCHEMA var1.tool_effect.v1` and `EFFECT_KEY effect`, then carries the legacy `PATH`/`BYTES` output for compatibility. This is the lightweight verification layer for small-model and bridge-facing workflows: the runtime proves the file effect at the tool boundary without introducing a separate evaluator loop.

`src/core/tools/sockets.zig` and `src/core/plugins/manifest.zig` are validation boundaries for typed sockets and plugin manifests. They do not load plugins, auto-discover plugin roots, or mutate the model-visible tool list.

## Capability governance

The executor now has a review-before-effect state transition for tool calls. `src/core/executor/loop.zig` appends `tool_requested`, passes the active `ToolDefinition` catalog into `src/core/tools/review.zig`, appends `tool_reviewed`, and then either dispatches through `src/core/tools/runtime.zig` or appends `tool_blocked` with a protocol-visible denial result. Risk classification comes from each module-owned `ToolDefinition.review_risk`; the blocked path preserves the provider tool-message contract while preventing unknown or context-unavailable tools from reaching an implementation branch.

Agent orchestration is catalog-first. In `agents.orchestrator_only` mode, the root receives only `agents`, `launch_agent`, `configure_agent`, `list_agents`, `agent_status`, `wait_agent`, and `cancel_agents`; its first tool call must be `agents {}`. That compact hot-loaded catalog exposes selection fields without loading private child instructions into the parent window. `launch_agent` accepts one `{ context, tasks[] }` batch, and every task chooses an id from the latest catalog. `configure_agent` atomically upserts, disables, or resets `config.json.agents.definitions` and the next `agents` or launch call reloads it without a process restart.

`src/core/agents/spec.zig` fixes each built-in capability floor and allows custom ids only through `extends`. `src/core/providers/routes.zig` maps route roles to provider, model, wire API, thinking mode, and budgets. `src/core/agents/supervisor.zig` owns bounded in-process admission, first-result wakeups, cancellation, and exactly-once convergence. A child receives only its private instruction capsule, explicit shared context, finite task, and output contract; it never inherits the parent transcript. The parent may park with zero provider calls or continue independent orchestration work. When the first terminal child becomes ready, the kernel appends one bounded convergence record, rebuilds the parent through the context compiler, and resumes automatically while unfinished siblings remain supervised.

The TUI projects tools and children through one nested activity grammar. Search, Explore, Agents, and To-dos use the same pending `[ ]`, running `[>]`, completed `[x]`, failed `[!]`, and cancelled `[-]` markers. Typed child and tool-output items render under their stable group row with `|--` / `` `--`` rail connectors. Replayed events rebuild the same rows after cold start; there is no client-owned status bus or fake timer state.

Memory and evaluation stay evidence-bound. `src/core/memory/derivative.zig` defines derivative memory entries that cite `session_id`, `source_seq_start`, and `source_seq_end`, and rejects transcript replay-shaped summaries. `src/core/evaluation/events.zig` appends redacted `runtime_heartbeat`, `evaluator_result`, and `runtime_unsupported_behavior` events; evaluator results carry `executor_mutation:"forbidden"` and never mutate loop state through a side channel.

Unsupported MAS-derived behavior is explicit: RecursiveMAS-style latent transfer, GRASP gradients, dynamic markets, autonomous background evolution, exact tokenizer integration, and plugin auto-discovery are not shipped runtime behavior.

## Quick start

Build, test, check provider readiness, then run one prompt:

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
```

## Commands

### CLI

```powershell
.\zig-out\bin\VAR1.exe run --prompt "Count the lowercase letter r in strawberry."
.\zig-out\bin\VAR1.exe run --prompt-file .\prompt.txt --json
.\zig-out\bin\VAR1.exe run --session-id session-1776778021956-42e781c4c8b4efb8
.\zig-out\bin\VAR1.exe health --json
.\zig-out\bin\VAR1.exe tools --json
.\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
```

### Browser client

1. Start the bridge:

   ```powershell
   .\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
   ```

2. Serve the static browser client from an explicit local HTTP origin.

   ```powershell
   cd ..\..\frontend\var1-client
   python -m http.server 5173 --bind 127.0.0.1
   ```

3. Open `http://127.0.0.1:5173` and point the client at `http://127.0.0.1:4310`.

The browser client uses only `POST /rpc`, `GET /events`, and `GET /api/health`. Startup reads `/api/health` first, stores the returned `bridge_token`, and sends it as `X-VAR1-Bridge-Token` for `/rpc` and `/events`.

## Session flow

### New session

1. `session/create`
2. `session/send`
3. kernel executes the run loop
4. bridge/client hydrates detail through `session/get` or `session/list`

### Follow-up on the same session

1. `session/send { session_id, prompt }`
2. the new user message appends to `messages.jsonl`
3. the context builder creates the model-visible view from the latest checkpoint plus recent raw messages
4. the next assistant output appends to the same session

### Manual compact

1. `session/compact { session_id, keep_recent_messages?, max_entries_per_checkpoint?, aggressiveness?, trigger? }`
2. the context compactor selects an older message entry or bounded range by stable `seq`
3. a structured summary checkpoint appends to `context.jsonl` with `aggressiveness_milli` and `compacted_entry_count`
4. repeated calls advance from `first_kept_seq`; higher aggressiveness recompacts the covered range from `messages.jsonl`
5. the next `session/send` keeps the checkpoint plus the recent raw suffix model-visible

### Resume

1. `session/send { session_id }`
2. the kernel reuses the stored prompt and transcript for that session

## Bridge behavior

`VAR1 serve` owns only transport projection.

- `/rpc` forwards JSON-RPC requests to the hidden stdio kernel host
- `/events` returns SSE-compatible event snapshots for session notifications
- `/api/health` is the local readiness and bridge-token handshake route
- `/` is bridge-only text that points operators at `apps/frontend/var1-client`

The bridge binds to `127.0.0.1` by default. `host/bridge_access.zig` owns the local-origin allowlist, token guard, bridge-visible key-and-value redaction, audit-action classification, and append-only audit emission to `.var/audit/bridge.jsonl`; `host/http_bridge.zig` owns route and connection transport, accepting each socket into a detached worker so long RPC/event requests do not serialize the listener. Health, error, RPC, and event payloads share the same secret-shaped value redactor before reaching the browser. Session, auth, and write-capable RPC actions use the `var1.bridge_audit.v1` event schema and fail closed if the audit sink cannot persist the event. No kernel-owned HTML is served from `src/`.

## Scripts

Windows-native operator scripts remain the primary lane:

```powershell
.\scripts\zigw.ps1 build test --summary all
.\scripts\health.ps1
.\scripts\local_gemma_smoke.ps1
.\scripts\local_gemma_smoke.ps1 -ExpectedModel gemma-4-e2b-it -AllowSanityMismatch
```

Shell wrappers remain available:

```bash
./scripts/zigw.sh build test --summary all
./scripts/health.sh
./scripts/local_gemma_smoke.sh
```

The smoke lane now proves:

- direct CLI execution
- delegated child-session execution
- bridge health and canonical bridge routes
- bridge-only root response
- external browser client presence at `apps/frontend/var1-client`

Before the first prompt run, the smoke scripts verify that the configured provider is reachable, that the expected model is actively served by the authenticated `/v1/models` surface, and that effective `VAR1 health` agrees with the expected runtime model. `-ExpectedModel` is optional for the default configured model and explicit for small-model probes. `-AllowSanityMismatch` keeps transport, tool, and bridge checks running when a deliberately weaker model misses the strawberry sanity answer, while still reporting that answer as an unverified model-capability result.

## Configuration

`.env` keys:

- `BASE_URL`
- `API_KEY`
- `MODEL`
- `MAX_STEPS` is optional and defaults to `32`
- `MAX_TOOL_CALLS_PER_TURN` is optional and defaults to `16`
- `MAX_TOOL_CALLS_PER_SESSION` is optional and defaults to `96`
- `WORKSPACE` is optional and defaults to `.`

Use `.env.example` only as a bootstrap template. Installed runtime state uses two sibling files under `$VANTARI_HOME` (normally `~/.vantari`): `auth.json` owns credentials/providers and `config.json` owns non-secret runtime policy. Legacy `.var/auth/auth.json`, nested `auth/auth.json`, and AppData auth files are migration inputs, not live owners.

```text
~/.vantari/
  config.json
  auth.json
```

`vantari config path|show|init|validate` exposes the non-secret configuration owner. The standards-valid JSON template documents every value through adjacent `_help` maps and records ownership/precedence in `_about`; these keys are validated metadata and never runtime policy. `agents.definitions` carries editable specialist personas, conditional `when_to_use` text, route roles, bounded budgets, and output contracts; credentials and arbitrary tool grants are rejected. The Windows installer retains valid operator config verbatim. When an older invalid v1 file cannot load the current schema, it writes a timestamped byte-identical backup, materializes the complete template, preserves the known `context.auto_compact` setting as `auto_compaction`, and validates before keeping the migration. Process environment values override the matching `config.json.environment` entries. API keys remain in `auth.json` and are never rendered by config commands.

The step policy and tool-call policy are separate controls. `MAX_STEPS` limits provider turns; `MAX_TOOL_CALLS_PER_TURN` and `MAX_TOOL_CALLS_PER_SESSION` limit the number of tool effects the model may request before dispatch. The context policy controls only model-window behavior. `messages.jsonl` stays append-only, `context.jsonl` stays the checkpoint ledger, manual `session/compact` remains available when `manual_compaction = true`, and executor auto-compaction calls the same compactor when estimates or provider overflow require a smaller model-visible window.

Prompt policy controls only user-editable model instructions. `src/core/prompts/` always wraps those optional files with a hidden kernel guardrail layer and the current tool-use contract. The runtime-owned contract requires bounded action bursts: state one observable step, act through a tool or delegation, inspect evidence, emit a compact checkpoint with changed state/proof/blocker/next action, then continue until terminal proof or a named blocker. Checkpoints are operator-visible transcript/context history, not private chain-of-thought, and remain present when project system/developer prompt files override the defaults. Prompt paths are workspace-relative JSON strings; null uses the built-in layer, while missing, empty, absolute, or mistyped configured values fail closed.

## Files worth reading first

- `src/root.zig`
- `src/clients/cli.zig`
- `src/host/stdio_rpc.zig`
- `src/host/http_bridge.zig`
- `src/host/bridge_access.zig`
- `src/core/executor/loop.zig`
- `src/core/context/builder.zig`
- `src/core/context/compactor.zig`
- `src/core/context/budget.zig`
- `src/core/context/overflow.zig`
- `src/core/prompts/index.zig`
- `src/core/sessions/store.zig`
- `src/core/tools/module.zig`
- `src/core/tools/review.zig`
- `src/core/tools/registry.zig`
- `src/core/tools/builtin/`
- `src/core/agents/spec.zig`
- `src/core/agents/supervisor.zig`
- `src/core/agents/profile.zig`
- `src/core/agents/scope.zig`
- `src/core/providers/routes.zig`
- `src/core/memory/derivative.zig`
- `src/core/evaluation/events.zig`
- `tests/`
- `../frontend/var1-client/`

## Current posture

This lane is now session-native end to end:

- store
- context builder
- context compactor
- context budget and overflow policy
- executor
- tool module registry and availability catalog
- tool review gate with `tool_reviewed` / `tool_blocked` events
- scoped delegation and typed capability profile contracts
- derivative memory and non-mutating evaluator event boundaries
- protocol types
- stdio host
- local bridge origin/token/key-and-value redaction plus durable audit guards
- CLI
- smoke scripts with stale local process diagnostics
- tests

No compatibility facade or old-layout storage reader remains in this lane.

Latest local Windows validation on 2026-05-04:

- `.\scripts\zigw.ps1 build test --summary all` -> `95/95 tests passed`
- `.\zig-out\bin\VAR1.exe tools --json` -> `search_files` includes `external_command` dependency availability for `iex`
- `.\scripts\health.ps1` -> `status: ready`
