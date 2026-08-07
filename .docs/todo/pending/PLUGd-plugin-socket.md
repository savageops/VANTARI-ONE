---
id: PLUGd-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: d
status: pending
patch_scope: "Add core/plugins/discovery.zig: scan the effective plugins directory for <id>/plugin.json, parse + validate each via the PLUGb parser/validator, filter by the PLUGc policy, and build an in-memory PluginRegistry. Hot-load: re-read on every loadPluginsForRuntime call (no process-local cache), mirroring agents/spec.loadRegistry. Re-export from core/plugins/index.zig."
blast_radius: low
blast_radius_justification: "Contained to a new module under core/plugins/. Nothing in the runtime reads the registry yet (PLUGf wires it). The new code reads disk + parses manifests; failure modes (missing dir, malformed manifest) return empty/error without affecting the existing catalog. Direct consumers = none yet at runtime."
idempotency_contract: idempotent
idempotency_notes: "Discovery re-reads disk on every call by design (hot-load). Re-executing the slice reproduces the same source. On PARTIAL recovery, re-execute from the top; the end state is the same module + tests."
acceptance: "loadPluginsForRuntime against a fixture plugins directory returns a PluginRegistry containing only enabled, valid plugin manifests; malformed manifests are skipped/rejected without aborting discovery; with policy.enabled=false the registry is empty; re-editing a manifest is visible on the next call (no cache)."
exit_criterion: "`zig build test` succeeds; new discovery tests (empty dir, one valid plugin, malformed skipped, disabled-by-policy empty, hot-load re-read, duplicate plugin ids across folders) pass."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*discovery.*pass|all tests passed|0 failed"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I1 (opt-in truth): loadPluginsForRuntime returns an empty registry when policy.enabled is false"
  - "I2 (no silent expansion): a plugin enters the registry only if its manifest is valid AND policy.enabled AND the per-plugin enable map has it true"
  - "I3 (review gate preservation): manifests failing validateManifest (e.g. missing review_risk) are excluded from the registry"
  - "I5 (hot-load parity): discovery re-reads disk on every call; no process-local cache"
source_message_anchor: "U5, U7"
source_message_excerpt: "Plugin discovery — scan .var/plugins/ for manifests, register tools/agents at startup. ... Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)."
source_message_proof_obligation: "Implement disk discovery that scans the effective plugins directory, parses+validates manifests through the PLUGb contract, filters by the PLUGc policy, and returns a hot-loaded registry with no stale cache. This closes U5 (discovery) and the load/hot-load half of U7 (lifecycle); enable/disable mutation lands in PLUGg."
entry_state: "PLUGb + PLUGc archived. core/plugins/manifest.zig exposes parsePluginManifestFromJson + descriptor-bearing PluginSocket + validateManifest. core/config/file.zig exposes loadPluginPolicy + PluginPolicy + pluginDirectory. core/plugins/index.zig re-exports manifest symbols. No discovery module exists."
rollback_surface: "1. Remove apps/backend/src/core/plugins/discovery.zig. 2. Revert apps/backend/src/core/plugins/index.zig re-exports added for discovery. Order: index.zig first, then delete discovery.zig."
dependencies: "PLUGb, PLUGc"
next_todo: /todo/pending/PLUGe-plugin-socket.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGd Plugin Discovery and Hot-Load Registry

## Execute Now

Create `core/plugins/discovery.zig` that scans the effective plugins directory, parses and validates each `<id>/plugin.json`, filters by the plugin policy, and returns a hot-loaded `PluginRegistry` re-read on every call.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must create only `core/plugins/discovery.zig` and extend `core/plugins/index.zig` re-exports, must NOT touch `core/tools/*` (PLUGf), must NOT implement the subprocess transport (PLUGe), and must NOT mutate config (PLUGg). If a question arises about how the runtime consumes the registry, record it for PLUGf.

## Why This Execution Unit Exists

Discovery is the bridge between the on-disk contract (PLUGb) + opt-in gate (PLUGc) and the runtime (PLUGf). Without it, there is no in-memory representation of installed plugins for the catalog, dispatch, or `manage_plugin` to read. It must be its own slice because (a) the hot-load/no-cache contract (I5, mirroring `agents/spec.loadRegistry`) is a distinct behavioral requirement from parsing or gating, and (b) isolating discovery keeps blast radius low: PLUGf can integrate a stable registry API without this slice's disk-scanning logic leaking into the runtime.

## Better-Than-Before Delta

