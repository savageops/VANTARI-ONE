# 21 — Plugin Contract Surface

**Priority: P1**

## The seam

A plugin is an opt-in capability contribution that must never silently alter the model-visible tool list (`AGENTS.md` §V). The seam is the boundary between *the built-in capability surface*, which is always present and catalog-first, and *plugin-contributed capability*, which appears only when an operator explicitly mounts it and only ever through the same module-owned `ToolDefinition` → catalog → review-gate → dispatch path the built-ins use.

The contract has three load-bearing invariants. First: a `ToolDefinition` is the single source of truth for provider schema, catalog JSON, availability, review risk, and dispatch — there is no parallel "plugin tool" shape, only plugin-owned instances of the built-in shape. Second: the model-visible catalog is compiled once from the active definition set; a plugin that is not opted in contributes zero tools, zero prompt mass, and zero catalog entries. Third: plugin contract code (manifest, socket, registry) belongs under `apps/backend/src/core/plugins/`; plugin implementations must not live inside `core/` (`AGENTS.md` §IX). Get this seam wrong in either direction and the harness degrades: let plugins inject tools silently and the catalog lies to the model (the forbidden schema-drift anti-pattern, §XII); refuse any extension and the surface cannot grow without a kernel recompile.

This theme serves the north star (01). Sharded context windows are only trustworthy if every shard — built-in or plugin-sourced — converges through the same review gate and emits the same effect evidence. A plugin tool that bypasses the compiled review gate or the effect-receipt contract would make branch convergence unsafe; therefore the plugin surface is the *generalization* of the tool contract, not a second dispatch lane.

## What exists today

- **The validated manifest shape.** `apps/backend/src/core/plugins/manifest.zig` defines `PluginManifest` (`id`, `version`, `sockets: []PluginSocket`) and `PluginSocket` (`kind: tool|provider|context|event`, `name`, `entry`). `validateManifest` enforces a lowercase `[a-z0-9_-]` plugin id, a non-empty version, and — critically — reuses `tool_sockets.validateName` for every `tool`-kind socket, so plugin tool names obey the exact same `lowercase snake_case` rule as built-ins (`manifest.zig:39-42`). This is the anti-schema-drift guarantee at the contract layer: one name validator, two populations.
- **The socket source enum.** `apps/backend/src/core/tools/sockets.zig` carries `ToolSource = enum { builtin, plugin }` and `ToolSocket = struct { source, owner_id, definition }`. The `plugin` variant and `owner_id` field exist precisely so a definition can be attributed to its owning plugin — but nothing populates them today.
- **The module-owned definition contract.** `apps/backend/src/shared/types.zig:241-248` defines `ToolDefinition` (`name`, `description`, `parameters_json`, `review_risk: ToolRiskClass`, optional `example_json`, `usage_hint`). Every built-in (`apps/backend/src/core/tools/builtin/*.zig`) exports a `definition` plus an `availability` spec of this shape; this is the only shape a plugin must produce.
- **Catalog-first discovery.** `apps/backend/src/core/tools/runtime.zig` → `renderCatalog` / `renderCatalogJson` iterate `builtinDefinitionsForContext` and emit per-tool availability (probed), review risk, example JSON, and usage hint. The catalog is the single model-visible surface; there is no second advertisement channel.
- **The compiled review gate.** `apps/backend/src/core/tools/review.zig` → `reviewToolName` fails closed (`tool_blocked`, `undeclared capability cannot be dispatched`) for any name not in the active definitions, and maps `review_risk` to an approve/block decision. `unknown_high_impact` is blocked before dispatch.
- **The dispatch table.** `runtime.zig:356-393` (`executeWithRunner`) is a hard-coded `if`/`else if` chain over built-in names that terminates in `return Error.UnknownTool`. There is no plugin dispatch arm.

**Gap:** the manifest is a validated struct that is never loaded from disk, never registered, and never wired into the catalog or dispatch. `ToolSource.plugin` is declared but never produced. The `PluginSocket.kind` enum advertises `provider`, `context`, and `event` sockets, but only `tool` has a validator. The seam is correctly drawn (one definition shape, one name rule, one catalog, one review gate); it is simply not connected on the contribution side. This theme connects it without introducing a second capability boundary.

