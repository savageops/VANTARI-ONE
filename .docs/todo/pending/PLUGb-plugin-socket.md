---
id: PLUGb-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: b
status: pending
patch_scope: "Extend core/plugins/manifest.zig with per-socket descriptor fields (description, parameters_json, usage_hint, example_json) and a disk JSON parser (parsePluginManifestFromJson); re-export from core/plugins/index.zig. The on-disk schema becomes the .var/plugins/<name>/plugin.json format. No runtime/dispatch/config change."
blast_radius: low
blast_radius_justification: "Contained to the plugin contract module. Existing manifest.zig types are extended additively (new optional fields + a new parse function); validateManifest keeps its current behavior and gains descriptor validation for tool sockets. No runtime, catalog, or dispatch path reads this yet (PLUGf does), so failure cannot propagate to the model-visible surface."
idempotency_contract: idempotent
idempotency_notes: "Source edits are deterministic additions. Re-executing the slice re-applies the same field additions and parser. On PARTIAL recovery, re-execute from the top: the end state is the same source text and the same test set."
acceptance: "parsePluginManifestFromJson parses a JSON document matching the locked schema into a PluginManifest whose tool sockets carry descriptor fields, validateManifest rejects tool sockets missing description/parameters_json/invalid review_risk, and the existing manifest tests still pass."
exit_criterion: "`zig build test` succeeds; new tests for parsePluginManifestFromJson (happy path, missing fields, invalid review_risk, duplicate names, non-tool socket rejection) pass; existing manifest tests pass."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*manifest.*pass|all tests passed|0 failed"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I3 (review gate preservation): manifest parser rejects tool sockets with missing/invalid review_risk before the manifest is mountable"
  - "I4 (ownership boundary): all changes under apps/backend/src/core/plugins/"
source_message_anchor: "U1, U4, U8"
source_message_excerpt: "Plugins should have a tool with hints in the descriptor. ... Plugin manifest schema — a .var/plugins/<name>/plugin.json format declaring: name, version, tool definitions, agent definitions, dependencies, review risk overrides. ... Plugin descriptor hints — usage hints, examples, review risk advertised in the manifest."
source_message_proof_obligation: "Implement the on-disk manifest schema so each tool socket carries the descriptor fields (description, parameters_json, usage_hint, example_json, review_risk) that types.ToolDefinition and the catalog consume, and so an invalid manifest fails closed at parse/validate time. This closes U4 (schema) and U8 (descriptor hints) and partially U1 (tool with hints)."
entry_state: "PLUGa archived. Interpretation Lock L4 requires descriptor fields on the manifest. core/plugins/manifest.zig has PluginManifest{id,version,sockets[]} and PluginSocket{kind,name,entry,review_risk?}. core/plugins/index.zig re-exports PluginManifest, PluginSocket, PluginSocketKind, validateManifest. Existing manifest tests cover validate/mount but not disk parsing or descriptor fields."
rollback_surface: "1. Revert apps/backend/src/core/plugins/manifest.zig to pre-PLUGb state. 2. Revert apps/backend/src/core/plugins/index.zig re-exports added by this slice. Order: index.zig first (remove re-exports), then manifest.zig."
dependencies: "PLUGa"
next_todo: /todo/pending/PLUGc-plugin-socket.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGb Plugin Manifest Schema, Disk Parser, and Descriptor Hints

## Execute Now

Extend `core/plugins/manifest.zig` with per-tool-socket descriptor fields and a JSON disk parser so a `.var/plugins/<name>/plugin.json` document becomes a validated, descriptor-bearing `PluginManifest`.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must extend only `core/plugins/manifest.zig` and `core/plugins/index.zig`, must NOT touch `runtime.zig`, `registry.zig`, `config/*`, or `default.json` (those are PLUGc/PLUGf), and must NOT begin discovery or dispatch (PLUGd/PLUGe). If a question arises about how descriptors render in the catalog, record it as an assumption for PLUGf — do not implement catalog rendering here.

## Why This Execution Unit Exists

The harvested `PluginManifest` carries only `id`, `version`, and sockets with `{kind, name, entry, review_risk?}`. The catalog (`runtime.renderCatalog`/`renderCatalogJson`) and `types.ToolDefinition` require `description`, `parameters_json`, `review_risk`, and optional `usage_hint`/`example_json` per tool. Without these fields on the manifest, a plugin tool could not render identically to a builtin (L4) and discovery (PLUGd) would have nothing descriptor-rich to feed the runtime. This slice closes that gap at the contract layer, before any runtime integration, so the schema is stable before PLUGc–PLUGf depend on it.

## Better-Than-Before Delta

