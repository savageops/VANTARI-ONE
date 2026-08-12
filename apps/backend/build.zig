const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("VAR1", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The TUI (vaxis) dependency is an exe-level concern, not a kernel
    // concern. The VAR1 library module stays dependency-free; only the
    // executable and the tui_chat test artifact pull in the tui module.
    const tui_dep = b.dependency("vantari_tui", .{
        .target = target,
        .optimize = optimize,
    });
    const tui_mod = tui_dep.module("tui");

    const exe = b.addExecutable(.{
        .name = "vantari",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = mod },
                .{ .name = "tui", .module = tui_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = mod },
            },
        }),
    });
    const run_integration_tests = addIsolatedTestRun(b, integration_tests, "integration");

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = addIsolatedTestRun(b, exe_tests, "exe");

    // TUI chat tests — needs the tui import alongside VAR1.
    const tui_chat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/clients/tui_chat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = mod },
                .{ .name = "tui", .module = tui_mod },
            },
        }),
    });
    const run_tui_chat_tests = addIsolatedTestRun(b, tui_chat_tests, "tui");
    const tui_test_step = b.step("test-tui", "Run TUI chat tests");
    tui_test_step.dependOn(&run_tui_chat_tests.step);

    const memory_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/memory_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_memory_tests = addIsolatedTestRun(b, memory_tests, "memory");

    // Provider cost/compat src-file tests (pricing, compat, turn_payload,
    // config) — Zig 0.15 runs a file's tests only inside the root module's
    // own file tree, so src modules must be referenced from a src-rooted
    // harness (same pattern as memory_tests.zig).
    const chain035_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/chain035_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_chain035_tests = addIsolatedTestRun(b, chain035_tests, "chain035");

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tui_chat_tests.step);
    test_step.dependOn(&run_memory_tests.step);
    test_step.dependOn(&run_chain035_tests.step);
}

/// Isolate test state at the child-process boundary.
/// Adapted from: ../../.refs/openai__codex/codex-rs/login/src/auth/storage_tests.rs
fn addIsolatedTestRun(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    name: []const u8,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    const test_root = b.pathResolve(&.{
        b.build_root.path orelse ".",
        b.cache_root.path orelse ".",
    });
    const test_home = b.pathResolve(&.{
        test_root,
        "vantari-test-home",
        b.fmt("{x}", .{b.graph.random_seed}),
        name,
    });
    run.setEnvironmentVariable("VANTARI_HOME", test_home);
    run.setEnvironmentVariable("VANTARI_TEST_ROOT", test_root);
    return run;
}
