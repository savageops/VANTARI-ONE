---
id: PLUGa-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: a
status: superseded
decision: deferred-delete
patch_scope: "Interpretation freeze and invariant declaration for the plugin socket chain. No artifact change."
blast_radius: low
blast_radius_justification: "No code, config, or doc artifact is modified. This unit only locks interpretation, scope boundaries, and invariants that downstream units inherit. Failure cannot propagate because nothing is executed against the runtime."
idempotency_contract: idempotent
idempotency_notes: "No artifact change. Re-reading and re-locking interpretation produces the same locked contract. Crash recovery: re-execute from the top."
acceptance: "The locked interpretation, scope-floor (tool sockets only; opt-in; ownership boundaries), and invariants I1-I8 are recorded as the authoritative entry state for PLUGb onward, with every source-language anchor mapped."
exit_criterion: "This file is present in /todo/pending/ with completed Interpretation Locks, Invariants, and Original User Message Proof sections, and no artifact has been modified (verified by git status showing no changes)."
validation: "git -C E:/Workspaces/01_Projects/01_Github/VANTARI-ONE status --porcelain apps/backend"
expected_exit_code: 0
expected_output_pattern: "(empty — no tracked changes produced by this unit)"
evidence: "Move40 superseded this design unit before implementation. No runtime artifact was claimed. The retained plugin contract scaffolding is not model-visible; the default-visible manage_plugin placeholder was deleted. Reopen only with a concrete user-facing need and a new owner-mapped plan."
conflict_surface: ""
invariants:
  - "I1 (opt-in truth): catalog/provider/dispatch contain zero plugin tools when plugins disabled or absent"
  - "I2 (no silent expansion): plugin tool requires valid manifest + plugins.enabled + per-plugin enable"
  - "I3 (review gate preservation): invalid/missing review_risk rejected before advertisement and dispatch"
  - "I4 (ownership boundary): plugin contract under core/plugins/, runtime under core/tools/, no implementation in core/"
  - "I5 (hot-load parity): discovery re-reads on admission like agents/spec.loadRegistry"
  - "I6 (subprocess isolation default): plugin dispatch uses IsolationLevel.subprocess"
  - "I7 (capability-profile preservation): ensureToolAllowed + toolClassForName gate plugin tools by profile"
  - "I8 (config mutation safety): manage_plugin mutates config.json atomically under mutex + validates effective registry"
source_message_anchor: "U1, U2, U3, U11"
source_message_excerpt: "VANTARI needs a clean, modular, simple plugin socket — a schema/format/syntax for any 'plug' (tool, agent, modifier, extension). Plugins should have a tool with hints in the descriptor. VANTARI knows about installed plugins and can discover/use them. ... Plugin tools are opt-in and must not silently alter the model-visible tool list ... Plugin contract code belongs under apps/backend/src/core/plugins/. Plugin implementations must not live inside core/ ... Tool runtime contracts belong under apps/backend/src/core/tools/ ... Focus on the minimal slices for the plugin manifest + discovery + tool integration."
source_message_proof_obligation: "Freeze the minimal interpretation of the plugin socket so downstream units cannot drift into WASM isolation, marketplace, provider/context/event sockets, or in-process plugin code. Lock the opt-in invariant (U2), the ownership boundaries (U3), and the minimal-slice focus (U11) as the entry-state contract."
entry_state: "Repository has harvested-but-unwired plugin contracts: core/plugins/manifest.zig (PluginManifest, PluginSocket, validateManifest, mountPlugin), core/plugins/isolation.zig (IsolationLevel, SubprocessTransport, default_isolation_level=.subprocess), core/plugins/index.zig, core/tools/sockets.zig (ToolSource=builtin|plugin, ToolSocket, validateDefinition). core/tools/runtime.zig has no plugin branch. core/config/default.json has no plugins section. Highest archived chain is 033."
rollback_surface: "None. No artifact is modified. If the unit is aborted, delete this file; nothing else changes."
dependencies: ""
next_todo: NONE
continuation: "On completion: record evidence (replace PLACEHOLDER with git status output), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGa Baseline / Contract Lock

