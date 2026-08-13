---
id: PLUGh-plugin-socket
parent: PLUG-plugin-socket
type: review-closeout
protocol_version: "3.0"
category: feature
phase: h
status: superseded
decision: deferred-delete
patch_scope: "No artifact change. This unit reviews, validates, verifies invariants, judges code quality and architecture, and decides whether the chain terminates or extends."
blast_radius: low
blast_radius_justification: "Read-only execution. Validation commands do not modify system state."
idempotency_contract: idempotent
idempotency_notes: "Validation commands are read-only (`zig build test`, `git status`, grep). Re-execution from any point is safe."
acceptance: "The full plugin-socket deliverable passes regression, every source anchor U1-U11 is implemented/evidenced/closed, every invariant I1-I8 holds with a passing test, every architectural target A1-A4 is verified, and the ownership/opt-in/scope-discipline audits pass — or the chain extends with a focused fix slice for any actionable finding."
exit_criterion: "Terminal review decision: PASS (close chain, archive parent) or EXTEND (create fix slice + new re-review)."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -60 && zig build 2>&1 | tail -20"
expected_exit_code: 0
expected_output_pattern: "all tests passed|0 failed|build success"
evidence: "Move40 superseded this review unit before implementation. No plugin runtime artifact exists to review. The default-visible manage_plugin placeholder was deleted; the retained manifest/isolation/socket types are contract-only and not model-visible. Reopen with a concrete need and a new owner-mapped plan."
conflict_surface: ""
invariants:
  - "I1-I8 (full set — verified as a block in this review)"
source_message_anchor: "U1, U2, U3, U4, U5, U6, U7, U8, U9, U10, U11"
source_message_excerpt: "(all parent anchors — closeout verifies every original-user-message requirement is implemented, evidenced, or explicitly closed)"
source_message_proof_obligation: "Verify every source-message anchor is mapped to a completed unit, every proof obligation has evidence, and no original-user-message requirement is lost between parent and closeout."
entry_state: "PLUGa through PLUGg were reviewed as the planned chain, but the plugin runtime remained unimplemented. Move40 superseded the chain before runtime integration; only contract-only manifest/isolation/socket types remain."
rollback_surface: "None. If review fails, the next action is chain extension, not rollback."
dependencies: "PLUGa, PLUGb, PLUGc, PLUGd, PLUGe, PLUGf, PLUGg"
next_todo: NONE
continuation: "Stay focused on this review until it reaches a decision. If pass: record evidence, status done, archive, execute Parent Archival Protocol. If fail: do not close; create the smallest fix slice + new terminal re-review slice, update parent manifest and phase plan, continue from the new fix slice."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGh Review, Regression, and Closeout Decision

## Execute Now

Run the full regression suite, assert all chain invariants I1–I8, judge the implementation quality and architecture, then either close the chain or extend it with the smallest fix slice the review proves is necessary.

## Review Focus Rule

This review owns the chain decision point. Do not speculate about follow-on fixes before the review findings exist. If the review passes, stop. If it fails, extend only with evidenced findings.

## Domain Standard Audit

| Standard / Criterion | Declared In | Evidence Used During Implementation | Review Evidence | Status |
|---|---|---|---|---|
| GS1 reuse harvested contracts (no parallel types) | parent + PLUGb | manifest.zig/sockets.zig/isolation.zig extended, not duplicated | grep confirming no second PluginManifest/ToolDefinition-like type in core/plugins or core/tools | [ ] PASS / [ ] FAIL |
| GS2 shared review/availability/dispatch spine | parent + PLUGf | effectiveDefinitionsForContext merges plugin defs; executeWithRunner plugin branch after ensureToolAllowed | review.reviewToolName called with effective defs; dispatch branch governed by ensureToolAllowed | [ ] PASS / [ ] FAIL |
| GS3 fail-closed validation | parent + PLUGb/d | validateManifest rejects missing review_risk/UnsupportedSocketKind; discovery skips invalid | manifest test + discovery malformed-skipped test | [ ] PASS / [ ] FAIL |
| GS4 subprocess reuse CommandRunner/Job Object kill | parent + PLUGe | dispatchPluginTool uses CommandLimits + injected runner | subprocess test: timeout->CommandTimedOut, truncation flagged | [ ] PASS / [ ] FAIL |
| GS5 manage_plugin mirrors configure_agent | parent + PLUGg | setPluginEnabled: mutex + validate-before-write + receipt | manage_plugin test: receipt sha + hot-load | [ ] PASS / [ ] FAIL |