Pre-slice, there is no way for the runtime to know what plugins are installed; the harvested contracts are unreachable. Post-slice, a single `loadPluginsForRuntime` call returns the complete, validated, policy-filtered, descriptor-bearing set of mounted plugins, re-fresh on every call. The registry API becomes the stable surface PLUGf (catalog/dispatch) and PLUGg (manage_plugin list/info) consume, and the no-cache discipline guarantees an operator edit or `manage_plugin` toggle is visible without a restart.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Hot-load = re-parse on every admission, no process-local cache. | `agents/spec.loadRegistry` re-parses config.json each call (`spec.zig:187`); comment: "No process-local cache exists". | `loadPluginsForRuntime` reads disk + parses manifests on every call. No module-level cached registry. | Must NOT cache the registry in a global var. |
| A malformed manifest must not abort the whole scan (resilience), but must not be mounted (fail-closed). | `validateManifest` returns typed errors; catalog must never advertise an invalid tool (I3). | Discovery logs/skips a plugin whose manifest fails parse/validate, and continues scanning siblings; it never appears in the registry. | Must NOT abort discovery on one bad manifest; must NOT include a bad manifest in the registry. |
| Directory structure is `<plugins_dir>/<plugin_id>/plugin.json`. | The request: ".var/plugins/<name>/plugin.json". | Discovery iterates immediate child directories of the plugins dir, reads `<child>/plugin.json`. | Must NOT recurse arbitrarily or accept plugin.json at the root. |
| Policy gating happens before mount, not after. | §V opt-in; PLUGc `PluginPolicy.enabled` + `enabled_plugins`. | A plugin is loaded only if `policy.enabled` AND `policy.isEnabled(plugin_id)`. | Must NOT mount first and filter later. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| How the runtime iterates a directory (walker pattern). | Re-read `module.collectFiles` (`module.zig:782`) which uses `dir.walk`. | repository source | Discovery uses `std.fs.openDirAbsolute` + iterate, one level deep (immediate child dirs only). | module.collectFiles pattern cited. |
| How fsutil builds absolute paths under the runtime root. | Re-read `fsutil.runtimeRootForWorkspace` + `fsutil.join` (done). | repository source | Discovery joins `pluginDirectory` + `<id>` + `plugin.json`. | fsutil helpers. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | New `apps/backend/src/core/plugins/discovery.zig`; `apps/backend/src/core/plugins/index.zig` (re-export); reuse `apps/backend/src/core/plugins/manifest.zig` (parsePluginManifestFromJson, validateManifest, PluginManifest, PluginSocket), `apps/backend/src/core/config/file.zig` (loadPluginPolicy, pluginDirectory, PluginPolicy), `apps/backend/src/shared/fsutil.zig` (runtimeRootForWorkspace, join, readTextAlloc, fileExists). |
| Existing-owner decision | New file inside the canonical plugin owner `core/plugins/`. Justified: discovery is plugin-contract code (§IX), and there is no existing discovery owner to extend. |
| Domain owner / canonical standard | AGENTS.md §IX (plugin contract under core/plugins/), §V (opt-in), the `agents/spec.loadRegistry` hot-load pattern. |
| Intended design | `PluginRegistry{ allocator, plugins: []MountedPlugin }` where `MountedPlugin{ manifest: PluginManifest, directory: []const u8 (abs path to <id>/), source: ToolSource.plugin }`. `pub fn loadPluginsForRuntime(allocator, workspace_root) !PluginRegistry` — (1) `policy = loadPluginPolicy`; if `!policy.enabled` return empty registry; (2) `dir = pluginDirectory(...)`; if missing, return empty registry; (3) iterate immediate child dirs; for each, read `<child>/plugin.json`; if missing or unparseable, record skip + continue; (4) `parsePluginManifestFromJson` + `validateManifest`; if invalid, skip + continue; (5) if `!policy.isEnabled(manifest.id)` skip; (6) append MountedPlugin. Return owned registry with `deinit`. Also `pub fn findTool(registry, tool_name) ?LocatedTool` returning the plugin + socket for a tool name (used by PLUGf dispatch + availability). |
| Integration path | Consumed by PLUGf (catalog merge + dispatch lookups via `findTool`) and PLUGg (manage_plugin list/info via `loadPluginsForRuntime`). Not consumed at any runtime call site in this slice. |
| Failure modes to prevent | One bad manifest aborting all discovery; process-global cache hiding edits; a plugin mounted despite policy.enabled=false or per-plugin disable; directory-not-found treated as error instead of empty registry; memory leak (free all duped paths/manifests on the registry's deinit and on the error path). |
| Alternatives rejected | Startup-only cache (rejected: violates I5); abort-on-first-error (rejected: one bad plugin kills all); recursive scan (rejected: spec is one level deep); mount-then-filter (rejected: must gate before mount). |
| Proof hooks | Tests (tmp dir fixtures): empty plugins dir -> empty registry; policy.enabled=false -> empty even with valid plugin present; one valid enabled plugin -> registry has 1 with correct descriptor fields; malformed manifest skipped, sibling still loaded; valid-but-disabled-by-map skipped; duplicate plugin id (two folders same id) -> deterministic keep-first or reject (lock one); hot-load: write manifest, call, edit manifest, call again, second call sees the edit; `findTool` returns the right plugin+socket; `deinit` frees under testing.allocator. |

## Codebase Research And Execution Addendum

**Implementation map:** Create `apps/backend/src/core/plugins/discovery.zig`. Read before writing: `module.collectFiles` (already read — directory walk pattern at `module.zig:782`), `agents/spec.loadRegistry` (already read — hot-load pattern), `manifest.parsePluginManifestFromJson` (from PLUGb), `config/file.zig loadPluginPolicy`+`pluginDirectory` (from PLUGc). Extend `core/plugins/index.zig` to re-export `PluginRegistry`, `MountedPlugin`, `loadPluginsForRuntime`, `findTool`.

**Existing-owner directive:** New file in `core/plugins/`. There is no existing discovery owner; the harvested contracts are parsing/validation only.

**Directive:** Implement `loadPluginsForRuntime` with the no-cache discipline. The registry is returned by value (owning its allocator + slices) and freed by `deinit`. `findTool` linear-scans plugins and their tool sockets for a matching `name`, returning a `LocatedTool{ plugin: *const MountedPlugin, socket: *const PluginSocket }` so PLUGf can fetch descriptor fields and the plugin directory (for the subprocess entry resolution in PLUGe).

**Locked directory scan rules:** (1) Only immediate child directories of `pluginDirectory` are scanned (one level deep). (2) Each child must contain `plugin.json` at its root; children without it are skipped silently. (3) The plugin's identity is `manifest.id` from the JSON, NOT the folder name (but record a warning/skip if they mismatch — lock: if `manifest.id != folder_name`, skip with a recorded reason, to prevent shadowing). (4) Two folders with the same `manifest.id`: keep the first lexicographically and skip the second with a recorded duplicate-id reason. These rules prevent ambiguity in dispatch routing.

**Gold-standard guardrail:** Do NOT introduce a module-level `var cached_registry` — that violates I5. Every `loadPluginsForRuntime` call must perform disk I/O.

**Knowledge gathering route:** Repository-local only (module.zig walk pattern, spec.zig hot-load pattern, fsutil). No external research.

**Runtime visualization:** `loadPluginsForRuntime(workspace_root)` -> `loadPluginPolicy` -> (enabled?) -> `pluginDirectory` -> iterate child dirs -> `<child>/plugin.json` -> `parsePluginManifestFromJson` -> `validateManifest` -> `policy.isEnabled(id)` -> append `MountedPlugin` -> return `PluginRegistry`. PLUGf reads registry -> catalog; PLUGe reads `MountedPlugin.directory + socket.entry` -> subprocess.

**Proof expansion:** Add ≥30 meaningful tests using tmp directories (mirror `config file is created beside runtime state` test style). Create fixture plugin folders with `plugin.json` content (use the locked schema from PLUGb). Cover: empty dir, disabled policy, valid+enabled, malformed-skipped-sibling-loaded, valid-disabled-by-map, id/folder mismatch skipped, duplicate-id keep-first, hot-load re-read (write, call, rewrite, call, assert change), `findTool` hit + miss, `deinit` no leaks.

**Action-mode arbitration:** N/A (synchronous disk read; no deferred/queued work).

## Embedded Framing

Discovery is where "VANTARI knows about installed plugins" becomes true: it must read the real disk state on every call, fail closed on every invalid manifest, honor the policy gate before mounting, and return a registry that is provably fresh — because the difference between hot-load and a stale cache is whether an operator's edit or a `manage_plugin` toggle is visible without a restart (F4, I5, I1, I2, I3).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| None external. | Directory walking and hot-load are repo-local proven patterns (module.collectFiles, agents/spec.loadRegistry). | N/A | repository source | This slice's tests prove the scan + hot-load + filter behavior. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U5 | "Plugin discovery — scan .var/plugins/ for manifests, register tools/agents at startup." | `loadPluginsForRuntime` scans the effective plugins dir for `<id>/plugin.json` and registers valid ones. | `test` block: fixture dir with one valid plugin -> registry has 1 entry. |
| U7 | "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)." | The load half: re-read on every call (no cache), mirroring spec.loadRegistry. | `test` block: edit manifest between calls -> second call sees the edit (hot-load proof). |

## Pre-flight Checklist

- [ ] `PLUGb` and `PLUGc` archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] `entry_state` claims verifiable: `parsePluginManifestFromJson` + `loadPluginPolicy` + `pluginDirectory` exist; no `discovery.zig` yet.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (low blast radius — new file).
- [ ] Idempotency contract read (idempotent; PARTIAL -> re-execute from top).
- [ ] No other slice being advanced.
- [ ] Slice Research Directive records local baseline (repo-only), no external research.

