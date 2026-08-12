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
- Untracked apps/backend/auth.json contains secret-shaped provider fields.

## Required mechanism

Set a generated isolated VANTARI_HOME on every test run artifact in build.zig. Add a test-mode guard that rejects runtime paths outside that root. Keep production environment behavior unchanged. Ignore legacy auth/config/session/todo/memory/changelog paths immediately, then migrate them to the canonical runtime root with explicit backup and readback.

For this incident: wait for the exact installed process pair to exit, snapshot C:\Users\Savage\.vantari, identify generated IDs from the recorded interval and fixture content, move them to a dated quarantine, rebuild summary/changelog projections, and verify retained rows. Do not delete by timestamp alone.

## Acceptance

- Broad tests pass with production VANTARI_HOME set in the parent shell while all test writes remain under the generated test root.
- A sentinel installed auth value cannot be read by any test.
- Test teardown leaves zero files in the production runtime root.
- Secret scanning and git status cannot stage legacy auth or state.
- Quarantine has a manifest and rollback path; live state is read back after projection repair.

## Source-message proof

- “assume full responsibility for any in progress work and make sure it is complete/accounted for”

## Out of scope

Do not remove or rewrite active user runtime data before backup and process shutdown.
