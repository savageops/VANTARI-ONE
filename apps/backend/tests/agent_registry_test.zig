const std = @import("std");
const VAR1 = @import("VAR1");

const registry_case_count = 56;

fn registryFromDocument(document: []const u8) !VAR1.core.agent_spec.Registry {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    return VAR1.core.agent_spec.loadRegistryFromValue(std.testing.allocator, parsed.value);
}

fn expectRegistryError(expected: anyerror, document: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, document, .{});
    defer parsed.deinit();
    try std.testing.expectError(expected, VAR1.core.agent_spec.loadRegistryFromValue(std.testing.allocator, parsed.value));
}

fn tmpWorkspacePath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, suffix });
}

fn makeConfig(allocator: std.mem.Allocator, workspace_root: []const u8) !VAR1.shared.types.Config {
    return .{
        .openai_base_url = try allocator.dupe(u8, "http://127.0.0.1:1234"),
        .openai_api_key = try allocator.dupe(u8, "eligibility-secret"),
        .openai_model = try allocator.dupe(u8, "eligibility-model"),
        .auth_provider = try allocator.dupe(u8, "active"),
        .max_steps = 256,
        .max_tool_calls_per_turn = 32,
        .max_tool_calls_per_session = 256,
        .workspace_root = try allocator.dupe(u8, workspace_root),
    };
}

fn makeToolCall(name: []const u8, arguments_json: []const u8) !VAR1.shared.types.ToolCall {
    return .{
        .id = try std.testing.allocator.dupe(u8, "registry-call"),
        .name = try std.testing.allocator.dupe(u8, name),
        .arguments_json = try std.testing.allocator.dupe(u8, arguments_json),
    };
}

