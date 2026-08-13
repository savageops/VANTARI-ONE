---
type: extraction
date: 2026-08-13
source: user-message
status: staged
---

# Codename provider promotion

> “make sure no rewriting of code, copy the compoetitors files, then remold
> them for our purposes”
>
> “you can brong them in under codenames, and then promote them when ready”

## Why

Provider and authentication changes cross several live owners. A codename
staging slice gives the harvest a reviewable identity and a failing tracer
before the mechanism enters the runtime. Promotion must leave one canonical
owner, not a permanent shadow adapter.

## How to apply

- Harvest the load-bearing interfaces and state transitions from named
  references before originating local glue. Preserve provenance in the staged
  module comment and research record.
- Give the staged mechanism a codename, add its falsifying tests, and keep it
  outside the live dispatch path until the tracer proves the intended contract.
- Promote by moving the tested mechanism into the existing canonical owner;
  remove the codename copy in the same change. Do not create a provider
  registry, second credential ledger, or parallel executor.
- Preserve unrelated shared-worktree changes. If another active task owns the
  consumer surface, finish the provider seam and report the exact handoff
  rather than rewriting that surface.

## Current receipt — 2026-08-13

The temporary `Prism` provider-profile experiment was compiled, falsified, and
promoted into `apps/backend/src/core/providers/profile.zig`. The full graph
passes (`19/19`, `2,007/2,007`), and the auth-to-config-to-route-to-dispatch-
to-header path has an installed provider fixture receipt. The codename is
retained here as provenance only; no shadow adapter remains in the live path.
See `.docs/research/2026-08-13-provider-prism-staging.md` and
`.docs/todo/changelog/037-provider-selection-prism.md`.
