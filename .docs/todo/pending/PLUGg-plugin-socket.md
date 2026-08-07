---
id: PLUGg-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: g
status: pending
patch_scope: "Add core/tools/builtin/manage_plugin.zig (list/info/enable/disable) mirroring the agents builtin + configure_agent pattern, register it in registry.zig/runtime.zig, and add a config-mutation helper in core/plugins/ (setPluginEnabled) that atomically upserts the plugins.enabled_plugins map under a mutex and validates the effective policy before writing config.json."
blast_radius: medium
blast_radius_justification: "Adds a new model-visible tool (manage_plugin) and mutates config.json (enable/disable). Containment: the tool is registered like any builtin; enable/disable mutate only the plugins.enabled_plugins map via the proven config-mutation pattern (validate-before-write, mutex). Direct consumers = provider tool-schema list (one new tool), config.json (mutations), discovery (hot-reads the mutated map on next call)."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Source additions are deterministic. enable/disable are themselves idempotent operations on the config map (upsert true/false). Condition: pre-PLUGg versions of registry.zig/runtime.zig intact and config-mutation helper not partially written. On PARTIAL recovery, verify registry/runtime compile and the helper compiles; re-execute from top. The config mutation is conditionally idempotent (upserting the same value twice yields the same file)."
acceptance: "manage_plugin list returns the discovered plugins with enabled/disabled state; info returns one plugin's manifest-derived descriptor + socket list; enable/disable round-trip through config.json and the next list reflects the change (hot-load); enable of an unknown plugin id fails closed; the tool is review-gated as write_capable and profile-gated (denied under recon/model_task)."
exit_criterion: "`zig build test` succeeds; new tests prove list reflects disk+policy, info returns descriptor, enable writes config + next list shows enabled, disable writes config + next list shows disabled, unknown-id rejected, tool is profile-denied under recon."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*manage_plugin.*pass|all tests passed|0 failed"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I8 (config mutation safety): enable/disable mutate config.json atomically under a mutex and validate the effective registry/policy before the file becomes visible"
  - "I5 (hot-load parity): a successful enable/disable is visible on the next manage_plugin list / discovery call without a restart"
  - "I7 (capability-profile preservation): manage_plugin is profile-gated like other write-capable tools"
source_message_anchor: "U1, U7, U10"
source_message_excerpt: "VANTARI knows about installed plugins and can discover/use them. ... Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs). ... A manage_plugin tool — list, enable, disable, info operations for the model to discover and manage plugins."
source_message_proof_obligation: "Give the model a tool to discover (list/info) and manage (enable/disable) installed plugins, hot-loading through config.json with the same validate-before-write + mutex discipline as configure_agent. This closes U10 (manage tool), U1 (model can discover plugins), and the enable/disable half of U7 (lifecycle)."
entry_state: "PLUGb/c/d/e/f archived. core/plugins/discovery.zig exposes loadPluginsForRuntime + PluginRegistry. core/config/file.zig exposes loadPluginPolicy + PluginPolicy + pluginDirectory + validateDocumentShape. core/agents/spec.zig is the config-mutation reference (config_mutation_mutex, mutateConfiguredAgent, MutationEvidence, upsertConfiguredAgent, ensureObjectField, putValue). registry.zig/runtime.zig register builtin tools via file_tool_definitions + executeWithRunner name checks. tools/builtin/agents.zig is the closest builtin analog (catalog + configure_agent)."
rollback_surface: "1. Revert apps/backend/src/core/tools/registry.zig (remove manage_plugin from file_tool_definitions + availability_entries). 2. Revert apps/backend/src/core/tools/runtime.zig (remove manage_plugin dispatch + toolClassForName entry). 3. Remove apps/backend/src/core/plugins/policy.zig (or wherever the mutation helper lives). 4. Remove apps/backend/src/core/tools/builtin/manage_plugin.zig. Order: registry/runtime first, then delete the helper + tool file."
dependencies: "PLUGd, PLUGf"
next_todo: /todo/pending/PLUGh-plugin-socket.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGg manage_plugin Tool

