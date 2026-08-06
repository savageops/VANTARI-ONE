const std = @import("std");
const types = @import("../../shared/types.zig");

/// Stream Rules (TTSR — Time-Traveling Stream Rules)
///
/// Regex-based mid-stream abort: when the model emits a pattern that matches
/// a rule (e.g. `Box::leak`, `eval(`, `os.system`), the provider stream is
/// aborted mid-token, the rule's message is injected as a system reminder,
/// and the turn retries from the same point. This prevents the model from
/// wasting tokens on known-bad patterns without paying context tax on every
/// turn — the rule sits dormant until triggered.
///
/// Harvested from oh-my-pi's TTSR implementation and adapted for VANTARI's
/// typed event spine and durable ledger. Rule injections are persisted as
/// `rule_injected` events so they survive compaction.

pub const StreamRule = struct {
    /// Unique rule identifier (e.g. "no-box-leak").
    id: []const u8,
    /// Regex pattern to match against streaming deltas. When this pattern
    /// appears in the accumulated assistant output or reasoning, the rule fires.
    pattern: []const u8,
    /// The message injected as a system reminder when the rule fires.
    /// Example: "Don't reach for Box::leak in production code paths. Use Arc instead."
    message: []const u8,
    /// Which delta streams to check: "text", "reasoning", or "both".
    scope: RuleScope = .both,
    /// Whether this rule is enabled.
    enabled: bool = true,
};

pub const RuleScope = enum {
    text,
    reasoning,
    both,
};

pub const RuleMatch = struct {
    rule_id: []const u8,
    message: []const u8,
    /// The text that triggered the match (for diagnostics).
    matched_text: []const u8,
};

/// Check accumulated streaming text against all active rules.
/// Returns the first match found, or null if no rules fire.
/// The caller is responsible for aborting the stream, injecting the message,
/// and retrying the turn.
pub fn checkRules(
    allocator: std.mem.Allocator,
    rules: []const StreamRule,
    accumulated_text: []const u8,
    accumulated_reasoning: []const u8,
) !?RuleMatch {
    for (rules) |rule| {
        if (!rule.enabled) continue;

        // Check the appropriate stream based on scope.
        const check_text = rule.scope == .text or rule.scope == .both;
        const check_reasoning = rule.scope == .reasoning or rule.scope == .both;

        if (check_text and accumulated_text.len > 0) {
            if (try matchPattern(allocator, rule.pattern, accumulated_text)) |match| {
                return .{
                    .rule_id = rule.id,
                    .message = rule.message,
                    .matched_text = match,
                };
            }
        }

        if (check_reasoning and accumulated_reasoning.len > 0) {
            if (try matchPattern(allocator, rule.pattern, accumulated_reasoning)) |match| {
                return .{
                    .rule_id = rule.id,
                    .message = rule.message,
                    .matched_text = match,
                };
            }
        }
    }
    return null;
}

/// Simple substring match (Zig's std.regex is limited; for production this
/// would use a proper regex engine, but substring matching covers the
/// majority of stream-rule use cases: "Box::leak", "os.system", "eval(").
fn matchPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    text: []const u8,
) !?[]const u8 {
    _ = allocator;
    if (std.mem.indexOf(u8, text, pattern)) |pos| {
        // Return a small context window around the match for diagnostics.
        const start = if (pos > 20) pos - 20 else 0;
        const end = @min(text.len, pos + pattern.len + 20);
        return text[start..end];
    }
    return null;
}

/// Built-in rules that ship with VANTARI. These are conservative patterns
/// that catch common mistakes across languages.
pub const builtin_rules = [_]StreamRule{
    .{
        .id = "no-eval",
        .pattern = "eval(",
        .message = "Avoid eval() — it introduces code injection risks. Use a safe parser or structured dispatch instead.",
        .scope = .both,
    },
    .{
        .id = "no-os-system",
        .pattern = "os.system(",
        .message = "Avoid os.system() — use subprocess with explicit argv and input validation for safer command execution.",
        .scope = .both,
    },
    .{
        .id = "no-innerhtml",
        .pattern = "innerHTML",
        .message = "Avoid innerHTML — it introduces XSS risks. Use textContent or a DOM API with proper escaping.",
        .scope = .text,
    },
};

/// Format a rule injection as a system reminder message for the provider.
/// This message is injected into the context window on retry, after the
/// aborted assistant message, as a user-role correction.
pub fn formatInjectionMessage(
    allocator: std.mem.Allocator,
    match: RuleMatch,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "[Stream rule '{s}' triggered] {s} The matched pattern was: \"{s}\". Please revise your approach and continue.",
        .{ match.rule_id, match.message, match.matched_text },
    );
}

// ============================================================================
// Tests
// ============================================================================

test "checkRules matches pattern in text stream" {
    const rules = [_]StreamRule{
        .{ .id = "test-rule", .pattern = "Box::leak", .message = "Use Arc instead", .scope = .both },
    };

    const result = try checkRules(std.testing.allocator, &rules, "let x = Box::leak(data);", "");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test-rule", result.?.rule_id);
    try std.testing.expect(std.mem.indexOf(u8, result.?.matched_text, "Box::leak") != null);
}

test "checkRules matches pattern in reasoning stream" {
    const rules = [_]StreamRule{
        .{ .id = "test-rule", .pattern = "os.system", .message = "Use subprocess", .scope = .reasoning },
    };

    const result = try checkRules(std.testing.allocator, &rules, "", "I should use os.system to run the command");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("test-rule", result.?.rule_id);
}

test "checkRules returns null when no pattern matches" {
    const rules = [_]StreamRule{
        .{ .id = "test-rule", .pattern = "Box::leak", .message = "Use Arc", .scope = .both },
    };

    const result = try checkRules(std.testing.allocator, &rules, "let x = Arc::new(data);", "");
    try std.testing.expect(result == null);
}

test "checkRules skips disabled rules" {
    const rules = [_]StreamRule{
        .{ .id = "disabled", .pattern = "eval(", .message = "Don't use eval", .enabled = false },
    };

    const result = try checkRules(std.testing.allocator, &rules, "eval('code')", "");
    try std.testing.expect(result == null);
}

test "formatInjectionMessage produces readable correction" {
    const match = RuleMatch{
        .rule_id = "no-eval",
        .message = "Avoid eval().",
        .matched_text = "eval('code')",
    };

    const msg = try formatInjectionMessage(std.testing.allocator, match);
    defer std.testing.allocator.free(msg);

    try std.testing.expect(std.mem.indexOf(u8, msg, "no-eval") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Avoid eval()") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Please revise") != null);
}

test "builtin rules include common dangerous patterns" {
    var found_eval = false;
    var found_os_system = false;
    for (builtin_rules) |rule| {
        if (std.mem.eql(u8, rule.id, "no-eval")) found_eval = true;
        if (std.mem.eql(u8, rule.id, "no-os-system")) found_os_system = true;
    }
    try std.testing.expect(found_eval);
    try std.testing.expect(found_os_system);
}
