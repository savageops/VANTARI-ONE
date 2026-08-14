---
id: changelog/079-plugin-runtime-yagni-moves86-87
parent: roadmap/24-harness-capability-next-90
type: changelog
protocol_version: "3.0"
status: closed
category: architecture
acceptance: "Moves 86 and 87 close without dynamic plugin discovery or a plugin executor."
exit_criterion: "No mounted plugin consumer or live plugin JSON-RPC process exists; contract-only namespaces remain explicit."
validation: "rg owner census plus current backend build test --summary all"
expected_exit_code: 0
expected_output_pattern: "no plugin discovery/dispatch/process owner; 19/19 steps; 2180/2180 tests"
evidence: "Current source exposes manifest/isolation/socket contracts only; no plugin tool is model-visible and no plugin process is mounted."
dependencies: "roadmap/24-harness-capability-next-90 rows 40 and 84-85"
next_todo: "roadmap/24-harness-capability-next-90 row 88"
source_message: "Strip dead config, prompt duplication, branches, wrappers, registries, fallback paths, and shadow owners."
source_message_proof: "A future plugin must reuse the built-in definition, availability, review, process, receipt, capability, and cleanup owners."
---

# Moves 86–87 — delete speculative plugin runtime

The current checkout has no concrete plugin mount or user-facing plugin
consumer. Keep manifest, isolation, and socket contracts as contract-only
validation. Do not add discovery, a plugin registry, or a second JSON-RPC
executor. If a plugin is later mounted, route it through the existing tool
definition, availability, review, process, receipt, capability, and cleanup
owners.

Validation: current source owner census and `scripts/zigw.ps1 build test
--summary all` passed 19/19 build steps and 2180/2180 tests. No installed
promotion is claimed by this documentation-only deletion.
