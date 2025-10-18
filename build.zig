const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const scanner = Scanner.create(b, .{});
    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr_layer_shell_v1.xml"));

    scanner.generate("wl_seat", 4);
    // scanner.generate("xdg_wm_base", 3);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_compositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("zwlr_layer_shell_v1", 5);

    const exe = b.addExecutable(.{
        .name = "wzbar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
            },
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.linkLibC();
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("freetype2");

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
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
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