## Execute Now

Freeze the plugin-socket interpretation, scope floor, ownership boundaries, and invariant set as the authoritative entry state for every downstream unit — and modify no artifacts.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must NOT begin any implementation, must NOT edit `manifest.zig`, `runtime.zig`, `default.json`, or any source file, and must NOT reinterpret the parent scope. The only deliverable is this locked contract. If a downstream-relevant ambiguity is found, record it here as a locked interpretation, do not defer it.

## Why This Execution Unit Exists

The harvested plugin contracts are unambiguous about shape (`PluginManifest`, `ToolSource`, `IsolationLevel`), but the request contains scope-broadening words ("agent definitions", "modifiers", "extensions", "dependencies", "review risk overrides") that could be misread as authorizing WASM sandboxes, plugin marketplaces, provider/context/event socket mounting, or in-process plugin code. Phase `a` exists to fail-closed against that scope creep before a single line is written: tool sockets only, opt-in gated, contract under `core/plugins/`, runtime under `core/tools/`, plugin implementations outside `core/`. Every later unit inherits these locks.

## Better-Than-Before Delta

Pre-slice, the plugin socket is a pile of harvested types with no agreed interpretation of how far the minimal slice goes. Post-slice, the chain has a single locked contract: the scope floor, the eight falsifiable invariants, and the ownership map. This makes PLUGb–PLUGg mechanically checkable against an unambiguous entry state and lets the review (PLUGh) verify scope discipline rather than re-litigate it.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Plugin tools traverse the same definition->availability->review->dispatch spine as builtins (AGENTS.md §V). | `runtime.builtinDefinitionsForContext`, `registry.resolveAvailability`, `review.reviewToolName` block unknown tools (`review.zig:24`). | PLUGf must merge plugin definitions into the existing slices and dispatch path; no second spine. | Must NOT assume a parallel plugin-only review or dispatch path is acceptable. |
| Plugin implementations must not live in `core/`; contract code does (AGENTS.md §IX). | `manifest.zig`, `isolation.zig`, `sockets.zig` already live under `core/plugins/` and `core/tools/`. | PLUGe subprocess transport lives in `core/plugins/`; plugin executables/fixtures live outside `core/`. | Must NOT assume plugin runtime logic may be imported into `core/`. |
| Hot-load re-reads on admission, no process-local cache (proven by `agents/spec.loadRegistry`). | `spec.zig:187` re-parses config on every call. | PLUGd discovery re-reads manifests on each catalog/dispatch admission. | Must NOT assume a startup-only cache is acceptable. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| External gap already closed by local/research artifact: the manifest shape is harvested. | Re-read `core/plugins/manifest.zig` + `sockets.zig` + `isolation.zig` (done in parent reconnaissance). | repository source | Confirms no new manifest type is needed (GS1). | Parent Repository Ownership Reconnaissance table. |
| Minimal JSON-RPC framing for subprocess dispatch (deferred to PLUGe). | Defer — slice `a` does not dispatch. | MCP spec (PLUGe) | Dispatches to PLUGe; recorded as AS4. | PLUGe slice research directive. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | `core/plugins/{manifest,isolation,index}.zig`, `core/tools/{sockets,runtime,registry,review,module}.zig`, `core/config/{file.zig,default.json}`, `core/agents/spec.zig`, `shared/types.zig` (ToolDefinition, ToolRiskClass) |
| Existing-owner decision | Extend existing owners. No new owner module until PLUGd (`discovery.zig`) and PLUGe (`subprocess.zig`) — both inside `core/plugins/`, justified by the harvested contract. |
| Domain owner / canonical standard | AGENTS.md §V (tool runtime contract), §IX (source hierarchy). |
| Intended design | (Lock only — no design authored here.) Tool sockets mounted from disk, opt-in via config, dispatched over subprocess JSON-RPC, merged into the existing catalog/review/dispatch spine. |
| Integration path | (Lock only.) Catalog + provider schema via `builtinDefinitionsForContext`; dispatch via `executeWithRunner`; availability via `resolveAvailability`. |
| Failure modes to prevent | Silent expansion (plugin tool visible when disabled), review bypass, in-process plugin code, scope creep into non-tool sockets. |
| Alternatives rejected | WASM sandbox (P3 future), in-process plugin loading (§IX violation), plugin marketplace (out of scope), provider/context/event socket mounting (fail-closed via harvested `isSocketKindMountable`). |
| Proof hooks | PLUGh asserts each locked invariant with a test; PLUGa itself proves only that the locks are recorded. |