## Entry State

- PLUGb archived: `manifest.zig` exposes `parsePluginManifestFromJson`, descriptor-bearing `PluginSocket`, `validateManifest`.
- PLUGc archived: `config/file.zig` exposes `loadPluginPolicy`, `PluginPolicy`, `pluginDirectory`.
- `core/plugins/index.zig` re-exports manifest symbols.
- No `discovery.zig`.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/plugins/index.zig` — re-export `PluginRegistry`, `MountedPlugin`, `loadPluginsForRuntime`, `findTool`, `LocatedTool`.

**Adds:**
- `apps/backend/src/core/plugins/discovery.zig` — `PluginRegistry`, `MountedPlugin`, `LocatedTool`, `loadPluginsForRuntime`, `findTool`, tests.

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/tools/*` (PLUGf).
- `apps/backend/src/core/plugins/subprocess.zig` (PLUGe).
- `apps/backend/src/core/config/*` (already done in PLUGc).
- `apps/backend/src/core/plugins/manifest.zig` (already done in PLUGb).

## Detailed Requirements

- R1: `pub const MountedPlugin = struct { manifest: PluginManifest, directory: []u8, id: []const u8 }` (directory = absolute path to `<plugins_dir>/<id>/`).
- R2: `pub const PluginRegistry = struct { allocator, plugins: []MountedPlugin, pub fn deinit(self) void, pub fn all(self) []const MountedPlugin }`.
- R3: `pub const LocatedTool = struct { plugin: *const MountedPlugin, socket: *const PluginSocket }`.
- R4: `pub fn loadPluginsForRuntime(allocator, workspace_root) !PluginRegistry` — implements the locked scan rules + policy gate + no-cache discipline. Returns empty registry (not error) when policy disabled or dir missing. Frees all allocations on the error path.
- R5: `pub fn findTool(registry, tool_name) ?LocatedTool` — linear scan over plugins + their `.tool` sockets.
- R6: Re-export all of the above from `index.zig`.
- R7: ≥30 meaningful tests (tmp-dir fixtures), including hot-load re-read and `deinit` leak checks with `std.testing.allocator`.

