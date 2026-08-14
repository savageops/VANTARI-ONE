---
type: changelog
id: 056-native-tool-schema-prompt-boundary
status: completed
---

# 056 — Native tool schema prompt boundary

Move 65 is source-complete. The provider request's native tool schemas are now
the model-facing API; the prompt builder no longer embeds the full human catalog
with duplicate examples, review metadata, and availability text.

The existing hot-loaded system/developer/persona/guardrail/user-context and
session-local mode layers remain the behavior owner. Skill routing remains a
bounded capsule with `skill_info` demand loading. Explicit catalog/JSON
diagnostics remain available through their existing operator surfaces.

Proof: Debug `19/19` build steps and `2,150/2,150` tests passed; source
ReleaseFast `9/9`; source SHA-256
`702DD2CB1A067246E82D8670F0F33FD322FD4178C271AF11E712A110151783D3`.
Installed promotion remains deferred.
