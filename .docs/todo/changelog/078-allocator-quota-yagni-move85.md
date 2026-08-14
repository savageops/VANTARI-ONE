---
id: changelog/078-allocator-quota-yagni-move85
parent: roadmap/24-harness-capability-next-90
type: changelog
protocol_version: "3.0"
status: closed
category: architecture
acceptance: "Move 85 is closed without speculative allocator quota infrastructure."
exit_criterion: "No measured allocator pressure or canonical quota consumer exists; the reopen gate is durable."
validation: "ix owner census plus current backend build test --summary all"
expected_exit_code: 0
expected_output_pattern: "no runtime allocator quota owner; 19/19 steps; 2180/2180 tests"
evidence: "Current source search found only an unused ScopedArena construction with no allocator, checkQuota, or bytes_allocated caller; scopes.zig and its loop lifecycle were deleted; the current backend graph passes 19/19 and 2180/2180."
dependencies: "roadmap/24-harness-capability-next-90 rows 1-84"
next_todo: "roadmap/24-harness-capability-next-90 row 88"
source_message: "Apply YAGNI ruthlessly. For every roadmap item, choose to add, merge, or delete."
source_message_proof: "The row's own condition requires counters to prove pressure before allocator quotas are added."
---

# Move 85 — delete allocator quota expansion

Deleted the unused ScopedArena and quota shell. No current measured pressure,
operator surface, or durable readback path justifies splitting allocator
quotas by turn, provider payload, tool result, or UI frame. Existing allocator
and bounded-process owners remain in place. Reopen only when a measured failure
names one owner, one consumer, and one proof path.

Validation: current source owner census and `scripts/zigw.ps1 build test
--summary all` passed 19/19 build steps and 2180/2180 tests. Source ReleaseFast
is 9/9 at SHA-256 `CD3B85914A138420B7721D9726174087F3CF1C0D7058979C7ACAFA95C04F1BF8`. No
installed promotion is claimed.
