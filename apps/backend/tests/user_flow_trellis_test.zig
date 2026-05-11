const std = @import("std");
const VAR1 = @import("VAR1");

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn makeToolCall(name: []const u8, arguments_json: []const u8) !VAR1.shared.types.ToolCall {
    return .{
        .id = try std.testing.allocator.dupe(u8, "call-1"),
        .name = try std.testing.allocator.dupe(u8, name),
        .arguments_json = try std.testing.allocator.dupe(u8, arguments_json),
    };
}

fn owned(value: []const u8) ![]u8 {
    return try std.testing.allocator.dupe(u8, value);
}

fn verifyUserFlowTrellisCase(index: usize) !void {
    switch (index % 23) {
        0 => try verifySessionRunningEnvelope(index),
        1 => try verifySessionFailureEnvelope(index),
        2 => try verifyKernelErrorEnvelope(index),
        3 => try verifyKernelTransportEnvelope(index),
        4 => try verifyPromptInputInline(index),
        5 => try verifyPromptInputEmptyResume(index),
        6 => try verifySessionListProjection(index),
        7 => try verifyToolCatalogJson(index),
        8 => try verifyToolCatalogText(index),
        9 => try verifyToolReviewKnown(index),
        10 => try verifyToolReviewUnknown(index),
        11 => try verifyToolHint(index),
        12 => try verifyToolExecutionError(index),
        13 => try verifyToolCallSummary(index),
        14 => try verifyWorkspaceStateRelevance(index),
        15 => try verifyBridgeCors(index),
        16 => try verifyBridgeToken(index),
        17 => try verifyBridgeSessionId(index),
        18 => try verifyBridgeRedaction(index),
        19 => try verifyBridgeAuditAction(index),
        20 => try verifyHelpSurface(index),
        21 => try verifyHealthShape(index),
        else => try verifySessionListEmptyWorkspace(index),
    }
}

fn verifySessionRunningEnvelope(index: usize) !void {
    const session_id = try std.fmt.allocPrint(std.testing.allocator, "session-trellis-{d}-running", .{index});
    defer std.testing.allocator.free(session_id);
    const envelope = try VAR1.clients.cli.renderSessionRunningEnvelope(std.testing.allocator, session_id);
    defer std.testing.allocator.free(envelope);
    try expectContains(envelope, "VAR1_STATUS category=session code=Running");
    try expectContains(envelope, "provider execution started");
    try expectContains(envelope, session_id);
    try expectNotContains(envelope, "VAR1_ERROR");
}

fn verifySessionFailureEnvelope(index: usize) !void {
    const session_id = try std.fmt.allocPrint(std.testing.allocator, "session-trellis-{d}-failed", .{index});
    defer std.testing.allocator.free(session_id);
    const reason = switch (index % 5) {
        0 => "BadStatus",
        1 => "ToolBudgetExceeded",
        2 => "ContextOverflow",
        3 => "TerminalUnavailable",
        else => "UnresolvedToolCallTranscript",
    };
    const envelope = try VAR1.clients.cli.renderSessionFailureEnvelope(std.testing.allocator, session_id, reason);
    defer std.testing.allocator.free(envelope);
    try expectContains(envelope, "VAR1_ERROR category=session");
    try expectContains(envelope, reason);
    try expectContains(envelope, session_id);
}

fn verifyKernelErrorEnvelope(index: usize) !void {
    const source = switch (index % 4) {
        0 => "{\"code\":-32001,\"message\":\"Session not found\"}",
        1 => "{\"code\":-32602,\"message\":\"Invalid params\"}",
        2 => "{\"message\":\"kernel returned a typed failure\"}",
        else => "{",
    };
    const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, source);
    defer std.testing.allocator.free(envelope);
    try expectContains(envelope, "VAR1_ERROR category=kernel_rpc");
    try expectNotContains(envelope, "panic");
}

fn verifyKernelTransportEnvelope(index: usize) !void {
    const err = switch (index % 4) {
        0 => error.InvalidRpcResponse,
        1 => error.BrokenPipe,
        2 => error.ConnectionResetByPeer,
        else => error.EndOfStream,
    };
    const envelope = try VAR1.clients.cli.renderKernelTransportErrorEnvelope(std.testing.allocator, err);
    defer std.testing.allocator.free(envelope);
    try expectContains(envelope, "VAR1_ERROR category=kernel_transport");
    try expectContains(envelope, @errorName(err));
}

fn verifyPromptInputInline(index: usize) !void {
    const prompt = try std.fmt.allocPrint(std.testing.allocator, "inline prompt case {d}", .{index});
    defer std.testing.allocator.free(prompt);
    const resolved = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, prompt, null);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(prompt, resolved);
}

fn verifyPromptInputEmptyResume(_: usize) !void {
    const resolved = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, null, null);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("", resolved);
}

fn verifySessionListProjection(index: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "resume visible transcript");
    defer session.deinit(std.testing.allocator);
    const output = try std.fmt.allocPrint(std.testing.allocator, "assistant output survives trellis case {d}", .{index});
    defer std.testing.allocator.free(output);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, output);
    const rendered = try VAR1.clients.cli.renderSessionListJson(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(rendered);
    try expectContains(rendered, session.id);
    try expectContains(rendered, output);
}

fn verifyToolCatalogJson(index: usize) !void {
    const ctx = VAR1.core.tool_runtime.ExecutionContext{ .workspace_root = "E:\\Workspaces\\Case" };
    const catalog = try VAR1.core.tool_runtime.renderCatalogJson(std.testing.allocator, ctx);
    defer std.testing.allocator.free(catalog);
    try expectContains(catalog, "\"tools\"");
    try expectContains(catalog, "shell_exec");
    if (index % 2 == 0) try expectContains(catalog, "parameters_schema");
}

fn verifyToolCatalogText(_: usize) !void {
    const ctx = VAR1.core.tool_runtime.ExecutionContext{ .workspace_root = "E:\\Workspaces\\Case" };
    const catalog = try VAR1.core.tool_runtime.renderCatalog(std.testing.allocator, ctx);
    defer std.testing.allocator.free(catalog);
    try expectContains(catalog, "VAR1 built-in tools");
    try expectContains(catalog, "Call contract");
}

fn verifyToolReviewKnown(index: usize) !void {
    const names = [_][]const u8{ "read_file", "write_file", "shell_exec", "wait_agent" };
    const decision = VAR1.core.tool_runtime.review.reviewToolName(names[index % names.len], VAR1.core.tool_runtime.builtinDefinitions(true));
    try std.testing.expect(decision.approved);
    try std.testing.expectEqualStrings("tool_reviewed", decision.event_type);
}

fn verifyToolReviewUnknown(index: usize) !void {
    const name = try std.fmt.allocPrint(std.testing.allocator, "unknown_tool_{d}", .{index});
    defer std.testing.allocator.free(name);
    const decision = VAR1.core.tool_runtime.review.reviewToolName(name, VAR1.core.tool_runtime.builtinDefinitions(true));
    try std.testing.expect(!decision.approved);
    try std.testing.expect(decision.tool_error_hint != null);
}

fn verifyToolHint(index: usize) !void {
    const hint = switch (index % 4) {
        0 => VAR1.core.tool_runtime.toolErrorHint("read_file", "FileNotFound").?,
        1 => VAR1.core.tool_runtime.toolErrorHint("search_files", "ToolUnavailable").?,
        2 => VAR1.core.tool_runtime.toolErrorHint("shell_exec", "InvalidArguments").?,
        else => VAR1.core.tool_runtime.toolErrorHint("append_file", "ToolPayloadExceeded").?,
    };
    try std.testing.expect(hint.len > 8);
    try expectNotContains(hint, "undefined");
}

fn verifyToolExecutionError(index: usize) !void {
    const payload = switch (index % 4) {
        0 => try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "shell_exec", "CommandTimedOut", "{\"timeout_ms\":1}"),
        1 => try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "shell_exec", "PathOutsideWorkspace", "{\"cwd\":\"..\"}"),
        2 => try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "write_file", "ToolPayloadExceeded", "{\"path\":\"x\"}"),
        else => try VAR1.core.tool_runtime.renderExecutionError(std.testing.allocator, "launch_agent", "UnsupportedDelegationScope", "{\"prompt\":\"x\"}"),
    };
    defer std.testing.allocator.free(payload);
    try expectContains(payload, "\"ok\":false");
    try expectContains(payload, "arguments_json");
    if (index % 2 == 0) try expectContains(payload, "parameters_schema");
}

fn verifyToolCallSummary(index: usize) !void {
    var calls = [_]VAR1.shared.types.ToolCall{
        try makeToolCall("read_file", "{}"),
        try makeToolCall(if (index % 2 == 0) "read_file" else "shell_exec", "{}"),
    };
    defer for (calls) |call| call.deinit(std.testing.allocator);
    const summary = try VAR1.core.tool_runtime.renderToolCallSummary(std.testing.allocator, calls[0..]);
    defer std.testing.allocator.free(summary);
    try expectContains(summary, "read_file");
}

