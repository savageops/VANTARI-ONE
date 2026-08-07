---
id: PLUGf-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: f
status: pending
patch_scope: "Wire plugin tools into the existing tool-runtime spine: merge enabled plugin tool definitions into builtinDefinitionsForContext (catalog + provider schema), add a plugin dispatch branch in executeWithRunner that calls dispatchPluginTool, extend availabilitySpec/resolveAvailability and toolClassForName to recognize plugin tool names, and render provenance (ToolSource.plugin) in the catalog. Plugin tools obey the same ensureToolAllowed profile gate and review.reviewToolName gate as builtins."
blast_radius: medium
blast_radius_justification: "Modifies the shared catalog/dispatch path (runtime.builtinDefinitionsForContext, executeWithRunner, registry.availabilitySpec/resolveAvailability, runtime.toolClassForName) consumed by the provider tool-schema builder and the review gate. Containment: all additions are gated by loadPluginPolicy (default OFF), so with plugins disabled the catalog is byte-identical to today; with plugins enabled, additions are additive ToolDefinitions vetted by the existing review gate. Direct consumers = provider schema list, review gate, dispatch loop."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Source edits are deterministic. Condition: the pre-PLUGf versions of runtime.zig and registry.zig are intact and PLUGb/c/d/e are archived. On PARTIAL recovery, verify both files compile; if a partial edit left either non-compiling, revert both before re-executing. The hot-load registry is re-read on each call so no runtime cache state needs recovery."
acceptance: "With plugins disabled, renderCatalogJson output is unchanged (no plugin tools) AND existing tool tests pass; with a fixture plugin enabled, its tool appears in the catalog with provenance, is availability-resolvable, is review-gated (invalid risk rejected before dispatch), dispatches via dispatchPluginTool through an injected CommandRunner, and is denied under a profile that disallows its tool class."
exit_criterion: "`zig build test` succeeds; new tests prove (1) disabled->no plugin tool in catalog, (2) enabled+per-plugin->tool present with provenance, (3) availability resolves for plugin tool, (4) review rejects unknown/invalid-risk plugin tool before dispatch, (5) dispatch routes to dispatchPluginTool, (6) profile gate denies disallowed class; existing catalog/dispatch tests still pass."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*runtime.*pass|all tests passed|0 failed"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I1 (opt-in truth): catalog/provider/dispatch contain zero plugin tools when plugins disabled or absent"
  - "I2 (no silent expansion): plugin tool requires valid manifest + plugins.enabled + per-plugin enable"
  - "I3 (review gate preservation): review.reviewToolName treats plugin ToolDefinitions identically to builtins; invalid risk rejected"
  - "I7 (capability-profile preservation): ensureToolAllowed + toolClassForName gate plugin tools by profile exactly as builtins"
source_message_anchor: "U2, U6"
source_message_excerpt: "Plugin tools are opt-in and must not silently alter the model-visible tool list ... Plugin tool socket — how plugin-provided tools integrate into the existing registry.zig + runtime.zig dispatch chain."
source_message_proof_obligation: "Integrate plugin tools into the existing catalog/provider-schema/availability/review/dispatch/profile spine so a plugin tool traverses the exact same path as a builtin, with the only new branch being the subprocess transport (PLUGe), not the gating. This closes U6 (tool-socket integration) and mechanically enforces U2/I1/I2/I3/I7 at the runtime layer."
entry_state: "PLUGb/c/d/e archived. core/plugins/discovery.zig exposes loadPluginsForRuntime + PluginRegistry + findTool + LocatedTool. core/plugins/subprocess.zig exposes dispatchPluginTool(allocator, runner, plugin, socket, tool_name, args, transport). core/tools/runtime.zig builtinDefinitionsForContext returns compiled-in slices; executeWithRunner dispatches by name with no plugin branch; toolClassForName maps known builtin names. core/tools/registry.zig availabilitySpec/resolveAvailability know only builtin names. core/tools/review.zig reviewToolName is generic over []const ToolDefinition. core/tools/sockets.zig exposes ToolSource=builtin|plugin."
rollback_surface: "1. Revert apps/backend/src/core/tools/registry.zig (availability/resolveAvailability plugin branches). 2. Revert apps/backend/src/core/tools/runtime.zig (builtinDefinitionsForContext merge, executeWithRunner plugin branch, toolClassForName plugin mapping, catalog provenance). Order: runtime.zig last (it consumes registry helpers). Re-running zig build test confirms restoration."
dependencies: "PLUGb, PLUGc, PLUGd, PLUGe"
next_todo: /todo/pending/PLUGg-plugin-socket.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGf Runtime Tool-Socket Integration

