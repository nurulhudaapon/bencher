const std = @import("std");
const ziex = @import("ziex");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_exe = b.addExecutable(.{
        .name = "web_bencher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    _ = try ziex.init(b, app_exe, .{
        .app = .{
            .client = .{
                .bindings = .{
                    .build = .enabled,
                    .install_subdir = "bindings",
                },
            },
        },
    });

    // Docker framework benchmarks: `zig build run -- [zap httpz ...]`
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench_exe);

    const run_step = b.step("run", "Run Docker framework benchmarks (zrk → app/results.zon)");
    const run_cmd = b.addRunArtifact(bench_exe);
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
}
