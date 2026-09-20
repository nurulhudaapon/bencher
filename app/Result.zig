const Result = @This();

const std = @import("std");

meta: Meta = .{},
scenarios: []const Scenario = &.{},
platforms: []const Platform = &.{},
runs: []const Run = &.{},

pub const Config = struct {
    runs: u32 = 0,
    connections: u32 = 0,
    threads: u32 = 0,
    duration_s: u32 = 0,
    rate: u64 = 0,
    port: u16 = 0,
};

pub const PlatformInfo = struct {
    id: []const u8 = "",
    os: []const u8 = "",
    os_version: []const u8 = "",
    arch: []const u8 = "",
    label: []const u8 = "",
    hostname: []const u8 = "",
};

pub const Meta = struct {
    generated_at: []const u8 = "",
    tool: []const u8 = "",
    mode: []const u8 = "",
    config: Config = .{},
    platform: PlatformInfo = .{},
};

pub const Scenario = struct {
    id: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    path: []const u8 = "",
    method: []const u8 = "",
};

pub const Platform = struct {
    id: []const u8 = "",
    os: []const u8 = "",
    arch: []const u8 = "",
    label: []const u8 = "",
};

pub const Run = struct {
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

/// Candidate locations of the bencher output, relative to the process cwd.
const search_paths = [_][]const u8{ "app/results.zon", "results.zon" };

/// Reads the raw ZON source of the bench results. Caller owns the memory.
pub fn readResultsFile(allocator: std.mem.Allocator, io: std.Io) ![:0]u8 {
    for (search_paths) |path| {
        return std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, .unlimited, .of(u8), 0) catch continue;
    }
    return error.ResultsFileNotFound;
}

pub fn parseResults(allocator: std.mem.Allocator, source: [:0]const u8) !Result {
    return std.zon.parse.fromSliceAlloc(Result, allocator, source, null, .{ .ignore_unknown_fields = true });
}