## Execute Now

Wire enabled plugin tools into `runtime.builtinDefinitionsForContext` (catalog + provider schema), `executeWithRunner` (dispatch via `dispatchPluginTool`), `registry.availabilitySpec`/`resolveAvailability`, and `toolClassForName`, preserving the review gate and profile gate — so a plugin tool traverses the same spine as a builtin.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must touch only `core/tools/runtime.zig`, `core/tools/registry.zig`, and (if needed for provenance) `core/tools/sockets.zig` — must NOT add `manage_plugin` (PLUGg), must NOT modify the plugin manifest/discovery/subprocess modules (already done), and must NOT change `review.zig` (it is already generic over `[]const ToolDefinition`). If a question arises about provider-schema consumption, find the real caller; do not assume a second schema-build site without proof.

## Why This Execution Unit Exists

This is the slice where the plugin socket becomes reachable from the model's reality: the catalog the provider sees, the review gate that approves/blocks tool calls, and the dispatch loop that executes them. Everything before this (PLUGb–PLUGe) built stable primitives; nothing was model-visible. This slice must be its own unit because (a) it modifies the shared spine (medium blast radius), (b) the opt-in invariant (I1/I2) is only mechanically true once the catalog merge is gated by `loadPluginPolicy`, and (c) the review/profile gates (I3/I7) must be proven to apply to plugin tools identically — not assumed. Sequencing after PLUGd (registry) and PLUGe (transport) is forced: there is nothing to integrate without them.

## Better-Than-Before Delta

