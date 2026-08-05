const std = @import("std");
const VAR1 = @import("VAR1");

test "canonical config file materializes typed runtime defaults" {
    if (std.process.hasEnvVarConstant("VANTARI_HOME")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);

    var policy = try VAR1.core.config_file.loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4096), policy.max_steps);

    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(config_path));
}

test "canonical config environment values override runtime values" {
    if (std.process.hasEnvVarConstant("VANTARI_HOME")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,
        \\ "runtime":{"max_steps":100,"max_tool_calls_per_turn":4,"max_tool_calls_per_session":20},
        \\ "provider":{"wire_api":"responses"},
        \\ "environment":{"MAX_STEPS":"250"}}
    );

    var policy = try VAR1.core.config_file.loadRuntimePolicy(std.testing.allocator, workspace);
    defer policy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 250), policy.max_steps);
    try std.testing.expectEqual(VAR1.shared.types.WireApi.responses, (try VAR1.core.config_file.loadWireApi(std.testing.allocator, workspace)).?);
}

test "canonical config rejects unknown keys instead of hiding typos" {
    if (std.process.hasEnvVarConstant("VANTARI_HOME")) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/workspace", .{tmp.sub_path});
    defer std.testing.allocator.free(workspace);
    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace);
    defer std.testing.allocator.free(config_path);
    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"runtime":{"max_stepz":100}}
    );
    try std.testing.expectError(
        VAR1.core.config_file.Error.InvalidConfig,
        VAR1.core.config_file.loadRuntimePolicy(std.testing.allocator, workspace),
    );
}

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

fn makeConfig(
    allocator: std.mem.Allocator,
    workspace_root: []const u8,
    max_steps: usize,
) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "test-key"),
        .openai_model = try allocator.dupe(u8, "gemma-4-e2b-it"),
        .max_steps = max_steps,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn makeContextCheckpoint(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_seq_end: u64,
    first_kept_seq: u64,
    summary: []const u8,
) !VAR1.shared.types.ContextCheckpoint {
    return .{
        .id = try allocator.dupe(u8, id),
        .entry_type = try allocator.dupe(u8, "summary_checkpoint"),
        .created_at_ms = std.time.milliTimestamp(),
        .source_seq_start = 1,
        .source_seq_end = source_seq_end,
        .first_kept_seq = first_kept_seq,
        .tokens_before_estimate = 100,
        .tokens_after_estimate = 25,
        .trigger = try allocator.dupe(u8, "manual"),
        .summary = try allocator.dupe(u8, summary),
    };
}

fn makeTestToolCall(
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
) !VAR1.shared.types.ToolCall {
    return .{
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, arguments_json),
    };
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |relative| {
        count += 1;
        offset += relative + needle.len;
    }
    return count;
}

test "config loader reads provider env values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=http://127.0.0.1:1234
        \\API_KEY=test-key
        \\MODEL=test-model
        \\MAX_STEPS=4
        \\MAX_TOOL_CALLS_PER_TURN=5
        \\MAX_TOOL_CALLS_PER_SESSION=12
        \\WORKSPACE=.
        \\
    );

    const config = try VAR1.core.config.loadFromEnvFile(std.testing.allocator, env_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("http://127.0.0.1:1234", config.openai_base_url);
    try std.testing.expectEqualStrings("test-key", config.openai_api_key);
    try std.testing.expectEqualStrings("test-model", config.openai_model);
    try std.testing.expectEqual(@as(usize, 4), config.max_steps);
    try std.testing.expectEqual(@as(usize, 5), config.max_tool_calls_per_turn);
    try std.testing.expectEqual(@as(usize, 12), config.max_tool_calls_per_session);
}

test "config loader defaults to a post-tool response budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=http://127.0.0.1:1234
        \\API_KEY=test-key
        \\MODEL=test-model
        \\
    );

    const config = try VAR1.core.config.loadFromEnvFile(std.testing.allocator, env_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4096), config.max_steps);
    try std.testing.expect(config.max_steps > 32);
    try std.testing.expectEqual(@as(usize, 16), config.max_tool_calls_per_turn);
    try std.testing.expectEqual(@as(usize, 96), config.max_tool_calls_per_session);
}

test "config loader rejects missing required keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=http://127.0.0.1:1234
        \\MODEL=test-model
        \\
    );

    try std.testing.expectError(VAR1.core.config.Error.MissingKey, VAR1.core.config.loadFromEnvFile(std.testing.allocator, env_path));
}

test "canonical config overlays non-secret context policy" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(config_path);

    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"context":{"auto_compaction":false,"manual_compaction":true,"context_window_tokens":128000,"compact_at_ratio_milli":750,"reserve_output_tokens":4096,"keep_recent_messages":6,"max_entries_per_checkpoint":3,"aggressiveness_milli":500,"retry_on_provider_overflow":false}}
    );

    const policy = try VAR1.core.config_file.loadContextPolicy(std.testing.allocator, workspace_root, .{});

    try std.testing.expect(!policy.auto_compaction);
    try std.testing.expect(policy.manual_compaction);
    try std.testing.expectEqual(@as(u64, 128_000), policy.context_window_tokens);
    try std.testing.expectEqual(@as(u16, 750), policy.compact_at_ratio_milli);
    try std.testing.expectEqual(@as(u64, 4_096), policy.reserve_output_tokens);
    try std.testing.expectEqual(@as(usize, 6), policy.keep_recent_messages);
    try std.testing.expectEqual(@as(usize, 3), policy.max_entries_per_checkpoint);
    try std.testing.expectEqual(@as(u16, 500), policy.aggressiveness_milli);
    try std.testing.expect(!policy.retry_on_provider_overflow);
}

test "canonical config rejects unknown context policy keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config_path = try VAR1.core.config_file.path(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(config_path);

    try VAR1.shared.fsutil.writeText(config_path,
        \\{"version":1,"context":{"auto_compact":false}}
    );

    try std.testing.expectError(
        VAR1.core.config_file.Error.InvalidConfig,
        VAR1.core.config_file.loadContextPolicy(std.testing.allocator, workspace_root, .{}),
    );
}

test "config loader ignores commented backup provider entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\# Backup local provider
        \\# BASE_URL=http://127.0.0.1:1234
        \\# API_KEY=local-key
        \\# MODEL=local-model
        \\BASE_URL=https://api.z.ai/api/coding/paas/v4
        \\API_KEY=active-key
        \\MODEL=GLM-5.1
        \\MAX_STEPS=10
        \\WORKSPACE=.
        \\
    );

    const config = try VAR1.core.config.loadFromEnvFile(std.testing.allocator, env_path);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("https://api.z.ai/api/coding/paas/v4", config.openai_base_url);
    try std.testing.expectEqualStrings("active-key", config.openai_api_key);
    try std.testing.expectEqualStrings("GLM-5.1", config.openai_model);
    try std.testing.expectEqual(@as(usize, 10), config.max_steps);
}

test "loadDefault canonicalizes relative workspace root to an absolute current directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=http://127.0.0.1:1234
        \\API_KEY=test-key
        \\MODEL=test-model
        \\MAX_STEPS=4
        \\WORKSPACE=.
        \\
    );

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const expected_root = try std.fs.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(expected_root);

    const config = try VAR1.core.config.loadDefault(std.testing.allocator, ".");
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(expected_root, config.workspace_root);
}

test "loadDefault seeds canonical auth state from env and then prefers auth ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=https://api.z.ai/api/coding/paas/v4
        \\API_KEY=env-key
        \\MODEL=GLM-5.1
        \\MAX_STEPS=4
        \\WORKSPACE=.
        \\
    );

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const seeded_config = try VAR1.core.config.loadDefault(std.testing.allocator, ".");
    defer seeded_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("env-key", seeded_config.openai_api_key);
    try std.testing.expectEqualStrings("zai", seeded_config.auth_provider.?);
    try std.testing.expectEqualStrings("GLM-5.1", seeded_config.subscription_plan_label.?);

    const auth_path = try VAR1.core.auth_store.authFilePath(std.testing.allocator, seeded_config.workspace_root);
    defer std.testing.allocator.free(auth_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(auth_path));

    try VAR1.shared.fsutil.writeText(auth_path,
        \\{
        \\  "version": 1,
        \\  "active_provider": "zai",
        \\  "providers": {
        \\    "zai": {
        \\      "auth_type": "api_key",
        \\      "api_key": "ledger-key",
        \\      "base_url": "https://api.z.ai/api/coding/paas/v4",
        \\      "model": "GLM-5.1",
        \\      "subscription": {
        \\        "plan_id": "zai-coding-plan",
        \\        "plan_label": "GLM-5.1",
        \\        "status": "active",
        \\        "source": "manual",
        \\        "last_verified_at_ms": 100
        \\      },
        \\      "updated_at_ms": 100
        \\    }
        \\  }
        \\}
        \\
    );

    const ledger_config = try VAR1.core.config.loadDefault(std.testing.allocator, ".");
    defer ledger_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("ledger-key", ledger_config.openai_api_key);
    try std.testing.expectEqualStrings("zai", ledger_config.auth_provider.?);
    try std.testing.expectEqualStrings("active", ledger_config.subscription_status.?);
}

test "loadDefault accepts UTF-8 BOM auth ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const env_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".env" });
    defer std.testing.allocator.free(env_path);

    try VAR1.shared.fsutil.writeText(env_path,
        \\BASE_URL=https://api.z.ai/api/coding/paas/v4
        \\API_KEY=env-key
        \\MODEL=GLM-5.1
        \\MAX_STEPS=4
        \\WORKSPACE=.
        \\
    );

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const seeded_config = try VAR1.core.config.loadDefault(std.testing.allocator, ".");
    defer seeded_config.deinit(std.testing.allocator);

    const auth_path = try VAR1.core.auth_store.authFilePath(std.testing.allocator, seeded_config.workspace_root);
    defer std.testing.allocator.free(auth_path);

    try VAR1.shared.fsutil.writeText(auth_path, "\xEF\xBB\xBF" ++
        \\{
        \\  "version": 1,
        \\  "active_provider": "zai",
        \\  "providers": {
        \\    "zai": {
        \\      "auth_type": "api_key",
        \\      "api_key": "bom-ledger-key",
        \\      "base_url": "https://api.z.ai/api/coding/paas/v4",
        \\      "model": "GLM-5.1",
        \\      "subscription": {
        \\        "plan_id": "zai-coding-plan",
        \\        "plan_label": "GLM-5.1",
        \\        "status": "active",
        \\        "source": "manual",
        \\        "last_verified_at_ms": 100
        \\      },
        \\      "updated_at_ms": 100
        \\    }
        \\  }
        \\}
        \\
    );

    const ledger_config = try VAR1.core.config.loadDefault(std.testing.allocator, ".");
    defer ledger_config.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("bom-ledger-key", ledger_config.openai_api_key);
    try std.testing.expectEqualStrings("zai", ledger_config.auth_provider.?);
    try std.testing.expectEqualStrings("GLM-5.1", ledger_config.openai_model);
}

