---
type: changelog
id: 054-ticket-quota-scheduler-policy
status: source-complete
roadmap_move: 63
---

# Move 63 — ticket, quota, and scheduler policy ownership

The policy audit retains one configured capacity key:
`agent_routes.max_concurrency`. It flows through the existing
`AgentService`/`Supervisor` pool and gates scheduler admission. Assignment stays
queue-only. The retired `tickets.auto_assign`, `tickets.proactive_workpool`,
`tickets.close_authority`, and `tickets.reopen_with_reasoning` keys remain
invalid. Lease TTL, heartbeat window, and dispatch burst remain private
scheduler protocol constants; specialist execution budgets remain owned by the
agent registry.

Proof:

- Debug: `19/19`, `2,154/2,154`.
- Source ReleaseFast build: `9/9`.
- Source SHA-256: `2530D80C6B8129960C131F85B9508896BBA332423EC64FD2506061770E5E042D`.
- Installed promotion deferred; live owner pair preserved.