Pre-slice, `ToolSource.plugin` is a declared-but-dead discriminator and the catalog treats every tool as builtin. Post-slice, the runtime distinguishes provenance, renders it, and routes plugin tools through the identical review/availability/dispatch/profile path as builtins — with the subprocess transport as the only new branch. The opt-in invariant becomes testable end-to-end (catalog is byte-identical when disabled; plugin tool appears only when enabled). This is the A1+A2+A3 ratchet landing at once: dead contracts become live capability, opt-in is mechanically enforced, and provenance is visible.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| The provider tool schema is built from the slice `builtinDefinitionsForContext` returns. | `renderCatalog`/`renderCatalogJson` iterate `builtinDefinitionsForContext` (`runtime.zig:128`, `runtime.zig:168`). | Merging plugin ToolDefinitions into that slice is sufficient for the model to see them — verify there is no second schema-build site. | Must NOT assume a second site without grepping; if one exists, extend it too. |
| The review gate is generic over the active definitions list. | `review.reviewToolName(tool_name, active_definitions)` (`review.zig:18`); the dispatch loop must pass the SAME list the catalog advertised. | The dispatch path must resolve the plugin tool's review_risk from its ToolDefinition; unknown tools are blocked (`review.zig:24`). | Must NOT bypass review for plugin tools; must NOT advertise a plugin tool in catalog but omit it from the dispatch-time definitions. |
| Profile gating uses toolClassForName + profile_contract.ensureToolClass. | `ensureToolAllowed` -> `toolClassForName` -> `ensureToolClass` (`runtime.zig:456`, `runtime.zig:473`). | `toolClassForName` must map plugin tool names to a class (derived from their review_risk or an explicit manifest field) so the profile gate applies. | Must NOT leave plugin tools unmapped (UnknownTool) or map them to a class that bypasses profile restrictions. |
| Availability resolution must cover plugin tools (they may declare dependencies). | `registry.resolveAvailability` + `availabilitySpec` (`registry.zig:81`, `registry.zig:73`); manifest carries `dependencies` metadata. | A plugin tool's availability reflects its declared dependencies (e.g. external_command); unavailable -> ToolUnavailable, not silent dispatch. | Must NOT dispatch a plugin tool whose declared dependency is unavailable. |
| Opt-in is enforced at the merge point, not assumed elsewhere. | §V; PLUGc `loadPluginPolicy`. | `builtinDefinitionsForContext` calls `loadPluginPolicy` + `loadPluginsForRuntime`; if disabled, appends zero plugin definitions. | Must NOT merge plugin definitions unconditionally. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Whether a second provider-schema build site exists besides `builtinDefinitionsForContext`. | `ix search "ToolDefinition" --type zig` in apps/backend/src; inspect callers of `renderCatalogJson`/`builtinDefinitionsForContext`. | repository source | Confirms merging into `builtinDefinitionsForContext` is sufficient (or names the second site). | PLUGf addendum: grep result + caller list. |
| How toolClassForName should classify plugin tools (explicit manifest field vs review_risk derivation). | Re-read `toolClassForName` (`runtime.zig:473`) + `profile_contract.ToolClass` + `ToolRiskClass` (`types.zig:413`). | repository source | Lock: derive class from the plugin tool's review_risk (read_only->file_read, write_capable->file_write, command_execution->command, delegating->delegation) OR require an explicit `tool_class` manifest field. Pick the explicit-field option for clarity. | Decision recorded below in Detailed Requirements. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `apps/backend/src/core/tools/runtime.zig` (builtinDefinitionsForContext, executeWithRunner, toolClassForName, renderCatalog, renderCatalogJson), `apps/backend/src/core/tools/registry.zig` (availabilitySpec, resolveAvailability), `apps/backend/src/core/tools/sockets.zig` (ToolSource — consume, possibly extend ToolDefinition rendering), `apps/backend/src/core/plugins/discovery.zig` (loadPluginsForRuntime, findTool, LocatedTool), `apps/backend/src/core/plugins/subprocess.zig` (dispatchPluginTool), `apps/backend/src/core/config/file.zig` (loadPluginPolicy, pluginDirectory). |
| Existing-owner decision | Extend the canonical tool-runtime owners `runtime.zig` + `registry.zig`. Do NOT create a parallel plugin catalog or plugin dispatch module. The plugin modules (discovery/subprocess) stay in `core/plugins/` and are only CALLED from `core/tools/`. |
| Domain owner / canonical standard | AGENTS.md §V (tool runtime contract: definition + availability + review_risk + execute -> catalog -> schema -> review -> dispatch -> evidence), §IX (runtime contracts under core/tools/). |
| Intended design | (1) `builtinDefinitionsForContext(ec)`: after computing the builtin slice, if `ec` carries a plugin-policy-enabled flag (or by calling `loadPluginPolicy` + `loadPluginsForRuntime` inside), append a `types.ToolDefinition` per enabled plugin tool socket (built from the manifest descriptor fields). The merge MUST be gated so disabled -> zero additions. Because the current function returns a comptime-known slice, refactor to return a runtime-built slice (allocator) OR provide a sibling `effectiveDefinitionsForContext(allocator, ec)` that the catalog/dispatch call instead — lock: add `effectiveDefinitionsForContext(allocator, ec) ![]types.ToolDefinition` that allocates builtin + plugin defs, and update `renderCatalog`/`renderCatalogJson`/`executeWithRunner` to use it. Keep `builtinDefinitionsForContext` for callers that want only builtins. (2) `executeWithRunner`: before the UnknownTool return, if `findTool(registry, tool_call.name)` hits, call `dispatchPluginTool(...)` with the injected `runner` (or the default runner), gated by the same `ensureToolAllowed` already at the top. (3) `registry.availabilitySpec`/`resolveAvailability`: accept an optional registry (or a new overload `resolvePluginAvailability`) that checks the plugin tool's manifest dependencies; wire dispatch path to consult it so unavailable plugin tools return ToolUnavailable. (4) `toolClassForName`: accept a registry (or a new `toolClassForNameWithRegistry`) and map the plugin tool via an explicit `tool_class` field on the manifest socket (lock: add `tool_class: ?[]const u8` to `PluginSocket` in PLUGb if not already; if not added there, this slice adds it — flag as a PLUGb dependency touch). (5) Catalog rendering: when emitting a plugin tool, include a `source`/provenance marker (`"plugin"`) and optionally the plugin id. |
| Integration path | Provider schema + model catalog via `renderCatalog`/`renderCatalogJson` -> `effectiveDefinitionsForContext`. Review via `review.reviewToolName` called with the same effective list. Dispatch via `executeWithRunner` -> plugin branch -> `dispatchPluginTool`. Availability via `resolveAvailability`/`resolvePluginAvailability`. Profile via `ensureToolAllowed` -> `toolClassForNameWithRegistry` -> `ensureToolClass`. |
| Failure modes to prevent | Plugin tool advertised when disabled (I1 breach); plugin tool advertised but not dispatchable (catalog/dispatch definition drift — I3 breach); plugin tool bypassing review; plugin tool bypassing profile gate (I7 breach); plugin tool with unavailable dependency dispatched anyway; memory leak in the runtime-built effective definitions slice; comptime-slice assumption broken (refactor must not break existing callers). |
| Alternatives rejected | A separate plugin catalog/dispatch (rejected: violates "one spine" F1); mapping plugin tool class by guessing from review_risk (rejected: explicit manifest field is clearer and operator-controlled); leaving ToolSource as dead code (rejected: A3 ratchet requires provenance rendered). |
| Proof hooks | Tests: (a) disabled -> `effectiveDefinitionsForContext` returns only builtins (byte-identical catalog); (b) enabled+fixture-plugin -> catalog JSON contains the plugin tool with `source:plugin`; (c) `resolveAvailability` for a plugin tool with an unavailable external_command dependency -> unavailable; (d) `review.reviewToolName` with a plugin tool of invalid risk -> blocked; (e) `executeWithRunner` with an injected stub runner routes a plugin tool call to `dispatchPluginTool` (spy on the runner); (f) under a `recon` profile, a plugin tool whose `tool_class` is `file_write` -> CapabilityDenied; (g) existing `tool catalog includes the built-in coding tools` test still passes. |