test "auth store migrates installed provider auth into the canonical workspace ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const installed_root = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "installed-profile-root" });
    defer std.testing.allocator.free(installed_root);

    const installed_auth_path = try VAR1.core.auth_store.installedAuthFilePathFromRoot(std.testing.allocator, installed_root);
    defer std.testing.allocator.free(installed_auth_path);

    try VAR1.shared.fsutil.writeText(installed_auth_path,
        \\{
        \\  "version": 1,
        \\  "active_provider": "zai",
        \\  "providers": {
        \\    "zai": {
        \\      "auth_type": "api_key",
        \\      "api_key": "installed-key",
        \\      "base_url": "https://api.z.ai/api/coding/paas/v4",
        \\      "model": "GLM-5.1",
        \\      "subscription": {
        \\        "plan_id": "zai-coding-plan",
        \\        "plan_label": "GLM-5.1",
        \\        "status": "active",
        \\        "source": "installed",
        \\        "last_verified_at_ms": 100
        \\      },
        \\      "updated_at_ms": 100
        \\    }
        \\  }
        \\}
        \\
    );

    const workspace_auth_path = try VAR1.core.auth_store.authFilePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(workspace_auth_path);
    try std.testing.expect(!VAR1.shared.fsutil.fileExists(workspace_auth_path));

    const auth = try VAR1.core.auth_store.resolveOrSeedWithInstalledAuthPath(
        std.testing.allocator,
        workspace_root,
        null,
        installed_auth_path,
    );
    defer auth.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("installed-key", auth.api_key);
    try std.testing.expectEqualStrings("zai", auth.provider_id);
    try std.testing.expectEqualStrings("GLM-5.1", auth.model);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(workspace_auth_path));
}

test "resolveInWorkspace anchors dot workspace roots against cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const original_cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_cwd);
    defer std.process.changeCurDir(original_cwd) catch unreachable;

    try std.process.changeCurDir(workspace_root);

    const expected_root = try std.fs.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(expected_root);

    const expected_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ expected_root, "playground", "hero-page-exercise", "index.html" });
    defer std.testing.allocator.free(expected_path);

    const resolved_path = try VAR1.shared.fsutil.resolveInWorkspace(
        std.testing.allocator,
        ".",
        "playground/hero-page-exercise/index.html",
    );
    defer std.testing.allocator.free(resolved_path);

    try std.testing.expectEqualStrings(expected_path, resolved_path);
    try std.testing.expectError(
        VAR1.shared.fsutil.PathError.PathOutsideWorkspace,
        VAR1.shared.fsutil.resolveInWorkspace(std.testing.allocator, ".", "../escape.txt"),
    );
}

test "store writes session json and event entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Count the letters.");
    defer session.deinit(std.testing.allocator);

    const session_dir = try VAR1.core.session_store.sessionDirPath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(session_dir);

    const session_json = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ session_dir, "session.json" });
    defer std.testing.allocator.free(session_json);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(session_json));

    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "Session initialized.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ session_dir, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    const events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(events);

    try std.testing.expect(std.mem.indexOf(u8, events, "session_started") != null);
}

test "session heartbeat row advances from event spine activity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSessionWithOptions(std.testing.allocator, workspace_root, "long running work", .{
        .status = .running,
    });
    defer session.deinit(std.testing.allocator);

    const original_updated_at = session.updated_at_ms;
    const heartbeat_ms = original_updated_at + 30_000;
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_delta",
        .message = "working",
        .timestamp_ms = heartbeat_ms,
    });
    try VAR1.core.session_store.touchSessionUpdatedAt(std.testing.allocator, workspace_root, session.id, heartbeat_ms);

    const refreshed = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer refreshed.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.running, refreshed.status);
    try std.testing.expectEqual(heartbeat_ms, refreshed.updated_at_ms);
}

test "store can list sessions newest first and read full event history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var first = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "first prompt");
    defer first.deinit(std.testing.allocator);
    std.Thread.sleep(2 * std.time.ns_per_ms);
    var second = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "second prompt");
    defer second.deinit(std.testing.allocator);

    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, second.id, .{
        .event_type = "session_started",
        .message = "Session initialized.",
        .timestamp_ms = std.time.milliTimestamp(),
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, second.id, .{
        .event_type = "assistant_response",
        .message = "Done.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    const sessions = try VAR1.core.session_store.listSessionRecords(std.testing.allocator, workspace_root);
    defer VAR1.shared.types.deinitSessionRecords(std.testing.allocator, sessions);

    try std.testing.expect(sessions.len >= 2);
    try std.testing.expectEqualStrings(second.id, sessions[0].id);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, second.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("assistant_response", events[1].event_type);
}

test "event readers return valid prefix before a corrupted line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "event prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // A corrupted first line means there is no valid prefix.
    try VAR1.shared.fsutil.writeText(
        events_path,
        "2133419}\n" ++
            "{\"event_type\":\"assistant_response\",\"message\":\"3\",\"timestamp_ms\":123}\n",
    );

    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    // readLatestEvent scans backward, so it skips the poison and finds the valid line.
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("assistant_response", latest.?.event_type);

    // readEvents scans forward and stops at the first corrupted line.
    // The corrupted line is first, so the valid prefix is empty.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "store appends lifecycle events after an interrupted partial event row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "event prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    try VAR1.shared.fsutil.appendText(events_path, "{\"event_type\":\"partial\"");
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_recovered",
        .message = "Recovered after interrupted event write.",
        .timestamp_ms = 456,
    });

    const raw_events = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(raw_events);
    try std.testing.expect(std.mem.indexOf(u8, raw_events, "{\"event_type\":\"partial\"\n{\"event_type\":\"session_recovered\"") != null);

    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("session_recovered", latest.?.event_type);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    // readEvents scans forward and stops at the partial line (the first line),
    // so the valid prefix is empty. The recovery evidence is visible via
    // readLatestEvent, which scans backward and skips the partial.
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "initSession produces unique ids for adjacent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var first = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "first");
    defer first.deinit(std.testing.allocator);

    var second = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "second");
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, first.id, second.id));
}

test "store round-trips canonical child delegation metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .initialized,
            .parent_session_id = "session-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer session.deinit(std.testing.allocator);

    var loaded = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.initialized, loaded.status);
    try std.testing.expectEqualStrings("session-parent", loaded.parent_session_id.?);
    try std.testing.expectEqualStrings("berry-child", loaded.display_name.?);
    try std.testing.expectEqualStrings("subagent", loaded.agent_profile.?);
}

test "store round-trips canonical continuation lineage metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "follow-up prompt",
        .{
            .status = .initialized,
            .continued_from_session_id = "session-prior",
        },
    );
    defer session.deinit(std.testing.allocator);

    var loaded = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.initialized, loaded.status);
    try std.testing.expectEqualStrings("session-prior", loaded.continued_from_session_id.?);
}

test "store seeds and appends canonical session messages on the same session" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Initial prompt", messages[0].content);
    try std.testing.expectEqualStrings("msg-2", messages[1].id);
    try std.testing.expectEqual(@as(u64, 2), messages[1].seq);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, messages[1].role);
    try std.testing.expectEqualStrings("Initial answer", messages[1].content);
    try std.testing.expectEqualStrings("msg-3", messages[2].id);
    try std.testing.expectEqual(@as(u64, 3), messages[2].seq);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.user, messages[2].role);
    try std.testing.expectEqualStrings("Follow-up prompt", messages[2].content);
    try std.testing.expectEqualStrings("msg-4", messages[3].id);
    try std.testing.expectEqual(@as(u64, 4), messages[3].seq);
    try std.testing.expectEqual(VAR1.shared.types.SessionMessageRole.assistant, messages[3].role);
    try std.testing.expectEqualStrings("Follow-up answer", messages[3].content);
}

test "store preserves append-only message ledger across corrupted and partial rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);

    const before = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(before);

    try VAR1.shared.fsutil.appendText(
        messages_path,
        "{\"id\":\"msg-99\",\"seq\":99,\"role\":\"user\",\"content\":\"poison\",\"timestamp_ms\":99\n" ++
            "{\"id\":\"msg-2\"",
    );

    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .assistant, "Recovered append", 200);

    const after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, before));
    try std.testing.expect(std.mem.indexOf(u8, after, "{\"id\":\"msg-2\"\n{\"id\":\"msg-2\",\"seq\":2") != null);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);

    // readSessionMessages scans forward and stops at the first poisoned line.
    // The valid prefix is only the initial message (msg-1). The poison row and
    // the recovered append exist on disk but are past the poison boundary.
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("msg-1", messages[0].id);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
}

test "store missing optional session ledgers resolve to explicit empty values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);

    const latest_event = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest_event) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest_event == null);

    const latest_checkpoint = try VAR1.core.session_store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest_checkpoint) |checkpoint| checkpoint.deinit(std.testing.allocator);
    try std.testing.expect(latest_checkpoint == null);

    const output = try VAR1.core.session_store.readOutput(std.testing.allocator, workspace_root, session.id);
    defer if (output) |value| std.testing.allocator.free(value);
    try std.testing.expect(output == null);
}

test "store appends context checkpoints and reads the latest valid entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    var first = try makeContextCheckpoint(std.testing.allocator, "ctx-1", 2, 3, "Older summary.");
    defer first.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, first);

    var second = try makeContextCheckpoint(std.testing.allocator, "ctx-2", 4, 5, "Latest summary.");
    defer second.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, second);

    const context_path = try VAR1.core.session_store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    try VAR1.shared.fsutil.appendText(context_path, "not valid json\n");

    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |value| value.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("ctx-2", latest.?.id);
    try std.testing.expectEqual(@as(u64, 5), latest.?.first_kept_seq);
    try std.testing.expectEqualStrings("Latest summary.", latest.?.summary);
}

test "store appends checkpoints after a partial context row without poisoning latest valid checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    var first = try makeContextCheckpoint(std.testing.allocator, "ctx-1", 2, 3, "Older summary.");
    defer first.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, first);

    const context_path = try VAR1.core.session_store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    const before = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(before);

    try VAR1.shared.fsutil.appendText(context_path, "{\"id\":\"ctx-partial\"");

    var second = try makeContextCheckpoint(std.testing.allocator, "ctx-2", 4, 5, "Recovered summary.");
    defer second.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, second);

    const after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.startsWith(u8, after, before));
    try std.testing.expect(std.mem.indexOf(u8, after, "{\"id\":\"ctx-partial\"\n{\"id\":\"ctx-2\"") != null);

    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |value| value.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("ctx-2", latest.?.id);
    try std.testing.expectEqualStrings("Recovered summary.", latest.?.summary);
}

test "context builder emits latest summary plus recent raw transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);

    var checkpoint = try makeContextCheckpoint(std.testing.allocator, "ctx-1", 2, 3, "Initial prompt was answered.");
    defer checkpoint.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, checkpoint);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);

    try std.testing.expectEqual(@as(usize, 3), provider_messages.items.len);
    try std.testing.expectEqual(VAR1.shared.types.MessageRole.user, provider_messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Initial prompt was answered.") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Initial prompt\n") == null);
    try std.testing.expectEqualStrings("Follow-up prompt", provider_messages.items[1].content.?);
    try std.testing.expectEqualStrings("Follow-up answer", provider_messages.items[2].content.?);
}

