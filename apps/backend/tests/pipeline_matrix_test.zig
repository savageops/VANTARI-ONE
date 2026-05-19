const std = @import("std");
const VAR1 = @import("VAR1");

const OverflowCase = struct {
    text: []const u8,
    expected: bool,
};

const overflow_cases = [_]OverflowCase{
    .{ .text = "openai error: context_length_exceeded", .expected = true },
    .{ .text = "provider said model_context_window_exceeded", .expected = true },
    .{ .text = "upstream request_too_large for prompt payload", .expected = true },
    .{ .text = "prompt is too long for selected model", .expected = true },
    .{ .text = "prompt too long after transcript replay", .expected = true },
    .{ .text = "This model's maximum context length is 128000 tokens.", .expected = true },
    .{ .text = "input exceeds the context window after tool transcript", .expected = true },
    .{ .text = "input exceeds the available context size", .expected = true },
    .{ .text = "payload greater than the context length", .expected = true },
    .{ .text = "context window exceeds limit", .expected = true },
    .{ .text = "too many tokens in request body", .expected = true },
    .{ .text = "token limit exceeded while building messages", .expected = true },
    .{ .text = "input is too long for this endpoint", .expected = true },
    .{ .text = "{\"error\":{\"code\":\"context_length_exceeded\"}}", .expected = true },
    .{ .text = "MAXIMUM CONTEXT LENGTH exceeded", .expected = true },
    .{ .text = "Prompt Too Long", .expected = true },
    .{ .text = "model reports REQUEST_TOO_LARGE", .expected = true },
    .{ .text = "The prompt is too long: 130000 tokens", .expected = true },
    .{ .text = "context_length_exceeded with provider metadata", .expected = true },
    .{ .text = "Context window exceeds limit during retry", .expected = true },
    .{ .text = "rate limit: maximum context length mentioned in docs", .expected = false },
    .{ .text = "too many requests and too many tokens in retry queue", .expected = false },
    .{ .text = "service unavailable: prompt is too long appears in retry text", .expected = false },
    .{ .text = "throttled because request_too_large pool is busy", .expected = false },
    .{ .text = "ordinary provider connection failure", .expected = false },
    .{ .text = "authentication failed for API key", .expected = false },
    .{ .text = "quota exhausted for account", .expected = false },
    .{ .text = "model not found", .expected = false },
    .{ .text = "invalid JSON response from provider", .expected = false },
    .{ .text = "network timeout waiting for completion", .expected = false },
    .{ .text = "Too Many Requests: rate limit exceeded.", .expected = false },
    .{ .text = "SERVICE UNAVAILABLE maximum context length", .expected = false },
    .{ .text = "temporary throttling input is too long", .expected = false },
    .{ .text = "bad gateway", .expected = false },
    .{ .text = "empty completion choices", .expected = false },
    .{ .text = "provider returned tool schema error", .expected = false },
    .{ .text = "request cancelled by operator", .expected = false },
    .{ .text = "permission denied by workspace policy", .expected = false },
    .{ .text = "socket hang up", .expected = false },
    .{ .text = "TLS handshake failed", .expected = false },
    .{ .text = "provider said context window is healthy", .expected = false },
    .{ .text = "context_length is configured", .expected = false },
    .{ .text = "token counter disabled", .expected = false },
    .{ .text = "prompt budget below threshold", .expected = false },
    .{ .text = "manual compaction skipped", .expected = false },
    .{ .text = "health probe successful", .expected = false },
    .{ .text = "readiness probe successful", .expected = false },
    .{ .text = "tool budget exceeded", .expected = false },
    .{ .text = "session cancelled", .expected = false },
    .{ .text = "workspace path escaped", .expected = false },
};

const valid_tool_names = [_][]const u8{
    "read_file",
    "search_files",
    "a",
    "a1",
    "a_b",
    "tool_01",
    "x9",
    "agent_status",
    "wait_agent",
    "list_agents",
    "init_workspace",
    "todo_slice",
    "changelog_ledger",
    "memory_ledger",
    "research_artifact",
    "docs_artifact",
    "workspace_backup",
    "git_worktree",
    "instruction_ingestion",
    "lookup_ticket",
    "ticket_123",
    "z",
    "z9_z",
    "plugin_tool_v1",
    "telemetry_sink",
};

const invalid_tool_names = [_][]const u8{
    "",
    "ReadFile",
    "read-file",
    "read.file",
    "read file",
    "read/file",
    "read:file",
    "read$file",
    "read,file",
    "read+file",
    "read_file?",
    "read_file!",
    "read_file*",
    "read_file@",
    "read_file#",
    "read_file%",
    "read_file&",
    "read_file=",
    "read_file(",
    "read_file)",
    "read_file[",
    "read_file]",
    "read_file{",
    "read_file}",
    "read\nfile",
};

const allowed_origins = [_][]const u8{
    "http://127.0.0.1:4310",
    "http://127.0.0.1:5173",
    "http://localhost:3000",
    "http://localhost:5173",
    "http://[::1]:4310",
    "http://[::1]:5173",
    "https://127.0.0.1:4310",
    "https://localhost:5173",
};

const denied_origins = [_][]const u8{
    "null",
    "file://local/index.html",
    "https://example.com",
    "http://example.com",
    "ftp://127.0.0.1:4310",
    "http://127.0.0.1:4310/path",
    "http://127.0.0.1:",
    "http://[::2]:4310",
};

const audited_methods = [_][]const u8{
    VAR1.shared.protocol.types.methods.session_create,
    VAR1.shared.protocol.types.methods.session_resume,
    VAR1.shared.protocol.types.methods.session_send,
    VAR1.shared.protocol.types.methods.session_compact,
    VAR1.shared.protocol.types.methods.session_cancel,
    VAR1.shared.protocol.types.methods.session_get,
    VAR1.shared.protocol.types.methods.session_list,
    "auth/status",
    VAR1.shared.protocol.types.methods.health_get,
    VAR1.shared.protocol.types.methods.tools_list,
};

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn verifyOverflowCase(index: usize) !void {
    const item = overflow_cases[index];
    try std.testing.expectEqual(item.expected, VAR1.core.context.overflow.isContextOverflowText(item.text));
}

