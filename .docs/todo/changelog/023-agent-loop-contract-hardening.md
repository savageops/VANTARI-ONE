---
id: 023-agent-loop-contract-hardening
type: parent
protocol_version: "2.1"
spec_status: approved
category: refactor
status: done
epic_boundary: "Close the five accepted VAR1 review findings by making tool turns durable, tool effects independently budgeted, tool ingress strict, HTTP bridge requests concurrent, and settings.toml string/comment parsing truthful."
subtodo_start: /todo/pending/023a-agent-loop-contract-hardening.md
subtodo_final: /todo/pending/023g-agent-loop-contract-hardening.md
continuation: "After each completed execution unit: record evidence, set status done, move to /todo/changelog/, continue immediately to next_todo. Never batch-archive."
---
# 023 Agent Loop Contract Hardening

## Objective

Convert the review findings into durable runtime contracts rather than cosmetic patches. The final state must preserve `messages.jsonl` as the complete transcript, reject tool arguments that contradict model-visible schemas, cap tool effects independently from provider steps, prevent one long bridge request from blocking other local bridge traffic, and make `.var/config/settings.toml` parsing honest about quoted strings and comments.

## Source Message Proof

- "Tool turns are not durable transcript entries"
- "Tool effects are not independently budgeted"
- "Runtime accepts unknown tool parameters"
- "HTTP bridge serializes long-running connections"
- "Prompt/settings parser is pseudo-TOML"
- "you know what just fix all of them use the planning spec skill to spec out each and every single one and then complete all of them"

## Invariants

- I1: `.var/sessions/<session-id>/messages.jsonl` remains the append-only complete transcript.
- I2: `core/context/builder.zig` remains the only owner that turns session storage into provider-ready messages.
- I3: Model-visible tool schemas and runtime argument parsing agree on unknown fields.
- I4: Provider-step limits and tool-effect limits are separate controls.
- I5: `/rpc`, `/events`, and `/api/health` can make progress while another bridge connection is waiting on kernel or event work.
- I6: `.var/config/settings.toml` supports the subset it claims: sections, scalars, quoted prompt paths, escaped string characters, and `#` comments outside strings.

## Chain Manifest

| File | Phase | Role | Status |
|------|-------|------|--------|
| `/todo/changelog/023-agent-loop-contract-hardening.md` | parent | Chain root | done |
| `/todo/changelog/023a-agent-loop-contract-hardening.md` | a | Baseline / contract lock | done |
| `/todo/changelog/023b-agent-loop-contract-hardening.md` | b | Strict tool ingress | done |
| `/todo/changelog/023c-agent-loop-contract-hardening.md` | c | Durable tool transcript | done |
| `/todo/changelog/023d-agent-loop-contract-hardening.md` | d | Independent tool budgets | done |
| `/todo/changelog/023e-agent-loop-contract-hardening.md` | e | Concurrent HTTP bridge | done |
| `/todo/changelog/023f-agent-loop-contract-hardening.md` | f | Settings parser fidelity | done |
| `/todo/changelog/023g-agent-loop-contract-hardening.md` | g | Validation / docs / closeout | done |

## Validation Expectations

- `.\scripts\zigw.ps1 build test --summary all` exits `0`.
- Tool-loop tests prove durable assistant tool-call and tool result rows are replayed.
- Tool tests prove unknown JSON arguments are rejected.
- Bridge tests or build coverage prove connection handling no longer runs inline in the accept loop.
- Settings tests prove `#` inside quoted prompt paths is data, while `#` outside strings is a comment.

## Next todo

Closed and archived under `/todo/changelog/`.

## Completion Evidence

- Tool ingress rejects undeclared parameters before side effects.
- Tool-call assistant turns and tool-result rows persist in `messages.jsonl`.
- Tool dispatch is bounded independently by `MAX_TOOL_CALLS_PER_TURN` and `MAX_TOOL_CALLS_PER_SESSION`.
- HTTP bridge connection handling no longer runs inline in the accept loop.
- Prompt settings require quoted TOML string scalars and preserve `#` inside quoted paths.
- Validation: `.\scripts\zigw.ps1 build test --summary all` -> `90/90 tests passed`.
