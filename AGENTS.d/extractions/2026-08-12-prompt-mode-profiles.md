---
type: extraction
date: 2026-08-12
source: user-message
status: applied
---

# Prompt mode profiles

> “shift+tab changes between orchestrate, build, align, and plan mode”
>
> “these system instructions govern VANTARI's behavior, personality, work
> method, and TUI response styles”

## Why

One executor can support distinct work postures when the selected prompt layer
changes the model's method. A runtime branch per posture would duplicate
behavior policy and make personalization require code changes.

## How to apply

- Make `orchestrate`, `build`, `align`, and `plan` named prompt profiles.
  `orchestrate` is the default profile.
- Let Shift+Tab cycle the active session profile in the TUI. Show the profile in
  the compact metadata row. Apply it on the next prompt compilation without
  starting another executor or mutating tool capability.
- Keep profile content hot-loaded. The profile controls delegation, action
  bias, question cadence, planning posture, voice, and response density. The
  kernel continues to own capability truth, safety, durability, and evidence.
- In `align`, instruct the model to explore first and ask useful multiple-choice
  questions in bounded rounds. The requested 12–60 question range belongs in
  the profile prompt, not an executor counter or mandatory gate when the answer
  is already known.
- In `plan`, instruct the model to express the plan through the canonical ticket
  lifecycle. Do not add a second plan ledger.
- Persist stable preferences only through existing reviewed memory or
  instruction-writing tools. A mode switch alone has no hidden write side
  effect.
- Prove each profile by provider-visible prompt capture and paired behavior
  tests. The same input must change method without changing executor code or
  advertised capabilities.
