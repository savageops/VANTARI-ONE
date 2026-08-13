---
id: 042
parent: harness-capability-next-90
type: execution-unit
protocol_version: "3.0"
title: Definition-owned capability manifest
category: capability
status: done
priority: high
created: 2026-08-13
next_todo: Move 56 — persistent Python eval kernel
source_message_anchor: "harness-capability-next-90-move55"
source_message_excerpt: "Generate the model-visible capability manifest from module definitions plus live dependency probes."
source_message_proof_obligation: "The selected definition must be the single source for schema, availability, review, and dispatch metadata; the installed catalog must reflect live dependency state."
acceptance: "Remove the duplicate availability table, preserve compatibility callers, fail closed when ix is unavailable, and prove the installed tools catalog."
exit_criterion: "Canonical Debug, focused TUI, ReleaseFast/install, source-installed hash equality, installed tools JSON, and exact proof-owned process teardown all pass."
validation: "apps/backend/.\\scripts\\zigw.ps1 build test --summary all; apps/backend/.\\scripts\\install_windows.ps1; installed tools --json; exact installed-process census"
expected_exit_code: 0
expected_output_pattern: "19/19 steps succeeded; 2102/2102 tests passed|tools --json search_files=available dependency=ix|source=installed|installed_processes=0"
evidence: ".docs/research/2026-08-13-capability-manifest-move55.md; source/installed SHA-256 F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692; test-tui 120/120; tools catalog 25 entries; final installed process census zero."
dependencies: [Move 50, Move 53, Move 54]
---

# Definition-owned capability manifest

## Change

- Added `AvailabilitySpec` to the shared `ToolDefinition` contract with a no-dependency default.
- Kept `module.zig` as the compatibility re-export for dependency types.
- Co-located the `search_files -> ix` dependency on `search_files.definition`.
- Removed the 15-entry name-keyed `availability_entries` table from `core/tools/registry.zig`.
- Passed the selected definition through availability resolution, catalog rendering, and search dispatch.
- Kept the legacy `availabilitySpec(name)` helper as a thin definition scan for existing callers; runtime paths do not use it.

## Proof

- Focused TUI: `9/9` steps; `120/120` tests passed.
- Full Debug: `19/19` steps; `2,102/2,102` tests passed.
- Negative probe: an unavailable `ix` command marks `search_files` unavailable while native `list_files` remains available.
- ReleaseFast/install: source and installed `vantari.exe` SHA-256 both equal `F5C78C9D1E2198015F1DA461CCDD6DEC0039EA62002B4F2B2A8BF69182E2B692`.
- Installed `tools --json`: 25 tools; `search_files` reports dependency `ix` and `available`.
- Exact installed `execution-owner`/`kernel-stdio` PIDs were stopped after the probe; final process census was zero.

## Boundary

This is a contract-owner correction. It does not add a generated manifest file, dynamic registry, plugin loader, or prompt behavior branch. Move 56 remains the next runtime frontier.