fn verifyBudgetCase(index: usize) !void {
    const i: u64 = @as(u64, @intCast(index + 1));
    const window: u64 = if (index % 13 == 0) 0 else 256 + i * 97;
    const ratio: u16 = @as(u16, @intCast(300 + ((index * 37) % 701)));
    const reserve: u64 = if (window == 0) 0 else if (index % 11 == 0) window else (i * 31) % (window + 17);
    const auto = index % 7 != 0;
    const policy = VAR1.shared.types.ContextPolicy{
        .auto_compaction = auto,
        .context_window_tokens = window,
        .compact_at_ratio_milli = ratio,
        .reserve_output_tokens = reserve,
    };

    const threshold = VAR1.core.context.budget.thresholdTokens(policy);
    if (window == 0 or reserve >= window) {
        try std.testing.expectEqual(@as(u64, 0), threshold);
        try std.testing.expect(!VAR1.core.context.budget.shouldCompact(threshold, policy));
        return;
    }

    const ratio_threshold = (window * ratio) / 1000;
    const reserve_threshold = window - reserve;
    try std.testing.expect(threshold <= ratio_threshold);
    try std.testing.expect(threshold <= reserve_threshold);
    try std.testing.expect(threshold == ratio_threshold or threshold == reserve_threshold);

    if (auto and threshold > 0) {
        try std.testing.expect(VAR1.core.context.budget.shouldCompact(threshold, policy));
        try std.testing.expect(!VAR1.core.context.budget.shouldCompact(threshold - 1, policy));
    } else {
        try std.testing.expect(!VAR1.core.context.budget.shouldCompact(threshold, policy));
    }

    const text_len = index * 3 + 1;
    var buffer: [180]u8 = undefined;
    @memset(buffer[0..text_len], 'x');
    try std.testing.expectEqual((@as(u64, @intCast(text_len)) + 3) / 4, VAR1.core.context.budget.estimateText(buffer[0..text_len]));
}

fn verifySocketCase(index: usize) !void {
    if (index < valid_tool_names.len) {
        const name = valid_tool_names[index];
        try VAR1.core.tools.sockets.validateName(name);
        try VAR1.core.tools.sockets.validateDefinition(std.testing.allocator, .{
            .name = name,
            .description = "Matrix validated tool socket.",
            .review_risk = .read_only,
            .parameters_json = "{\"type\":\"object\",\"additionalProperties\":false}",
        });
        return;
    }

    const name = invalid_tool_names[index - valid_tool_names.len];
    if (name.len == 0) {
        try std.testing.expectError(VAR1.core.tools.sockets.Error.EmptyToolName, VAR1.core.tools.sockets.validateName(name));
    } else {
        try std.testing.expectError(VAR1.core.tools.sockets.Error.InvalidToolName, VAR1.core.tools.sockets.validateName(name));
    }
}

fn verifyPluginManifestCase(index: usize) !void {
    switch (index % 5) {
        0 => {
            const id = try std.fmt.allocPrint(std.testing.allocator, "plugin-{d}", .{index});
            defer std.testing.allocator.free(id);
            const version = try std.fmt.allocPrint(std.testing.allocator, "0.1.{d}", .{index});
            defer std.testing.allocator.free(version);
            const socket_name = try std.fmt.allocPrint(std.testing.allocator, "context-{d}", .{index});
            defer std.testing.allocator.free(socket_name);
            const sockets = [_]VAR1.core.plugins.PluginSocket{.{
                .kind = .context,
                .name = socket_name,
                .entry = "context/entry",
            }};
            try VAR1.core.plugins.validateManifest(.{ .id = id, .version = version, .sockets = sockets[0..] });
        },
        1 => {
            const id = try std.fmt.allocPrint(std.testing.allocator, "plugin_{d}", .{index});
            defer std.testing.allocator.free(id);
            const socket_name = try std.fmt.allocPrint(std.testing.allocator, "lookup_ticket_{d}", .{index});
            defer std.testing.allocator.free(socket_name);
            const sockets = [_]VAR1.core.plugins.PluginSocket{.{
                .kind = .tool,
                .name = socket_name,
                .entry = "tools/lookup_ticket",
            }};
            try VAR1.core.plugins.validateManifest(.{ .id = id, .version = "1.0.0", .sockets = sockets[0..] });
        },
        2 => {
            const id = try std.fmt.allocPrint(std.testing.allocator, "missing-version-{d}", .{index});
            defer std.testing.allocator.free(id);
            try std.testing.expectError(VAR1.core.plugins.manifest.Error.MissingPluginVersion, VAR1.core.plugins.validateManifest(.{
                .id = id,
                .version = " ",
            }));
        },
        3 => {
            const id = try std.fmt.allocPrint(std.testing.allocator, "Plugin-{d}", .{index});
            defer std.testing.allocator.free(id);
            try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidPluginId, VAR1.core.plugins.validateManifest(.{
                .id = id,
                .version = "1.0.0",
            }));
        },
        else => {
            const id = try std.fmt.allocPrint(std.testing.allocator, "plugin-{d}", .{index});
            defer std.testing.allocator.free(id);
            const socket_name = try std.fmt.allocPrint(std.testing.allocator, "lookup-ticket-{d}", .{index});
            defer std.testing.allocator.free(socket_name);
            const sockets = [_]VAR1.core.plugins.PluginSocket{.{
                .kind = .tool,
                .name = socket_name,
                .entry = "tools/lookup_ticket",
            }};
            try std.testing.expectError(VAR1.core.plugins.manifest.Error.InvalidSocketName, VAR1.core.plugins.validateManifest(.{
                .id = id,
                .version = "1.0.0",
                .sockets = sockets[0..],
            }));
        },
    }
}

