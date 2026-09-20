//! Docker-side load-test harness using zrk programmatically.
//! Waits for framework services, runs configured scenarios, writes results.zon.

const std = @import("std");
const Io = std.Io;
const zio = @import("zio");
const zrk = @import("zrk");

const fig = @import("benchfig.zon");

const ScenarioResult = struct {
    framework: []const u8,
    scenario: []const u8,
    platform: []const u8 = "",
    rps: f64,
    average_s: f64,
    fastest_s: f64,
    slowest_s: f64,
    success_rate: f64,
    latency_p50_s: f64,
    latency_p95_s: f64,
    latency_p99_s: f64,
    achieved_rate: f64,
    target_rate: f64,
    error_rate: f64,
    requests: u64,
};

const known_platforms = [_]struct { id: []const u8, os: []const u8, arch: []const u8, label: []const u8 }{
    .{ .id = "linux-x86_64", .os = "linux", .arch = "x86_64", .label = "Linux x86_64" },
    .{ .id = "linux-aarch64", .os = "linux", .arch = "aarch64", .label = "Linux aarch64" },
    .{ .id = "macos-x86_64", .os = "macos", .arch = "x86_64", .label = "macOS x86_64" },
    .{ .id = "macos-aarch64", .os = "macos", .arch = "aarch64", .label = "macOS aarch64" },
    .{ .id = "windows-x86_64", .os = "windows", .arch = "x86_64", .label = "Windows x86_64" },
    .{ .id = "windows-aarch64", .os = "windows", .arch = "aarch64", .label = "Windows aarch64" },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--merge")) {
        const out_path = if (args.len > 2) args[2] else "/out/results.zon";
        mergeFromSidecar(init.gpa, init.io, init.environ_map, out_path) catch |err| {
            std.log.err("bencher merge failed: {s}", .{@errorName(err)});
            return err;
        };
        return;
    }

    mainInner(init) catch |err| {
        std.log.err("bencher failed: {s}", .{@errorName(err)});
        return err;
    };
}

