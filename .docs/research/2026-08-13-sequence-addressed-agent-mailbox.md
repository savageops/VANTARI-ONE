---
type: research
id: research/sequence-addressed-agent-mailbox
status: accepted
date: 2026-08-13
owner: apps/backend/src/core/agents/mailbox.zig
roadmap_move: 26
---

# Sequence-addressed agent mailbox

## Problem

VANTARI agents are normal sessions with independent context. They can report a
terminal result through parent convergence, but they cannot exchange a bounded
fact while work is live. Copying sibling transcripts would erase the context
scaling benefit. Adding a broker, topic registry, or second inbox ledger would
create a parallel runtime owner.

Move 26 needs one durable information path. A message is evidence. It does not
assign a ticket, claim work, launch a session, or grant authority.

## Current owner map

- `sessions/store.zig` owns append-only `events.jsonl`, exact per-session event
  sequence, valid-prefix replay, and durability flushes.
- `types.SessionRecord.parent_session_id` owns the parent edge.
- `types.ExecutionReceiptView.group_id` and `parent_session_id` own immutable
  current-group membership.
- `executor/loop.zig` owns provider-bound context and safe step boundaries.
- `tools/runtime.zig` owns catalog, profile filtering, review, and dispatch.
- `agents/service.zig` and `agents/supervisor.zig` own live agent notification.

No new runtime-state file, process, service, registry, transcript role, or
config key is required. One code owner is added for the event-spine protocol.

## Harvest

