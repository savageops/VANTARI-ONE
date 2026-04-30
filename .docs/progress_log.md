# VANTARI-ONE Technical Progress Log

Updated: 2026-04-30
Branch: `develop`
Base HEAD before this slice: `56d3eb8 feat(var1): prioritize tool effect receipts`
Runtime lane: `apps/backend/variant-1`
Kernel executable: `VAR1`

## Current State

VANTARI-ONE is currently a local agent harness centered on one Zig kernel, `VAR1`. The backend lane at `apps/backend/variant-1` is the only live runtime lane. CLI, browser, and future desktop shells are clients of the same session runtime; they do not own storage, provider wiring, tool dispatch, or context construction.

The tracked git worktree was clean before this progress-log artifact was refreshed. Latest fresh validation in this turn:

- `.\scripts\zigw.ps1 build test --summary all` -> `88/88 tests passed`
- `.\zig-out\bin\VAR1.exe health --json` -> `ok: true`
- Active health model -> `glm-5.1`
- Active health base URL -> `https://api.z.ai/api/coding/paas/v4`
- Active auth provider -> `zai`
- `.\zig-out\bin\VAR1.exe tools --json` -> tool catalog emits availability metadata, including `search_files` with `external_command` dependency `iex` available
- Live comparison against `main` (`3d33a01`) on Z.AI `glm-5.1`: upgraded `develop` completed the six-operation file-tool benchmark in session `session-1777576359915-3cf77bc839898869`; `main` failed in session `session-1777576409385-a2b609f0db4508dc` after one `write_file` with `StepLimitExceeded`.

Live Z.AI credentials/configuration are not recorded here. The effective provider state resolves through ignored `.var/auth/auth.json`; secrets remain local and are not copied into this document.

## Architecture Lock

- One runtime primitive: `session`
- One durable runtime root: `.var/`
- One canonical session root: `.var/sessions/<session-id>/`
- One complete transcript: `messages.jsonl`
- One model-window checkpoint ledger: `context.jsonl`
- One protocol: JSON-RPC 2.0 over stdio with `Content-Length` framing
- One browser bridge surface: `POST /rpc`, `GET /events`, `GET /api/health`
- One live backend lane: `apps/backend/variant-1`
- One external browser client: `apps/frontend/var1-client`
- No old `.harness` runtime root, no old task facade, no old `/api/tasks*` HTTP surface, no old storage migration reader

Canonical session layout:

```text
.var/sessions/<session-id>/
  session.json
  messages.jsonl
  context.jsonl
  events.jsonl
  output.txt
```

## Source Ownership

- `src/shared/` owns shared types, filesystem helpers, and protocol payloads.
- `src/core/sessions/` owns `.var/sessions` storage.
- `src/core/context/` owns builder, compactor, budget estimation, and provider-overflow classification.
- `src/core/executor/loop.zig` owns session execution and model/tool turn progression.
- `src/core/providers/openai_compatible.zig` owns provider transport.
- `src/core/tools/` owns tool contracts, availability, dispatch, workspace state, and mutating-tool effect receipts.
- `src/core/tools/builtin/*.zig` owns per-tool `definition`, `availability`, and `execute`.
- `src/core/auth/` owns the `.var/auth/auth.json` auth ledger and effective provider resolution.
- `src/core/config/` owns `.env` parsing and non-secret `.var/config/settings.toml` context/prompt policy.
- `src/core/prompts/` owns the model-presented prompt envelope, including hidden kernel guardrails, optional user-editable system/developer prompt files, and tool-use contract assembly.
- `src/core/plugins/` owns manifest/socket validation only. It does not load plugins yet.
- `src/host/stdio_rpc.zig` owns the stdio JSON-RPC host.
- `src/host/http_bridge.zig` owns HTTP routing for the browser bridge.
- `src/host/bridge_access.zig` owns local-origin policy, bridge tokens, redaction, audit classification, and durable bridge audit emission.
- `src/clients/cli.zig` owns the protocol-backed CLI shell.

## Completed Runtime Work