fn mainInner(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const out_path = if (args.len > 1) args[1] else "/out/results.zon";

    const frameworks = if (init.environ_map.get("BENCH_FRAMEWORKS")) |raw|
        try splitCsv(gpa, raw)
    else
        try listFrameworks(gpa);
    defer {
        if (init.environ_map.get("BENCH_FRAMEWORKS") != null) {
            for (frameworks) |fw| gpa.free(fw);
        }
        gpa.free(frameworks);
    }

    var rt = try zio.Runtime.init(gpa, .{
        .executors = .exact(fig.threads),
    });
    defer rt.deinit();
    const io = rt.io();

    const platform_id = try detectPlatformId(gpa, init.environ_map);
    defer gpa.free(platform_id);

    std.log.info("bencher starting; frameworks={d} scenarios={d} platform={s} out={s}", .{
        frameworks.len,
        @typeInfo(@TypeOf(fig.scenarios)).@"struct".fields.len,
        platform_id,
        out_path,
    });

    const scenario_filter: ?[]const []const u8 = if (init.environ_map.get("BENCH_SCENARIOS")) |raw|
        try splitCsv(gpa, raw)
    else
        null;
    defer if (scenario_filter) |sf| {
        for (sf) |s| gpa.free(s);
        gpa.free(sf);
    };

    var results: std.ArrayList(ScenarioResult) = .empty;
    defer results.deinit(gpa);

    inline for (@typeInfo(@TypeOf(fig.scenarios)).@"struct".fields) |field| {
        const scenario = @field(fig.scenarios, field.name);
        const scenario_wanted: bool = blk: {
            const sf = scenario_filter orelse break :blk true;
            for (sf) |id| {
                if (std.mem.eql(u8, id, scenario.id)) break :blk true;
            }
            break :blk false;
        };
        if (scenario_wanted) {
            for (frameworks) |fw| {
            // JSON scenario is not implemented on std/zzz (plaintext-only).
            if (std.mem.eql(u8, scenario.id, "json") and
                (std.mem.eql(u8, fw, "std") or std.mem.eql(u8, fw, "zzz")))
            {
                std.log.info("skip {s}/{s} (endpoint not supported)", .{ fw, scenario.id });
                continue;
            }

            waitHealthy(io, fw, fig.port, scenario.path) catch |err| {
                std.log.err("unhealthy before {s}/{s}: {s} — keeping {d} prior run(s)", .{
                    fw,
                    scenario.id,
                    @errorName(err),
                    results.items.len,
                });
                // Persist what we have so a wedged server does not discard earlier scenarios.
                if (results.items.len > 0) {
                    try writePartial(gpa, io, init.environ_map, out_path, results.items);
                    std.log.info("wrote partial for {s} ({d} runs)", .{ fw, results.items.len });
                }
                return err;
            };
            // Brief settle after health — reduces OrbStack io_uring flakiness on first blast.
            // Zinc needs longer: aarch64 CI wedges immediately if the keep-alive storm
            // starts before workers finish accepting the initial connection set.
            const settle_s: i64 = if (std.mem.eql(u8, fw, "zinc")) 3 else 1;
            try Io.sleep(io, Io.Duration.fromSeconds(settle_s), .awake);

            var run_i: u32 = 0;
            var sum = zeroResult(fw, scenario.id, platform_id);
            while (run_i < fig.runs) : (run_i += 1) {
                std.log.info("run {d}/{d}: {s} {s}", .{ run_i + 1, fig.runs, fw, scenario.id });
                const one = try runOnce(gpa, io, fw, scenario.path, scenario.method);
                accumulate(&sum, one);
            }
            average(&sum, fig.runs);
            sum.platform = platform_id;
            try results.append(gpa, sum);
            std.log.info("done {s}/{s}: rps={d:.0} p99={d:.2}ms", .{
                fw,
                scenario.id,
                sum.rps,
                sum.latency_p99_s * 1000.0,
            });
            }
        }
    }

    // Per-framework+platform partial while zio is live; final results.zon from --merge.
    try writePartial(gpa, io, init.environ_map, out_path, results.items);
    std.log.info("wrote partial for {s} ({d} runs)", .{
        if (results.items.len > 0) results.items[0].framework else "?",
        results.items.len,
    });
}

/// Same shape as a `results.zon` run entry — used for intermediate sidecars.
const PartialRun = struct {
    framework: []const u8 = "",
    scenario: []const u8 = "",
    platform: []const u8 = "",
    rps: f64 = 0,
    average: f64 = 0,
    fastest: f64 = 0,
    slowest: f64 = 0,
    success_rate: f64 = 0,
    latency_p50: f64 = 0,
    latency_p95: f64 = 0,
    latency_p99: f64 = 0,
    achieved_rate: f64 = 0,
    target_rate: f64 = 0,
    error_rate: f64 = 0,
    requests: u64 = 0,
};

const PartialFile = struct {
    runs: []const PartialRun = &.{},
};

const ScenarioEntry = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
    method: []const u8 = "",
};

const PlatformEntry = struct {
    id: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    label: []const u8 = "",
};

const ConfigEntry = struct {
    runs: u32 = 0,
    connections: u32 = 0,
    threads: u32 = 0,
    duration_s: u32 = 0,
    rate: u64 = 0,
    port: u16 = 0,
};

const PlatformMeta = struct {
    id: []const u8 = "",
    os: []const u8 = "",
    os_version: []const u8 = "",
    arch: []const u8 = "",
    label: []const u8 = "",
    hostname: []const u8 = "",
};

const MetaEntry = struct {
    generated_at: []const u8 = "",
    tool: []const u8 = "",
    mode: []const u8 = "",
    config: ConfigEntry = .{},
    platform: PlatformMeta = .{},
};

const ResultsFile = struct {
    meta: MetaEntry = .{},
    scenarios: []const ScenarioEntry = &.{},
    platforms: []const PlatformEntry = &.{},
    runs: []const PartialRun = &.{},
};