fn verifyToolRuntimeCase(index: usize) !void {
    const file_names = [_][]const u8{ "read_file", "search_files", "write_file", "append_file", "replace_in_file", "list_files" };
    const agent_names = [_][]const u8{ "launch_agent", "agent_status", "wait_agent", "list_agents" };

    switch (index % 10) {
        0 => {
            const decision = VAR1.core.tool_runtime.review.reviewToolName(file_names[index % file_names.len], VAR1.core.tool_runtime.builtinDefinitions(false));
            try std.testing.expect(decision.approved);
            try std.testing.expectEqualStrings("tool_reviewed", decision.event_type);
        },
        1 => {
            const name = try std.fmt.allocPrint(std.testing.allocator, "unknown_tool_{d}", .{index});
            defer std.testing.allocator.free(name);
            const decision = VAR1.core.tool_runtime.review.reviewToolName(name, VAR1.core.tool_runtime.builtinDefinitions(true));
            try std.testing.expect(!decision.approved);
            try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.unknown_high_impact, decision.risk);
            try std.testing.expect(decision.tool_error_hint != null);
        },
        2 => {
            const name = agent_names[index % agent_names.len];
            const decision = VAR1.core.tool_runtime.review.reviewToolName(name, VAR1.core.tool_runtime.builtinDefinitions(true));
            try std.testing.expect(decision.approved);
            try std.testing.expectEqualStrings("tool_reviewed", decision.event_type);
            try std.testing.expect(!std.mem.eql(u8, VAR1.core.tool_runtime.toolCallLogLabel(name), name));
        },
        3 => {
            const blocked = VAR1.core.tool_runtime.review.reviewToolName("init_workspace", VAR1.core.tool_runtime.builtinDefinitions(false));
            try std.testing.expect(!blocked.approved);
            const available = VAR1.core.tool_runtime.review.reviewToolName("init_workspace", VAR1.core.tool_runtime.builtinDefinitionsForContext(.{
                .workspace_root = ".",
                .workspace_state_enabled = true,
            }));
            try std.testing.expect(available.approved);
        },
        4 => {
            const hint = VAR1.core.tool_runtime.toolErrorHint("todo_slice", "InvalidArguments").?;
            try expectContains(hint, "todo_slice");
            try expectContains(hint, "category");
        },
        5 => {
            const hint = VAR1.core.tool_runtime.toolErrorHint("read_file", "FileNotFound").?;
            try expectContains(hint, "list_files");
        },
        6 => {
            const hint = VAR1.core.tool_runtime.toolErrorHint("search_files", "ToolUnavailable").?;
            try expectContains(hint, "iex");
        },
        7 => {
            const prompt = try std.fmt.allocPrint(std.testing.allocator, "Please update .var workspace state case {d}.", .{index});
            defer std.testing.allocator.free(prompt);
            try std.testing.expect(VAR1.core.tool_runtime.workspaceStateRelevant(prompt));
        },
        8 => {
            const prompt = try std.fmt.allocPrint(std.testing.allocator, "Count letters in strawberry case {d}.", .{index});
            defer std.testing.allocator.free(prompt);
            try std.testing.expect(!VAR1.core.tool_runtime.workspaceStateRelevant(prompt));
        },
        else => {
            const payload = try VAR1.core.tool_runtime.renderExecutionError(
                std.testing.allocator,
                "launch_agent",
                "UnsupportedDelegationScope",
                "{\"prompt\":\"expand\",\"scope_depth\":2}",
            );
            defer std.testing.allocator.free(payload);
            try expectContains(payload, "escalation_reason");
            try expectContains(payload, "parameters_schema");
        },
    }
}

fn verifyBridgeAccessCase(index: usize) !void {
    switch (index % 10) {
        0 => {
            const origin = allowed_origins[index % allowed_origins.len];
            try std.testing.expectEqualStrings(origin, VAR1.host.bridge_access.allowedCorsOrigin(origin).?);
        },
        1 => {
            const origin = denied_origins[index % denied_origins.len];
            try std.testing.expect(VAR1.host.bridge_access.allowedCorsOrigin(origin) == null);
        },
        2 => {
            const expected = try std.fmt.allocPrint(std.testing.allocator, "token-{d}", .{index});
            defer std.testing.allocator.free(expected);
            const provided = if (index % 4 == 0) expected else "wrong-token";
            try std.testing.expectEqual(index % 4 == 0, VAR1.host.bridge_access.tokenValid(expected, provided));
            try std.testing.expect(!VAR1.host.bridge_access.tokenValid(expected, null));
        },
        3 => {
            const required = switch (index % 4) {
                0 => VAR1.host.bridge_access.isTokenRequired(.POST, "/rpc"),
                1 => VAR1.host.bridge_access.isTokenRequired(.GET, "/events"),
                2 => VAR1.host.bridge_access.isTokenRequired(.GET, "/rpc"),
                else => VAR1.host.bridge_access.isTokenRequired(.POST, "/events"),
            };
            try std.testing.expectEqual(index % 4 < 2, required);
        },
        4 => {
            const method = audited_methods[index % audited_methods.len];
            const action = VAR1.host.bridge_access.auditAction(method);
            if (std.mem.startsWith(u8, method, "auth/")) {
                try std.testing.expectEqualStrings("auth", action.?);
            } else if (std.mem.indexOf(u8, method, "session/") != null) {
                try std.testing.expect(action != null);
            } else {
                try std.testing.expect(action == null);
            }
        },
        5 => {
            const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"session_id\":\"session-{d}\",\"prompt\":\"next\"}}", .{index});
            defer std.testing.allocator.free(payload);
            const session_id = try VAR1.host.bridge_access.extractSessionId(std.testing.allocator, payload);
            defer if (session_id) |value| std.testing.allocator.free(value);
            const expected = try std.fmt.allocPrint(std.testing.allocator, "session-{d}", .{index});
            defer std.testing.allocator.free(expected);
            try std.testing.expectEqualStrings(expected, session_id.?);
        },
        6 => {
            const secret = switch (index % 3) {
                0 => "sk-live-secret",
                1 => "Bearer abc.def.ghi",
                else => "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            };
            const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"ok\":false,\"message\":\"provider returned {s}\",\"safe\":\"case-{d}\"}}", .{ secret, index });
            defer std.testing.allocator.free(payload);
            const redacted = try VAR1.host.bridge_access.redactAndAttachHandshake(std.testing.allocator, payload, "bridge-token");
            defer std.testing.allocator.free(redacted);
            try expectNotContains(redacted, secret);
            try expectContains(redacted, "\"message\":\"[redacted]\"");
            try expectContains(redacted, "\"bridge_token\":\"bridge-token\"");
        },
        7 => {
            const redacted = try VAR1.host.bridge_access.redactJsonPayload(std.testing.allocator, "not-json");
            defer std.testing.allocator.free(redacted);
            try expectContains(redacted, "InvalidBridgePayload");
        },
        8 => {
            const no_session = try VAR1.host.bridge_access.extractSessionId(std.testing.allocator, "{\"session_id\":42}");
            defer if (no_session) |value| std.testing.allocator.free(value);
            try std.testing.expect(no_session == null);
            const invalid = try VAR1.host.bridge_access.extractSessionId(std.testing.allocator, "not-json");
            defer if (invalid) |value| std.testing.allocator.free(value);
            try std.testing.expect(invalid == null);
        },
        else => {
            const payload = try VAR1.host.bridge_access.redactAndAttachHandshake(
                std.testing.allocator,
                "{\"ok\":true,\"api_key\":\"sk-secret\",\"nested\":{\"authorization\":\"Bearer abc\",\"safe\":\"value\"}}",
                "token-1",
            );
            defer std.testing.allocator.free(payload);
            try expectNotContains(payload, "sk-secret");
            try expectNotContains(payload, "Bearer abc");
            try expectContains(payload, "\"api_key\":\"[redacted]\"");
            try expectContains(payload, "\"authorization\":\"[redacted]\"");
        },
    }
}

