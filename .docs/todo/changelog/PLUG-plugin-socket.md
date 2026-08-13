---
id: PLUG-plugin-socket
type: parent
protocol_version: "3.0"
spec_status: approved
category: feature
status: done
decision: deferred-delete
next_todo: NONE
epic_boundary: "Wire the existing plugin manifest/socket contracts into the tool runtime so discovered plugins register tools, dispatch through the subprocess socket, surface in the model-visible catalog, and are manageable via a manage_plugin tool — all opt-in and never silently altering the built-in tool list."
subtodo_start: /todo/changelog/PLUGa-plugin-socket.md
subtodo_final: /todo/changelog/PLUGh-plugin-socket.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Stay focused on one slice at a time. Never batch-archive. Never pause between units."
source_message_policy: "Every lettered unit MUST include source_message_anchor, source_message_excerpt, source_message_proof_obligation, and an Original User Message Proof section with verbatim snippets from the original user message."
---

# PLUG Plugin Socket — Discovery, Dispatch, and Model-Visible Management

## Objective

VANTARI needs a clean, modular, simple plugin socket so any "plug" — tool, agent, modifier, extension — declares itself through one schema and the kernel can discover and use it. This chain closes the gap between the harvested manifest/socket contracts that already exist in `apps/backend/src/core/plugins/` and `apps/backend/src/core/tools/sockets.zig` and the tool runtime that actually advertises, gates, and dispatches capability. The precise system delta: a `.var/plugins/<name>/plugin.json` manifest is parsed from disk, opt-in gated by a new `plugins` config section, mounted as a validated `PluginManifest`, its tool sockets converted into `types.ToolDefinition` entries fed through the existing `registry`/`runtime` catalog and dispatch chain, dispatched over the already-harvested subprocess JSON-RPC transport, and exposed to the model through a new `manage_plugin` tool so the model can list/enable/disable/inspect installed plugins. The canonical system boundary is AGENTS.md §V (tool runtime contract: definition + availability + review_risk + execute -> catalog -> provider schema -> review gate -> runtime dispatch -> effect/event evidence) and §IX (plugin contract code belongs under `apps/backend/src/core/plugins/`; plugin implementations must not live inside `core/`). The intended long-run shape is a single socket primitive where built-in tools are merely `ToolSource.builtin` and plugin tools are `ToolSource.plugin`, both governed by the same review/availability/dispatch spine — no parallel truth, no second dispatch path.

## Rationale

The plugin scaffolding was already harvested but never wired. `core/plugins/manifest.zig` defines `PluginManifest`, `PluginSocket`, `PluginSocketKind`, `validateManifest`, and `mountPlugin`; `core/plugins/isolation.zig` defines `IsolationLevel` (in_process/subprocess/wasm_sandbox), `SubprocessTransport`, and `default_isolation_level = .subprocess`; `core/tools/sockets.zig` defines `ToolSource = builtin | plugin`, `ToolSocket`, and `validateDefinition`. Yet none of this is reachable from `runtime.zig`: `builtinDefinitionsForContext` returns only compiled-in slices, `executeWithRunner` has no plugin branch, `availabilitySpec` / `resolveAvailability` only know builtin names, and there is no code anywhere that reads `.var/plugins/`, no `plugins` section in `default.json`, and no `manage_plugin` tool. The dependency order is therefore forced: the manifest schema must become disk-parseable and carry the descriptor hints (usage, example, review-risk override) the catalog needs; the config surface must exist so opt-in is honored before any discovery (§V: "Plugin tools are opt-in and must not silently alter the model-visible tool list"); discovery must produce a durable registry the runtime can read; the subprocess dispatch module must turn a `SubprocessTransport` into a `CommandRunner`-bounded JSON-RPC call; the runtime must merge plugin definitions into the catalog and dispatch; and finally the model needs a tool to see and manage the installed set. Downstream surfaces that depend on this parent's completion: the provider tool-schema list (so plugin tools reach the model only when enabled), the review gate (so plugin tools fail closed on unknown risk), and the agent `subagent`/`write` capability profiles (which must continue to see only their allowed tool classes, extended by plugin contributions where the class matches).

## Domain Expertise Baseline

