const std = @import("std");
const VAR1 = @import("VAR1");

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn verifyCliUsablePipelineCase(index: usize) !void {
    switch (index % 12) {
        0 => {
            const session_id = try std.fmt.allocPrint(std.testing.allocator, "session-{d}-abc", .{index});
            defer std.testing.allocator.free(session_id);
            const envelope = try VAR1.clients.cli.renderSessionRunningEnvelope(std.testing.allocator, session_id);
            defer std.testing.allocator.free(envelope);
            try expectContains(envelope, "VAR1_STATUS category=session code=Running");
            try expectContains(envelope, "provider execution started");
            try expectContains(envelope, session_id);
            try expectNotContains(envelope, "VAR1_ERROR");
        },
        1 => {
            const session_id = try std.fmt.allocPrint(std.testing.allocator, "session-{d}-quoted", .{index});
            defer std.testing.allocator.free(session_id);
            const failure = switch (index % 4) {
                0 => "BadStatus",
                1 => "ConnectionRefused",
                2 => "ToolBudgetExceeded",
                else => "UnresolvedToolCallTranscript",
            };
            const envelope = try VAR1.clients.cli.renderSessionFailureEnvelope(std.testing.allocator, session_id, failure);
            defer std.testing.allocator.free(envelope);
            try expectContains(envelope, "VAR1_ERROR category=session");
            try expectContains(envelope, failure);
            try expectContains(envelope, session_id);
            try expectNotContains(envelope, "Execution failed");
        },
        2 => {
            const payload = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"code\":-3200{d},\"message\":\"Session {d} failed before output\"}}",
                .{ index % 10, index },
            );
            defer std.testing.allocator.free(payload);
            const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, payload);
            defer std.testing.allocator.free(envelope);
            try expectContains(envelope, "VAR1_ERROR category=kernel_rpc");
            try expectContains(envelope, "Session ");
            try expectNotContains(envelope, "unparsable");
        },
        3 => {
            const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, "{");
            defer std.testing.allocator.free(envelope);
            try std.testing.expectEqualStrings(
                "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned an unparsable error envelope\"\n",
                envelope,
            );
        },
        4 => {
            const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, "[]");
            defer std.testing.allocator.free(envelope);
            try std.testing.expectEqualStrings(
                "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned a non-object error envelope\"\n",
                envelope,
            );
        },
        5 => {
            const err = switch (index % 3) {
                0 => error.InvalidRpcResponse,
                1 => error.BrokenPipe,
                else => error.ConnectionResetByPeer,
            };
            const envelope = try VAR1.clients.cli.renderKernelTransportErrorEnvelope(std.testing.allocator, err);
            defer std.testing.allocator.free(envelope);
            try expectContains(envelope, @errorName(err));
            try expectContains(envelope, "kernel stdio host closed");
        },
        6 => {
            const topic = switch (index % 7) {
                0 => @as(?[]const u8, null),
                1 => "run",
                2 => "c",
                3 => "workspace",
                4 => "health",
                5 => "serve",
                else => "tools",
            };
            const help = VAR1.clients.cli.helpText(topic).?;
            try expectContains(help, "Usage:");
            try std.testing.expect(
                std.mem.indexOf(u8, help, "VAR1") != null or
                    std.mem.indexOf(u8, help, "var ") != null or
                    std.mem.indexOf(u8, help, "vantari") != null,
            );
            if (topic) |name| {
                if (std.mem.eql(u8, name, "serve")) try expectNotContains(help, "/api/tasks");
                if (std.mem.eql(u8, name, "health")) try expectContains(help, "does not send a model completion request");
            } else {
                try expectContains(help, "vantari");
                try expectContains(help, "PowerShell reserves bare var");
            }
        },
        7 => {
            const root = try std.fmt.allocPrint(std.testing.allocator, "C:\\Users\\Savage\\AppData\\Local\\case-{d}", .{index});
            defer std.testing.allocator.free(root);
            const path = try VAR1.core.auth_store.installedAuthFilePathFromRoot(std.testing.allocator, root);
            defer std.testing.allocator.free(path);
            try expectContains(path, "Vantari");
            try expectContains(path, "auth");
            try expectContains(path, "auth.json");
            try expectNotContains(path, ".var\\sessions");
        },
        8 => {
            const prompt = try std.fmt.allocPrint(std.testing.allocator, "inline prompt {d}", .{index});
            defer std.testing.allocator.free(prompt);
            const resolved = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, prompt, null);
            defer std.testing.allocator.free(resolved);
            try std.testing.expectEqualStrings(prompt, resolved);
        },
        9 => {
            const tool_name = switch (index % 6) {
                0 => "read_file",
                1 => "list_files",
                2 => "search_files",
                3 => "write_file",
                4 => "append_file",
                else => "replace_in_file",
            };
            const decision = VAR1.core.tool_runtime.review.reviewToolName(tool_name, VAR1.core.tool_runtime.builtinDefinitions(false));
            try std.testing.expect(decision.approved);
            try std.testing.expectEqualStrings("tool_reviewed", decision.event_type);
        },
        10 => {
            const name = try std.fmt.allocPrint(std.testing.allocator, "unknown_tool_{d}", .{index});
            defer std.testing.allocator.free(name);
            const decision = VAR1.core.tool_runtime.review.reviewToolName(name, VAR1.core.tool_runtime.builtinDefinitions(true));
            try std.testing.expect(!decision.approved);
            try std.testing.expect(decision.tool_error_hint != null);
            try std.testing.expectEqual(VAR1.core.tool_runtime.review.ToolReviewRisk.unknown_high_impact, decision.risk);
        },
        else => {
            const payload = try VAR1.core.tool_runtime.renderExecutionError(
                std.testing.allocator,
                "launch_agent",
                "UnsupportedDelegationScope",
                "{\"prompt\":\"expand\",\"scope_depth\":2}",
            );
            defer std.testing.allocator.free(payload);
            try expectContains(payload, "UnsupportedDelegationScope");
            try expectContains(payload, "escalation_reason");
            try expectContains(payload, "parameters_schema");
        },
    }
}

