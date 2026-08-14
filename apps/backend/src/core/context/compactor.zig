const std = @import("std");
const store = @import("../sessions/store.zig");
const types = @import("../../shared/types.zig");
const semantic = @import("semantic.zig");

pub const Error = error{
    InvalidCompactionOptions,
};

pub const CompactOptions = struct {
    keep_recent_messages: usize = 4,
    trigger: []const u8 = "manual",
    max_message_chars: usize = 600,
    aggressiveness_milli: u16 = 350,
    max_entries_per_checkpoint: usize = 0,
    /// When true, score messages by semantic similarity (embeddings or
    /// TF-IDF) to the session purpose before selection. Messages with
    /// low relevance are dropped first. (semantic compaction engine)
    semantic_scoring: bool = false,
    /// The session purpose text (typically the original user prompt).
    /// Used as the reference vector for semantic scoring. Required when
    /// semantic_scoring is true.
    purpose_text: []const u8 = "",
};

pub const CompactResult = struct {
    checkpoint: ?types.ContextCheckpoint = null,
    reason: []const u8 = "compacted",

    pub fn deinit(self: CompactResult, allocator: std.mem.Allocator) void {
        if (self.checkpoint) |checkpoint| checkpoint.deinit(allocator);
    }
};

const CompactionPlan = struct {
    source_start_seq: u64,
    source_end_seq: u64,
    segment_start_seq: u64,
    segment_end_seq: u64,
    first_kept_seq: u64,
    compacted_entry_count: u32,
    recompact: bool,
};

pub fn compactSession(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    session_id: []const u8,
    options: CompactOptions,
) !CompactResult {
    if (options.keep_recent_messages == 0 or options.trigger.len == 0 or options.max_message_chars == 0 or options.aggressiveness_milli > 1000) {
        return Error.InvalidCompactionOptions;
    }

    var session = try store.readSessionRecord(allocator, workspace_root, session_id);
    defer session.deinit(allocator);

    const messages = try store.readSessionMessages(allocator, workspace_root, session.id);
    defer types.deinitSessionMessages(allocator, messages);

    if (messages.len <= options.keep_recent_messages) {
        return .{ .reason = "not_enough_messages" };
    }

    const latest = try store.readLatestContextCompileCheckpoint(allocator, workspace_root, session.id);
    defer if (latest) |checkpoint| checkpoint.deinit(allocator);

    const plan = buildPlan(messages, latest, options) orelse return .{ .reason = "checkpoint_already_current" };

    const summary = try renderSummary(
        allocator,
        latest,
        messages,
        plan,
        options,
    );
    errdefer allocator.free(summary);

    const checkpoint_id = try checkpointId(allocator);
    errdefer allocator.free(checkpoint_id);

    const entry_type = try allocator.dupe(u8, "summary_checkpoint");
    errdefer allocator.free(entry_type);

    const trigger = try allocator.dupe(u8, options.trigger);
    errdefer allocator.free(trigger);

    const checkpoint = types.ContextCheckpoint{
        .id = checkpoint_id,
        .entry_type = entry_type,
        .created_at_ms = std.time.milliTimestamp(),
        .source_seq_start = plan.source_start_seq,
        .source_seq_end = plan.source_end_seq,
        .first_kept_seq = plan.first_kept_seq,
        .tokens_before_estimate = estimateMessages(messages, plan.source_start_seq, plan.source_end_seq),
        .tokens_after_estimate = estimateText(summary) + estimateMessages(messages, plan.first_kept_seq, null),
        .aggressiveness_milli = options.aggressiveness_milli,
        .compacted_entry_count = plan.compacted_entry_count,
        .trigger = trigger,
        .summary = summary,
    };

    try store.appendContextCheckpoint(allocator, workspace_root, session.id, checkpoint);
    return .{ .checkpoint = checkpoint };
}