## Assumption Ledger Audit

| Assumption ID | Resolution Evidence | Still Risky? | Status |
|---|---|---|---|
| AS1 (manifest extensible) | PLUGb added descriptor fields; existing tests still pass | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS2 (provider schema from builtinDefinitionsForContext) | PLUGf verified via grep + effectiveDefinitionsForContext is the schema source | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS3 (plugins dir under runtime root) | PLUGc pluginDirectory resolves under .var/plugins | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS4 (MCP-stdio JSON-RPC) | PLUGe envelope matches MCP shape; RCH-1 closed | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| AS5 (mutate config.json not a separate file) | PLUGg setPluginEnabled writes config.json | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Better-Than-Before Audit

| Target ID | Claimed Better-Than-Before Outcome | Evidence | Status |
|---|---|---|---|
| A1 (harvested contracts reachable) | Plugin tool appears in catalog + dispatches via subprocess | PLUGf catalog test + PLUGe round-trip test | [ ] PASS / [ ] FAIL |
| A2 (opt-in mechanically enforced) | plugins section default-OFF; catalog byte-identical when disabled | PLUGc disabled-default test + PLUGf byte-equality test | [ ] PASS / [ ] FAIL |
| A3 (ToolSource provenance rendered) | catalog emits source/plugin for plugin tools | PLUGf provenance test + grep ToolSource.plugin read | [ ] PASS / [ ] FAIL |
| A4 (model can discover + manage) | manage_plugin list/info/enable/disable work + hot-load | PLUGg manage_plugin tests | [ ] PASS / [ ] FAIL |

## Embedded Framing Audit

| Frame ID | Expected Embedded Meaning | Evidence In Parent / Units | Status |
|---|---|---|---|
| F1 (one socket, two sources) | shared spine; only transport differs | PLUGf focus + review gate reuse | [ ] PASS / [ ] FAIL |
| F2 (opt-in = mechanical truth) | config-gated discovery | PLUGc + PLUGf disabled-byte-equality | [ ] PASS / [ ] FAIL |
| F3 (harvested contracts load-bearing) | manifest/isolation/sockets reused | PLUGb/d/e extend existing owners | [ ] PASS / [ ] FAIL |
| F4 (hot-load, never stale) | no process-local cache | PLUGd hot-load test + PLUGg hot-load test | [ ] PASS / [ ] FAIL |

## Research Coverage Audit

| Research ID / Topic | Declared In | Evidence Present | Implementation Impact Recorded | Status |
|---|---|---|---|---|
| RCH-1 (MCP stdio JSON-RPC) | PLUGe | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| RCH-2 (repo stdio_rpc envelope) | PLUGe | [ ] YES / [ ] NO | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Repository Ownership Audit