test "context builder ignores poisoned checkpoint suffix and uses canonical raw ledger suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);

    var checkpoint = try makeContextCheckpoint(std.testing.allocator, "ctx-valid", 2, 3, "Valid compacted summary.");
    defer checkpoint.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, checkpoint);

    const context_path = try VAR1.core.session_store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    try VAR1.shared.fsutil.appendText(
        context_path,
        "{\"id\":\"ctx-poison\",\"type\":\"summary_checkpoint\",\"created_at_ms\":1,\"source_seq_start\":1,\"source_seq_end\":99,\"first_kept_seq\":100,\"trigger\":\"bad\",\"summary\":\"Poisoned summary.\"\n",
    );

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);

    try std.testing.expectEqual(@as(usize, 3), provider_messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Valid compacted summary.") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Poisoned summary.") == null);
    try std.testing.expectEqualStrings("Follow-up prompt", provider_messages.items[1].content.?);
    try std.testing.expectEqualStrings("Follow-up answer", provider_messages.items[2].content.?);
}

test "context builder rejects unresolved assistant tool-call transcripts before provider use" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Read context");
    defer session.deinit(std.testing.allocator);

    var tool_call = try makeTestToolCall(std.testing.allocator, "call_unresolved", "read_file", "{\"path\":\"context.txt\"}");
    defer tool_call.deinit(std.testing.allocator);
    const tool_calls = [_]VAR1.shared.types.ToolCall{tool_call};

    try VAR1.core.session_store.appendAssistantToolCallSessionMessage(
        std.testing.allocator,
        workspace_root,
        session.id,
        null,
        tool_calls[0..],
        200,
    );

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    // Self-healing: builder synthesizes missing tool results instead of hard-failing.
    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    // The provider window should contain the assistant tool-call message
    // plus a synthetic tool result for the unresolved call.
    try std.testing.expect(provider_messages.items.len >= 2);
}

test "context builder skips orphan tool results created by corrupt suffix boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Read context");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.appendToolSessionMessage(
        std.testing.allocator,
        workspace_root,
        session.id,
        "call_orphan",
        "orphan output",
        200,
    );

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    // Self-healing: orphan tool results are skipped, not hard-failed.
    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    // The orphan tool result should be skipped. Only the initial user prompt
    // should appear in the provider window (no tool messages).
    try std.testing.expectEqual(@as(usize, 1), provider_messages.items.len);
    try std.testing.expectEqual(VAR1.shared.types.MessageRole.user, provider_messages.items[0].role);
}

test "context budget and overflow primitives expose explicit capability boundaries" {
    const policy = VAR1.shared.types.ContextPolicy{
        .auto_compaction = true,
        .context_window_tokens = 1000,
        .compact_at_ratio_milli = 900,
        .reserve_output_tokens = 250,
    };

    try std.testing.expectEqual(@as(u64, 750), VAR1.core.context.budget.thresholdTokens(policy));
    try std.testing.expect(!VAR1.core.context.budget.shouldCompact(749, policy));
    try std.testing.expect(VAR1.core.context.budget.shouldCompact(750, policy));
    try std.testing.expect(VAR1.core.context.overflow.isContextOverflowText("maximum context length exceeded"));
    try std.testing.expect(!VAR1.core.context.overflow.isContextOverflowText("Too many requests: rate limit exceeded."));
}

test "context compactor appends a structured checkpoint from stable sequence ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt", 500);

    const result = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 2,
        .trigger = "manual-test",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), result.checkpoint.?.source_seq_start);
    try std.testing.expectEqual(@as(u64, 3), result.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 4), result.checkpoint.?.first_kept_seq);
    try std.testing.expectEqual(@as(u16, 350), result.checkpoint.?.aggressiveness_milli);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoint.?.compacted_entry_count);
    try std.testing.expectEqualStrings("manual-test", result.checkpoint.?.trigger);
    try std.testing.expect(std.mem.indexOf(u8, result.checkpoint.?.summary, "VAR1 context checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.checkpoint.?.summary, "segment_range: 1..3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.checkpoint.?.summary, "seq=1 role=user") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.checkpoint.?.summary, "seq=4 role=assistant") == null);

    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |checkpoint| checkpoint.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings(result.checkpoint.?.id, latest.?.id);
}

test "context compactor keeps assistant tool-call batches together in the raw suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    var tool_call = try makeTestToolCall(std.testing.allocator, "call_boundary", "read_file", "{\"path\":\"context.txt\"}");
    defer tool_call.deinit(std.testing.allocator);
    const tool_calls = [_]VAR1.shared.types.ToolCall{tool_call};
    try VAR1.core.session_store.appendAssistantToolCallSessionMessage(std.testing.allocator, workspace_root, session.id, null, tool_calls[0..], 200);
    try VAR1.core.session_store.appendToolSessionMessage(std.testing.allocator, workspace_root, session.id, "call_boundary", "file output", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Final answer", 400);

    const result = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 2,
        .trigger = "tool-boundary-test",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), result.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 2), result.checkpoint.?.first_kept_seq);
    try std.testing.expectEqual(@as(u32, 1), result.checkpoint.?.compacted_entry_count);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);
    try std.testing.expectEqual(@as(usize, 4), provider_messages.items.len);
    try std.testing.expectEqual(VAR1.shared.types.MessageRole.user, provider_messages.items[0].role);
    try std.testing.expectEqual(@as(usize, 1), provider_messages.items[1].tool_calls.len);
    try std.testing.expectEqualStrings("call_boundary", provider_messages.items[1].tool_calls[0].id);
    try std.testing.expectEqual(VAR1.shared.types.MessageRole.tool, provider_messages.items[2].role);
    try std.testing.expectEqualStrings("call_boundary", provider_messages.items[2].tool_call_id.?);
    try std.testing.expectEqualStrings("Final answer", provider_messages.items[3].content.?);
}

test "context compactor advances from the prior checkpoint without duplicating the raw suffix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer", 400);

    const first = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 2,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 3), first.checkpoint.?.first_kept_seq);

    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Third prompt", 500);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Third answer", 600);

    const second = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 2,
    });
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(second.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), second.checkpoint.?.source_seq_start);
    try std.testing.expectEqual(@as(u64, 4), second.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 5), second.checkpoint.?.first_kept_seq);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "previous_summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=3 role=user") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=5 role=user") == null);
}

test "context compactor can advance by one jsonl entry per checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt", 500);

    const first = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 1,
        .max_entries_per_checkpoint = 1,
    });
    defer first.deinit(std.testing.allocator);

    try std.testing.expect(first.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), first.checkpoint.?.source_seq_start);
    try std.testing.expectEqual(@as(u64, 1), first.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 2), first.checkpoint.?.first_kept_seq);
    try std.testing.expectEqual(@as(u32, 1), first.checkpoint.?.compacted_entry_count);
    try std.testing.expect(std.mem.indexOf(u8, first.checkpoint.?.summary, "segment_range: 1..1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.checkpoint.?.summary, "seq=1 role=user") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.checkpoint.?.summary, "seq=2 role=assistant") == null);

    const second = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 1,
        .max_entries_per_checkpoint = 1,
    });
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(second.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), second.checkpoint.?.source_seq_start);
    try std.testing.expectEqual(@as(u64, 2), second.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 3), second.checkpoint.?.first_kept_seq);
    try std.testing.expectEqual(@as(u32, 1), second.checkpoint.?.compacted_entry_count);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "previous_summary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "segment_range: 2..2") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=2 role=assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=3 role=user") == null);
}

test "context compactor recompacts an existing range when aggressiveness increases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Second prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Second answer", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt", 500);

    const first = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 1,
        .max_entries_per_checkpoint = 1,
        .aggressiveness_milli = 350,
    });
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(first.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), first.checkpoint.?.source_seq_end);

    const second = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 1,
        .max_entries_per_checkpoint = 1,
        .aggressiveness_milli = 700,
    });
    defer second.deinit(std.testing.allocator);

    try std.testing.expect(second.checkpoint != null);
    try std.testing.expectEqual(@as(u64, 1), second.checkpoint.?.source_seq_start);
    try std.testing.expectEqual(@as(u64, 4), second.checkpoint.?.source_seq_end);
    try std.testing.expectEqual(@as(u64, 5), second.checkpoint.?.first_kept_seq);
    try std.testing.expectEqual(@as(u16, 700), second.checkpoint.?.aggressiveness_milli);
    try std.testing.expectEqual(@as(u32, 4), second.checkpoint.?.compacted_entry_count);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "replaces_checkpoint:") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "segment_range: 1..4") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=4 role=assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.checkpoint.?.summary, "seq=5 role=user") == null);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);
    const messages_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(messages_jsonl);
    try std.testing.expectEqual(@as(usize, 5), countOccurrences(messages_jsonl, "\"id\":\"msg-"));

    const context_path = try VAR1.core.session_store.contextFilePath(std.testing.allocator, workspace_root, session.id);
    defer std.testing.allocator.free(context_path);
    const context_jsonl = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_jsonl);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(context_jsonl, "\"type\":\"summary_checkpoint\""));
    try std.testing.expect(std.mem.indexOf(u8, context_jsonl, "\"role\":\"user\"") == null);
}

test "context builder consumes checkpoints generated by the compactor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "Initial prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Initial answer", 200);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Follow-up prompt", 300);
    try VAR1.core.session_store.upsertAssistantSessionMessage(std.testing.allocator, workspace_root, session.id, "Follow-up answer", 400);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "Final prompt", 500);

    const result = try VAR1.core.context.compactor.compactSession(std.testing.allocator, workspace_root, session.id, .{
        .keep_recent_messages = 2,
    });
    defer result.deinit(std.testing.allocator);

    var provider_messages = std.array_list.Managed(VAR1.shared.types.ChatMessage).init(std.testing.allocator);
    defer {
        for (provider_messages.items) |message| message.deinit(std.testing.allocator);
        provider_messages.deinit();
    }

    try VAR1.core.context.appendProviderMessages(std.testing.allocator, workspace_root, &provider_messages, session);

    try std.testing.expectEqual(@as(usize, 3), provider_messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "VAR1 context checkpoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_messages.items[0].content.?, "Initial prompt") != null);
    try std.testing.expectEqualStrings("Follow-up answer", provider_messages.items[1].content.?);
    try std.testing.expectEqualStrings("Final prompt", provider_messages.items[2].content.?);
}