| Reference | Strong invariant | Reject |
|---|---|---|
| [OpenAI Codex multi-agent messaging](https://github.com/openai/codex/tree/main/codex-rs/core/src/tools/handlers/multi_agents_v2) | One shared delivery primitive distinguishes queue-only from turn-triggering follow-up. Completion uses the same inter-agent control shape. | Live manager state without a durable per-recipient replay cursor. |
| [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) | Independent contexts, direct messages, automatic teammate delivery, and team awareness remain available to restricted teammates. | Broadcast-by-loop, task-list coupling, and documented resume/shutdown gaps. |
| [AutoGen Core communication](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/framework/message-and-communication.html) | Messages are serializable data; direct and publish/subscribe semantics are explicit. | Topic subscriptions, handler registries, and a second agent runtime. |
| [LangGraph multi-agent systems](https://langchain-ai.github.io/langgraph/concepts/multi_agent/) | Selective handoff and state channels beat universal context sharing. | Shared message-state reducers and graph ownership for a capability already owned by VAR1 sessions. |
| [Google ADK multi-agent systems](https://google.github.io/adk-docs/agents/multi-agents/) | Branch isolation protects context and makes parent aggregation explicit. | Leaf-only agents and no peer exchange. |
| [Strands Swarm](https://strandsagents.com/latest/documentation/docs/user-guide/concepts/multi-agent/swarm/) | Handoffs need bounded steps and time. | Full shared task history across every agent. |
| [OpenAI Agents SDK orchestration](https://openai.github.io/openai-agents-python/multi_agent/) | Manager and handoff patterns are both valid; input filters can narrow transferred context. | Full-history handoff as the default and no durable peer mailbox. |
| [CrewAI collaboration](https://docs.crewai.com/en/concepts/collaboration) | The model chooses when collaboration is useful. | Generic coworker delegation tools without event-ledger delivery proof. |

Local pressure checks also covered `pi-collaborating-agents`, `pi-intercom`,
Scion, and NullClaw. Their useful mechanisms are stable message IDs, queue vs
urgent intent, bounded disconnected mail, reply metadata, and watched delivery.
Their rejected surfaces are global feeds, filesystem inbox registries, blocking
ask/reply RPC, broker-only durability, and process-local queues.

## Decision

Add `core/agents/mailbox.zig` as a projection over existing session events.
Expose one `send_agent_message` tool.

### Targets

- `direct`: require an exact session ID in the sender's session tree.
- `parent`: resolve `SessionRecord.parent_session_id`.
- `current_group`: resolve the sender's immutable execution receipt and deliver
  to its sibling sessions, excluding the sender. Parent delivery stays explicit.

Reject self-delivery, missing sessions, cross-tree delivery, root-to-parent,
and an empty current group before any append.

### Intent

- `queue`: persist now; expose on the recipient's next run or when another wake
  causes the mailbox to drain.
- `wake`: persist now; request the next safe provider boundary in an already
  running recipient. Never interrupt a provider/tool call and never start an
  idle session.

The model chooses target, intent, content, and cadence. Prompt profiles tune
that choice. Kernel logic only validates scope, bounds, identity, sequence, and
durability.

### Event grammar

```text
sender tool call
  -> agent_message_received on each resolved recipient events.jsonl
  -> agent_message_sent receipt on sender events.jsonl
  -> bounded system context segment at a recipient step boundary
  -> agent_mailbox_cursor after successful provider observation
```

`agent_message_received.message` uses `var1.agent_message.v1` and stores the
message ID, sender session, target, current group when present, recipient,
queue/wake intent, bounded body, bounded references, and send time. The outer
event `seq` is the recipient delivery sequence.

`agent_message_sent.message` stores the immutable request fingerprint and every
resolved recipient with its delivery sequence. This is the durable delivery
receipt. A replay of the same tool-call identity fills missing recipient events
and returns the same receipt; conflicting content fails.

`agent_mailbox_cursor.message` stores the highest contiguous delivery sequence
observed by a successful provider turn. The transcript remains unchanged.

### Fixed bounds

- Body: 4 KiB.
- References: 8 entries, 512 bytes each.
- Resolved recipients: 64.
- One context batch: 16 messages and 16 KiB rendered text.

These are transport and context safety limits, not behavior controls. Do not
add config keys until measured workloads prove a different bound.

### Context semantics

Render mailbox data as one system runtime segment after the canonical context
compiler output. Mark it as collaboration input, not authority. Never append it
to `messages.jsonl` and never import a sender transcript.

At run start, drain the oldest unread prefix. During a run, queue-only mail
waits. If any unread wake exists, drain the contiguous unread prefix so a
scalar cursor cannot skip an earlier queued message. A successful provider
response advances the cursor. Provider failure leaves the cursor unchanged for
cold replay.

## Rejected surface

- No IRC server, broker, daemon, socket, topic, channel, feed, or global chat.
- No `ask`, `reply`, `thread`, `broadcast`, reservation, or blocking request API.
- No shared task list or alternate work lifecycle. Tickets remain canonical.
- No sibling transcript, hidden context merge, or `agent` transcript role.
- No auto-launch, auto-claim, provider interruption, or permission transfer.
- No message-policy config. Prompts control communication behavior.

## Method gates

Harvest reflex: passed with twelve current/local implementations and eight
primary source families above.

Sprout Method: keep one seed (`send_agent_message`), plant it in the existing
event owner, and make direct/parent/group all call the same primitive. Do not
add reply, feed, broker, or arbitrary-group branches before use proves them.

Tracer code: required because the change crosses tool, session, context, and
live-notification boundaries. Write failing tracers before production code.

## Tracer proof

1. Direct, parent, sibling-group, and nested-parent resolution use durable
   session/receipt edges.
2. Cross-tree, self, empty-group, malformed, and over-budget sends append zero
   events.
3. Each recipient receives one exact event sequence and the sender receipt
   lists the same sequence.
4. Replaying one tool-call identity creates no duplicate delivery.
5. Queue mail waits during an active run; wake mail reaches the next safe step.
6. Provider failure replays unread mail; provider success advances the durable
   cursor.
7. Mail context is bounded, ordered, and absent from `messages.jsonl`.
8. Restarted readers reconstruct the same unread projection from events alone.

## Boundary

Move 26 proves durable at-least-once observation and idempotence for one tool
call. Move 29 adds owner generation, heartbeat/expiry, and exactly-once
resume-or-requeue reconciliation across process failure. Move 30 proves the
installed Windows lifecycle, including detach, kill, restart, and nested mail.
