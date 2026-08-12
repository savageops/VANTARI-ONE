---
type: finding
id: harness-finding-10
status: pending
priority: P0
owner: apps/backend/src/host
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Kernel lifetime and RPC admission

## Finding

The initial audit found detached request threads, a non-atomic session check/set,
unsynchronized buffer identity/preview state, and unbounded client reply/exit
waits. Moves 5–7 and 11 closed the detached-worker and settings-hang failure
class. Moves 8–10 retain the admission, buffer, and full shutdown-stress work.

## Evidence

- `Server` owns a four-worker thread pool and 32-request admission gate; overload
  is typed and shutdown drains the executor before service/state deinit.
- `LocalClient` applies method deadlines, retires late request IDs, bounds
  graceful/forced exit plus reader drain, and owns its child through
  `shared/process_tree.zig`.
- Session admission still checks and marks running in separate transitions.
- Buffer session identity and preview remain separate synchronization surfaces.

## Required mechanism

Use one bounded request executor owned by Server. Add one atomic tryStartSession transition. Protect buffer session identity and preview text as one mutex-owned object. Shutdown in this order: stop admission, signal cancellation, drain or terminate bounded work, join workers, stop services, close transport, free Server. Give every client call and child wait a deadline with a typed timeout.

Do not add another RPC server, running registry, or settings-specific workaround.

## Progress — 2026-08-12

- Closed moves 5–7: bounded executor/admission/drain, typed client deadlines,
  late-response retirement, one shared Windows Job Object, bounded child exit,
  forced process-tree termination, and bounded reader drain.
- Closed move 11: 58/58 TUI tests cover settings open/apply/close/reopen/timeout
  and remote errors. The installed transport flipped `full_access_mode` in an
  isolated workspace, returned in 5 ms, cleaned all state, and left zero process.
- Remaining: move 8 atomic `tryStartSession`, move 9 one mutex-owned buffer
  state object, and move 10 active-request shutdown stress/terminal-event proof.

## Acceptance

- 100 concurrent sends for one session produce one admitted turn and 99 typed SessionRunning results.
- Closing stdin during active requests exits without use-after-free, leaked worker, or lost terminal event.
- A non-replying kernel returns a typed timeout; the TUI remains responsive.
- Settings open/close is exercised through the real TUI-to-kernel transport.
- Windows process inventory returns to the expected owner set after cancellation and exit.

## Source and salvage

- User: “settings makes the TUI hang”.
- [Eve](https://github.com/vercel/eve): guarded cancellation over durable stream identity.
- [OpenHands Runtime](https://docs.openhands.dev/openhands/usage/architecture/runtime): one runtime owner for action execution and teardown.

## Out of scope

Do not redesign provider streaming, ticket routing, or TUI layout in this item.