## What the competitor does

### Eve (Vercel) — extension packages, dynamic tools, namespace mounts

- **Extension packages with contribution slots.** `docs/extensions.md`: an extension exports `defineExtension({ config })` and contributes `tools/`, `connections/`, `skills/`, `instructions.md`, `hooks/` from a package root. A consumer mounts it under `agent/extensions/<ns>.ts`; the mount adds a `<ns>__` prefix (`tools/search.ts` → `crm__search`). Names come from paths; the consumer's mount owns the namespace.
- **Dynamic tools resolved from context.** `packages/eve/src/context/build-dynamic-tools.ts` → `buildDynamicTools` reads step/turn/session-scoped tool metadata from the context store and *replays* durable tool definitions through bundler-registered step functions (`lookupStepFunction` via `Symbol.for("@workflow/core//registeredSteps")`). Narrower scopes win on name collision (`??=` dedup). `packages/eve/src/harness/tool-loop.ts:952-963` merges dynamic tools over authored tools and throws on collision with a runtime-visible subagent.
- **Advertised-tool filtering.** `packages/eve/src/harness/advertised-tools.ts` → `getAdvertisedTools` filters unavailable delegation tools by session depth and applies workflow-sandbox host-tool gating. The advertised set is derived, not declared.
- **Override and disable.** A directory mount lets a consumer replace or `disableTool()` an extension contribution; dynamic tools win over same-named static tools at runtime.
- **Compatibility metadata at build time.** `eve extension build` emits capability metadata; the host checks it and refuses an extension needing an unsupported contract.

**Limitation:** Eve's extensions mount tools into the model-visible namespace by default — the mount *is* the opt-in, and once mounted the tool is advertised. There is no review-risk class on the Eve tool definition; governance is a separate approval-hook layer over the AI SDK, not a compiled property of the definition. Dynamic tools are replayed from durable metadata tied to a bundler symbol registry — a JS-host-specific mechanism that has no analogue in a Zig kernel.

### pi-mono (badlogic) — runtime `registerTool`, active-set selection, branch-persistent config

- **`ExtensionAPI.registerTool`.** `packages/coding-agent/src/core/extensions/types.ts:1114-1116` and `examples/extensions/dynamic-tools.ts`: an extension calls `pi.registerTool({ name, label, description, parameters, promptSnippet, promptGuidelines, execute })` at `session_start` or on a command. Tool names are normalized to lowercase `[a-z0-9_]` (`dynamic-tools.ts:17-22`) — the same rule VANTARI's `sockets.validateName` enforces.
- **Active-set selection.** `examples/extensions/tools.ts`: `pi.setActiveTools([...])` / `pi.getActiveTools()` / `pi.getAllTools()` let an operator enable/disable tools interactively; the selection is persisted as a `tools-config` custom entry and restored per-branch on `session_start` / `session_tree`.
- **Prompt contributions per tool.** `ToolDefinition` (`types.ts:421-468`) carries optional `promptSnippet` and `promptGuidelines` that are injected into the system prompt when the tool is active — the tool owns a slice of prompt mass.
- **Per-tool execution mode and rendering hooks.** `executionMode: "sequential" | "parallel"`, `renderCall`/`renderResult`, `prepareArguments` compatibility shim.

**Limitation:** registration is imperative and runtime-mutating — a tool added by `registerTool` immediately joins the active set the model sees, with no compiled review gate and no catalog-first declaration. The active-set is the governance layer, not a risk class on the definition. Prompt mass grows linearly with active tools (`promptSnippet`/`promptGuidelines`), the same unbounded-announcement pressure roadmap 20 counters for skills.

### Codex (OpenAI) — shared tool-primitive crate, MCP, discoverable/deferred tools