test "pipeline matrix overflow classifier case 001" {
    try verifyOverflowCase(0);
}
test "pipeline matrix overflow classifier case 002" {
    try verifyOverflowCase(1);
}
test "pipeline matrix overflow classifier case 003" {
    try verifyOverflowCase(2);
}
test "pipeline matrix overflow classifier case 004" {
    try verifyOverflowCase(3);
}
test "pipeline matrix overflow classifier case 005" {
    try verifyOverflowCase(4);
}
test "pipeline matrix overflow classifier case 006" {
    try verifyOverflowCase(5);
}
test "pipeline matrix overflow classifier case 007" {
    try verifyOverflowCase(6);
}
test "pipeline matrix overflow classifier case 008" {
    try verifyOverflowCase(7);
}
test "pipeline matrix overflow classifier case 009" {
    try verifyOverflowCase(8);
}
test "pipeline matrix overflow classifier case 010" {
    try verifyOverflowCase(9);
}
test "pipeline matrix overflow classifier case 011" {
    try verifyOverflowCase(10);
}
test "pipeline matrix overflow classifier case 012" {
    try verifyOverflowCase(11);
}
test "pipeline matrix overflow classifier case 013" {
    try verifyOverflowCase(12);
}
test "pipeline matrix overflow classifier case 014" {
    try verifyOverflowCase(13);
}
test "pipeline matrix overflow classifier case 015" {
    try verifyOverflowCase(14);
}
test "pipeline matrix overflow classifier case 016" {
    try verifyOverflowCase(15);
}
test "pipeline matrix overflow classifier case 017" {
    try verifyOverflowCase(16);
}
test "pipeline matrix overflow classifier case 018" {
    try verifyOverflowCase(17);
}
test "pipeline matrix overflow classifier case 019" {
    try verifyOverflowCase(18);
}
test "pipeline matrix overflow classifier case 020" {
    try verifyOverflowCase(19);
}
test "pipeline matrix overflow classifier case 021" {
    try verifyOverflowCase(20);
}
test "pipeline matrix overflow classifier case 022" {
    try verifyOverflowCase(21);
}
test "pipeline matrix overflow classifier case 023" {
    try verifyOverflowCase(22);
}
test "pipeline matrix overflow classifier case 024" {
    try verifyOverflowCase(23);
}
test "pipeline matrix overflow classifier case 025" {
    try verifyOverflowCase(24);
}
test "pipeline matrix overflow classifier case 026" {
    try verifyOverflowCase(25);
}
test "pipeline matrix overflow classifier case 027" {
    try verifyOverflowCase(26);
}
test "pipeline matrix overflow classifier case 028" {
    try verifyOverflowCase(27);
}
test "pipeline matrix overflow classifier case 029" {
    try verifyOverflowCase(28);
}
test "pipeline matrix overflow classifier case 030" {
    try verifyOverflowCase(29);
}
test "pipeline matrix overflow classifier case 031" {
    try verifyOverflowCase(30);
}
test "pipeline matrix overflow classifier case 032" {
    try verifyOverflowCase(31);
}
test "pipeline matrix overflow classifier case 033" {
    try verifyOverflowCase(32);
}
test "pipeline matrix overflow classifier case 034" {
    try verifyOverflowCase(33);
}
test "pipeline matrix overflow classifier case 035" {
    try verifyOverflowCase(34);
}
test "pipeline matrix overflow classifier case 036" {
    try verifyOverflowCase(35);
}
test "pipeline matrix overflow classifier case 037" {
    try verifyOverflowCase(36);
}
test "pipeline matrix overflow classifier case 038" {
    try verifyOverflowCase(37);
}
test "pipeline matrix overflow classifier case 039" {
    try verifyOverflowCase(38);
}
test "pipeline matrix overflow classifier case 040" {
    try verifyOverflowCase(39);
}
test "pipeline matrix overflow classifier case 041" {
    try verifyOverflowCase(40);
}
test "pipeline matrix overflow classifier case 042" {
    try verifyOverflowCase(41);
}
test "pipeline matrix overflow classifier case 043" {
    try verifyOverflowCase(42);
}
test "pipeline matrix overflow classifier case 044" {
    try verifyOverflowCase(43);
}
test "pipeline matrix overflow classifier case 045" {
    try verifyOverflowCase(44);
}
test "pipeline matrix overflow classifier case 046" {
    try verifyOverflowCase(45);
}
test "pipeline matrix overflow classifier case 047" {
    try verifyOverflowCase(46);
}
test "pipeline matrix overflow classifier case 048" {
    try verifyOverflowCase(47);
}
test "pipeline matrix overflow classifier case 049" {
    try verifyOverflowCase(48);
}
test "pipeline matrix overflow classifier case 050" {
    try verifyOverflowCase(49);
}

