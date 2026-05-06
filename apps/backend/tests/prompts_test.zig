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

    try std.testing.expect(std.mem.indexOf(u8, prompt, "# VAR1 Prompt Envelope") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Internal Runtime Guardrails") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# System Prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Developer Prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Tool Use Contract") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- list_files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Call contract: pass one JSON object") != null);
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
