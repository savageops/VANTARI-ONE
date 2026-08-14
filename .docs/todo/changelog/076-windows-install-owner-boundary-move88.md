---
type: changelog
id: changelog/076-windows-install-owner-boundary-move88
status: closed
updated: 2026-08-14
---

# Move 88 — Windows install owner boundary

## Result

The installer no longer force-stops exact-path processes. It requires one
authenticated owner projection for the current workspace, requests graceful
shutdown through `/owner/shutdown`, and verifies that the complete exact-path
process tree has drained before the staged swap begins.

## Changed owner

- `apps/backend/scripts/install_windows.ps1`

## Proof

- PowerShell parse passed.
- Live locked-binary dry run failed closed on stale projection for PIDs
  `22152,29908`; no process or target binary changed.
- Existing installed owner lifecycle proof passed with `4/4` clients,
  graceful shutdown, crash recovery, generation replacement, and zero
  proof-owned processes. Evidence:
  `apps/backend/.zig-cache/owner-proofs/cc2c1a439e624c188a2cf03bb8f2c98f`.
- Source validation passed: `19/19` build steps and `2,196/2,196` tests.

## Remaining blocker

Installed promotion is not claimed. The installed hash is
`F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`; the
source ReleaseFast hash is
`E9E6BBBED7F7A52D3A5B48EAB78D63D4AA38E10FA548F468608771551067D4B8`.
The active installed owner pair has no matching current projection, so the
installer correctly refuses to terminate it.