test "pipeline matrix context budget case 001" {
    try verifyBudgetCase(0);
}
test "pipeline matrix context budget case 002" {
    try verifyBudgetCase(1);
}
test "pipeline matrix context budget case 003" {
    try verifyBudgetCase(2);
}
test "pipeline matrix context budget case 004" {
    try verifyBudgetCase(3);
}
test "pipeline matrix context budget case 005" {
    try verifyBudgetCase(4);
}
test "pipeline matrix context budget case 006" {
    try verifyBudgetCase(5);
}
test "pipeline matrix context budget case 007" {
    try verifyBudgetCase(6);
}
test "pipeline matrix context budget case 008" {
    try verifyBudgetCase(7);
}
test "pipeline matrix context budget case 009" {
    try verifyBudgetCase(8);
}
test "pipeline matrix context budget case 010" {
    try verifyBudgetCase(9);
}
test "pipeline matrix context budget case 011" {
    try verifyBudgetCase(10);
}
test "pipeline matrix context budget case 012" {
    try verifyBudgetCase(11);
}
test "pipeline matrix context budget case 013" {
    try verifyBudgetCase(12);
}
test "pipeline matrix context budget case 014" {
    try verifyBudgetCase(13);
}
test "pipeline matrix context budget case 015" {
    try verifyBudgetCase(14);
}
test "pipeline matrix context budget case 016" {
    try verifyBudgetCase(15);
}
test "pipeline matrix context budget case 017" {
    try verifyBudgetCase(16);
}
test "pipeline matrix context budget case 018" {
    try verifyBudgetCase(17);
}
test "pipeline matrix context budget case 019" {
    try verifyBudgetCase(18);
}
test "pipeline matrix context budget case 020" {
    try verifyBudgetCase(19);
}
test "pipeline matrix context budget case 021" {
    try verifyBudgetCase(20);
}
test "pipeline matrix context budget case 022" {
    try verifyBudgetCase(21);
}
test "pipeline matrix context budget case 023" {
    try verifyBudgetCase(22);
}
test "pipeline matrix context budget case 024" {
    try verifyBudgetCase(23);
}
test "pipeline matrix context budget case 025" {
    try verifyBudgetCase(24);
}
test "pipeline matrix context budget case 026" {
    try verifyBudgetCase(25);
}
test "pipeline matrix context budget case 027" {
    try verifyBudgetCase(26);
}
test "pipeline matrix context budget case 028" {
    try verifyBudgetCase(27);
}
test "pipeline matrix context budget case 029" {
    try verifyBudgetCase(28);
}
test "pipeline matrix context budget case 030" {
    try verifyBudgetCase(29);
}
test "pipeline matrix context budget case 031" {
    try verifyBudgetCase(30);
}
test "pipeline matrix context budget case 032" {
    try verifyBudgetCase(31);
}
test "pipeline matrix context budget case 033" {
    try verifyBudgetCase(32);
}
test "pipeline matrix context budget case 034" {
    try verifyBudgetCase(33);
}
test "pipeline matrix context budget case 035" {
    try verifyBudgetCase(34);
}
test "pipeline matrix context budget case 036" {
    try verifyBudgetCase(35);
}
test "pipeline matrix context budget case 037" {
    try verifyBudgetCase(36);
}
test "pipeline matrix context budget case 038" {
    try verifyBudgetCase(37);
}
test "pipeline matrix context budget case 039" {
    try verifyBudgetCase(38);
}
test "pipeline matrix context budget case 040" {
    try verifyBudgetCase(39);
}
test "pipeline matrix context budget case 041" {
    try verifyBudgetCase(40);
}
test "pipeline matrix context budget case 042" {
    try verifyBudgetCase(41);
}
test "pipeline matrix context budget case 043" {
    try verifyBudgetCase(42);
}
test "pipeline matrix context budget case 044" {
    try verifyBudgetCase(43);
}
test "pipeline matrix context budget case 045" {
    try verifyBudgetCase(44);
}
test "pipeline matrix context budget case 046" {
    try verifyBudgetCase(45);
}
test "pipeline matrix context budget case 047" {
    try verifyBudgetCase(46);
}
test "pipeline matrix context budget case 048" {
    try verifyBudgetCase(47);
}
test "pipeline matrix context budget case 049" {
    try verifyBudgetCase(48);
}
test "pipeline matrix context budget case 050" {
    try verifyBudgetCase(49);
}

