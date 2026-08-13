const std = @import("std");
const VAR1 = @import("VAR1");

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn execCtx(workspace_root: []const u8) VAR1.core.tool_runtime.ExecutionContext {
    return .{
        .workspace_root = workspace_root,
    };
}

test "prompt builder emits ordered guardrails and tool contract" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const prompt = try VAR1.core.prompts.buildAgentSystemPrompt(
        std.testing.allocator,
        execCtx(workspace_root),
        .{},
    );
    defer std.testing.allocator.free(prompt);

    // Envelope structure — identity-first ordering.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# VAR1 Prompt Envelope") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Current Mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Internal Runtime Guardrails") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Developer Discipline") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Operating Core") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Skill Routing Contract") != null);

    // Identity — behavioral, not architectural. No internal-mechanic leaks.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "senior engineering orchestrator") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Delegate ravenously") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Calibrate your confidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Meta-reason when stuck") != null);

    // Architecture-leak guard: these terms reveal the strategy, not embody it.
    // Note: "append-only" legitimately appears in tool descriptions (append_file,
    // list_processes); "kernel_fallback" is a literal source enum value the model
    // must recognize. Those are tool/config documentation, not strategy leakage.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "causal chain") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "context compiler") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "event spine") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "the cockpit") == null);

    // Five consolidated protocols.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Evidence Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Delegation Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Edit Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Continuity Protocol") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## Evolution Protocol") != null);

    // Delegation protocol — "never delegate understanding" rule + synthesis procedure.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Never delegate understanding") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "falsify before averaging") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Read-only tracks (research, recon) can parallelize freely") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "quiet, inspect, message, challenge, launch, queue, or wake") != null);

    // Continuity protocol — interjection + memory + session summary.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "USER_STEER_MESSAGE") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "messages.jsonl remains transcript truth") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "update_session_summary before your turn ends") != null);

    // Evolution protocol — tickets + knowledge logging + scheduling + self-tuning.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "VANTARI tunes its own configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, ".var/tickets/") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "A missing knowledge surface is a drift signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "durable jobs live under .var/schedules") != null);

    // Edit protocol — tool routing + path + file inspection.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "native IX expressions such as lit:needle") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "paths are relative to the displayed workspace root") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "write_file may write the complete file") != null);

    // Tool catalog + capsules.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- list_files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- skill_info:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- planning-spec:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- insect:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Skills are reusable operating protocols") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "wait_agent accepts timeout_ms") != null);

    // Continuation contract survives the restructure.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Continue chaining bursts until terminal proof or a named blocker") != null);

    // Budgeted capsules — routing decision tree is now present.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Skill Routing Decision Tree") != null);

    // Legacy phrases removed by the rewrite.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Tool Use Contract") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# System Prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Developer Prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Slow is smooth") == null);
}

test "prompt builder loads project-local system and developer prompt files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);

    const system_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "system.md" });
    defer allocator.free(system_path);
    const developer_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "developer.md" });
    defer allocator.free(developer_path);

    try VAR1.shared.fsutil.writeText(system_path, "# System Prompt\nCustom system invariant.\n");
    try VAR1.shared.fsutil.writeText(developer_path, "# Developer Prompt\nCustom developer invariant.\n");

    var policy = VAR1.shared.types.PromptPolicy{
        .system_prompt_file = try allocator.dupe(u8, ".var/prompts/system.md"),
        .developer_prompt_file = try allocator.dupe(u8, ".var/prompts/developer.md"),
    };
    defer policy.deinit(allocator);

    const prompt = try VAR1.core.prompts.buildAgentSystemPrompt(
        allocator,
        execCtx(workspace_root),
        policy,
    );
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Custom system invariant.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Custom developer invariant.") != null);
    // The runtime-owned continuation contract survives project-local
    // system and developer overrides.
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Continue chaining bursts until terminal proof or a named blocker") != null);
}

test "prompt builder fails closed for explicit missing or empty prompt layers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);

    var missing_policy = VAR1.shared.types.PromptPolicy{
        .system_prompt_file = try allocator.dupe(u8, ".var/prompts/missing-system.md"),
    };
    defer missing_policy.deinit(allocator);

    try std.testing.expectError(
        VAR1.core.prompts.builder.Error.PromptLayerUnavailable,
        VAR1.core.prompts.buildAgentSystemPrompt(
            allocator,
            execCtx(workspace_root),
            missing_policy,
        ),
    );

    const empty_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "empty-developer.md" });
    defer allocator.free(empty_path);
    try VAR1.shared.fsutil.writeText(empty_path, " \n\t\n");

    var empty_policy = VAR1.shared.types.PromptPolicy{
        .developer_prompt_file = try allocator.dupe(u8, ".var/prompts/empty-developer.md"),
    };
    defer empty_policy.deinit(allocator);

    try std.testing.expectError(
        VAR1.core.prompts.builder.Error.EmptyPromptLayer,
        VAR1.core.prompts.buildAgentSystemPrompt(
            allocator,
            execCtx(workspace_root),
            empty_policy,
        ),
    );
}

test "prompt profiles choose collaboration posture without executor branches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const allocator = std.testing.allocator;
    const workspace_root = try tmpWorkspacePath(allocator, &tmp);
    defer allocator.free(workspace_root);

    const quiet_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "quiet.md" });
    defer allocator.free(quiet_path);
    const hive_path = try std.fs.path.join(allocator, &.{ workspace_root, ".var", "prompts", "hive.md" });
    defer allocator.free(hive_path);
    try VAR1.shared.fsutil.writeText(quiet_path, "# Quiet profile\nWork inline. Stay quiet unless collaboration is necessary.\n");
    try VAR1.shared.fsutil.writeText(hive_path, "# Hive profile\nInspect the team and collaborate whenever independent evidence can compound.\n");

    var quiet_policy = VAR1.shared.types.PromptPolicy{
        .system_prompt_file = try allocator.dupe(u8, ".var/prompts/quiet.md"),
    };
    defer quiet_policy.deinit(allocator);
    const quiet = try VAR1.core.prompts.buildAgentSystemPrompt(allocator, execCtx(workspace_root), quiet_policy);
    defer allocator.free(quiet);

    var hive_policy = VAR1.shared.types.PromptPolicy{
        .system_prompt_file = try allocator.dupe(u8, ".var/prompts/hive.md"),
    };
    defer hive_policy.deinit(allocator);
    const hive = try VAR1.core.prompts.buildAgentSystemPrompt(allocator, execCtx(workspace_root), hive_policy);
    defer allocator.free(hive);

    try std.testing.expect(std.mem.indexOf(u8, quiet, "Work inline. Stay quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, hive, "Inspect the team and collaborate") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Delegate ravenously") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "Delegate the moment work is branchable") == null);
    try std.testing.expect(std.mem.indexOf(u8, hive, "Delegate the moment work is branchable") == null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "quiet, inspect, message, challenge, launch, queue, or wake") != null);
    try std.testing.expect(std.mem.indexOf(u8, hive, "quiet, inspect, message, challenge, launch, queue, or wake") != null);
    try std.testing.expect(std.mem.indexOf(u8, quiet, "- send_agent_message:") != null);
    try std.testing.expect(std.mem.indexOf(u8, hive, "- send_agent_message:") != null);
}
