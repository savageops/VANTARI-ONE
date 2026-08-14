---
type: research
id: research/2026-08-14-ttsr-abort-move60
status: applied-source-only
date: 2026-08-14
owner: apps/backend/src/core/executor/loop.zig; apps/backend/src/core/providers/openai_compatible.zig
---

# TTSR stream-abort boundary

## Question

When a time-traveling stream rule matches, how can VANTARI stop the provider
read before a stale terminal response is committed, inject the correction
durably, and retry through the same executor without adding a stream manager?

## Failure boundary

The stream callback could observe a matching rule, but the provider read loop
could continue consuming buffered SSE data and reach terminal completion. That
left the correction/retry decision racing with a terminal assistant response.
The safe seam is the existing provider stream reader and executor retry state,
not a second cancellation channel or provider-specific loop.

## Reference harvest

| Source | Invariant retained | VANTARI compression decision |
|---|---|---|
| `.refs/can1357__oh-my-pi/packages/coding-agent/src/session/agent-session.ts` | TTSR abort state is explicit and post-prompt recovery waits for the retry/continuation gate. | Keep one typed stream-abort outcome in the existing executor loop; do not add a recovery manager. |
| `.refs/can1357__oh-my-pi/packages/coding-agent/src/commands/ttsr.ts` | Rule matches are a real stream feature, not a post-hoc text rewrite. | Keep matching at the provider delta boundary and make the read stop before terminal settlement. |
| `.refs/can1357__oh-my-pi/packages/coding-agent/src/edit/streaming.ts` | Stream rules evaluate the relevant projected content while it is still streaming. | Preserve the existing VANTARI hook surface; abort the transport as soon as the callback requests it. |

## Decision

- Add one `StreamAborted` provider error and one `StreamHooks.shouldAbortFn` callback to the existing stream reader.
- Check the abort flag before reads, after buffered-event processing, and after assistant/reasoning delta callbacks. Forward the hook through every provider adapter.
- Let `loop.zig` catch the typed outcome, persist the correction as a user message plus `rule_injected` event, and retry through the existing turn loop.
- Retain a post-completion guard for adapters that ignore the callback. No second stream reader, provider registry, or prompt-only retry is allowed.

## Evidence

- `apps/backend/scripts/zigw.ps1 build test --summary all` — `19/19` steps and `2,151/2,151` Debug tests passed.
- `apps/backend/scripts/zigw.ps1 build -Doptimize=ReleaseFast --summary all` — `9/9` steps passed; source SHA-256 is `521FE17CC941C0CA34605FFEAADD27BA9B3DC5001847022A308AFFE45BA26DE7`.
- The regression proves that a matching stream injects one durable correction, does not commit the stale terminal response, and retries through the normal executor path.
- Installed promotion remains deferred; the preserved installed owner was not replaced or run against the new source.

## Residual boundary

Source provider adapters and the executor retry path are proven. A live
provider-specific TTSR stream and installed binary proof remain open until the
installed-promotion boundary is lifted.
