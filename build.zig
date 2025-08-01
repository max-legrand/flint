const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    const verbose = b.option(bool, "verbose", "Enable verbose logging");
    options.addOption(bool, "verbose", verbose orelse false);
    exe_mod.addOptions("config", options);

    const zlog = b.dependency("zlog", .{});
    exe_mod.addImport("zlog", zlog.module("zlog"));

    const exe = b.addExecutable(.{
        .name = "flint",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const exe_check = b.addExecutable(.{
        .name = "check",
        .root_module = exe_mod,
    });
    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe_check.step);
}