## Codebase Research And Execution Addendum

**Implementation map:** This slice inspects (does not edit): `apps/backend/src/core/plugins/manifest.zig`, `isolation.zig`, `index.zig`; `apps/backend/src/core/tools/sockets.zig`, `runtime.zig`, `registry.zig`; `apps/backend/src/core/config/file.zig`, `default.json`; `apps/backend/src/core/agents/spec.zig`. All inspected in parent reconnaissance.

**Existing-owner directive:** Lock the rule that every implementation unit extends `core/plugins/` (contract) or `core/tools/` (runtime) owners; no parallel plugin module elsewhere.

**Directive:** Record the interpretation locks, the eight invariants, and the ownership map. Do not write code.

**Gold-standard guardrail:** Do not author a "design proposal" or architecture options here — phase `a` freezes one interpretation, it does not enumerate alternatives.

**Knowledge gathering route:** Already complete (parent reconnaissance read all owners). No external research needed for this slice.

**Runtime visualization:** N/A (no runtime change).

**Proof expansion:** `git status` proving zero artifact change.

**Action-mode arbitration:** N/A (no deferred/queued work).

## Embedded Framing

Lock the contract so the rest of the chain is mechanical: tool sockets only, opt-in by config, hot-loaded from disk, dispatched over the harvested subprocess transport, merged into the shared review/availability/dispatch spine. Anything broader is a separate parent.

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| None for this slice. | Phase `a` performs no implementation and the harvested-contract reconnaissance is already complete in the parent. | N/A | repository source (already read) | Parent Repository Ownership Reconnaissance + this file's locks. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U1 | "VANTARI needs a clean, modular, simple plugin socket — a schema/format/syntax for any 'plug' (tool, agent, modifier, extension). Plugins should have a tool with hints in the descriptor. VANTARI knows about installed plugins and can discover/use them." | Freeze "socket" as the single shared spine (F1) and "tool with hints in the descriptor" as the manifest-descriptor requirement (closed by PLUGb). | Interpretation Lock L1 (socket = shared spine), L4 (descriptor hints required). |
| U2 | "Plugin tools are opt-in and must not silently alter the model-visible tool list" | Lock opt-in as invariant I1/I2 and the medium of enforcement (config gate, closed by PLUGc/PLUGf). | Interpretation Lock L2, Invariants I1, I2. |
| U3 | "Plugin contract code belongs under apps/backend/src/core/plugins/. Plugin implementations must not live inside core/" + "Tool runtime contracts belong under apps/backend/src/core/tools/" | Lock the ownership map (I4) so every later unit's file placement is checkable. | Interpretation Lock L3, Invariant I4, Ownership Map table. |
| U11 | "Focus on the minimal slices for the plugin manifest + discovery + tool integration." | Lock the scope floor (tool sockets only) and the explicit out-of-scope list so the review can reject scope creep. | Interpretation Lock L5, Out-of-Scope Lock. |

## Pre-flight Checklist

- [x] All `dependencies` are archived in `/todo/changelog/` with non-PLACEHOLDER evidence. (None — first unit.)
- [x] All `entry_state` claims are verifiable on the current filesystem. (Harvested contracts present; highest archived chain 033.)
- [x] `source_message_anchor`, `source_message_excerpt`, and `source_message_proof_obligation` are populated and match the parent.
- [x] `conflict_surface` is empty.
- [x] Rollback procedure is populated (N/A — no artifact change).
- [x] If re-executing after partial failure: idempotency_contract is read (idempotent; re-execute directly).
- [x] No other slice in this chain is being advanced while this slice is unresolved.
- [x] Slice Research Directive records the local research baseline (already complete in parent).

