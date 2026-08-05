---
id: 023e-agent-loop-contract-hardening
parent: 023-agent-loop-contract-hardening
protocol_version: "2.1"
category: refactor
status: done
phase: e
role: "Concurrent HTTP bridge"
depends_on: [023d-agent-loop-contract-hardening]
next_todo: /todo/pending/023f-agent-loop-contract-hardening.md
---
# 023e Concurrent HTTP Bridge

## Objective

Move HTTP connection processing out of the accept loop so long `/rpc` calls and `/events` waits do not serialize local bridge health checks and unrelated requests.

## Patch Surface

- `apps/backend/variant-1/src/host/http_bridge.zig`
- Optional focused tests if the local test harness can prove the accept-loop behavior without flaky timing.

## Contract

- `serve` keeps accepting after handing each connection to a detached worker.
- Connection lifecycle remains owned by exactly one handler.
- Bridge token, CORS, audit, redaction, and route behavior remain unchanged.

## Validation

- Full Zig suite compiles and passes.
- Code review confirms the accept loop no longer calls `handleConnection` inline.
