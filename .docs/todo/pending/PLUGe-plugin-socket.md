---
id: PLUGe-plugin-socket
parent: PLUG-plugin-socket
type: execution-unit
protocol_version: "3.0"
category: feature
phase: e
status: pending
patch_scope: "Add core/plugins/subprocess.zig: a JSON-RPC caller that dispatches one plugin tool invocation to the plugin's entry executable over the harvested SubprocessTransport, bounded by CommandRunner/CommandLimits (timeout, output cap, Job-Object/process-group kill). Re-export from core/plugins/index.zig. No runtime wiring yet (PLUGf does it)."
blast_radius: low
blast_radius_justification: "Contained to a new module under core/plugins/. Nothing in the runtime calls it yet (PLUGf wires it into executeWithRunner). The module spawns a child process only when invoked; tests use a deterministic local executable/script fixture or a stubbed CommandRunner so no real untrusted plugin runs during tests. Failure cannot propagate to the catalog (not wired yet)."
idempotency_contract: conditionally-idempotent
idempotency_notes: "Source additions are deterministic. Condition: tests use a stubbed CommandRunner or a repo-local fixture executable; they do NOT depend on an external plugin being installed. On PARTIAL recovery, verify subprocess.zig compiles and tests use the stubbed/fixture transport; re-execute from the top."
acceptance: "dispatchPluginTool invokes the plugin entry over a bounded subprocess with a JSON-RPC request envelope and returns the plugin's response content; timeouts kill the process tree and return CommandTimedOut; oversized output is truncated and reported (not silently dropped); a stub/mock plugin round-trips the tool name + arguments and returns an ok envelope."
exit_criterion: "`zig build test` succeeds; new subprocess tests (round-trip via stubbed runner, timeout->CommandTimedOut, output cap->truncation flag, malformed plugin response->error, missing executable->FileNotFound/CommandFailed) pass."
validation: "cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40"
expected_exit_code: 0
expected_output_pattern: ".*subprocess.*pass|all tests passed|0 failed"
evidence: "PLACEHOLDER — replace with exact captured stdout at completion. Archival is gated on this field being populated."
conflict_surface: ""
invariants:
  - "I4 (ownership boundary): transport caller lives under core/plugins/; plugin implementations (executables) live outside core/ and are invoked only as subprocesses"
  - "I6 (subprocess isolation default): dispatch uses IsolationLevel.subprocess via SubprocessTransport; never in-process"
source_message_anchor: "U3, U6"
source_message_excerpt: "Plugin contract code belongs under apps/backend/src/core/plugins/. Plugin implementations must not live inside core/ ... Plugin tool socket — how plugin-provided tools integrate into the existing registry.zig + runtime.zig dispatch chain."
source_message_proof_obligation: "Implement the subprocess transport caller so a plugin tool invocation becomes a bounded, killable, output-capped JSON-RPC call to the plugin's entry executable — the harvested isolation default (subprocess) made operational. This closes the transport half of U6 and enforces U3/I6 (plugin code runs out-of-process, contract code stays in core/plugins/)."
entry_state: "PLUGb + PLUGc + PLUGd archived. core/plugins/manifest.zig exposes descriptor-bearing PluginSocket (with `entry` field). core/plugins/isolation.zig exposes SubprocessTransport{executable,args,timeout_ms,max_output_bytes}, IsolationLevel.subprocess, default_isolation_level. core/plugins/discovery.zig exposes MountedPlugin{manifest,directory,id}. core/tools/module.zig exposes CommandRunner, CommandLimits, CommandOutput, Error. runtime.zig has the Windows Job Object kill path (runCommandWithLimitsWindows) as the reference pattern."
rollback_surface: "1. Revert apps/backend/src/core/plugins/index.zig re-exports added for subprocess. 2. Remove apps/backend/src/core/plugins/subprocess.zig. Order: index.zig first, then delete subprocess.zig."
dependencies: "PLUGb"
next_todo: /todo/pending/PLUGf-plugin-socket.md
continuation: "On completion: record evidence (replace PLACEHOLDER), set status done, move this file to /todo/changelog/<same filename>, continue immediately to next_todo. Stay fully focused on this slice until it resolves. Do not switch to any other slice. Do not pause. Do not batch."
blocked_reason: ""
unblock_action: ""
resumption_point: ""
---