Plugin systems that survive are contract-validated, fail-closed, and never silently expand the model's tool surface. The non-negotiable rules for this chain are derived from the existing harvested contracts, AGENTS.md §V/§IX, and the proven `configure_agent` hot-load pattern.

| Domain Question | Current Evidence | Gold-Standard Requirement | What This Chain Must Not Assume |
|---|---|---|---|
| How does a tool become model-visible? | `runtime.builtinDefinitionsForContext` + `registry.availabilitySpec` + `review.reviewToolName` (`src/core/tools/runtime.zig:100`, `registry.zig:73`, `review.zig:18`). Unknown tool names are blocked before execution (`review.zig:24`). | A plugin tool must traverse the exact same path: definition -> availability -> review risk -> dispatch. No bypass, no prompt-only advertisement. | Must NOT inject plugin tools by editing the system prompt; must NOT add a second dispatch switch that skips review. |
| How is capability hot-loaded from disk? | `agents/spec.zig:loadRegistry` re-parses `config.json` on every call, no process-local cache; `configure_agent` mutates atomically under a mutex and validates the whole registry before writing (`spec.zig:187`, `spec.zig:266`). | Plugin discovery must re-read manifests on each catalog/dispatch admission (no stale cache) OR invalidate atomically; mutation must validate the complete effective set before it becomes visible. | Must NOT build a one-shot startup cache that hides operator edits; must NOT invent a new mutation protocol unrelated to the proven config-mutex pattern. |
| What isolation do plugins get? | `isolation.zig`: default `.subprocess`, stdio JSON-RPC, kernel-supervised kill via Job Object / process group, bounded `timeout_ms` + `max_output_bytes`. Reuses `CommandRunner`/`CommandLimits`. | Plugin tools dispatch over the harvested subprocess transport with the same timeout/output/kill discipline as `shell_exec` (`runtime.zig` Windows Job Object path). | Must NOT load plugin code in-process (§IX: implementations must not live in core); must NOT invent a new IPC shape unrelated to the harvested MCP-stdio contract. |
| How is opt-in enforced? | `config/file.zig` `validateDocumentShape` rejects unknown top-level keys (`file.zig:266`); `default.json` has no `plugins` section. §V: plugin tools are opt-in and must not silently alter the model-visible tool list. | A `plugins` config section with `enabled`, `path`, and per-plugin enable map. With `enabled:false` (or section absent), zero plugin tools reach the catalog. | Must NOT default plugins on; must NOT make discovery implicit with no config gate. |
| How are tool descriptors surfaced? | `ToolDefinition` carries `name, description, parameters_json, review_risk, example_json?, usage_hint?` (`shared/types.zig:431`); catalog renders all of these (`runtime.zig:128`, `runtime.zig:168`). | Plugin manifest must carry the same fields so plugin tools render identically to builtin tools in catalog text and JSON. | Must NOT invent a separate descriptor format that omits usage_hint/example/review_risk. |

## Gold-Standard Decision Criteria

| Criterion ID | Decision Rule | Evidence Required Before Selection | Review Failure Signal |
|---|---|---|---|
| GS1 | Reuse the existing `PluginManifest`/`PluginSocket`/`ToolSocket` types as the contract; extend them only with disk-parsing and descriptor fields the catalog already consumes. | `manifest.zig`, `sockets.zig`, `types.ToolDefinition` field list. | A new parallel manifest struct or a second ToolDefinition-like type is introduced. |
| GS2 | Plugin tools must traverse the identical review/availability/dispatch spine as builtin tools; the only new branch is the transport (subprocess vs in-process), not the gating. | `review.reviewToolName`, `registry.resolveAvailability`, `runtime.executeWithRunner`. | A plugin dispatch path that skips `ensureToolAllowed` or `reviewToolName`. |
| GS3 | Discovery must be config-gated and fail-closed: malformed manifest, missing review_risk, or unsupported socket kind never advertises a tool (harvested `validateManifest` already enforces this). | `manifest.validateManifest` rejects UnsupportedSocketKind / InvalidReviewRisk / DuplicateSocketName (`manifest.zig:49`). | A plugin with no/invalid review_risk appears in the catalog. |
| GS4 | Plugin subprocess dispatch reuses `CommandRunner`/`CommandLimits` and the Windows Job Object kill path; no bespoke process spawning. | `runtime.runCommandWithLimitsWindows` Job Object pattern (`runtime.zig:744`). | A second child-process spawner that does not drain pipes, cap output, or kill the tree on timeout. |
| GS5 | The `manage_plugin` tool mirrors the `agents` discovery pattern: list is always available; enable/disable mutate config atomically under the same proven mutex discipline as `configure_agent`. | `agents.zig` catalog pattern, `spec.zig` config-mutation mutex (`spec.zig:78`). | A manage_plugin that mutates plugin state without re-validating the effective registry. |

