const std = @import("std");
const VAR1 = @import("VAR1");

const registry_case_count = 53;

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
            const catalog = try VAR1.core.agent_spec.renderCatalog(std.testing.allocator, registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "var1.agent_catalog.v1") != null);
        },
        6 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try VAR1.core.agent_spec.renderCatalog(std.testing.allocator, registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "when_to_use") != null);
        },
        7 => {
            var registry = try registryFromDocument("{\"version\":1}");
            defer registry.deinit();
            const catalog = try VAR1.core.agent_spec.renderCatalog(std.testing.allocator, registry);
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
            const catalog = try VAR1.core.agent_spec.renderCatalog(std.testing.allocator, registry);
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
            var ledger = VAR1.core.tool_runtime.AgentDiscoveryLedger{};
            var call = try makeToolCall("agents", "{}");
            defer call.deinit(std.testing.allocator);
            const output = try VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = workspace,
                .orchestrator_only = true,
                .agent_discovery_ledger = &ledger,
            }, call);
            defer std.testing.allocator.free(output);
            try std.testing.expect(ledger.hasDiscovered());
            try std.testing.expect(std.mem.indexOf(u8, output, "var1.agent_catalog.v1") != null);
        },
        42 => {
            var ledger = VAR1.core.tool_runtime.AgentDiscoveryLedger{};
            var call = try makeToolCall("launch_agent", "{\"context\":\"\",\"tasks\":[{\"agent\":\"recon\",\"task\":\"x\"}]}");
            defer call.deinit(std.testing.allocator);
            try std.testing.expectError(VAR1.core.tool_runtime.Error.AgentCatalogRequired, VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = ".",
                .orchestrator_only = true,
                .agent_discovery_ledger = &ledger,
            }, call));
        },
        43 => {
            var ledger = VAR1.core.tool_runtime.AgentDiscoveryLedger{};
            ledger.mark();
            var call = try makeToolCall("read_file", "{\"path\":\"README.md\"}");
            defer call.deinit(std.testing.allocator);
            try std.testing.expectError(VAR1.core.tool_runtime.Error.CapabilityDenied, VAR1.core.tool_runtime.execute(std.testing.allocator, .{
                .workspace_root = ".",
                .orchestrator_only = true,
                .agent_discovery_ledger = &ledger,
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
            const catalog = try VAR1.core.agent_spec.renderCatalog(std.testing.allocator, registry);
            defer std.testing.allocator.free(catalog);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"doctrine\":\"ticket-discipline") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"ticket_ownership\":true") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"ticket_ownership\":false") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"checkpoint\":\"var1.summary.v1\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"autonomy\":\"self_directed\"") != null);
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
        else => return error.UnknownRegistryCase,
    }
}

test "agent registry contracts cover every declared case" {
    for (0..registry_case_count) |index| try verifyRegistryCase(index);
}

test "agent registry case count stays above the planning pressure floor" {
    try std.testing.expect(registry_case_count >= 30);
}