fn partialPath(gpa: std.mem.Allocator, out_path: []const u8, framework: []const u8, platform: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(out_path) orelse ".";
    return try std.fmt.allocPrint(gpa, "{s}/.bench-{s}-{s}.zon", .{ dir, framework, platform });
}

fn toPartialRun(r: ScenarioResult, platform: []const u8) PartialRun {
    return .{
        .framework = r.framework,
        .scenario = r.scenario,
        .platform = platform,
        .rps = r.rps,
        .average = r.average_s,
        .fastest = r.fastest_s,
        .slowest = r.slowest_s,
        .success_rate = r.success_rate,
        .latency_p50 = r.latency_p50_s,
        .latency_p95 = r.latency_p95_s,
        .latency_p99 = r.latency_p99_s,
        .achieved_rate = r.achieved_rate,
        .target_rate = r.target_rate,
        .error_rate = r.error_rate,
        .requests = r.requests,
    };
}

fn writeZon(w: *std.Io.Writer, value: anytype) !void {
    try std.zon.stringify.serialize(value, .{}, w);
    try w.writeByte('\n');
}

fn writePartial(gpa: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, out_path: []const u8, fresh: []const ScenarioResult) !void {
    if (fresh.len == 0) return;
    var platform_owned: ?[]u8 = null;
    defer if (platform_owned) |p| gpa.free(p);
    const platform: []const u8 = if (fresh[0].platform.len > 0) fresh[0].platform else blk: {
        platform_owned = try detectPlatformId(gpa, environ_map);
        break :blk platform_owned.?;
    };

    const path = try partialPath(gpa, out_path, fresh[0].framework, platform);
    defer gpa.free(path);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var runs: std.ArrayList(PartialRun) = .empty;
    defer runs.deinit(gpa);

    // Keep prior scenarios for this framework+platform when a later run covers only a subset.
    if (Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1024 * 1024), .of(u8), 0)) |existing| {
        const parsed = try std.zon.parse.fromSliceAlloc(PartialFile, arena, existing, null, .{ .ignore_unknown_fields = true });
        for (parsed.runs) |r| {
            var replaced = false;
            for (fresh) |f| {
                if (std.mem.eql(u8, f.scenario, r.scenario)) {
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try runs.append(gpa, r);
        }
    } else |_| {}

    for (fresh) |r| {
        try runs.append(gpa, toPartialRun(r, platform));
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeZon(&aw.writer, PartialFile{ .runs = runs.items });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn mergeFromSidecar(gpa: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, out_path: []const u8) !void {
    var results: std.ArrayList(ScenarioResult) = .empty;
    defer {
        for (results.items) |r| {
            gpa.free(r.framework);
            gpa.free(r.scenario);
            if (r.platform.len > 0) gpa.free(r.platform);
        }
        results.deinit(gpa);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    inline for (@typeInfo(@TypeOf(fig.frameworks)).@"struct".fields) |field| {
        const name = @field(fig.frameworks, field.name);
        for (known_platforms) |pl| {
            const path = try partialPath(gpa, out_path, name, pl.id);
            defer gpa.free(path);
            const raw = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1024 * 1024), .of(u8), 0) catch continue;
            const parsed = try std.zon.parse.fromSliceAlloc(PartialFile, arena, raw, null, .{ .ignore_unknown_fields = true });
            for (parsed.runs) |r| {
                try results.append(gpa, .{
                    .framework = try gpa.dupe(u8, r.framework),
                    .scenario = try gpa.dupe(u8, r.scenario),
                    .platform = try gpa.dupe(u8, if (r.platform.len > 0) r.platform else pl.id),
                    .rps = r.rps,
                    .average_s = r.average,
                    .fastest_s = r.fastest,
                    .slowest_s = r.slowest,
                    .success_rate = r.success_rate,
                    .latency_p50_s = r.latency_p50,
                    .latency_p95_s = r.latency_p95,
                    .latency_p99_s = r.latency_p99,
                    .achieved_rate = r.achieved_rate,
                    .target_rate = r.target_rate,
                    .error_rate = r.error_rate,
                    .requests = r.requests,
                });
            }
        }
    }

    if (results.items.len == 0) return error.EmptySidecar;
    try writeResultsZon(gpa, io, environ_map, out_path, results.items);
    std.log.info("merged {d} runs → {s}", .{ results.items.len, out_path });
}

fn listFrameworks(gpa: std.mem.Allocator) ![]const []const u8 {
    const n = @typeInfo(@TypeOf(fig.frameworks)).@"struct".fields.len;
    const out = try gpa.alloc([]const u8, n);
    inline for (@typeInfo(@TypeOf(fig.frameworks)).@"struct".fields, 0..) |field, i| {
        out[i] = @field(fig.frameworks, field.name);
    }
    return out;
}

fn splitCsv(gpa: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, trimmed));
    }
    return try list.toOwnedSlice(gpa);
}