fn verifyWorkspaceStateRelevance(index: usize) !void {
    const prompt = if (index % 2 == 0) "update .var session record and changelog" else "count letters in strawberry";
    try std.testing.expectEqual(index % 2 == 0, VAR1.core.tool_runtime.workspaceStateRelevant(prompt));
}

fn verifyBridgeCors(index: usize) !void {
    const origin = if (index % 2 == 0) "http://127.0.0.1:4310" else "https://evil.example";
    const allowed = VAR1.host.bridge_access.allowedCorsOrigin(origin);
    try std.testing.expectEqual(index % 2 == 0, allowed != null);
}

fn verifyBridgeToken(index: usize) !void {
    const expected = try std.fmt.allocPrint(std.testing.allocator, "token-{d}", .{index});
    defer std.testing.allocator.free(expected);
    try std.testing.expect(VAR1.host.bridge_access.tokenValid(expected, expected));
    try std.testing.expect(!VAR1.host.bridge_access.tokenValid(expected, "wrong-token"));
    try std.testing.expect(!VAR1.host.bridge_access.tokenValid(expected, null));
}

fn verifyBridgeSessionId(index: usize) !void {
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"session_id\":\"session-{d}\",\"prompt\":\"next\"}}", .{index});
    defer std.testing.allocator.free(payload);
    const session_id = try VAR1.host.bridge_access.extractSessionId(std.testing.allocator, payload);
    defer if (session_id) |value| std.testing.allocator.free(value);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "session-{d}", .{index});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, session_id.?);
}

fn verifyBridgeRedaction(index: usize) !void {
    const secret = if (index % 2 == 0) "sk-live-secret" else "Bearer abc.def.ghi";
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"message\":\"provider returned {s}\",\"case\":{d}}}", .{ secret, index });
    defer std.testing.allocator.free(payload);
    const redacted = try VAR1.host.bridge_access.redactAndAttachHandshake(std.testing.allocator, payload, "bridge-token");
    defer std.testing.allocator.free(redacted);
    try expectNotContains(redacted, secret);
    try expectContains(redacted, "bridge-token");
}

fn verifyBridgeAuditAction(index: usize) !void {
    const method = switch (index % 5) {
        0 => VAR1.shared.protocol.types.methods.session_create,
        1 => VAR1.shared.protocol.types.methods.session_get,
        2 => VAR1.shared.protocol.types.methods.session_list,
        3 => "auth/login",
        else => "tools/list",
    };
    const action = VAR1.host.bridge_access.auditAction(method);
    if (index % 5 == 4) {
        try std.testing.expect(action == null);
    } else {
        try std.testing.expect(action != null);
    }
}

fn verifyHelpSurface(index: usize) !void {
    const help = VAR1.clients.cli.helpText(if (index % 3 == 0) null else if (index % 3 == 1) "run" else "c").?;
    try expectContains(help, "Usage:");
    try expectNotContains(help, "TODO");
}

fn verifyHealthShape(index: usize) !void {
    var config = VAR1.shared.types.Config{
        .workspace_root = try owned("E:\\Workspaces\\Case"),
        .openai_base_url = try owned("https://api.z.ai/api/coding/paas/v4"),
        .openai_api_key = try owned("test-key"),
        .openai_model = try owned(if (index % 2 == 0) "glm-5.1" else "qwen-coder"),
        .auth_provider = try owned("zai"),
        .subscription_plan_label = try owned("coding"),
        .subscription_status = try owned("active"),
        .max_steps = 512,
    };
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(config.openai_model.len > 0);
    try std.testing.expect(config.workspace_root.len > 0);
}

fn verifySessionListEmptyWorkspace(_: usize) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);
    const rendered = try VAR1.clients.cli.renderSessionListJson(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(rendered);
    try expectContains(rendered, "\"sessions\":[]");
}