## Interpretation Locks

- **L1 — "Socket" = one shared spine, two sources.** The plugin socket is not a new dispatch path. Builtin tools are `ToolSource.builtin`; plugin tools are `ToolSource.plugin`; both traverse definition -> availability -> review_risk -> dispatch -> effect/event (AGENTS.md §V). PLUGf merges plugin definitions into the existing slices; it does not build a plugin-only catalog/review/dispatch.
- **L2 — Opt-in is mechanical truth.** "Opt-in" (§V) means: zero plugin tools in catalog/provider-schema/dispatch unless (a) a valid manifest exists on disk, (b) the `plugins` config section is present with `enabled: true`, and (c) the specific plugin is enabled. Default is OFF (section absent or `enabled:false`). This is enforced by config-gated discovery, not operator discipline.
- **L3 — Ownership map is fixed.** Plugin contract code (`manifest` parser, `discovery`, `subprocess` transport caller, mutation helper) lives ONLY under `apps/backend/src/core/plugins/`. Tool-runtime integration (catalog merge, availability, dispatch branch, `toolClassForName`, the `manage_plugin` builtin tool registration) lives ONLY under `apps/backend/src/core/tools/`. Plugin implementations (the executables that the subprocess transport invokes) and test fixtures live OUTSIDE `core/` (e.g., under a test fixtures dir or `.var/plugins/`). No plugin runtime logic is imported into `core/`.
- **L4 — Descriptor hints are part of the manifest contract.** "A tool with hints in the descriptor" + "usage hints, examples, review risk advertised in the manifest" means the on-disk `plugin.json` carries, per tool socket: `name`, `description`, `parameters_json`, `review_risk`, and optional `usage_hint`, `example_json` — the exact fields of `types.ToolDefinition`. A plugin tool must render identically to a builtin in catalog text and JSON.
- **L5 — Minimal-slice scope floor.** This chain mounts `.tool` sockets only. `PluginSocketKind.provider/context/event` remain declared and fail closed with the harvested `Error.UnsupportedSocketKind`. Agent definitions contributed by plugins are OUT of scope (agent hot-load already has a canonical owner in `agents/spec.zig`; a plugin->agent wiring is a separate parent). "Dependencies" in the manifest are recorded as declared metadata but NOT resolved/installed by this chain (no package manager). "Review risk overrides" means the manifest advertises the tool's `review_risk`; it does not let a plugin override the kernel's review gate.

## Out-of-Scope Lock

The following are explicitly out of scope and PLUGh must verify none was silently added:
- WASM sandbox isolation (`IsolationLevel.wasm_sandbox` — P3 future).
- In-process loading of plugin-provided code (§IX violation).
- Provider/context/event socket mounting (fail-closed only).
- Plugin-provided agent definitions wired into `agents/spec.zig`.
- Plugin dependency resolution / installation / marketplace.
- Plugin signing or network distribution.
- Any change to the agent-spec hot-load owner (`agents/spec.zig`).

## Ownership Map (locked)