Pre-slice, the manifest is an in-memory struct with no disk format and no descriptor richness; it cannot be the source of a catalog entry. Post-slice, `.var/plugins/<name>/plugin.json` is a parseable, validated, descriptor-bearing contract: one plugin tool carries the same hint surface as `read_file` or `skill_info`. The schema becomes the stable interface every later slice reads, and malformed manifests fail closed at parse time (I3) rather than reaching the catalog.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| A tool descriptor must match `types.ToolDefinition` field-for-field so catalog rendering is uniform. | `types.ToolDefinition{name,description,parameters_json,review_risk,example_json?,usage_hint?}` (`shared/types.zig:431`); catalog renders all these (`runtime.zig:128`,`runtime.zig:168`). | Manifest tool socket carries `description`, `parameters_json`, `review_risk`, optional `usage_hint`, `example_json`. | Must NOT invent a separate plugin-descriptor struct that omits any ToolDefinition field. |
| Validation fails closed on missing/invalid risk and malformed schemas, mirroring `review.reviewToolName`. | `manifest.validateManifest` already rejects InvalidReviewRisk/DuplicateSocketName (`manifest.zig:49`); `sockets.validateDefinition` parses parameters_json (`sockets.zig`). | Parser + validator reject tool sockets missing description/parameters_json or with invalid review_risk, and parameters_json must parse as a JSON object. | Must NOT accept a tool socket with empty description or unparseable parameters_json. |
| Versioning is explicit (`version` field) like config.json `version:1`. | `config/file.zn validateDocumentValue` requires `version==1`. | Manifest schema carries a `version` integer (start at 1) so future evolution is gated. | Must NOT make the schema versionless. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Exact field set ToolDefinition needs (already known). | Re-read `shared/types.zig:431-438` (done). | repository source | Confirms descriptor field list. | types.zig field list cited above. |
| How config.json validates a typed section (pattern to mirror). | Re-read `config/file.zig validateDocumentShape` + `optionalStringClone`/`optionalUsize` (done). | repository source | Parser uses the same optional/required extraction helpers pattern. | config/file.zig helper pattern. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `apps/backend/src/core/plugins/manifest.zig` (extend), `apps/backend/src/core/plugins/index.zig` (re-export new symbols), `apps/backend/src/core/tools/sockets.zig` (reuse `validateDefinition`, `validateName`), `apps/backend/src/shared/types.zig` (`ToolDefinition`, `parseReviewRiskLabel`). |
| Existing-owner decision | Extend `manifest.zig` (the canonical manifest owner). Add fields to `PluginSocket` and a new `parsePluginManifestFromJson` function in the same file. Do not create a second manifest module. |
| Domain owner / canonical standard | AGENTS.md §IX (plugin contract under `core/plugins/`); §V (definition includes description + parameters + review risk). |
| Intended design | `PluginSocket` gains: `description: ?[]const u8`, `parameters_json: ?[]const u8`, `usage_hint: ?[]const u8`, `example_json: ?[]const u8` (optional so non-tool sockets and legacy tests still compile, but validateManifest requires description+parameters_json+review_risk for tool sockets). `PluginManifest` gains `schema_version: u8 = 1`. New `parsePluginManifestFromJson(allocator, text) !PluginManifest` returns an allocator-owned manifest (all strings duped). The on-disk JSON shape (locked below) maps 1:1 to these structs. |
| Integration path | Consumed by PLUGd (discovery reads `.var/plugins/<name>/plugin.json`, calls `parsePluginManifestFromJson`, then `validateManifest`). PLUGf reads the descriptor fields to build `types.ToolDefinition`. Not consumed by runtime in this slice. |
| Failure modes to prevent | Tool socket with empty description / unparseable parameters_json / missing review_risk accepted; duplicate tool names within one manifest; memory leak on parse error (free duped strings on the error path); non-tool socket accidentally requiring tool descriptor fields. |
| Alternatives rejected | A separate `PluginDescriptor` struct (rejected: diverges from ToolDefinition, GS1); parsing in discovery.zig (rejected: parser belongs with the manifest contract); TOML/YAML (rejected: JSON is the repo standard per config.json). |
| Proof hooks | Tests: happy-path parse produces expected fields; missing description -> error; missing parameters_json -> error; invalid review_risk -> error; duplicate tool names -> error; non-tool socket (provider) -> UnsupportedSocketKind on validate; parameters_json that is not a JSON object -> error; round-trip parse->validate->fields readable. |

## Codebase Research And Execution Addendum

**Implementation map:** Edit `apps/backend/src/core/plugins/manifest.zig`. Read before editing: the full current file (already read — 190 lines). The struct `PluginSocket` (line 24) gains optional descriptor fields; `PluginManifest` (line 33) gains `schema_version`; `validateManifest` (line 49) gains descriptor validation for `socket.kind == .tool`; new `parsePluginManifestFromJson` is added near the bottom (before tests). `index.zig` re-exports `parsePluginManifestFromJson`.