| Ownership Question | Declared Owner / Evidence | Review Finding | Status |
|---|---|---|---|
| Did each slice modify/extend the real canonical owner? | core/plugins/{manifest,discovery,subprocess,policy,isolation}.zig + core/tools/{runtime,registry,sockets}.zig + core/tools/builtin/manage_plugin.zig + core/config/{file.zig,default.json} | grep confirming changed files match the parent Ownership Map | [ ] PASS / [ ] FAIL |
| Were duplicate/adjacent owners collapsed or bounded? | no second manifest/discovery/transport/catalog created | grep confirming no parallel plugin catalog or dispatch module | [ ] PASS / [ ] FAIL |
| Did any slice rely on prompt-only fixes, hardcoded triggers, or active-tool absence? | expected no | review of dispatch path (real CommandRunner dispatch, not prompt advertisement) | [ ] PASS / [ ] FAIL |
| Are unsupported boundaries proven by probes? | wasm_sandbox/provider/context/event sockets fail closed via harvested isSocketKindMountable | manifest test for UnsupportedSocketKind | [ ] PASS / [ ] FAIL |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Covered By Unit(s) | Evidence / Closeout Signal |
|---|---|---|---|
| U1 | "VANTARI needs a clean, modular, simple plugin socket ... Plugins should have a tool with hints in the descriptor. VANTARI knows about installed plugins and can discover/use them." | PLUGa (lock), PLUGb (descriptor), PLUGd (discovery), PLUGf (use), PLUGg (manage) | archived evidence fields; catalog test shows plugin tool with descriptor; manage_plugin list test |
| U2 | "Plugin tools are opt-in and must not silently alter the model-visible tool list" | PLUGa, PLUGc, PLUGf, PLUGh | disabled-byte-equality test; config default-OFF |
| U3 | "Plugin contract code belongs under apps/backend/src/core/plugins/. Plugin implementations must not live inside core/ ... Tool runtime contracts belong under apps/backend/src/core/tools/" | PLUGa, all impl units, PLUGh | grep: changed files match ownership map; plugin executables/fixtures outside core/ |
| U4 | "Plugin manifest schema — a .var/plugins/<name>/plugin.json format declaring: name, version, tool definitions, agent definitions, dependencies, review risk overrides" | PLUGb | parsePluginManifestFromJson test parsing the locked schema |
| U5 | "Plugin discovery — scan .var/plugins/ for manifests, register tools/agents at startup" | PLUGd | loadPluginsForRuntime fixture test |
| U6 | "Plugin tool socket — how plugin-provided tools integrate into the existing registry.zig + runtime.zig dispatch chain" | PLUGe, PLUGf | dispatch-via-spy-runner test; effectiveDefinitionsForContext merge test |
| U7 | "Plugin lifecycle — load, enable/disable, unload (hot-loadable like agent specs)" | PLUGc, PLUGd, PLUGg | hot-load re-read test; enable/disable round-trip test |
| U8 | "Plugin descriptor hints — usage hints, examples, review risk advertised in the manifest" | PLUGb | manifest descriptor-fields test |
| U9 | "Config surface — plugins.enabled, plugins.path, per-plugin enable/disable" | PLUGc | loadPluginPolicy test; default.json diff |
| U10 | "A manage_plugin tool — list, enable, disable, info operations for the model to discover and manage plugins" | PLUGg | manage_plugin execute test (all 4 actions) |
| U11 | "Focus on the minimal slices for the plugin manifest + discovery + tool integration." | PLUGa (scope lock), PLUGh (scope audit) | out-of-scope lock honored: no WASM, no marketplace, no provider/context/event sockets, no plugin->agent wiring |

## Pre-flight Checklist

- [ ] Every execution unit from `PLUGa` through `PLUGg` is in `/todo/changelog/`.
- [ ] No unit in `/todo/changelog/` for this chain has `evidence: PLACEHOLDER`.
- [ ] No unit in `/todo/pending/` for this chain remains `in-progress` or `blocked`.
- [ ] All exit state claims from prior units are verifiable on the current filesystem.
- [ ] Every parent source-message anchor appears in ≥1 archived unit's `Original User Message Proof`.
- [ ] Every declared research obligation has closure evidence or an explicit no-research justification.
- [ ] Every parent and slice domain standard has review evidence or a documented failure finding.
- [ ] Every assumption is resolved, downgraded with evidence, or converted into a review finding.

## Invariant Assertion Surface

| Invariant ID | Statement | Verification Command | Expected Result |
|---|---|---|---|
| I1 | catalog/provider/dispatch contain zero plugin tools when plugins disabled/absent | `zig build test` (PLUGc disabled-default + PLUGf byte-equality tests) | both pass |
| I2 | plugin tool requires valid manifest + plugins.enabled + per-plugin enable | `zig build test` (PLUGd valid+enabled vs disabled-by-map tests) | pass |
| I3 | invalid/missing review_risk rejected before advertisement + dispatch | `zig build test` (PLUGb validate test + PLUGf review-block test) | pass |
| I4 | plugin contract under core/plugins/; runtime under core/tools/; no implementation in core/ | `git diff --name-only` against pre-chain + grep for plugin impl under core/ | changed files match Ownership Map; no plugin executable/import under core/ |
| I5 | discovery re-reads on admission, no process-local cache | `zig build test` (PLUGd hot-load test) | pass |
| I6 | plugin dispatch uses IsolationLevel.subprocess | `zig build test` (PLUGe round-trip via CommandRunner; never in-process) | pass |
| I7 | ensureToolAllowed + toolClassForName gate plugin tools by profile | `zig build test` (PLUGf profile-deny test + PLUGg manage_plugin profile test) | pass |
| I8 | manage_plugin mutates config atomically under mutex + validates effective registry | `zig build test` (PLUGg receipt + validate-before-write tests) | pass |

