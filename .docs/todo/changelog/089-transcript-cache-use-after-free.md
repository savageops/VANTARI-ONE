## 089 — Transcript row cache use-after-free after agent launches

- **Commit**: `cbe52dd`
- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `decef39c42960487` at `/usr/local/bin/vantari`

### Crash evidence

Two TUI segfaults in dmesg (`11:43:24`, `11:50:01`): user-mode **read** of an
unmapped, page-aligned heap address (`error 4`), both on the binary that
introduced the transcript row cache — after launching multiple agents.

### Root cause

Cached `TranscriptRow` text borrows `Message` storage. Child-agent activity
events rewrite exactly that storage mid-list
(`updateChildActivity`/`upsertActivityProgress`/`appendToolProgress` →
`replaceTextOwned` frees the old buffer) while cached rows still point at it.
The cache key (width, message count, last-message length, reasoning) missed
middle-message rewrites — next draw rendered freed memory; GPA munmaps freed
large allocations → SIGSEGV at a page boundary.

Flag-only mutations (`setActivityChildrenState`, `markPriorActivitySiblings`)
produced the non-crashing variant: frozen child rows rendering stale state.

### Fix

Invalidate by construction: `transcript_revision` bumps at every message
mutation; cache validity compares revisions. Length/count fields removed.

### Second bug found in the same audit

Footer cache dirty key covered status/model/width but not `waiting`,
`cancel_requested`, `scroll_offset`, agent counts, context tokens, or pool
pressure — the footer froze after the first agent launch. Fixed with
`footer_telemetry_revision`; footer rebuild now formats the replacement
before freeing the old line (failed format no longer leaves a dangling cache).

### Verification

- Regression tests: activity rewrite moves revision without count change;
  footer telemetry revision moves without status/model movement
- Debug gate 19/19, 2,236/2,240 (4 platform skips)
- Live on deployed binary: `/agents`, prompt turn, scroll, `/clear` — no
  crash; dmesg shows zero new segfaults after deploy