fn findDefinition(name: []const u8) ?VAR1.shared.types.ToolDefinition {
    for (VAR1.core.tool_runtime.builtinDefinitions(true)) |definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

fn renderFixtureEligibility(registry: VAR1.core.agent_spec.Registry) ![]u8 {
    const rows = try std.testing.allocator.alloc(VAR1.core.agent_spec.EligibilityAgent, registry.all().len);
    defer std.testing.allocator.free(rows);
    for (registry.all(), 0..) |spec, index| {
        rows[index] = .{
            .id = spec.id,
            .when_to_use = spec.when_to_use,
            .kind = spec.execution_kind.label(),
            .route_role = spec.route_role.label(),
            .capability_profile = spec.capability_profile_id,
            .provider = "fixture-provider",
            .model = "fixture-model",
            .effort = spec.effort,
            .max_children = spec.max_children,
        };
    }
    return VAR1.core.agent_spec.renderEligibilitySnapshot(
        std.testing.allocator,
        rows,
        &.{},
        .{
            .parent_profile_id = "root",
            .delegation_allowed = true,
            .depth_remaining = 3,
            .scope_without_reason = 1,
            .contact_without_reason = 1,
            .capacity_max = 6,
            .capacity_available = 6,
        },
    );
}

fn expectEligibilityReceipt(envelope: []const u8) !void {
    const receipt_marker = "\"receipt\":\"sha256:";
    const snapshot_marker = ",\"snapshot\":";
    const receipt_offset = std.mem.indexOf(u8, envelope, receipt_marker) orelse return error.MissingReceipt;
    const receipt_start = receipt_offset + receipt_marker.len;
    try std.testing.expect(envelope.len > receipt_start + 64);
    const receipt = envelope[receipt_start .. receipt_start + 64];
    const snapshot_offset = std.mem.indexOf(u8, envelope, snapshot_marker) orelse return error.MissingSnapshot;
    const snapshot_start = snapshot_offset + snapshot_marker.len;
    try std.testing.expect(envelope.len > snapshot_start and envelope[envelope.len - 1] == '}');
    const expected = VAR1.core.agent_spec.contentHash(envelope[snapshot_start .. envelope.len - 1]);
    try std.testing.expectEqualStrings(expected[0..], receipt);
}

fn verifyRegistryCase(index: usize) !void {
    switch (index) {
        0 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            try std.testing.expectEqual(@as(usize, 12), registry.all().len);
        },
        1 => {
            const spec = try VAR1.core.agent_spec.resolve("general");
            try std.testing.expectEqual(VAR1.core.provider_routes.ExecutionKind.agent_session, spec.execution_kind);
        },
        2 => {
            const spec = try VAR1.core.agent_spec.resolve("recon");
            try std.testing.expectEqualStrings("recon", spec.capability_profile_id);
        },
        3 => {
            const spec = try VAR1.core.agent_spec.resolve("planner");
            try std.testing.expectEqual(VAR1.core.provider_routes.ExecutionKind.model_task, spec.execution_kind);
        },
        4 => {
            const spec = try VAR1.core.agent_spec.resolve("implementer");
            try std.testing.expectEqualStrings("write", spec.capability_profile_id);
        },
        5 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try renderFixtureEligibility(registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "var1.agent_eligibility.v1") != null);
        },
        6 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try renderFixtureEligibility(registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "when_to_use") != null);
        },
        7 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try renderFixtureEligibility(registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "Inspect only. Return findings") == null);
        },
        8 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"ui_recon\":{\"extends\":\"recon\"}}}}");
            defer registry.deinit();
            try std.testing.expectEqualStrings("recon", (try registry.resolve("ui_recon")).capability_profile_id);
        },
        9 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"ui_recon\":{\"extends\":\"recon\",\"route_role\":\"validation\"}}}}");
            defer registry.deinit();
            try std.testing.expectEqual(VAR1.core.provider_routes.RouteRole.validation, (try registry.resolve("ui_recon")).route_role);
        },
        10 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"ui_recon\":{\"extends\":\"recon\",\"max_steps\":20,\"max_tool_calls\":10}}}}");
            defer registry.deinit();
            const spec = try registry.resolve("ui_recon");
            try std.testing.expectEqual(@as(usize, 20), spec.max_steps);
            try std.testing.expectEqual(@as(usize, 10), spec.max_tool_calls);
        },
        11 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"ui_recon\":{\"extends\":\"recon\",\"output_contract\":\"var1.ui.v1\"}}}}");
            defer registry.deinit();
            try std.testing.expectEqualStrings("var1.ui.v1", (try registry.resolve("ui_recon")).output_contract);
        },
        12 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"recon\":{\"description\":\"Custom recon description.\"}}}}");
            defer registry.deinit();
            try std.testing.expectEqualStrings("Custom recon description.", (try registry.resolve("recon")).description);
        },
        13 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"recon\":{\"route_role\":\"general\"}}}}");
            defer registry.deinit();
            try std.testing.expectEqual(VAR1.core.provider_routes.RouteRole.general, (try registry.resolve("recon")).route_role);
        },
        14 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"recon\":{\"enabled\":false}}}}");
            defer registry.deinit();
            try std.testing.expectEqual(@as(usize, 11), registry.all().len);
        },
        15 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            try std.testing.expectError(VAR1.core.agent_spec.Error.UnknownAgentSpec, registry.resolve("missing_agent"));
        },
        16 => try expectRegistryError(VAR1.core.agent_spec.Error.UnknownAgentBase, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"missing\"}}}}"),
        17 => try expectRegistryError(VAR1.core.agent_spec.Error.UnknownAgentBase, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"description\":\"No base.\"}}}}"),
        18 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"planner\",\"max_steps\":2}}}}"),
        19 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"planner\",\"max_tool_calls\":1}}}}"),
        20 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"planner\",\"max_children\":1}}}}"),
        21 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"max_children\":1}}}}"),
        22 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"implementer\",\"max_children\":1}}}}"),
        23 => try expectRegistryError(VAR1.core.agent_spec.Error.InvalidAgentDefinition, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"general\",\"max_tool_calls\":0}}}}"),
        24 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"Upper\":{\"extends\":\"recon\"}}}}"),
        25 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"bad-id\":{\"extends\":\"recon\"}}}}"),
        26 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"1bad\":{\"extends\":\"recon\"}}}}"),
        27 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"\"}}}}"),
        28 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"max_steps\":0}}}}"),
        29 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"general\",\"max_children\":65}}}}"),
        30 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"route_role\":\"unknown\"}}}}"),
        31 => try expectRegistryError(VAR1.core.agent_spec.Error.EmptyAgentRegistry, "{\"version\":1,\"agents\":{\"definitions\":{\"general\":{\"enabled\":false},\"recon\":{\"enabled\":false},\"planner\":{\"enabled\":false},\"spec\":{\"enabled\":false},\"compactor\":{\"enabled\":false},\"implementer\":{\"enabled\":false},\"doc_writer\":{\"enabled\":false},\"scaffold\":{\"enabled\":false},\"orchestrator_parent\":{\"enabled\":false},\"harvester\":{\"enabled\":false},\"reviewer\":{\"enabled\":false},\"validator\":{\"enabled\":false}}}}"),
        32 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"recon\":{\"route_role\":\"validation\"}}}}");
            defer registry.deinit();
            const configured = try VAR1.core.agent_spec.capabilityHash(try registry.resolve("recon"), "recon");
            const compiled = try VAR1.core.agent_spec.capabilityHash(try VAR1.core.agent_spec.resolve("recon"), "recon");
            try std.testing.expect(!std.mem.eql(u8, configured[0..], compiled[0..]));
        },
        33 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"instruction\":\"PRIVATE-CAPSULE-DO-NOT-LEAK\"}}}}");
            defer registry.deinit();
            const catalog = try renderFixtureEligibility(registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "PRIVATE-CAPSULE-DO-NOT-LEAK") == null);
        },
        34 => {
            const first = VAR1.core.agent_spec.contentHash("same");
            const second = VAR1.core.agent_spec.contentHash("same");
            try std.testing.expectEqualStrings(first[0..], second[0..]);
        },
        35 => {
            var registry = try registryFromDocument("{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"route_role\":\"implementation\"}}}}");
            defer registry.deinit();
            const custom = try registry.resolve("custom");
            try std.testing.expectEqualStrings("recon", custom.capability_profile_id);
            try std.testing.expectEqual(VAR1.core.provider_routes.ExecutionKind.agent_session, custom.execution_kind);
        },
        36, 37, 38, 39, 40 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "mutations");
            defer std.testing.allocator.free(workspace);
            if (index == 36) {
                const evidence = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{ .id = "ui_recon", .extends = "recon", .description = "UI recon." });
                defer evidence.deinit(std.testing.allocator);
                var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
                defer registry.deinit();
                try std.testing.expectEqualStrings("UI recon.", (try registry.resolve("ui_recon")).description);
            } else if (index == 37) {
                var first = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{ .id = "ui_recon", .extends = "recon" });
                first.deinit(std.testing.allocator);
                const evidence = try VAR1.core.agent_spec.resetConfiguredAgent(std.testing.allocator, workspace, "ui_recon");
                defer evidence.deinit(std.testing.allocator);
                var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
                defer registry.deinit();
                try std.testing.expectError(VAR1.core.agent_spec.Error.UnknownAgentSpec, registry.resolve("ui_recon"));
            } else if (index == 38) {
                var first = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{ .id = "recon", .description = "Changed." });
                first.deinit(std.testing.allocator);
                var second = try VAR1.core.agent_spec.resetConfiguredAgent(std.testing.allocator, workspace, "recon");
                second.deinit(std.testing.allocator);
                var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
                defer registry.deinit();
                try std.testing.expectEqualStrings("Read-only repository or evidence reconnaissance. IX/IEX search, exact provenance.", (try registry.resolve("recon")).description);
            } else if (index == 39) {
                const evidence = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{ .id = "recon", .enabled = false });
                defer evidence.deinit(std.testing.allocator);
                var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
                defer registry.deinit();
                try std.testing.expectError(VAR1.core.agent_spec.Error.UnknownAgentSpec, registry.resolve("recon"));
            } else {
                const evidence = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{ .id = "recon", .description = "Hash change." });
                defer evidence.deinit(std.testing.allocator);
                try std.testing.expect(!std.mem.eql(u8, evidence.before_sha256[0..], evidence.after_sha256[0..]));
                try std.testing.expect(evidence.after_bytes > 0);
            }
        },
        41 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "catalog-ledger");
            defer std.testing.allocator.free(workspace);
            const config = try makeConfig(std.testing.allocator, workspace);
            defer config.deinit(std.testing.allocator);
            var service = VAR1.core.agent_runtime.Service.init(&config);
            defer service.deinit();
            var parent = try VAR1.core.session_store.initSession(std.testing.allocator, workspace, "eligibility parent");
            defer parent.deinit(std.testing.allocator);
            var ledger = VAR1.core.tool_runtime.AgentEligibilityLedger{};
            var call = try makeToolCall("agents", "{}");
            defer call.deinit(std.testing.allocator);
            const output = try VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = workspace,
                .session_id = parent.id,
                .parent_session_id = parent.id,
                .agent_service = service.handle(),
                .capability_profile_id = "root",
                .delegation_depth_remaining = 3,
                .orchestrator_only = true,
                .agent_eligibility_ledger = &ledger,
            }, call);
            defer std.testing.allocator.free(output);
            try std.testing.expect(ledger.hasCurrent());
            try std.testing.expect(std.mem.indexOf(u8, output, "var1.agent_eligibility.v1") != null);
        },
        42 => {
            var ledger = VAR1.core.tool_runtime.AgentEligibilityLedger{};
            var call = try makeToolCall("launch_agent", "{\"context\":\"\",\"tasks\":[{\"agent\":\"recon\",\"task\":\"x\"}]}");
            defer call.deinit(std.testing.allocator);
            try std.testing.expectError(VAR1.core.tool_runtime.Error.AgentEligibilityRequired, VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = ".",
                .orchestrator_only = true,
                .agent_eligibility_ledger = &ledger,
            }, call));
        },
        43 => {
            var ledger = VAR1.core.tool_runtime.AgentEligibilityLedger{};
            ledger.markCurrent();
            var call = try makeToolCall("read_file", "{\"path\":\"README.md\"}");
            defer call.deinit(std.testing.allocator);
            try std.testing.expectError(VAR1.core.tool_runtime.Error.CapabilityDenied, VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = ".",
                .orchestrator_only = true,
                .agent_eligibility_ledger = &ledger,
            }, call));
        },
        44 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "policy");
            defer std.testing.allocator.free(workspace);
            const policy = try VAR1.core.config_file.loadAgentPolicy(std.testing.allocator, workspace);
            try std.testing.expect(policy.orchestrator_only);
        },
        45 => {
            const launch = findDefinition("launch_agent") orelse return error.MissingLaunchAgentDefinition;
            try std.testing.expect(std.mem.indexOf(u8, launch.parameters_json, "general,recon") == null);
            try std.testing.expect(std.mem.indexOf(u8, launch.parameters_json, "Hot-loaded specialist id") != null);
        },
        46 => {
            const scaffold = try VAR1.core.agent_spec.resolve("scaffold");
            try std.testing.expectEqualStrings("self_directed", scaffold.autonomy);
            try std.testing.expect(scaffold.ticket_ownership);
            const orchestrator = try VAR1.core.agent_spec.resolve("orchestrator_parent");
            try std.testing.expectEqual(@as(usize, 12), orchestrator.max_children);
            try std.testing.expectEqualStrings("ticket-discipline parallel-fanout live-monitor reconcile-contradictions parent-owned-conclusion close-with-reasoning", orchestrator.doctrine_tags);
            const planner = try VAR1.core.agent_spec.resolve("planner");
            try std.testing.expect(!planner.ticket_ownership);
            const implementer = try VAR1.core.agent_spec.resolve("implementer");
            try std.testing.expect(implementer.ticket_ownership);
            try std.testing.expectEqualStrings("var1.summary.v1", implementer.checkpoint_contract);
        },
        47 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try renderFixtureEligibility(registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"provider\":\"fixture-provider\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"model\":\"fixture-model\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"doctrine\"") == null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"instruction_capsule\"") == null);
        },
        48 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "doctrine-upsert");
            defer std.testing.allocator.free(workspace);
            const evidence = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{
                .id = "frontend_recon",
                .extends = "recon",
                .description = "Frontend ownership recon.",
                .doctrine_tags = "evidence-first findings-ledger",
                .ticket_ownership = true,
                .checkpoint_contract = "var1.summary.v1",
                .autonomy = "bounded",
                .effort = "high",
                .temperature = 0.3,
            });
            defer evidence.deinit(std.testing.allocator);
            var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
            defer registry.deinit();
            const spec = try registry.resolve("frontend_recon");
            try std.testing.expectEqualStrings("evidence-first findings-ledger", spec.doctrine_tags);
            try std.testing.expect(spec.ticket_ownership);
            try std.testing.expectEqualStrings("var1.summary.v1", spec.checkpoint_contract);
            try std.testing.expectEqualStrings("bounded", spec.autonomy);
            try std.testing.expectEqualStrings("high", spec.effort);
            try std.testing.expectApproxEqAbs(@as(f64, 0.3), spec.temperature, 1e-9);
        },
        49 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"autonomy\":\"unlimited\"}}}}"),
        50 => try expectRegistryError(VAR1.core.config_file.Error.InvalidConfig, "{\"version\":1,\"agents\":{\"definitions\":{\"custom\":{\"extends\":\"recon\",\"temperature\":3.5}}}}"),
        51 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "no-ticket");
            defer std.testing.allocator.free(workspace);
            const evidence = try VAR1.core.agent_spec.upsertConfiguredAgent(std.testing.allocator, workspace, .{
                .id = "no_ticket_recon",
                .extends = "recon",
                .ticket_ownership = false,
            });
            defer evidence.deinit(std.testing.allocator);
            var registry = try VAR1.core.agent_spec.loadRegistry(std.testing.allocator, workspace);
            defer registry.deinit();
            try std.testing.expect(!(try registry.resolve("no_ticket_recon")).ticket_ownership);
        },
        52 => {
            const spec = try VAR1.core.agent_spec.resolve("doc_writer");
            try std.testing.expectEqual(@as(usize, 120), spec.max_steps);
            const harvester = try VAR1.core.agent_spec.resolve("harvester");
            try std.testing.expectEqualStrings("harvest-before-originate six-competitor-floor source-or-retract evidence-ledger benchmark-deep", harvester.doctrine_tags);
            const reviewer = try VAR1.core.agent_spec.resolve("reviewer");
            try std.testing.expectEqualStrings("findings-first capability-truth no-parallel-systems falsification-pressure maintainer-craft", reviewer.doctrine_tags);
        },
        53 => {
            const general = try VAR1.core.agent_spec.resolve("general");
            const recon = try VAR1.core.agent_spec.resolve("recon");
            const first_rows = [_]VAR1.core.agent_spec.EligibilityAgent{
                .{ .id = recon.id, .when_to_use = recon.when_to_use, .kind = recon.execution_kind.label(), .route_role = recon.route_role.label(), .capability_profile = recon.capability_profile_id, .provider = "p", .model = "m", .effort = "", .max_children = recon.max_children },
                .{ .id = general.id, .when_to_use = general.when_to_use, .kind = general.execution_kind.label(), .route_role = general.route_role.label(), .capability_profile = general.capability_profile_id, .provider = "p", .model = "m", .effort = "", .max_children = general.max_children },
            };
            const second_rows = [_]VAR1.core.agent_spec.EligibilityAgent{ first_rows[1], first_rows[0] };
            const state = VAR1.core.agent_spec.EligibilityState{
                .parent_profile_id = "root",
                .delegation_allowed = true,
                .depth_remaining = 2,
                .scope_without_reason = 1,
                .contact_without_reason = 1,
                .capacity_max = 2,
                .capacity_available = 1,
            };
            const first = try VAR1.core.agent_spec.renderEligibilitySnapshot(std.testing.allocator, &first_rows, &.{}, state);
            defer std.testing.allocator.free(first);
            const second = try VAR1.core.agent_spec.renderEligibilitySnapshot(std.testing.allocator, &second_rows, &.{}, state);
            defer std.testing.allocator.free(second);
            try std.testing.expectEqualStrings(first, second);
            try expectEligibilityReceipt(first);
            var changed_state = state;
            changed_state.capacity_available = 0;
            const changed = try VAR1.core.agent_spec.renderEligibilitySnapshot(std.testing.allocator, &first_rows, &.{}, changed_state);
            defer std.testing.allocator.free(changed);
            try expectEligibilityReceipt(changed);
            try std.testing.expect(!std.mem.eql(u8, first, changed));
        },
        54 => {
            const unavailable = [_]VAR1.core.agent_spec.UnavailableAgent{
                .{ .id = "reviewer", .reason = "route_unavailable" },
            };
            const snapshot = try VAR1.core.agent_spec.renderEligibilitySnapshot(std.testing.allocator, &.{}, &unavailable, .{
                .parent_profile_id = "root",
                .delegation_allowed = true,
                .depth_remaining = 1,
                .scope_without_reason = 1,
                .contact_without_reason = 1,
                .capacity_max = 1,
                .capacity_running = 1,
                .capacity_available = 0,
            });
            defer std.testing.allocator.free(snapshot);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"admission\":\"queue_only\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"reason\":\"route_unavailable\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"model_choices\":[\"quiet\",\"inspect\",\"message\",\"challenge\",\"launch\",\"queue\",\"wake\"]") != null);
        },
        55 => {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const workspace = try tmpWorkspacePath(std.testing.allocator, &tmp, "eligibility-invalidation");
            defer std.testing.allocator.free(workspace);
            var ledger = VAR1.core.tool_runtime.AgentEligibilityLedger{};
            ledger.markCurrent();
            var call = try makeToolCall("configure_agent", "{\"action\":\"upsert\",\"id\":\"fresh_recon\",\"extends\":\"recon\"}");
            defer call.deinit(std.testing.allocator);
            const output = try VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = workspace,
                .orchestrator_only = true,
                .agent_eligibility_ledger = &ledger,
            }, call);
            defer std.testing.allocator.free(output);
            try std.testing.expect(std.mem.indexOf(u8, output, "var1.agent_config_effect.v1") != null);
            try std.testing.expect(!ledger.hasCurrent());
        },
        else => return error.UnknownRegistryCase,
    }
}

test "agent registry contracts cover every declared case" {
    for (0..registry_case_count) |index| try verifyRegistryCase(index);
}

test "agent registry case count stays above the planning pressure floor" {
    try std.testing.expect(registry_case_count >= 30);
}
