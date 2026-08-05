# Task 15 — Arena/Quota Allocator Discipline

## Your mission

Expand the VANTARI roadmap by writing `.docs/roadmap/15-arena-quota-allocator-discipline.md`.

1. **Study the repo** — read `AGENTS.md` (Section VIII, Section X cost model, Section XVIII item 6), `.docs/log.txt` (search for "alloc", "arena", "memory", "leak", "quota", "gpa"), and the backend source for `ArenaAllocator`, `GeneralPurposeAllocator`, `page_allocator`, `heap` usage patterns across `apps/backend/src/`.
2. **Study competitors** — `.refs/vercel__eve/` (V8 GC, no manual allocation — what does VANTARI gain by manual?), `.refs/badlogic__pi-mono/` (Rust ownership/allocator patterns).
3. **Web research** — search for: Zig arena allocator best practices, per-turn allocation scopes, quota-bounded allocators, Rust arena patterns (bumpalo, typed-arena), how agent runtimes manage memory per turn / per provider payload / per tool result / per UI frame, memory leak detection in long-running agent sessions.
4. **Write the roadmap file** following the exact shape of existing roadmap files.

## What this theme covers (AGENTS.md Section XVIII item 6)

- **Arena/quota discipline:** split allocators by turn, provider payload, tool result, and UI frame.
- Each allocation scope must have a clear owner, a clear lifetime, and a clear bound.
- The goal is deterministic memory behavior: no unbounded growth, no leak across turns, no OOM mid-session.

## Competitor angles to research

- **Vercel Eve:** TypeScript/V8 — GC-managed, no arena discipline. What are the failure modes? (memory pressure, GC pauses, unbounded message arrays)
- **pi-mono (Rust):** ownership model, `Box`/`Rc`/arena patterns, how does it bound per-turn memory?
- **Zig ecosystem:** `ArenaAllocator` lifecycle patterns, `debug_allocators`, leak detection.
- **C/C++ runtimes:** jemalloc/MI per-thread arenas, region-based allocation.

## Allocation scopes to define

| Scope | Owner | Lifetime | Bound |
|---|---|---|---|
| Turn | executor loop | one provider turn | max tokens × overhead |
| Provider payload | provider adapter | one request/response cycle | max context window |
| Tool result | tool runtime | one tool dispatch | output cap bytes |
| UI frame | TUI client | one render frame | terminal buffer size |

## Pipeline items to define

- P1: Audit all allocation sites and assign each to a scope
- P1: Quota-bounded allocator for tool results (prevents oversized write payloads)
- P2: Per-turn arena reset with leak detection in debug builds

## Reminders from .docs/log.txt

Read `.docs/log.txt`. Search for "alloc", "arena", "memory", "leak". Memory at 72 mentions — a smaller but critical theme.

## Output

Write ONLY `.docs/roadmap/15-arena-quota-allocator-discipline.md`. Do not modify source code or the index.
