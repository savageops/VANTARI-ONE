---
type: changelog-receipt
id: provider-credential-import-model-routing
status: closed
opened: 2026-08-14
closed: 2026-08-16
owner: core/auth + core/providers + host/stdio_rpc + clients (settings, tui, cli)
source: omp session 01a001ea-b4dd-7000-885e-2f25f09d07a5 (operator asks of 2026-08-14/15) + 2026-08-16 defect takeover
---

# Provider credential import, single-owner model routing, and the Settings → Models tab

**Outcome:** One provider namespace (`provider/model-name`) with a single-owner
credential ladder, explicit import of native Codex / Claude Code / OpenCode
credentials, per-agent provider/model overrides, and a cycle-to-lock Models tab
in Settings. Ledger mutations (`auth/import`, `auth use`,
`providers/set-model`, `agents/configure`) now apply on the next turn without a
kernel restart, and every models-tab status line reports the actual outcome.

## Shipped capability

- `auth detect` (CLI + `auth/detect` RPC): secret-free inventory of native
  `~/.codex/auth.json`, `~/.claude/.credentials.json`,
  `~/.local/share/opencode/auth.json`, and env API keys. Reports
  provenance, provider id, liveness, account hint — never a token.
- `auth import` (CLI + `auth/import` RPC): explicit, opt-in import into the
  auth ledger with `credential_source` provenance and a source-collision
  guard (refuses to clobber a record owned by another source without
  `--force`/`force`). Import is the only path a native refresh token crosses
  into VANTARI's store.
- `core/providers/router.zig`: the single owner turning a `provider/model`
  selector into a live credential (ledger record → env API key). Provider
  prefixes are the collision guard; a named provider without a resolvable
  credential is a hard route failure, never a silent active-provider
  fallback.
- Per-agent provider/model overrides (`agents/spec.zig`, `service.zig`,
  `routes.zig`): precedence agent > role route > active provider;
  `agents/list` + `agents/configure` RPCs mutate the registry owner.
- Five new RPC methods (`auth/detect`, `auth/import`, `providers/set-model`,
  `agents/list`, `agents/configure`) through the canonical stdio/owner
  dispatch; OpenCode provider family added to the profile table; bearer-OAuth
  imports (Claude Code) route through the shared transport at dispatch.
- Settings → Models tab (~930 lines): provider/model/assign layered pickers
  over the shared `Picker` engine, in-panel import for detected rows, and
  model assignment to the pulled provider or any agent. `/model` with no
  argument opens the tab; `/model <name>` sets the active provider's ledger
  model through `providers/set-model` — the argument is never silently
  discarded.
- `core/tools/process.zig`: persistent-reader teardown no longer reattaches
  or re-closes a pipe `terminateChild` already closed (double-free fix with
  regression test).

## Defect fixes taken over from the interrupted 2026-08-15 audit

The prior session's audit enumerated defects and was cut off before any fix.
All were re-verified against source and fixed:

1. `session/send` only refreshed credentials for an explicit non-active
   provider; `providers/set-model`, `auth/import`, and `auth use` never
   applied until restart while the TUI claimed "applies on next turn". Fixed:
   an explicit provider is always an explicit ledger read; with no explicit
   provider, `refreshActiveAuthFromLedger` (one shared owner) re-resolves the
   ledger's active provider each turn; env-configured workspaces without a
   ledger keep the startup snapshot.
2. `models/list` compared the request against the startup snapshot's active
   provider, so after an import a bare request targeted the wrong provider.
   Fixed: bare requests resolve the ledger's active provider through the same
   refresh owner.
3. Section transitions were duplicated between the generic handler and the
   models overlay. Fixed: one `changeSection` owner loads the destination
   surface (models → `loadModels`, others → `loadSection`) on every keyboard
   path.
4. Three `models.status_message = null` sites leaked the previous heap
   message. Fixed: `ModelsState.clearStatus` frees on every transition.
5. Assign target 0 was labeled with the active provider but committed the
   pulled-from provider. Fixed: the row names the provider the commit writes;
   "(active provider)" appears only when they are identical; the success
   message names provider and model.
6. `/model <name>` silently discarded its argument. Fixed: typed argument
   routes through `providers/set-model` on the ledger's active provider with
   honest error/status messages.
7. Import reported "Imported." even when the collision guard skipped
   everything. Fixed: the status reports imported vs skipped counts and the
   force path.
8. Models-tab prints used the default `.grapheme` wrap; long labels wrapped
   onto subsequent picker rows. Fixed: every models print is single-line
   (`.wrap = .none`).

## Proof

- Full Debug gate through `scripts/zigw.sh build test --summary all`:
  `19/19` steps, `2,223/2,227` tests passed, 4 platform-conditional skips,
  zero failures. New regression probes cover every fix: ledger-active
  resolution for `models/list` (dispatch-level, offline), snapshot fallback
  without a ledger, explicit-provider-equals-active failing closed as
  `ProviderNotFound`, tab-into-models loading, status-transition leak
  freedom, assign-row labeling, and skipped-import honesty.
- Source ReleaseFast: `9/9` at SHA-256
  `217240A0050B07579A3B31B8A52B95E182532A83376DF942BFE25D5C6EC86663`.
- Installed deployment (this Linux workstation): staged rename replaced
  `/usr/local/bin/vantari` (prior binary retained as
  `vantari.bak.20260816-145054`); installed hash equals the source
  ReleaseFast hash; the execution owner restarted on the new generation
  `6d030efe1845470443d3646f85c5e57a` with the clicloud workspace owner left
  untouched. Installed probes: `health --json` ok, secret-free
  `auth detect --json` (live codex, expired claude, live opencode rows),
  `auth status --json`, and a live `models/list` through the owner RPC
  returning the real Z.AI catalog with `status:"ok"`.
- The prior deployment (`bec8b47b…`, 2026-08-15) was a Debug build of this
  same source graph before the defect fixes; it is superseded.

## Boundary

- Import copies tokens; it does not implement refresh flows for Anthropic or
  OpenCode. Codex keeps its existing refresh owner. Claude imports carry the
  native `expiresAt`; after expiry the operator re-imports or waits for a
  future refresh owner — that residual remains open in `workspace.json`.
- A live provider turn was not re-run for this receipt (operator quota had
  just hit a provider 429 window); turn-path application of the refresh is
  covered by the dispatch-level regression and the shared-owner call shape,
  not by a spent token.
- Windows-native installed promotion of this chain remains unclaimed; the
  Linux workstation deployment above is the only installed proof.