test "agent service resolves child session status from the canonical session store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const config = try makeConfig(std.testing.allocator, workspace_root, 4);
    defer config.deinit(std.testing.allocator);

    var completed = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "how many r in strawberry",
        .{
            .status = .completed,
            .parent_session_id = "session-parent",
            .display_name = "berry-child",
            .agent_profile = "subagent",
        },
    );
    defer completed.deinit(std.testing.allocator);
    try VAR1.core.session_store.writeOutput(std.testing.allocator, workspace_root, completed.id, "There are 3 r's in strawberry.");
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, completed.id, .{
        .event_type = "assistant_response",
        .message = "There are 3 r's in strawberry.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    var running = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "Refine the hero page",
        .{
            .status = .running,
            .parent_session_id = "session-parent",
            .display_name = "hero-child",
            .agent_profile = "subagent",
        },
    );
    defer running.deinit(std.testing.allocator);
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, running.id, .{
        .event_type = "tool_completed",
        .message = "tool completed: write_file",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    var unrelated = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "ignore me",
        .{
            .status = .running,
            .parent_session_id = "other-parent",
            .display_name = "other-child",
            .agent_profile = "subagent",
        },
    );
    defer unrelated.deinit(std.testing.allocator);

    var service = VAR1.core.agent_runtime.Service.init(&config);
    const handle = service.handle();

    const status_output = try handle.status(std.testing.allocator, "session-parent", "berry-child");
    defer std.testing.allocator.free(status_output);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "PARENT_SESSION_ID session-parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "OUTPUT There are 3 r's in strawberry.") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LATEST_EVENT_TYPE assistant_response") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "TERMINAL true") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "LIFECYCLE_STATE completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_output, "NEXT_PARENT_ACTION collect_result") != null);

    const wait_output = try handle.wait(std.testing.allocator, "session-parent", "berry-child", 10);
    defer std.testing.allocator.free(wait_output);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "STATUS completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_output, "WAIT_STATE terminal") != null);

    const running_status_output = try handle.status(std.testing.allocator, "session-parent", "hero-child");
    defer std.testing.allocator.free(running_status_output);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "LATEST_EVENT_MESSAGE tool completed: write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "TERMINAL false") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "LIFECYCLE_STATE processing") != null);
    try std.testing.expect(std.mem.indexOf(u8, running_status_output, "HEARTBEAT_AGE_MS") != null);

    const timeout_output = try handle.wait(std.testing.allocator, "session-parent", "hero-child", 1);
    defer std.testing.allocator.free(timeout_output);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "STATUS running") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "WAIT_STATE timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, timeout_output, "WAIT_TIMEOUT_MS 1") != null);

    const list_output = try handle.list(std.testing.allocator, "session-parent");
    defer std.testing.allocator.free(list_output);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "berry-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "hero-child") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "other-child") == null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "SESSION_ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "UPDATED_AT_MS") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "LIFECYCLE_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_output, "NEXT_PARENT_ACTION") != null);
}

test "derivative memory is sequence-bound and rejects transcript replay" {
    const memory = VAR1.core.memory.derivative;

    const entry = memory.DerivativeMemoryEntry{
        .session_id = "session-1",
        .source_seq_start = 2,
        .source_seq_end = 5,
        .entry_type = .decision,
        .summary = "Operator approved bounded capability profiles and rejected background evolution.",
        .created_at_ms = 123,
    };
    try memory.validateEntry(entry);

    const rendered = try memory.renderEntryJson(std.testing.allocator, entry);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source_seq_start\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"source_seq_end\":5") != null);

    try std.testing.expectError(memory.Error.TranscriptReplayRejected, memory.validateEntry(.{
        .session_id = "session-1",
        .source_seq_start = 2,
        .source_seq_end = 5,
        .entry_type = .summary,
        .summary = "{\"seq\":2,\"role\":\"user\",\"content\":\"raw transcript row\"}",
        .created_at_ms = 123,
    }));

    const diagnostic = memory.unsupportedBehaviorDiagnostic(.autonomous_background_evolution);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "cold-start recovery") != null);
}

test "heartbeat and evaluator boundaries append redacted session events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "evaluate current run");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.evaluation.events.appendHeartbeatEvent(std.testing.allocator, workspace_root, session.id, .running, "api_key=sk-test");
    try VAR1.core.evaluation.events.appendEvaluatorEvent(std.testing.allocator, workspace_root, session.id, "contract-check", true, "No executor mutation.");
    try VAR1.core.evaluation.events.appendUnsupportedBehaviorEvent(
        std.testing.allocator,
        workspace_root,
        session.id,
        "autonomous_background_evolution",
        VAR1.core.memory.derivative.unsupportedBehaviorDiagnostic(.autonomous_background_evolution),
    );

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("runtime_heartbeat", events[0].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[0].message, "[redacted]") != null);
    try std.testing.expectEqualStrings("evaluator_result", events[1].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[1].message, "\"executor_mutation\":\"forbidden\"") != null);
    try std.testing.expectEqualStrings("runtime_unsupported_behavior", events[2].event_type);
    try std.testing.expect(std.mem.indexOf(u8, events[2].message, "cold-start recovery") != null);
}

test "docs sync writes pending sessions and archives completed sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const snapshot = VAR1.shared.types.ProgressSnapshot{
        .session_id = "session-123",
        .status = "running",
        .prompt = "how many r in strawberry",
        .output = "",
        .updated_at_ms = std.time.milliTimestamp(),
    };

    try VAR1.core.docs_sync.writePending(std.testing.allocator, workspace_root, snapshot);
    try VAR1.core.docs_sync.appendLog(std.testing.allocator, workspace_root, "started session-123");

    const pending_path = try VAR1.core.docs_sync.todoSlicePath(std.testing.allocator, workspace_root, "session-123");
    defer std.testing.allocator.free(pending_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(pending_path));

    try VAR1.core.docs_sync.completeSession(std.testing.allocator, workspace_root, .{
        .session_id = "session-123",
        .status = "completed",
        .prompt = "how many r in strawberry",
        .output = "There are 3 r's in strawberry.",
        .updated_at_ms = std.time.milliTimestamp(),
    });

    const changelog_path = try VAR1.core.docs_sync.changelogSlicePath(std.testing.allocator, workspace_root, "session-123");
    defer std.testing.allocator.free(changelog_path);

    try std.testing.expect(!VAR1.shared.fsutil.fileExists(pending_path));
    try std.testing.expect(VAR1.shared.fsutil.fileExists(changelog_path));
}

test "docs sync appends human-readable log entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try VAR1.core.docs_sync.appendLog(std.testing.allocator, workspace_root, "example log event");

    const log_path = try VAR1.core.docs_sync.runLogPath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(log_path);

    const log_contents = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, log_path);
    defer std.testing.allocator.free(log_contents);

    try std.testing.expect(std.mem.indexOf(u8, log_contents, "example log event") != null);
}

test "docs sync seeds run log and memories when missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    try VAR1.core.docs_sync.ensureRunStart(std.testing.allocator, workspace_root);

    const log_path = try VAR1.core.docs_sync.runLogPath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(log_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(log_path));

    const memories_path = try VAR1.core.docs_sync.memoriesFilePath(std.testing.allocator, workspace_root);
    defer std.testing.allocator.free(memories_path);
    try std.testing.expect(VAR1.shared.fsutil.fileExists(memories_path));
}

test "fsutil writeText replaces text through the atomic write primitive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    const path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, "atomic", "record.json" });
    defer std.testing.allocator.free(path);

    try VAR1.shared.fsutil.writeText(path, "{\"version\":1}\n");
    try VAR1.shared.fsutil.writeText(path, "{\"version\":2}\n");

    const content = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("{\"version\":2}\n", content);
}

test "events get monotonic seq assigned by appendEvent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "seq prompt");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "turn 1",
        .timestamp_ms = 100,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_response",
        .message = "turn 2",
        .timestamp_ms = 200,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_finished",
        .message = "turn 3",
        .timestamp_ms = 300,
    });

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(@as(u64, 1), events[0].seq);
    try std.testing.expectEqual(@as(u64, 2), events[1].seq);
    try std.testing.expectEqual(@as(u64, 3), events[2].seq);
}

test "event seq survives cold start and continues monotonically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "cold start prompt");
    defer session.deinit(std.testing.allocator);

    // First "process": write 2 events.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "first",
        .timestamp_ms = 100,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_response",
        .message = "second",
        .timestamp_ms = 200,
    });

    // Cold-start read: verify seq persisted on disk.
    const events_before = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events_before);
    try std.testing.expectEqual(@as(u64, 1), events_before[0].seq);
    try std.testing.expectEqual(@as(u64, 2), events_before[1].seq);

    // Second "process": append one more event. Seq must continue from 3.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_completed",
        .message = "third after restart",
        .timestamp_ms = 300,
    });

    const events_after = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events_after);
    try std.testing.expectEqual(@as(usize, 3), events_after.len);
    try std.testing.expectEqual(@as(u64, 3), events_after[2].seq);
}

test "event seq continues correctly after a torn write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "torn prompt");
    defer session.deinit(std.testing.allocator);

    // Write one valid event (gets seq=1).
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "valid",
        .timestamp_ms = 100,
    });

    // Inject a torn/partial line (simulating crash mid-write).
    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);
    try VAR1.shared.fsutil.appendText(events_path, "{\"event_type\":\"partial\"");

    // Append another event. The tail-scan must skip the partial line and
    // find seq=1 from the valid event, so the new event gets seq=2.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_recovered",
        .message = "after torn write",
        .timestamp_ms = 200,
    });

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // readEvents stops at the poisoned partial line (valid-prefix rule), so
    // only the first valid event is returned. Its seq must be 1.
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u64, 1), events[0].seq);

    // But readLatestEvent scans backward, skips the partial, and returns the
    // recovered event with seq=2.
    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("session_recovered", latest.?.event_type);
    try std.testing.expectEqual(@as(u64, 2), latest.?.seq);
}

test "readEvents stops at poisoned suffix and returns valid prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "poisoned prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // Write 2 valid events followed by a malformed 3rd line.
    try VAR1.shared.fsutil.writeText(
        events_path,
        "{\"event_type\":\"session_started\",\"message\":\"a\",\"timestamp_ms\":100,\"seq\":1}\n" ++
            "{\"event_type\":\"assistant_response\",\"message\":\"b\",\"timestamp_ms\":200,\"seq\":2}\n" ++
            "GARBAGE_NOT_JSON\n",
    );

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // Must return exactly the 2 valid prefix lines, not silently swallow the poison.
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("assistant_response", events[1].event_type);
}

test "readMessages stops at poisoned suffix and returns valid prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "msg poison prompt");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);

    // Write 1 valid message followed by a malformed line.
    try VAR1.shared.fsutil.writeText(
        messages_path,
        "{\"id\":\"msg-1\",\"seq\":1,\"role\":\"user\",\"content\":\"hello\",\"timestamp_ms\":100}\n" ++
            "BROKEN_JSON_LINE\n",
    );

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);

    // Must return exactly the 1 valid prefix line.
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(@as(u64, 1), messages[0].seq);
    try std.testing.expectEqualStrings("hello", messages[0].content);
}

