//! Host-side Docker bench orchestrator.
//!
//! Layout:
//!   bench/src/          this orchestrator (compose + docker run loop)
//!   bench/runner/       in-container load generator (binary still named `bencher`)
//!   bench/docker/       Dockerfile for the load-generator image
//!
//! Discovers frameworks/*/Dockerfile and writes bench/compose.generated.yml.
//! Usage: zig build run -- [zap httpz ...]   (default: all discovered)

const std = @import("std");
const Io = std.Io;

const port: u16 = 8081;
const health_path = "/httpz";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    const root = try findRepoRoot(arena, io);
    const frameworks_dir = try std.fs.path.join(arena, &.{ root, "frameworks" });
    const bench_dir = try std.fs.path.join(arena, &.{ root, "bench" });
    const out_zon = try std.fs.path.join(arena, &.{ root, "app", "results.zon" });
    const compose_path = try std.fs.path.join(arena, &.{ bench_dir, "compose.generated.yml" });

    const discovered = try discoverFrameworks(arena, io, frameworks_dir);
    const frameworks: []const []const u8 = if (args.len > 1)
        try filterRequested(arena, discovered, args[1..])
    else
        discovered;

    if (frameworks.len == 0) return error.NoFrameworks;

    // Always register every discovered framework in compose so leftover
    // containers from prior runs can be stopped (cpuset isolation).
    try writeCompose(arena, io, compose_path, discovered, frameworks_dir);

    const csv = try joinCsv(arena, frameworks);
    std.log.info("frameworks: {s}", .{csv});
    std.log.info("compose:    {s}", .{compose_path});
    std.log.info("output:     {s}", .{out_zon});

    // CI pre-builds images with Buildx/GHA cache, then sets BENCH_SKIP_BUILD=1.
    const skip_build = if (init.environ_map.get("BENCH_SKIP_BUILD")) |v|
        v.len > 0 and !std.mem.eql(u8, v, "0") and !std.mem.eql(u8, v, "false")
    else
        false;
    if (skip_build) {
        std.log.info("BENCH_SKIP_BUILD set - using preloaded images", .{});
    } else {
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "build" });
        try cmd.appendSlice(arena, frameworks);
        try cmd.append(arena, "bencher");
        try runInDir(gpa, io, bench_dir, cmd.items);
    }

    // Fair isolation: only one framework at a time.
    const volume = try std.fmt.allocPrint(arena, "{s}/app:/out", .{root});
    // Clear prior partials; keep app/results.zon until merge rewrites it.
    {
        const app_dir_path = try std.fs.path.join(arena, &.{ root, "app" });
        var app_dir = try Io.Dir.cwd().openDir(io, app_dir_path, .{ .iterate = true });
        defer app_dir.close(io);
        var it = app_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, ".bench-")) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
            app_dir.deleteFile(io, entry.name) catch {};
        }
    }

    // Tear down any leftover project containers from interrupted runs.
    {
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "down", "--remove-orphans" });
        runInDir(gpa, io, bench_dir, cmd.items) catch {};
    }

    for (frameworks) |fw| {
        std.log.info("── framework {s} ──", .{fw});

        // Fresh container per scenario so a wedged server cannot poison later runs.
        const scenarios = [_][]const u8{ "plaintext", "json" };
        for (scenarios) |scenario| {
            if (std.mem.eql(u8, scenario, "json") and
                (std.mem.eql(u8, fw, "std") or std.mem.eql(u8, fw, "zzz")))
            {
                continue;
            }

            {
                var cmd: std.ArrayList([]const u8) = .empty;
                try cmd.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "up", "-d", "--wait", "--force-recreate", fw });
                try runInDir(gpa, io, bench_dir, cmd.items);
            }

            {
                const env_fw = try std.fmt.allocPrint(arena, "BENCH_FRAMEWORKS={s}", .{fw});
                const env_sc = try std.fmt.allocPrint(arena, "BENCH_SCENARIOS={s}", .{scenario});
                var cmd: std.ArrayList([]const u8) = .empty;
                try cmd.appendSlice(arena, &.{
                    "docker",         "compose",
                    "-f",             compose_path,
                    "run",            "--rm",
                    "--no-deps",      "-e",
                    env_fw,           "-e",
                    env_sc,
                });
                if (init.environ_map.get("BENCH_PLATFORM")) |plat| {
                    const env_pl = try std.fmt.allocPrint(arena, "BENCH_PLATFORM={s}", .{plat});
                    try cmd.appendSlice(arena, &.{ "-e", env_pl });
                }
                try cmd.appendSlice(arena, &.{
                    "-v",             volume,
                    "bencher",        "/out/results.zon",
                });
                // OrbStack + zio/io_uring occasionally SIGBUS/SIGTRAP under load.
                var attempt: u32 = 0;
                while (true) : (attempt += 1) {
                    runInDir(gpa, io, bench_dir, cmd.items) catch |err| {
                        if (attempt + 1 >= 4) return err;
                        std.log.warn("bencher {s}/{s} failed ({s}); retry {d}/3", .{ fw, scenario, @errorName(err), attempt + 1 });
                        {
                            var recreate: std.ArrayList([]const u8) = .empty;
                            try recreate.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "up", "-d", "--wait", "--force-recreate", fw });
                            runInDir(gpa, io, bench_dir, recreate.items) catch |re| {
                                std.log.warn("recreate {s} failed: {s}", .{ fw, @errorName(re) });
                            };
                        }
                        continue;
                    };
                    break;
                }
            }

            {
                var cmd: std.ArrayList([]const u8) = .empty;
                try cmd.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "stop", fw });
                runInDir(gpa, io, bench_dir, cmd.items) catch |err| {
                    std.log.warn("stop {s} failed: {s}", .{ fw, @errorName(err) });
                };
            }
        }
    }

    {
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(arena, &.{
            "docker",         "compose",
            "-f",             compose_path,
            "run",            "--rm",
            "--no-deps",      "-v",
            volume,           "bencher",
            "--merge",        "/out/results.zon",
        });
        try runInDir(gpa, io, bench_dir, cmd.items);
    }

    {
        var cmd: std.ArrayList([]const u8) = .empty;
        try cmd.appendSlice(arena, &.{ "docker", "compose", "-f", compose_path, "down", "--remove-orphans" });
        runInDir(gpa, io, bench_dir, cmd.items) catch {};
    }

    std.log.info("done → {s}", .{out_zon});
}