test "cli usable pipeline adversarial case 001" {
    try verifyCliUsablePipelineCase(0);
}
test "cli usable pipeline adversarial case 002" {
    try verifyCliUsablePipelineCase(1);
}
test "cli usable pipeline adversarial case 003" {
    try verifyCliUsablePipelineCase(2);
}
test "cli usable pipeline adversarial case 004" {
    try verifyCliUsablePipelineCase(3);
}
test "cli usable pipeline adversarial case 005" {
    try verifyCliUsablePipelineCase(4);
}
test "cli usable pipeline adversarial case 006" {
    try verifyCliUsablePipelineCase(5);
}
test "cli usable pipeline adversarial case 007" {
    try verifyCliUsablePipelineCase(6);
}
test "cli usable pipeline adversarial case 008" {
    try verifyCliUsablePipelineCase(7);
}
test "cli usable pipeline adversarial case 009" {
    try verifyCliUsablePipelineCase(8);
}
test "cli usable pipeline adversarial case 010" {
    try verifyCliUsablePipelineCase(9);
}
test "cli usable pipeline adversarial case 011" {
    try verifyCliUsablePipelineCase(10);
}
test "cli usable pipeline adversarial case 012" {
    try verifyCliUsablePipelineCase(11);
}
test "cli usable pipeline adversarial case 013" {
    try verifyCliUsablePipelineCase(12);
}
test "cli usable pipeline adversarial case 014" {
    try verifyCliUsablePipelineCase(13);
}
test "cli usable pipeline adversarial case 015" {
    try verifyCliUsablePipelineCase(14);
}
test "cli usable pipeline adversarial case 016" {
    try verifyCliUsablePipelineCase(15);
}
test "cli usable pipeline adversarial case 017" {
    try verifyCliUsablePipelineCase(16);
}
test "cli usable pipeline adversarial case 018" {
    try verifyCliUsablePipelineCase(17);
}
test "cli usable pipeline adversarial case 019" {
    try verifyCliUsablePipelineCase(18);
}
test "cli usable pipeline adversarial case 020" {
    try verifyCliUsablePipelineCase(19);
}
test "cli usable pipeline adversarial case 021" {
    try verifyCliUsablePipelineCase(20);
}
test "cli usable pipeline adversarial case 022" {
    try verifyCliUsablePipelineCase(21);
}
test "cli usable pipeline adversarial case 023" {
    try verifyCliUsablePipelineCase(22);
}
test "cli usable pipeline adversarial case 024" {
    try verifyCliUsablePipelineCase(23);
}
test "cli usable pipeline adversarial case 025" {
    try verifyCliUsablePipelineCase(24);
}
test "cli usable pipeline adversarial case 026" {
    try verifyCliUsablePipelineCase(25);
}
test "cli usable pipeline adversarial case 027" {
    try verifyCliUsablePipelineCase(26);
}
test "cli usable pipeline adversarial case 028" {
    try verifyCliUsablePipelineCase(27);
}
test "cli usable pipeline adversarial case 029" {
    try verifyCliUsablePipelineCase(28);
}
test "cli usable pipeline adversarial case 030" {
    try verifyCliUsablePipelineCase(29);
}
test "cli usable pipeline adversarial case 031" {
    try verifyCliUsablePipelineCase(30);
}
test "cli usable pipeline adversarial case 032" {
    try verifyCliUsablePipelineCase(31);
}
test "cli usable pipeline adversarial case 033" {
    try verifyCliUsablePipelineCase(32);
}
test "cli usable pipeline adversarial case 034" {
    try verifyCliUsablePipelineCase(33);
}
test "cli usable pipeline adversarial case 035" {
    try verifyCliUsablePipelineCase(34);
}
test "cli usable pipeline adversarial case 036" {
    try verifyCliUsablePipelineCase(35);
}
test "cli usable pipeline adversarial case 037" {
    try verifyCliUsablePipelineCase(36);
}
test "cli usable pipeline adversarial case 038" {
    try verifyCliUsablePipelineCase(37);
}
test "cli usable pipeline adversarial case 039" {
    try verifyCliUsablePipelineCase(38);
}
test "cli usable pipeline adversarial case 040" {
    try verifyCliUsablePipelineCase(39);
}
test "cli usable pipeline adversarial case 041" {
    try verifyCliUsablePipelineCase(40);
}
test "cli usable pipeline adversarial case 042" {
    try verifyCliUsablePipelineCase(41);
}
test "cli usable pipeline adversarial case 043" {
    try verifyCliUsablePipelineCase(42);
}
test "cli usable pipeline adversarial case 044" {
    try verifyCliUsablePipelineCase(43);
}
test "cli usable pipeline adversarial case 045" {
    try verifyCliUsablePipelineCase(44);
}
test "cli usable pipeline adversarial case 046" {
    try verifyCliUsablePipelineCase(45);
}
test "cli usable pipeline adversarial case 047" {
    try verifyCliUsablePipelineCase(46);
}
test "cli usable pipeline adversarial case 048" {
    try verifyCliUsablePipelineCase(47);
}
test "cli usable pipeline adversarial case 049" {
    try verifyCliUsablePipelineCase(48);
}
test "cli usable pipeline adversarial case 050" {
    try verifyCliUsablePipelineCase(49);
}
test "cli usable pipeline adversarial case 051" {
    try verifyCliUsablePipelineCase(50);
}
test "cli usable pipeline adversarial case 052" {
    try verifyCliUsablePipelineCase(51);
}
test "cli usable pipeline adversarial case 053" {
    try verifyCliUsablePipelineCase(52);
}
test "cli usable pipeline adversarial case 054" {
    try verifyCliUsablePipelineCase(53);
}
test "cli usable pipeline adversarial case 055" {
    try verifyCliUsablePipelineCase(54);
}
test "cli usable pipeline adversarial case 056" {
    try verifyCliUsablePipelineCase(55);
}
test "cli usable pipeline adversarial case 057" {
    try verifyCliUsablePipelineCase(56);
}
test "cli usable pipeline adversarial case 058" {
    try verifyCliUsablePipelineCase(57);
}
test "cli usable pipeline adversarial case 059" {
    try verifyCliUsablePipelineCase(58);
}
test "cli usable pipeline adversarial case 060" {
    try verifyCliUsablePipelineCase(59);
}
test "cli usable pipeline adversarial case 061" {
    try verifyCliUsablePipelineCase(60);
}
test "cli usable pipeline adversarial case 062" {
    try verifyCliUsablePipelineCase(61);
}
test "cli usable pipeline adversarial case 063" {
    try verifyCliUsablePipelineCase(62);
}
test "cli usable pipeline adversarial case 064" {
    try verifyCliUsablePipelineCase(63);
}
test "cli usable pipeline adversarial case 065" {
    try verifyCliUsablePipelineCase(64);
}
test "cli usable pipeline adversarial case 066" {
    try verifyCliUsablePipelineCase(65);
}
test "cli usable pipeline adversarial case 067" {
    try verifyCliUsablePipelineCase(66);
}
test "cli usable pipeline adversarial case 068" {
    try verifyCliUsablePipelineCase(67);
}
test "cli usable pipeline adversarial case 069" {
    try verifyCliUsablePipelineCase(68);
}
test "cli usable pipeline adversarial case 070" {
    try verifyCliUsablePipelineCase(69);
}
test "cli usable pipeline adversarial case 071" {
    try verifyCliUsablePipelineCase(70);
}
test "cli usable pipeline adversarial case 072" {
    try verifyCliUsablePipelineCase(71);
}
test "cli usable pipeline adversarial case 073" {
    try verifyCliUsablePipelineCase(72);
}
test "cli usable pipeline adversarial case 074" {
    try verifyCliUsablePipelineCase(73);
}
test "cli usable pipeline adversarial case 075" {
    try verifyCliUsablePipelineCase(74);
}
test "cli usable pipeline adversarial case 076" {
    try verifyCliUsablePipelineCase(75);
}
test "cli usable pipeline adversarial case 077" {
    try verifyCliUsablePipelineCase(76);
}
test "cli usable pipeline adversarial case 078" {
    try verifyCliUsablePipelineCase(77);
}
test "cli usable pipeline adversarial case 079" {
    try verifyCliUsablePipelineCase(78);
}
test "cli usable pipeline adversarial case 080" {
    try verifyCliUsablePipelineCase(79);
}
test "cli usable pipeline adversarial case 081" {
    try verifyCliUsablePipelineCase(80);
}
test "cli usable pipeline adversarial case 082" {
    try verifyCliUsablePipelineCase(81);
}
test "cli usable pipeline adversarial case 083" {
    try verifyCliUsablePipelineCase(82);
}
test "cli usable pipeline adversarial case 084" {
    try verifyCliUsablePipelineCase(83);
}
test "cli usable pipeline adversarial case 085" {
    try verifyCliUsablePipelineCase(84);
}
test "cli usable pipeline adversarial case 086" {
    try verifyCliUsablePipelineCase(85);
}
test "cli usable pipeline adversarial case 087" {
    try verifyCliUsablePipelineCase(86);
}
test "cli usable pipeline adversarial case 088" {
    try verifyCliUsablePipelineCase(87);
}
test "cli usable pipeline adversarial case 089" {
    try verifyCliUsablePipelineCase(88);
}
test "cli usable pipeline adversarial case 090" {
    try verifyCliUsablePipelineCase(89);
}
test "cli usable pipeline adversarial case 091" {
    try verifyCliUsablePipelineCase(90);
}
test "cli usable pipeline adversarial case 092" {
    try verifyCliUsablePipelineCase(91);
}
test "cli usable pipeline adversarial case 093" {
    try verifyCliUsablePipelineCase(92);
}
test "cli usable pipeline adversarial case 094" {
    try verifyCliUsablePipelineCase(93);
}
test "cli usable pipeline adversarial case 095" {
    try verifyCliUsablePipelineCase(94);
}
test "cli usable pipeline adversarial case 096" {
    try verifyCliUsablePipelineCase(95);
}
test "cli usable pipeline adversarial case 097" {
    try verifyCliUsablePipelineCase(96);
}
test "cli usable pipeline adversarial case 098" {
    try verifyCliUsablePipelineCase(97);
}
test "cli usable pipeline adversarial case 099" {
    try verifyCliUsablePipelineCase(98);
}
test "cli usable pipeline adversarial case 100" {
    try verifyCliUsablePipelineCase(99);
}
test "cli usable pipeline adversarial case 101" {
    try verifyCliUsablePipelineCase(100);
}
test "cli usable pipeline adversarial case 102" {
    try verifyCliUsablePipelineCase(101);
}
test "cli usable pipeline adversarial case 103" {
    try verifyCliUsablePipelineCase(102);
}
test "cli usable pipeline adversarial case 104" {
    try verifyCliUsablePipelineCase(103);
}
test "cli usable pipeline adversarial case 105" {
    try verifyCliUsablePipelineCase(104);
}
test "cli usable pipeline adversarial case 106" {
    try verifyCliUsablePipelineCase(105);
}
test "cli usable pipeline adversarial case 107" {
    try verifyCliUsablePipelineCase(106);
}
test "cli usable pipeline adversarial case 108" {
    try verifyCliUsablePipelineCase(107);
}
test "cli usable pipeline adversarial case 109" {
    try verifyCliUsablePipelineCase(108);
}
test "cli usable pipeline adversarial case 110" {
    try verifyCliUsablePipelineCase(109);
}
test "cli usable pipeline adversarial case 111" {
    try verifyCliUsablePipelineCase(110);
}