fn zeroResult(fw: []const u8, scenario: []const u8, platform: []const u8) ScenarioResult {
    return .{
        .framework = fw,
        .scenario = scenario,
        .platform = platform,
        .rps = 0,
        .average_s = 0,
        .fastest_s = 0,
        .slowest_s = 0,
        .success_rate = 0,
        .latency_p50_s = 0,
        .latency_p95_s = 0,
        .latency_p99_s = 0,
        .achieved_rate = 0,
        .target_rate = @floatFromInt(fig.rate),
        .error_rate = 0,
        .requests = 0,
    };
}

fn accumulate(dst: *ScenarioResult, src: ScenarioResult) void {
    dst.rps += src.rps;
    dst.average_s += src.average_s;
    dst.fastest_s += src.fastest_s;
    dst.slowest_s += src.slowest_s;
    dst.success_rate += src.success_rate;
    dst.latency_p50_s += src.latency_p50_s;
    dst.latency_p95_s += src.latency_p95_s;
    dst.latency_p99_s += src.latency_p99_s;
    dst.achieved_rate += src.achieved_rate;
    dst.target_rate = src.target_rate;
    dst.error_rate += src.error_rate;
    dst.requests += src.requests;
}

fn average(dst: *ScenarioResult, runs: u32) void {
    const n: f64 = @floatFromInt(runs);
    dst.rps /= n;
    dst.average_s /= n;
    dst.fastest_s /= n;
    dst.slowest_s /= n;
    dst.success_rate /= n;
    dst.latency_p50_s /= n;
    dst.latency_p95_s /= n;
    dst.latency_p99_s /= n;
    dst.achieved_rate /= n;
    dst.error_rate /= n;
    dst.requests = dst.requests / runs;
}

fn waitHealthy(io: Io, host: []const u8, port: u16, path: []const u8) !void {
    var attempt: u32 = 0;
    while (attempt < 90) : (attempt += 1) {
        if (probe(io, host, port, path)) {
            std.log.info("healthy http://{s}:{d}{s}", .{ host, port, path });
            return;
        }
        try Io.sleep(io, Io.Duration.fromSeconds(1), .awake);
    }
    return error.FrameworkNotHealthy;
}

fn probe(io: Io, host: []const u8, port: u16, path: []const u8) bool {
    const address = zrk.runner.resolveAddress(io, host, port) catch return false;
    const stream = address.connect(io, .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = Io.Duration.fromSeconds(1), .clock = .awake } },
    }) catch return false;
    defer stream.close(io);

    var req_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: bench\r\nConnection: close\r\n\r\n", .{path}) catch return false;

    var wbuf: [256]u8 = undefined;
    var rbuf: [128]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    var r = stream.reader(io, &rbuf);

    w.interface.writeAll(request) catch return false;
    w.interface.flush() catch return false;

    // Cap wait so a wedged server (accepts TCP, never responds) cannot hang the suite.
    // Seen with zinc after plaintext: workers stuck in io_cqring_wait.
    var pfd = [_]std.posix.pollfd{.{
        .fd = stream.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&pfd, 2000) catch return false;
    if (ready == 0) return false;
    if (pfd[0].revents & std.posix.POLL.IN == 0) return false;

    const line = r.interface.takeDelimiterInclusive('\n') catch return false;
    return line.len >= 12 and std.mem.startsWith(u8, line, "HTTP/1.") and std.mem.indexOf(u8, line, " 200") != null;
}

