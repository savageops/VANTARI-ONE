---
type: extraction
id: chat-log-level-posture
status: applied
version: 1.0.0
---

# Chat log-level posture

`runtime.log_level` is a three-value operator posture: `silent` (default),
`normal`, or `full`. It controls only the operator-facing chat projection and
the matching prompt instruction. The append-only event/session ledgers remain
complete at every level. `silent` suppresses internal telemetry, repetition,
and transient mechanics; `normal` exposes concise operational checkpoints;
`full` permits diagnostic lifecycle detail. A blocker is shown only when it
changes the operator's next action.
