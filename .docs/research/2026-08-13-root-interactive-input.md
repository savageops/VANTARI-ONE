---
type: research-record
id: research/root-interactive-input
status: current
updated: 2026-08-13
owner: apps/backend/src/core/tools/builtin/ask_user.zig
---

# Root interactive input

## Decision

Keep operator questions as one root-only tool and one RPC method. `ask_user`
normalizes a bounded batch to stable option ids `a`–`f`, reserves `f` for
inline Other text, persists the request as `var1.input_requested.v1`, and waits
on the host `InputBroker`. The TUI owns only a projection and resolves through
`input/respond`.

This keeps the model as the decision plane and the prompt as the behavior
control plane. The kernel owns only capability truth, validation, persistence,
review risk, wake-up, cancellation, and recovery. Headless child profiles omit
the tool and fail with `InputUnavailable`; they do not block on operator input.

## Harvest

| Reference | Invariant harvested |
|---|---|
| `.refs/badlogic__pi-mono/.../examples/extensions/questionnaire.ts` | One questionnaire controller can batch related questions, support tabs, and finish with explicit submit. |
| `.refs/openai__codex/codex-rs/app-server/README.md` | User input is a request/resolution protocol with a bounded question count. |
| `.refs/can1357__oh-my-pi/.../warp-events.ts` | Input requests are attention events, not a parallel transcript. |
| `.refs/savageops__scion/cmd/sciontool/commands/status.go` | Waiting-for-input is a status projection plus notification, not a new execution owner. |
| `.refs/nullclaw-main/src/interactions/choices.zig` | Choice counts and input sizes need hard bounds. |
| `.refs/vercel__eve/.../runtime/input/types.ts` | Request ids, typed question kinds, and freeform responses make resolution explicit. |

Rejected: a second status bus, question poller, child input loop, transcript
copy, global question registry, and a new resolved-event family. The existing
event spine, RPC dispatch, input surface, and tool span already own the needed
state transitions.

## Runtime contract

```text
provider -> ask_user -> input_requested event -> TUI controller
                                      <- input/respond <- operator
       <- response JSON <- InputBroker <-
       -> tool_finished -> turn_terminal
```

- `InputBroker` keys pending waits by session id plus tool-call id. Provider
  ids are local to a turn and may repeat across sessions.
- Session cancellation and owner shutdown broadcast to pending waits.
- Terminal event replay clears a stale controller before cold-start rendering.
- Request, label, description, Other text, answer count, and serialized payload
  sizes are bounded before provider dispatch or event persistence.
- A malformed or unresolved request fails with protocol-visible input error;
  it does not silently fall back to a prompt or hang.

## Proof

- Debug canonical graph: `19/19` steps, `2,023/2,023` tests.
- Falsification coverage: duplicate request ids across sessions, broker
  cancellation wake-up, empty-answer rejection, inline Other serialization,
  terminal cleanup, and normalized `a`–`f` request shape.
- Installed promotion remains required: ReleaseFast build, source/installed
  hash equality, real TUI question request/response, and zero proof-owned
  processes. No installed claim is made until that lane completes.