## Codebase Research And Execution Addendum

**Implementation map:** Edit `apps/backend/src/core/tools/runtime.zig`. Read before editing (already read): `builtinDefinitionsForContext` (line 100), `executeWithRunner` (line 401), `ensureToolAllowed` (line 456), `toolClassForName` (line 473), `renderCatalog` (line 128), `renderCatalogJson` (line 168). Edit `apps/backend/src/core/tools/registry.zig`: `availabilitySpec` (line 73), `resolveAvailability` (line 81). The comptime-slice return type of `builtinDefinitionsForContext` (`[]const types.ToolDefinition` pointing into comptime arrays) cannot append runtime plugin defs — so add a NEW allocator-building function `effectiveDefinitionsForContext(allocator, ec) ![]types.ToolDefinition` that clones builtin defs + appends plugin defs, and switch catalog/dispatch/review callers to it. Keep `builtinDefinitionsForContext` for any caller that intentionally wants only builtins.

**Existing-owner directive:** Extend `core/tools/runtime.zig` + `registry.zig`. They are the canonical tool-runtime owners (§IX). Do NOT create a plugin runtime module.

**Directive:** The plugin branch in `executeWithRunner` must come AFTER `ensureToolAllowed(ec, tool_name)` (already called at the top) so profile gating applies, and the tool must be findable in the effective definitions used by the review gate. Concretely: the dispatch loop should consult `effectiveDefinitionsForContext` (or a once-per-turn resolution passed in) so `review.reviewToolName` and the dispatch agree on the tool set. If `executeWithRunner` currently dispatches by name without a definitions list, the review gate is applied upstream — confirm where `review.reviewToolName` is called and ensure it receives the effective (builtin+plugin) list when plugins are enabled. The plugin dispatch branch calls `dispatchPluginTool` with the `runner` already threaded into `executeWithRunner`.

