---
id: PLUGc-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: c
status: superseded
decision: deferred-delete
patch_scope: "Add a validated `plugins` config section to core/config/default.json and core/config/file.zig (enabled, path, per-plugin enable map) default-OFF, plus a loadPluginPolicy loader. This is the opt-in gate; no discovery reads it yet (PLUGd does)."
blast_radius: medium
blast_radius_justification: "default.json is the foundational config document and file.zig validateDocumentShape gates every config read. Adding a top-level section changes the validated shape. Containment: the section is additive and defaults to plugins-disabled, so existing behavior is preserved; the validator change only permits one new key. Direct consumers = all config readers, but they ignore the new section unless they call loadPluginPolicy."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Edits to default.json and file.zig are deterministic. Condition: the pre-PLUGc versions of both files are intact. On PARTIAL recovery, verify both files match the intended end state; if so, re-run zig build test. If a partial edit left either file non-compiling, revert both to pre-PLUGc before re-executing."
acceptance: "default.json has a documented `plugins` section with enabled=false and _help; file.zig validateDocumentShape accepts the section and rejects unknown keys/invalid types within it; loadPluginPolicy returns enabled=false by default and reflects enabled/path/per-plugin overrides when present; with the section absent, loadPluginPolicy returns the disabled default."
exit_criterion: "`zig build test` succeeds; the existing config test 'default config documents every persistent value' still passes (the new section is fully _help-documented); new tests prove enabled-defaults-false, path override, per-plugin enable map, and rejection of malformed sections."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*config.*pass|all tests passed|0 failed"
evidence: "Move40 superseded this design unit before implementation. No runtime artifact was claimed. The retained plugin contract scaffolding is not model-visible; the default-visible manage_plugin placeholder was deleted. Reopen only with a concrete user-facing need and a new owner-mapped plan."
conflict_surface: ""
invariants:
  - "I1 (opt-in truth): with plugins section absent or enabled=false, loadPluginPolicy returns a disabled policy"
  - "I2 (no silent expansion): per-plugin enable defaults to false; a plugin is enabled only by an explicit entry"
source_message_anchor: "U2, U7, U9"
source_message_excerpt: "Plugin tools are opt-in and must not silently alter the model-visible tool list ... Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs) ... Config surface — plugins.enabled, plugins.path, per-plugin enable/disable."
source_message_proof_obligation: "Implement the config gate so plugin capability is mechanically OFF by default and only a section with enabled=true plus an explicit per-plugin enable map can turn it on. This closes U9 (config surface), anchors U2 (opt-in invariant I1/I2), and provides the enable/disable substrate for U7 (lifecycle)."
entry_state: "PLUGb archived. core/config/default.json has no plugins section. file.zig validateDocumentShape rejects unknown top-level keys (line 266 allowed-list) and validates typed sections with _help parity. loadRuntimePolicy/loadAgentPolicy/loadContextPolicy etc. are the loader pattern. config.file.path() resolves config.json under fsutil.runtimeRootForWorkspace."
rollback_surface: "1. Revert apps/backend/src/core/config/default.json (remove plugins section). 2. Revert apps/backend/src/core/config/file.zig (remove plugins validation block + loadPluginPolicy + PluginPolicy struct + tests). Order: file.zig first (so validator no longer references the section), then default.json."
dependencies: "PLUGb"
next_todo: NONE
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGc Plugin Config Surface and Opt-In Gate

## Execute Now

Add a documented, validated `plugins` section (default-OFF) to `core/config/default.json` and a `loadPluginPolicy` loader + `PluginPolicy` type to `core/config/file.zig` so plugin capability is mechanically opt-in.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must touch only `core/config/default.json` and `core/config/file.zig`, must NOT add discovery (`core/plugins/discovery.zig` is PLUGd), must NOT add the manifest parser's config read path, and must NOT wire `loadPluginPolicy` into any runtime call site (PLUGd/PLUGf do that). If a question arises about how discovery resolves `path`, record it as an assumption for PLUGd.

## Why This Execution Unit Exists

AGENTS.md §V makes opt-in a hard invariant ("must not silently alter the model-visible tool list"), and the request names an explicit config surface (`plugins.enabled`, `plugins.path`, per-plugin enable/disable). The repo's config owner (`file.zig validateDocumentShape`) currently rejects unknown top-level keys, so there is literally no way for plugins to be enabled without first adding a validated section. This slice must land before discovery (PLUGd) so that discovery has a gate to read, and before the runtime merge (PLUGf) so the catalog can never expand before the gate exists. Sequencing config before discovery is the dependency order that makes I1/I2 enforceable rather than aspirational.