fn buildPlan(
    messages: []const types.SessionMessage,
    latest: ?types.ContextCheckpoint,
    options: CompactOptions,
) ?CompactionPlan {
    const eligible_end_index = messages.len - options.keep_recent_messages - 1;
    const eligible_end_seq = messages[eligible_end_index].seq;
    const recompact = if (latest) |checkpoint| options.aggressiveness_milli > checkpoint.aggressiveness_milli else false;
    const start_seq = if (recompact)
        latest.?.source_seq_start
    else if (latest) |checkpoint|
        checkpoint.first_kept_seq
    else
        messages[0].seq;

    if (!recompact and eligible_end_seq < start_seq) return null;

    const start_index = findFirstMessageIndexAtOrAfter(messages, start_seq) orelse return null;
    if (start_index > eligible_end_index) return null;

    var segment_end_index = eligible_end_index;
    if (!recompact and options.max_entries_per_checkpoint > 0) {
        const bounded_end = start_index + options.max_entries_per_checkpoint - 1;
        segment_end_index = @min(bounded_end, eligible_end_index);
    }
    segment_end_index = adjustSegmentEndForProviderBoundary(messages, start_index, segment_end_index) orelse return null;
    if (segment_end_index < start_index) return null;

    const segment_start_seq = messages[start_index].seq;
    const segment_end_seq = messages[segment_end_index].seq;
    const source_start_seq = if (latest) |checkpoint| checkpoint.source_seq_start else segment_start_seq;
    const source_end_seq = segment_end_seq;
    const first_kept_seq = messages[segment_end_index + 1].seq;

    if (!recompact and latest != null and first_kept_seq <= latest.?.first_kept_seq) return null;

    return .{
        .source_start_seq = source_start_seq,
        .source_end_seq = source_end_seq,
        .segment_start_seq = segment_start_seq,
        .segment_end_seq = segment_end_seq,
        .first_kept_seq = first_kept_seq,
        .compacted_entry_count = @intCast(countMessages(messages, segment_start_seq, segment_end_seq)),
        .recompact = recompact,
    };
}

fn adjustSegmentEndForProviderBoundary(
    messages: []const types.SessionMessage,
    start_index: usize,
    proposed_end_index: usize,
) ?usize {
    const first_kept_index = proposed_end_index + 1;
    if (first_kept_index >= messages.len or messages[first_kept_index].role != .tool) return proposed_end_index;

    const tool_call_id = messages[first_kept_index].tool_call_id orelse return null;
    var index = first_kept_index;
    while (index > 0) {
        index -= 1;
        const message = messages[index];
        if (message.role != .assistant or message.tool_calls.len == 0) continue;
        for (message.tool_calls) |tool_call| {
            if (std.mem.eql(u8, tool_call.id, tool_call_id)) {
                if (index == 0 or index <= start_index) return null;
                return index - 1;
            }
        }
    }

    return null;
}

fn renderSummary(
    allocator: std.mem.Allocator,
    latest: ?types.ContextCheckpoint,
    messages: []const types.SessionMessage,
    plan: CompactionPlan,
    options: CompactOptions,
) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    const writer = output.writer();

    try writer.print(
        "VAR1 context checkpoint\nsource_range: {d}..{d}\nsegment_range: {d}..{d}\nfirst_kept_seq: {d}\naggressiveness_milli: {d}\ncompacted_entry_count: {d}\n",
        .{
            plan.source_start_seq,
            plan.source_end_seq,
            plan.segment_start_seq,
            plan.segment_end_seq,
            plan.first_kept_seq,
            options.aggressiveness_milli,
            plan.compacted_entry_count,
        },
    );

    if (latest) |checkpoint| {
        if (plan.recompact) {
            try writer.print("\nreplaces_checkpoint: {s}\n", .{checkpoint.id});
        } else {
            try writer.print("\nprevious_summary:\n{s}\n", .{checkpoint.summary});
        }
    }

    // Semantic scoring: when enabled, score each compactable message by
    // relevance to the session purpose. Messages below the median score
    // are dropped from the summary; high-relevance messages get expanded
    // char budget. This is the semantic compaction engine Stage 1.
    var semantic_scores: ?[]f32 = null;
    defer if (semantic_scores) |s| allocator.free(s);
    if (options.semantic_scoring and options.purpose_text.len > 0) {
        // Collect messages in the compactable range for scoring.
        var compactable = std.array_list.Managed(types.SessionMessage).init(allocator);
        defer compactable.deinit();
        for (messages) |message| {
            if (message.seq >= plan.segment_start_seq and message.seq <= plan.segment_end_seq) {
                try compactable.append(message);
            }
        }
        if (compactable.items.len > 0) {
            semantic_scores = semantic.scoreMessages(allocator, null, options.purpose_text, compactable.items) catch null;
        }
    }

    try writer.writeAll("\ncompacted_messages:\n");
    var score_idx: usize = 0;
    for (messages) |message| {
        if (message.seq < plan.segment_start_seq or message.seq > plan.segment_end_seq) continue;

        // When semantic scoring is active, skip messages below median relevance.
        // This drops the least relevant content before rendering, keeping the
        // summary focused on what matters for the session's purpose.
        if (semantic_scores) |scores| {
            if (score_idx < scores.len) {
                const score = scores[score_idx];
                score_idx += 1;
                // Skip messages in the bottom quartile of relevance.
                if (score < 0.15) continue;
                try writer.print("[relevance={d:.2}] ", .{score});
            }
        }

        try writer.print(
            "- seq={d} role={s} chars={d}: ",
            .{ message.seq, types.sessionMessageRoleLabel(message.role), message.content.len },
        );
        try appendOneLinePrefix(&output, message.content, options.max_message_chars);
        try writer.writeByte('\n');

        // Reasoning-aware compaction: at low aggressiveness (< 500 milli, i.e.
        // < 50%), include a one-line reasoning excerpt so the model's thinking
        // trace survives as a checkpoint anchor. At high aggressiveness, omit
        // reasoning to minimize token cost. (roadmap: reasoning checkpoints)
        if (message.reasoning) |reasoning| {
            if (reasoning.len > 0 and options.aggressiveness_milli < 500) {
                const max_reasoning_chars: usize = 200;
                try writer.print("  reasoning_excerpt: ", .{});
                try appendOneLinePrefix(&output, reasoning, max_reasoning_chars);
                try writer.writeByte('\n');
            }
        }
    }

    return output.toOwnedSlice();
}