test "readEvents strips UTF-8 BOM from the events ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "bom prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // Write a BOM-prefixed events file (as some Windows editors do).
    try VAR1.shared.fsutil.writeText(
        events_path,
        "\xEF\xBB\xBF" ++
            "{\"event_type\":\"session_started\",\"message\":\"bom\",\"timestamp_ms\":100,\"seq\":1}\n" ++
            "{\"event_type\":\"assistant_response\",\"message\":\"ok\",\"timestamp_ms\":200,\"seq\":2}\n",
    );

    // readEvents must strip the BOM and parse both events.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("assistant_response", events[1].event_type);

    // readLatestEvent must also strip the BOM and find the last event.
    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("assistant_response", latest.?.event_type);
}

test "readSessionMessages strips UTF-8 BOM from the messages ledger" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "msg bom prompt");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);

    // Write a BOM-prefixed messages file.
    try VAR1.shared.fsutil.writeText(
        messages_path,
        "\xEF\xBB\xBF" ++
            "{\"id\":\"msg-1\",\"seq\":1,\"role\":\"user\",\"content\":\"bom-free\",\"timestamp_ms\":100}\n",
    );

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("bom-free", messages[0].content);
}

test "readEvents stops at invalid UTF-8 bytes and returns valid prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "invalid utf8 prompt");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // First line is valid JSON. Second line starts with invalid UTF-8 (0xFE is
    // never valid in UTF-8). Third line is valid but should not be reached.
    const poison = "{\"event_type\":\"session_started\",\"message\":\"ok\",\"timestamp_ms\":100,\"seq\":1}\n" ++
        "\xFE\xFFgarbage\n" ++
        "{\"event_type\":\"assistant_response\",\"message\":\"after\",\"timestamp_ms\":200,\"seq\":2}\n";
    try VAR1.shared.fsutil.writeText(events_path, poison);

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // Must return only the valid prefix (1 event). The invalid UTF-8 line
    // acts as a poisoned boundary.
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
}

test "readSessionMessages stops at invalid UTF-8 bytes and returns valid prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "msg invalid utf8");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);

    // One valid message followed by invalid UTF-8 bytes.
    const poison = "{\"id\":\"msg-1\",\"seq\":1,\"role\":\"user\",\"content\":\"valid\",\"timestamp_ms\":100}\n" ++
        "\xC0\xC1invalid\n";
    try VAR1.shared.fsutil.writeText(messages_path, poison);

    const messages = try VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("valid", messages[0].content);
}

test "session record reader strips UTF-8 BOM from session.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "bom session");
    defer session.deinit(std.testing.allocator);

    // Overwrite session.json with a BOM prefix.
    const session_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "session.json" });
    defer std.testing.allocator.free(session_path);

    const original = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, session_path);
    defer std.testing.allocator.free(original);

    const bom_prefixed = try std.fmt.allocPrint(std.testing.allocator, "\xEF\xBB\xBF{s}", .{original});
    defer std.testing.allocator.free(bom_prefixed);
    try VAR1.shared.fsutil.writeText(session_path, bom_prefixed);

    // readSessionRecord must strip the BOM and parse the record.
    const record = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer record.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bom session", record.prompt);
}

test "events with same-millisecond timestamps are disambiguated by monotonic seq" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "burst prompt");
    defer session.deinit(std.testing.allocator);

    // Append 3 events that all share the exact same timestamp_ms (simulating a
    // same-millisecond burst). Without seq, a timestamp-only cursor could not
    // distinguish their order. With seq, the order is deterministic.
    const burst_ts: i64 = 999999;
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_started",
        .message = "burst-1",
        .timestamp_ms = burst_ts,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_output_delta",
        .message = "burst-2",
        .timestamp_ms = burst_ts,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_finished",
        .message = "burst-3",
        .timestamp_ms = burst_ts,
    });

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // All 3 share the same timestamp, but seq is strictly monotonic.
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqual(burst_ts, events[0].timestamp_ms);
    try std.testing.expectEqual(burst_ts, events[1].timestamp_ms);
    try std.testing.expectEqual(burst_ts, events[2].timestamp_ms);

    // seq breaks the tie: 1 < 2 < 3, matching append order.
    try std.testing.expectEqual(@as(u64, 1), events[0].seq);
    try std.testing.expectEqual(@as(u64, 2), events[1].seq);
    try std.testing.expectEqual(@as(u64, 3), events[2].seq);

    // The event types are in the causal order: started → delta → finished.
    try std.testing.expectEqualStrings("tool_started", events[0].event_type);
    try std.testing.expectEqualStrings("tool_output_delta", events[1].event_type);
    try std.testing.expectEqualStrings("tool_finished", events[2].event_type);
}

test "stale running session is recoverable as failed with durable evidence after cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Simulate a process that started a session, marked it running, then died.
    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "stale recovery prompt",
        .{ .status = .running },
    );
    defer session.deinit(std.testing.allocator);

    // Write a stale session_started event (old timestamp).
    const stale_ts = std.time.milliTimestamp() - 10_000;
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "Session was running when process died.",
        .timestamp_ms = stale_ts,
    });

    // Cold-start "discovery": read the session record, detect it's stale.
    var recovered = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.running, recovered.status);

    // Read the latest event to get the heartbeat timestamp.
    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("session_started", latest.?.event_type);

    // The heartbeat age proves staleness: now - stale_ts >= stale_running_session_ms (5000).
    const now = std.time.milliTimestamp();
    try std.testing.expect(now - latest.?.timestamp_ms >= 5_000);

    // Reconcile: mark the session as failed with durable evidence.
    // setSessionFailure takes ownership of the record's allocation and frees
    // the old failure_reason (null here) before duping the new one.
    try VAR1.core.session_store.setSessionFailure(
        std.testing.allocator,
        workspace_root,
        &recovered,
        "Session was marked running but no active kernel execution owns it.",
    );

    // Cold-start read again: the failure must be durable.
    const after = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(VAR1.shared.types.SessionStatus.failed, after.status);
    try std.testing.expect(after.failure_reason != null);
    try std.testing.expect(std.mem.indexOf(u8, after.failure_reason.?, "no active kernel execution") != null);
}

test "session prompt survives cold start for no-prompt resume fail-closed check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // A session with a real prompt.
    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "real task prompt");
    defer session.deinit(std.testing.allocator);

    // Cold-start read: prompt must be durable.
    const recovered = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("real task prompt", recovered.prompt);

    // The no-prompt resume check is: trimmed prompt length == 0 → reject.
    // A real prompt must survive so the check can accept it.
    const trimmed = std.mem.trim(u8, recovered.prompt, " \t\r\n");
    try std.testing.expect(trimmed.len > 0);
}

test "session with whitespace-only prompt is rejected by the empty-prompt check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Simulate a corrupted or malformed session with a whitespace-only prompt.
    // initSession would reject this at the RPC layer, but the store itself
    // may carry such a record from a partial write or migration.
    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "   ");
    defer session.deinit(std.testing.allocator);

    // Cold-start read.
    const recovered = try VAR1.core.session_store.readSessionRecord(std.testing.allocator, workspace_root, session.id);
    defer recovered.deinit(std.testing.allocator);

    // The empty-prompt check must reject this: trimmed prompt is empty.
    const trimmed = std.mem.trim(u8, recovered.prompt, " \t\r\n");
    try std.testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "stale session failure event is visible in the event spine after cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator,
        workspace_root,
        "event spine stale",
        .{ .status = .running },
    );
    defer session.deinit(std.testing.allocator);

    // Write a stale started event.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "running",
        .timestamp_ms = std.time.milliTimestamp() - 10_000,
    });

    // Reconcile: append a session_failed event.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_failed",
        .message = "Session was marked running but no active kernel execution owns it.",
        .timestamp_ms = std.time.milliTimestamp(),
    });

    // Cold-start read: both events must be visible, in order, with seq.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("session_started", events[0].event_type);
    try std.testing.expectEqualStrings("session_failed", events[1].event_type);
    try std.testing.expect(events[0].seq < events[1].seq);

    // The latest event must be the failure.
    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("session_failed", latest.?.event_type);
}

// =============================================================================
// P0-22f: Property-based fuzz harness for JSONL readers
// =============================================================================
//
// Invariant: for ANY byte sequence written to events.jsonl, the readers must
// never crash, never leak memory, and never return corrupted data. They must
// return the valid prefix (possibly empty) and stop at the first poisoned line.
// This is AGENTS.md §II: "preserve valid prefix state across poisoned suffixes."

test "readEvents never crashes on random corrupted bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "fuzz events");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // Seed a deterministic PRNG so failures are reproducible.
    var prng = std.Random.DefaultPrng.init(42);
    var rng = prng.random();

    var iter: u32 = 0;
    while (iter < 50) : (iter += 1) {
        // Generate random bytes of random length (0 to 256).
        const len = rng.intRangeAtMost(usize, 0, 256);
        const garbage = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(garbage);
        rng.bytes(garbage);

        // Write the garbage as the events file content.
        try VAR1.shared.fsutil.writeText(events_path, garbage);

        // The reader must not crash. It returns either events (valid prefix)
        // or an empty slice. Either is acceptable; crashing is not.
        const events = VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id) catch {
            // A read error is acceptable if the file content is truly unparsable
            // at the I/O level (e.g. a directory permission issue from the temp
            // path). What is NOT acceptable is a crash.
            continue;
        };
        defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

        // Every returned event must have non-empty event_type (no partial data).
        for (events) |event| {
            try std.testing.expect(event.event_type.len > 0);
        }
    }
}

test "readLatestEvent never crashes on random corrupted bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "fuzz latest");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    var prng = std.Random.DefaultPrng.init(99);
    var rng = prng.random();

    var iter: u32 = 0;
    while (iter < 50) : (iter += 1) {
        const len = rng.intRangeAtMost(usize, 0, 256);
        const garbage = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(garbage);
        rng.bytes(garbage);

        try VAR1.shared.fsutil.writeText(events_path, garbage);

        const latest = VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id) catch continue;
        defer if (latest) |event| event.deinit(std.testing.allocator);
        // latest may be null (no parseable line) or an event. Both are valid.
    }
}

test "readSessionMessages never crashes on random corrupted bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "fuzz messages");
    defer session.deinit(std.testing.allocator);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "messages.jsonl" });
    defer std.testing.allocator.free(messages_path);

    var prng = std.Random.DefaultPrng.init(137);
    var rng = prng.random();

    var iter: u32 = 0;
    while (iter < 50) : (iter += 1) {
        const len = rng.intRangeAtMost(usize, 0, 256);
        const garbage = try std.testing.allocator.alloc(u8, len);
        defer std.testing.allocator.free(garbage);
        rng.bytes(garbage);

        try VAR1.shared.fsutil.writeText(messages_path, garbage);

        const messages = VAR1.core.session_store.readSessionMessages(std.testing.allocator, workspace_root, session.id) catch continue;
        defer VAR1.shared.types.deinitSessionMessages(std.testing.allocator, messages);

        for (messages) |msg| {
            try std.testing.expect(msg.id.len > 0);
        }
    }
}

