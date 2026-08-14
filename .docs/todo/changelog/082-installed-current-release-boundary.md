---
type: changelog
id: installed-current-release-boundary
status: closed
updated: 2026-08-14
---

# Installed current-release boundary

`apps/backend/scripts/install_windows.ps1 -SkipBuild` installed the current
ReleaseFast artifact after the exact installed-process gate was clear. The
installed SHA-256 is
`50546CCD5EEDD4E451AAF08134186CF321366AABE659A636BA7AB08F74F5EF88`, equal to
the source artifact; the previous binary was retained as a timestamped `.bak`.
The installer retained the existing runtime config and provider auth.

Installed `--help`, `health --json`, `tools --json`, `auth status --json`, and
`workspace` probes exited `0`. The catalog exposed 33 tools, including
`ask_user` and `replace_in_file`. Repository-scoped proof owners were drained
through authenticated `POST /owner/shutdown`; the final source and installed
exact-path process census was zero. The user-scoped projection was preserved
whenever it was live; no installed process was force-stopped.

The provider-driven question lane remains open because the real provider did
not emit `input_requested` in the bounded source probe. No fallback or second
question system was added.