# PLUGe Plugin Subprocess Dispatch Transport

## Execute Now

Create `core/plugins/subprocess.zig` that turns a `MountedPlugin` tool invocation into a bounded JSON-RPC subprocess call via `CommandRunner`/`CommandLimits`, returning the plugin's response content.

## Slice Focus Rule

This unit owns the agent's attention until it resolves. The agent must create only `core/plugins/subprocess.zig` and extend `core/plugins/index.zig`, must NOT wire the transport into `runtime.executeWithRunner` (PLUGf), must NOT invent a new IPC shape, and must NOT run any real untrusted plugin in tests (use a stubbed CommandRunner or a repo-local fixture script). If a question arises about JSON-RPC error semantics, lock the minimal envelope here.

## Why This Execution Unit Exists

The harvested `isolation.zig` declares `IsolationLevel.subprocess` as the default and `SubprocessTransport` as the contract (stdio JSON-RPC, kernel-supervised kill), but no code actually invokes it. Plugin dispatch must be its own slice separate from runtime integration (PLUGf) because (a) the transport is a self-contained, testable boundary (request envelope -> bounded child -> response/error), and (b) keeping it isolated means PLUGf's runtime branch is a one-line handoff to a stable function, not a tangle of process spawning inside the dispatch switch. This slice enforces I6 (subprocess default) and I4 (implementations out of `core/`) at the mechanism level: the only way a plugin tool executes is as a separately-resolved executable, never an in-process call.

## Better-Than-Before Delta

Pre-slice, the subprocess contract is a documented intent with no implementation; there is no way to actually run a plugin tool. Post-slice, one function (`dispatchPluginTool`) turns a plugin + socket + arguments into a bounded, killable, output-capped call, reusing the same `CommandRunner`/`CommandLimits` discipline as `shell_exec` (including the Windows Job Object kill path). The transport becomes the stable primitive PLUGf calls and that PLUGh can stress-test for timeout/truncation/crash isolation.

## Slice Domain Standard

| Domain Standard | Local Evidence | Implementation Consequence | Anti-Assumption Guard |
|---|---|---|---|
| Subprocess transport = line-delimited JSON-RPC over stdio (MCP-stdio shape). | `isolation.zig:45-57` documents SubprocessTransport + "same shape as MCP stdio transport". | Request envelope = one JSON line `{jsonrpc, id, method:"invoke", params:{tool, arguments}}`; response = one JSON line with `result` or `error`. | Must NOT invent a length-prefixed binary protocol or a different RPC shape. |
| Bounded execution: timeout, output cap, kill the tree on timeout. | `runtime.runCommandWithLimitsWindows` Job Object path (`runtime.zig:744`); `module.CommandLimits{timeout_ms,max_output_bytes}` (`module.zig:118`); `shell_exec` truncation reporting. | dispatchPluginTool passes `CommandLimits` derived from SubprocessTransport; on timeout returns `Error.CommandTimedOut`; truncation is flagged, not silently dropped (AGENTS.md §IV). | Must NOT spawn an unbounded child or omit the kill path. |
| Plugin executables resolve relative to the plugin directory; never in-process. | §IX; manifest `entry` field (`manifest.zig:27`). | Resolve `<MountedPlugin.directory>/<socket.entry>` as the executable (or `<directory>/<entry>.exe`/script). | Must NOT import plugin code into the kernel. |
| Reuse CommandRunner so tests can inject a stub. | `runtime.executeWithRunner` takes a `CommandRunner` (`runtime.zig:401`); `runCommand`/`runCommandWithLimits` are the real impl. | `dispatchPluginTool` takes a `CommandRunner` parameter so tests inject a deterministic runner. | Must NOT hard-spawn inside the function with no injection point. |

## Domain-Knowledge Research Check

| Knowledge Gap | Research / Probe To Run | Source Priority | Decision It Controls | Closure Evidence |
|---|---|---|---|---|
| Minimal MCP stdio JSON-RPC tool-call envelope. | RCH-1: `engine --query "Model Context Protocol stdio transport JSON-RPC tool call request response shape"`. | MCP spec (modelcontextprotocol.io) primary. | Lock the request/response fields (method, params, result, error). | Note in this file citing the MCP framing fields used. |
| Whether the repo has an existing stdio_rpc envelope to reuse. | RCH-2: `ix search "stdio_rpc"` / read host stdio_rpc if present. | repository source | Reuse the local envelope if one exists. | PLUGe addendum: cite local envelope or confirm none + use MCP shape. |