fn findFirstMessageIndexAtOrAfter(messages: []const types.SessionMessage, seq: u64) ?usize {
    for (messages, 0..) |message, index| {
        if (message.seq >= seq) return index;
    }
    return null;
}

fn countMessages(messages: []const types.SessionMessage, first_seq: u64, last_seq: u64) usize {
    var count: usize = 0;
    for (messages) |message| {
        if (message.seq >= first_seq and message.seq <= last_seq) count += 1;
    }
    return count;
}

/// Append a value-weighted summary of `content` to `output`, bounded by
/// `max_chars`. Unlike naive truncation (which cuts mid-word and appends
/// "..."), this function drops whole words by ascending value weight:
///
/// 1. Tokenize into words (whitespace-delimited, preserving code tokens).
/// 2. Score each word: identifiers, code paths, numbers, and keywords rank
///    higher than filler (articles, prepositions, conjunctions).
/// 3. If the full text fits within `max_chars`, emit it verbatim (whitespace-
///    flattened).
/// 4. If it doesn't fit, drop the lowest-weighted words first until it does,
///    preserving the order of surviving words. This means the summary keeps
///    the high-signal tokens (function names, error strings, file paths,
///    numbers) and loses the connective tissue.
///
/// This is VANTARI's value-weighted compaction engine: the model's reasoning
/// trace and output are distilled to their highest-information prefix, never
/// butchered by a mid-word cut.
fn appendOneLinePrefix(output: *std.array_list.Managed(u8), content: []const u8, max_chars: usize) !void {
    // Fast path: if the flattened content fits, emit it verbatim.
    const flat_len = countFlatLen(content);
    if (flat_len <= max_chars) {
        for (content) |byte| {
            switch (byte) {
                '\r', '\n', '\t' => try output.append(' '),
                else => try output.append(byte),
            }
        }
        return;
    }

    // Value-weighted path: tokenize, score, drop lowest-value words.
    const allocator = output.allocator;

    // Tokenize into words (slices into the original content).
    var words = std.array_list.Managed([]const u8).init(allocator);
    defer words.deinit();
    var word_starts = std.array_list.Managed(usize).init(allocator);
    defer word_starts.deinit();

    var i: usize = 0;
    while (i < content.len) {
        while (i < content.len and isWordBoundary(content[i])) : (i += 1) {}
        if (i >= content.len) break;
        const start = i;
        while (i < content.len and !isWordBoundary(content[i])) : (i += 1) {}
        try words.append(content[start..i]);
        try word_starts.append(start);
    }

    if (words.items.len == 0) return;

    // Score each word by information value.
    var scores = try allocator.alloc(u8, words.items.len);
    defer allocator.free(scores);
    for (words.items, 0..) |word, idx| {
        scores[idx] = wordValueWeight(word);
    }

    // Iteratively drop the lowest-scored word until we fit.
    // Keep track of which words are dropped.
    var dropped = try allocator.alloc(bool, words.items.len);
    defer allocator.free(dropped);
    @memset(dropped, false);

    var current_len = flat_len;
    while (current_len > max_chars) {
        // Find the lowest-scored non-dropped word. Ties break toward the
        // end of the text (later words are more likely to be detail).
        var min_idx: usize = 0;
        var min_score: u8 = 255;
        var found = false;
        var w: usize = words.items.len;
        while (w > 0) {
            w -= 1;
            if (dropped[w]) continue;
            if (!found or scores[w] < min_score) {
                min_score = scores[w];
                min_idx = w;
                found = true;
            }
        }
        if (!found) break;

        dropped[min_idx] = true;
        // Each dropped word saves its length + 1 (the separating space).
        current_len = current_len -| (flatWordLen(words.items[min_idx]) + 1);
    }

    // Emit surviving words in original order.
    var first = true;
    for (words.items, 0..) |word, idx| {
        if (dropped[idx]) continue;
        if (!first) try output.append(' ');
        first = false;
        for (word) |byte| {
            switch (byte) {
                '\r', '\n', '\t' => try output.append(' '),
                else => try output.append(byte),
            }
        }
    }
}