| Concern | Owner path (absolute) | New or existing |
|---|---|---|
| Manifest types + disk parser | `apps/backend/src/core/plugins/manifest.zig` | existing (extend in PLUGb) |
| Isolation + transport contract | `apps/backend/src/core/plugins/isolation.zig` | existing (consumed in PLUGe) |
| Plugin namespace re-export | `apps/backend/src/core/plugins/index.zig` | existing (extend in PLUGb/d/e) |
| Discovery + hot-load registry | `apps/backend/src/core/plugins/discovery.zig` | new (PLUGd) |
| Subprocess dispatch caller | `apps/backend/src/core/plugins/subprocess.zig` | new (PLUGe) |
| Config mutation (enable/disable) | helper in `apps/backend/src/core/plugins/` + `apps/backend/src/core/config/file.zig` | new/extend (PLUGc, PLUGg) |
| Config schema + validation | `apps/backend/src/core/config/default.json`, `apps/backend/src/core/config/file.zig` | extend (PLUGc) |
| Catalog + provider schema merge | `apps/backend/src/core/tools/runtime.zig` | extend (PLUGf) |
| Availability | `apps/backend/src/core/tools/registry.zig` | extend (PLUGf) |
| Review gate | `apps/backend/src/core/tools/review.zig` | no change (already generic over `[]const ToolDefinition`) |
| Tool-socket provenance | `apps/backend/src/core/tools/sockets.zig` | extend only if PLUGf needs a provenance marker |
| manage_plugin tool | `apps/backend/src/core/tools/builtin/manage_plugin.zig` + register in `registry.zig`/`runtime.zig` | new (PLUGg) |

## Entry State

- Harvested plugin contracts present and unmodified: `core/plugins/{manifest,isolation,index}.zig`, `core/tools/sockets.zig`.
- `core/tools/runtime.zig` has no plugin dispatch branch; `builtinDefinitionsForContext` returns only compiled-in slices.
- `core/config/default.json` has no `plugins` section; `file.zig validateDocumentShape` rejects unknown top-level keys.
- `core/agents/spec.zig` is the canonical hot-load + config-mutation reference (mutex + validate-before-write).
- Highest archived chain is 033; `PLUG-` prefix is reserved for this chain.

## Patch Surface

**Modifies:**
- (none)

**Adds:**
- (none)

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- Every file under `apps/backend/src/` — this unit changes no artifacts.
- All config, all source, all tests.

## Detailed Requirements (Interpretation Locks delivered)

- R1: Record Interpretation Locks L1–L5 (above) as the authoritative entry-state interpretation.
- R2: Record the eight invariants I1–I8 (metadata + Invariants section) as the falsifiable conditions PLUGh must verify.
- R3: Record the Ownership Map and Out-of-Scope Lock so every later unit's file placement and scope are checkable.
- R4: Map every source-language anchor (U1–U11) to at least one downstream unit (done in parent Source Message Coverage; this unit confirms U1/U2/U3/U11).

## Invariants This Unit Must Preserve

- I1–I8 are declared (not yet implemented); this unit preserves them by not weakening any lock.

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `git -C E:/Workspaces/01_Projects/01_Github/VANTARI-ONE status --porcelain apps/backend` | `0` | empty (no tracked changes) | yes |

**Evidence to capture:** The exact `git status --porcelain apps/backend` stdout (expected empty) confirming no artifact was modified by this baseline unit.

## Exit State (Handoff Contract)

- Interpretation Locks L1–L5 are recorded in this file.
- Invariants I1–I8 are recorded and inherited verbatim by PLUGb–PLUGg.
- Ownership Map and Out-of-Scope Lock are recorded.
- No artifact under `apps/backend/` was modified (proven by empty `git status`).
- The next unit (PLUGb) may begin extending `core/plugins/manifest.zig` with descriptor fields + a disk parser, confident that: tool sockets only, descriptor fields required, opt-in enforced later by PLUGc/PLUGf, ownership under `core/plugins/`.

## Rollback Procedure

1. Delete `/todo/pending/PLUGa-plugin-socket.md` (or, if archived, move it back to `/todo/pending/`).
2. No source/config/doc revert is required — none was modified.

## Next todo

`/todo/pending/PLUGb-plugin-socket.md`

## Completion

- [ ] Pre-flight passed.
- [ ] Implementation-unit test floor: this unit is baseline/contract-lock (documentation-only) and claims the documented exemption — no executable tests apply.
- [ ] `git status --porcelain apps/backend` is empty (no artifact change).
- [ ] Interpretation Locks L1–L5, Invariants I1–I8, Ownership Map, Out-of-Scope Lock recorded.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGa-plugin-socket.md /todo/changelog/PLUGa-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