- **Tool primitives extracted, orchestration kept back.** `codex-rs/tools/README.md`: `codex-tools` owns `ToolDefinition`, `ToolSpec`, `JsonSchema`, MCP/dynamic parsers, and Responses-API adapters, but *explicitly* does not pull `Session` / `TurnContext` / approval / runtime execution into the shared crate "unless those dependencies have first been split into stable shared interfaces." This is the same boundary discipline VANTARI's §IX codifies.
- **MCP, dynamic, and discoverable tools.** The crate lists `parse_mcp_tool`, `parse_dynamic_tool`, `mcp_tool_to_responses_api_tool`, `mcp_tool_to_deferred_responses_api_tool`, and `tool_search` / `tool_suggest` discoverable-tool builders. MCP tools can be *deferred* (not sent inline) and surfaced on demand.
- **MCP transport.** Per the MCP spec (2025-11-25): **stdio** (client spawns the server as a subprocess; line-delimited JSON-RPC over stdin/stdout; 1:1, local) and **Streamable HTTP** (HTTP POST client→server, optional SSE over a long-lived GET server→client; 1:N, remote). The legacy HTTP+SSE transport is deprecated. Both carry identical JSON-RPC message bodies; the choice is operational.

**Limitation:** MCP pushes the capability boundary *out of process* — a tool server is a separate process speaking JSON-RPC. That is a clean isolation boundary but a second dispatch substrate (a subprocess supervisor + RPC framing) that VANTARI does not yet have and does not need for its first plugin surface. Codex's deferred-tool and `tool_search` model is interesting but adds a discovery-round-trip the catalog-first model avoids.

### Cross-industry patterns researched

- **VS Code** activation events + contribution points: an extension *statically declares* contributions (commands, views, configs) in its manifest `contributes` field and *lazily activates* only when an activation event fires (`onCommand`, `onLanguage`, `workspaceContains`). The host never loads extension code until the event matches. This is the canonical "declare statically, activate lazily" pattern.
- **Temporal** `WorkerPlugin`: a plugin registers activities *after* worker creation (`worker.registerActivitiesImplementations`); a workflow worker can invoke an activity through an untyped stub *by name* without registering it itself. Registration is decoupled from invocation; the name is the contract.
- **WASM vs process isolation** (researched): WASM gives in-process linear-memory isolation with IPC orders of magnitude faster than a process boundary, at the cost of a maturing toolchain and host-function surface; an OS process boundary is mature and battle-tested with a larger attack surface. The trade-off is isolation strength vs IPC/forgoing native performance.
- **Dynamic library loading in Zig**: `std.DynLib` is the cross-platform abstraction over `dlopen` (Linux/macOS) and `LoadLibrary` (Windows) — `DynLib.open(path)` then `lookup(fn_ptr_type, "symbol")`. This is the native in-process loading primitive should VANTARI ever load plugin code, not a JS bundler symbol table.

## Why VANTARI does it better

1. **One definition shape, two populations.** A plugin contributes `ToolDefinition` instances — the same struct built-ins use. Eve maintains `HarnessToolDefinition` separate from advertised/model tools; pi-mono's `ToolDefinition` carries UI and prompt fields the kernel does not need. VANTARI's plugin surface is *not a new type*; it is new owners of the existing type, so the catalog, the review gate, the availability prober, and the dispatch path are unchanged. This is the direct mechanical answer to the forbidden "tool schema drift between template, runtime, API endpoint, and frontend" anti-pattern (§XII): there is one schema source.
2. **Catalog-first is the only model-visible surface; plugins are opt-in.** `renderCatalog` / `renderCatalogJson` compile the active definition set into the single announcement. A plugin that is not mounted contributes zero entries — unlike Eve, where the mount *is* the advertisement, or pi-mono, where `registerTool` immediately joins the active set. This honors §V ("Plugin tools are opt-in and must not silently alter the model-visible tool list") at the structural level, not the prompt-prose level.
3. **The compiled review gate governs plugins identically.** `review.reviewToolName` fails closed for any name absent from the active set and maps `review_risk` to the approve/block decision. A plugin tool with `unknown_high_impact` is blocked before dispatch exactly like a built-in would be. Eve's governance is a runtime approval hook layered over the AI SDK; pi-mono has no risk class. VANTARI's risk class is a compiled property of the definition, so plugin tools cannot buy capabilities the kernel would not grant a built-in.
4. **One name validator, reused.** `manifest.validateManifest` calls `tool_sockets.validateName` for every `tool`-kind socket (`manifest.zig:39-42`). Plugin tool names and built-in tool names pass the same `lowercase snake_case` check. Eve relies on path-derived names plus a mount prefix; pi-mono re-implements a normalizer. VANTARI's single validator is the proof that the two populations share one namespace contract.
5. **Contract in `core/`, implementations outside.** §IX mandates plugin *contract* code under `apps/backend/src/core/plugins/` and plugin *implementations* outside `core/`. The manifest, socket, and registry are kernel-owned and stable; plugin packages live in a workspace- or user-owned root. This is the Codex discipline (shared primitives in, orchestration kept back) applied to the plugin boundary: the kernel owns the seam, the plugin owns the body.