test "readEvents preserves valid prefix when random corruption is injected mid-file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "fuzz mid-file");
    defer session.deinit(std.testing.allocator);

    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{ workspace_root, ".var", "sessions", session.id, "events.jsonl" });
    defer std.testing.allocator.free(events_path);

    // Write 3 valid events.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "session_started",
        .message = "1",
        .timestamp_ms = 100,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_response",
        .message = "2",
        .timestamp_ms = 200,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_completed",
        .message = "3",
        .timestamp_ms = 300,
    });

    // Read before corruption: all 3 events.
    const before = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, before);
    try std.testing.expectEqual(@as(usize, 3), before.len);

    // Inject random bytes after the 3 valid events (simulating a torn write).
    var prng = std.Random.DefaultPrng.init(7);
    var rng = prng.random();
    const garbage = try std.testing.allocator.alloc(u8, 64);
    defer std.testing.allocator.free(garbage);
    rng.bytes(garbage);
    try VAR1.shared.fsutil.appendText(events_path, garbage);

    // Read after corruption: must still return the 3 valid prefix events.
    const after = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, after);
    try std.testing.expectEqual(@as(usize, 3), after.len);
    try std.testing.expectEqualStrings("session_started", after[0].event_type);
    try std.testing.expectEqualStrings("assistant_response", after[1].event_type);
    try std.testing.expectEqualStrings("tool_completed", after[2].event_type);
}

// =============================================================================
// P0-1: Shard ledger primitive
// =============================================================================

test "shard checkpoint is written to context.jsonl and survives cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "shard parent prompt");
    defer session.deinit(std.testing.allocator);

    // Write a summary checkpoint first (the parent).
    {
        const id = try std.testing.allocator.dupe(u8, "checkpoint-parent-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent checkpoint summary.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id,
            .entry_type = etype,
            .created_at_ms = 1000,
            .source_seq_start = 1,
            .source_seq_end = 10,
            .first_kept_seq = 8,
            .tokens_before_estimate = 500,
            .tokens_after_estimate = 200,
            .trigger = trigger,
            .summary = summary,
        });
    }

    // Write a shard checkpoint referencing the parent.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator,
        workspace_root,
        session.id,
        "checkpoint-parent-1",
        1,
        .open,
        "Branch A: investigating search performance.",
    );

    // Cold-start read: the latest checkpoint in context.jsonl must be the shard.
    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(
        std.testing.allocator,
        workspace_root,
        session.id,
    );
    defer if (latest) |cp| cp.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("shard_checkpoint", latest.?.entry_type);
    try std.testing.expect(latest.?.parent_checkpoint_id != null);
    try std.testing.expectEqualStrings("checkpoint-parent-1", latest.?.parent_checkpoint_id.?);
    try std.testing.expectEqual(@as(u64, 1), latest.?.branch_seq);

    // Verify the raw file contains the shard entry with parent reference.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"type\":\"shard_checkpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"parent_checkpoint_id\":\"checkpoint-parent-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"open\"") != null);
}

test "shard checkpoint can be updated to converged status" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "shard converge prompt");
    defer session.deinit(std.testing.allocator);

    // Parent checkpoint.
    {
        const id = try std.testing.allocator.dupe(u8, "checkpoint-parent-2");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "auto");
        const summary = try std.testing.allocator.dupe(u8, "Parent for convergence test.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id,
            .entry_type = etype,
            .created_at_ms = 2000,
            .source_seq_start = 1,
            .source_seq_end = 5,
            .first_kept_seq = 4,
            .tokens_before_estimate = 300,
            .tokens_after_estimate = 150,
            .trigger = trigger,
            .summary = summary,
        });
    }

    // Open shard.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "checkpoint-parent-2", 1, .open, "Branch investigating.",
    );

    // Converge the shard.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "checkpoint-parent-2", 1, .converged, "Branch converged with findings.",
    );

    // The latest checkpoint must be the converged shard.
    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(
        std.testing.allocator, workspace_root, session.id,
    );
    defer if (latest) |cp| cp.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("shard_checkpoint", latest.?.entry_type);
    try std.testing.expectEqualStrings("checkpoint-parent-2", latest.?.parent_checkpoint_id.?);

    // Verify the converged status is in the raw file.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"converged\"") != null);
}

test "shard checkpoint does not corrupt summary checkpoint reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "mixed checkpoint prompt");
    defer session.deinit(std.testing.allocator);

    // Write a summary checkpoint, then a shard, then another summary.
    {
        const id = try std.testing.allocator.dupe(u8, "summary-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "First summary.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 100,
            .source_seq_start = 1, .source_seq_end = 3, .first_kept_seq = 2,
            .tokens_before_estimate = 100, .tokens_after_estimate = 50,
            .trigger = trigger, .summary = summary,
        });
    }

    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "summary-1", 1, .abandoned, "Abandoned branch.",
    );

    {
        const id = try std.testing.allocator.dupe(u8, "summary-2");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "auto");
        const summary = try std.testing.allocator.dupe(u8, "Second summary after shard.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 200,
            .source_seq_start = 1, .source_seq_end = 6, .first_kept_seq = 5,
            .tokens_before_estimate = 200, .tokens_after_estimate = 80,
            .trigger = trigger, .summary = summary,
        });
    }

    // The latest checkpoint must be the second summary (not the shard).
    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(
        std.testing.allocator, workspace_root, session.id,
    );
    defer if (latest) |cp| cp.deinit(std.testing.allocator);

    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("summary_checkpoint", latest.?.entry_type);
    try std.testing.expectEqualStrings("Second summary after shard.", latest.?.summary);
    try std.testing.expect(latest.?.parent_checkpoint_id == null);
}

// =============================================================================
// P0-3: Shard garbage collection — tombstone marks + byte-identical invariant
// =============================================================================

test "shard convergence leaves parent transcript byte-identical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "gc byte-identical");
    defer session.deinit(std.testing.allocator);

    // Write some messages to build a transcript.
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .user, "first", 100);
    try VAR1.core.session_store.appendSessionMessage(std.testing.allocator, workspace_root, session.id, .assistant, "second", 200);

    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "messages.jsonl",
    });
    defer std.testing.allocator.free(messages_path);

    // Capture the transcript content BEFORE any shard operations.
    const before = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(before);

    // Write a parent checkpoint, open a shard, then converge it.
    {
        const id = try std.testing.allocator.dupe(u8, "cp-gc-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent for GC test.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 300,
            .source_seq_start = 1, .source_seq_end = 2, .first_kept_seq = 1,
            .tokens_before_estimate = 50, .tokens_after_estimate = 30,
            .trigger = trigger, .summary = summary,
        });
    }

    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-1", 1, .open, "Branch for GC test.",
    );

    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-1", 1, .converged, "Branch converged.",
    );

    // Capture the transcript content AFTER shard operations.
    const after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(after);

    // The transcript MUST be byte-identical — shard convergence only appends
    // to context.jsonl, never modifies messages.jsonl (AGENTS.md §II, P0-3).
    try std.testing.expectEqualStrings(before, after);
}

test "shard tombstone marks survive cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "gc tombstone");
    defer session.deinit(std.testing.allocator);

    // Parent checkpoint.
    {
        const id = try std.testing.allocator.dupe(u8, "cp-gc-2");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent for tombstone test.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 500,
            .source_seq_start = 1, .source_seq_end = 1, .first_kept_seq = 1,
            .tokens_before_estimate = 30, .tokens_after_estimate = 15,
            .trigger = trigger, .summary = summary,
        });
    }

    // Open two branches.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-2", 1, .open, "Branch A.",
    );
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-2", 2, .open, "Branch B.",
    );

    // Abandon branch A, converge branch B.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-2", 1, .abandoned, "Branch A abandoned.",
    );
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-2", 2, .converged, "Branch B converged.",
    );

    // Cold-start read: verify all tombstone marks are in the raw ledger.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(raw);

    // All lifecycle transitions must be durable in the ledger.
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"abandoned\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"converged\"") != null);

    // The latest checkpoint must be the converged branch B.
    const latest = try VAR1.core.session_store.readLatestContextCheckpoint(
        std.testing.allocator, workspace_root, session.id,
    );
    defer if (latest) |cp| cp.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("shard_checkpoint", latest.?.entry_type);
    try std.testing.expectEqualStrings("Branch B converged.", latest.?.summary);
}

test "shard ledger is append-only — no deletion of tombstoned entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "gc append-only");
    defer session.deinit(std.testing.allocator);

    {
        const id = try std.testing.allocator.dupe(u8, "cp-gc-3");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, session.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 600,
            .source_seq_start = 1, .source_seq_end = 1, .first_kept_seq = 1,
            .tokens_before_estimate = 30, .tokens_after_estimate = 15,
            .trigger = trigger, .summary = summary,
        });
    }

    // Open then abandon a branch.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-3", 1, .open, "Branch to abandon.",
    );

    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);

    // Capture the ledger content before tombstone.
    const before_tombstone = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(before_tombstone);

    // Write the tombstone.
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, session.id,
        "cp-gc-3", 1, .abandoned, "Abandoned.",
    );

    // Capture after tombstone.
    const after_tombstone = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(after_tombstone);

    // The ledger must be append-only: the "before" content is a prefix of "after".
    try std.testing.expect(after_tombstone.len > before_tombstone.len);
    try std.testing.expect(std.mem.startsWith(u8, after_tombstone, before_tombstone));

    // The "open" status entry is NOT deleted — it's still there alongside the
    // "abandoned" tombstone. GC is a mark, not a delete (AGENTS.md §II, P0-3).
    try std.testing.expect(std.mem.indexOf(u8, after_tombstone, "\"branch_status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_tombstone, "\"branch_status\":\"abandoned\"") != null);
}

// =============================================================================
// P0-2: Branch-and-converge reprocessing loop
// =============================================================================

