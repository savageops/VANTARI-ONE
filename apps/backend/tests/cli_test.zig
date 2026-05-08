const std = @import("std");
const VAR1 = @import("VAR1");

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
    try std.testing.expect(std.mem.indexOf(u8, help, "var <command> [flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "var c") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "PowerShell reserves bare var") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 <command> [flags]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 health") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 tools --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "VAR1 help <command>") != null);
}

test "cli recent-session help is canonical-store scoped" {
    const help = VAR1.clients.cli.helpText("c").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "var c [--limit <count>] [--json]") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, ".var/sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "legacy or global runtime roots") != null);
    try std.testing.expect(VAR1.clients.cli.helpText("continue") != null);
    try std.testing.expect(VAR1.clients.cli.helpText("sessions") != null);
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

test "cli health help documents config-only readiness output" {
    const help = VAR1.clients.cli.helpText("health").?;

    try std.testing.expect(std.mem.indexOf(u8, help, "\"base_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "\"auth_provider\"") != null);
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
