# Ventari Session Workbench

Framework-free browser workbench for the `VAR1` bridge.

This folder is the browser operator surface for starting, inspecting, and continuing agent sessions. It sends session RPC calls to `VAR1 serve`, renders bridge events, and leaves storage, context, tools, and provider calls inside the Zig kernel.

## What it does

- Connects to a running local `VAR1` HTTP bridge.
- Creates, resumes, sends to, lists, and reads sessions through canonical RPC methods.
- Displays session progress, messages, events, and final output from token-gated bridge snapshots.
- Runs as static HTML, CSS, and JavaScript with no package install step.

## Quick start

From `apps/backend`, start the bridge:

```powershell
.\zig-out\bin\VAR1.exe serve --host 127.0.0.1 --port 4310
```

Serve this folder from an explicit local HTTP origin, then set the bridge URL to `http://127.0.0.1:4310`.

```powershell
python -m http.server 5173 --bind 127.0.0.1
```

Open `http://127.0.0.1:5173`. Direct `file://` opens are intentionally unsupported because the backend rejects `Origin: null`.

## Runtime contract

- `POST /rpc`
- `GET /events`
- `GET /api/health`

`GET /api/health` is the startup handshake. The bridge returns readiness plus a per-process `bridge_token`; the client sends that value as `X-VAR1-Bridge-Token` on `POST /rpc` and `GET /events`.

The client talks to the bridge through the canonical session RPC methods:

- `initialize`
- `session/create`
- `session/send`
- `session/get`
- `session/list`

## Session flow

1. Confirm bridge health through `GET /api/health` and store the returned bridge token.
2. Start or select a session.
3. Send prompts through `session/send`.
4. Read progress from token-authenticated `GET /events` and hydrate details through `session/get`.

## Boundary

The client does not read `.var/`, construct provider messages, execute tools, or persist transcript state. Those responsibilities belong to `apps/backend`. The backend bridge remains local by default and rejects unapproved browser origins before session-mutating RPC is forwarded.