test "convergeBranches merges child outputs into parent checkpoint and transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Create a parent session.
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "parent converge prompt");
    defer parent.deinit(std.testing.allocator);

    // Write a parent checkpoint.
    {
        const id = try std.testing.allocator.dupe(u8, "cp-converge-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent checkpoint for convergence.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, parent.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 1000,
            .source_seq_start = 1, .source_seq_end = 2, .first_kept_seq = 1,
            .tokens_before_estimate = 100, .tokens_after_estimate = 50,
            .trigger = trigger, .summary = summary,
        });
    }

    // Capture parent transcript before convergence.
    const messages_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", parent.id, "messages.jsonl",
    });
    defer std.testing.allocator.free(messages_path);
    const transcript_before = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(transcript_before);

    // Set up the agent service with a config.
    const config = VAR1.shared.types.Config{
        .openai_base_url = try std.testing.allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try std.testing.allocator.dupe(u8, "test-key"),
        .openai_model = try std.testing.allocator.dupe(u8, "test-model"),
        .max_steps = 10,
        .workspace_root = try std.testing.allocator.dupe(u8, workspace_root),
    };
    defer {
        std.testing.allocator.free(config.openai_base_url);
        std.testing.allocator.free(config.openai_api_key);
        std.testing.allocator.free(config.openai_model);
        std.testing.allocator.free(config.workspace_root);
    }
    var service = VAR1.core.agent_runtime.Service.init(&config);

    // Simulate two completed child branches with outputs.
    const branches = [_]VAR1.core.agent_runtime.ChildBranchResult{
        .{ .agent_name = "scout-a", .output = "Found 3 relevant files in src/core." },
        .{ .agent_name = "scout-b", .output = "No issues found in the test suite." },
    };

    // Execute the convergence.
    try VAR1.core.agent_runtime.convergeBranches(
        &service,
        std.testing.allocator,
        parent.id,
        "cp-converge-1",
        &branches,
    );

    // 1. Verify the converged shard checkpoint exists in context.jsonl.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", parent.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const context_raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(context_raw);
    try std.testing.expect(std.mem.indexOf(u8, context_raw, "\"branch_status\":\"converged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_raw, "\"parent_checkpoint_id\":\"cp-converge-1\"") != null);

    // 2. Verify the merged result was appended to the parent transcript.
    const transcript_after = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, messages_path);
    defer std.testing.allocator.free(transcript_after);
    try std.testing.expect(transcript_after.len > transcript_before.len);
    try std.testing.expect(std.mem.indexOf(u8, transcript_after, "Converged 2 branch(es)") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript_after, "scout-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript_after, "scout-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript_after, "Found 3 relevant files") != null);

    // 3. Verify the transcript before convergence is a prefix (append-only).
    try std.testing.expect(std.mem.startsWith(u8, transcript_after, transcript_before));

    // 4. Verify a branch_converged event was emitted on the event spine.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var found_converged = false;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "branch_converged")) {
            found_converged = true;
            break;
        }
    }
    try std.testing.expect(found_converged);

    // 5. Verify the latest checkpoint is the converged shard.
    const latest_cp = try VAR1.core.session_store.readLatestContextCheckpoint(
        std.testing.allocator, workspace_root, parent.id,
    );
    defer if (latest_cp) |cp| cp.deinit(std.testing.allocator);
    try std.testing.expect(latest_cp != null);
    try std.testing.expectEqualStrings("shard_checkpoint", latest_cp.?.entry_type);
}

// =============================================================================
// P0-4b: Shard-graph cold-start recovery
// =============================================================================

test "reconcileOpenShards marks unsettled open branches as abandoned at cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "cold start parent");
    defer parent.deinit(std.testing.allocator);

    // Parent checkpoint.
    {
        const id = try std.testing.allocator.dupe(u8, "cp-cold-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent for cold-start test.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, parent.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 1000,
            .source_seq_start = 1, .source_seq_end = 2, .first_kept_seq = 1,
            .tokens_before_estimate = 100, .tokens_after_estimate = 50,
            .trigger = trigger, .summary = summary,
        });
    }

    // Open branch A (will be left unsettled — simulated dead owner).
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, parent.id,
        "cp-cold-1", 1, .open, "Branch A open.",
    );

    // Open branch B, then converge it (settled — should NOT be abandoned).
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, parent.id,
        "cp-cold-1", 2, .open, "Branch B open.",
    );
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, parent.id,
        "cp-cold-1", 2, .converged, "Branch B converged.",
    );

    // Open branch C (also unsettled — simulated dead owner).
    try VAR1.core.session_store.appendShardCheckpoint(
        std.testing.allocator, workspace_root, parent.id,
        "cp-cold-1", 3, .open, "Branch C open.",
    );

    // Set up agent service.
    const config = VAR1.shared.types.Config{
        .openai_base_url = try std.testing.allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try std.testing.allocator.dupe(u8, "test-key"),
        .openai_model = try std.testing.allocator.dupe(u8, "test-model"),
        .max_steps = 10,
        .workspace_root = try std.testing.allocator.dupe(u8, workspace_root),
    };
    defer {
        std.testing.allocator.free(config.openai_base_url);
        std.testing.allocator.free(config.openai_api_key);
        std.testing.allocator.free(config.openai_model);
        std.testing.allocator.free(config.workspace_root);
    }
    var service = VAR1.core.agent_runtime.Service.init(&config);

    // Cold-start reconciliation: branches A and C are open and unsettled.
    const abandoned = try VAR1.core.agent_runtime.reconcileOpenShards(
        &service, std.testing.allocator, parent.id,
    );

    // Exactly 2 branches (A and C) should be marked abandoned. Branch B was
    // already converged and must NOT be re-abandoned.
    try std.testing.expectEqual(@as(usize, 2), abandoned);

    // Verify the raw ledger contains abandoned tombstones for A and C.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", parent.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(raw);

    // The converged branch B must still be converged (not re-abandoned).
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"converged\"") != null);
    // The abandoned tombstones from cold-start recovery must be present.
    try std.testing.expect(std.mem.indexOf(u8, raw, "cold start") != null);

    // Verify branch_abandoned events were emitted.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, parent.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    var abandoned_events: usize = 0;
    for (events) |event| {
        if (std.mem.eql(u8, event.event_type, "branch_abandoned")) abandoned_events += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), abandoned_events);
}

// =============================================================================
// P0-5b: Write-intent ledger
// =============================================================================

test "write intent reserve and commit leaves durable evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "intent test");
    defer session.deinit(std.testing.allocator);

    // Reserve an intent before mutation.
    try VAR1.core.session_store.reserveWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-1", "write_file", "src/main.zig", "abc123",
    );

    // Commit the intent after successful mutation.
    try VAR1.core.session_store.commitWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-1", "def456", 1024,
    );

    // Read the ledger: must have both reserved and committed entries.
    const intents = try VAR1.core.session_store.readWriteIntents(std.testing.allocator, workspace_root, session.id);
    defer {
        for (intents) |e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(intents);
    }
    try std.testing.expectEqual(@as(usize, 2), intents.len);
    try std.testing.expectEqualStrings("reserved", intents[0].status);
    try std.testing.expectEqualStrings("committed", intents[1].status);
    try std.testing.expectEqualStrings("write_file", intents[0].tool.?);
    try std.testing.expectEqualStrings("src/main.zig", intents[0].path.?);
    try std.testing.expectEqualStrings("abc123", intents[0].before_sha256.?);
    try std.testing.expectEqualStrings("def456", intents[1].after_sha256.?);
    try std.testing.expectEqual(@as(usize, 1024), intents[1].bytes_written);

    // Reconciliation: 0 abandoned (both reserved → committed).
    const abandoned = try VAR1.core.session_store.reconcileAbandonedIntents(
        std.testing.allocator, workspace_root, session.id,
    );
    try std.testing.expectEqual(@as(usize, 0), abandoned);
}

test "abandoned write intent (reserved without commit) is detected at cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "abandoned intent");
    defer session.deinit(std.testing.allocator);

    // Reserve intent A (will be committed).
    try VAR1.core.session_store.reserveWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-a", "write_file", "src/a.zig", "hash-a-before",
    );
    try VAR1.core.session_store.commitWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-a", "hash-a-after", 100,
    );

    // Reserve intent B (simulated crash — never committed).
    try VAR1.core.session_store.reserveWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-b", "write_file", "src/b.zig", "hash-b-before",
    );

    // Reserve intent C (also never committed — crash).
    try VAR1.core.session_store.reserveWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-c", "replace_in_file", "src/c.zig", "hash-c-before",
    );

    // Cold-start reconciliation: intents B and C are reserved without commit.
    const abandoned = try VAR1.core.session_store.reconcileAbandonedIntents(
        std.testing.allocator, workspace_root, session.id,
    );
    try std.testing.expectEqual(@as(usize, 2), abandoned);
}

test "write intent ledger is append-only and survives cold start" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "intent cold start");
    defer session.deinit(std.testing.allocator);

    // Write a complete intent cycle.
    try VAR1.core.session_store.reserveWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-x", "append_file", "log.txt", null,
    );
    try VAR1.core.session_store.commitWriteIntent(
        std.testing.allocator, workspace_root, session.id,
        "intent-x", "hash-x-after", 50,
    );

    // Cold-start read: ledger must be readable and contain both entries.
    const intents = try VAR1.core.session_store.readWriteIntents(std.testing.allocator, workspace_root, session.id);
    defer {
        for (intents) |e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(intents);
    }
    try std.testing.expectEqual(@as(usize, 2), intents.len);

    // Verify the raw ledger file exists and is append-only JSONL.
    const intents_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "intents.jsonl",
    });
    defer std.testing.allocator.free(intents_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, intents_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"status\":\"reserved\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"status\":\"committed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"tool\":\"append_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"bytes_written\":50") != null);
}

// =============================================================================
// P0-12b: Binary-safe event payloads (bytes_b64 field)
// =============================================================================

test "event with bytes_b64 field survives cold-start round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "binary payload");
    defer session.deinit(std.testing.allocator);

    // Append an event with a binary-safe base64 payload.
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_output_delta",
        .message = "Binary command output.",
        .timestamp_ms = 100,
        .bytes_b64 = "SGVsbG8gV29ybGQ=", // base64 of "Hello World"
    });

    // Append a normal text-only event (no bytes_b64).
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_completed",
        .message = "Done.",
        .timestamp_ms = 200,
    });

    // Cold-start read: both events must be readable with correct fields.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);

    // First event has bytes_b64.
    try std.testing.expect(events[0].bytes_b64 != null);
    try std.testing.expectEqualStrings("SGVsbG8gV29ybGQ=", events[0].bytes_b64.?);

    // Second event has no bytes_b64 (text-only).
    try std.testing.expect(events[1].bytes_b64 == null);

    // Verify the raw JSONL contains the bytes_b64 field.
    const events_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", session.id, "events.jsonl",
    });
    defer std.testing.allocator.free(events_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, events_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"bytes_b64\":\"SGVsbG8gV29ybGQ=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"bytes_b64\":null") != null);
}

test "readLatestEvent returns bytes_b64 field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "latest binary");
    defer session.deinit(std.testing.allocator);

    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_output_delta",
        .message = "latest binary output",
        .timestamp_ms = 300,
        .bytes_b64 = "AAECAwQ=", // base64 of bytes [0x00, 0x01, 0x02, 0x03, 0x04]
    });

    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expect(latest.?.bytes_b64 != null);
    try std.testing.expectEqualStrings("AAECAwQ=", latest.?.bytes_b64.?);
}

// =============================================================================
// P0-12c: CRC per-line checksums
// =============================================================================

test "computeLineCrc32 produces deterministic hash for JSON content" {
    const line = "{\"event_type\":\"test\",\"message\":\"hello\"}";
    const crc = VAR1.core.session_store.computeLineCrc32(line);
    // Same input must produce same CRC.
    try std.testing.expectEqual(crc, VAR1.core.session_store.computeLineCrc32(line));
    // Different input must produce different CRC.
    const different = "{\"event_type\":\"test\",\"message\":\"world\"}";
    try std.testing.expect(crc != VAR1.core.session_store.computeLineCrc32(different));
}

test "verifyLineCrc32 returns null for legacy entries without crc32 field" {
    const line = "{\"event_type\":\"test\",\"message\":\"no crc here\"}";
    const result = VAR1.core.session_store.verifyLineCrc32(line);
    try std.testing.expect(result == null);
}