test "cli resolvePromptInput reads prompt files and trims trailing newlines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "prompt.txt",
        .data = "Count the lowercase letter r in strawberry.\n",
    });

    const prompt_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/prompt.txt",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(prompt_path);

    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, null, prompt_path);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("Count the lowercase letter r in strawberry.", prompt);
}

test "cli resolvePromptInput prefers inline prompt when present" {
    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, "inline prompt", null);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("inline prompt", prompt);
}

test "cli resolvePromptInput returns empty prompt for resume-only runs" {
    const prompt = try VAR1.clients.cli.resolvePromptInput(std.testing.allocator, null, null);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("", prompt);
}

test "cli root help advertises command discovery and tools json export" {
    const help = VAR1.clients.cli.helpText(null).?;

    try std.testing.expect(std.mem.indexOf(u8, help, "vantari") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "vantari -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "var <command> [flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "var c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "PowerShell reserves bare var") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 <command> [flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 health") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 tools --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 help <command>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "most recently updated session") != null);
}

test "cli recent-session help is canonical-store scoped" {
    const help = VAR1.clients.cli.helpText("c").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "var c [--limit <count>] [--json]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, ".var/sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "legacy or global runtime roots") != null);
    try std.testing.expect(VAR1.clients.cli.helpText("continue") != null);
    try std.testing.expect(VAR1.clients.cli.helpText("sessions") != null);
}