test "pipeline matrix tool socket case 001" {
    try verifySocketCase(0);
}
test "pipeline matrix tool socket case 002" {
    try verifySocketCase(1);
}
test "pipeline matrix tool socket case 003" {
    try verifySocketCase(2);
}
test "pipeline matrix tool socket case 004" {
    try verifySocketCase(3);
}
test "pipeline matrix tool socket case 005" {
    try verifySocketCase(4);
}
test "pipeline matrix tool socket case 006" {
    try verifySocketCase(5);
}
test "pipeline matrix tool socket case 007" {
    try verifySocketCase(6);
}
test "pipeline matrix tool socket case 008" {
    try verifySocketCase(7);
}
test "pipeline matrix tool socket case 009" {
    try verifySocketCase(8);
}
test "pipeline matrix tool socket case 010" {
    try verifySocketCase(9);
}
test "pipeline matrix tool socket case 011" {
    try verifySocketCase(10);
}
test "pipeline matrix tool socket case 012" {
    try verifySocketCase(11);
}
test "pipeline matrix tool socket case 013" {
    try verifySocketCase(12);
}
test "pipeline matrix tool socket case 014" {
    try verifySocketCase(13);
}
test "pipeline matrix tool socket case 015" {
    try verifySocketCase(14);
}
test "pipeline matrix tool socket case 016" {
    try verifySocketCase(15);
}
test "pipeline matrix tool socket case 017" {
    try verifySocketCase(16);
}
test "pipeline matrix tool socket case 018" {
    try verifySocketCase(17);
}
test "pipeline matrix tool socket case 019" {
    try verifySocketCase(18);
}
test "pipeline matrix tool socket case 020" {
    try verifySocketCase(19);
}
test "pipeline matrix tool socket case 021" {
    try verifySocketCase(20);
}
test "pipeline matrix tool socket case 022" {
    try verifySocketCase(21);
}
test "pipeline matrix tool socket case 023" {
    try verifySocketCase(22);
}
test "pipeline matrix tool socket case 024" {
    try verifySocketCase(23);
}
test "pipeline matrix tool socket case 025" {
    try verifySocketCase(24);
}
test "pipeline matrix tool socket case 026" {
    try verifySocketCase(25);
}
test "pipeline matrix tool socket case 027" {
    try verifySocketCase(26);
}
test "pipeline matrix tool socket case 028" {
    try verifySocketCase(27);
}
test "pipeline matrix tool socket case 029" {
    try verifySocketCase(28);
}
test "pipeline matrix tool socket case 030" {
    try verifySocketCase(29);
}
test "pipeline matrix tool socket case 031" {
    try verifySocketCase(30);
}
test "pipeline matrix tool socket case 032" {
    try verifySocketCase(31);
}
test "pipeline matrix tool socket case 033" {
    try verifySocketCase(32);
}
test "pipeline matrix tool socket case 034" {
    try verifySocketCase(33);
}
test "pipeline matrix tool socket case 035" {
    try verifySocketCase(34);
}
test "pipeline matrix tool socket case 036" {
    try verifySocketCase(35);
}
test "pipeline matrix tool socket case 037" {
    try verifySocketCase(36);
}
test "pipeline matrix tool socket case 038" {
    try verifySocketCase(37);
}
test "pipeline matrix tool socket case 039" {
    try verifySocketCase(38);
}
test "pipeline matrix tool socket case 040" {
    try verifySocketCase(39);
}
test "pipeline matrix tool socket case 041" {
    try verifySocketCase(40);
}
test "pipeline matrix tool socket case 042" {
    try verifySocketCase(41);
}
test "pipeline matrix tool socket case 043" {
    try verifySocketCase(42);
}
test "pipeline matrix tool socket case 044" {
    try verifySocketCase(43);
}
test "pipeline matrix tool socket case 045" {
    try verifySocketCase(44);
}
test "pipeline matrix tool socket case 046" {
    try verifySocketCase(45);
}
test "pipeline matrix tool socket case 047" {
    try verifySocketCase(46);
}
test "pipeline matrix tool socket case 048" {
    try verifySocketCase(47);
}
test "pipeline matrix tool socket case 049" {
    try verifySocketCase(48);
}
test "pipeline matrix tool socket case 050" {
    try verifySocketCase(49);
}

test "pipeline matrix plugin manifest case 001" {
    try verifyPluginManifestCase(0);
}
test "pipeline matrix plugin manifest case 002" {
    try verifyPluginManifestCase(1);
}
test "pipeline matrix plugin manifest case 003" {
    try verifyPluginManifestCase(2);
}
test "pipeline matrix plugin manifest case 004" {
    try verifyPluginManifestCase(3);
}
test "pipeline matrix plugin manifest case 005" {
    try verifyPluginManifestCase(4);
}
test "pipeline matrix plugin manifest case 006" {
    try verifyPluginManifestCase(5);
}
test "pipeline matrix plugin manifest case 007" {
    try verifyPluginManifestCase(6);
}
test "pipeline matrix plugin manifest case 008" {
    try verifyPluginManifestCase(7);
}
test "pipeline matrix plugin manifest case 009" {
    try verifyPluginManifestCase(8);
}
test "pipeline matrix plugin manifest case 010" {
    try verifyPluginManifestCase(9);
}
test "pipeline matrix plugin manifest case 011" {
    try verifyPluginManifestCase(10);
}
test "pipeline matrix plugin manifest case 012" {
    try verifyPluginManifestCase(11);
}
test "pipeline matrix plugin manifest case 013" {
    try verifyPluginManifestCase(12);
}
test "pipeline matrix plugin manifest case 014" {
    try verifyPluginManifestCase(13);
}
test "pipeline matrix plugin manifest case 015" {
    try verifyPluginManifestCase(14);
}
test "pipeline matrix plugin manifest case 016" {
    try verifyPluginManifestCase(15);
}
test "pipeline matrix plugin manifest case 017" {
    try verifyPluginManifestCase(16);
}
test "pipeline matrix plugin manifest case 018" {
    try verifyPluginManifestCase(17);
}
test "pipeline matrix plugin manifest case 019" {
    try verifyPluginManifestCase(18);
}
test "pipeline matrix plugin manifest case 020" {
    try verifyPluginManifestCase(19);
}
test "pipeline matrix plugin manifest case 021" {
    try verifyPluginManifestCase(20);
}
test "pipeline matrix plugin manifest case 022" {
    try verifyPluginManifestCase(21);
}
test "pipeline matrix plugin manifest case 023" {
    try verifyPluginManifestCase(22);
}
test "pipeline matrix plugin manifest case 024" {
    try verifyPluginManifestCase(23);
}
test "pipeline matrix plugin manifest case 025" {
    try verifyPluginManifestCase(24);
}
test "pipeline matrix plugin manifest case 026" {
    try verifyPluginManifestCase(25);
}
test "pipeline matrix plugin manifest case 027" {
    try verifyPluginManifestCase(26);
}
test "pipeline matrix plugin manifest case 028" {
    try verifyPluginManifestCase(27);
}
test "pipeline matrix plugin manifest case 029" {
    try verifyPluginManifestCase(28);
}
test "pipeline matrix plugin manifest case 030" {
    try verifyPluginManifestCase(29);
}
test "pipeline matrix plugin manifest case 031" {
    try verifyPluginManifestCase(30);
}
test "pipeline matrix plugin manifest case 032" {
    try verifyPluginManifestCase(31);
}
test "pipeline matrix plugin manifest case 033" {
    try verifyPluginManifestCase(32);
}
test "pipeline matrix plugin manifest case 034" {
    try verifyPluginManifestCase(33);
}
test "pipeline matrix plugin manifest case 035" {
    try verifyPluginManifestCase(34);
}
test "pipeline matrix plugin manifest case 036" {
    try verifyPluginManifestCase(35);
}
test "pipeline matrix plugin manifest case 037" {
    try verifyPluginManifestCase(36);
}
test "pipeline matrix plugin manifest case 038" {
    try verifyPluginManifestCase(37);
}
test "pipeline matrix plugin manifest case 039" {
    try verifyPluginManifestCase(38);
}
test "pipeline matrix plugin manifest case 040" {
    try verifyPluginManifestCase(39);
}
test "pipeline matrix plugin manifest case 041" {
    try verifyPluginManifestCase(40);
}
test "pipeline matrix plugin manifest case 042" {
    try verifyPluginManifestCase(41);
}
test "pipeline matrix plugin manifest case 043" {
    try verifyPluginManifestCase(42);
}
test "pipeline matrix plugin manifest case 044" {
    try verifyPluginManifestCase(43);
}
test "pipeline matrix plugin manifest case 045" {
    try verifyPluginManifestCase(44);
}
test "pipeline matrix plugin manifest case 046" {
    try verifyPluginManifestCase(45);
}
test "pipeline matrix plugin manifest case 047" {
    try verifyPluginManifestCase(46);
}
test "pipeline matrix plugin manifest case 048" {
    try verifyPluginManifestCase(47);
}
test "pipeline matrix plugin manifest case 049" {
    try verifyPluginManifestCase(48);
}
test "pipeline matrix plugin manifest case 050" {
    try verifyPluginManifestCase(49);
}