## Repository Ownership Reconnaissance

| Question | Evidence Found | Planning Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Current canonical owners of plugin contracts | `core/plugins/manifest.zig` (`PluginManifest`, `PluginSocket`, `validateManifest`, `mountPlugin`), `core/plugins/isolation.zig` (`IsolationLevel`, `SubprocessTransport`, `default_isolation_level`), `core/plugins/index.zig` (re-exports), `core/tools/sockets.zig` (`ToolSource`, `ToolSocket`, `validateDefinition`, `validateName`). Registered in `core/index.zig:19`. | Extend these owners; do not create a new plugin module. PLUGb enriches manifest with descriptor fields + disk parser; PLUGe implements the subprocess transport caller. | Must NOT create a second manifest type or a parallel `plugin_registry.zig` outside `core/plugins/`. |
| Adjacent/duplicate owners | Tool catalog/dispatech: `core/tools/runtime.zig`, `registry.zig`. Availability: `registry.zig:resolveAvailability`. Review: `core/tools/review.zig`. Config: `core/config/file.zig`, `default.json`. Hot-load pattern: `core/agents/spec.zig` (`loadRegistry`, `upsertConfiguredAgent`). | Runtime integration extends these; config integration adds a `plugins` section validated like the `agents` section. | Must NOT fork the catalog renderer or build a plugin-only catalog. |
| Canonical callers/consumers | Provider tool-schema list (wherever `renderCatalogJson`/`builtinDefinitionsForContext` is consumed to build the provider request), the review gate, the dispatch loop. | PLUGf must feed plugin definitions into the same slice the provider sees, gated by profile + opt-in. | Must NOT advertise plugin tools in the prompt while keeping them out of the provider schema, or vice versa. |
| Existing tests and proof gaps | `manifest.zig` tests cover validate/mount but NOT disk parsing, NOT descriptor fields, NOT discovery. `sockets.zig` tests cover validateDefinition. No test covers plugin tools in the catalog or dispatch. | Each slice adds tests proving the real consumer path (catalog contains plugin tool only when enabled; dispatch reaches subprocess transport; manage_plugin list reflects disk). | A test that only checks a struct field without rendering the catalog or dispatching is a shallow proof. |
| Unsupported runtime boundaries | `isolation.wasm_sandbox` is explicitly future (P3). `PluginSocketKind.provider/context/event` are declared but not mountable (`isSocketKindMountable` returns true only for `.tool`). | Chain mounts `.tool` sockets only; provider/context/event sockets fail closed with the harvested UnsupportedSocketKind error. | Must NOT attempt to implement provider/context/event sockets or WASM isolation in this chain. |

## Scope

**In scope:**
- Disk-parsed `.var/plugins/<name>/plugin.json` manifest with descriptor fields (description, parameters_json, usage_hint, example_json, review_risk) per tool socket.
- `plugins` config section in `default.json` + `file.zig` validation (`enabled`, `path`, per-plugin enable map).
- Plugin discovery: scan the configured plugins path, parse + validate manifests, build an in-memory registry re-read on admission (hot-load, no stale cache).
- Subprocess dispatch module: invoke plugin entry executables over bounded JSON-RPC via `CommandRunner`/`CommandLimits`.
- Runtime integration: merge enabled plugin tool definitions into `builtinDefinitionsForContext` output (catalog + provider schema), extend `executeWithRunner` dispatch, extend `availabilitySpec`/`resolveAvailability`/`toolClassForName`, preserve review gate.
- `manage_plugin` tool: list, info, enable, disable — config-backed, hot-loading, mirroring the `agents` catalog/mutation pattern.
- Capability-profile and orchestrator-only preservation: plugin tools obey the same `ensureToolAllowed` profile gating as builtins.