## Execute Now

Add a `manage_plugin` builtin tool (list/info/enable/disable) and a config-mutation helper so the model can discover and manage installed plugins, hot-loading through `config.json` with the same discipline as `configure_agent`.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must add only `core/tools/builtin/manage_plugin.zig`, a mutation helper in `core/plugins/` (e.g. `core/plugins/policy.zig` or extend an existing file), and the registration touches in `registry.zig`/`runtime.zig`. Must NOT change the subprocess transport, discovery semantics, or catalog provenance (already done). If a question arises about receipt shape, mirror `MutationEvidence` from `agents/spec.zig`.

## Why This Execution Unit Exists

The request explicitly asks for "a `manage_plugin` tool — list, enable, disable, info operations for the model to discover and manage plugins," and §V requires the model-visible surface to explain available tools. Without this tool, the model cannot see what is installed or actuate lifecycle (U7/U10). It is its own slice because (a) it adds a model-visible tool (medium blast radius — the schema list changes), (b) enable/disable mutate `config.json` and must reuse the proven `configure_agent` mutex + validate-before-write pattern (I8), and (c) it depends on discovery (PLUGd) and runtime registration (PLUGf) being stable. Sequencing after PLUGf is forced: the tool registers through the same spine PLUGf made plugin-aware.

## Better-Than-Before Delta

