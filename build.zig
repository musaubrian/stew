const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const known_folders = b.dependency(
        "known_folders",
        .{ .target = target, .optimize = optimize },
    ).module("known-folders");

    const exe = b.addExecutable(.{
        .name = "stew",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("build.zig.zon", b.createModule(
        .{ .root_source_file = b.path("build.zig.zon") },
    ));
    exe.root_module.addImport("known_folders", known_folders);

    const version_opts = b.addOptions();
    version_opts.addOption(std.lang.Optimize, "mode", optimize);
    exe.root_module.addOptions("version", version_opts);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const exe_check = b.addExecutable(.{
        .name = "stew_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const check = b.step("check", "Check if app compiles");
    check.dependOn(&exe_check.step);
}
