const Frameworks = @This();

const std = @import("std");
const Io = std.Io;

frameworks: []const Framework = &.{},

pub const FeatureCell = struct {
    value: []const u8 = "-",
    status: []const u8 = "error",
};

pub const Feature = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "-",
    status: []const u8 = "error",
};

pub const Category = struct {
    category: []const u8 = "",
    description: []const u8 = "",
    features: []const Feature = &.{},
};

/// Per-framework metadata from `frameworks/<id>/build.zig.zon` → `.meta`.
pub const Framework = struct {
    /// Folder / docker / results id (e.g. `dusty-std`).
    name: []const u8 = "",
    /// UI label (e.g. `dusty+std`); defaults to `name`.
    label: []const u8 = "",
    version: []const u8 = "",
    repo_url: []const u8 = "",
    disabled: bool = false,
    privileged: bool = false,
    comparison: []const Category = &.{},
};

const MetaFile = struct {
    label: []const u8 = "",
    version: []const u8 = "",
    repo_url: []const u8 = "",
    disabled: bool = false,
    privileged: bool = false,
    comparison: []const Category = &.{},
};

const PackageFile = struct {
    meta: ?MetaFile = null,
};

/// Loads every `frameworks/*/build.zig.zon` that defines `.meta`.
/// Frameworks without `.meta` are omitted from the catalog / comparison table.
pub fn load(allocator: std.mem.Allocator, io: Io) !Frameworks {
    const root = try findRepoRoot(allocator, io);
    const frameworks_dir = try std.fs.path.join(allocator, &.{ root, "frameworks" });

    var dir = try Io.Dir.cwd().openDir(io, frameworks_dir, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(Framework) = .empty;
    var names: std.ArrayList([]const u8) = .empty;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, "shared")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    for (names.items) |name| {
        const zon_path = try std.fs.path.join(allocator, &.{ frameworks_dir, name, "build.zig.zon" });
        const raw = readFile(allocator, io, zon_path) catch continue;

        const parsed = try std.zon.parse.fromSliceAlloc(PackageFile, allocator, raw, null, .{
            .ignore_unknown_fields = true,
        });
        const meta = parsed.meta orelse continue;

        const privileged_path = try std.fs.path.join(allocator, &.{ frameworks_dir, name, "privileged" });
        const privileged_marker = pathExists(io, privileged_path);
        const label = if (meta.label.len > 0) meta.label else name;

        try list.append(allocator, .{
            .name = name,
            .label = label,
            .version = meta.version,
            .repo_url = meta.repo_url,
            .disabled = meta.disabled,
            .privileged = meta.privileged or privileged_marker,
            .comparison = meta.comparison,
        });
    }

    return .{ .frameworks = try list.toOwnedSlice(allocator) };
}

/// Frameworks that contribute comparison-table columns (have comparison rows).
pub fn comparisonFrameworks(self: Frameworks, allocator: std.mem.Allocator) ![]const Framework {
    var list: std.ArrayList(Framework) = .empty;
    for (self.frameworks) |fw| {
        if (fw.disabled) continue;
        if (fw.comparison.len == 0) continue;
        try list.append(allocator, fw);
    }
    return try list.toOwnedSlice(allocator);
}

fn readFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ![:0]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    _ = try reader.interface.streamRemaining(&aw.writer);
    try aw.writer.writeByte(0);
    const owned = try aw.toOwnedSlice();
    return owned[0 .. owned.len - 1 :0];
}

fn pathExists(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn findRepoRoot(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    var dir = try allocator.dupe(u8, cwd_buf[0..cwd_len]);

    while (true) {
        const marker = try std.fs.path.join(allocator, &.{ dir, "frameworks" });
        if (pathExists(io, marker)) return dir;

        const parent = std.fs.path.dirname(dir) orelse return error.RepoRootNotFound;
        if (std.mem.eql(u8, parent, dir)) return error.RepoRootNotFound;
        dir = try allocator.dupe(u8, parent);
    }
}

/// Looks up a feature cell for `fw` by category + feature name.
pub fn cellFor(fw: Framework, category_name: []const u8, feature_name: []const u8) FeatureCell {
    for (fw.comparison) |cat| {
        if (!std.mem.eql(u8, cat.category, category_name)) continue;
        for (cat.features) |f| {
            if (std.mem.eql(u8, f.name, feature_name)) {
                return .{ .value = f.value, .status = f.status };
            }
        }
    }
    return .{};
}
