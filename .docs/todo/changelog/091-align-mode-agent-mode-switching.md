## 091 — Align-mode extraction lens, agent-driven mode switching, single-question TUI

- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `b7b8d083` at `/usr/local/bin/vantari`

### Shipped

1. **Single-question TUI modal** (`clients/question_view.zig`) — the question
   projection now shows exactly one question at a time: full-context prompt
   (grapheme-wrapped, never column-truncated), options stacked vertically one
   per row with indented dim description rows, Ctrl+Q/Ctrl+E wrap-cycle
   questions (settings-section semantics, never entering review), Up/Down
   move the option cursor, Tab advances into the review/submit state.
   Response serialization is byte-compatible.
2. **Align extraction lens** (`core/prompts/builder.zig`) — the align
   instruction now names the goal explicitly: extract the operator's intent,
   idea, thought process, and constraints; ask through `ask_user` in bounded
   rounds; distill a PROFILE (goals/constraints/preferences/environment/
   definition of done) and KEYWORDS (the operator's exact vocabulary); state
   them back for correction; hand off via `set_prompt_mode` (align → plan →
   build/orchestrate); no irreversible execution from align.
3. **Agent-driven mode switching** (kernel slice) —
   - `SessionRecord.prompt_mode` (?[]const u8) is the durable owner of the
     active label; `store.setSessionPromptMode` is the mutator.
   - `session/send`: explicit label validates AND persists; omitted label
     follows the stored record (orchestrate fallback only for fresh sessions).
   - New root tool `builtin/set_prompt_mode.zig` (all four modes; headless
     children fail `ToolUnavailable`; unknown label fails `InvalidArguments`
     before effects; reason bounded to 240 bytes) → host `PromptModeService`
     → durable write → `var1.prompt_mode_changed.v1` event (from/to/reason).
   - `core/executor/loop.zig` reconciles `active_prompt_mode` +
     `orchestrator_only` from the durable record after each tool batch, so
     the next provider call in the SAME run uses the new lens. Provider/model
     routing stays as resolved at send time.
   - TUI projects the event: footer label flips + one bounded system row
     `mode: <from> → <to> — <reason>`, idempotent under seq replay.

### Bugs found by the live proof and fixed at the source

- **Use-after-free (segfault, twice reproduced live)**: `onPromptModeSet`
  held `old_label` across `setSessionPromptMode`, which frees the stored
  label — the serializer then read freed memory; Debug tests survived
  (pages still mapped), the long-lived ReleaseFast owner crashed at a page
  boundary (dmesg, same IP both runs). Fix: the mutator now returns the
  previous label as freshly owned memory (`!?[]u8`), making the alias
  impossible by construction; regression test asserts slice independence.
- **Stale-record clobber**: `commitTurnTerminal` → `setSessionStatus` wrote
  the WHOLE record from the run's send-time struct, reverting the mid-run
  `prompt_mode` switch on cancellation. Fix: `setSessionStatus`,
  `setSessionFailure`, and `setSessionPromptMode` are now field-surgical
  (read current, mutate own fields, write) while still mirroring their
  fields onto the caller struct — the whole class of concurrent-field
  reverts is closed, not just prompt_mode.
- **Footer cache staleness**: the footer meta dirty key omitted
  `prompt_mode`, so Shift+Tab cycling and the mode-change event rendered a
  stale label. Fix: both mutations bump the existing
  `footer_telemetry_revision`.

### Proof

- Debug gate: 19/19 steps, 2,258/2,262 passed, 4 skipped, 0 failed, 0 leaked
  (24 new tests across question view, lens containment, tool fake-service
  harness, send omission fallback, mutator independence).
- Live PTY end-to-end on the installed binary (`b7b8d083`, owner restarted
  onto it): align footer after Shift+Tab ✓, agent-driven `ask_user` modal ✓,
  single-question render ✓, Ctrl+E/Ctrl+Q cycling ✓, review+submit ✓,
  `prompt_mode_changed` event with agent-authored reason in the ledger ✓,
  visible `mode: align → plan` transcript row + footer flip ✓, and the mode
  survives cancellation in `session.json` ✓. No new segfaults in dmesg.
