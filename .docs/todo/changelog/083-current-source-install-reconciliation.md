---
type: changelog
id: current-source-install-reconciliation
status: closed
updated: 2026-08-14
---

# Current source/install reconciliation

The fresh ReleaseFast build from the current worktree passed the full `19/19`
step graph and `2,182/2,182` tests. Its SHA-256 is
`3EFF45169AEC2BC419B20FF0EC8228A3B12AA508C5E93BE21509427F40191550`.

`install_windows.ps1 -SkipBuild` first observed an already-exited stale PID and
failed closed without force-stop. The retry passed the exact owner boundary,
installed the current artifact, retained the previous binary as a recoverable
`.bak`, and retained the existing runtime config and provider auth. Source and
installed SHA-256 now match.

Installed `--help`, `health --json`, `tools --json`, `auth status --json`, and
`workspace` probes exited `0`; the catalog exposed 33 tools, including
`ask_user` and `replace_in_file`. The final source/installed exact-path process
census was zero. Move 89 remains partial for native effect/write review,
cancellation, restart/cold-start, TUI, and provider-driven question response;
no fallback or second repair system was added.
