---
type: finding
id: harness-finding-12
status: pending
priority: P0
owner: apps/backend/build.zig
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Test isolation and runtime hygiene

## Finding

The broad test runner inherits production VANTARI_HOME. Tests then read installed auth and write sessions, summaries, todos, and changelog records into the live runtime root. Legacy state also exists unignored at apps/backend outside the canonical .var owner.

## Incident evidence

- The inherited run failed 71 tests and touched C:\Users\Savage\.vantari.
- The isolated rerun reduced the failure set to 3.
- Incident window: 2026-08-12 09:43:57 through 09:51:26.
- 130 session directories; 512 session files; 17 changelog files; 4 todo files; 535 files and 2,214,002 bytes touched.
- [fsutil.zig:191](../../../apps/backend/src/shared/fsutil.zig#L191) gives VANTARI_HOME precedence over each test workspace.
- Ignored `apps/backend/auth.json` contains credential-shaped provider fields.

## Required mechanism

Set a generated isolated VANTARI_HOME on every test run artifact in build.zig. Add a test-mode guard that rejects runtime paths outside that root. Keep production environment behavior unchanged. Ignore legacy auth/config/session/todo/memory/changelog paths immediately, then migrate them to the canonical runtime root with explicit backup and readback.

For this incident: wait for the exact installed process pair to exit, snapshot C:\Users\Savage\.vantari, identify generated IDs from the recorded interval and fixture content, move them to a dated quarantine, rebuild summary/changelog projections, and verify retained rows. Do not delete by timestamp alone.

## Acceptance

- Broad tests pass with production VANTARI_HOME set in the parent shell while all test writes remain under the generated test root.
- A sentinel installed auth value cannot be read by any test.
- Test teardown leaves zero files in the production runtime root.
- Secret scanning and git status cannot stage legacy auth or state.
- Quarantine has a manifest and rollback path; live state is read back after projection repair.

## Progress — 2026-08-12

- Move 1 is closed. All five test artifacts use one
  `addIsolatedTestRun` constructor. Each child receives a generated
  `VANTARI_HOME`; the parent shell does not change.
- Move 2 is closed. The test-only `VANTARI_TEST_ROOT` marker constrains global and
  workspace runtime paths to Zig's cache root. An outside path returns
  `TestRuntimePathOutsideRoot` before directory creation; ReleaseFast compiles
  the marker out of production runtime behavior.
- Deleted 31 `VANTARI_HOME` skip guards. The broad graph now executes all
  1,695 tests instead of hiding 188 cases.
- With the parent pointed at `C:\Users\Savage\.vantari`, the run preserved
  live file count, byte count, and the complete relative-path/content tree
  SHA-256. It passed 1,695 of 1,695.
- Move 31 is closed. Removed one retired `todo_slice` prompt instruction, one
  duplicate file-inspection instruction, and brittle prose assertions while
  preserving the enforced write-before-inspect contract.
- A recoverable pre-repair snapshot exists at
  `C:\Users\Savage\.vantari-backups\2026-08-12-test-isolation-incident-pre-repair`.
  The copy contains 100,483 files and 693,081,758 bytes. Incident
  classification found 129 session directories whose prompts all match exact
  Zig source literals.
- Live mutation remains paused because a new installed TUI/kernel pair started
  as PIDs 10624 and 33816 during snapshot verification. Their new session and
  scheduler lease were preserved.

This finding stays pending. Move 3 still owns incident quarantine and projection
readback after the active installed pair exits. Move 4 owns reversible quarantine
of ignored backend fixtures plus consolidation of the split todo/changelog owner;
no fixture merge into live `.var` or `.vantari` is justified.

## Source-message proof

- “assume full responsibility for any in progress work and make sure it is complete/accounted for”

## Out of scope

Do not remove or rewrite active user runtime data before backup and process shutdown.
