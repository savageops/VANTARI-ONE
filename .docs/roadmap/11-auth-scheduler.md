# 11 — Auth Chain & Scheduler

**Priority: P1**

## The seam

The active Codex subscription-auth chain and the scheduler are the highest-priority in-progress items. The scheduler shutdown segfault is the current top blocker for the whole pipeline. The auth chain is the gate to real-provider proof.

## What exists today

- **Auth:** `$VANTARI_HOME/auth.json` is the credential/provider ledger. Sibling config (`config.json`) for non-secret settings. One-time migration from legacy paths.
- **Scheduler:** `apps/backend/src/core/scheduler/store.zig` owns the scheduler state. Scheduler shutdown during `VAR1 --help health/tools` produces a segfault from the scheduler thread.
- **Codex subscription:** `apps/backend/src/core/auth/openai_codex.zig`, `clients/cli_auth.zig` — the active Codex subscription-auth chain is in-progress, dirty, not yet promoted.

## What the competitor does

- **Codex:** has a full subscription-auth chain with refresh, failure classification, and redaction.
- **Eve:** uses Vercel AI Gateway + provider API keys. No Codex subscription auth.
- **Claude Code:** uses Anthropic API keys with a built-in auth flow.

## Pipeline items under this theme

### P1-11a: Finish the Codex subscription-auth chain
- **Contract:** the Codex subscription-auth provider, resolver, CLI auth, and persistence seams are complete. Cold-start resolution, refresh failure classification, secret redaction, and installed-client behavior are proven.
- **Mechanism:** the worktree already owns the provider, resolver, CLI auth, and persistence seams. Close them.
- **Test:** cold-start resolution with a valid token; refresh failure with a typed event; secret redaction in logs.
- **Proof:** installed-client proof on Windows.

### P1-11b: Fix scheduler shutdown (blocking, carry from P0-4a)
- **Contract:** scheduler thread is drained and joined before process exit; no segfault.
- **Test:** `VAR1 health --json` and `VAR1 tools --json` exit cleanly.
- **Proof:** installed binary proof.

## Definition of done
- Codex auth chain is finished, tested, and installed-client proven.
- Scheduler shutdown is repaired and proven on Windows.