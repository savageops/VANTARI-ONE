const std = @import("std");
const types = @import("../../shared/types.zig");

pub fn estimateText(text: []const u8) u64 {
    if (text.len == 0) return 0;
    return (@as(u64, @intCast(text.len)) + 3) / 4;
}

pub fn promptWithinBudget(prompt: []const u8, budget_tokens: u64) bool {
    return budget_tokens > 0 and estimateText(prompt) <= budget_tokens;
}

pub fn estimateChatMessages(messages: []const types.ChatMessage) u64 {
    var total: u64 = 0;
    for (messages) |message| {
        total += 4;
        if (message.content) |content| total += estimateText(content);
        if (message.tool_call_id) |tool_call_id| total += estimateText(tool_call_id);
        for (message.tool_calls) |tool_call| {
            total += estimateText(tool_call.id);
            total += estimateText(tool_call.name);
            total += estimateText(tool_call.arguments_json);
        }
    }
    return total;
}

pub fn thresholdTokens(policy: types.ContextPolicy) u64 {
    if (policy.context_window_tokens == 0) return 0;
    if (policy.reserve_output_tokens >= policy.context_window_tokens) return 0;

    const ratio_threshold = (policy.context_window_tokens * policy.compact_at_ratio_milli) / 1000;
    const reserve_threshold = policy.context_window_tokens - policy.reserve_output_tokens;
    return @min(ratio_threshold, reserve_threshold);
}

pub fn shouldCompact(estimated_tokens: u64, policy: types.ContextPolicy) bool {
    if (!policy.auto_compaction) return false;
    const threshold = thresholdTokens(policy);
    return threshold > 0 and estimated_tokens >= threshold;
}

/// Token cost breakdown of a provider window assembled from a checkpoint
/// prefix and a raw transcript suffix. This is the shard assembly budget:
/// each shard is a checkpoint + branch, and the branch must be cheaper than
/// the full parent window (roadmap P0-2a).
pub const WindowBudget = struct {
    /// Estimated tokens in the checkpoint summary prefix.
    checkpoint_tokens: u64,
    /// Estimated tokens in the raw transcript suffix after `first_kept_seq`.
    suffix_tokens: u64,
    /// Total estimated tokens in the assembled window.
    total_tokens: u64,
    /// True when the suffix is cheaper than re-sending the full transcript.
    /// This is the economic invariant of the shard model: a shard (checkpoint
    /// + one branch) costs less than the full parent window.
    suffix_cheaper_than_full: bool,

    pub fn suffixSavings(self: WindowBudget, full_transcript_tokens: u64) u64 {
        if (full_transcript_tokens <= self.total_tokens) return 0;
        return full_transcript_tokens - self.total_tokens;
    }
};

/// Compute the token budget of a window assembled as checkpoint + suffix.
/// `checkpoint_summary` is the compacted summary text; `suffix_messages` are
/// the raw messages from `first_kept_seq` onward. `full_transcript_tokens` is
/// the estimated cost of sending the entire transcript without compaction.
pub fn windowBudget(
    checkpoint_summary: []const u8,
    suffix_messages: []const types.ChatMessage,
    full_transcript_tokens: u64,
) WindowBudget {
    const checkpoint_tokens = estimateText(checkpoint_summary);
    const suffix_tokens = estimateChatMessages(suffix_messages);
    const total_tokens = checkpoint_tokens + suffix_tokens;
    return .{
        .checkpoint_tokens = checkpoint_tokens,
        .suffix_tokens = suffix_tokens,
        .total_tokens = total_tokens,
        .suffix_cheaper_than_full = total_tokens < full_transcript_tokens,
    };
}

test "context budget threshold respects ratio and reserve" {
    const policy = types.ContextPolicy{
        .context_window_tokens = 1000,
        .compact_at_ratio_milli = 900,
        .reserve_output_tokens = 250,
    };

    try std.testing.expectEqual(@as(u64, 750), thresholdTokens(policy));
    try std.testing.expect(!shouldCompact(749, policy));
    try std.testing.expect(shouldCompact(750, policy));
}

test "prompt budget uses the shared estimated token rule" {
    const prompt = "12345678";
    try std.testing.expectEqual(@as(u64, 2), estimateText(prompt));
    try std.testing.expect(promptWithinBudget(prompt, 2));
    try std.testing.expect(!promptWithinBudget(prompt, 1));
    try std.testing.expect(!promptWithinBudget(prompt, 0));
}

test "windowBudget proves checkpoint + suffix is cheaper than full transcript" {
    // Simulate: full transcript is 100 messages of ~50 chars each.
    var full_messages: [100]types.ChatMessage = undefined;
    for (&full_messages, 0..) |*msg, i| {
        msg.* = .{
            .role = .user,
            .content = std.fmt.allocPrint(std.testing.allocator, "message body line {d} with enough text to be meaningful", .{i}) catch unreachable,
        };
    }
    defer for (full_messages) |msg| if (msg.content) |c| std.testing.allocator.free(c);

    const full_tokens = estimateChatMessages(&full_messages);

    // After compaction: a 200-char summary + 5 recent messages.
    const summary = "Summary of work done: implemented event seq, BOM stripping, UTF-8 validation, fsync durability, and Job Object process-tree termination.";
    var recent: [5]types.ChatMessage = undefined;
    for (&recent, 0..) |*msg, i| {
        msg.* = .{
            .role = .user,
            .content = std.fmt.allocPrint(std.testing.allocator, "recent message {d}", .{i}) catch unreachable,
        };
    }
    defer for (recent) |msg| if (msg.content) |c| std.testing.allocator.free(c);

    const budget = windowBudget(summary, &recent, full_tokens);

    // The checkpoint + suffix must be cheaper than the full transcript.
    try std.testing.expect(budget.suffix_cheaper_than_full);
    try std.testing.expect(budget.total_tokens < full_tokens);

    // The savings must be positive and meaningful.
    const savings = budget.suffixSavings(full_tokens);
    try std.testing.expect(savings > 0);

    // The checkpoint tokens must be much smaller than the full transcript.
    try std.testing.expect(budget.checkpoint_tokens < full_tokens / 2);
}

test "windowBudget handles empty suffix" {
    const summary = "compacted summary";
    const budget = windowBudget(summary, &.{}, 1000);
    try std.testing.expectEqual(estimateText(summary), budget.total_tokens);
    try std.testing.expectEqual(@as(u64, 0), budget.suffix_tokens);
}
