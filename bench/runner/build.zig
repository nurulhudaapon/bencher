const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zrk_dep = b.dependency("zrk", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bencher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrk", .module = zrk_dep.module("zrk") },
                .{ .name = "zio", .module = zio_dep.module("zio") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the load generator");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