**Out of scope:**
- Provider/context/event socket mounting (declared, fail-closed only).
- WASM sandbox isolation (P3 future).
- Plugin-provided agent definitions (the task names "agent definitions" in the manifest, but agent hot-load already has a canonical owner in `agents/spec.zig`; wiring plugin->agent is a separate parent).
- Plugin signing, network distribution, or a plugin marketplace.
- In-process plugin loading of arbitrary code (forbidden by §IX).

## Source Language Anchors

Verbatim wording from the approved request that downstream execution units MUST honor:

- "VANTARI needs a clean, modular, simple plugin socket — a schema/format/syntax for any 'plug' (tool, agent, modifier, extension)."
- "Plugins should have a tool with hints in the descriptor."
- "VANTARI knows about installed plugins and can discover/use them."
- "Plugin tools are opt-in and must not silently alter the model-visible tool list" (AGENTS.md §V).
- "Plugin contract code belongs under `apps/backend/src/core/plugins/`. Plugin implementations must not live inside `core/`" (AGENTS.md §IX).
- "Tool runtime contracts belong under `apps/backend/src/core/tools/`" (AGENTS.md §IX).
- "Plugin manifest schema — a `.var/plugins/<name>/plugin.json` format declaring: name, version, tool definitions, agent definitions, dependencies, review risk overrides."
- "Plugin discovery — scan `.var/plugins/` for manifests, register tools/agents at startup."
- "Plugin tool socket — how plugin-provided tools integrate into the existing `registry.zig` + `runtime.zig` dispatch chain."
- "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)."
- "Plugin descriptor hints — usage hints, examples, review risk advertised in the manifest."
- "Config surface — `plugins.enabled`, `plugins.path`, per-plugin enable/disable."
- "A `manage_plugin` tool — list, enable, disable, info operations for the model to discover and manage plugins."
- "Focus on the minimal slices for the plugin manifest + discovery + tool integration."

## Original User Message Capture

| Anchor ID | Information Piece | Verbatim Original Snippet | Required Coverage |
|---|---|---|---|
| U1 | vision / objective | "VANTARI needs a clean, modular, simple plugin socket — a schema/format/syntax for any 'plug' (tool, agent, modifier, extension). Plugins should have a tool with hints in the descriptor. VANTARI knows about installed plugins and can discover/use them." | PLUGa (freeze), PLUGb (schema+descriptor), PLUGd (discovery), PLUGf (use via dispatch), PLUGg (manage tool) |
| U2 | opt-in invariant (AGENTS.md §V) | "Plugin tools are opt-in and must not silently alter the model-visible tool list" | PLUGa (lock), PLUGc (config gate), PLUGf (catalog merge gated), PLUGh (review) |
| U3 | ownership boundaries (AGENTS.md §IX) | "Plugin contract code belongs under `apps/backend/src/core/plugins/`. Plugin implementations must not live inside `core/`" + "Tool runtime contracts belong under `apps/backend/src/core/tools/`" | PLUGa (lock), every implementation unit (file placement), PLUGh (review) |
| U4 | manifest schema requirement | "Plugin manifest schema — a `.var/plugins/<name>/plugin.json` format declaring: name, version, tool definitions, agent definitions, dependencies, review risk overrides" | PLUGb |
| U5 | discovery requirement | "Plugin discovery — scan `.var/plugins/` for manifests, register tools/agents at startup" | PLUGd |
| U6 | tool-socket integration requirement | "Plugin tool socket — how plugin-provided tools integrate into the existing `registry.zig` + `runtime.zig` dispatch chain" | PLUGe (transport), PLUGf (runtime merge) |
| U7 | lifecycle requirement | "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)" | PLUGc (config enable/disable), PLUGd (hot-load re-read), PLUGg (manage ops) |
| U8 | descriptor hints requirement | "Plugin descriptor hints — usage hints, examples, review risk advertised in the manifest" | PLUGb |
| U9 | config surface requirement | "Config surface — `plugins.enabled`, `plugins.path`, per-plugin enable/disable" | PLUGc |
| U10 | manage tool requirement | "A `manage_plugin` tool — list, enable, disable, info operations for the model to discover and manage plugins" | PLUGg |
| U11 | scope-focusing instruction | "Focus on the minimal slices for the plugin manifest + discovery + tool integration." | PLUGa (lock minimal set), all units (no gold-plating: no WASM, no marketplace, no provider/context/event sockets) |

