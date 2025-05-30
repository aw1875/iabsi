const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const client = b.addExecutable(.{
        .name = "iabsi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(client);

    // TODO: Setup client run and test command?

    const daemon = b.addExecutable(.{
        .name = "iabsid",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    daemon.root_module.addImport("sqlite", sqlite.module("sqlite"));

    b.installArtifact(daemon);

    const daemon_run_cmd = b.addRunArtifact(daemon);
    daemon_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        daemon_run_cmd.addArgs(args);
    }

    const daemon_run_step = b.step("run", "Run the daemon");
    daemon_run_step.dependOn(&daemon_run_cmd.step);

    const daemon_unit_tests = b.addTest(.{
        .root_module = daemon.root_module,
    });

    const run_daemon_unit_tests = b.addRunArtifact(daemon_unit_tests);

    const daemon_test_step = b.step("test", "Run unit tests against the daemon");
    daemon_test_step.dependOn(&run_daemon_unit_tests.step);
}
