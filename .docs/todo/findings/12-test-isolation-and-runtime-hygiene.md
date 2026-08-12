---
type: finding
id: harness-finding-12
status: closed
priority: P0
owner: apps/backend/build.zig
source: ../../research/2026-08-12-full-harness-sitrep.md
---

# Test isolation and runtime hygiene

## Finding

The initial broad runner and a later direct `zig test` invocation inherited
production VANTARI_HOME. Tests could then read installed auth or write sessions,
summaries, todos, and changelog records into the live runtime root. Legacy state
also existed unignored at apps/backend outside the canonical .var owner.

## Incident evidence

- The inherited run failed 71 tests and touched C:\Users\Savage\.vantari.
- The isolated rerun reduced the failure set to 3.
- Incident window: 2026-08-12 09:43:57 through 09:51:26.
- 130 session directories; 512 session files; 17 changelog files; 4 todo files; 535 files and 2,214,002 bytes touched.
- [fsutil.zig:191](../../../apps/backend/src/shared/fsutil.zig#L191) gives VANTARI_HOME precedence over each test workspace.
- Ignored `apps/backend/auth.json` contains credential-shaped provider fields.
- Follow-up direct-test incident: 21 exact shutdown-probe sessions, 84 files, and
  19,401 bytes; zero summary/changelog projection hits and unchanged config/auth.

## Required mechanism

Set a generated isolated VANTARI_HOME on every build-graph artifact and direct
wrapper test. Add a test-mode guard that rejects runtime paths outside that root.
Keep production environment behavior unchanged. Ignore legacy
auth/config/session/todo/memory/changelog paths immediately, then migrate them to
the canonical runtime root with explicit backup and readback.

For this incident: wait for the exact installed process pair to exit, snapshot C:\Users\Savage\.vantari, identify generated IDs from the recorded interval and fixture content, move them to a dated quarantine, rebuild summary/changelog projections, and verify retained rows. Do not delete by timestamp alone.

## Acceptance

- Broad tests pass with production VANTARI_HOME set in the parent shell while all test writes remain under the generated test root.
- A sentinel installed auth value cannot be read by any test.
- Test teardown leaves zero files in the production runtime root.
- Secret scanning and git status cannot stage legacy auth or state.
- Quarantine has a manifest and rollback path; live state is read back after projection repair.

## Closure — 2026-08-12

- Moves 1–2: all six test artifacts use `addIsolatedTestRun`; child homes and
  `std.testing.tmpDir` stay under `apps/backend/.zig-cache`, and the test-only
  guard rejects escape. The graph passes 1,923/1,923 with zero skips while the
  live root remains byte/count/hash identical.
- Move 3: the pre-repair snapshot remains at
  `C:\Users\Savage\.vantari-backups\2026-08-12-test-isolation-incident-pre-repair`.
  The exact 129 sessions, 16 changelog directories, 18 summary keys, and 64
  known test rows are quarantined at
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-test-isolation-incident`.
  Manifest, rollback, zero-hit live readback, auth preservation, and zero
  process inventory are proven.
- Move 4: seven legacy backend owners containing 2,252 files and 2,127,443 bytes
  are archived without merge under
  `.var/backup/2026-08-12-legacy-backend-runtime`. All old sources are absent,
  archive readback matches, secret-shaped fixtures remain untracked, and
  todo/changelog sync uses direct workspace `.var` owners.
- Move 31 removed the retired `todo_slice` prompt instruction, duplicate
  file-inspection prose, and brittle wording assertions without weakening the
  enforced write-before-inspect contract.
- Follow-up closure: `scripts/zigw.ps1` and `scripts/zigw.sh` now assign direct
  `zig test` invocations a generated cache-owned `VANTARI_HOME` and
  `VANTARI_TEST_ROOT`. The 21 exact shutdown-probe sessions are copied under
  `C:\Users\Savage\.vantari-backups\2026-08-12-host-shutdown-stress-incident-pre-repair`
  and quarantined under
  `C:\Users\Savage\.vantari-quarantine\2026-08-12-host-shutdown-stress-incident`
  with matching payload digest, manifest, and rollback. A direct rerun kept the
  live root at 99,960 files / 693,051,144 bytes with config/auth unchanged.

No generated fixture was merged into operator state. This finding is closed.

## Source-message proof

- “assume full responsibility for any in progress work and make sure it is complete/accounted for”

## Out of scope

Do not remove or rewrite active user runtime data before backup and process shutdown.
