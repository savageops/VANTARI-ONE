## 092 — Model-first selection: picker overlay + any-model current default

- **Date**: 2026-08-17
- **Deployed**: ReleaseFast `c1d9bc26` at `/usr/local/bin/vantari`

### Shipped

1. **`models/list-all` RPC** (`host/stdio_rpc.zig::handleModelsListAll`)
   — one call returns every credentialed provider's catalog:
   `{schema:"var1.models_all.v1", active_provider, active_model,
   providers:[{provider_id, base_url, status, error_message, models[]}]}`.
   Active provider group sorts first; per-group discovery/read failures
   degrade to `status:"unreachable"` without failing the call. Every string
   is allocator-owned: model ids/owners are duped out of each iteration's
   discovery result and freed after render (the per-iteration `discovered`
   deinit made borrowing them a use-after-free).
2. **`providers/set-model` cross-provider semantics** — same params; when the
   requested provider differs from the active one, the handler also selects
   it through `auth_store.selectProvider`, so picking a model from another
   provider IS switching: one action, `{provider, model}` becomes the active
   pair. Response carries `active_provider`.
3. **Model picker overlay** (`clients/models_view.zig`) — full-frame overlay:
   flat catalog grouped under provider headers (`zai (base_url)` etc.),
   active model marked `▸`, context-window hints, type-to-filter across
   model+provider ids, ↑/↓ cursor, Enter commits, Esc cancels. Vaxis-borrowed
   text stays State- or frame-owned through the render boundary.
4. **Palette Space pivot** (`clients/tui_chat.zig`) — typing `model` then
   Space opens the picker (composer cleared, palette dismissed); other
   commands keep the existing whitespace-dismiss behavior. Bare `model`
   (palette Enter or `/model`) opens the picker instead of pinning the
   settings Models tab; `/model <id>` keeps direct-set and now also flips
   `state.model` + footer immediately. Commit path updates `state.model`,
   bumps the footer revision, and appends one bounded
   `model: <old> → <new> · provider <id>` system row. Picker owns keys in
   both the idle and during-turn loops.

Per-agent model overrides remain in Settings → Models (assign layer) and
`agents/configure`; the picker is the current-default surface.

### Proof

- Debug gate: 19/19 steps, 2,263/2,267 passed, 4 skipped, 0 failed, 0 leaked
  (aggregation/sorting, cross- and same-provider set-model round-trips,
  picker parse/filter/navigation/commit, palette pivot, footer flip).
- Live PTY on installed `c1d9bc26`: `model` + Space opened the picker with
  329 models grouped under 5 provider headers; Enter committed a different
  model; ledger readback showed the new active pair
  (`zai → glm-4.7`, restored to `glm-5.3` after the proof); the set-model
  response carries `active_provider`.
