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

The stdio host detaches request threads while Server remains stack-owned, frees Runtime during deinit without joining request workers, admits sessions through a non-atomic check/set pair, and lets the client wait indefinitely for replies and child exit. This is the concrete failure class behind the reported settings hang and an unsafe shutdown boundary.

## Evidence

- [stdio_rpc.zig:200](../../../apps/backend/src/host/stdio_rpc.zig#L200) frees service/runtime state.
- [stdio_rpc.zig:312](../../../apps/backend/src/host/stdio_rpc.zig#L312) spawns and detaches one thread per request.
- [stdio_rpc.zig:605](../../../apps/backend/src/host/stdio_rpc.zig#L605) checks running state separately from the set at line 621.
- [stdio_client.zig:211](../../../apps/backend/src/host/stdio_client.zig#L211) waits for child exit without a deadline.
- [stdio_client.zig:321](../../../apps/backend/src/host/stdio_client.zig#L321) waits indefinitely for a response.

## Required mechanism

Use one bounded request executor owned by Server. Add one atomic tryStartSession transition. Protect buffer session identity and preview text as one mutex-owned object. Shutdown in this order: stop admission, signal cancellation, drain or terminate bounded work, join workers, stop services, close transport, free Server. Give every client call and child wait a deadline with a typed timeout.

Do not add another RPC server, running registry, or settings-specific workaround.

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