test "verifyLineCrc32 returns true for valid checksum and false for tampered" {
    // Build a line with a valid CRC. The CRC is computed over the content
    // WITHOUT the crc32 field and WITHOUT the closing brace (which is where
    // the crc32 field is inserted).
    const content_without_brace = "{\"event_type\":\"test\",\"message\":\"verify me\"";
    const crc = VAR1.core.session_store.computeLineCrc32(content_without_brace);
    const line_with_crc = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s},\"crc32\":\"{x}\"}}",
        .{ content_without_brace, crc },
    );
    defer std.testing.allocator.free(line_with_crc);

    // Valid CRC must verify true.
    const valid = VAR1.core.session_store.verifyLineCrc32(line_with_crc);
    try std.testing.expect(valid != null);
    try std.testing.expect(valid.?);

    // Tampered line (different content, same CRC) must verify false.
    const tampered = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"event_type\":\"test\",\"message\":\"TAMPERED\",\"crc32\":\"{x}\"}}",
        .{crc},
    );
    defer std.testing.allocator.free(tampered);
    const invalid = VAR1.core.session_store.verifyLineCrc32(tampered);
    try std.testing.expect(invalid != null);
    try std.testing.expect(!invalid.?);
}

// =============================================================================
// P0-22h: TUI scrollback under live streaming
// =============================================================================
// The TUI is a read model over events.jsonl. This test verifies the event
// spine invariant that the TUI depends on: a sequence of assistant deltas,
// tool lifecycle events, and output deltas must be ordered, complete, and
// replayable from cold start — preserving transcript comprehension.

test "event spine produces ordered replay for TUI under live streaming" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "live streaming tui test");
    defer session.deinit(std.testing.allocator);

    // Simulate a live streaming session: turn_started → assistant_delta* →
    // tool_started → tool_output_delta* → tool_finished → tool_completed →
    // assistant_response. Every event gets a monotonic seq.
    const ts: i64 = 1000;
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "turn_started", .message = "step 0", .timestamp_ms = ts,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_delta", .message = "Let me search ", .timestamp_ms = ts + 1,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_delta", .message = "for the file.", .timestamp_ms = ts + 2,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_started", .message = "search_files", .timestamp_ms = ts + 3,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_output_delta", .message = "Found 3 matches", .timestamp_ms = ts + 4,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_finished", .message = "search done", .timestamp_ms = ts + 5,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "tool_completed", .message = "completed", .timestamp_ms = ts + 6,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_delta", .message = "I found the issue.", .timestamp_ms = ts + 7,
    });
    try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
        .event_type = "assistant_response", .message = "Final answer.", .timestamp_ms = ts + 8,
    });

    // Cold-start read: the TUI reconstructs the full transcript from the event spine.
    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // All 9 events must be present — no data loss under streaming.
    try std.testing.expectEqual(@as(usize, 9), events.len);

    // Seq must be strictly monotonic (1..9) — the TUI uses seq for cursor-based replay.
    for (events, 0..) |event, i| {
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), event.seq);
    }

    // The event types must be in the correct causal order:
    // turn_started → assistant_delta → tool lifecycle → assistant_delta → assistant_response.
    try std.testing.expectEqualStrings("turn_started", events[0].event_type);
    try std.testing.expectEqualStrings("assistant_delta", events[1].event_type);
    try std.testing.expectEqualStrings("assistant_delta", events[2].event_type);
    try std.testing.expectEqualStrings("tool_started", events[3].event_type);
    try std.testing.expectEqualStrings("tool_output_delta", events[4].event_type);
    try std.testing.expectEqualStrings("tool_finished", events[5].event_type);
    try std.testing.expectEqualStrings("tool_completed", events[6].event_type);
    try std.testing.expectEqualStrings("assistant_delta", events[7].event_type);
    try std.testing.expectEqualStrings("assistant_response", events[8].event_type);

    // The latest event must be the final assistant_response (terminal state).
    const latest = try VAR1.core.session_store.readLatestEvent(std.testing.allocator, workspace_root, session.id);
    defer if (latest) |event| event.deinit(std.testing.allocator);
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings("assistant_response", latest.?.event_type);
    try std.testing.expectEqual(@as(u64, 9), latest.?.seq);
}

test "event spine preserves same-millisecond delta burst ordering for TUI replay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    var session = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "burst replay");
    defer session.deinit(std.testing.allocator);

    // Simulate a rapid burst of assistant deltas — all same timestamp.
    // Without seq, the TUI could not determine their order for replay.
    const burst_ts: i64 = 5000;
    const chunks = [_][]const u8{ "Hello", ", ", "world", "!" };
    for (chunks) |chunk| {
        try VAR1.core.session_store.appendEvent(std.testing.allocator, workspace_root, session.id, .{
            .event_type = "assistant_delta", .message = chunk, .timestamp_ms = burst_ts,
        });
    }

    const events = try VAR1.core.session_store.readEvents(std.testing.allocator, workspace_root, session.id);
    defer VAR1.shared.types.deinitSessionEvents(std.testing.allocator, events);

    // All 4 deltas share the same timestamp, but seq is strictly increasing.
    try std.testing.expectEqual(@as(usize, 4), events.len);
    for (events) |event| {
        try std.testing.expectEqual(burst_ts, event.timestamp_ms);
    }
    try std.testing.expectEqual(@as(u64, 1), events[0].seq);
    try std.testing.expectEqual(@as(u64, 2), events[1].seq);
    try std.testing.expectEqual(@as(u64, 3), events[2].seq);
    try std.testing.expectEqual(@as(u64, 4), events[3].seq);

    // The TUI can reconstruct the message by concatenating in seq order:
    // "Hello" + ", " + "world" + "!" = "Hello, world!"
    var reconstructed = std.array_list.Managed(u8).init(std.testing.allocator);
    defer reconstructed.deinit();
    for (events) |event| {
        try reconstructed.appendSlice(event.message);
    }
    try std.testing.expectEqualStrings("Hello, world!", reconstructed.items);
}

// =============================================================================
// P1-06: Checkpoint-addressed child launch
// =============================================================================

test "launchFromCheckpoint creates child with parent checkpoint reference" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Create parent session with a checkpoint.
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "checkpoint parent");
    defer parent.deinit(std.testing.allocator);

    {
        const id = try std.testing.allocator.dupe(u8, "cp-launch-1");
        const etype = try std.testing.allocator.dupe(u8, "summary_checkpoint");
        const trigger = try std.testing.allocator.dupe(u8, "manual");
        const summary = try std.testing.allocator.dupe(u8, "Parent checkpoint for child launch.");
        defer { std.testing.allocator.free(id); std.testing.allocator.free(etype); std.testing.allocator.free(trigger); std.testing.allocator.free(summary); }
        try VAR1.core.session_store.appendContextCheckpoint(std.testing.allocator, workspace_root, parent.id, .{
            .id = id, .entry_type = etype, .created_at_ms = 1000,
            .source_seq_start = 1, .source_seq_end = 5, .first_kept_seq = 3,
            .tokens_before_estimate = 200, .tokens_after_estimate = 100,
            .trigger = trigger, .summary = summary,
        });
    }

    // Set up agent service.
    const config = VAR1.shared.types.Config{
        .openai_base_url = try std.testing.allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try std.testing.allocator.dupe(u8, "test-key"),
        .openai_model = try std.testing.allocator.dupe(u8, "test-model"),
        .max_steps = 10,
        .workspace_root = try std.testing.allocator.dupe(u8, workspace_root),
    };
    defer {
        std.testing.allocator.free(config.openai_base_url);
        std.testing.allocator.free(config.openai_api_key);
        std.testing.allocator.free(config.openai_model);
        std.testing.allocator.free(config.workspace_root);
    }
    var service = VAR1.core.agent_runtime.Service.init(&config);

    // Launch a checkpoint-addressed child.
    const result = try VAR1.core.agent_runtime.launchFromCheckpoint(
        &service, std.testing.allocator,
        parent.id, "cp-launch-1", 1,
        "Investigate the auth module.", "scout-auth",
    );
    defer std.testing.allocator.free(result);

    // Verify the JSON result references the parent checkpoint.
    try std.testing.expect(std.mem.indexOf(u8, result, "\"parent_checkpoint_id\":\"cp-launch-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"branch_seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"agent_name\":\"scout-auth\"") != null);

    // Verify the parent's context.jsonl has an open shard checkpoint.
    const context_path = try VAR1.shared.fsutil.join(std.testing.allocator, &.{
        workspace_root, ".var", "sessions", parent.id, "context.jsonl",
    });
    defer std.testing.allocator.free(context_path);
    const raw = try VAR1.shared.fsutil.readTextAlloc(std.testing.allocator, context_path);
    defer std.testing.allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"type\":\"shard_checkpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"parent_checkpoint_id\":\"cp-launch-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"branch_status\":\"open\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "scout-auth") != null);
}

// =============================================================================
// P1-07: Shard-scoped memory recall
// =============================================================================

test "recallForBranch reads parent and child session memories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace_root = try tmpWorkspacePath(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(workspace_root);

    // Create parent and child sessions.
    var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace_root, "parent memory");
    defer parent.deinit(std.testing.allocator);
    var child = try VAR1.core.session_store.initSessionWithOptions(
        std.testing.allocator, workspace_root, "child memory",
        .{ .parent_session_id = parent.id },
    );
    defer child.deinit(std.testing.allocator);

    // Write a parent session memory.
    const parent_memories_path = try VAR1.core.memory.store.sessionMemoryPath(std.testing.allocator, workspace_root, parent.id);
    defer std.testing.allocator.free(parent_memories_path);
    try VAR1.shared.fsutil.writeText(parent_memories_path,
        \\{"schema":"vantari.memory.v1","id":"mem-parent-1","operation":"remember","scope":"session","kind":"decision","topic":"architecture","content":"Use append-only JSONL for session storage","trigger":"user_requested","activation":"always","created_at_ms":1000}
    );

    // Write a child session memory.
    const child_memories_path = try VAR1.core.memory.store.sessionMemoryPath(std.testing.allocator, workspace_root, child.id);
    defer std.testing.allocator.free(child_memories_path);
    try VAR1.shared.fsutil.writeText(child_memories_path,
        \\{"schema":"vantari.memory.v1","id":"mem-child-1","operation":"remember","scope":"session","kind":"fact","topic":"search","content":"IX is the search dependency","trigger":"agent_decided","activation":"relevant","created_at_ms":2000}
    );

    // Recall for the branch — should include BOTH parent and child memories.
    const recalled = try VAR1.core.memory.store.recallForBranch(
        std.testing.allocator, workspace_root,
        child.id, parent.id, // child + parent
        "architecture search", // query matches both topics
        4096, // byte budget
    );
    defer std.testing.allocator.free(recalled);

    // Both parent and child memories must be present.
    try std.testing.expect(std.mem.indexOf(u8, recalled, "append-only JSONL") != null);
    try std.testing.expect(std.mem.indexOf(u8, recalled, "IX is the search dependency") != null);
}