**Existing-owner directive:** Extend `core/plugins/manifest.zig`. It is the canonical manifest owner; no new owner.

**Directive:** (1) Add `schema_version: u8 = 1` to `PluginManifest`. (2) Add optional descriptor fields to `PluginSocket`: `description`, `parameters_json`, `usage_hint`, `example_json` (all `?[]const u8 = null`). (3) In `validateManifest`, for `socket.kind == .tool`: require non-empty `description`, non-empty `parameters_json` that parses as a JSON object (reuse `sockets.validateDefinition` shape or call `std.json.parseFromSlice` + check `.object`), and a valid `review_risk` (already checked). (4) Add `pub fn parsePluginManifestFromJson(allocator: std.mem.Allocator, text: []const u8) anyerror!PluginManifest` that: parses the document, extracts `schema_version` (default 1, reject != 1 with a typed error), `id` (string), `version` (string), and `sockets` (array of objects with `kind`/`name`/`entry`/`review_risk`/`description`/`parameters_json`/`usage_hint`/`example_json`), dupes all strings into the allocator, and returns an owned `PluginManifest`. Free all duped strings on any error path. (5) Re-export `parsePluginManifestFromJson` from `index.zig`.

**Locked on-disk JSON schema** (`.var/plugins/<name>/plugin.json`):
```json
{
  "schema_version": 1,
  "id": "tickets",
  "version": "0.1.0",
  "sockets": [
    {
      "kind": "tool",
      "name": "lookup_ticket",
      "entry": "tools/lookup_ticket",
      "description": "Look up a ticket by id.",
      "parameters_json": "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false}",
      "review_risk": "read_only",
      "usage_hint": "Optional: when to call this tool.",
      "example_json": "{\"id\":\"ENG-123\"}"
    }
  ],
  "dependencies": [
    { "kind": "external_command", "name": "jira-cli" }
  ],
  "agents": []
}
```
`dependencies` and `agents` arrays are parsed as declared metadata only (recorded on the manifest as opaque/raw or a minimal `Dependency` slice reusing `module.Dependency`/`DependencyKind`) and NOT resolved by this chain (L5). `agents` is recorded but not wired (out of scope). Unknown top-level keys are rejected (fail closed, mirroring config.json).

**Gold-standard guardrail:** Do NOT weaken `validateManifest`'s existing rejections to accept the new fields; the new descriptor requirements are additive constraints on tool sockets only.

**Knowledge gathering route:** Repository-local only for this slice (types.zig, config/file.zig pattern, manifest.zig). No external research needed.

**Runtime visualization:** N/A — no runtime path reads this yet.

**Proof expansion:** Add ≥30 meaningful tests in `manifest.zig` `test` blocks covering: schema_version default + reject; id validation; per-field presence (description, parameters_json, review_risk) for tool sockets; parameters_json must be a JSON object; duplicate socket names; non-tool socket (provider) accepted at parse but rejected by validateManifest's `isSocketKindMountable`; usage_hint/example_json optional; dependencies array parsed as metadata; unknown top-level key rejected; allocator cleanup on error (use `std.testing.allocator` to detect leaks).

**Action-mode arbitration:** N/A (no deferred/queued work).

## Embedded Framing

A plugin tool is only as good as its descriptor: the manifest must carry the same description, parameters, review risk, usage hint, and example richness as a built-in tool, and it must fail closed the moment any of those is missing or malformed — because the catalog and review gate treat plugin tools identically to builtins (F1, L4, I3).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| None external. | The schema is anchored in repo-local types (ToolDefinition) and the repo's own config-validation pattern. | N/A | repository source (types.zig, config/file.zig) | This slice's tests prove the parser/validator match the locked schema. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U1 | "Plugins should have a tool with hints in the descriptor." | Each tool socket carries description + parameters + review_risk + optional usage_hint/example_json. | `test` block asserting parsed tool socket has all descriptor fields populated. |
| U4 | "Plugin manifest schema — a .var/plugins/<name>/plugin.json format declaring: name, version, tool definitions, agent definitions, dependencies, review risk overrides." | The on-disk schema (locked above) declares id, version, sockets (tool definitions), dependencies (metadata), agents (recorded). | `test` block parsing the locked example JSON successfully. |
| U8 | "Plugin descriptor hints — usage hints, examples, review risk advertised in the manifest." | `usage_hint` and `example_json` are manifest fields; `review_risk` is required and validated. | `test` block: tool socket with usage_hint/example_json parses and renders; invalid review_risk rejected. |

## Pre-flight Checklist

- [ ] `PLUGa` archived in `/todo/changelog/` with non-PLACEHOLDER evidence.
- [ ] `entry_state` claims verifiable: `core/plugins/manifest.zig` present with current types; `core/plugins/index.zig` re-exports present.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (low blast radius).
- [ ] Idempotency contract read (idempotent; PARTIAL -> re-execute from top).
- [ ] No other slice in this chain being advanced.
- [ ] Slice Research Directive records local baseline (repo-only) and declares no external research.