fn discoverFrameworks(arena: std.mem.Allocator, io: Io, frameworks_dir: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, frameworks_dir, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "shared")) continue;

        const dockerfile = try std.fs.path.join(arena, &.{ frameworks_dir, entry.name, "Dockerfile" });
        if (!pathExists(io, dockerfile)) continue;

        try list.append(arena, try arena.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    return try list.toOwnedSlice(arena);
}

fn filterRequested(
    arena: std.mem.Allocator,
    discovered: []const []const u8,
    requested: []const []const u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (requested) |req| {
        var found = false;
        for (discovered) |d| {
            if (std.mem.eql(u8, d, req)) {
                try list.append(arena, d);
                found = true;
                break;
            }
        }
        if (!found) {
            std.log.err("unknown framework '{s}' (no frameworks/{s}/Dockerfile)", .{ req, req });
            return error.UnknownFramework;
        }
    }
    return try list.toOwnedSlice(arena);
}

fn writeCompose(
    arena: std.mem.Allocator,
    io: Io,
    compose_path: []const u8,
    frameworks: []const []const u8,
    frameworks_dir: []const u8,
) !void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(
        \\# Generated by bench/src/main.zig - do not edit.
        \\name: zig_web_bench
        \\
        \\x-framework: &framework
        \\  deploy:
        \\    resources:
        \\      limits:
        \\        cpus: "2"
        \\        memory: 2G
        \\  networks:
        \\    - bench-net
        \\
        \\x-healthcheck: &healthcheck
        \\  test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8081/httpz"]
        \\  interval: 1s
        \\  timeout: 2s
        \\  retries: 30
        \\  start_period: 2s
        \\
        \\services:
        \\
    );

    for (frameworks) |fw| {
        const privileged_path = try std.fs.path.join(arena, &.{ frameworks_dir, fw, "privileged" });
        const privileged = pathExists(io, privileged_path);

        try w.print(
            \\  {s}:
            \\    <<: *framework
            \\    image: zig_web_bench-{s}
            \\    build:
            \\      context: ..
            \\      dockerfile: frameworks/{s}/Dockerfile
            \\
        , .{ fw, fw, fw });
        if (privileged) try w.writeAll("    privileged: true\n");
        try w.writeAll("    healthcheck: *healthcheck\n\n");
    }

    try w.writeAll(
        \\  bencher:
        \\    image: zig_web_bench-bencher
        \\    build:
        \\      context: ..
        \\      dockerfile: bench/docker/Dockerfile
        \\      args:
        \\        ZIG_VER: "0.16.0"
        \\    # zio/zrk needs io_uring (Docker Desktop / OrbStack)
        \\    privileged: true
        \\    deploy:
        \\      resources:
        \\        limits:
        \\          cpus: "2"
        \\          memory: 4G
        \\    environment:
        \\      BENCH_FRAMEWORKS: ${BENCH_FRAMEWORKS:-}
        \\      BENCH_SCENARIOS: ${BENCH_SCENARIOS:-}
        \\      BENCH_PLATFORM: ${BENCH_PLATFORM:-}
        \\    volumes:
        \\      - ../app:/out
        \\    networks:
        \\      - bench-net
        \\
        \\networks:
        \\  bench-net:
        \\    driver: bridge
        \\
    );

    _ = port;
    _ = health_path;

    const body = aw.written();
    const file = try Io.Dir.cwd().createFile(io, compose_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

fn joinCsv(arena: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try list.append(arena, ',');
        try list.appendSlice(arena, item);
    }
    return try list.toOwnedSlice(arena);
}

fn findRepoRoot(arena: std.mem.Allocator, io: Io) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    var dir = try arena.dupe(u8, cwd_buf[0..cwd_len]);

    while (true) {
        const marker = try std.fs.path.join(arena, &.{ dir, "frameworks" });
        const bench = try std.fs.path.join(arena, &.{ dir, "bench", "docker", "Dockerfile" });
        if (pathExists(io, marker) and pathExists(io, bench)) return dir;

        const parent = std.fs.path.dirname(dir) orelse return error.RepoRootNotFound;
        if (std.mem.eql(u8, parent, dir)) return error.RepoRootNotFound;
        dir = try arena.dupe(u8, parent);
    }
}

fn pathExists(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn runInDir(gpa: std.mem.Allocator, io: Io, cwd: []const u8, argv: []const []const u8) !void {
    const joined = try joinArgs(gpa, argv);
    defer gpa.free(joined);
    std.log.info("$ {s}", .{joined});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn joinArgs(gpa: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    for (argv, 0..) |a, i| {
        if (i > 0) try list.append(gpa, ' ');
        try list.appendSlice(gpa, a);
    }
    return try list.toOwnedSlice(gpa);
}