## Source Message Coverage

| Unit | Source Anchor(s) | Slice Proof Obligation |
|---|---|---|
| PLUGa | U1, U2, U3, U11 | Freeze the minimal interpretation: tool sockets only, opt-in gated, plugin contract under `core/plugins/`, runtime contract under `core/tools/`. Reject WASM/marketplace/provider-socket scope creep. |
| PLUGb | U1, U4, U8 | Implement the `.var/plugins/<name>/plugin.json` schema + disk parser + descriptor fields (usage_hint, example_json, review_risk) so a plugin tool carries the same descriptor richness as a builtin. |
| PLUGc | U2, U7, U9 | Implement the `plugins` config section with `enabled`, `path`, per-plugin enable map; default OFF so plugin tools never silently appear. |
| PLUGd | U5, U7 | Scan `.var/plugins/`, parse manifests, validate, build a registry re-read on admission (hot-load like agent specs). |
| PLUGe | U3, U6 | Implement the subprocess JSON-RPC dispatch caller reusing `CommandRunner`/`CommandLimits`; plugin implementations stay out of `core/`. |
| PLUGf | U2, U6 | Merge enabled plugin definitions into catalog/provider-schema/review/availability/dispatch; preserve profile gating and fail-closed review. |
| PLUGg | U1, U7, U10 | `manage_plugin` list/info/enable/disable mirroring the `agents` catalog + `configure_agent` mutation pattern. |
| PLUGh | U1–U11 | Verify every source anchor is implemented/evidenced/closed and the opt-in + ownership invariants hold end-to-end. |

## Constraints

| Dimension | Constraint |
|---|---|
| Category boundary | Only `feature` operations extending the plugin socket. No refactoring of unrelated modules, no agent-spec redesign. |
| Blast radius ceiling | medium — Runtime/catalog/dispatch touch the provider tool-schema path, but changes are additive and gated by config default-OFF. No unit exceeds medium. |
| Structural boundary | New code under `apps/backend/src/core/plugins/` (contract) and `apps/backend/src/core/tools/` (runtime integration). Plugin implementations remain outside `core/` (test fixtures live under test dirs, not `core/`). |
| Dependency boundary | Reuse `types.ToolDefinition`, `module.CommandRunner`/`CommandLimits`, `config.file` validation pattern, `agents.spec` hot-load + mutation-mutex pattern. No new IPC library, no external dependency. |
| Rollback surface | Each slice's changes are additive (new files + narrow edits to runtime/registry/config). Rollback = revert the slice's file additions and the enumerated edits; no data migration. |
| Parallelism | Sequential. PLUGd depends on PLUGb+PLUGc; PLUGf depends on PLUGd+PLUGe; PLUGg depends on PLUGf. No parallel slices. |

## Invariants

- I1 (opt-in truth): With `plugins.enabled` false OR the section absent, the model-visible catalog, provider tool schema, and dispatch set contain zero plugin tools. Proven by a test asserting catalog JSON has no plugin tool name when disabled.
- I2 (no silent expansion): Plugin tools never appear in the catalog or provider schema without (a) a valid manifest on disk, (b) the `plugins` section enabled, (c) the specific plugin enabled. Proven by a test toggling each gate.
- I3 (review gate preservation): A plugin tool with undeclared/invalid `review_risk` is rejected before advertisement and before dispatch; the review gate (`review.reviewToolName`) treats plugin tool definitions identically to builtins. Proven by a test that a no-review-risk plugin is absent from the catalog.
- I4 (ownership boundary): All plugin contract code lands under `src/core/plugins/`; all tool-runtime integration lands under `src/core/tools/`; no plugin implementation (executable logic) lives inside `core/`. Proven by review grep.
- I5 (hot-load parity): Discovery re-reads manifests on each admission (catalog render / dispatch), matching the `agents/spec.loadRegistry` no-stale-cache contract. Proven by a test that an edited manifest is visible on the next read without a restart.
- I6 (subprocess isolation default): Plugin tool dispatch uses `IsolationLevel.subprocess`; plugin code never runs in the kernel process. Proven by dispatch routing through the subprocess transport, not an in-process call.
- I7 (capability-profile preservation): `ensureToolAllowed` and `toolClassForName` continue to gate plugin tools by profile (recon/write/root/subagent) exactly as they gate builtins. Proven by a test where a plugin tool of a disallowed class is denied under a recon profile.
- I8 (config mutation safety): `manage_plugin` enable/disable mutates `config.json` atomically under a mutex and validates the effective registry before the file becomes visible, mirroring `configure_agent`. Proven by a test of concurrent/sequential mutation receipts.