## Entry State

- PLUGa archived; Interpretation Lock L4 active (descriptor fields required).
- `core/plugins/manifest.zig` has `PluginManifest{id,version,sockets[]}`, `PluginSocket{kind,name,entry,review_risk?}`, `PluginSocketKind{tool,provider,context,event}`, `validateManifest`, `mountPlugin`; existing tests pass.
- `core/plugins/index.zig` re-exports `PluginManifest, PluginSocket, PluginSocketKind, validateManifest`.
- No disk parser exists.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/plugins/manifest.zig` — add descriptor fields to `PluginSocket`, `schema_version` to `PluginManifest`, descriptor validation to `validateManifest`, new `parsePluginManifestFromJson`, new tests.

**Adds:**
- (functions inside the existing file; no new files in this slice — discovery.zig/subprocess.zig come later)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/tools/runtime.zig`, `registry.zig`, `review.zig`, `module.zig` — runtime integration is PLUGf.
- `apps/backend/src/core/config/*`, `default.json` — config is PLUGc.
- Any new file under `core/plugins/discovery.zig` or `subprocess.zig` — those are PLUGd/PLUGe.

## Detailed Requirements

- R1: Add `schema_version: u8 = 1` to `PluginManifest`. Parser rejects `schema_version` != 1 with a typed error (e.g. `Error.UnsupportedSchemaVersion`).
- R2: Add optional descriptor fields to `PluginSocket`: `description: ?[]const u8 = null`, `parameters_json: ?[]const u8 = null`, `usage_hint: ?[]const u8 = null`, `example_json: ?[]const u8 = null`. Optional preserves legacy/non-tool-socket compilation.
- R3: In `validateManifest`, for each socket with `kind == .tool`: require `description` non-empty (trim), `parameters_json` non-empty AND parsing as a JSON `object` (reuse `std.json.parseFromSlice` + `.object` check, mirroring `sockets.validateDefinition`), and `review_risk` present + valid (already checked). Return typed errors (e.g. `MissingToolDescription`, `MissingToolParameters`, `InvalidToolParameters`).
- R4: Add `pub fn parsePluginManifestFromJson(allocator: std.mem.Allocator, text: []const u8) anyerror!PluginManifest`. It parses the locked JSON schema, dupes all strings into `allocator`, builds `PluginManifest`, and frees all duped strings on any error path. Unknown top-level keys are rejected. `dependencies` parsed into a `[]const module.Dependency`-shaped slice (reuse `module.Dependency`/`DependencyKind` from `core/tools/module.zig`); recorded as metadata only. `agents` parsed as a raw/count only (recorded, not wired).
- R5: Re-export `parsePluginManifestFromJson` (and any new error variants) from `core/plugins/index.zig`.
- R6: Add ≥30 meaningful tests (see Proof expansion) using `std.testing.allocator` (assert no leaks).

## Invariants This Unit Must Preserve

- I3: parser/validator reject tool sockets with missing description/parameters_json/invalid review_risk (R3 + tests).
- I4: all edits under `apps/backend/src/core/plugins/` (Patch Surface).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | includes new manifest parse/validate test names passing; "0 failed" or equivalent | yes |

**Evidence to capture:** The `zig build test` tail output showing the manifest test count and zero failures, plus a one-line excerpt of a passing parse test name.

## Exit State (Handoff Contract)

- `core/plugins/manifest.zig` exposes `parsePluginManifestFromJson` and descriptor-bearing `PluginSocket`/`PluginManifest`; `validateManifest` enforces descriptor requirements for tool sockets.
- `core/plugins/index.zig` re-exports the parser.
- The locked on-disk JSON schema is the stable interface PLUGc (config) and PLUGd (discovery) will read.
- All manifest tests (existing + new) pass; no leaks under `std.testing.allocator`.
- PLUGc may begin adding the `plugins` config section, confident the manifest schema is stable.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/plugins/index.zig` (remove new re-exports).
2. `git checkout -- apps/backend/src/core/plugins/manifest.zig` (revert descriptor fields, schema_version, parser, tests).
3. Re-run `zig build test` to confirm the pre-PLUGb test set passes.

## Next todo

`/todo/pending/PLUGc-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests in manifest.zig (parse happy path, missing description/parameters/review_risk, invalid parameters_json, duplicate names, non-tool socket handling, dependencies metadata, unknown-key rejection, allocator leak checks).
- [ ] Tests prove the descriptor capability through `parsePluginManifestFromJson` + `validateManifest` (the real consumer path for this slice).
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: `parsePluginManifestFromJson` exported from `index.zig`; `validateManifest` enforces descriptor requirements.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGb-plugin-socket.md /todo/changelog/PLUGb-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