## Acceptance Criteria Matrix

| Unit | Acceptance Criterion | Status |
|---|---|---|
| PLUGa | Interpretation Locks L1-L5 + Invariants I1-I8 + Ownership Map recorded; no artifact change | [ ] PASS / [ ] FAIL |
| PLUGb | parsePluginManifestFromJson + descriptor fields + validateManifest reject missing description/parameters/review_risk | [ ] PASS / [ ] FAIL |
| PLUGc | plugins section default-OFF + loadPluginPolicy + pluginDirectory + _help parity | [ ] PASS / [ ] FAIL |
| PLUGd | loadPluginsForRuntime hot-loaded + policy-gated + malformed-skipped + findTool | [ ] PASS / [ ] FAIL |
| PLUGe | dispatchPluginTool bounded by timeout/output cap + truncation reported + injected CommandRunner | [ ] PASS / [ ] FAIL |
| PLUGf | effectiveDefinitionsForContext merge gated + dispatch via dispatchPluginTool + review/profile preserved + disabled byte-equality | [ ] PASS / [ ] FAIL |
| PLUGg | manage_plugin list/info/enable/disable + setPluginEnabled mutex+validate+receipt + profile-gated | [ ] PASS / [ ] FAIL |

## Source Message Coverage Audit

| Source Anchor | Original Snippet Present In Parent | Covered By Unit | Evidence Present | Status |
|---|---|---|---|---|
| U1 | [ ] YES / [ ] NO | PLUGa/b/d/f/g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U2 | [ ] YES / [ ] NO | PLUGa/c/f/h | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U3 | [ ] YES / [ ] NO | PLUGa + all impl + h | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U4 | [ ] YES / [ ] NO | PLUGb | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U5 | [ ] YES / [ ] NO | PLUGd | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U6 | [ ] YES / [ ] NO | PLUGe/f | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U7 | [ ] YES / [ ] NO | PLUGc/d/g | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U8 | [ ] YES / [ ] NO | PLUGb | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U9 | [ ] YES / [ ] NO | PLUGc | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U10 | [ ] YES / [ ] NO | PLUGg | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |
| U11 | [ ] YES / [ ] NO | PLUGa/h | [ ] YES / [ ] NO | [ ] PASS / [ ] FAIL |

## Regression Surface

**Files in combined patch surface:**
- `apps/backend/src/core/plugins/manifest.zig` — touched by PLUGb (and PLUGf if `tool_class` added there)
- `apps/backend/src/core/plugins/index.zig` — touched by PLUGb/d/e/g (re-exports)
- `apps/backend/src/core/plugins/discovery.zig` — added by PLUGd
- `apps/backend/src/core/plugins/subprocess.zig` — added by PLUGe
- `apps/backend/src/core/plugins/policy.zig` (or extended file) — added by PLUGg
- `apps/backend/src/core/tools/runtime.zig` — touched by PLUGf/g
- `apps/backend/src/core/tools/registry.zig` — touched by PLUGf/g
- `apps/backend/src/core/tools/sockets.zig` — possibly touched by PLUGf (provenance)
- `apps/backend/src/core/tools/builtin/manage_plugin.zig` — added by PLUGg
- `apps/backend/src/core/config/file.zig` — touched by PLUGc
- `apps/backend/src/core/config/default.json` — touched by PLUGc
- (optional) `apps/backend/test-fixtures/plugins/...` — fixture(s) outside core/