### CONTRIBUTION FLOW (target)

```text
plugin package (outside core/)
  └─ manifest: id + version + sockets[]   (validated by core/plugins/manifest.zig)
       └─ each tool socket -> ToolDefinition + AvailabilitySpec + review_risk
             │
             ▼  (opt-in mount: operator declares the plugin in workspace/user config)
       active definition set  =  builtinDefinitions  ++  mounted plugin definitions
             │
             ▼
       renderCatalog / renderCatalogJson   (single model-visible surface)
             │
             ▼
       review.reviewToolName               (compiled gate, fails closed)
             │
             ▼
       executeWithRunner                   (one dispatch path; plugin arm resolves owner)
             │
             ▼
       var1.tool_effect.v1 / tool_* events (same evidence as built-ins)
```

A plugin tool enters the same compiled pipeline as `read_file` or `shell_exec`. It never gets a private dispatch lane, a private review path, or a private announcement channel. A branch (roadmap 01) that invokes a plugin tool produces the same reviewable effect receipts (roadmap 05) as a built-in, so convergence is safe.

## Pipeline items under this theme

### P1-1: Plugin manifest as a typed, catalog-derivable contract
- **Contract:** a `PluginManifest` (already in `manifest.zig`) is the declared contribution: `id`, `version`, and a non-empty `sockets` list where each `tool`-kind socket carries a full `ToolDefinition` (`name`, `description`, `parameters_json`, `review_risk`, optional `example_json`/`usage_hint`) plus an `AvailabilitySpec`. The manifest is the unit a plugin package ships; the kernel validates it and derives catalog entries from it — it never accepts a tool definition that bypasses the manifest.
- **Mechanism:** extend `PluginSocket` so a `tool`-kind socket embeds the `ToolDefinition` and `AvailabilitySpec` directly (today it carries only `name` + `entry`, which presumes a code-loading step this theme defers). `validateManifest` already validates name/id/version; add validation that every `tool` socket's embedded `definition` passes `sockets.validateDefinition` and that `review_risk != .unknown_high_impact` (a plugin must declare a concrete risk class — `unknown_high_impact` is blocked anyway, so reject it at validation). Keep `provider`/`context`/`event` socket kinds as declared-but-not-yet-wired (do not build empty folders — §IX).
- **Test:** (a) a manifest with a well-formed `tool` socket validates; (b) a manifest whose tool socket has `review_risk = .unknown_high_impact` is rejected by `validateManifest`; (c) a manifest whose tool name fails `validateName` is rejected (already true — keep it green as the socket shape grows).
- **Proof:** the manifest is the only input needed to synthesize catalog JSON for a plugin tool without loading any plugin code; a snapshot test proves the catalog entry for a plugin tool is byte-identical in shape to a built-in entry.