test "cli recent-session json keeps hydrated outputs alive through render" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "resume this session");
    defer session.deinit(std.testing.allocator);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, session.id, "assistant output survives projection");

    const rendered = try VAR1.clients.cli.renderSessionListJson(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "assistant output survives projection") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, session.id) != null);
}

test "cli run help documents prompt-source exclusivity and session resume semantics" {
    const help = VAR1.clients.cli.helpText("run").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "--prompt-file <path>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--session-id <session-id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Exactly one prompt source is allowed") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "reuse its stored prompt") != null);
}

test "cli tools help documents schema fields" {
    const help = VAR1.clients.cli.helpText("tools").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "\"parameters_schema\": { ... }") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\"contract_example\": { ... }") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Workspace-state tools remain relevance-gated") != null);
}

test "cli health help documents readiness and operator projection output" {
    const help = VAR1.clients.cli.helpText("health").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "pool capacity") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "ticket pressure") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "does not send a model completion request") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 health --json") != null);
}

test "cli serve help documents canonical bridge routes only" {
    const help = VAR1.clients.cli.helpText("serve").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "POST /rpc") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "GET  /events") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "GET  /api/health") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "/api/tasks") == null);
}

test "cli kernel error envelope preserves code and JSON-escapes message" {
    const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(
        std.testing.allocator,
        "{\"code\":-32001,\"message\":\"Session \\\"not\\\" found\"}",
    );
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_ERROR category=kernel_rpc code=-32001 message=\"Session \\\"not\\\" found\"\n",
        envelope,
    );
}