Pre-slice, there is no model-facing way to know what plugins are installed or to enable/disable them; "VANTARI knows about installed plugins" is false at the model layer. Post-slice, the model can list installed plugins (with enabled state), inspect a plugin's descriptor + sockets, and enable/disable — with every mutation hot-loading through the canonical config owner under a mutex, validated before it becomes visible. This lands the A4 ratchet (model can discover + manage) and closes the lifecycle loop (U7).

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Tool registration follows the builtin module pattern: a `definition` + `availability` + `execute`. | `tools/builtin/skills.zig` (definition+availability+execute), `registry.file_tool_definitions` + `availability_entries` (`registry.zig:37`,`registry.zig:57`), `runtime.executeWithRunner` name check (`runtime.zig:409`). | `manage_plugin.zig` exposes `definition` (review_risk write_capable), `availability`, `execute`; registered in `file_tool_definitions` + `availability_entries`; dispatched in `executeWithRunner`; mapped in `toolClassForName`. | Must NOT register manage_plugin outside the standard builtin path. |
| Config mutation = mutex + read-validate-write + content-hash receipt. | `agents/spec.zig config_mutation_mutex` (`spec.zig:78`), `mutateConfiguredAgent` (`spec.zig:330`), `MutationEvidence{config_path,action,agent_id,before/after bytes+sha}` (`spec.zig:63`), `ensureObjectField`/`putValue` helpers (`spec.zig:382`). | The plugin enable/disable helper locks a mutex, reads+validates config, mutates `plugins.enabled_plugins.<id>`, validates the effective `PluginPolicy` via `loadPluginPolicy`, writes atomically, returns a hash receipt. | Must NOT mutate config without the mutex or without validating the effective policy after the edit (I8). |
| list/info are read-only and always available; enable/disable are write-capable and profile-gated. | `review.reviewToolName` + `ensureToolAllowed` profile gate (PLUGf). | The tool's `action` enum (list/info/enable/disable) is carried in arguments; the whole tool is `write_capable` (because enable/disable mutate config) and denied under recon/model_task profiles. | Must NOT make manage_plugin read-only (it can mutate) or allow it under a read-only profile. |
| Hot-load: the mutation is visible on the next read without a restart. | `agents/spec.loadRegistry` re-reads config each call; PLUGd `loadPluginsForRuntime` re-reads disk each call. | After enable/disable, the next `manage_plugin list` and the next discovery/catalog build see the change. | Must NOT cache the policy/registry across the mutation. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Exact MutationEvidence + mutation-helper pattern to mirror. | Re-read `agents/spec.zig` `mutateConfiguredAgent`, `upsertConfiguredAgent`, `resetConfiguredAgent`, `MutationEvidence`, `ensureObjectField`, `putValue`, `putString`, `contentHash` (already read). | repository source | Confirms the helper's shape + receipt fields. | spec.zig functions cited. |
| How a builtin tool parses its action enum + renders output. | Re-read `tools/builtin/agents.zig` (catalog render) + `workspace_runtime.zig` (action enum: read/upsert/archive) (already read). | repository source | Confirms the `action`-dispatch + okEnvelope rendering pattern. | agents.zig + workspace_runtime.zig patterns. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | New `apps/backend/src/core/tools/builtin/manage_plugin.zig`; new helper in `apps/backend/src/core/plugins/policy.zig` (or extend an existing plugins file); `apps/backend/src/core/tools/registry.zig` (register definition + availability); `apps/backend/src/core/tools/runtime.zig` (dispatch name check + `toolClassForName` entry). Reuse `core/plugins/discovery.zig` (loadPluginsForRuntime), `core/config/file.zig` (loadPluginPolicy, validateDocumentShape, ensure, path), `core/agents/spec.zig` (MutationEvidence pattern, contentHash), `core/tools/module.zig` (okEnvelope). |
| Existing-owner decision | New builtin tool under `core/tools/builtin/` (the canonical builtin owner, §IX). New mutation helper under `core/plugins/` (plugin-contract code, §IX). Do NOT put config-mutation logic in `core/config/file.zig` beyond what PLUGc already added — the helper lives in `core/plugins/` and CALLS `file.zig`'s ensure/validate primitives (mirroring how `agents/spec.zig` owns agent mutation while calling `config/file.zig`). |
| Domain owner / canonical standard | AGENTS.md §V (catalog explains tools), §IX (tools under core/tools/, plugin contract under core/plugins/); the `agents`/`configure_agent` proven pattern. |
| Intended design | `manage_plugin.definition`: name `manage_plugin`, description "Discover and manage installed VANTARI plugins: list installed plugins, inspect a plugin's tools, enable or disable a plugin.", review_risk `.write_capable`, parameters_json with `action` enum [list, info, enable, disable], `plugin_id` (required for info/enable/disable), example_json, usage_hint. `execute(allocator, ec, arguments_json)`: parse action; `list` -> `loadPluginsForRuntime` + `loadPluginPolicy`, render a compact catalog (id, version, enabled state, tool-socket names); `info` -> render one plugin's descriptor + sockets (mirror agents compact catalog); `enable`/`disable` -> call the mutation helper, return a MutationEvidence-shaped receipt. The mutation helper `setPluginEnabled(allocator, workspace_root, plugin_id, enabled) !MutationEvidence`: locks `plugin_config_mutex`, `config.file.ensure`, reads+validates the document, upserts `plugins.enabled_plugins.<plugin_id>` = bool, validates the effective `PluginPolicy` via `loadPluginPolicy`, writes atomically, returns receipt (config_path, action, plugin_id, before/after bytes+sha). Reject unknown plugin ids (not present on disk) with a typed error. |
| Integration path | Registered as a builtin tool (catalog/provider schema via PLUGf's `effectiveDefinitionsForContext`, which already merges builtins). Dispatched in `executeWithRunner`. `toolClassForName("manage_plugin") = .file_write` (or a dedicated class if appropriate; lock: `.file_write` since it mutates config). Profile-gated: denied under recon/model_task. |
| Failure modes to prevent | Enabling a non-existent plugin id; mutating config without the mutex (race); writing config without validating the effective policy after the edit; leaking the receipt strings; list/info returning stale cached data; manage_plugin allowed under a read-only profile; receipt not proving the change (no before/after hash). |
| Alternatives rejected | Separate list_plugin/enable_plugin/disable_plugin tools (rejected: one tool with action enum matches the agents/workspace_runtime pattern); mutation via a separate state file (rejected: single canonical config owner, U9/I8); caching the policy in the tool (rejected: violates hot-load I5). |
| Proof hooks | Tests (tmp workspace + fixture plugin dir): list-empty; list-with-one-plugin shows id+version+enabled; info returns descriptor + socket names; enable writes config + next list shows enabled=true; disable writes config + next list shows enabled=false; enable-unknown-id -> typed error; the receipt has before/after sha differing; concurrent-ish (sequential under mutex) enable then disable round-trips; manage_plugin is denied under a recon profile (via ensureToolAllowed/toolClassForName); manage_plugin definition has review_risk write_capable. |

## Codebase Research And Execution Addendum

**Implementation map:** Create `apps/backend/src/core/tools/builtin/manage_plugin.zig` modeled on `tools/builtin/skills.zig` (definition+availability+execute) and `tools/builtin/agents.zig` (compact catalog render). Create `apps/backend/src/core/plugins/policy.zig` (or extend an existing plugins file) modeled on `agents/spec.zig`'s `mutateConfiguredAgent` + `MutationEvidence` + `contentHash`. Edit `apps/backend/src/core/tools/registry.zig`: add `manage_plugin.definition` to `file_tool_definitions` and an availability entry. Edit `apps/backend/src/core/tools/runtime.zig`: add `if (std.mem.eql(u8, tool_call.name, "manage_plugin")) return manage_plugin.execute(...)` in `executeWithRunner`; add `manage_plugin` to `toolClassForName` mapping (-> `.file_write`). Read before editing (already read): `registry.zig:37-71`, `runtime.zig:409-490`, `agents/spec.zig:266-380`, `tools/builtin/skills.zig`.

**Existing-owner directive:** New builtin in `core/tools/builtin/`; new mutation helper in `core/plugins/`. Both are the canonical locations (§IX).

**Directive:** The mutation helper MUST: (1) use a file-scoped `plugin_config_mutex: std.Thread.Mutex` (do NOT reuse agents' mutex — separate concern); (2) `config.file.ensure` the config exists; (3) read+validate via `config.file.readValidatedDocument`; (4) upsert `plugins.enabled_plugins.<id>` using the `ensureObjectField`/`putValue` pattern (copy the helper shape from spec.zig or factor a shared helper — lock: copy the small helpers locally to avoid cross-module coupling); (5) re-validate by calling `loadPluginPolicy` on the mutated value; (6) write atomically (write text); (7) return a `MutationEvidence`-shaped struct with before/after bytes + sha256 (reuse `spec.contentHash` or copy it). Reject `plugin_id` not matching any `<plugins_dir>/<id>/plugin.json` on disk.

**Locked `manage_plugin` definition:**
- name: `manage_plugin`
- description: "Discover and manage installed VANTARI plugins. Use list to see installed plugins and their enabled state, info to inspect a plugin's tool sockets and descriptors, enable/disable to hot-load or unload a plugin through config.json."
- review_risk: `.write_capable`
- parameters_json: object with `action` enum [list, info, enable, disable], `plugin_id` (string, required for info/enable/disable), `additionalProperties: false`.
- example_json: `{"action":"list"}` and `{"action":"enable","plugin_id":"tickets"}`
- usage_hint: "Call list first. enable/disable hot-load through config.json and take effect on the next tool catalog. Enable only plugin ids returned by list."

**Gold-standard guardrail:** Do NOT allow manage_plugin to bypass the profile gate (it must be denied under recon/model_task). Do NOT mutate config without validating the effective policy afterward (a malformed edit must not leave config in an invalid state). Do NOT cache the policy/registry across the mutation.

**Knowledge gathering route:** Repository-local only (spec.zig mutation pattern, agents.zig/skills.zig builtin pattern, registry/runtime registration). No external research.

**Runtime visualization:** model calls `manage_plugin {action:list}` -> `loadPluginsForRuntime` + `loadPluginPolicy` -> render compact catalog (id, version, enabled, tool names). Model calls `manage_plugin {action:enable, plugin_id:"tickets"}` -> `setPluginEnabled` -> mutex lock -> read+validate config -> upsert `plugins.enabled_plugins.tickets=true` -> `loadPluginPolicy` re-validate -> write config.json -> receipt (before/after sha). Next `manage_plugin list` / discovery / catalog build -> sees `tickets` enabled (hot-load).

**Proof expansion:** Add ≥30 meaningful tests with a tmp workspace + fixture plugin dir: list-empty, list-one (assert id+version+enabled-state), info-one (assert descriptor fields + socket names), enable-known (assert receipt + config file mutated + next list shows enabled), disable-known (round-trip), enable-unknown-id (typed error), receipt before/after sha differ, mutation validates effective policy (a malformed mutation is rejected), profile denial under recon (via `ensureToolAllowed`/`toolClassForName`), definition review_risk is write_capable, `additionalProperties:false` enforced, hot-load (enable then immediately list reflects it). Use `std.testing.allocator` for leak checks.

**Action-mode arbitration:** enable/disable are immediate config mutations (not deferred); the receipt is the terminal proof (config file sha changed). list/info are immediate reads. No queued work.

## Embedded Framing

The model can only use what it can see and govern: manage_plugin must let it list installed plugins, inspect their descriptors, and enable/disable them — with every mutation hot-loading through the canonical config owner under a mutex, validated before it becomes visible, because an unvalidated or cached mutation is silent drift (F4, I5, I8, U7, U10).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Decision It Controls |
|---|---|---|---|---|
| None external. | The tool + mutation pattern are repo-local proven (agents.zig, skills.zig, spec.zig mutateConfiguredAgent). | N/A | repository source | This slice's tests prove list/info/enable/disable match the locked behavior. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U1 | "VANTARI knows about installed plugins and can discover/use them." | `manage_plugin list`/`info` return the installed set + descriptors. | `test`: list-one + info-one assertions. |
| U7 | "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)." | enable/disable round-trip through config + hot-load on next read. | `test`: enable round-trip + hot-load list reflects it. |
| U10 | "A manage_plugin tool — list, enable, disable, info operations for the model to discover and manage plugins." | The tool exposes list/info/enable/disable. | `test`: each action exercised; definition review_risk write_capable. |

## Pre-flight Checklist

- [ ] `PLUGd`, `PLUGf` archived with non-PLACEHOLDER evidence.
- [ ] `entry_state` claims verifiable: `loadPluginsForRuntime`, `loadPluginPolicy`, `config.file.ensure/readValidatedDocument`, spec.zig mutation pattern all present.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (medium — new tool + helper + registration).
- [ ] Idempotency contract read (conditionally-idempotent; verify file integrity before re-execute).
- [ ] No other slice being advanced.
- [ ] Slice Research Directive records local baseline (repo-only), no external research.

## Entry State

- PLUGd archived: `loadPluginsForRuntime` + `PluginRegistry`.
- PLUGf archived: `effectiveDefinitionsForContext` merges builtins (so manage_plugin will appear once registered), `executeWithRunner` dispatch path stable, `toolClassForName` extensible.
- `agents/spec.zig` is the mutation-pattern reference.
- No `manage_plugin.zig`; no plugin config-mutation helper.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/tools/registry.zig` — add `manage_plugin.definition` to `file_tool_definitions` + an `availability_entries` row.
- `apps/backend/src/core/tools/runtime.zig` — add `manage_plugin` dispatch in `executeWithRunner`; add `manage_plugin` -> `.file_write` in `toolClassForName`.

**Adds:**
- `apps/backend/src/core/tools/builtin/manage_plugin.zig` — definition, availability, execute (list/info/enable/disable), tests.
- `apps/backend/src/core/plugins/policy.zig` (or extend an existing plugins file) — `setPluginEnabled`, `plugin_config_mutex`, receipt struct (mirror MutationEvidence), tests.

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/plugins/discovery.zig`, `subprocess.zig`, `manifest.zig`, `isolation.zig` (consumed, not modified).
- `apps/backend/src/core/tools/runtime.zig` plugin-merge logic (done in PLUGf) — only add the manage_plugin dispatch + class entry here.
- `apps/backend/src/core/agents/spec.zig` (reference only).

## Detailed Requirements

- R1: `manage_plugin.zig` exposes `pub const definition` (locked shape), `pub const availability = module.AvailabilitySpec{}`, `pub fn execute(allocator, ec, arguments_json) ![]u8`.
- R2: `execute` parses `action` (list/info/enable/disable) + `plugin_id`. `list`: `loadPluginsForRuntime` + `loadPluginPolicy`, render compact catalog (id, version, enabled, tool-socket names) via `module.okEnvelope`. `info`: render one plugin's descriptor + sockets. `enable`/`disable`: call `setPluginEnabled`, return the receipt text.
- R3: `setPluginEnabled(allocator, workspace_root, plugin_id, enabled) !PluginMutationEvidence` in `core/plugins/policy.zig`: mutex lock; reject unknown id (no `<plugins_dir>/<plugin_id>/plugin.json`); ensure config; read+validate; upsert `plugins.enabled_plugins.<id>`; re-validate via `loadPluginPolicy`; write; return receipt (config_path, action enable/disable, plugin_id, before/after bytes + sha256).
- R4: Register `manage_plugin` in `registry.file_tool_definitions` + `availability_entries`; dispatch in `runtime.executeWithRunner`; map in `toolClassForName` -> `.file_write`.
- R5: ≥30 tests (see Proof expansion) with tmp workspace + fixture plugin dir + `std.testing.allocator`.

## Invariants This Unit Must Preserve

- I8: mutation under mutex + validate-before-write + receipt (R3 + tests).
- I5: mutation visible on next read (R2/R3 + hot-load test).
- I7: manage_plugin profile-gated as write_capable (R4 + test).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | manage_plugin tests pass; "0 failed" | yes (conditional on file integrity) |

**Evidence to capture:** `zig build test` tail showing manage_plugin tests passing + a captured list/info/enable round-trip excerpt.

## Exit State (Handoff Contract)

- `core/tools/builtin/manage_plugin.zig` exposes list/info/enable/disable; registered + dispatched; profile-gated.
- `core/plugins/policy.zig` exposes `setPluginEnabled` with mutex + validate-before-write + receipt.
- The model can discover and manage plugins; enable/disable hot-load through config.json.
- PLUGh may begin the terminal review verifying every source anchor, invariant, and architectural target across the whole chain.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/tools/registry.zig` (remove manage_plugin registration).
2. `git checkout -- apps/backend/src/core/tools/runtime.zig` (remove dispatch + class entry).
3. `rm apps/backend/src/core/tools/builtin/manage_plugin.zig`.
4. `rm apps/backend/src/core/plugins/policy.zig` (or revert the extended file).
5. Re-run `zig build test`.

## Next todo

`/todo/pending/PLUGh-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests (list-empty/one, info-one, enable/disable round-trip, enable-unknown-id error, receipt sha, policy re-validation, profile denial, review_risk, hot-load, leak checks).
- [ ] Tests prove manage_plugin through `execute` (the real consumer path) + `setPluginEnabled` through config.json.
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: list/info/enable/disable work; mutations hot-load; profile-gated.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGg-plugin-socket.md /todo/changelog/PLUGg-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