**Locked decisions:**
- D1: Add an explicit `tool_class: ?[]const u8 = null` to `PluginSocket` (if not already in PLUGb; if missing, this slice amends `manifest.zig` — declare manifest.zig as a touch in Patch Surface and add a PLUGb-note). Valid values: `file_read`, `file_write`, `command`, `scheduling`, `delegation`, `workspace_state` (the `profile_contract.ToolClass` variants). `toolClassForNameWithRegistry` maps a plugin tool to this class. A plugin tool without `tool_class` is rejected at validate time (extend `validateManifest` if not done in PLUGb).
- D2: Provenance rendering — catalog JSON emits `"source":"plugin"` and `"plugin":"<id>"` for plugin tools; builtins emit `"source":"builtin"` (additive, does not change existing builtin fields). Catalog text emits a `(plugin: <id>)` suffix on the tool line.
- D3: The effective-definitions allocation is owned by the caller and freed after the turn/dispatch; do NOT cache.

**Gold-standard guardrail:** Do NOT let the plugin dispatch branch skip `ensureToolAllowed`. Do NOT advertise a plugin tool in the catalog that is absent from the dispatch-time effective definitions. Do NOT map a plugin tool to a class that a restrictive profile would allow when it should deny (e.g. a write-capable plugin tool must be `file_write`, denied under recon).

**Knowledge gathering route:** Run the RCH probes (grep for ToolDefinition callers; confirm `review.reviewToolName` call site and what list it receives). Read `profile_contract.zig` for the `ToolClass` enum + `ensureToolClass` to confirm class names. All repo-local.

**Runtime visualization:** provider turn -> `renderCatalogJson(ec)` -> `effectiveDefinitionsForContext(allocator, ec)` -> `loadPluginPolicy`; if disabled -> builtin defs only; if enabled -> `loadPluginsForRuntime` -> for each plugin tool socket, build `ToolDefinition{name,description,parameters_json,review_risk,usage_hint,example_json}` + append -> catalog JSON includes plugin tools with `source:plugin`. Model calls plugin tool -> `executeWithRunner` -> `ensureToolAllowed` (profile gate via `toolClassForNameWithRegistry`) -> review gate (via effective definitions) -> plugin branch -> `dispatchPluginTool(runner, plugin, socket, name, args, transport)` -> subprocess (PLUGe) -> `okEnvelope`.

**Proof expansion:** Add ≥30 meaningful tests: (1) disabled-catalog byte-equality (snapshot of builtin-only catalog vs pre-chain); (2) enabled+fixture plugin -> catalog contains tool with `source:plugin` + `plugin:<id>`; (3) `effectiveDefinitionsForContext` frees under testing.allocator; (4) `resolveAvailability` for plugin tool with available/unavailable dependency; (5) review blocks invalid-risk plugin tool; (6) dispatch routes to dispatchPluginTool via injected spy runner; (7) profile denial under recon for a file_write plugin tool; (8) profile allowance under root for the same; (9) orchestrator_only still denies plugin tools that aren't delegation; (10) existing builtin catalog test still passes. Use a fixture plugin dir under a test-fixtures location (NOT core/) and an injected CommandRunner.

**Action-mode arbitration:** N/A (synchronous dispatch; the subprocess timeout is the bounded-execution receipt from PLUGe).

## Embedded Framing

