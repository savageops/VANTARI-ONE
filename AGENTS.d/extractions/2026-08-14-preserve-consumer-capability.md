---
type: extraction
id: preserve-consumer-capability
status: applied
version: 1.0.0
---

# Preserve consumer capability

- Treat a real consumer-facing capability as preserved scope during subtractive work.
- Clean or consolidate its owner before considering removal.
- Delete only dead, duplicate, internal-only, or actively harmful complexity after an explicit consumer-path check.
- Record the capability preserved, owner simplified, and proof boundary for each deletion.
