---
type: changelog
id: changelog/049-question-panel-consumer-hardening
status: source-complete
date: 2026-08-14
owner: apps/backend/src/clients/question_view.zig
---

# Question panel consumer hardening

## Shipped in source

- The existing settings-style question panel now sanitizes untrusted prompt,
  label, and summary text for the Vaxis display projection. Invalid UTF-8 and
  ASCII control characters cannot cross the frame boundary as render text.
- Display option keys are static `a`–`f` values while original model option ids
  remain intact in the `input/respond` response.
- Header, divider, row, and review rendering are guarded by the actual viewport
  height. Normal and review states remain safe at clipped terminal heights.
- The same controller remains shared by `orchestrate` and `align`; no second
  question protocol or TUI overlay was added.

## Evidence and boundary

- Focused TUI: `131/131` tests passed.
- Full Debug: `19/19` steps, `2,144/2,144` tests passed.
- Source ReleaseFast: exit `0`; SHA-256
  `7CD32F0D445F96E411EE8B35308A40CF08077BDE3703855525E446667799B3BB`.
- Installed promotion and provider-driven installed response remain deferred by
  the explicit operator boundary. Research:
  `.docs/research/2026-08-14-question-panel-consumer-hardening.md`.