### P1-2: Opt-in mount boundary — plugins never alter the default catalog
- **Contract:** the model-visible catalog is compiled from `builtinDefinitionsForContext` plus *only* the manifests explicitly mounted in the active workspace/user configuration. A plugin that is installed but not mounted contributes zero catalog entries, zero prompt mass, and zero dispatch arms. This is §V ("must not silently alter the model-visible tool list") made structural.
- **Mechanism:** introduce a kernel-owned mount registry (in `core/plugins/`) that holds the set of mounted manifests resolved from configuration. `runtime.builtinDefinitionsForContext` becomes `activeDefinitionsForContext` = built-ins `++` mounted-plugin definitions, where the mounted set is empty by default. `renderCatalog`/`renderCatalogJson` and `review.reviewToolName` consume the active set unchanged. The dispatch table (`executeWithRunner`) gains a terminal plugin-resolution arm that attributes the call to the owning manifest (`ToolSocket.owner_id`) before `Error.UnknownTool`. No second catalog, no second review path, no second dispatch lane.
- **Test:** (a) with no plugin mounted, `renderCatalog` output is byte-identical to today (regression guard); (b) mounting one manifest adds exactly its tool entries to the catalog and no others; (c) a tool call to a plugin tool that is installed-but-not-mounted fails with `tool_blocked` ("undeclared capability") from the review gate, never reaching dispatch.
- **Proof:** event-spine evidence that an unmounted plugin tool produces `tool_blocked` with the catalog-as-source-of-truth reason, and a mounted plugin tool produces the full `tool_requested → tool_reviewed → tool_started → tool_finished → tool_completed` span with `owner_id` attribution.

### P1-3: Single dispatch path with owner attribution
- **Contract:** plugin tools dispatch through `executeWithRunner` — the same function built-ins use — and emit the same `var1.tool_effect.v1` receipts (roadmap 05) and typed tool events (roadmap 03) as built-ins. The dispatch arm resolves the owning manifest and refuses to run a tool whose definition is not in the active set (defense in depth: the review gate already enforces this, but dispatch must not trust a name string alone).
- **Mechanism:** the terminal plugin arm in `executeWithRunner` looks up the tool name in the mounted-manifest registry, confirms its `ToolDefinition` is in the active set, and delegates to the plugin's execute entry. For the first cut, the execute entry is a kernel-resolved function (the manifest's `entry` names a path the kernel resolves), *not* arbitrary `dlopen`/`LoadLibrary` code loading — that is P2-1. The arm records `owner_id` on the tool span so effect receipts and event evidence are attributable.
- **Test:** (a) a mounted plugin tool executes and emits an effect receipt with `owner_id` set to the plugin id; (b) a mounted plugin tool whose definition was removed from the active set between catalog compile and dispatch fails closed; (c) a plugin tool's event span is replayable from `events.jsonl` after cold start with the owner attribution intact.
- **Proof:** cold-start replay of a session that invoked a plugin tool reproduces the review decision, the effect receipt, and the owner attribution from repository state.

### P2-1: Plugin isolation strategy — process boundary vs in-process vs WASM
- **Contract:** decide and document the isolation boundary for plugin *execution bodies*. The choice is constrained by VANTARI's Windows-native, no-second-runtime discipline (§IX, roadmap 09): an in-process `std.DynLib` (`dlopen`/`LoadLibrary`) load is fastest but trusts the plugin with the kernel's address space; a subprocess (MCP-stdio-style) gives an OS process boundary at the cost of a supervisor and RPC framing; WASM gives in-process linear-memory isolation but adds a runtime dependency. The contract is to pick one default and prove it, not to ship three.
- **Mechanism:** recommended first cut is the **subprocess / stdio-RPC boundary** (MCP-stdio shape): a plugin ships as an executable the kernel spawns, framing `tool_call`/`tool_result` as line-delimited JSON-RPC over stdin/stdout, reusing the existing `CommandRunner` / `CommandLimits` / output-budget machinery (roadmap 13). This matches the existing process-supervision surface, avoids address-space trust, and is the MCP-idiomatic shape. `std.DynLib` in-process loading stays a documented future option for trusted, kernel-built plugins (e.g. a C-ABI acceleration socket, roadmap 14); WASM is rejected until a dependency-free WASM runtime is proven necessary.
- **Test:** a subprocess plugin tool executes under the same `CommandLimits` (timeout, output cap, termination) as `shell_exec`; a plugin that exceeds the output budget is capped and terminated identically.
- **Proof:** a plugin tool implemented as a subprocess produces the same effect-receipt shape and event span as an in-process built-in; the isolation boundary is visible in the event evidence (process pid, exit class).