1. Repo-root and public docs were normalized around VANTARI-ONE as a local agent harness rather than a vague replay/inspection runtime.
2. Runtime state moved from `.harness` into `.var`; legacy task/session compatibility readers and facades were removed.
3. Session storage was finalized around `session.json`, `messages.jsonl`, `context.jsonl`, `events.jsonl`, and `output.txt`.
4. Message records gained stable IDs and monotonic sequence numbers so compaction boundaries do not depend on array positions.
5. The context builder became the sole owner for turning session storage into provider-ready messages.
6. Manual `session/compact` was implemented through `core/context/compactor.zig`.
7. Compaction became entry-aware: checkpoints record covered sequence range, `first_kept_seq`, `compacted_entry_count`, and `aggressiveness_milli`.
8. Auto-threshold compaction and one-shot provider-overflow retry were added through the same compactor primitive.
9. Non-secret context policy moved to optional `.var/config/settings.toml` with fail-closed unknown-key behavior.
10. Public provider config was renamed to canonical `BASE_URL`, `API_KEY`, `MODEL`, `WORKSPACE`, and `MAX_STEPS`.
11. Effective provider state now resolves through `.var/auth/auth.json` after auth is seeded.
12. The backend source layout was collapsed into canonical `shared`, `core`, `host`, and `clients` ownership domains.
13. Built-in tools were split into per-tool modules under `core/tools/builtin/`.
14. Tool catalog availability became truthful: schemas and current capability state are both reported.
15. `search_files` became explicitly command-backed by the real `iex` executable; missing `iex` makes search unavailable at the capability boundary instead of failing late.
16. The stale `rg_search` compatibility alias and string-branch tool registry drift were removed.
17. Browser bridge CORS was narrowed to explicit local HTTP origins; `Origin: null` direct-file access is denied.
18. Bridge token handshake was added through `/api/health`; `/rpc` and `/events` require `X-VAR1-Bridge-Token`.
19. Bridge-visible health/error/RPC/event payloads share key-based and value-pattern redaction for secret-shaped strings.
20. Bridge audit was promoted from stderr to append-only redacted `var1.bridge_audit.v1` JSONL at `.var/audit/bridge.jsonl`.
21. Audited session/auth/write-capable bridge actions fail closed when audit persistence fails.
22. `scripts/health.ps1` now diagnoses stale local `VAR1.exe` processes before validation/build gates.
23. `scripts/local_gemma_smoke.ps1` became model-parametric and can run small-model transport/tool checks even when the model fails the strawberry reasoning sentinel.
24. Complex-tool smoke testing against `gemma-4-e2b-it` proved tool execution paths but exposed weak small-model artifact self-evaluation.
25. Mutating file tools now return structured `var1.tool_effect.v1` receipts for `write_file`, `append_file`, and `replace_in_file`.
26. Effect receipts record requested path, resolved path, before/after existence, before/after byte counts, operation-specific counts, and SHA-256 evidence.
27. Effect action and metric vocabularies are typed in `core/tools/module.zig` instead of free-form strings.
28. Write and replace receipts derive post-state hashes from committed buffers; append receipts derive deterministic expected post-state from pre-read content plus appended payload.
29. Mutating tool `content` is now effect-first for weaker models: it starts with `EFFECT_SCHEMA var1.tool_effect.v1` and `EFFECT_KEY effect` before legacy `PATH`/`BYTES`.
30. The structured `effect` JSON object remains canonical for programmatic clients, while legacy content remains present for compatibility.
31. Prompt assembly moved out of `core/tools/runtime.zig` into `core/prompts/builder.zig`.
32. Optional `[prompts]` settings now support workspace-relative `system_prompt_file` and `developer_prompt_file`; missing or empty files fall back to built-in defaults while unknown keys and absolute paths fail closed.
33. Tool descriptors and the rendered catalog now emphasize JSON-object call grammar, recovery from `ok:false`/tool-error hints, path-discovery order, and effect/result evidence for weaker models.
34. Isolated-cache comparison builds proved the upgraded descriptor catalog differs from `main`; the upgraded live lane executed `write_file -> read_file -> append_file -> read_file -> replace_in_file -> read_file` and returned the exact required final answer, while `main` stopped after only the first write.

## Recent Commit Chain

- `834a632 feat(var1): add prompt layer envelope` - added the canonical prompt envelope, configurable system/developer prompt paths, hidden guardrail layer, and stronger tool descriptors.
- `56d3eb8 feat(var1): prioritize tool effect receipts` - made model-visible mutating-tool content effect-first.
- `4e8924b feat(var1): add mutating tool effect receipts` - added structured file-effect metadata and SHA-256 receipts.
- `3d33a01 Harden local model smoke harness` - made the Gemma smoke lane model-aware and tolerant for small-model probes.
- `5870dfe fix: harden VAR1 bridge and tool contracts` - closed redaction, registry, settings, and stale-process review findings.
- `6a5b5c7 docs: refresh validation status` - synchronized validation counts after runtime hardening.
- `3fc24be feat(var1): harden context tools and bridge` - delivered tool capability truthfulness, bridge hardening, and context policy work.
- `c1e4eb6 docs: reframe Ventari as agent harness` - corrected product framing and public documentation.
- `d8ce1e0 refactor/runtime: canonicalize VAR1 kernel ownership` - moved the backend into the current layered ownership hierarchy.

