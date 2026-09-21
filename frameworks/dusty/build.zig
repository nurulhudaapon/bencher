const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_mod = b.addModule("shared_mod", .{
        .root_source_file = b.path("../shared/shared_mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bench_dusty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared_mod", .module = shared_mod },
            },
        }),
    });

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
        .use_tls = false,
    });
    exe.root_module.addImport("dusty", dusty.module("dusty"));
    b.installArtifact(exe);
}
