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

The temporary `Prism` provider-profile experiment was compiled and its pure
profile tests passed inside the full graph (`19/19`, `2,004/2,004`), but it was
not promotion-complete: the auth-to-config-to-route-to-dispatch-to-header path
and installed provider fixture were not closed. The partial live wiring remains
staged under the codename; the next promotion must carry an installed
request/header receipt before it enters the live path. See
`.docs/research/2026-08-13-provider-prism-staging.md`.
