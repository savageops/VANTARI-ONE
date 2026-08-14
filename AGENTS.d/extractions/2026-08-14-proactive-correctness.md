---
type: extraction
id: proactive-correctness
status: applied
version: 1.0.0
---

# Proactive correctness

Prevent failure in the canonical owner before adding a reactive recovery
control plane. Test the real provider, tool, process, storage, installed, and
consumer paths until the invariant is durable. Do not add repair, replay,
fallback, evaluator, rollback, or alternate-owner code for a failure that
should be prevented or made explicit at its existing boundary.

Retain only bounded compiler projection repair that is required to construct a
valid model view from an append-only transcript. Any future recovery mechanism
must earn one measured failure class, one owner, one operator consumer, and
durable proof before it is admitted.
