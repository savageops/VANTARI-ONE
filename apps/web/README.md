# Vantari Web

Web interface for the [Vantari](../backend) local agent kernel, served through
its browser bridge. Forked from an existing open-source chat UI and retrofitted onto
the Vantari runtime — chat, models, and provider state all cross the
token-gated, redacted browser lane; no other transport exists in this app.

## Architecture

```text
Browser ──GET /api/health──────────▶ Vantari owner (browser bridge)
        ◀── bridge_token handshake ──

        ──POST /rpc (x-vantari-bridge-token)──▶
              session/create · session/send · models/list · health/get

        ──GET /events?since=N&wait_ms=M──────▶
              assistant_delta → streamed chat chunks
              reasoning       → reasoning panel
              turn_terminal   → completion
```

`src/lib/services/vantari.service.ts` is the single translation owner: bridge
token lifecycle, JSON-RPC, event long-polling, and the mapping of Vantari
responses into the shapes this UI consumes — including an OpenAI-style SSE
synthesis for chat so the existing stream pipeline reads the kernel's event
lane unchanged.

## Development

```bash
npm install
npm run build          # production bundle in dist/
npx vite preview       # serve the built app
```

The bridge origin defaults to `http://127.0.0.1:18833`; override with
`VITE_VANTARI_BRIDGE` at build time. The owner must be running:

```bash
vantari serve --port 18833   # from the workspace root
```

## Layout

```text
src/lib/services/   API layer — vantari.service.ts is the bridge owner
src/lib/stores/     reactive state
src/lib/components/ UI components (chat, settings, dialogs, MCP)
src/routes/         SvelteKit routes
docs/               architecture and flow diagrams
```

Storage is namespaced under the `Vantari` prefix (localStorage keys and the
IndexedDB database) — a fresh namespace for this fork.