fn runOnce(gpa: std.mem.Allocator, io: Io, host: []const u8, path: []const u8, method: []const u8) !ScenarioResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url_str = try std.fmt.allocPrint(arena, "http://{s}:{d}{s}", .{ host, fig.port, path });
    // Zinc's aio/io_uring keep-alive path cannot absorb a 50k open-loop offer:
    // on linux-x86_64 CI it settles at ~50% success (completed ≈ half of offered);
    // on linux-aarch64 CI plaintext wedges to 0 completed. Cap rate + connections
    // so workers stay responsive; other frameworks keep the full fig ceiling.
    const is_zinc = std.mem.eql(u8, host, "zinc");
    const rate: u64 = if (is_zinc) @min(fig.rate, 5_000) else fig.rate;
    const connections: u32 = if (is_zinc) @min(fig.connections, 16) else fig.connections;

    var cfg: zrk.cli.Config = .{
        .threads = fig.threads,
        .connections = connections,
        .duration_ns = fig.duration_s * std.time.ns_per_s,
        .rate = rate,
        .timeout_ns = fig.timeout_s * std.time.ns_per_s,
        .interval_ns = 1 * std.time.ns_per_s,
        .method = method,
        .url = try zrk.cli.parseUrl(url_str),
    };

    const report = try zrk.runner.run(arena, io, &cfg, 0, null, null);
    const snap = report.snapshot;
    const elapsed = report.elapsed_s;
    const completed = snap.counters.completed;
    const failures = snap.counters.socketErrors() + snap.counters.deadline_errors + snap.counters.status_errors;
    const attempts = completed + failures;
    const success_rate: f64 = if (attempts == 0) 0 else @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(attempts));
    const rps: f64 = if (elapsed <= 0) 0 else @as(f64, @floatFromInt(completed)) / elapsed;

    // Histogram values are microseconds.
    const p50_us = snap.hist.valueAtPercentile(50);
    const p95_us = snap.hist.valueAtPercentile(95);
    const p99_us = snap.hist.valueAtPercentile(99);
    const mean_us = snap.hist.mean();
    const min_us = snap.hist.min();
    const max_us = snap.hist.max();

    return .{
        .framework = host,
        .scenario = "",
        .rps = rps,
        .average_s = mean_us / 1_000_000.0,
        .fastest_s = @as(f64, @floatFromInt(min_us)) / 1_000_000.0,
        .slowest_s = @as(f64, @floatFromInt(max_us)) / 1_000_000.0,
        .success_rate = success_rate,
        .latency_p50_s = @as(f64, @floatFromInt(p50_us)) / 1_000_000.0,
        .latency_p95_s = @as(f64, @floatFromInt(p95_us)) / 1_000_000.0,
        .latency_p99_s = @as(f64, @floatFromInt(p99_us)) / 1_000_000.0,
        .achieved_rate = rps,
        .target_rate = @floatFromInt(rate),
        .error_rate = zrk.report.errorRate(snap.counters),
        .requests = completed,
    };
}

