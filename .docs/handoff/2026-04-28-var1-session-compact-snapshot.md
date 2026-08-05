# VAR1 Session Compact Snapshot - 2026-04-28

## Objective

Implement the manual `session/compact` slice as a simple, entry-aware checkpoint primitive without copying reference implementations or introducing a second transcript path.

## U1 Hierarchy Flow

```text
<session/compact>
  └─ <Guard / Precondition> session exists, session is not running, keep_recent_messages > 0
  └─ <Parent Contract / Layout> .var/sessions/<session-id>/
        │ JSON-RPC request
        ▼
  <src/core/context/compactor.zig>
  ├─ <Read Channel> session.json + messages.jsonl + latest valid context.jsonl checkpoint
  ├─ <Core Transform> stable seq entry/range -> structured checkpoint summary
  ├─ <Failure Path> no writable checkpoint when message range is insufficient/current
  ├─ <State Mutation> append one summary checkpoint to context.jsonl
  │   └─ <Invariant Preserved> messages.jsonl remains complete append-only transcript; checkpoint marks range + aggressiveness
  ├─ <Feedback Emit> SessionCompactResult { session_id, compacted, checkpoint, reason }
  └─ <Control Handoff>
        ▼
  <src/core/context/builder.zig>
  └─ <Init / Consume>
      ├─ <Read Channel> latest checkpoint
      ├─ <Hydrate State> summary message + raw transcript where seq >= first_kept_seq
      └─ <Terminal State> provider-ready message window
```

## U2 Directory Hierarchy

```text
apps/backend/variant-1/src/
├─ core/
│  ├─ context/
│  │  ├─ builder.zig // model-visible transcript owner
│  │  ├─ compactor.zig // entry-aware checkpoint planner/writer
│  │  └─ index.zig // context exports
│  └─ sessions/
│     └─ store.zig // .var/sessions storage owner
├─ host/
│  └─ stdio_rpc.zig // session/compact dispatch
└─ shared/
   └─ protocol/
      └─ types.zig // method and result contract
```

## U4 State Machine

```text
<Uncompacted Rows>
  │ session/compact with max_entries_per_checkpoint
  ▼
<Segment Checkpointed>
  ├─ entry action: append context.jsonl checkpoint
  ├─ invariant: messages.jsonl remains canonical transcript
  │ later session/compact with same/lower aggressiveness
  ▼
<Next Segment Checkpointed>
  │ later session/compact with higher aggressiveness
  ▼
<Range Recompacted> (terminal for current request)
  └─ effect: latest checkpoint replaces the model-visible summary view
```

## Validation

```text
cd apps/backend/variant-1
.\scripts\zigw.ps1 build test --summary all -> 67/67 tests passed
.\scripts\health.ps1 -> status: ready
git diff --check -> clean except existing CRLF conversion warnings
```

## Boundary

The implemented compactor is deterministic and Zig-native. It creates a structured extractive checkpoint using stable message sequence numbers, carries the prior checkpoint summary forward during incremental advancement, keeps JSON `keep_recent_messages` and `max_entries_per_checkpoint` wire values bounded as `u32` before widening inside the kernel, and leaves provider-driven semantic summarization plus auto-compaction out of scope until token accounting and cancellation behavior are proven.

Entry-level compaction is live through `max_entries_per_checkpoint`. A value of `1` advances one `messages.jsonl` row per checkpoint; `0` compacts all currently eligible rows. The public `aggressiveness` slider is accepted as `0..1` and stored as `aggressiveness_milli`; when a later request is stronger than the latest checkpoint, the compactor recompacts the covered range from the immutable transcript instead of repeatedly summarizing checkpoint text.