## Better-Than-Before Delta

Pre-slice, there is no mechanism preventing a future discovery call from advertising plugin tools; the opt-in invariant rests on operator discipline. Post-slice, opt-in is a typed, validated config section defaulting to disabled, with the same `_help`-documentation parity and `rejectUnknownKeys` discipline as every other section. The invariant becomes mechanically testable: `loadPluginPolicy` returns disabled unless the section explicitly enables it, and the per-plugin map defaults each plugin off.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Every config value has a `_help` entry; `_help` keys cannot drift from configurable keys. | `config/file.zig validateHelp` (`file.zig:402`); the test "default config documents every persistent value" (`file.zig:595`). | The `plugins` section MUST include `_help` for `enabled`, `path`, and `enabled_plugins`, and the test must keep passing. | Must NOT add a config section without `_help` parity. |
| Top-level unknown keys are rejected; per-section unknown keys are rejected. | `validateDocumentShape` allowed-list at `file.zig:266`; `rejectUnknownKeys`. | Add `plugins` to the top-level allowed list and a per-section allowed-keys list. | Must NOT relax key rejection to accept the new section. |
| Optional sections collapse to typed defaults, but a present section with wrong type is an error (not silent default). | `validatedObjectField` distinguishes absent vs wrong-type (`file.zig:393`). | `loadPluginPolicy` returns disabled default when absent; errors if `plugins` is non-object or `enabled` is non-bool. | Must NOT let a malformed `plugins` section silently disable plugins without erroring. |
| Paths are workspace-relative or runtime-root-relative, never absolute (precedent: prompts `system_prompt_file`). | `loadPromptPolicy` rejects absolute paths (`file.zig:202`). | `plugins.path` rejects absolute paths; resolves under the runtime root. | Must NOT accept an absolute plugins path. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Exact loader pattern to mirror. | Re-read `loadAgentPolicy` + `loadMemoryPolicy` (`file.zig:114`, `file.zig:226`). | repository source | Confirms PluginPolicy loader shape (optional section -> typed struct with defaults). | file.zig loader functions cited. |
| How the runtime root resolves for path defaults. | Re-read `fsutil.runtimeRootForWorkspace` + `config.file.path` (done). | repository source | Confirms `plugins.path` default resolves under `.var/plugins`. | config.file.path uses runtimeRootForWorkspace. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `apps/backend/src/core/config/default.json` (add section), `apps/backend/src/core/config/file.zig` (add validation block in `validateDocumentShape`, add `PluginPolicy` struct + `loadPluginPolicy`). |
| Existing-owner decision | Extend the canonical config owner `file.zig` + `default.json`. Do not create a plugin-specific config module. |
| Domain owner / canonical standard | AGENTS.md §V (opt-in), the repo's config-validation discipline (`_help` parity, `rejectUnknownKeys`). |
| Intended design | `PluginPolicy{ enabled: bool = false, path: ?[]u8 = null, enabled_plugins: std.StringHashMap(bool) or small map }`. `loadPluginPolicy(allocator, workspace_root) !PluginPolicy` reads the `plugins` section: `enabled` (bool, default false), `path` (string, optional, must be relative), `enabled_plugins` (object mapping plugin-id -> bool; only entries with `true` are considered enabled). Returns disabled default when section absent. Errors on type mismatch / unknown keys / absolute path. |
| Integration path | Consumed by PLUGd (discovery checks `policy.enabled` and the per-plugin map before reading/validating a manifest) and PLUGf (catalog merge gated by the same policy). PLUGg (manage_plugin) mutates the section. Not consumed at any runtime call site in this slice. |
| Failure modes to prevent | Plugin silently enabled when section absent (must default false); absolute `path` accepted; unknown key in `plugins` accepted; `enabled_plugins` entry with non-bool value silently ignored; memory leak in the policy (free `path` + map in `deinit`). |
| Alternatives rejected | Per-plugin enable as a separate file (rejected: diverges from single canonical config owner; U9 says it's a config surface); default-on with opt-out (rejected: violates §V); a global boolean with no per-plugin map (rejected: U9 requires per-plugin enable/disable). |
| Proof hooks | Tests: section absent -> disabled; `enabled:false` -> disabled; `enabled:true` with empty map -> no plugin enabled; `enabled:true` + `enabled_plugins:{x:true}` -> x enabled, others not; absolute `path` -> InvalidConfig; unknown key in plugins -> InvalidConfig; non-bool `enabled` -> InvalidConfig; `_help` parity holds (existing "documents every persistent value" test passes). |

## Codebase Research And Execution Addendum

**Implementation map:** Edit `apps/backend/src/core/config/default.json` — add a top-level `plugins` object AFTER the `memory` section and BEFORE `environment` (or at the end), with `_help`, `enabled: false`, `path: null`, `enabled_plugins: {}`. Edit `apps/backend/src/core/config/file.zig` — (1) add `"plugins"` to the allowed-keys list in `validateDocumentShape` (line ~266); (2) add a validation branch mirroring the `memory` branch (`file.zig:379`) that calls `rejectUnknownKeys` with `&.{"_help","enabled","path","enabled_plugins"}`, validates `_help` parity, checks `enabled` is bool if present, checks `path` is a relative string if present, checks `enabled_plugins` is an object of bools if present; (3) add `pub const PluginPolicy = struct { enabled: bool = false, path: ?[]u8 = null, enabled_plugins: ... , pub fn deinit(...) };`; (4) add `pub fn loadPluginPolicy(allocator, workspace_root) !PluginPolicy` mirroring `loadMemoryPolicy`/`loadAgentPolicy`. Read before editing: full `file.zig` (already read).

**Existing-owner directive:** Extend `core/config/file.zig` + `default.json`. They are the canonical config owners.

**Directive:** Add the `plugins` section defaulting to disabled. The per-plugin enable map is the substrate for `manage_plugin` enable/disable (PLUGg) and the gate discovery reads (PLUGd). `path` defaults to `<runtime_root>/plugins` (i.e. `.var/plugins`) when null — compute this in `loadPluginPolicy` via `fsutil.runtimeRootForWorkspace` + `fsutil.join`, do not store a default in the JSON that implies a specific absolute location.

**Locked `plugins` section shape** (in `default.json`):
```json
"plugins": {
  "_help": {
    "enabled": "Master switch for plugin tool capability. When false (or absent), zero plugin tools are discovered, advertised, or dispatched. This is the AGENTS.md Section V opt-in gate.",
    "path": "Optional workspace-relative directory holding plugin folders. Null resolves to <runtime_root>/plugins (i.e. .var/plugins). Must be relative; absolute paths are rejected.",
    "enabled_plugins": "Object mapping plugin id to a boolean. Only plugins present here with value true are loaded when plugins.enabled is true. Absent or false means the plugin is discovered but not mounted."
  },
  "enabled": false,
  "path": null,
  "enabled_plugins": {}
}
```

**Gold-standard guardrail:** Do NOT default `enabled` to true under any circumstance, and do NOT treat an absent `enabled_plugins` entry as enabled-by-default.

**Knowledge gathering route:** Repository-local only (file.zig pattern, fsutil). No external research.

**Runtime visualization:** config.json -> `loadPluginPolicy` -> `PluginPolicy{enabled,path,enabled_plugins}` -> (consumed by PLUGd discovery gate + PLUGf catalog gate).

**Proof expansion:** Add ≥30 meaningful tests using a tmp workspace (mirror the `config file is created beside runtime state` test at `file.zig:614`): write a config.json with each variant, call `loadPluginPolicy`, assert the policy fields. Cover: absent section, explicit false, true+empty map, true+map, absolute path rejection, unknown-key rejection, non-bool enabled, non-bool map value, non-object plugins section, `_help` parity (the existing "documents every persistent value" test must include the new section — extend it to loop over `plugins` too).

**Action-mode arbitration:** N/A (no deferred/queued work).

## Embedded Framing

Opt-in is not a flag; it is a typed gate. The `plugins` section must default to disabled, document every key with `_help`, reject every unknown key, and require an explicit per-plugin enable — because the difference between "plugin tools are opt-in" as a slogan and as a mechanical truth is whether `loadPluginPolicy` can return enabled when the section is absent (F2, I1, I2).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| None external. | The config pattern is repo-local and already proven across runtime/provider/agents/context/prompts/draft/buffer/memory/environment sections. | N/A | repository source (file.zig, default.json) | This slice's tests prove the gate matches the locked shape. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U2 | "Plugin tools are opt-in and must not silently alter the model-visible tool list" | `loadPluginPolicy` returns disabled when section absent or `enabled:false`. | `test` block: absent section -> disabled; `enabled:false` -> disabled. |
| U7 | "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)" | The `enabled_plugins` map is the enable/disable substrate PLUGg mutates and PLUGd reads. | `test` block: `enabled_plugins:{x:true}` -> x enabled, others not. |
| U9 | "Config surface — plugins.enabled, plugins.path, per-plugin enable/disable" | The three fields exist, are validated, `_help`-documented, and default-safe. | `default.json` diff + the "documents every persistent value" test passing with `plugins` included. |

## Pre-flight Checklist

- [ ] `PLUGb` archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] `entry_state` claims verifiable: `default.json` has no `plugins` section; `file.zig validateDocumentShape` rejects unknown top-level keys.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (medium blast radius).
- [ ] Idempotency contract read (conditionally-idempotent; verify file integrity before re-execute).
- [ ] No other slice being advanced.
- [ ] Slice Research Directive records local baseline (repo-only), no external research.

