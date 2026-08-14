---
type: changelog
id: release-build-seed-reproducibility
status: closed
updated: 2026-08-14
---

# Release build seed reproducibility

The release manifest exposed a proactive build-integrity gap: Zig's default
dependency traversal seed is random, so repeated ReleaseFast builds could
produce different bytes without source drift. The release owner now passes
`--seed 0` and records the seed in
`.docs/research/2026-08-14-roadmap-24-release-manifest.json`.

Two consecutive ReleaseFast builds produced the same source SHA-256:
`A7D01B37DBB3F954CF93F534CC04E9E662B86F34F19E4C2192EA302208515806`.
The current source/install manifest is `promotable`, with `19/19` release
steps, `2,184/2,184` tests, equal source/installed hashes, and zero preserved
installed-path processes after authenticated owner shutdown. Installed
provider/model-selector and settings proofs passed against this artifact.

This is a build determinism gate, not a repair or replay path. A future
artifact mismatch remains a failed promotion claim until the source, install,
and owner evidence are reconciled by their existing owners.
