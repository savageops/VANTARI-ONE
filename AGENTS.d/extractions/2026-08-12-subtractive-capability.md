---
type: extraction
date: 2026-08-12
source: user-message
status: applied
---

# Subtractive capability

> “ensuring at all times YAGNI. Less is more. if we dont need it, strip it.”
>
> “simplification isnt the downgrade type, its the ‘this is uneccessarilly complex’ type of simplification”

## Why

Unused abstractions, policy branches, registries, and config keys create loose
ends. They reduce autonomous reliability. Remove accidental complexity. Keep
or increase executable capability.

## How to apply

- Evaluate each numbered move as add, merge, or delete. Close every move with
  proof. A closed move does not always add code.
- Name the user capability and runtime cost center first. Add a mechanism only
  when the current owner cannot solve the need in its present form.
- Prefer deletion, one owner, and direct typed state transitions. Avoid
  wrappers, factories, policy engines, registries, and compatibility branches.
- Remove dead config, prompt duplication, shadow owners, fallback readers, and
  tests that prove removed paths.
- Prove that each deletion preserves the canonical consumer path. Do not call a
  capability reduction simplification.
