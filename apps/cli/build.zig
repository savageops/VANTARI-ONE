const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kernel_mod = b.addModule("VAR1", .{
        .root_source_file = b.path("../backend/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tui_dep = b.dependency("vantari_tui", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "var",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = kernel_mod },
                .{ .name = "tui", .module = tui_dep.module("tui") },
            },
        }),
    });
    b.installArtifact(exe);

    const powershell_exe = b.addExecutable(.{
        .name = "vantari",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = kernel_mod },
                .{ .name = "tui", .module = tui_dep.module("tui") },
            },
        }),
    });
    b.installArtifact(powershell_exe);

    const run_step = b.step("run", "Run the var CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const tui_chat_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tui_chat.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "VAR1", .module = kernel_mod },
                .{ .name = "tui", .module = tui_dep.module("tui") },
            },
        }),
    });
    const run_tui_chat_tests = b.addRunArtifact(tui_chat_tests);

    const test_step = b.step("test", "Run CLI package tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_tui_chat_tests.step);
}
