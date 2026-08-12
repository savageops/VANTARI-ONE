---
type: extraction
date: 2026-08-12
source: user-message
status: applied
---

# Sequence-addressed agent mailbox

> “agents should be able to send messages to each other”
>
> “send grouped or directed notifications”
>
> “with tuning to vantari prompts, instructions, etc could get vantari harness
> to act like a multi context, context scaling into a hive model”

## Why

Independent session contexts scale reasoning only when agents can exchange the
small facts that affect one another. Copying every transcript into every agent
destroys that advantage. Centralizing every exchange through the root also
turns the orchestrator into a latency and context bottleneck.

## How to apply

- Keep every agent as a normal session. A session with delegated capacity may
  become a parent; do not add a second teammate runtime.
- Add one durable mailbox through the existing agent/session/event owners.
  Support direct-session, parent, and current-group targets. Do not build a
  generic IRC server, topic registry, or global shared transcript.
- Persist message ID, sender session, resolved recipient set, target group,
  bounded body, artifact or summary references, delivery sequence, and cursor.
  Delivery, retry, acknowledgement, and cold-start replay are kernel truth.
- Keep tickets as the only work lifecycle. A message informs or requests; it
  never silently assigns, claims, or launches work.
- Let the model choose when to send, inspect, challenge, wake, delegate, or
  remain quiet. Let the prompt envelope control communication density, update
  cadence, collaboration posture, and nesting. Reuse existing capacity, depth,
  and contact budgets.
- Provide bounded team awareness through agent inventory, status, canonical
  summaries, and artifact references. Demand-load detail. Never inject every
  sibling transcript into every context.
- Make completion one typed mailbox/event case, not a special second wake path.
  The same persistent owner must deliver ordinary information, terminal
  results, corrections, and follow-up work.