## Architectural Improvement Targets

| Target ID | Pre-Chain Weakness | Required Better-Than-Before Outcome | Verified By |
|---|---|---|---|
| A1 | Plugin contracts (`manifest.zig`, `sockets.zig`, `isolation.zig`) exist but are dead code — unreachable from the runtime. | Plugin manifests are discoverable from disk and plugin tools traverse the full catalog->schema->review->dispatch spine. | Test: a fixture plugin under `.var/plugins/` produces a tool in `renderCatalogJson` and dispatches through the subprocess transport. |
| A2 | No `plugins` config surface; nothing enforces the §V opt-in invariant. | A validated `plugins` config section default-OFF; the invariant is mechanically enforced, not aspirational. | Test: with the section absent, zero plugin tools in catalog; with `enabled:true` + per-plugin enable, the tool appears. |
| A3 | `ToolSource` discriminator exists but the catalog/dispatch treat everything as builtin. | The runtime distinguishes `builtin` vs `plugin` provenance and renders it, so operators can see which tools are plugin-sourced. | Test: catalog JSON includes a `source`/provenance marker for plugin tools; grep confirms `ToolSource.plugin` is read, not just declared. |
| A4 | No model-facing way to discover or manage plugins; the model cannot know what is installed. | `manage_plugin` gives the model list/info/enable/disable with the same hot-load discipline as `agents`/`configure_agent`. | Test: `manage_plugin` list reflects on-disk plugins; enable/disable round-trips through config and is visible on the next list. |

## Embedded Framing Contract

| Frame ID | Embedded Meaning | Where It Appears | Gold-Standard Pressure |
|---|---|---|---|
| F1 | "One socket, two sources" — builtins are `ToolSource.builtin`, plugins are `ToolSource.plugin`; the review/availability/dispatch spine is shared, not forked. | Objective, PLUGf focus, PLUGh review. | Pulls every slice toward extending the existing spine rather than building a parallel plugin dispatch. |
| F2 | "Opt-in is mechanical truth, not a default" — §V's invariant is enforced by config-gated discovery, not by operator discipline. | PLUGc, PLUGf, PLUGh. | Pulls the config + discovery + catalog slices toward a testable OFF-by-default gate. |
| F3 | "Harvested contracts are load-bearing" — `manifest.zig`/`isolation.zig`/`sockets.zig` already encode the shape; the chain wires them, it does not reinvent them. | Objective, PLUGb/PLUGd/PLUGe. | Pulls slices toward reuse and away from parallel types. |
| F4 | "Hot-load, never stale" — discovery behaves like `agents/spec.loadRegistry`: re-read on admission, no process-local cache. | PLUGd, PLUGg. | Pulls discovery/management toward the proven no-cache pattern. |

## Research Program

