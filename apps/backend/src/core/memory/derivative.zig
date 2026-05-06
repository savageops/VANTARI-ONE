const std = @import("std");

pub const Error = error{
    MissingSourceRange,
    InvalidSourceRange,
    EmptySummary,
    TranscriptReplayRejected,
    UnsupportedMemoryCapability,
};

pub const EntryType = enum {
    summary,
    invariant,
    decision,
    evaluator_note,
};

pub const UnsupportedBehavior = enum {
    autonomous_background_evolution,
    exact_tokenizer_integration,
    model_internal_latent_transfer,
};

pub const DerivativeMemoryEntry = struct {
    session_id: []const u8,
    source_seq_start: u64,
    source_seq_end: u64,
    entry_type: EntryType,
    summary: []const u8,
    created_at_ms: i64,
    invalidated_at_ms: ?i64 = null,
    invalidation_reason: ?[]const u8 = null,
};

pub fn validateEntry(entry: DerivativeMemoryEntry) Error!void {
    if (entry.session_id.len == 0) return Error.MissingSourceRange;
    if (entry.source_seq_start == 0 or entry.source_seq_end == 0) return Error.MissingSourceRange;
    if (entry.source_seq_end < entry.source_seq_start) return Error.InvalidSourceRange;
    if (std.mem.trim(u8, entry.summary, " \t\r\n").len == 0) return Error.EmptySummary;
    if (looksLikeRawTranscriptReplay(entry.summary)) return Error.TranscriptReplayRejected;
}

pub fn renderEntryJson(allocator: std.mem.Allocator, entry: DerivativeMemoryEntry) ![]u8 {
    try validateEntry(entry);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"var1.derivative_memory.v1\",\"session_id\":{f},\"source_seq_start\":{},\"source_seq_end\":{},\"entry_type\":\"{s}\",\"summary\":{f},\"created_at_ms\":{},\"invalidated_at_ms\":{f},\"invalidation_reason\":{f}}}",
        .{
            std.json.fmt(entry.session_id, .{}),
            entry.source_seq_start,
            entry.source_seq_end,
            entryTypeLabel(entry.entry_type),
            std.json.fmt(entry.summary, .{}),
            entry.created_at_ms,
            std.json.fmt(entry.invalidated_at_ms, .{}),
            std.json.fmt(entry.invalidation_reason, .{}),
        },
    );
}

pub fn entryTypeLabel(entry_type: EntryType) []const u8 {
    return switch (entry_type) {
        .summary => "summary",
        .invariant => "invariant",
        .decision => "decision",
        .evaluator_note => "evaluator_note",
    };
}

pub fn unsupportedBehaviorDiagnostic(behavior: UnsupportedBehavior) []const u8 {
    return switch (behavior) {
        .autonomous_background_evolution => "autonomous background evolution is unsupported until cancellation, idempotent range marks, measurable benefit, and cold-start recovery are proven",
        .exact_tokenizer_integration => "exact tokenizer integration is unsupported until approximate budget tests prove the heuristic is insufficient",
        .model_internal_latent_transfer => "model-internal latent transfer is unsupported because VAR1 only owns external session, checkpoint, and tool-state contracts",
    };
}

fn looksLikeRawTranscriptReplay(summary: []const u8) bool {
    const has_role = std.ascii.indexOfIgnoreCase(summary, "\"role\"") != null;
    const has_content = std.ascii.indexOfIgnoreCase(summary, "\"content\"") != null;
    const has_seq = std.ascii.indexOfIgnoreCase(summary, "\"seq\"") != null;
    const names_transcript = std.ascii.indexOfIgnoreCase(summary, "messages.jsonl") != null;
    return has_role and has_content and (has_seq or names_transcript);
}

test "derivative memory requires sequence ranges and rejects transcript replay" {
    try validateEntry(.{
        .session_id = "session-1",
        .source_seq_start = 2,
        .source_seq_end = 4,
        .entry_type = .summary,
        .summary = "The operator selected scoped delegation and rejected background evolution.",
        .created_at_ms = 123,
    });

    try std.testing.expectError(Error.MissingSourceRange, validateEntry(.{
        .session_id = "session-1",
        .source_seq_start = 0,
        .source_seq_end = 4,
        .entry_type = .summary,
        .summary = "missing lower bound",
        .created_at_ms = 123,
    }));

    try std.testing.expectError(Error.TranscriptReplayRejected, validateEntry(.{
        .session_id = "session-1",
        .source_seq_start = 2,
        .source_seq_end = 4,
        .entry_type = .summary,
        .summary = "{\"seq\":2,\"role\":\"user\",\"content\":\"raw transcript row\"}",
        .created_at_ms = 123,
    }));
}

test "unsupported memory behavior reports explicit diagnostics" {
    const diagnostic = unsupportedBehaviorDiagnostic(.autonomous_background_evolution);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "cold-start recovery") != null);
}