## Invariants This Unit Must Preserve

- I1: `policy.enabled == false` -> empty registry (R4 + test).
- I2: plugin mounted only when valid + enabled + per-plugin-enabled (R4 + test).
- I3: invalid manifest (e.g. missing review_risk) excluded (R4 + test).
- I5: no module-level cache; every call reads disk (R4 + hot-load test).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | discovery tests pass; "0 failed" | yes |

**Evidence to capture:** `zig build test` tail showing discovery test names passing, plus an excerpt proving hot-load (second call sees edited manifest).

## Exit State (Handoff Contract)

- `core/plugins/discovery.zig` exposes `loadPluginsForRuntime` (hot-loaded, policy-gated), `PluginRegistry`, `MountedPlugin`, `findTool`, `LocatedTool`.
- `core/plugins/index.zig` re-exports them.
- The registry is the stable surface PLUGf (catalog/dispatch) and PLUGg (manage_plugin) consume.
- PLUGe may begin implementing the subprocess transport, resolving entries against `MountedPlugin.directory + socket.entry`.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/plugins/index.zig` (remove discovery re-exports).
2. `rm apps/backend/src/core/plugins/discovery.zig`.
3. Re-run `zig build test`.

## Next todo

`/todo/pending/PLUGe-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests (empty dir, disabled, valid+enabled, malformed-skipped, disabled-by-map, id/folder mismatch, duplicate-id, hot-load re-read, findTool hit/miss, deinit no-leak).
- [ ] Tests prove discovery through `loadPluginsForRuntime` (the real consumer path).
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: registry empty when disabled; hot-load verified; invalid manifests excluded.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGd-plugin-socket.md /todo/changelog/PLUGd-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
