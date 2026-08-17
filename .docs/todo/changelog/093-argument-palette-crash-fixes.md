## 093 — Argument-aware model palette + model-first Settings tab + crash fixes from the live outage

- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `ec01f766` at `/usr/local/bin/vantari`

### Shipped

1. **Argument-aware model palette** (`tui_chat.zig`, `models_view.zig`) —
   typing `model` alone shows the command row; `model g` live-filters the
   catalog as palette rows (`glm-4.5 — zai`, …); `model o` shows opencode +
   openai entries; `model openco` narrows to opencode. Prefix match is
   case-insensitive on model id OR provider id; Enter commits the highlighted
   row through `providers/set-model` (cross-provider select included) and
   flips the footer; no-match renders a dim placeholder and Enter is inert.
   The earlier `model`+Space picker pivot is gone (regression-tested); bare
   `model` + Enter still opens the full-frame picker. One cached
   `models_view.Catalog` (fetchCatalog) serves palette, picker, and settings.
2. **Settings → Models is model-first** (`settings_view.zig`) — the tab opens
   on the flat catalog grouped by provider with active marker and context
   hints; Enter on a model opens the assign layer whose "current default"
   row names the exact `provider/model` it will write; agents follow;
   commit paths reuse `providers/set-model` / `agents/configure`. The old
   provider-first flow survives behind a `P` toggle (providers mode) for
   import and base-url viewing — selection never requires it.
3. **Honest provider-failure classification**
   (`providers/openai_compatible.zig`) — a non-JSON response body (e.g.
   Cloudflare's `error code: 1010`) no longer leaks Zig's
   `error.SyntaxError` as the turn failure; it maps to
   `MalformedHttpResponse`, and the 403 path keeps the full
   `BadStatus status=403 … body_prefix=…` diagnostic.

### Live-outage root causes found and fixed at the source

- **Third segfault (crash after first failed turn)**: `scanCurrentTurnTerminal`
  duped the terminal row's `detail` AFTER `defer terminal.deinit()` freed the
  parsed payload — the copy read freed memory. The first failed provider turn
  wrote the terminal row; the NEXT commit rescanned it and crashed the kernel
  child, leaving the owner serving 500s. Reproduced deterministically under a
  Debug build against a local 403 server (full stack captured); fixed by
  copying the detail while the payload is alive. Regression test uses the
  testing allocator's freed-memory poisoning to falsify a late copy.
- Same repro proves the fix: four consecutive failing turns return honest
  `BadStatus status=403 …` diagnostics and the owner stays healthy.

### Operator impact notes

- `api.opencode.ai` Cloudflare-blocks this host (HTTP 403, error 1010) — its
  models remain selectable but turns fail with the honest diagnostic until
  the gateway accepts the client.
- The blocked-model outage was resolved by restoring `zai` as the active
  provider (`glm-4.5`).

### Proof

- Debug gate: 19/19 steps, 2,285/2,289 passed, 4 skipped, 0 failed, 0 leaked
  (palette filter/navigation/commit/regression tests, settings catalog/assign/
  providers-mode tests, terminal-scan poison test, plain-text-body tests).
- Live PTY on installed `ec01f766`: bare `model` → command row; `model g` →
  glm rows; `model o` → opencode/openai; `model openco` → narrowed; Enter
  committed cross-provider with the `model: glm-4.5 → gemini-3-pro · opencode`
  row and ledger readback; model restored afterward.