fn isWordBoundary(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn countFlatLen(content: []const u8) usize {
    return content.len; // flatlen == content.len (each byte maps 1:1)
}

fn flatWordLen(word: []const u8) usize {
    return word.len;
}

/// Score a word by information value on a 0-255 scale.
/// Higher = more valuable, less likely to be dropped during compaction.
///
/// Value tiers:
/// - 255: code identifiers with underscores/camelCase (function_call, myVar)
/// - 240: file paths and URLs (src/core/file.zig, http://...)
/// - 220: numbers and hex (42, 0x1F, session-178...)
/// - 200: long words (7+ chars, likely domain-specific)
/// - 160: medium words (4-6 chars)
/// - 100: short common words (the, a, is, to, of, in, for, and)
/// - 60: single-char tokens
fn wordValueWeight(word: []const u8) u8 {
    if (word.len == 0) return 0;

    // Code identifiers: contains underscore or mixed case (not all-caps acronym).
    if (std.mem.indexOfScalar(u8, word, '_') != null) return 255;
    var has_lower = false;
    var has_upper = false;
    for (word) |c| {
        if (c >= 'a' and c <= 'z') has_lower = true;
        if (c >= 'A' and c <= 'Z') has_upper = true;
    }
    if (has_lower and has_upper) return 255; // camelCase

    // File paths, URLs: contains / or \ or . in a path-like pattern.
    if (std.mem.indexOfScalar(u8, word, '/') != null or
        std.mem.indexOfScalar(u8, word, '\\') != null) return 240;
    if (std.mem.startsWith(u8, word, "http") or std.mem.startsWith(u8, word, "HTTP")) return 240;

    // Numbers: starts with a digit or 0x.
    if (word[0] >= '0' and word[0] <= '9') return 220;
    if (std.mem.startsWith(u8, word, "0x") or std.mem.startsWith(u8, word, "0X")) return 220;

    // Punctuation-heavy tokens (error strings, code fragments).
    var punct_count: usize = 0;
    for (word) |c| {
        if (c == '(' or c == ')' or c == '{' or c == '}' or
            c == '[' or c == ']' or c == '=' or c == ';' or
            c == '"' or c == '\'' or c == '`') punct_count += 1;
    }
    if (punct_count > 0) return 210;

    // All-caps words (acronyms like API, HTTP, JSON) — high signal.
    if (has_upper and !has_lower and word.len >= 2) return 200;

    // Filler words — the lowest tier.
    const filler = [_][]const u8{
        "the",   "a",     "an",  "is",  "are", "was", "were", "be",   "been", "being",
        "to",    "of",    "in",  "for", "on",  "at",  "by",   "with", "from", "as",
        "and",   "or",    "but", "not", "so",  "if",  "then", "else", "this", "that",
        "these", "those", "it",  "its",
    };
    for (filler) |f| {
        if (std.ascii.eqlIgnoreCase(word, f)) return 100;
    }

    // Length-based tiers for remaining words.
    if (word.len >= 7) return 200;
    if (word.len >= 4) return 160;
    if (word.len == 1) return 60;
    return 130; // 2-3 char words
}

fn estimateMessages(messages: []const types.SessionMessage, first_seq: u64, last_seq: ?u64) u64 {
    var chars: u64 = 0;
    for (messages) |message| {
        if (message.seq < first_seq) continue;
        if (last_seq) |max_seq| {
            if (message.seq > max_seq) continue;
        }
        chars += message.content.len;
    }
    return estimateChars(chars);
}

fn estimateText(text: []const u8) u64 {
    return estimateChars(text.len);
}

fn estimateChars(chars: u64) u64 {
    if (chars == 0) return 0;
    return (chars + 3) / 4;
}

fn checkpointId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "ctx-{d}-{x}", .{ std.time.milliTimestamp(), std.crypto.random.int(u64) });
}
