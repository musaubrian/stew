const std = @import("std");

const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(
        .{ .preferred_optimize_mode = .small },
    );

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
    exe.root_module.addImport("known_folders", known_folders);

    const version_opts = b.addOptions();
    version_opts.addOption(std.lang.Optimize, "mode", optimize);
    exe.root_module.addOptions("version", version_opts);

    const results = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{});
    const hash = switch (results) {
        .success => |hash| std.mem.trim(u8, hash, "\n"),
        else => "Unknown",
    };
    const version_str = b.allocator.print("{s}-{s}", .{ zon.version, hash }) catch @panic("oom");
    version_opts.addOption([]const u8, "str", version_str);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

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
    exe_check.root_module.addImport("known_folders", known_folders);
    exe_check.root_module.addOptions("version", version_opts);

    const check = b.step("check", "Check if app compiles");
    check.dependOn(&exe_check.step);
}
