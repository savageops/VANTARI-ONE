---
type: finding
id: harness-finding-20
status: pending
priority: P1
owner: apps/backend/src/core/tools
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Tool capability truth

## Finding

eval, DAP, TTSR, provider probing, write intents, quota scopes, and search are surfaced beyond their executable proof. The model receives capabilities whose lifecycle, timeout, persistence, or dependency contract is absent.

## Evidence

- [eval.zig:286](../../../apps/backend/src/core/tools/builtin/eval.zig#L286) advertises persistent Python/Bun; [eval.zig:330](../../../apps/backend/src/core/tools/builtin/eval.zig#L330) creates a kernel per call and Bun ignores timeout.
- [dap.zig:295](../../../apps/backend/src/core/tools/builtin/dap.zig#L295) destroys attach state on return; [dap.zig:339](../../../apps/backend/src/core/tools/builtin/dap.zig#L339) admits stacktrace starts a fresh adapter.
- [loop.zig:1124](../../../apps/backend/src/core/executor/loop.zig#L1124) records a stream-rule abort request without aborting the provider read.
- Provider capability cache and write-intent paths have tests but no canonical runtime caller.
- Installed tools reports search_files unavailable because iex is absent while ix.exe exists.

## Required mechanism

Build eval and DAP on the canonical process supervisor with session-owned state, bounded pipes, timeout, cancellation, and teardown receipts. Add an explicit provider-stream abort return for TTSR. Wire probes, intents, and quotas through their real consumers or keep them frontier-only. Resolve one installed search executable identity.

Gate only unsafe execution points while these obligations remain pending; do not convert useful capabilities into permanent unsupported copy.

## Acceptance

- Python and Bun variables survive calls in one session and never cross sessions.
- Both kernels time out, drain both pipes, and terminate their process tree.
- DAP attach, pause, stacktrace, scopes, variables, and detach use one client.
- A TTSR match stops provider streaming before terminal completion.
- Every advertised capability has a live availability probe and consumer-path test.
- search_files works through the installed binary or is truthfully unavailable with one actionable dependency name.

## Source and salvage

- [oh-my-pi](https://github.com/can1357/oh-my-pi): persistent eval, real DAP, and stream-rule interruption.
- [OpenHands Runtime](https://docs.openhands.dev/openhands/usage/architecture/runtime): sandbox-owned execution.

## Out of scope

Do not add a general plugin system or hidden shell fallbacks.