test "pipeline matrix tool runtime case 001" {
    try verifyToolRuntimeCase(0);
}
test "pipeline matrix tool runtime case 002" {
    try verifyToolRuntimeCase(1);
}
test "pipeline matrix tool runtime case 003" {
    try verifyToolRuntimeCase(2);
}
test "pipeline matrix tool runtime case 004" {
    try verifyToolRuntimeCase(3);
}
test "pipeline matrix tool runtime case 005" {
    try verifyToolRuntimeCase(4);
}
test "pipeline matrix tool runtime case 006" {
    try verifyToolRuntimeCase(5);
}
test "pipeline matrix tool runtime case 007" {
    try verifyToolRuntimeCase(6);
}
test "pipeline matrix tool runtime case 008" {
    try verifyToolRuntimeCase(7);
}
test "pipeline matrix tool runtime case 009" {
    try verifyToolRuntimeCase(8);
}
test "pipeline matrix tool runtime case 010" {
    try verifyToolRuntimeCase(9);
}
test "pipeline matrix tool runtime case 011" {
    try verifyToolRuntimeCase(10);
}
test "pipeline matrix tool runtime case 012" {
    try verifyToolRuntimeCase(11);
}
test "pipeline matrix tool runtime case 013" {
    try verifyToolRuntimeCase(12);
}
test "pipeline matrix tool runtime case 014" {
    try verifyToolRuntimeCase(13);
}
test "pipeline matrix tool runtime case 015" {
    try verifyToolRuntimeCase(14);
}
test "pipeline matrix tool runtime case 016" {
    try verifyToolRuntimeCase(15);
}
test "pipeline matrix tool runtime case 017" {
    try verifyToolRuntimeCase(16);
}
test "pipeline matrix tool runtime case 018" {
    try verifyToolRuntimeCase(17);
}
test "pipeline matrix tool runtime case 019" {
    try verifyToolRuntimeCase(18);
}
test "pipeline matrix tool runtime case 020" {
    try verifyToolRuntimeCase(19);
}
test "pipeline matrix tool runtime case 021" {
    try verifyToolRuntimeCase(20);
}
test "pipeline matrix tool runtime case 022" {
    try verifyToolRuntimeCase(21);
}
test "pipeline matrix tool runtime case 023" {
    try verifyToolRuntimeCase(22);
}
test "pipeline matrix tool runtime case 024" {
    try verifyToolRuntimeCase(23);
}
test "pipeline matrix tool runtime case 025" {
    try verifyToolRuntimeCase(24);
}
test "pipeline matrix tool runtime case 026" {
    try verifyToolRuntimeCase(25);
}
test "pipeline matrix tool runtime case 027" {
    try verifyToolRuntimeCase(26);
}
test "pipeline matrix tool runtime case 028" {
    try verifyToolRuntimeCase(27);
}
test "pipeline matrix tool runtime case 029" {
    try verifyToolRuntimeCase(28);
}
test "pipeline matrix tool runtime case 030" {
    try verifyToolRuntimeCase(29);
}
test "pipeline matrix tool runtime case 031" {
    try verifyToolRuntimeCase(30);
}
test "pipeline matrix tool runtime case 032" {
    try verifyToolRuntimeCase(31);
}
test "pipeline matrix tool runtime case 033" {
    try verifyToolRuntimeCase(32);
}
test "pipeline matrix tool runtime case 034" {
    try verifyToolRuntimeCase(33);
}
test "pipeline matrix tool runtime case 035" {
    try verifyToolRuntimeCase(34);
}
test "pipeline matrix tool runtime case 036" {
    try verifyToolRuntimeCase(35);
}
test "pipeline matrix tool runtime case 037" {
    try verifyToolRuntimeCase(36);
}
test "pipeline matrix tool runtime case 038" {
    try verifyToolRuntimeCase(37);
}
test "pipeline matrix tool runtime case 039" {
    try verifyToolRuntimeCase(38);
}
test "pipeline matrix tool runtime case 040" {
    try verifyToolRuntimeCase(39);
}
test "pipeline matrix tool runtime case 041" {
    try verifyToolRuntimeCase(40);
}
test "pipeline matrix tool runtime case 042" {
    try verifyToolRuntimeCase(41);
}
test "pipeline matrix tool runtime case 043" {
    try verifyToolRuntimeCase(42);
}
test "pipeline matrix tool runtime case 044" {
    try verifyToolRuntimeCase(43);
}
test "pipeline matrix tool runtime case 045" {
    try verifyToolRuntimeCase(44);
}
test "pipeline matrix tool runtime case 046" {
    try verifyToolRuntimeCase(45);
}
test "pipeline matrix tool runtime case 047" {
    try verifyToolRuntimeCase(46);
}
test "pipeline matrix tool runtime case 048" {
    try verifyToolRuntimeCase(47);
}
test "pipeline matrix tool runtime case 049" {
    try verifyToolRuntimeCase(48);
}
test "pipeline matrix tool runtime case 050" {
    try verifyToolRuntimeCase(49);
}