## Full Regression Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern |
|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -60` | `0` | `<n> passed, 0 failed` (all existing + new plugin tests) |
| 2 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build 2>&1 | tail -20` | `0` | build success, no new warnings |
| 3 | `git -C E:/Workspaces/01_Projects/01_Github/VANTARI-ONE diff --name-only` | `0` | changed files match the Regression Surface list (no stray files, no plugin impl under core/) |
| 4 | `grep -rn "ToolSource.plugin" apps/backend/src/core/tools` | `0` | at least one read site (provenance rendered), not just a declaration |

**Evidence to capture:** Full stdout from all validation commands; the `git diff --name-only` output confirming the patch surface; the grep confirming ToolSource.plugin is consumed.

## Scope-Discipline Audit (U11)

- [ ] No WASM sandbox isolation code added (`IsolationLevel.wasm_sandbox` remains future-only).
- [ ] No in-process plugin code loading (all plugin dispatch via subprocess transport).
- [ ] No provider/context/event socket mounting (fail-closed via harvested `isSocketKindMountable`).
- [ ] No plugin-provided agent definitions wired into `agents/spec.zig`.
- [ ] No plugin dependency resolution/installation/marketplace.
- [ ] No plugin signing/network distribution.
- [ ] No change to the agent-spec hot-load owner beyond consumption.

If any box is unchecked, the review FAILS and the chain extends with a fix slice that removes the scope creep.

## Review Findings And Extension Decision

| Finding ID | Severity | Surface | Evidence | Requires Extension? |
|---|---|---|---|---|
| R1 | <high|medium|low> | <owner boundary or file set> | <test/lint/type/review evidence> | [ ] YES / [ ] NO |

(To be filled during review execution. Start empty. If all audits pass and no findings require extension, the chain closes.)

## Regression Triage (if failures occur)

1. Identify which test(s) or lint rule(s) failed.
2. Trace the failure to its origin: which execution unit's patch surface introduced it?
3. Determine: regression (invariant broken), incomplete implementation (acceptance not met), or structural defect requiring a focused fix slice?
4. If findings are real and in-scope: extend the chain — create one focused fix slice + one new terminal re-review slice. Update parent manifest, Phase Plan, `subtodo_final`, Better-Than-Before Audit rows. Do not close.
5. If findings are external blockers: block this review unit with `blocked_reason` and preserve the implementation obligation.

## Chain Audit

- [ ] Chain manifest in parent is complete: every planned letter (a–h) has a file in `/todo/changelog/`.
- [ ] Parent's Phase Plan table: all letters marked `archived`.
- [ ] No files for this chain remain in `/todo/pending/` except the parent and this unit.
- [ ] Source Message Coverage Audit: PASS for every anchor (U1–U11).
- [ ] Research Coverage Audit: PASS for every declared research obligation (RCH-1, RCH-2).
- [ ] Better-Than-Before Audit: PASS for every architectural improvement target (A1–A4).
- [ ] Embedded Framing Audit: PASS for every declared framing contract (F1–F4).
- [ ] Domain Standard Audit: PASS for every declared gold-standard decision criterion (GS1–GS5).
- [ ] Assumption Ledger Audit: no unresolved blocking assumptions (AS1–AS5).
- [ ] Scope-Discipline Audit (U11): all boxes checked (no scope creep).
- [ ] All invariants in Invariant Assertion Surface: PASS (I1–I8).
- [ ] All acceptance criteria in Acceptance Criteria Matrix: PASS (PLUGa–PLUGg).

## Next todo

`NONE`

## Completion

- [ ] All pre-flight checks passed.
- [ ] Full regression suite executed. All commands exit 0. All output patterns matched.
- [ ] All invariants asserted: PASS (I1–I8).
- [ ] All acceptance criteria resolved: PASS (PLUGa–PLUGg).
- [ ] Review findings table resolved: no extension required, or extension created and parent updated.
- [ ] Chain audit complete: all rows verified (including Scope-Discipline Audit).
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] If pass: status `done`, `mv` verified, Parent Archival Protocol executed, chain complete.
- [ ] If fail: parent extended with fix + re-review, findings recorded, execution continues.
