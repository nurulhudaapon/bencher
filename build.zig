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

    const run_step = b.step("run", "Run Docker framework benchmarks (bench/run.sh → app/results.zon)");
    const run_cmd = b.addSystemCommand(&.{ "bash", "./bench/run.sh" });
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
}
