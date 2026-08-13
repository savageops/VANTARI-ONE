---
type: research
id: model-selected-agent-eligibility
status: accepted
date: 2026-08-13
roadmap_move: 27
---

# Model-selected agent eligibility

## Problem

Before Move 27, `agents {}` rendered configured agent definitions from
`apps/backend/src/core/agents/spec.zig`. It does not prove that a route resolves,
show current parent-team state, expose fixed-pool pressure, or bind the result to
a deterministic receipt. At the same time,
`apps/backend/src/core/prompts/builder.zig` carries an always-on instruction to
fan out immediately. This mixes prompt posture with executable eligibility and
prevents a user prompt from choosing a quiet or single-owner posture.

## Reference pressure

| Reference | Retain | Reject |
|---|---|---|
| [Codex subagents](https://developers.openai.com/codex/multi-agent) | Prompt and agent descriptions choose delegation; runtime exposes active/done state and caps concurrency. | Client-specific thread UI and configuration layering as a second runtime owner. |
| [Claude Code agent teams](https://code.claude.com/docs/en/agent-teams) | Independent contexts, direct mailbox delivery, compact task/team awareness, and explicit coordination cost. | Shared task-file ownership, no nesting, and full teammate session inspection as a model-context default. |
| [OpenAI Agents SDK orchestration](https://openai.github.io/openai-agents-python/multi_agent/) | Let the LLM choose orchestration; represent dynamically enabled destinations as tools. | Python orchestration callbacks and handoff object layers around the existing VAR1 session primitive. |
| [Google ADK collaboration](https://adk.dev/workflows/collaboration/) | Candidate subagents become model-visible delegation choices; parallel branches keep isolated context and return bounded results. | Code-owned chat/task/single-turn behavior modes and leaf-only nesting limits. |
| [AutoGen selector teams](https://microsoft.github.io/autogen/stable/user-guide/agentchat-user-guide/selector-group-chat.html) | Give the model concise participant names and descriptions after a deterministic candidate filter. | A second selector model call, broadcast history, and group-chat manager loop. |
| [Strands Swarm](https://strandsagents.com/docs/user-guide/concepts/multi-agent/swarm/) | Show available specialists, handoff state, and explicit step/time bounds so agents can choose collaboration. | Mutable shared working memory, full shared history, and process-local swarm ownership. |
| [LangGraph multi-agent patterns](https://langchain-ai.github.io/langgraph/tutorials/multi_agent/multi-agent-collaboration/) | Keep the manager on requirements and synthesis; return only the child result needed by the caller. | Graph nodes, reducers, routing edges, and duplicated durable state. |
| [Pi agent queues](https://github.com/badlogic/pi-mono/tree/main/packages/agent) | Distinguish an interrupting steer from a deferred follow-up and preserve queue order. | A transcript-owned in-memory queue; VAR1 already owns durable queue/wake delivery in `events.jsonl`. |

## Harvested invariant

Expose one compact, deterministic set of choices to the current model. Include
only route-resolvable specialists and enough live state to choose whether to
work solo, launch now, accept queueing, inspect detail, message, challenge, or
wake. Keep full child transcripts private. Revalidate every launch and message
at the existing side-effect boundary; discovery is evidence, not a capability
token.

## Sprout Method

Use the existing `agents {}` tool and the existing `AgentService` owner:

1. `AgentService` hot-loads the registry, resolves each route, reads one
   supervisor capacity snapshot, and reads one non-blocking parent-team
   snapshot.
2. `spec.zig` renders sorted eligible specialist rows into canonical JSON.
3. The service hashes the canonical payload and returns
   `var1.agent_eligibility.v1` with a SHA-256 receipt.
4. `launch_agent` keeps its current immediate scope, route, depth, contact, and
   capacity revalidation. The model does not echo the receipt.
5. `configure_agent` invalidates the prior eligibility ledger; the next agent
   action requires a fresh `agents {}` snapshot.
6. `list_agents` remains demand-loaded detail; no second registry, team bus,
   scheduler, selector model, or transcript projection is added.

The snapshot contains only:

- eligible specialist id, `when_to_use`, execution kind, route role,
  capability profile, provider/model, and effort;
- unavailable specialist id plus a stable failure class;
- parent-team aggregate and fixed-pool aggregate;
- current depth and default contact bounds;
- available communication targets and delivery modes (`queue`, `wake`);
- a receipt over the sorted payload.

## Tracer code

Before implementation, add deterministic tests that fail unless:

1. identical registry, route, parent-team, capacity, depth, and contact state
   produce byte-identical payloads and receipts;
2. an unavailable route is excluded with a stable failure class;
3. zero remaining depth exposes no launch-eligible specialist;
4. capacity saturation remains visible as queue pressure without inventing a
   second admission path;
5. a quiet prompt and an orchestration prompt compile through the same executor
   path while selecting different allowed actions in captured model output;
6. the prompt says that inspect, message, challenge, queue, wake, delegation,
   and quiet are model choices rather than mandatory branches.

## Landed mechanism and proof

- `core/agents/service.zig` now resolves the hot-loaded registry against live
  routes, fixed-pool capacity, session topology, and a non-blocking team snapshot.
- `core/agents/spec.zig` sorts eligible and unavailable rows, renders canonical
  JSON, and hashes the exact snapshot into `var1.agent_eligibility.v1`.
- An unstarted supervisor projects configured idle capacity without starting
  worker threads; after startup the actual pool ceiling and occupancy win.
- A missing configured provider yields `route_unavailable`; zero depth yields no
  eligible rows; saturation advertises `queue_only`; changed state changes the
  verified receipt.
- One captured transport runs quiet and hive prompt profiles through the same
  executor. Quiet completes inline in one provider call. Hive calls `agents {}`,
  observes eligibility and communication state on call two, then completes.
- Debug and ReleaseFast each pass 19/19 build steps and 1,946/1,946 tests;
  ReleaseFast build passes 9/9. The final seven-file/115-segment GGUF audit
  returns one expected import/declaration adjacency candidate between the service
  and supervisor owners, zero exact duplicates, and no second selection/pool owner.
- Source ReleaseFast SHA-256 is
  `8CB2B28182BE153458C211BBF5A500F1BCD1726BAAB517771C4939697CC72B42`.
  Installed replacement remains move 38 because operator-owned PIDs 12028 and
  14452 still run the prior installed hash.

## Decision boundary

Move 27 does not implement prompt-mode switching, a shared task graph, capacity
accounting changes, or crash reconciliation. Moves 28-30 own those mechanics.
It removes the unconditional always-on fan-out policy and establishes the
smallest eligibility receipt that those later moves can extend without a new
owner.