## Tool Surface

Current built-in tools:

- `list_files` - native workspace discovery.
- `search_files` - content search through `iex search --json`; unavailable if a real `iex` executable is not resolvable.
- `read_file` - exact workspace file reads with optional line range.
- `write_file` - whole-file write with `var1.tool_effect.v1` receipt.
- `append_file` - additive write with `var1.tool_effect.v1` receipt.
- `replace_in_file` - exact string replacement with `var1.tool_effect.v1` receipt.
- `launch_agent` - child session launch.
- `agent_status` - non-blocking child session status.
- `wait_agent` - bounded child wait returning completion or current snapshot.
- `list_agents` - current parent child-session listing.

## Context And Compaction

The context system intentionally separates durable history from model-visible context. `messages.jsonl` remains the complete transcript. `context.jsonl` stores compacted checkpoints only. The builder reads `session.json`, `messages.jsonl`, and the latest valid checkpoint, then emits provider messages as runtime/system context, compacted summary, and recent raw transcript.

Manual compaction is live through `session/compact`. Auto-compaction is also wired, but it calls the same compactor primitive and is governed by `.var/config/settings.toml`. Exact tokenizer integration is not currently required; approximate token heuristics remain acceptable while tests prove checkpoint/event behavior and provider-overflow recovery.

Current context policy shape:

```toml
[context]
auto_compaction = true
manual_compaction = true
context_window_tokens = 128000
compact_at_ratio = 0.85
reserve_output_tokens = 8192
keep_recent_messages = 8
max_entries_per_checkpoint = 0
aggressiveness_milli = 350
retry_on_provider_overflow = true
```

## Prompt Layers

The prompt system intentionally separates editable user instruction layers from non-editable kernel constraints. `src/core/prompts/builder.zig` emits one OpenAI-compatible system-role envelope with explicit sections for internal guardrails, system prompt, developer prompt, and tool-use contract. The transport role stays conservative for OpenAI-compatible servers that do not support a separate developer role, while the prompt text preserves the boundary shape for the model.

Optional prompt override shape:

```toml
[prompts]
system_prompt_file = ".var/prompts/system.md"
developer_prompt_file = ".var/prompts/developer.md"
```

Those files are workspace-relative and user-editable. Hidden guardrails, tool rules, tool availability, and the catalog are assembled from compiled kernel code and module-owned tool definitions, not from a user-editable prompt file.

## Security And Audit Posture

- Default bridge bind remains `127.0.0.1`.
- Browser access requires explicit local HTTP origins.
- Direct-file browser origin is denied.
- `/api/health` is the bridge-token handshake.
- `/rpc` and `/events` require the bridge token.
- Sensitive keys and secret-shaped values are redacted before bridge-visible output leaves the backend.
- Session/auth/write-capable bridge RPCs append redacted audit records to `.var/audit/bridge.jsonl`.
- Audit write failure blocks audited mutation instead of allowing unaudited state.

## Current Known Boundaries

- The local small model `gemma-4-e2b-it` can use the harness and tools, but it still has weaker reasoning and artifact self-evaluation than larger models.
- The strawberry sentinel for the small model previously returned `2` instead of `3`; this is treated as model capability degradation, not a transport/runtime failure.
- Mutating-tool effect receipts improve model-visible evidence and the Z.AI `glm-5.1` benchmark shows better evidence-grounded adherence than the prior legacy receipt lane, but receipts are not a full deterministic artifact validator or a complete model-obedience fix.
- Prompt layering improves instruction salience and configurability; the first direct `main` comparison shows better tool batching/adherence under the same auth-only step budget, but deterministic validators remain the next boundary for artifact correctness after mutating tools.
- The active provider is currently Z.AI `glm-5.1`; switch-provider smokes must preserve `.var/auth/auth.json` secret hygiene and avoid recording API keys in docs or logs.
- Plugin manifests and sockets validate contracts only; runtime plugin discovery/execution is intentionally not active.
- Exact tokenizer accounting is deferred until the current heuristic proves insufficient under real overflow evidence.

## Next High-Value Steps

1. Add deterministic artifact validators for mutating tools where the expected artifact class is known, starting with shell/script syntax and JSON/TOML validation.
2. Add a repeatable model-adherence evaluation harness that scores baseline tool-output salience, prompt-layer presentation, descriptor clarity, and effect-first receipts across local and remote providers.
3. Keep bridge audit and redaction tests in the primary validation gate as more browser actions become write-capable.
4. Add provider-switch smoke support that can test remote providers through a temporary resolved config without mutating local `.env` or leaking secrets.
5. Preserve the current invariant: compact, typed, explicit capability boundaries before dynamic workers, plugin loading, or broader automation.