## Entry State

- PLUGb archived; manifest schema stable.
- `core/config/default.json` has sections: runtime, provider, agent_routes, agents, context, prompts, draft, buffer, memory, environment. No `plugins`.
- `core/config/file.zig validateDocumentShape` allowed top-level keys list at line ~266 does not include `plugins`.
- `loadMemoryPolicy`/`loadAgentPolicy` are the loader-pattern references.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/config/default.json` — add documented `plugins` section (default OFF).
- `apps/backend/src/core/config/file.zig` — add `"plugins"` to allowed top-level keys; add `plugins` validation branch; add `PluginPolicy` struct + `loadPluginPolicy` + `deinit`; extend the "documents every persistent value" test to cover `plugins`; add new tests.

**Adds:**
- (new symbols inside existing files; no new files)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/plugins/discovery.zig` (PLUGd).
- `apps/backend/src/core/tools/*` (PLUGf).
- `apps/backend/src/core/agents/spec.zig` (out of scope entirely).

## Detailed Requirements

- R1: In `default.json`, add the locked `plugins` section with `_help`, `enabled: false`, `path: null`, `enabled_plugins: {}`.
- R2: In `file.zig validateDocumentShape`, add `"plugins"` to the top-level allowed-keys list and add a validation branch that: rejects unknown keys (`_help`, `enabled`, `path`, `enabled_plugins` only); validates `_help` parity; validates `enabled` is bool if present; validates `path` is a non-empty relative string if present (reject absolute); validates `enabled_plugins` is an object whose values are all bools if present.
- R3: Add `pub const PluginPolicy = struct { enabled: bool = false, path: ?[]u8 = null, enabled_plugins: <map or sorted small struct>, pub fn deinit(self, allocator) void {...} }`. The enable map must support `isEnabled(plugin_id) bool` lookup.
- R4: Add `pub fn loadPluginPolicy(allocator, workspace_root) !PluginPolicy`. Returns disabled default when `plugins` absent. Reads `enabled` (default false), `path` (optional, relative, duped), `enabled_plugins` (object of bools). Computes the effective plugins directory: if `path` present, resolve it workspace-relative; else `<runtimeRootForWorkspace>/plugins`. Errors on type mismatch / absolute path / unknown keys.
- R5: The effective-plugins-directory computation lives in a small helper (e.g. `pub fn pluginDirectory(allocator, workspace_root, policy) ![]u8`) so PLUGd can reuse it without re-deriving.
- R6: Add ≥30 meaningful tests (tmp-workspace pattern), including extending the existing "documents every persistent value" test to iterate `plugins`.

