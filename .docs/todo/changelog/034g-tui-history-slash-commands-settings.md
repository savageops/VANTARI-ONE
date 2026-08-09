---
id: 034g
title: "Terminal review + QC"
parent: 034
status: pending
priority: high
blast_radius: low
category: review
dependencies: [034a, 034b, 034c, 034d, 034e, 034f]
next_todo: NONE
source_message_anchor: leave-better
source_message_excerpt: "LEAVE THE CODE BETTER THAN YOU FOUND IT."
source_message_proof_obligation: Reviews the entire chain for capability truth, ownership boundaries, test pressure, code quality, and architectural improvement. Extends if defects found.
idempotency_contract: n/a — review-only slice.
---

## Execute Now

Review the complete TUI history + slash commands + settings panel chain as a ruthless senior maintainer. Verify capability truth (every feature works through its real consumer path), ownership boundaries (no parallel systems), test pressure (≥30 meaningful tests across the chain), and code quality. Fix defects by extending the chain if review proves additional work necessary.

## Review Criteria (QC 4/4)

### 1. Structure (maintainer-grade)
- [ ] `commands.zig` is a clean registry with no hidden coupling to `tui_chat.zig` internals beyond the `ChatState` pointer
- [ ] `settings_view.zig` is self-contained — its state, rendering, and key handling don't leak into the main event loop
- [ ] `history.zig` mirrors the `summaries.zig` pattern (same struct shape, same JSONL approach, same atomic write discipline)
- [ ] `config/file.zig` write function preserves the validation-before-write invariant
- [ ] No file exceeds its natural ownership boundary

### 2. Contract truth (capability completion)
- [ ] History persists across TUI restart (manual proof: send message, restart, press Up, see it)
- [ ] `/help` shows all registered commands grouped by category
- [ ] `/clear` resets the transcript
- [ ] `/exit` exits the TUI
- [ ] `/settings` opens the overlay; all 10 sections are navigable; inline editing writes config; Esc closes
- [ ] `/model`, `/effort`, `/persona` write config and apply on next turn
- [ ] `/agents` lists personas; enable/disable works
- [ ] Autocomplete renders on `/` prefix; Tab completes
- [ ] Ctrl+R enters reverse search
- [ ] `/search` finds history entries
- [ ] Config write is atomic — invalid write does not corrupt config.json

### 3. Test pressure (≥30 meaningful tests)
- [ ] history.zig: 6 tests
- [ ] commands.zig: 10+ tests
- [ ] config/file.zig write: 8 tests
- [ ] settings_view.zig: 10 tests
- [ ] integration (autocomplete, search): 8 tests
- [ ] Total ≥ 42 tests — exceeds the 30 floor

### 4. Code quality (anti-pattern sweep)
- [ ] No hardcoded string-equality command checks remain (the old `/exit` pattern is gone)
- [ ] No `TODO` or `FIXME` left in new code
- [ ] Every new function has a capability comment
- [ ] No parallel systems created (history uses the same JSONL+atomic-write pattern as sessions/summaries)
- [ ] No dead code (stub commands from 034b are replaced or removed)
- [ ] Naming is consistent (history, commands, settings_view — all snake_case modules)
- [ ] Error handling is explicit — no swallowed errors in the write path

## Patch Surface

**Reviews:**
- `src/core/sessions/history.zig`
- `src/clients/commands.zig`
- `src/clients/settings_view.zig`
- `src/clients/tui_chat.zig`
- `src/core/config/file.zig`
- `src/host/stdio_rpc.zig`
- `src/shared/protocol/types.zig`
- All new test files

## Exit State / Handoff Contract

- If review passes: chain terminates. Archive all units + parent. Update changelog.
- If review finds defects: create fix slice(s) `034h`, `034i`, etc. + new terminal re-review `034j`. Continue until clean.

## Validation

```bash
zig build test                          # full suite
zig build -Doptimize=ReleaseFast        # optimized build
# Install to LocalAppData
# Manual: /help, /settings, /model, Ctrl+R, restart + Up arrow
```
