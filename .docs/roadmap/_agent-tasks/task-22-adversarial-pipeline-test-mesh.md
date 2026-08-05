# Task 22 — Adversarial Pipeline Test Mesh

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/22-adversarial-pipeline-test-mesh.md`.

1. **Study the repo** — read `AGENTS.md` (Section XIII Proof-Gated Promotion Lifecycle, Section XIV Testing Integrity), `.docs/log.txt` (search for "test", "matrix", "pipeline", "adversarial", "falsification", "pressure"), and the test files under `apps/backend/tests/`.
2. **Study competitors** — `.refs/vercel__eve/` (test patterns, what do they test?), `.refs/openai__codex/`, `.refs/badlogic__pi-mono/`.
3. **Web research** — search for: adversarial testing for agent runtimes, property-based testing in Zig, fuzzing JSONL parsers, chaos engineering for stateful systems, how Temporal/Temporal testing works, testing streaming SSE parsing, testing torn-write recovery, testing process cancellation, testing context window overflow.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Sections XIII, XIV, XVIII item 13)

- **Adversarial pipeline test mesh:** suites for provider recovery, tool loops, context rebuilds, TUI event consumption, installed auth/workspace resolution, and Windows process behavior.

- **Testing integrity (Section XIV) — tests must behave like adversarial pipeline probes:**
  - corrupted JSONL suffixes
  - stale running sessions
  - failed no-prompt resumes
  - invalid tool batches
  - orphan tool results
  - duplicate context after provider overflow
  - command timeout and process locks
  - stdout/stderr cap markers
  - oversized write payloads
  - cwd escape before process launch
  - same-millisecond event bursts
  - terminal scrollback under live streaming
  - installed binary auth/workspace resolution

- **Proof-gated promotion lifecycle (Section XIII):**
  ```
  Recon -> Contract -> Smallest durable slice -> Canonical tests
        -> Native installed proof -> Event/session evidence -> Docs/changelog
  ```
  Tests are gate 2. A test is valuable only when the assertion proves an invariant a shallow implementation would violate.

## Competitor angles to research

- **Vercel Eve:** what test coverage does it have? Mock providers? Integration tests?
- **Temporal:** testing framework — time skipping, activity mocking, workflow replay testing.
- **Property-based testing:** QuickCheck/Hypothesis patterns for JSONL integrity.
- **Chaos engineering:** Netflix Chaos Monkey patterns applied to agent sessions.

## Existing test files to inventory

Look at `apps/backend/tests/` — the log mentions `agent_pipeline_deep_matrix_test.zig`, `pipeline_matrix_test.zig`, `runtime_loop_test.zig`, `tools_test.zig`, `auth_store_test.zig`, `core_store_test.zig`, `workspace_resolution_test.zig`.

## Pipeline items to define

- P0: Complete adversarial probe list (all 13 items from Section XIV)
- P1: Property-based fuzzing for JSONL readers (random corruption, random valid prefix)
- P1: Mock provider that simulates overflow, refusal, tool-call shape errors
- P2: TUI event consumption test harness
- P2: Installed-binary integration test (auth, workspace, health)

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "test", "matrix", "pipeline", "adversarial", "falsification". The log mentions 1365/1365 tests passing at one point.

## Output

Write ONLY `.docs/roadmap/22-adversarial-pipeline-test-mesh.md`. Do not modify source code or the index.