One socket, two sources: the plugin tool must walk the identical catalog->schema->review->dispatch->profile spine as a builtin, differ only in transport (subprocess vs in-process), and never appear when the opt-in gate is closed — because the moment a plugin tool bypasses review, profiles, or the opt-in gate, the socket has become an execution hole (F1, F2, I1, I2, I3, I7).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Decision It Controls |
|---|---|---|---|---|
| Confirm provider-schema build site(s). | Ensures merging into effectiveDefinitionsForContext reaches the provider. | `ix search "renderCatalogJson\|builtinDefinitionsForContext\|ToolDefinition" --type zig` | repository source | Whether a second schema site needs the same merge. |
| Confirm review.reviewToolName call site + list source. | Ensures plugin tools are review-gated at dispatch. | `ix search "reviewToolName\|reviewToolCall"` | repository source | Where to inject the effective definitions list. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U2 | "Plugin tools are opt-in and must not silently alter the model-visible tool list" | `effectiveDefinitionsForContext` returns only builtins when disabled; catalog byte-identical. | `test`: disabled-catalog byte-equality; enabled-adds-tool. |
| U6 | "Plugin tool socket — how plugin-provided tools integrate into the existing registry.zig + runtime.zig dispatch chain" | Plugin tools merge into catalog/provider schema, are availability-resolvable, review-gated, profile-gated, and dispatched via the existing chain + dispatchPluginTool. | `test`: catalog contains plugin tool; dispatch routes via spy runner; profile denies disallowed class. |

## Pre-flight Checklist

- [ ] `PLUGb`, `PLUGc`, `PLUGd`, `PLUGe` archived with non-PLACEHOLDER evidence.
- [ ] `entry_state` claims verifiable: `loadPluginsForRuntime`, `dispatchPluginTool`, `loadPluginPolicy`, `ToolSource` all exist.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (medium blast radius — revert runtime.zig + registry.zig).
- [ ] Idempotency contract read (conditionally-idempotent; verify file integrity before re-execute).
- [ ] No other slice being advanced.
- [ ] Slice Research Directive records the two repo-local probes + closure plan.

## Entry State

- PLUGb/c/d/e archived: `loadPluginsForRuntime`, `dispatchPluginTool`, `loadPluginPolicy`, descriptor-bearing `PluginSocket` (with `tool_class` if added by this slice), `ToolSource` all available.
- `runtime.builtinDefinitionsForContext` returns comptime builtin slices; no plugin merge.
- `executeWithRunner` dispatches by name with no plugin branch; `ensureToolAllowed` at top.
- `registry.availabilitySpec`/`resolveAvailability` know only builtin names.
- `toolClassForName` maps only builtin names.
- `review.reviewToolName` is generic over `[]const ToolDefinition`.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/tools/runtime.zig` — add `effectiveDefinitionsForContext(allocator, ec) ![]types.ToolDefinition`; switch `renderCatalog`/`renderCatalogJson` to it; add plugin dispatch branch in `executeWithRunner` calling `dispatchPluginTool`; add `toolClassForNameWithRegistry` (or extend `toolClassForName`) to map plugin tools via manifest `tool_class`; render provenance (`source`/`plugin`) in catalog text + JSON.
- `apps/backend/src/core/tools/registry.zig` — add plugin-aware availability (e.g. `resolvePluginAvailability` or extend `resolveAvailability` to consult a registry) so plugin tool dependencies gate dispatch.
- `apps/backend/src/core/plugins/manifest.zig` — (only if D1 `tool_class` not added in PLUGb) add `tool_class: ?[]const u8` to `PluginSocket` + require it for tool sockets in `validateManifest`. If this touch is needed, note that PLUGb's exemption was incomplete and this slice closes it.

**Adds:**
- (new functions inside existing files; no new modules)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/tools/builtin/manage_plugin.zig` (PLUGg).
- `apps/backend/src/core/tools/review.zig` (already generic; no change needed).
- `apps/backend/src/core/plugins/discovery.zig`, `subprocess.zig`, `isolation.zig` (consumed, not modified — except the manifest.zig `tool_class` touch noted above).

## Detailed Requirements

