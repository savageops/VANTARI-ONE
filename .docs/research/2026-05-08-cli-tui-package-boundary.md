# CLI/TUI Package Boundary

Date: 2026-05-08

## Finding

The correct monorepo boundary is executable responsibility, not feature-name accumulation inside the kernel.

Codex uses separate crates for `core`, `exec`, `tui`, and `cli`. Pi keeps the coding-agent CLI/TUI surface outside its lower agent packages. OpenCode uses a layered client/server architecture with multiple client surfaces over one session/runtime substrate. The shared invariant is not "many packages"; it is one runtime contract with thin, replaceable clients.

## VANTARI Target Shape

```text
apps/
├─ backend/
│  └─ src/
│     ├─ core/      // session, context, tools, provider, agent loop
│     ├─ host/      // stdio rpc and HTTP bridge ingress
│     ├─ shared/    // protocol and cross-client types
│     └─ clients/   // temporary CLI protocol adapter until package extraction
├─ cli/
│  └─ src/main.zig  // installable `var` command
├─ tui/             // future fullscreen terminal interface
└─ frontend/        // browser client
```

## Retained Boundary Rules

- `apps/backend` remains the only kernel owner.
- `apps/cli` owns the installable `var` executable and command-line entrypoint.
- The future fullscreen TUI must be a separate client package, because rendering, terminal input, scrollback, diff widgets, and interaction state are not kernel responsibilities.
- Headless execution is a CLI mode before it becomes a separate package. Split `apps/headless` only when it has a distinct executable contract, test lane, or automation release target.
- API/socket surfaces stay under `apps/backend/src/host/` while they are runtime ingress adapters. Split them only if a separate deployable server exists.
- Shared protocol moves out of backend only when two or more package build graphs import it directly.

## Architecture Flow

```text
var CLI / future TUI / browser
  └─ protocol client
      └─ stdio rpc or HTTP bridge
          └─ VAR1 kernel
              ├─ session lifecycle
              ├─ context compiler
              ├─ tool registry/runtime
              ├─ provider transport
              └─ append-only .var evidence
```

## Rejected Shapes

- Kernel-owned fullscreen TUI: couples terminal rendering and runtime safety.
- Separate packages for "sockets" and "API" before a second deployable exists: package theater.
- Duplicate CLI execution path outside `session/create`, `session/send`, and `session/list`: parallel runtime.
- Global session root import: violates project-local `.var/sessions`.

## Immediate Slice

Create `apps/cli` as the first real package. It imports the backend module and delegates execution to the existing CLI/kernel surface. This makes `var` install/build ownership explicit while keeping runtime state, provider calls, tools, and sessions in the backend kernel.

On Windows PowerShell, `var` is a reserved language keyword. The package still ships `var.exe` for cmd/Git Bash/Unix parity, and also ships `vantari.exe` as the PowerShell-safe alias.

Workspace ownership follows execution context. The installed client resolves `VANTARI_WORKSPACE` first, then an explicit installed override created by `vantari workspace set <path>`, then the terminal's current directory and ancestors. The installer must not bind a default repository workspace. Provider credentials are different from workspace ownership: installed clients may read `%LOCALAPPDATA%\Vantari\auth\auth.json`, while session artifacts remain under the resolved workspace `.var/sessions`.
## Zig TUI Reference Probe

Checked `E:\Workspaces\04_Repo_Collection\zig` after the first interactive CLI probe failed operator expectations.

- `zml-master/bin/zml-smi/tui` uses `vaxis`/`vxfw` with explicit init, tick, key press, mouse, redraw, and surface drawing. This is the strongest candidate for a future fullscreen `apps/tui` package because it already models terminal UI as an evented application rather than styled stdout.
- `ziex-main/src/tui` exposes `Printer`, `Colors`, and `Box`; useful for CLI output polish, but not enough for the agent chat TUI core.
- `attyx-main` has Windows terminal/editor dispatch patterns worth mining for platform edges, not for the main UI framework.

Immediate conclusion: repair the line-mode CLI first; use `vaxis` as the reference candidate when `apps/tui` becomes a real package.