test "pipeline matrix bridge access case 001" {
    try verifyBridgeAccessCase(0);
}
test "pipeline matrix bridge access case 002" {
    try verifyBridgeAccessCase(1);
}
test "pipeline matrix bridge access case 003" {
    try verifyBridgeAccessCase(2);
}
test "pipeline matrix bridge access case 004" {
    try verifyBridgeAccessCase(3);
}
test "pipeline matrix bridge access case 005" {
    try verifyBridgeAccessCase(4);
}
test "pipeline matrix bridge access case 006" {
    try verifyBridgeAccessCase(5);
}
test "pipeline matrix bridge access case 007" {
    try verifyBridgeAccessCase(6);
}
test "pipeline matrix bridge access case 008" {
    try verifyBridgeAccessCase(7);
}
test "pipeline matrix bridge access case 009" {
    try verifyBridgeAccessCase(8);
}
test "pipeline matrix bridge access case 010" {
    try verifyBridgeAccessCase(9);
}
test "pipeline matrix bridge access case 011" {
    try verifyBridgeAccessCase(10);
}
test "pipeline matrix bridge access case 012" {
    try verifyBridgeAccessCase(11);
}
test "pipeline matrix bridge access case 013" {
    try verifyBridgeAccessCase(12);
}
test "pipeline matrix bridge access case 014" {
    try verifyBridgeAccessCase(13);
}
test "pipeline matrix bridge access case 015" {
    try verifyBridgeAccessCase(14);
}
test "pipeline matrix bridge access case 016" {
    try verifyBridgeAccessCase(15);
}
test "pipeline matrix bridge access case 017" {
    try verifyBridgeAccessCase(16);
}
test "pipeline matrix bridge access case 018" {
    try verifyBridgeAccessCase(17);
}
test "pipeline matrix bridge access case 019" {
    try verifyBridgeAccessCase(18);
}
test "pipeline matrix bridge access case 020" {
    try verifyBridgeAccessCase(19);
}
test "pipeline matrix bridge access case 021" {
    try verifyBridgeAccessCase(20);
}
test "pipeline matrix bridge access case 022" {
    try verifyBridgeAccessCase(21);
}
test "pipeline matrix bridge access case 023" {
    try verifyBridgeAccessCase(22);
}
test "pipeline matrix bridge access case 024" {
    try verifyBridgeAccessCase(23);
}
test "pipeline matrix bridge access case 025" {
    try verifyBridgeAccessCase(24);
}
test "pipeline matrix bridge access case 026" {
    try verifyBridgeAccessCase(25);
}
test "pipeline matrix bridge access case 027" {
    try verifyBridgeAccessCase(26);
}
test "pipeline matrix bridge access case 028" {
    try verifyBridgeAccessCase(27);
}
test "pipeline matrix bridge access case 029" {
    try verifyBridgeAccessCase(28);
}
test "pipeline matrix bridge access case 030" {
    try verifyBridgeAccessCase(29);
}
test "pipeline matrix bridge access case 031" {
    try verifyBridgeAccessCase(30);
}
test "pipeline matrix bridge access case 032" {
    try verifyBridgeAccessCase(31);
}
test "pipeline matrix bridge access case 033" {
    try verifyBridgeAccessCase(32);
}
test "pipeline matrix bridge access case 034" {
    try verifyBridgeAccessCase(33);
}
test "pipeline matrix bridge access case 035" {
    try verifyBridgeAccessCase(34);
}
test "pipeline matrix bridge access case 036" {
    try verifyBridgeAccessCase(35);
}
test "pipeline matrix bridge access case 037" {
    try verifyBridgeAccessCase(36);
}
test "pipeline matrix bridge access case 038" {
    try verifyBridgeAccessCase(37);
}
test "pipeline matrix bridge access case 039" {
    try verifyBridgeAccessCase(38);
}
test "pipeline matrix bridge access case 040" {
    try verifyBridgeAccessCase(39);
}
test "pipeline matrix bridge access case 041" {
    try verifyBridgeAccessCase(40);
}
test "pipeline matrix bridge access case 042" {
    try verifyBridgeAccessCase(41);
}
test "pipeline matrix bridge access case 043" {
    try verifyBridgeAccessCase(42);
}
test "pipeline matrix bridge access case 044" {
    try verifyBridgeAccessCase(43);
}
test "pipeline matrix bridge access case 045" {
    try verifyBridgeAccessCase(44);
}
test "pipeline matrix bridge access case 046" {
    try verifyBridgeAccessCase(45);
}
test "pipeline matrix bridge access case 047" {
    try verifyBridgeAccessCase(46);
}
test "pipeline matrix bridge access case 048" {
    try verifyBridgeAccessCase(47);
}
test "pipeline matrix bridge access case 049" {
    try verifyBridgeAccessCase(48);
}
test "pipeline matrix bridge access case 050" {
    try verifyBridgeAccessCase(49);
}