- R1: Add `pub fn effectiveDefinitionsForContext(allocator, ec) ![]types.ToolDefinition` that clones builtin defs (from `builtinDefinitionsForContext(ec)`) and, if `loadPluginPolicy(...).enabled`, appends a `ToolDefinition` per enabled plugin tool socket from `loadPluginsForRuntime(...)`. Free on error path. Caller owns + frees.
- R2: `renderCatalog`/`renderCatalogJson` use `effectiveDefinitionsForContext`; emit `source`/`plugin` provenance for plugin tools (D2). With plugins disabled, output is byte-identical to pre-chain (existing builtin fields unchanged; provenance `source:builtin` is additive only if it does not alter the existing byte-equality test — lock: do NOT add `source` to builtins if it breaks the existing catalog test; add provenance only to plugin tools).
- R3: `executeWithRunner`: after the existing builtin name checks and before `return Error.UnknownTool`, add `if (plugins.enabled and findTool(registry, name) hit) return dispatchPluginTool(allocator, runner, plugin, socket, name, args, transport)`. The `ensureToolAllowed` at the top must govern this branch. Resolve the registry via `loadPluginsForRuntime` (hot-load) or accept a pre-resolved registry threaded from the caller — lock: re-resolve via `loadPluginsForRuntime` inside the branch (keeps the signature stable; hot-load is cheap and correct).
- R4: `registry`: add the ability to resolve availability for a plugin tool from its manifest dependencies (external_command etc.). Unavailable dependency -> `ToolUnavailable`, not dispatch.
- R5: `toolClassForName`/`toolClassForNameWithRegistry`: map plugin tool -> `profile_contract.ToolClass` from manifest `tool_class` (D1). Unknown/unmapped -> UnknownTool (denied).
- R6: Ensure `review.reviewToolName` is called (wherever the dispatch loop applies review) with the effective definitions so plugin tools are review-gated. If review is currently applied with only builtin defs, switch to effective defs when plugins enabled.
- R7: ≥30 tests (see Proof expansion) using a fixture plugin dir + injected CommandRunner.

## Invariants This Unit Must Preserve

- I1: `effectiveDefinitionsForContext` returns only builtins when disabled (R1 + byte-equality test).
- I2: plugin tool requires valid manifest + enabled + per-plugin enable (R1 + test).
- I3: review gate applies to plugin tools via effective definitions (R6 + test).
- I7: profile gate applies via `toolClassForNameWithRegistry` (R5 + test).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | runtime/dispatch tests pass including new plugin integration tests; "0 failed"; existing "tool catalog includes the built-in coding tools" still passes | yes (conditional on file integrity) |

**Evidence to capture:** `zig build test` tail showing the new integration tests passing + the existing catalog test still passing, plus a captured catalog JSON excerpt proving (a) no plugin tool when disabled and (b) a plugin tool with `source:plugin` when enabled.

## Exit State (Handoff Contract)

- `runtime.effectiveDefinitionsForContext` merges plugin defs (gated by policy); catalog/provider schema include plugin tools only when enabled.
- `executeWithRunner` dispatches plugin tools via `dispatchPluginTool`, governed by `ensureToolAllowed` + review.
- `registry` resolves plugin-tool availability from manifest dependencies.
- `toolClassForNameWithRegistry` maps plugin tools to a profile class.
- With plugins disabled, the catalog is byte-identical to pre-chain (I1 proven).
- PLUGg may begin adding the `manage_plugin` tool, consuming `loadPluginsForRuntime` for list/info and the config mutation helper for enable/disable.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/tools/registry.zig` (revert plugin availability).
2. `git checkout -- apps/backend/src/core/tools/runtime.zig` (revert effectiveDefinitionsForContext, dispatch branch, toolClass mapping, provenance).
3. If manifest.zig `tool_class` was added here, `git checkout -- apps/backend/src/core/plugins/manifest.zig` to the PLUGb state.
4. Re-run `zig build test` to confirm the pre-PLUGf set passes.

## Next todo

`/todo/pending/PLUGg-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests (disabled byte-equality, enabled-adds-tool, availability, review-block, dispatch routing via spy runner, profile deny/allow, orchestrator_only, provenance, existing catalog test).
- [ ] Tests prove the integration through `renderCatalogJson`/`executeWithRunner`/`review.reviewToolName` (the real consumer paths).
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: disabled catalog byte-identical; plugin tool traverses review+profile+dispatch.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGf-plugin-socket.md /todo/changelog/PLUGf-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
