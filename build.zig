const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const graphon_mod = b.addModule("graphon", .{
        .root_source_file = b.path("src/graphon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    graphon_mod.linkSystemLibrary("rocksdb", .{});

    const lib = b.addLibrary(.{
        .name = "graphon",
        .linkage = .static,
        .root_module = graphon_mod,
    });
    b.installArtifact(lib);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const anyline_dep = b.dependency("anyline", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("anyline", anyline_dep.module("anyline"));
    exe_mod.linkSystemLibrary("rocksdb", .{});

    const exe = b.addExecutable(.{
        .name = "graphon",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addImport("anyline", anyline_dep.module("anyline"));
    const cli_exe = b.addExecutable(.{
        .name = "graphon-cli",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = graphon_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const cli_unit_tests = b.addTest(.{
        .root_module = cli_mod,
    });
    const run_cli_unit_tests = b.addRunArtifact(cli_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_cli_unit_tests.step);
}