### P2-2: Plugin capability negotiation — what a plugin may expose
- **Contract:** a manifest declares not only tool sockets but the *capability profile* it needs (which dependencies, which review-risk classes it is allowed to claim, whether it needs command execution or filesystem write). The kernel negotiates at mount time: a plugin claiming `command_execution` risk in a configuration that forbids it is rejected before any tool is advertised. This generalizes the built-in `AvailabilitySpec`/dependency-probe contract to plugins.
- **Mechanism:** extend the manifest with a `capability_profile` (allowed risk classes, required external-command dependencies). At mount, the kernel runs `registry.resolveAvailability` against the plugin's declared dependencies and refuses the mount if a required dependency is unavailable or a claimed risk class exceeds the operator's policy. This is the Temporal `WorkerPlugin` discipline (register-after-create, refuse-on-mismatch) and the VS Code activation-event discipline (activate only when the host can satisfy the contract) applied to the tool boundary.
- **Test:** (a) a plugin requiring an unavailable external command is not mounted and its tools do not appear in the catalog; (b) a plugin claiming `command_execution` under a read-only operator policy is rejected at mount with a typed reason; (c) mounting a plugin whose dependencies later become available re-resolves its tools to `available` on the next catalog compile.
- **Proof:** the catalog's availability column for a plugin tool is derived from the same prober as built-ins (parity proven by the existing `resolveAvailability` test), and a rejected mount is recorded as a typed diagnostic thinner than the capability it refused (§XII).

## North-star link

The north star (01) is many windows, each a shard, converging on reviewed evidence. A plugin is the most likely vector for a *second* capability boundary — a private tool lane, a private review path, a private announcement channel — and a second boundary is exactly what makes shard convergence unsafe: a branch that invoked a plugin tool would produce evidence the merge decision could not trust. This theme forbids the second boundary by construction: plugin tools are `ToolDefinition` instances in the active set, compiled into the same catalog, gated by the same review, dispatched through the same `executeWithRunner`, and evidenced by the same `var1.tool_effect.v1` receipts. A shard that calls a plugin tool is therefore indistinguishable — to the catalog, the gate, and the convergence logic — from one that calls `read_file`. The plugin surface is the generalization of the tool contract, not an exception to it. This theme feeds roadmap 05 (tool governance: the review gate and effect receipts govern plugins identically), roadmap 03 (typed event grammar: plugin tool spans carry `owner_id` attribution), roadmap 06 (parent-child delegation: a branch's capability profile must bound which plugin tools a child may invoke), and roadmap 14 (C-ABI acceleration socket: the trusted in-process plugin path for kernel-built extensions).

## Definition of done
- A plugin manifest is a typed, validated contribution whose `tool` sockets embed full `ToolDefinition` + `AvailabilitySpec` instances; `unknown_high_impact` is rejected at validation.
- The model-visible catalog is compiled from built-ins plus *only* explicitly mounted plugins; an unmounted plugin contributes zero catalog entries and zero prompt mass.
- Plugin tools dispatch through `executeWithRunner`, pass the compiled review gate, and emit `var1.tool_effect.v1` receipts and typed tool spans with `owner_id` attribution — identical in shape to built-ins.
- The isolation strategy is chosen and proven (subprocess/stdio-RPC recommended first); plugin execution is bounded by the same `CommandLimits` as `shell_exec`.
- Capability negotiation refuses a mount whose declared dependencies are unavailable or whose claimed risk classes exceed operator policy, before any tool is advertised.
- No second catalog, no second review gate, no second dispatch lane, no plugin implementation code inside `core/`.
