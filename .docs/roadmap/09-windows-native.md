# 09 — Windows-Native Runtime Discipline

**Priority: P1**

## The seam

VANTARI's stated differentiator is **Windows-native first class**, with Linux/macOS via Zig cross-compilation. Every competitor here is Node/Python-first and treats Windows as an afterthought. This is the un-served operator segment, and it is a structural moat — not a feature.

## What exists today

- Single static Zig binary, zero runtime deps (no Python/Node after install).
- `install_windows.ps1` installer; `%LOCALAPPDATA%\Vantari\bin\vantari.exe` is the canonical installed path.
- Process supervision handles Windows handle lifetime, pipe draining, timeout, child termination.
- Windows-native command execution preserves argv mode, workspace-contained cwd, timeout, output budgets, process termination.
- Windows-native installed binary proof is mandatory after CLI/TUI/provider/workspace/auth changes.

## What the competitor does (Eve)

Eve is TypeScript/Node. It requires a Node runtime, expects a Temporal server for durability, and its "Windows" support is whatever Node provides. It is cheerfully cross-platform but has no Windows-first discipline: no installed-binary proof, no Windows process-lifetime handling, no handle-lifetime guarantees.

## What the competitor does (others)

- OpenAI Codex, Claude Code, Gemini CLI, OpenHands, Aider, Continue — all Node/Python/Go-TUI products. None installs a zero-dependency Windows-native binary with a first-class installer and process-supervision guarantees.
- The log.txt theme frequency confirms this is a *daily* concern: `windows` (517), `shell/exec` (1166), `process` — a whole pipeline of Windows-native work.

## Why VANTARI does it better

1. **Zero runtime dependencies.** The single Zig binary needs no Node, no Python, no Temporal, no container. Eve requires Node + Temporal. This is the operator-emptiness that Windows-native fills.
2. **First-class installer.** `install_windows.ps1` + `%LOCALAPPDATA%\Vantari\bin\vantari.exe` is a real Windows install path, tested. No competitor ships a comparable native Windows install.
3. **Windows process supervision.** VANTARI accounts for handle lifetime, pipe draining, timeout, and child termination. Eve's `shell_exec` is whatever Node's `child_process` provides.
4. **Installed proof is mandatory.** AGENTS.md §XV makes `%LOCALAPPDATA%\Vantari\bin\vantari.exe` proof mandatory after user-facing changes. This is a discipline, not a nicety.

## Pipeline items under this theme

### P1-9a: Repair installed-binary shutdown (continue from P0-4a)
- **Contract:** `vantari health --json` / `vantari tools --json` exit cleanly from the installed binary — no scheduler segfault.
- **Mechanism:** the scheduler thread is drained and joined before exit; the child-kernel lifecycle is proven through a cold-start process test.
- **Test:** the process test runs against the *installed* `%LOCALAPPDATA%\Vantari\bin\vantari.exe`, not the build output.
- **Proof:** clean exit code + no segfault on installed Windows.

### P1-9b: Locked-binary diagnostics
- **Contract:** operator scripts diagnose locked installed binaries and stale local processes before failing obscurely (AGENTS.md §XV).
- **Mechanism:** the installer and health probe detect a locked `vantari.exe` and report which process holds it.
- **Test:** manually lock the binary, run the installer, assert a clear diagnostic, not a cryptic failure.
- **Proof:** the diagnostic output is captured and matches the expected message.

### P1-9c: Cross-compile proof for Linux/macOS
- **Contract:** the same source cross-compiles to Linux/macOS with the same test suite (CGI via Zig cross-compilation).
- **Mechanism:** CI cross-compile step; the Windows-native suite remains the primary proof, cross-platform is a secondary target.
- **Test:** the backend suite passes on Linux/macOS via cross-compiled binaries.
- **Proof:** CI artifact for each target.

## North-star link
The sharded model is a runtime product. Its users are operators. Windows-native operators are the underserved segment — and a zero-dependency installed binary is the only way to serve them without a runtime dependency. The north star is meaningless if the harness cannot run on the operator's machine.

## Definition of done
- Installed binary exits cleanly on all commands.
- Locked binaries are diagnosed clearly.
- Cross-compile proof exists for Linux/macOS.