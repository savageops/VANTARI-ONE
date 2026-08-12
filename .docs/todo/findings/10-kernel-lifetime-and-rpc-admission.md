---
type: finding
id: harness-finding-10
status: closed
priority: P0
owner: apps/backend/src/host
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Kernel lifetime and RPC admission

## Finding

The initial audit found detached request threads, a non-atomic session check/set,
unsynchronized buffer identity/preview state, and unbounded client reply/exit
waits. Moves 5–11 now close that complete failure class through existing host,
runtime, buffer, and process owners.

## Evidence

- `Server` owns a four-worker thread pool and 32-request admission gate; overload
  is typed and shutdown drains the executor before service/state deinit.
- `LocalClient` applies method deadlines, retires late request IDs, bounds
  graceful/forced exit plus reader drain, and owns its child through
  `shared/process_tree.zig`.
- `Runtime.tryStartSession` atomically selects one turn owner and queues a losing
  prompt as a bounded interjection under the same mutex.
- `BufferProjection` owns session identity and preview together; late callbacks
  from a prior session are rejected and consumers receive owned copies.
- `Runtime.beginShutdown` fences queued turns and marks every active session for
  cancellation before the request pool joins.

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
- Closed move 8: 100 synchronized contenders produced one turn owner and 99
  non-starters; a separate probe proved the losing steer is retained.
- Closed move 9: A→B session switching rejected a late A preview while preserving
  the already-returned owned A copy and exposing only B state to B.
- Closed move 10: a real provider transport remained blocked until EOF-driven
  shutdown signalled cancellation. Join completed below two seconds, exactly one
  `session_cancelled` event persisted, the RPC result reported `cancelled`, and
  late admission failed as `ServerShuttingDown`. Twenty repeat runs passed.
- Full pinned graph: 19/19 steps and 1,923/1,923 tests; host lane 224/224.
- Installed ReleaseFast hash matches source at
  `6E6DFC9688F3B2763487C7A379586E17376546784F16AEC736493EF7F602CB4A`;
  installed settings transport remains 5 ms with zero surviving process.

## Acceptance

- 100 concurrent admissions produce one turn owner and 99 non-starters; losing
  user prompts preserve the interjection contract instead of starting or dropping work.
- Closing stdin during an active provider request exits without use-after-free,
  leaked worker, or lost/duplicated terminal event.
- A non-replying kernel returns a typed timeout; the TUI remains responsive.
- Settings open/close is exercised through the real TUI-to-kernel transport.
- Windows process inventory returns to zero after cancellation and exit.

## Source and salvage

- User: “settings makes the TUI hang”.
- [Eve](https://github.com/vercel/eve): guarded cancellation over durable stream identity.
- [OpenHands Runtime](https://docs.openhands.dev/openhands/usage/architecture/runtime): one runtime owner for action execution and teardown.

## Out of scope

Do not redesign provider streaming, ticket routing, or TUI layout in this item.