test "user flow trellis case 001" {
    try verifyUserFlowTrellisCase(0);
}
test "user flow trellis case 002" {
    try verifyUserFlowTrellisCase(1);
}
test "user flow trellis case 003" {
    try verifyUserFlowTrellisCase(2);
}
test "user flow trellis case 004" {
    try verifyUserFlowTrellisCase(3);
}
test "user flow trellis case 005" {
    try verifyUserFlowTrellisCase(4);
}
test "user flow trellis case 006" {
    try verifyUserFlowTrellisCase(5);
}
test "user flow trellis case 007" {
    try verifyUserFlowTrellisCase(6);
}
test "user flow trellis case 008" {
    try verifyUserFlowTrellisCase(7);
}
test "user flow trellis case 009" {
    try verifyUserFlowTrellisCase(8);
}
test "user flow trellis case 010" {
    try verifyUserFlowTrellisCase(9);
}
test "user flow trellis case 011" {
    try verifyUserFlowTrellisCase(10);
}
test "user flow trellis case 012" {
    try verifyUserFlowTrellisCase(11);
}
test "user flow trellis case 013" {
    try verifyUserFlowTrellisCase(12);
}
test "user flow trellis case 014" {
    try verifyUserFlowTrellisCase(13);
}
test "user flow trellis case 015" {
    try verifyUserFlowTrellisCase(14);
}
test "user flow trellis case 016" {
    try verifyUserFlowTrellisCase(15);
}
test "user flow trellis case 017" {
    try verifyUserFlowTrellisCase(16);
}
test "user flow trellis case 018" {
    try verifyUserFlowTrellisCase(17);
}
test "user flow trellis case 019" {
    try verifyUserFlowTrellisCase(18);
}
test "user flow trellis case 020" {
    try verifyUserFlowTrellisCase(19);
}
test "user flow trellis case 021" {
    try verifyUserFlowTrellisCase(20);
}
test "user flow trellis case 022" {
    try verifyUserFlowTrellisCase(21);
}
test "user flow trellis case 023" {
    try verifyUserFlowTrellisCase(22);
}
test "user flow trellis case 024" {
    try verifyUserFlowTrellisCase(23);
}
test "user flow trellis case 025" {
    try verifyUserFlowTrellisCase(24);
}
test "user flow trellis case 026" {
    try verifyUserFlowTrellisCase(25);
}
test "user flow trellis case 027" {
    try verifyUserFlowTrellisCase(26);
}
test "user flow trellis case 028" {
    try verifyUserFlowTrellisCase(27);
}
test "user flow trellis case 029" {
    try verifyUserFlowTrellisCase(28);
}
test "user flow trellis case 030" {
    try verifyUserFlowTrellisCase(29);
}
test "user flow trellis case 031" {
    try verifyUserFlowTrellisCase(30);
}
test "user flow trellis case 032" {
    try verifyUserFlowTrellisCase(31);
}
test "user flow trellis case 033" {
    try verifyUserFlowTrellisCase(32);
}
test "user flow trellis case 034" {
    try verifyUserFlowTrellisCase(33);
}
test "user flow trellis case 035" {
    try verifyUserFlowTrellisCase(34);
}
test "user flow trellis case 036" {
    try verifyUserFlowTrellisCase(35);
}
test "user flow trellis case 037" {
    try verifyUserFlowTrellisCase(36);
}
test "user flow trellis case 038" {
    try verifyUserFlowTrellisCase(37);
}
test "user flow trellis case 039" {
    try verifyUserFlowTrellisCase(38);
}
test "user flow trellis case 040" {
    try verifyUserFlowTrellisCase(39);
}
test "user flow trellis case 041" {
    try verifyUserFlowTrellisCase(40);
}
test "user flow trellis case 042" {
    try verifyUserFlowTrellisCase(41);
}
test "user flow trellis case 043" {
    try verifyUserFlowTrellisCase(42);
}
test "user flow trellis case 044" {
    try verifyUserFlowTrellisCase(43);
}
test "user flow trellis case 045" {
    try verifyUserFlowTrellisCase(44);
}
test "user flow trellis case 046" {
    try verifyUserFlowTrellisCase(45);
}
test "user flow trellis case 047" {
    try verifyUserFlowTrellisCase(46);
}
test "user flow trellis case 048" {
    try verifyUserFlowTrellisCase(47);
}
test "user flow trellis case 049" {
    try verifyUserFlowTrellisCase(48);
}
test "user flow trellis case 050" {
    try verifyUserFlowTrellisCase(49);
}
test "user flow trellis case 051" {
    try verifyUserFlowTrellisCase(50);
}
test "user flow trellis case 052" {
    try verifyUserFlowTrellisCase(51);
}
test "user flow trellis case 053" {
    try verifyUserFlowTrellisCase(52);
}
test "user flow trellis case 054" {
    try verifyUserFlowTrellisCase(53);
}
test "user flow trellis case 055" {
    try verifyUserFlowTrellisCase(54);
}
test "user flow trellis case 056" {
    try verifyUserFlowTrellisCase(55);
}
test "user flow trellis case 057" {
    try verifyUserFlowTrellisCase(56);
}
test "user flow trellis case 058" {
    try verifyUserFlowTrellisCase(57);
}
test "user flow trellis case 059" {
    try verifyUserFlowTrellisCase(58);
}
test "user flow trellis case 060" {
    try verifyUserFlowTrellisCase(59);
}
test "user flow trellis case 061" {
    try verifyUserFlowTrellisCase(60);
}
test "user flow trellis case 062" {
    try verifyUserFlowTrellisCase(61);
}
test "user flow trellis case 063" {
    try verifyUserFlowTrellisCase(62);
}
test "user flow trellis case 064" {
    try verifyUserFlowTrellisCase(63);
}
test "user flow trellis case 065" {
    try verifyUserFlowTrellisCase(64);
}
test "user flow trellis case 066" {
    try verifyUserFlowTrellisCase(65);
}
test "user flow trellis case 067" {
    try verifyUserFlowTrellisCase(66);
}
test "user flow trellis case 068" {
    try verifyUserFlowTrellisCase(67);
}
test "user flow trellis case 069" {
    try verifyUserFlowTrellisCase(68);
}
test "user flow trellis case 070" {
    try verifyUserFlowTrellisCase(69);
}
test "user flow trellis case 071" {
    try verifyUserFlowTrellisCase(70);
}
test "user flow trellis case 072" {
    try verifyUserFlowTrellisCase(71);
}
test "user flow trellis case 073" {
    try verifyUserFlowTrellisCase(72);
}
test "user flow trellis case 074" {
    try verifyUserFlowTrellisCase(73);
}
test "user flow trellis case 075" {
    try verifyUserFlowTrellisCase(74);
}
test "user flow trellis case 076" {
    try verifyUserFlowTrellisCase(75);
}
test "user flow trellis case 077" {
    try verifyUserFlowTrellisCase(76);
}
test "user flow trellis case 078" {
    try verifyUserFlowTrellisCase(77);
}
test "user flow trellis case 079" {
    try verifyUserFlowTrellisCase(78);
}
test "user flow trellis case 080" {
    try verifyUserFlowTrellisCase(79);
}
test "user flow trellis case 081" {
    try verifyUserFlowTrellisCase(80);
}
test "user flow trellis case 082" {
    try verifyUserFlowTrellisCase(81);
}
test "user flow trellis case 083" {
    try verifyUserFlowTrellisCase(82);
}
test "user flow trellis case 084" {
    try verifyUserFlowTrellisCase(83);
}
test "user flow trellis case 085" {
    try verifyUserFlowTrellisCase(84);
}
test "user flow trellis case 086" {
    try verifyUserFlowTrellisCase(85);
}
test "user flow trellis case 087" {
    try verifyUserFlowTrellisCase(86);
}
test "user flow trellis case 088" {
    try verifyUserFlowTrellisCase(87);
}
test "user flow trellis case 089" {
    try verifyUserFlowTrellisCase(88);
}
test "user flow trellis case 090" {
    try verifyUserFlowTrellisCase(89);
}
test "user flow trellis case 091" {
    try verifyUserFlowTrellisCase(90);
}
test "user flow trellis case 092" {
    try verifyUserFlowTrellisCase(91);
}
test "user flow trellis case 093" {
    try verifyUserFlowTrellisCase(92);
}
test "user flow trellis case 094" {
    try verifyUserFlowTrellisCase(93);
}
test "user flow trellis case 095" {
    try verifyUserFlowTrellisCase(94);
}
test "user flow trellis case 096" {
    try verifyUserFlowTrellisCase(95);
}
test "user flow trellis case 097" {
    try verifyUserFlowTrellisCase(96);
}
test "user flow trellis case 098" {
    try verifyUserFlowTrellisCase(97);
}
test "user flow trellis case 099" {
    try verifyUserFlowTrellisCase(98);
}
test "user flow trellis case 100" {
    try verifyUserFlowTrellisCase(99);
}
test "user flow trellis case 101" {
    try verifyUserFlowTrellisCase(100);
}
test "user flow trellis case 102" {
    try verifyUserFlowTrellisCase(101);
}
test "user flow trellis case 103" {
    try verifyUserFlowTrellisCase(102);
}
test "user flow trellis case 104" {
    try verifyUserFlowTrellisCase(103);
}
test "user flow trellis case 105" {
    try verifyUserFlowTrellisCase(104);
}
test "user flow trellis case 106" {
    try verifyUserFlowTrellisCase(105);
}
test "user flow trellis case 107" {
    try verifyUserFlowTrellisCase(106);
}
test "user flow trellis case 108" {
    try verifyUserFlowTrellisCase(107);
}
test "user flow trellis case 109" {
    try verifyUserFlowTrellisCase(108);
}
test "user flow trellis case 110" {
    try verifyUserFlowTrellisCase(109);
}
test "user flow trellis case 111" {
    try verifyUserFlowTrellisCase(110);
}
test "user flow trellis case 112" {
    try verifyUserFlowTrellisCase(111);
}
test "user flow trellis case 113" {
    try verifyUserFlowTrellisCase(112);
}
test "user flow trellis case 114" {
    try verifyUserFlowTrellisCase(113);
}
test "user flow trellis case 115" {
    try verifyUserFlowTrellisCase(114);
}
test "user flow trellis case 116" {
    try verifyUserFlowTrellisCase(115);
}
test "user flow trellis case 117" {
    try verifyUserFlowTrellisCase(116);
}
test "user flow trellis case 118" {
    try verifyUserFlowTrellisCase(117);
}
test "user flow trellis case 119" {
    try verifyUserFlowTrellisCase(118);
}
test "user flow trellis case 120" {
    try verifyUserFlowTrellisCase(119);
}
test "user flow trellis case 121" {
    try verifyUserFlowTrellisCase(120);
}
test "user flow trellis case 122" {
    try verifyUserFlowTrellisCase(121);
}
test "user flow trellis case 123" {
    try verifyUserFlowTrellisCase(122);
}
test "user flow trellis case 124" {
    try verifyUserFlowTrellisCase(123);
}
test "user flow trellis case 125" {
    try verifyUserFlowTrellisCase(124);
}
test "user flow trellis case 126" {
    try verifyUserFlowTrellisCase(125);
}
test "user flow trellis case 127" {
    try verifyUserFlowTrellisCase(126);
}
test "user flow trellis case 128" {
    try verifyUserFlowTrellisCase(127);
}
test "user flow trellis case 129" {
    try verifyUserFlowTrellisCase(128);
}
test "user flow trellis case 130" {
    try verifyUserFlowTrellisCase(129);
}
test "user flow trellis case 131" {
    try verifyUserFlowTrellisCase(130);
}
test "user flow trellis case 132" {
    try verifyUserFlowTrellisCase(131);
}
test "user flow trellis case 133" {
    try verifyUserFlowTrellisCase(132);
}
test "user flow trellis case 134" {
    try verifyUserFlowTrellisCase(133);
}
test "user flow trellis case 135" {
    try verifyUserFlowTrellisCase(134);
}
test "user flow trellis case 136" {
    try verifyUserFlowTrellisCase(135);
}
test "user flow trellis case 137" {
    try verifyUserFlowTrellisCase(136);
}
test "user flow trellis case 138" {
    try verifyUserFlowTrellisCase(137);
}
test "user flow trellis case 139" {
    try verifyUserFlowTrellisCase(138);
}
test "user flow trellis case 140" {
    try verifyUserFlowTrellisCase(139);
}
test "user flow trellis case 141" {
    try verifyUserFlowTrellisCase(140);
}
test "user flow trellis case 142" {
    try verifyUserFlowTrellisCase(141);
}
test "user flow trellis case 143" {
    try verifyUserFlowTrellisCase(142);
}
test "user flow trellis case 144" {
    try verifyUserFlowTrellisCase(143);
}
test "user flow trellis case 145" {
    try verifyUserFlowTrellisCase(144);
}
test "user flow trellis case 146" {
    try verifyUserFlowTrellisCase(145);
}
test "user flow trellis case 147" {
    try verifyUserFlowTrellisCase(146);
}
test "user flow trellis case 148" {
    try verifyUserFlowTrellisCase(147);
}
test "user flow trellis case 149" {
    try verifyUserFlowTrellisCase(148);
}
test "user flow trellis case 150" {
    try verifyUserFlowTrellisCase(149);
}
test "user flow trellis case 151" {
    try verifyUserFlowTrellisCase(150);
}
test "user flow trellis case 152" {
    try verifyUserFlowTrellisCase(151);
}
test "user flow trellis case 153" {
    try verifyUserFlowTrellisCase(152);
}
test "user flow trellis case 154" {
    try verifyUserFlowTrellisCase(153);
}
test "user flow trellis case 155" {
    try verifyUserFlowTrellisCase(154);
}
test "user flow trellis case 156" {
    try verifyUserFlowTrellisCase(155);
}
test "user flow trellis case 157" {
    try verifyUserFlowTrellisCase(156);
}
test "user flow trellis case 158" {
    try verifyUserFlowTrellisCase(157);
}
test "user flow trellis case 159" {
    try verifyUserFlowTrellisCase(158);
}
test "user flow trellis case 160" {
    try verifyUserFlowTrellisCase(159);
}
test "user flow trellis case 161" {
    try verifyUserFlowTrellisCase(160);
}
test "user flow trellis case 162" {
    try verifyUserFlowTrellisCase(161);
}
test "user flow trellis case 163" {
    try verifyUserFlowTrellisCase(162);
}
test "user flow trellis case 164" {
    try verifyUserFlowTrellisCase(163);
}
test "user flow trellis case 165" {
    try verifyUserFlowTrellisCase(164);
}
test "user flow trellis case 166" {
    try verifyUserFlowTrellisCase(165);
}
test "user flow trellis case 167" {
    try verifyUserFlowTrellisCase(166);
}
test "user flow trellis case 168" {
    try verifyUserFlowTrellisCase(167);
}
test "user flow trellis case 169" {
    try verifyUserFlowTrellisCase(168);
}
test "user flow trellis case 170" {
    try verifyUserFlowTrellisCase(169);
}
test "user flow trellis case 171" {
    try verifyUserFlowTrellisCase(170);
}
test "user flow trellis case 172" {
    try verifyUserFlowTrellisCase(171);
}
test "user flow trellis case 173" {
    try verifyUserFlowTrellisCase(172);
}
test "user flow trellis case 174" {
    try verifyUserFlowTrellisCase(173);
}
test "user flow trellis case 175" {
    try verifyUserFlowTrellisCase(174);
}
test "user flow trellis case 176" {
    try verifyUserFlowTrellisCase(175);
}
test "user flow trellis case 177" {
    try verifyUserFlowTrellisCase(176);
}
test "user flow trellis case 178" {
    try verifyUserFlowTrellisCase(177);
}
test "user flow trellis case 179" {
    try verifyUserFlowTrellisCase(178);
}
test "user flow trellis case 180" {
    try verifyUserFlowTrellisCase(179);
}
test "user flow trellis case 181" {
    try verifyUserFlowTrellisCase(180);
}
test "user flow trellis case 182" {
    try verifyUserFlowTrellisCase(181);
}
test "user flow trellis case 183" {
    try verifyUserFlowTrellisCase(182);
}
test "user flow trellis case 184" {
    try verifyUserFlowTrellisCase(183);
}
test "user flow trellis case 185" {
    try verifyUserFlowTrellisCase(184);
}
test "user flow trellis case 186" {
    try verifyUserFlowTrellisCase(185);
}
test "user flow trellis case 187" {
    try verifyUserFlowTrellisCase(186);
}
test "user flow trellis case 188" {
    try verifyUserFlowTrellisCase(187);
}
test "user flow trellis case 189" {
    try verifyUserFlowTrellisCase(188);
}
test "user flow trellis case 190" {
    try verifyUserFlowTrellisCase(189);
}
test "user flow trellis case 191" {
    try verifyUserFlowTrellisCase(190);
}
test "user flow trellis case 192" {
    try verifyUserFlowTrellisCase(191);
}
test "user flow trellis case 193" {
    try verifyUserFlowTrellisCase(192);
}
test "user flow trellis case 194" {
    try verifyUserFlowTrellisCase(193);
}
test "user flow trellis case 195" {
    try verifyUserFlowTrellisCase(194);
}
test "user flow trellis case 196" {
    try verifyUserFlowTrellisCase(195);
}
test "user flow trellis case 197" {
    try verifyUserFlowTrellisCase(196);
}
test "user flow trellis case 198" {
    try verifyUserFlowTrellisCase(197);
}
test "user flow trellis case 199" {
    try verifyUserFlowTrellisCase(198);
}
test "user flow trellis case 200" {
    try verifyUserFlowTrellisCase(199);
}
test "user flow trellis case 201" {
    try verifyUserFlowTrellisCase(200);
}
test "user flow trellis case 202" {
    try verifyUserFlowTrellisCase(201);
}
test "user flow trellis case 203" {
    try verifyUserFlowTrellisCase(202);
}
test "user flow trellis case 204" {
    try verifyUserFlowTrellisCase(203);
}
test "user flow trellis case 205" {
    try verifyUserFlowTrellisCase(204);
}
test "user flow trellis case 206" {
    try verifyUserFlowTrellisCase(205);
}
test "user flow trellis case 207" {
    try verifyUserFlowTrellisCase(206);
}
test "user flow trellis case 208" {
    try verifyUserFlowTrellisCase(207);
}
test "user flow trellis case 209" {
    try verifyUserFlowTrellisCase(208);
}
test "user flow trellis case 210" {
    try verifyUserFlowTrellisCase(209);
}
test "user flow trellis case 211" {
    try verifyUserFlowTrellisCase(210);
}
test "user flow trellis case 212" {
    try verifyUserFlowTrellisCase(211);
}
test "user flow trellis case 213" {
    try verifyUserFlowTrellisCase(212);
}
test "user flow trellis case 214" {
    try verifyUserFlowTrellisCase(213);
}
test "user flow trellis case 215" {
    try verifyUserFlowTrellisCase(214);
}
test "user flow trellis case 216" {
    try verifyUserFlowTrellisCase(215);
}
test "user flow trellis case 217" {
    try verifyUserFlowTrellisCase(216);
}
test "user flow trellis case 218" {
    try verifyUserFlowTrellisCase(217);
}
test "user flow trellis case 219" {
    try verifyUserFlowTrellisCase(218);
}
test "user flow trellis case 220" {
    try verifyUserFlowTrellisCase(219);
}
test "user flow trellis case 221" {
    try verifyUserFlowTrellisCase(220);
}
test "user flow trellis case 222" {
    try verifyUserFlowTrellisCase(221);
}
test "user flow trellis case 223" {
    try verifyUserFlowTrellisCase(222);
}
test "user flow trellis case 224" {
    try verifyUserFlowTrellisCase(223);
}
test "user flow trellis case 225" {
    try verifyUserFlowTrellisCase(224);
}
test "user flow trellis case 226" {
    try verifyUserFlowTrellisCase(225);
}
test "user flow trellis case 227" {
    try verifyUserFlowTrellisCase(226);
}
test "user flow trellis case 228" {
    try verifyUserFlowTrellisCase(227);
}
test "user flow trellis case 229" {
    try verifyUserFlowTrellisCase(228);
}
test "user flow trellis case 230" {
    try verifyUserFlowTrellisCase(229);
}
test "user flow trellis case 231" {
    try verifyUserFlowTrellisCase(230);
}
test "user flow trellis case 232" {
    try verifyUserFlowTrellisCase(231);
}
test "user flow trellis case 233" {
    try verifyUserFlowTrellisCase(232);
}
test "user flow trellis case 234" {
    try verifyUserFlowTrellisCase(233);
}
test "user flow trellis case 235" {
    try verifyUserFlowTrellisCase(234);
}
test "user flow trellis case 236" {
    try verifyUserFlowTrellisCase(235);
}
test "user flow trellis case 237" {
    try verifyUserFlowTrellisCase(236);
}
test "user flow trellis case 238" {
    try verifyUserFlowTrellisCase(237);
}
test "user flow trellis case 239" {
    try verifyUserFlowTrellisCase(238);
}
test "user flow trellis case 240" {
    try verifyUserFlowTrellisCase(239);
}
test "user flow trellis case 241" {
    try verifyUserFlowTrellisCase(240);
}
test "user flow trellis case 242" {
    try verifyUserFlowTrellisCase(241);
}
test "user flow trellis case 243" {
    try verifyUserFlowTrellisCase(242);
}
test "user flow trellis case 244" {
    try verifyUserFlowTrellisCase(243);
}
test "user flow trellis case 245" {
    try verifyUserFlowTrellisCase(244);
}
test "user flow trellis case 246" {
    try verifyUserFlowTrellisCase(245);
}
test "user flow trellis case 247" {
    try verifyUserFlowTrellisCase(246);
}
test "user flow trellis case 248" {
    try verifyUserFlowTrellisCase(247);
}
test "user flow trellis case 249" {
    try verifyUserFlowTrellisCase(248);
}
test "user flow trellis case 250" {
    try verifyUserFlowTrellisCase(249);
}
test "user flow trellis case 251" {
    try verifyUserFlowTrellisCase(250);
}
test "user flow trellis case 252" {
    try verifyUserFlowTrellisCase(251);
}
test "user flow trellis case 253" {
    try verifyUserFlowTrellisCase(252);
}
test "user flow trellis case 254" {
    try verifyUserFlowTrellisCase(253);
}
test "user flow trellis case 255" {
    try verifyUserFlowTrellisCase(254);
}
test "user flow trellis case 256" {
    try verifyUserFlowTrellisCase(255);
}
test "user flow trellis case 257" {
    try verifyUserFlowTrellisCase(256);
}
test "user flow trellis case 258" {
    try verifyUserFlowTrellisCase(257);
}
test "user flow trellis case 259" {
    try verifyUserFlowTrellisCase(258);
}
test "user flow trellis case 260" {
    try verifyUserFlowTrellisCase(259);
}
test "user flow trellis case 261" {
    try verifyUserFlowTrellisCase(260);
}
test "user flow trellis case 262" {
    try verifyUserFlowTrellisCase(261);
}
test "user flow trellis case 263" {
    try verifyUserFlowTrellisCase(262);
}
test "user flow trellis case 264" {
    try verifyUserFlowTrellisCase(263);
}
test "user flow trellis case 265" {
    try verifyUserFlowTrellisCase(264);
}
test "user flow trellis case 266" {
    try verifyUserFlowTrellisCase(265);
}
test "user flow trellis case 267" {
    try verifyUserFlowTrellisCase(266);
}
test "user flow trellis case 268" {
    try verifyUserFlowTrellisCase(267);
}
test "user flow trellis case 269" {
    try verifyUserFlowTrellisCase(268);
}
test "user flow trellis case 270" {
    try verifyUserFlowTrellisCase(269);
}
test "user flow trellis case 271" {
    try verifyUserFlowTrellisCase(270);
}
test "user flow trellis case 272" {
    try verifyUserFlowTrellisCase(271);
}
test "user flow trellis case 273" {
    try verifyUserFlowTrellisCase(272);
}
test "user flow trellis case 274" {
    try verifyUserFlowTrellisCase(273);
}
test "user flow trellis case 275" {
    try verifyUserFlowTrellisCase(274);
}
test "user flow trellis case 276" {
    try verifyUserFlowTrellisCase(275);
}
test "user flow trellis case 277" {
    try verifyUserFlowTrellisCase(276);
}
test "user flow trellis case 278" {
    try verifyUserFlowTrellisCase(277);
}
test "user flow trellis case 279" {
    try verifyUserFlowTrellisCase(278);
}
test "user flow trellis case 280" {
    try verifyUserFlowTrellisCase(279);
}
test "user flow trellis case 281" {
    try verifyUserFlowTrellisCase(280);
}
test "user flow trellis case 282" {
    try verifyUserFlowTrellisCase(281);
}
test "user flow trellis case 283" {
    try verifyUserFlowTrellisCase(282);
}
test "user flow trellis case 284" {
    try verifyUserFlowTrellisCase(283);
}
test "user flow trellis case 285" {
    try verifyUserFlowTrellisCase(284);
}
test "user flow trellis case 286" {
    try verifyUserFlowTrellisCase(285);
}
test "user flow trellis case 287" {
    try verifyUserFlowTrellisCase(286);
}
test "user flow trellis case 288" {
    try verifyUserFlowTrellisCase(287);
}
test "user flow trellis case 289" {
    try verifyUserFlowTrellisCase(288);
}
test "user flow trellis case 290" {
    try verifyUserFlowTrellisCase(289);
}
test "user flow trellis case 291" {
    try verifyUserFlowTrellisCase(290);
}
test "user flow trellis case 292" {
    try verifyUserFlowTrellisCase(291);
}
test "user flow trellis case 293" {
    try verifyUserFlowTrellisCase(292);
}
test "user flow trellis case 294" {
    try verifyUserFlowTrellisCase(293);
}
test "user flow trellis case 295" {
    try verifyUserFlowTrellisCase(294);
}
test "user flow trellis case 296" {
    try verifyUserFlowTrellisCase(295);
}
test "user flow trellis case 297" {
    try verifyUserFlowTrellisCase(296);
}
test "user flow trellis case 298" {
    try verifyUserFlowTrellisCase(297);
}
test "user flow trellis case 299" {
    try verifyUserFlowTrellisCase(298);
}
test "user flow trellis case 300" {
    try verifyUserFlowTrellisCase(299);
}
test "user flow trellis case 301" {
    try verifyUserFlowTrellisCase(300);
}
test "user flow trellis case 302" {
    try verifyUserFlowTrellisCase(301);
}
test "user flow trellis case 303" {
    try verifyUserFlowTrellisCase(302);
}
test "user flow trellis case 304" {
    try verifyUserFlowTrellisCase(303);
}
test "user flow trellis case 305" {
    try verifyUserFlowTrellisCase(304);
}
test "user flow trellis case 306" {
    try verifyUserFlowTrellisCase(305);
}
test "user flow trellis case 307" {
    try verifyUserFlowTrellisCase(306);
}
test "user flow trellis case 308" {
    try verifyUserFlowTrellisCase(307);
}
test "user flow trellis case 309" {
    try verifyUserFlowTrellisCase(308);
}
test "user flow trellis case 310" {
    try verifyUserFlowTrellisCase(309);
}
test "user flow trellis case 311" {
    try verifyUserFlowTrellisCase(310);
}
test "user flow trellis case 312" {
    try verifyUserFlowTrellisCase(311);
}
test "user flow trellis case 313" {
    try verifyUserFlowTrellisCase(312);
}
test "user flow trellis case 314" {
    try verifyUserFlowTrellisCase(313);
}
test "user flow trellis case 315" {
    try verifyUserFlowTrellisCase(314);
}
test "user flow trellis case 316" {
    try verifyUserFlowTrellisCase(315);
}
test "user flow trellis case 317" {
    try verifyUserFlowTrellisCase(316);
}
test "user flow trellis case 318" {
    try verifyUserFlowTrellisCase(317);
}
test "user flow trellis case 319" {
    try verifyUserFlowTrellisCase(318);
}
test "user flow trellis case 320" {
    try verifyUserFlowTrellisCase(319);
}
test "user flow trellis case 321" {
    try verifyUserFlowTrellisCase(320);
}
test "user flow trellis case 322" {
    try verifyUserFlowTrellisCase(321);
}
test "user flow trellis case 323" {
    try verifyUserFlowTrellisCase(322);
}
test "user flow trellis case 324" {
    try verifyUserFlowTrellisCase(323);
}
test "user flow trellis case 325" {
    try verifyUserFlowTrellisCase(324);
}
test "user flow trellis case 326" {
    try verifyUserFlowTrellisCase(325);
}
test "user flow trellis case 327" {
    try verifyUserFlowTrellisCase(326);
}
test "user flow trellis case 328" {
    try verifyUserFlowTrellisCase(327);
}
test "user flow trellis case 329" {
    try verifyUserFlowTrellisCase(328);
}
test "user flow trellis case 330" {
    try verifyUserFlowTrellisCase(329);
}
test "user flow trellis case 331" {
    try verifyUserFlowTrellisCase(330);
}
test "user flow trellis case 332" {
    try verifyUserFlowTrellisCase(331);
}
test "user flow trellis case 333" {
    try verifyUserFlowTrellisCase(332);
}
test "user flow trellis case 334" {
    try verifyUserFlowTrellisCase(333);
}
test "user flow trellis case 335" {
    try verifyUserFlowTrellisCase(334);
}
test "user flow trellis case 336" {
    try verifyUserFlowTrellisCase(335);
}
test "user flow trellis case 337" {
    try verifyUserFlowTrellisCase(336);
}
test "user flow trellis case 338" {
    try verifyUserFlowTrellisCase(337);
}
test "user flow trellis case 339" {
    try verifyUserFlowTrellisCase(338);
}
test "user flow trellis case 340" {
    try verifyUserFlowTrellisCase(339);
}
test "user flow trellis case 341" {
    try verifyUserFlowTrellisCase(340);
}
test "user flow trellis case 342" {
    try verifyUserFlowTrellisCase(341);
}
test "user flow trellis case 343" {
    try verifyUserFlowTrellisCase(342);
}
test "user flow trellis case 344" {
    try verifyUserFlowTrellisCase(343);
}
test "user flow trellis case 345" {
    try verifyUserFlowTrellisCase(344);
}
test "user flow trellis case 346" {
    try verifyUserFlowTrellisCase(345);
}
test "user flow trellis case 347" {
    try verifyUserFlowTrellisCase(346);
}
test "user flow trellis case 348" {
    try verifyUserFlowTrellisCase(347);
}
test "user flow trellis case 349" {
    try verifyUserFlowTrellisCase(348);
}
test "user flow trellis case 350" {
    try verifyUserFlowTrellisCase(349);
}
test "user flow trellis case 351" {
    try verifyUserFlowTrellisCase(350);
}
test "user flow trellis case 352" {
    try verifyUserFlowTrellisCase(351);
}
test "user flow trellis case 353" {
    try verifyUserFlowTrellisCase(352);
}
test "user flow trellis case 354" {
    try verifyUserFlowTrellisCase(353);
}
test "user flow trellis case 355" {
    try verifyUserFlowTrellisCase(354);
}
test "user flow trellis case 356" {
    try verifyUserFlowTrellisCase(355);
}
test "user flow trellis case 357" {
    try verifyUserFlowTrellisCase(356);
}
test "user flow trellis case 358" {
    try verifyUserFlowTrellisCase(357);
}
test "user flow trellis case 359" {
    try verifyUserFlowTrellisCase(358);
}
test "user flow trellis case 360" {
    try verifyUserFlowTrellisCase(359);
}
test "user flow trellis case 361" {
    try verifyUserFlowTrellisCase(360);
}
test "user flow trellis case 362" {
    try verifyUserFlowTrellisCase(361);
}
test "user flow trellis case 363" {
    try verifyUserFlowTrellisCase(362);
}
test "user flow trellis case 364" {
    try verifyUserFlowTrellisCase(363);
}
test "user flow trellis case 365" {
    try verifyUserFlowTrellisCase(364);
}
test "user flow trellis case 366" {
    try verifyUserFlowTrellisCase(365);
}
test "user flow trellis case 367" {
    try verifyUserFlowTrellisCase(366);
}
test "user flow trellis case 368" {
    try verifyUserFlowTrellisCase(367);
}
test "user flow trellis case 369" {
    try verifyUserFlowTrellisCase(368);
}
test "user flow trellis case 370" {
    try verifyUserFlowTrellisCase(369);
}
test "user flow trellis case 371" {
    try verifyUserFlowTrellisCase(370);
}
test "user flow trellis case 372" {
    try verifyUserFlowTrellisCase(371);
}
test "user flow trellis case 373" {
    try verifyUserFlowTrellisCase(372);
}
test "user flow trellis case 374" {
    try verifyUserFlowTrellisCase(373);
}
test "user flow trellis case 375" {
    try verifyUserFlowTrellisCase(374);
}
test "user flow trellis case 376" {
    try verifyUserFlowTrellisCase(375);
}
test "user flow trellis case 377" {
    try verifyUserFlowTrellisCase(376);
}
test "user flow trellis case 378" {
    try verifyUserFlowTrellisCase(377);
}
test "user flow trellis case 379" {
    try verifyUserFlowTrellisCase(378);
}
test "user flow trellis case 380" {
    try verifyUserFlowTrellisCase(379);
}
test "user flow trellis case 381" {
    try verifyUserFlowTrellisCase(380);
}
test "user flow trellis case 382" {
    try verifyUserFlowTrellisCase(381);
}
test "user flow trellis case 383" {
    try verifyUserFlowTrellisCase(382);
}
test "user flow trellis case 384" {
    try verifyUserFlowTrellisCase(383);
}
test "user flow trellis case 385" {
    try verifyUserFlowTrellisCase(384);
}
test "user flow trellis case 386" {
    try verifyUserFlowTrellisCase(385);
}
test "user flow trellis case 387" {
    try verifyUserFlowTrellisCase(386);
}
test "user flow trellis case 388" {
    try verifyUserFlowTrellisCase(387);
}
test "user flow trellis case 389" {
    try verifyUserFlowTrellisCase(388);
}
test "user flow trellis case 390" {
    try verifyUserFlowTrellisCase(389);
}
test "user flow trellis case 391" {
    try verifyUserFlowTrellisCase(390);
}
test "user flow trellis case 392" {
    try verifyUserFlowTrellisCase(391);
}
test "user flow trellis case 393" {
    try verifyUserFlowTrellisCase(392);
}
test "user flow trellis case 394" {
    try verifyUserFlowTrellisCase(393);
}
test "user flow trellis case 395" {
    try verifyUserFlowTrellisCase(394);
}
test "user flow trellis case 396" {
    try verifyUserFlowTrellisCase(395);
}
test "user flow trellis case 397" {
    try verifyUserFlowTrellisCase(396);
}
test "user flow trellis case 398" {
    try verifyUserFlowTrellisCase(397);
}
test "user flow trellis case 399" {
    try verifyUserFlowTrellisCase(398);
}
test "user flow trellis case 400" {
    try verifyUserFlowTrellisCase(399);
}
test "user flow trellis case 401" {
    try verifyUserFlowTrellisCase(400);
}
test "user flow trellis case 402" {
    try verifyUserFlowTrellisCase(401);
}
test "user flow trellis case 403" {
    try verifyUserFlowTrellisCase(402);
}
test "user flow trellis case 404" {
    try verifyUserFlowTrellisCase(403);
}
test "user flow trellis case 405" {
    try verifyUserFlowTrellisCase(404);
}
test "user flow trellis case 406" {
    try verifyUserFlowTrellisCase(405);
}
test "user flow trellis case 407" {
    try verifyUserFlowTrellisCase(406);
}
test "user flow trellis case 408" {
    try verifyUserFlowTrellisCase(407);
}
test "user flow trellis case 409" {
    try verifyUserFlowTrellisCase(408);
}
test "user flow trellis case 410" {
    try verifyUserFlowTrellisCase(409);
}
test "user flow trellis case 411" {
    try verifyUserFlowTrellisCase(410);
}
test "user flow trellis case 412" {
    try verifyUserFlowTrellisCase(411);
}
test "user flow trellis case 413" {
    try verifyUserFlowTrellisCase(412);
}
test "user flow trellis case 414" {
    try verifyUserFlowTrellisCase(413);
}
test "user flow trellis case 415" {
    try verifyUserFlowTrellisCase(414);
}
test "user flow trellis case 416" {
    try verifyUserFlowTrellisCase(415);
}
test "user flow trellis case 417" {
    try verifyUserFlowTrellisCase(416);
}
test "user flow trellis case 418" {
    try verifyUserFlowTrellisCase(417);
}
test "user flow trellis case 419" {
    try verifyUserFlowTrellisCase(418);
}
test "user flow trellis case 420" {
    try verifyUserFlowTrellisCase(419);
}
test "user flow trellis case 421" {
    try verifyUserFlowTrellisCase(420);
}
test "user flow trellis case 422" {
    try verifyUserFlowTrellisCase(421);
}
test "user flow trellis case 423" {
    try verifyUserFlowTrellisCase(422);
}
test "user flow trellis case 424" {
    try verifyUserFlowTrellisCase(423);
}
test "user flow trellis case 425" {
    try verifyUserFlowTrellisCase(424);
}
test "user flow trellis case 426" {
    try verifyUserFlowTrellisCase(425);
}
test "user flow trellis case 427" {
    try verifyUserFlowTrellisCase(426);
}
test "user flow trellis case 428" {
    try verifyUserFlowTrellisCase(427);
}
test "user flow trellis case 429" {
    try verifyUserFlowTrellisCase(428);
}
test "user flow trellis case 430" {
    try verifyUserFlowTrellisCase(429);
}
test "user flow trellis case 431" {
    try verifyUserFlowTrellisCase(430);
}
test "user flow trellis case 432" {
    try verifyUserFlowTrellisCase(431);
}
test "user flow trellis case 433" {
    try verifyUserFlowTrellisCase(432);
}
test "user flow trellis case 434" {
    try verifyUserFlowTrellisCase(433);
}
test "user flow trellis case 435" {
    try verifyUserFlowTrellisCase(434);
}
test "user flow trellis case 436" {
    try verifyUserFlowTrellisCase(435);
}
test "user flow trellis case 437" {
    try verifyUserFlowTrellisCase(436);
}
test "user flow trellis case 438" {
    try verifyUserFlowTrellisCase(437);
}
test "user flow trellis case 439" {
    try verifyUserFlowTrellisCase(438);
}
test "user flow trellis case 440" {
    try verifyUserFlowTrellisCase(439);
}
test "user flow trellis case 441" {
    try verifyUserFlowTrellisCase(440);
}
test "user flow trellis case 442" {
    try verifyUserFlowTrellisCase(441);
}
test "user flow trellis case 443" {
    try verifyUserFlowTrellisCase(442);
}
test "user flow trellis case 444" {
    try verifyUserFlowTrellisCase(443);
}
test "user flow trellis case 445" {
    try verifyUserFlowTrellisCase(444);
}
test "user flow trellis case 446" {
    try verifyUserFlowTrellisCase(445);
}
test "user flow trellis case 447" {
    try verifyUserFlowTrellisCase(446);
}
test "user flow trellis case 448" {
    try verifyUserFlowTrellisCase(447);
}
test "user flow trellis case 449" {
    try verifyUserFlowTrellisCase(448);
}
test "user flow trellis case 450" {
    try verifyUserFlowTrellisCase(449);
}
test "user flow trellis case 451" {
    try verifyUserFlowTrellisCase(450);
}
test "user flow trellis case 452" {
    try verifyUserFlowTrellisCase(451);
}
test "user flow trellis case 453" {
    try verifyUserFlowTrellisCase(452);
}
test "user flow trellis case 454" {
    try verifyUserFlowTrellisCase(453);
}
test "user flow trellis case 455" {
    try verifyUserFlowTrellisCase(454);
}
test "user flow trellis case 456" {
    try verifyUserFlowTrellisCase(455);
}
test "user flow trellis case 457" {
    try verifyUserFlowTrellisCase(456);
}
test "user flow trellis case 458" {
    try verifyUserFlowTrellisCase(457);
}
test "user flow trellis case 459" {
    try verifyUserFlowTrellisCase(458);
}
test "user flow trellis case 460" {
    try verifyUserFlowTrellisCase(459);
}
test "user flow trellis case 461" {
    try verifyUserFlowTrellisCase(460);
}
test "user flow trellis case 462" {
    try verifyUserFlowTrellisCase(461);
}
test "user flow trellis case 463" {
    try verifyUserFlowTrellisCase(462);
}
test "user flow trellis case 464" {
    try verifyUserFlowTrellisCase(463);
}
test "user flow trellis case 465" {
    try verifyUserFlowTrellisCase(464);
}
test "user flow trellis case 466" {
    try verifyUserFlowTrellisCase(465);
}
test "user flow trellis case 467" {
    try verifyUserFlowTrellisCase(466);
}
test "user flow trellis case 468" {
    try verifyUserFlowTrellisCase(467);
}
test "user flow trellis case 469" {
    try verifyUserFlowTrellisCase(468);
}
test "user flow trellis case 470" {
    try verifyUserFlowTrellisCase(469);
}
test "user flow trellis case 471" {
    try verifyUserFlowTrellisCase(470);
}
test "user flow trellis case 472" {
    try verifyUserFlowTrellisCase(471);
}
test "user flow trellis case 473" {
    try verifyUserFlowTrellisCase(472);
}
test "user flow trellis case 474" {
    try verifyUserFlowTrellisCase(473);
}
test "user flow trellis case 475" {
    try verifyUserFlowTrellisCase(474);
}
test "user flow trellis case 476" {
    try verifyUserFlowTrellisCase(475);
}
test "user flow trellis case 477" {
    try verifyUserFlowTrellisCase(476);
}
test "user flow trellis case 478" {
    try verifyUserFlowTrellisCase(477);
}
test "user flow trellis case 479" {
    try verifyUserFlowTrellisCase(478);
}
test "user flow trellis case 480" {
    try verifyUserFlowTrellisCase(479);
}
test "user flow trellis case 481" {
    try verifyUserFlowTrellisCase(480);
}
test "user flow trellis case 482" {
    try verifyUserFlowTrellisCase(481);
}
test "user flow trellis case 483" {
    try verifyUserFlowTrellisCase(482);
}
test "user flow trellis case 484" {
    try verifyUserFlowTrellisCase(483);
}
test "user flow trellis case 485" {
    try verifyUserFlowTrellisCase(484);
}
test "user flow trellis case 486" {
    try verifyUserFlowTrellisCase(485);
}
test "user flow trellis case 487" {
    try verifyUserFlowTrellisCase(486);
}
test "user flow trellis case 488" {
    try verifyUserFlowTrellisCase(487);
}
test "user flow trellis case 489" {
    try verifyUserFlowTrellisCase(488);
}
test "user flow trellis case 490" {
    try verifyUserFlowTrellisCase(489);
}
test "user flow trellis case 491" {
    try verifyUserFlowTrellisCase(490);
}
test "user flow trellis case 492" {
    try verifyUserFlowTrellisCase(491);
}
test "user flow trellis case 493" {
    try verifyUserFlowTrellisCase(492);
}
test "user flow trellis case 494" {
    try verifyUserFlowTrellisCase(493);
}
test "user flow trellis case 495" {
    try verifyUserFlowTrellisCase(494);
}
test "user flow trellis case 496" {
    try verifyUserFlowTrellisCase(495);
}
test "user flow trellis case 497" {
    try verifyUserFlowTrellisCase(496);
}
test "user flow trellis case 498" {
    try verifyUserFlowTrellisCase(497);
}
test "user flow trellis case 499" {
    try verifyUserFlowTrellisCase(498);
}
test "user flow trellis case 500" {
    try verifyUserFlowTrellisCase(499);
}
test "user flow trellis case 501" {
    try verifyUserFlowTrellisCase(500);
}
test "user flow trellis case 502" {
    try verifyUserFlowTrellisCase(501);
}
test "user flow trellis case 503" {
    try verifyUserFlowTrellisCase(502);
}
test "user flow trellis case 504" {
    try verifyUserFlowTrellisCase(503);
}
test "user flow trellis case 505" {
    try verifyUserFlowTrellisCase(504);
}
test "user flow trellis case 506" {
    try verifyUserFlowTrellisCase(505);
}
test "user flow trellis case 507" {
    try verifyUserFlowTrellisCase(506);
}
test "user flow trellis case 508" {
    try verifyUserFlowTrellisCase(507);
}
test "user flow trellis case 509" {
    try verifyUserFlowTrellisCase(508);
}
test "user flow trellis case 510" {
    try verifyUserFlowTrellisCase(509);
}
test "user flow trellis case 511" {
    try verifyUserFlowTrellisCase(510);
}
test "user flow trellis case 512" {
    try verifyUserFlowTrellisCase(511);
}
test "user flow trellis case 513" {
    try verifyUserFlowTrellisCase(512);
}
test "user flow trellis case 514" {
    try verifyUserFlowTrellisCase(513);
}
test "user flow trellis case 515" {
    try verifyUserFlowTrellisCase(514);
}
test "user flow trellis case 516" {
    try verifyUserFlowTrellisCase(515);
}
test "user flow trellis case 517" {
    try verifyUserFlowTrellisCase(516);
}
test "user flow trellis case 518" {
    try verifyUserFlowTrellisCase(517);
}
test "user flow trellis case 519" {
    try verifyUserFlowTrellisCase(518);
}
test "user flow trellis case 520" {
    try verifyUserFlowTrellisCase(519);
}
test "user flow trellis case 521" {
    try verifyUserFlowTrellisCase(520);
}
test "user flow trellis case 522" {
    try verifyUserFlowTrellisCase(521);
}
test "user flow trellis case 523" {
    try verifyUserFlowTrellisCase(522);
}
test "user flow trellis case 524" {
    try verifyUserFlowTrellisCase(523);
}
test "user flow trellis case 525" {
    try verifyUserFlowTrellisCase(524);
}
test "user flow trellis case 526" {
    try verifyUserFlowTrellisCase(525);
}
test "user flow trellis case 527" {
    try verifyUserFlowTrellisCase(526);
}
test "user flow trellis case 528" {
    try verifyUserFlowTrellisCase(527);
}
test "user flow trellis case 529" {
    try verifyUserFlowTrellisCase(528);
}
test "user flow trellis case 530" {
    try verifyUserFlowTrellisCase(529);
}
test "user flow trellis case 531" {
    try verifyUserFlowTrellisCase(530);
}
test "user flow trellis case 532" {
    try verifyUserFlowTrellisCase(531);
}
test "user flow trellis case 533" {
    try verifyUserFlowTrellisCase(532);
}
test "user flow trellis case 534" {
    try verifyUserFlowTrellisCase(533);
}
test "user flow trellis case 535" {
    try verifyUserFlowTrellisCase(534);
}
test "user flow trellis case 536" {
    try verifyUserFlowTrellisCase(535);
}
test "user flow trellis case 537" {
    try verifyUserFlowTrellisCase(536);
}
test "user flow trellis case 538" {
    try verifyUserFlowTrellisCase(537);
}
test "user flow trellis case 539" {
    try verifyUserFlowTrellisCase(538);
}
test "user flow trellis case 540" {
    try verifyUserFlowTrellisCase(539);
}
test "user flow trellis case 541" {
    try verifyUserFlowTrellisCase(540);
}
test "user flow trellis case 542" {
    try verifyUserFlowTrellisCase(541);
}
test "user flow trellis case 543" {
    try verifyUserFlowTrellisCase(542);
}
test "user flow trellis case 544" {
    try verifyUserFlowTrellisCase(543);
}
test "user flow trellis case 545" {
    try verifyUserFlowTrellisCase(544);
}
test "user flow trellis case 546" {
    try verifyUserFlowTrellisCase(545);
}
test "user flow trellis case 547" {
    try verifyUserFlowTrellisCase(546);
}
test "user flow trellis case 548" {
    try verifyUserFlowTrellisCase(547);
}
test "user flow trellis case 549" {
    try verifyUserFlowTrellisCase(548);
}
test "user flow trellis case 550" {
    try verifyUserFlowTrellisCase(549);
}
test "user flow trellis case 551" {
    try verifyUserFlowTrellisCase(550);
}
test "user flow trellis case 552" {
    try verifyUserFlowTrellisCase(551);
}
test "user flow trellis case 553" {
    try verifyUserFlowTrellisCase(552);
}
test "user flow trellis case 554" {
    try verifyUserFlowTrellisCase(553);
}
test "user flow trellis case 555" {
    try verifyUserFlowTrellisCase(554);
}
test "user flow trellis case 556" {
    try verifyUserFlowTrellisCase(555);
}
test "user flow trellis case 557" {
    try verifyUserFlowTrellisCase(556);
}
test "user flow trellis case 558" {
    try verifyUserFlowTrellisCase(557);
}
test "user flow trellis case 559" {
    try verifyUserFlowTrellisCase(558);
}
test "user flow trellis case 560" {
    try verifyUserFlowTrellisCase(559);
}
test "user flow trellis case 561" {
    try verifyUserFlowTrellisCase(560);
}
test "user flow trellis case 562" {
    try verifyUserFlowTrellisCase(561);
}
test "user flow trellis case 563" {
    try verifyUserFlowTrellisCase(562);
}
test "user flow trellis case 564" {
    try verifyUserFlowTrellisCase(563);
}
test "user flow trellis case 565" {
    try verifyUserFlowTrellisCase(564);
}
test "user flow trellis case 566" {
    try verifyUserFlowTrellisCase(565);
}
test "user flow trellis case 567" {
    try verifyUserFlowTrellisCase(566);
}
test "user flow trellis case 568" {
    try verifyUserFlowTrellisCase(567);
}
test "user flow trellis case 569" {
    try verifyUserFlowTrellisCase(568);
}
test "user flow trellis case 570" {
    try verifyUserFlowTrellisCase(569);
}
test "user flow trellis case 571" {
    try verifyUserFlowTrellisCase(570);
}
test "user flow trellis case 572" {
    try verifyUserFlowTrellisCase(571);
}
test "user flow trellis case 573" {
    try verifyUserFlowTrellisCase(572);
}
test "user flow trellis case 574" {
    try verifyUserFlowTrellisCase(573);
}
test "user flow trellis case 575" {
    try verifyUserFlowTrellisCase(574);
}
test "user flow trellis case 576" {
    try verifyUserFlowTrellisCase(575);
}
test "user flow trellis case 577" {
    try verifyUserFlowTrellisCase(576);
}
test "user flow trellis case 578" {
    try verifyUserFlowTrellisCase(577);
}
test "user flow trellis case 579" {
    try verifyUserFlowTrellisCase(578);
}
test "user flow trellis case 580" {
    try verifyUserFlowTrellisCase(579);
}
test "user flow trellis case 581" {
    try verifyUserFlowTrellisCase(580);
}
test "user flow trellis case 582" {
    try verifyUserFlowTrellisCase(581);
}
test "user flow trellis case 583" {
    try verifyUserFlowTrellisCase(582);
}
test "user flow trellis case 584" {
    try verifyUserFlowTrellisCase(583);
}
test "user flow trellis case 585" {
    try verifyUserFlowTrellisCase(584);
}
test "user flow trellis case 586" {
    try verifyUserFlowTrellisCase(585);
}
test "user flow trellis case 587" {
    try verifyUserFlowTrellisCase(586);
}
test "user flow trellis case 588" {
    try verifyUserFlowTrellisCase(587);
}
test "user flow trellis case 589" {
    try verifyUserFlowTrellisCase(588);
}
test "user flow trellis case 590" {
    try verifyUserFlowTrellisCase(589);
}
test "user flow trellis case 591" {
    try verifyUserFlowTrellisCase(590);
}
test "user flow trellis case 592" {
    try verifyUserFlowTrellisCase(591);
}
test "user flow trellis case 593" {
    try verifyUserFlowTrellisCase(592);
}
test "user flow trellis case 594" {
    try verifyUserFlowTrellisCase(593);
}
test "user flow trellis case 595" {
    try verifyUserFlowTrellisCase(594);
}
test "user flow trellis case 596" {
    try verifyUserFlowTrellisCase(595);
}
test "user flow trellis case 597" {
    try verifyUserFlowTrellisCase(596);
}
test "user flow trellis case 598" {
    try verifyUserFlowTrellisCase(597);
}
test "user flow trellis case 599" {
    try verifyUserFlowTrellisCase(598);
}
test "user flow trellis case 600" {
    try verifyUserFlowTrellisCase(599);
}
test "user flow trellis case 601" {
    try verifyUserFlowTrellisCase(600);
}
test "user flow trellis case 602" {
    try verifyUserFlowTrellisCase(601);
}
test "user flow trellis case 603" {
    try verifyUserFlowTrellisCase(602);
}
test "user flow trellis case 604" {
    try verifyUserFlowTrellisCase(603);
}
test "user flow trellis case 605" {
    try verifyUserFlowTrellisCase(604);
}
test "user flow trellis case 606" {
    try verifyUserFlowTrellisCase(605);
}
test "user flow trellis case 607" {
    try verifyUserFlowTrellisCase(606);
}
test "user flow trellis case 608" {
    try verifyUserFlowTrellisCase(607);
}
test "user flow trellis case 609" {
    try verifyUserFlowTrellisCase(608);
}
test "user flow trellis case 610" {
    try verifyUserFlowTrellisCase(609);
}
test "user flow trellis case 611" {
    try verifyUserFlowTrellisCase(610);
}
test "user flow trellis case 612" {
    try verifyUserFlowTrellisCase(611);
}
test "user flow trellis case 613" {
    try verifyUserFlowTrellisCase(612);
}
test "user flow trellis case 614" {
    try verifyUserFlowTrellisCase(613);
}
test "user flow trellis case 615" {
    try verifyUserFlowTrellisCase(614);
}
test "user flow trellis case 616" {
    try verifyUserFlowTrellisCase(615);
}
test "user flow trellis case 617" {
    try verifyUserFlowTrellisCase(616);
}
test "user flow trellis case 618" {
    try verifyUserFlowTrellisCase(617);
}
test "user flow trellis case 619" {
    try verifyUserFlowTrellisCase(618);
}
test "user flow trellis case 620" {
    try verifyUserFlowTrellisCase(619);
}
test "user flow trellis case 621" {
    try verifyUserFlowTrellisCase(620);
}
test "user flow trellis case 622" {
    try verifyUserFlowTrellisCase(621);
}
test "user flow trellis case 623" {
    try verifyUserFlowTrellisCase(622);
}
test "user flow trellis case 624" {
    try verifyUserFlowTrellisCase(623);
}
test "user flow trellis case 625" {
    try verifyUserFlowTrellisCase(624);
}
test "user flow trellis case 626" {
    try verifyUserFlowTrellisCase(625);
}
test "user flow trellis case 627" {
    try verifyUserFlowTrellisCase(626);
}
test "user flow trellis case 628" {
    try verifyUserFlowTrellisCase(627);
}
test "user flow trellis case 629" {
    try verifyUserFlowTrellisCase(628);
}
test "user flow trellis case 630" {
    try verifyUserFlowTrellisCase(629);
}
test "user flow trellis case 631" {
    try verifyUserFlowTrellisCase(630);
}
test "user flow trellis case 632" {
    try verifyUserFlowTrellisCase(631);
}
test "user flow trellis case 633" {
    try verifyUserFlowTrellisCase(632);
}
test "user flow trellis case 634" {
    try verifyUserFlowTrellisCase(633);
}
test "user flow trellis case 635" {
    try verifyUserFlowTrellisCase(634);
}
test "user flow trellis case 636" {
    try verifyUserFlowTrellisCase(635);
}
test "user flow trellis case 637" {
    try verifyUserFlowTrellisCase(636);
}
test "user flow trellis case 638" {
    try verifyUserFlowTrellisCase(637);
}
test "user flow trellis case 639" {
    try verifyUserFlowTrellisCase(638);
}
test "user flow trellis case 640" {
    try verifyUserFlowTrellisCase(639);
}
test "user flow trellis case 641" {
    try verifyUserFlowTrellisCase(640);
}
test "user flow trellis case 642" {
    try verifyUserFlowTrellisCase(641);
}
test "user flow trellis case 643" {
    try verifyUserFlowTrellisCase(642);
}
test "user flow trellis case 644" {
    try verifyUserFlowTrellisCase(643);
}
test "user flow trellis case 645" {
    try verifyUserFlowTrellisCase(644);
}
test "user flow trellis case 646" {
    try verifyUserFlowTrellisCase(645);
}
test "user flow trellis case 647" {
    try verifyUserFlowTrellisCase(646);
}
test "user flow trellis case 648" {
    try verifyUserFlowTrellisCase(647);
}
test "user flow trellis case 649" {
    try verifyUserFlowTrellisCase(648);
}
test "user flow trellis case 650" {
    try verifyUserFlowTrellisCase(649);
}
test "user flow trellis case 651" {
    try verifyUserFlowTrellisCase(650);
}
test "user flow trellis case 652" {
    try verifyUserFlowTrellisCase(651);
}
test "user flow trellis case 653" {
    try verifyUserFlowTrellisCase(652);
}
test "user flow trellis case 654" {
    try verifyUserFlowTrellisCase(653);
}
test "user flow trellis case 655" {
    try verifyUserFlowTrellisCase(654);
}
test "user flow trellis case 656" {
    try verifyUserFlowTrellisCase(655);
}
test "user flow trellis case 657" {
    try verifyUserFlowTrellisCase(656);
}
test "user flow trellis case 658" {
    try verifyUserFlowTrellisCase(657);
}
test "user flow trellis case 659" {
    try verifyUserFlowTrellisCase(658);
}
test "user flow trellis case 660" {
    try verifyUserFlowTrellisCase(659);
}
test "user flow trellis case 661" {
    try verifyUserFlowTrellisCase(660);
}
test "user flow trellis case 662" {
    try verifyUserFlowTrellisCase(661);
}
test "user flow trellis case 663" {
    try verifyUserFlowTrellisCase(662);
}
test "user flow trellis case 664" {
    try verifyUserFlowTrellisCase(663);
}
test "user flow trellis case 665" {
    try verifyUserFlowTrellisCase(664);
}
test "user flow trellis case 666" {
    try verifyUserFlowTrellisCase(665);
}
test "user flow trellis case 667" {
    try verifyUserFlowTrellisCase(666);
}