The plugin socket design is substantially anchored in already-harvested repository contracts plus two well-understood external patterns (MCP stdio transport, and the host's own `configure_agent` hot-load). Research is therefore light and slice-bounded.

| Research ID | Why This Research Exists | Questions To Answer | Insect Surface | Priority Sources | Expected Artifact / Evidence |
|---|---|---|---|---|---|
| RCH-1 | Confirm the MCP stdio JSON-RPC framing the harvested `SubprocessTransport` is based on, so the dispatch request/response envelope is canonical. | What is the minimal line-delimited JSON-RPC request/response shape for a tool call? How are errors encoded? | `engine --query "Model Context Protocol stdio transport JSON-RPC tool call"` | MCP spec (modelcontextprotocol.io), official docs | A short note in PLUGe naming the framing fields (method, params, result, error) with citation. |
| RCH-2 | Confirm the line-delimited JSON-RPC envelope used by the host's own stdio_rpc (referenced in `isolation.zig:47`). | What envelope does `host/stdio_rpc.zig` already use, if present in the repo? | repo-local: `ix search "stdio_rpc"` / read | repository source | PLUGe addendum citing the local envelope to reuse. |

## Assumption Ledger

| Assumption ID | Assumption | Evidence Class | Risk If Wrong | Slice That Proves Or Eliminates It |
|---|---|---|---|---|
| AS1 | The harvested `PluginManifest`/`PluginSocket` types can be extended with descriptor fields (description, parameters_json, usage_hint, example_json) without breaking the existing tests. | verified repo fact (`manifest.zig` struct is extensible; `PluginSocket` already has optional `review_risk`) | Low — additive fields. | PLUGb |
| AS2 | The provider tool-schema consumer reads from `builtinDefinitionsForContext` (or the slice it returns), so merging plugin definitions there is sufficient for the model to see them. | verified repo fact (`runtime.renderCatalogJson` iterates `builtinDefinitionsForContext`) | Low — if there is a second schema-build site, PLUGf must extend it too. | PLUGf |
| AS3 | `.var/plugins/` should resolve under the same `fsutil.runtimeRootForWorkspace` root as `config.json` (`.var/`). | verified repo fact (`config.file.path` uses `runtimeRootForWorkspace` + `config.json`) | Low — if operators expect a different root, the `plugins.path` override covers it. | PLUGc/PLUGd |
| AS4 | The subprocess plugin transport should use line-delimited JSON-RPC (MCP-stdio shape) as already documented in `isolation.zig`. | primary source (MCP spec) + repo comment | Low — the harvested contract already commits to this shape. | PLUGe |
| AS5 | `manage_plugin` should mutate `config.json` (not a separate plugin-state file) so enable/disable hot-loads through the same canonical config owner. | verified repo fact (`configure_agent` mutates config.json) | Low — if a separate state file is cleaner, PLUGg must justify it. | PLUGg |

## Chain Manifest

| File | Phase | Role | Status |
|---|---|---|---|
| `/todo/pending/PLUG-plugin-socket.md` | parent | Chain root | pending |
| `/todo/pending/PLUGa-plugin-socket.md` | a | Baseline / contract lock | pending |
| `/todo/pending/PLUGb-plugin-socket.md` | b | Manifest schema + disk parser + descriptor hints | pending |
| `/todo/pending/PLUGc-plugin-socket.md` | c | Config surface (`plugins` section) + opt-in gate | pending |
| `/todo/pending/PLUGd-plugin-socket.md` | d | Discovery + registry (hot-load) | pending |
| `/todo/pending/PLUGe-plugin-socket.md` | e | Subprocess dispatch module (JSON-RPC transport) | pending |
| `/todo/pending/PLUGf-plugin-socket.md` | f | Runtime tool-socket integration (catalog/availability/review/dispatch/profile) | pending |
| `/todo/pending/PLUGg-plugin-socket.md` | g | `manage_plugin` tool (list/info/enable/disable) | pending |
| `/todo/pending/PLUGh-plugin-socket.md` | h | Review / regression / closeout decision | pending |

Chain is complete when all rows read `archived` and all files are in `/todo/changelog/`.

## Execution Index

| Order | Unit | Role | Decision After Completion |
|---|---|---|---|
| 1 | `PLUGa` | Baseline / contract lock | Continue to `PLUGb` |
| 2 | `PLUGb` | Manifest schema + disk parser + descriptor hints | Continue to `PLUGc` |
| 3 | `PLUGc` | Config surface + opt-in gate | Continue to `PLUGd` |
| 4 | `PLUGd` | Discovery + hot-load registry | Continue to `PLUGe` |
| 5 | `PLUGe` | Subprocess dispatch transport | Continue to `PLUGf` |
| 6 | `PLUGf` | Runtime integration (catalog/review/dispatch/profile) | Continue to `PLUGg` |
| 7 | `PLUGg` | `manage_plugin` tool | Continue to `PLUGh` |
| 8 | `PLUGh` | Review / regression / closeout decision | `NONE` if pass; extend chain only if review proves fix work is required |

Every row above should compound the parent ratchet (A1–A4).

## Phase Plan

| Letter | Role | Patch Surface | Depends On | Parallelizable |
|---|---|---|---|---|
| `a` | Baseline / contract lock | Interpretation freeze, boundary declaration, invariant declaration — no artifact change | — | No |
| `b` | Manifest schema + disk parser + descriptor hints | `core/plugins/manifest.zig` (extend `PluginSocket`/`PluginManifest` with descriptor fields + add `parsePluginManifestFromJson`), `core/plugins/index.zig` (re-export) | `a` | No |
| `c` | Config surface + opt-in gate | `core/config/default.json` (add `plugins` section), `core/config/file.zig` (validate `plugins` section + `loadPluginPolicy`) | `a` | No |
| `d` | Discovery + hot-load registry | new `core/plugins/discovery.zig` (scan `.var/plugins/`, parse, validate, build registry), `core/plugins/index.zig` re-export | `b`, `c` | No |
| `e` | Subprocess dispatch transport | new `core/plugins/subprocess.zig` (JSON-RPC caller via `CommandRunner`/`CommandLimits`), `core/plugins/index.zig` re-export | `b` | No |
| `f` | Runtime tool-socket integration | `core/tools/runtime.zig` (merge plugin defs into catalog + dispatch + `toolClassForName`), `core/tools/registry.zig` (availability for plugin tools), `core/tools/sockets.zig` (if provenance marker needed) | `d`, `e` | No |
| `g` | `manage_plugin` tool | new `core/tools/builtin/manage_plugin.zig` (+ register in `registry`/`runtime`), config mutation helper in `core/plugins/` (enable/disable via `file.zig`) | `d`, `f` | No |
| `h` | Review / regression / closeout decision | Full deliverable validation plus architectural judgment | all prior | No |

## Validation Expectations

- Signal 1: `zig build` succeeds with zero new warnings across the touched modules.
- Signal 2: `zig build test` — all existing tests pass plus new plugin tests (manifest disk parse, config gate, discovery hot-load, subprocess dispatch mock, catalog merge gated by config, manage_plugin list/enable/disable).
- Signal 3: With `plugins.enabled:false` (or absent), `renderCatalogJson` output is byte-identical to the pre-chain catalog (no silent expansion — I1/I2).
- Signal 4: With a fixture plugin enabled, its tool appears in catalog JSON, is review-gated, and dispatches through the subprocess transport (I3/I6).
- Per-unit test floor: every implementation unit provides at least 30 meaningful feature-value tests before archival, unless explicitly documentation/baseline-only with a written exemption (PLUGa is baseline-only and claims the exemption).
- Test-value rule: tests must prove the changed capability through the intended entrypoint (`renderCatalogJson`/`renderCatalog`, `executeWithRunner`, `manage_plugin` execute) and its valuable output path; manifest-struct-only or config-only assertions do not satisfy the floor for the runtime/dispatch slices.
- Evidence format expected: captured `zig build test` stdout showing new test names passing + captured catalog JSON excerpts proving opt-in gating.

## Current Frontier

No active frontier. Move40 deliberately deferred the plugin socket and removed
the default-visible `manage_plugin` placeholder. The retained manifest,
isolation, and socket types are contract-only scaffolding and do not advertise,
discover, or dispatch plugin capability.

## Stop Condition

The chain is superseded by Move40. No plugin implementation is claimed.

## Next todo

`NONE`

## Move40 Decision — 2026-08-13

The full plugin chain is deferred until a concrete user-facing plugin/tool
need exists. Recon found that `manage_plugin` was a default-visible builtin
whose enable/disable path was a TODO placeholder, while manifest/isolation/
socket contracts had no runtime consumer beyond synthetic tests. Move40
deleted the manager registration, dispatch branch, and placeholder file. The
contract-only types remain isolated for a future re-decomposition; they are not
an installed capability. Reopen with a new plan that uses the existing tool
definition, availability, review, dispatch, process, and event owners.