## Invariants This Unit Must Preserve

- I1: `loadPluginPolicy` returns disabled when section absent or `enabled:false` (R4 + tests).
- I2: per-plugin enable defaults false; only explicit `true` entries enable (R3/R4 + tests).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | config tests pass including new plugin-policy tests; "0 failed" | yes (conditional on file integrity) |

**Evidence to capture:** `zig build test` tail showing config test names passing (including the extended "documents every persistent value" test), plus an excerpt of a passing `loadPluginPolicy` disabled-default test.

## Exit State (Handoff Contract)

- `default.json` carries a documented, default-OFF `plugins` section.
- `file.zig` validates the section and exposes `loadPluginPolicy` + `PluginPolicy` + `pluginDirectory`.
- The opt-in gate is mechanically enforced and testable.
- PLUGd may begin scanning the effective plugins directory, gated by `loadPluginPolicy`.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/config/file.zig` (revert validation branch, PluginPolicy, loadPluginPolicy, tests).
2. `git checkout -- apps/backend/src/core/config/default.json` (remove plugins section).
3. Re-run `zig build test` to confirm the pre-PLUGc test set passes.

## Next todo

`/todo/pending/PLUGd-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests (absent section, false, true+empty, true+map, absolute path rejection, unknown-key rejection, non-bool enabled, non-bool map value, non-object section, `_help` parity, effective-directory helper).
- [ ] Tests prove the opt-in gate through `loadPluginPolicy` (the real consumer path for this slice).
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: `loadPluginPolicy` returns disabled default; section validated with `_help` parity.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGc-plugin-socket.md /todo/changelog/PLUGc-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