## Technical Execution Blueprint

| Area | Required Detail |
|---|---|
| Repository anchors | New `apps/backend/src/core/plugins/subprocess.zig`; reuse `core/plugins/isolation.zig` (SubprocessTransport, IsolationLevel), `core/plugins/manifest.zig` (PluginSocket), `core/plugins/discovery.zig` (MountedPlugin), `core/tools/module.zig` (CommandRunner, CommandLimits, CommandOutput, Error, okEnvelope). |
| Existing-owner decision | New file inside `core/plugins/`. Justified: the transport caller is plugin-contract code (§IX); there is no existing transport owner — `isolation.zig` only declares the contract. |
| Domain owner / canonical standard | AGENTS.md §IX, §IV (truncation reported), §V (dispatch); MCP stdio JSON-RPC framing; the harvested `isolation.zig` contract. |
| Intended design | `pub fn dispatchPluginTool(allocator, runner: CommandRunner, plugin: MountedPlugin, socket: PluginSocket, tool_name, arguments_json, transport: SubprocessTransport) ![]u8`. Steps: (1) resolve executable = `<plugin.directory>/<socket.entry>` (lock: treat `entry` as a path relative to the plugin dir; if it has no extension on Windows, also try `.exe`). (2) Build the JSON-RPC request line: `{"jsonrpc":"2.0","id":1,"method":"invoke","params":{"tool":<tool_name>,"arguments":<arguments_json parsed then re-emitted>}}`. (3) `argv = [executable] ++ transport.args`, cwd = plugin.directory. (4) `limits = CommandLimits{ .timeout_ms = transport.timeout_ms, .max_output_bytes = transport.max_output_bytes, .output_callback = .{} }`. (5) `runner.runWithLimits(...)`. (6) On `timed_out` -> return `Error.CommandTimedOut`. (7) On non-zero exit -> return `Error.CommandFailed` (or CommandTerminated). (8) Parse the (last non-empty) stdout line as JSON; extract `result.content` (string) on success or convert `error` to a typed Error. (9) If `truncated` flag set, append a visible truncation marker to the content (AGENTS.md §IV — silent truncation is a contract violation). (10) Return content (wrapped via `module.okEnvelope` or as the plugin's own envelope — lock: the plugin returns raw content text; the transport wraps it in `okEnvelope(tool_name, content)` so the runtime sees a uniform shape). |
| Integration path | Called by PLUGf's runtime dispatch branch for `ToolSource.plugin` tools. The `CommandRunner` is threaded from `runtime.executeWithRunner` so the real process spawner (with Job Object kill) is used in production and a stub is used in tests. |
| Failure modes to prevent | Unbounded execution (no timeout); silent truncation; missing executable -> wrong error; plugin crash (non-zero exit) treated as success; in-process execution; JSON-RPC response without result/error -> ambiguous; memory leak of the request line / parsed response. |
| Alternatives rejected | In-process plugin call (rejected: I6/§IX); HTTP transport (rejected: harvested contract is stdio); length-prefixed binary (rejected: MCP stdio is line-delimited); returning raw subprocess stdout without JSON-RPC parsing (rejected: need structured success/error). |
| Proof hooks | Tests with a STUBBED CommandRunner (inject deterministic CommandOutput): round-trip returns content; timeout (timed_out=true) -> CommandTimedOut; truncation (truncated=true) -> content carries truncation marker; non-zero exit -> CommandFailed; response missing result+error -> error; executable resolution from plugin.directory+socket.entry. Optionally one test with a real tiny fixture script under a test-fixtures dir (NOT under core/) that echoes a JSON-RPC line. |

## Codebase Research And Execution Addendum

**Implementation map:** Create `apps/backend/src/core/plugins/subprocess.zig`. Read before writing: `core/plugins/isolation.zig` (already read — SubprocessTransport, IsolationLevel), `core/tools/module.zig` CommandRunner/CommandLimits/CommandOutput/Error/okEnvelope (already read), `core/tools/runtime.zig runCommandWithLimitsWindows` (already read — Job Object pattern reference). Extend `core/plugins/index.zig` to re-export `dispatchPluginTool` (+ any helper types).

**Existing-owner directive:** New file in `core/plugins/`. There is no existing transport implementation owner.

**Directive:** Implement `dispatchPluginTool` taking an injected `CommandRunner` (mandatory for testability). Reuse `module.CommandLimits` for bounds. Reuse the harvested `SubprocessTransport` for the per-call config (executable override is NOT taken from transport.executable — lock: transport.executable is reserved for the future case where a plugin ships a single runtime binary; for this chain the executable is ALWAYS resolved from `<plugin.directory>/<socket.entry>` so each tool socket can target a distinct entry. If `transport.executable` is non-empty, it overrides; otherwise resolve from entry. Document this.). The response is parsed as JSON-RPC; only the last non-empty stdout line is parsed (plugins may print logging to stderr and a single response line to stdout).

**Locked JSON-RPC envelope:**
- Request (one JSON line on stdin — but since we use `runWithLimits` which currently uses `stdin_behavior = .Ignore` in the portable path, lock: for this chain, pass `arguments` via the request envelope serialized into `argv` is NOT viable; instead pass `tool` + `arguments` as argv trailing args OR via an env var. Simplest lock consistent with harvested contract: the plugin reads the request from a single argv argument `<json-rpc-request-line>`. So `argv = [executable] ++ transport.args ++ [request_line]`. This keeps stdin ignored (matches current CommandRunner) and is testable. Document that future stdio-pump support can move the request to stdin.). Request line: `{"jsonrpc":"2.0","id":1,"method":"invoke","params":{"tool":"<name>","arguments":<args-json>}}`.
- Response (last non-empty stdout line): `{"jsonrpc":"2.0","id":1,"result":{"content":"<text>"}}` or `{"jsonrpc":"2.0","id":1,"error":{"code":<int>,"message":"<text>"}}`.
- The transport wraps success content via `module.okEnvelope(tool_name, result.content)`.

**Gold-standard guardrail:** Do NOT swallow truncation — if `CommandOutput.truncated` is true, append `\n[plugin output truncated at <max_output_bytes> bytes]` to the content. Do NOT treat non-zero exit as success. Do NOT resolve the executable to anything under `core/`.

**Knowledge gathering route:** Run RCH-1 (MCP stdio JSON-RPC shape) via the Insect runtime `engine --query` if the envelope above needs validation; otherwise anchor on the harvested `isolation.zig` comment which already commits to the MCP-stdio shape. Run RCH-2 (`ix search "stdio_rpc"`) to check for a repo-local envelope to reuse.

**Runtime visualization:** `runtime.executeWithRunner` (PLUGf) -> `dispatchPluginTool(runner, plugin, socket, tool_name, args, transport)` -> resolve executable under `plugin.directory` -> build JSON-RPC request line -> `runner.runWithLimits(argv, cwd=plugin.directory, limits=CommandLimits{timeout,max_output})` -> parse stdout last line -> on result -> `okEnvelope`; on error -> typed Error; on timed_out -> CommandTimedOut; on truncated -> append marker.

**Proof expansion:** Add ≥30 meaningful tests with a STUBBED CommandRunner (a struct capturing the call and returning a canned CommandOutput). Cover: success round-trip (plugin returns result.content -> okEnvelope has it); timed_out -> CommandTimedOut; truncated flag -> marker appended; non-zero exit -> CommandFailed; missing executable (stub returns FileNotFound-style) -> mapped error; response with error object -> typed Error; response missing result+error -> error; executable resolution (assert the runner received argv[0] == `<plugin.dir>/<entry>` or `.exe` variant on Windows); argv carries the request line; transport.args prepended correctly; large content within budget passes; budget exceeded -> truncation. If feasible, ONE test with a real fixture script (e.g., a tiny `echo`-style script) placed under `apps/backend/test-fixtures/` (NOT core/) to prove end-to-end, but the stubbed-runner tests are the load-bearing proof.

**Action-mode arbitration:** N/A (synchronous subprocess call bounded by timeout; no deferred/queued work; the timeout itself is the bounded-execution receipt).

## Embedded Framing

A plugin tool is only as isolated as its dispatch: the transport must run the plugin out-of-process, bound the execution by timeout and output cap, kill the whole tree on timeout, report truncation visibly, and parse a structured JSON-RPC response — because crash isolation and bounded execution are the difference between a plugin socket and an arbitrary code-execution hole (F1, I4, I6, AGENTS.md §IV/§IX).

## Slice Research Directive

| Research Topic | Why It Matters To This Slice | Insect Mode | Source Priority | Closure Evidence |
|---|---|---|---|---|
| MCP stdio JSON-RPC tool-call envelope (RCH-1). | Confirms the request/response field names the harvested contract commits to. | `engine --query "Model Context Protocol stdio JSON-RPC tool invoke request response"` | MCP spec primary, then docs | Note above citing fields (jsonrpc, id, method, params, result, error). |
| Repo-local stdio_rpc envelope (RCH-2). | Avoids inventing a second envelope if one exists. | `ix search "stdio_rpc"` then read | repository source | Addendum line: reuse local envelope OR confirm none + use MCP shape. |

## Original User Message Proof

| Source Anchor | Verbatim Original Snippet | Slice Proof Obligation | Evidence Capture |
|---|---|---|---|
| U3 | "Plugin contract code belongs under apps/backend/src/core/plugins/. Plugin implementations must not live inside core/" | Transport caller lives in `core/plugins/`; plugin executables resolved under `plugin.directory` (outside core) and run as subprocesses. | `test` asserting argv[0] resolves under plugin.directory, not core/; grep confirming no in-process plugin import. |
| U6 | "Plugin tool socket — how plugin-provided tools integrate into the existing registry.zig + runtime.zig dispatch chain" | Provides the dispatch primitive PLUGf integrates; reuses CommandRunner/CommandLimits (the same chain shell_exec uses). | `test` round-trip proving dispatchPluginTool returns content through the injected CommandRunner. |

## Pre-flight Checklist

- [ ] `PLUGb` archived (PLUGd not strictly required for this slice, but `MountedPlugin` comes from PLUGd — declare PLUGd as dependency too if `dispatchPluginTool` references MountedPlugin).
- [ ] `entry_state` claims verifiable: `SubprocessTransport`, `MountedPlugin`, `CommandRunner`/`CommandLimits` all exist.
- [ ] `source_message_anchor`/`excerpt`/`proof_obligation` populated and match parent.
- [ ] `conflict_surface` empty.
- [ ] Rollback procedure populated (low — new file).
- [ ] Idempotency contract read (conditionally-idempotent; tests use stubbed runner; verify before re-execute).
- [ ] No other slice being advanced.
- [ ] Slice Research Directive records RCH-1/RCH-2 + closure plan.

## Entry State

- PLUGb archived: descriptor-bearing `PluginSocket` with `entry`.
- PLUGd archived: `MountedPlugin{manifest,directory,id}`.
- `core/plugins/isolation.zig` exposes `SubprocessTransport`, `IsolationLevel.subprocess`, `default_isolation_level`.
- `core/tools/module.zig` exposes `CommandRunner`, `CommandLimits`, `CommandOutput`, `Error`, `okEnvelope`.
- `runtime.runCommandWithLimitsWindows` is the Job Object kill reference (not modified here).
- No `subprocess.zig` exists.

> Note: although `dependencies` lists only PLUGb (the manifest contract), this slice references `MountedPlugin` from PLUGd. The executing agent MUST treat PLUGd as an additional prerequisite (add it to `dependencies` before pre-flight if PLUGd is the owner of `MountedPlugin`). The cleanest resolution is to declare `dependencies: "PLUGb, PLUGd"`.

## Patch Surface

**Modifies:**
- `apps/backend/src/core/plugins/index.zig` — re-export `dispatchPluginTool` (+ helper types).

**Adds:**
- `apps/backend/src/core/plugins/subprocess.zig` — `dispatchPluginTool`, request/response envelope helpers, tests.
- (optional) `apps/backend/test-fixtures/plugins/echo/` — a tiny fixture script for one end-to-end test (NOT under core/). If a stubbed runner suffices for the floor, this is optional.

**Deletes:**
- (none)

**Must not touch (out of scope for this unit):**
- `apps/backend/src/core/tools/runtime.zig`, `registry.zig` (PLUGf).
- `apps/backend/src/core/plugins/manifest.zig`, `discovery.zig`, `isolation.zig` (consumed, not modified).
- Any real plugin executable under `core/` (forbidden by §IX).

## Detailed Requirements

- R1: `pub fn dispatchPluginTool(allocator, runner: module.CommandRunner, plugin: MountedPlugin, socket: PluginSocket, tool_name: []const u8, arguments_json: []const u8, transport: SubprocessTransport) ![]u8`.
- R2: Resolve executable: if `transport.executable` non-empty use it; else `<plugin.directory>/<socket.entry>` (on Windows, if no extension and the bare path doesn't exist, try `.exe`). Missing -> `Error.FileNotFound` (or CommandFailed).
- R3: Build JSON-RPC request line (locked envelope). `argv = [executable] ++ transport.args ++ [request_line]`. cwd = `plugin.directory`.
- R4: `limits = .{ .timeout_ms = transport.timeout_ms, .max_output_bytes = transport.max_output_bytes, .output_callback = .{} }`. Call `runner.runWithLimits(allocator, cwd, argv, limits)`.
- R5: On `output.timed_out` -> return `Error.CommandTimedOut`. On non-zero exit -> `Error.CommandFailed` (or `.CommandTerminated` if not Exited).
- R6: Parse the last non-empty stdout line as JSON. If `result.content` (string) present -> success content. If `error` present -> map to a typed Error (e.g., return `Error.CommandFailed` carrying the message, or a plugin-error envelope). If neither -> error.
- R7: If `output.truncated` -> append `\n[plugin output truncated at <N> bytes]` to content before wrapping (AGENTS.md §IV).
- R8: Wrap success via `module.okEnvelope(allocator, tool_name, content)` and return.
- R9: Free the request line + parsed JSON on every path (use an arena or explicit frees).
- R10: ≥30 tests with a stubbed CommandRunner (round-trip, timeout, truncation, non-zero exit, error object, missing result+error, executable resolution, argv shape, transport.args prepended, large content, budget exceeded).
- R11: Update `dependencies` metadata to include PLUGd before pre-flight (MountedPlugin owner).

## Invariants This Unit Must Preserve

- I4: transport caller in `core/plugins/`; executables resolved outside `core/` and run as subprocesses (R2 + test).
- I6: dispatch via `SubprocessTransport`/subprocess; never in-process (R1/R4 + test).

## Validation Plan

| Step | Command | Expected Exit Code | Expected Output Pattern | Idempotent |
|---|---|---|---|---|
| 1 | `cd E:/Workspaces/01_Projects/01_Github/VANTARI-ONE/apps/backend && zig build test 2>&1 | tail -40` | `0` | subprocess tests pass; "0 failed" | yes (conditional on stubbed-runner test design) |

**Evidence to capture:** `zig build test` tail showing subprocess test names passing, plus an excerpt of the round-trip + timeout tests.

## Exit State (Handoff Contract)

- `core/plugins/subprocess.zig` exposes `dispatchPluginTool` taking an injected `CommandRunner`.
- `core/plugins/index.zig` re-exports it.
- The transport is the stable primitive PLUGf calls from `executeWithRunner` for plugin tools.
- PLUGf may begin merging plugin definitions into the catalog and adding the dispatch branch.

## Rollback Procedure

1. `git checkout -- apps/backend/src/core/plugins/index.zig` (remove subprocess re-exports).
2. `rm apps/backend/src/core/plugins/subprocess.zig`.
3. Remove any optional test-fixtures plugin added.
4. Re-run `zig build test`.

## Next todo

`/todo/pending/PLUGf-plugin-socket.md`

## Completion

- [ ] Pre-flight passed (dependencies updated to include PLUGd).
- [ ] Implementation-unit test floor satisfied: ≥30 meaningful feature-value tests (round-trip, timeout, truncation, non-zero exit, error object, missing fields, executable resolution, argv shape, budget).
- [ ] Tests prove dispatch through `dispatchPluginTool` with an injected CommandRunner (the real consumer path for this slice).
- [ ] All validation commands executed. Exit codes and output patterns match.
- [ ] Post-flight: transport bounded by timeout+output cap; truncation reported; non-zero exit not treated as success.
- [ ] Evidence captured. PLACEHOLDER gone.
- [ ] Status set to `done`.
- [ ] `mv /todo/pending/PLUGe-plugin-socket.md /todo/changelog/PLUGe-plugin-socket.md` verified.
- [ ] Continue immediately to `next_todo`. No pause. No batch. No sibling detour.
