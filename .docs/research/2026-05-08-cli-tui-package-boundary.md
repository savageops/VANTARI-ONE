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

Workspace ownership follows execution context. The installed client resolves `VANTARI_WORKSPACE` first, then the terminal's current directory and ancestors, then an explicit installed override created by `vantari workspace set <path>`. The installer must not bind a default repository workspace.