fn writeResultsZon(gpa: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, out_path: []const u8, results: []const ScenarioResult) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const host_platform = try detectPlatformId(gpa, environ_map);
    defer gpa.free(host_platform);

    // Prefer the first run's platform for meta; fall back to host.
    const meta_platform = if (results.len > 0 and results[0].platform.len > 0)
        results[0].platform
    else
        host_platform;
    const meta_info = platformInfo(meta_platform);
    const uname = std.posix.uname();
    const now = Io.Timestamp.now(io, .real).toSeconds();

    var scenarios: std.ArrayList(ScenarioEntry) = .empty;
    inline for (@typeInfo(@TypeOf(fig.scenarios)).@"struct".fields) |field| {
        const s = @field(fig.scenarios, field.name);
        try scenarios.append(arena, .{
            .id = s.id,
            .label = s.label,
            .description = s.description,
            .path = s.path,
            .method = s.method,
        });
    }
    try scenarios.append(arena, .{
        .id = "file_upload",
        .label = "File Upload",
        .description = "Multipart upload throughput (coming soon)",
        .path = "/upload",
        .method = "POST",
    });

    // Platforms that have at least one run, then placeholders for the rest.
    var seen: [known_platforms.len]bool = @splat(false);
    for (results) |r| {
        const id = if (r.platform.len > 0) r.platform else host_platform;
        for (known_platforms, 0..) |pl, i| {
            if (std.mem.eql(u8, pl.id, id)) seen[i] = true;
        }
    }

    var platforms: std.ArrayList(PlatformEntry) = .empty;
    for (known_platforms, 0..) |pl, i| {
        if (!seen[i]) continue;
        try platforms.append(arena, .{ .id = pl.id, .os = pl.os, .arch = pl.arch, .label = pl.label });
    }
    for (known_platforms, 0..) |pl, i| {
        if (seen[i]) continue;
        try platforms.append(arena, .{ .id = pl.id, .os = pl.os, .arch = pl.arch, .label = pl.label });
    }

    var runs: std.ArrayList(PartialRun) = .empty;
    for (results) |r| {
        const run_platform = if (r.platform.len > 0) r.platform else host_platform;
        try runs.append(arena, toPartialRun(r, run_platform));
    }

    const results_file: ResultsFile = .{
        .meta = .{
            .generated_at = try std.fmt.allocPrint(arena, "{d}", .{now}),
            .tool = "zrk",
            .mode = "docker",
            .config = .{
                .runs = fig.runs,
                .connections = fig.connections,
                .threads = fig.threads,
                .duration_s = fig.duration_s,
                .rate = fig.rate,
                .port = fig.port,
            },
            .platform = .{
                .id = meta_info.id,
                .os = meta_info.os,
                .os_version = try arena.dupe(u8, trimCstr(&uname.release)),
                .arch = meta_info.arch,
                .label = meta_info.label,
                .hostname = "bench",
            },
        },
        .scenarios = scenarios.items,
        .platforms = platforms.items,
        .runs = runs.items,
    };

    const file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw: Io.File.Writer = .init(file, io, &buf);
    const w = &fw.interface;
    try w.writeAll("// Auto-generated by bench/bencher — do not edit by hand\n");
    try writeZon(w, results_file);
    try w.flush();
}

fn platformInfo(id: []const u8) @TypeOf(known_platforms[0]) {
    for (known_platforms) |pl| {
        if (std.mem.eql(u8, pl.id, id)) return pl;
    }
    return .{ .id = id, .os = "linux", .arch = "x86_64", .label = id };
}

fn detectPlatformId(gpa: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]u8 {
    // Optional override for CI matrix labeling.
    if (environ_map.get("BENCH_PLATFORM")) |override| {
        if (override.len > 0) return try gpa.dupe(u8, override);
    }
    const uname = std.posix.uname();
    const os_raw = try asciiLower(gpa, trimCstr(&uname.sysname));
    defer gpa.free(os_raw);
    const arch_raw = try asciiLower(gpa, trimCstr(&uname.machine));
    defer gpa.free(arch_raw);

    const os = if (std.mem.eql(u8, os_raw, "darwin")) "macos" else os_raw;
    const arch = if (std.mem.eql(u8, arch_raw, "arm64"))
        "aarch64"
    else if (std.mem.eql(u8, arch_raw, "amd64"))
        "x86_64"
    else
        arch_raw;

    return try std.fmt.allocPrint(gpa, "{s}-{s}", .{ os, arch });
}

fn trimCstr(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

fn asciiLower(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, s);
    for (out) |*c| {
        if (c.* >= 'A' and c.* <= 'Z') c.* = c.* + ('a' - 'A');
    }
    return out;
}