test "cli kernel error envelope handles malformed remote error JSON" {
    const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, "{");
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned an unparsable error envelope\"\n",
        envelope,
    );
}

test "cli kernel error envelope handles non-object remote error JSON" {
    const envelope = try VAR1.clients.cli.renderKernelErrorEnvelope(std.testing.allocator, "[]");
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_ERROR category=kernel_rpc code=RemoteError message=\"kernel returned a non-object error envelope\"\n",
        envelope,
    );
}

test "cli kernel transport error envelope names child stdio failure" {
    const envelope = try VAR1.clients.cli.renderKernelTransportErrorEnvelope(std.testing.allocator, error.InvalidRpcResponse);
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_ERROR category=kernel_transport code=InvalidRpcResponse message=\"kernel stdio host closed before returning a valid JSON-RPC response\"\n",
        envelope,
    );
}

test "cli session failure envelope preserves durable failure reason and session id" {
    const envelope = try VAR1.clients.cli.renderSessionFailureEnvelope(
        std.testing.allocator,
        "session-1",
        "BadStatus",
    );
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_ERROR category=session code=BadStatus message=\"session failed\" session_id=\"session-1\"\n",
        envelope,
    );
}

test "cli session running envelope exposes started provider execution" {
    const envelope = try VAR1.clients.cli.renderSessionRunningEnvelope(std.testing.allocator, "session-1");
    defer std.testing.allocator.free(envelope);

    try std.testing.expectEqualStrings(
        "VAR1_STATUS category=session code=Running message=\"provider execution started\" session_id=\"session-1\"\n",
        envelope,
    );
}
