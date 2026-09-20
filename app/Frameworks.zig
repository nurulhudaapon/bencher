const Frameworks = @This();

const std = @import("std");

frameworks: []const Framework = &.{},
comparison: []const Category = &.{},

pub const Framework = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    repo_url: []const u8 = "",
};

pub const FeatureCell = struct {
    value: []const u8 = "—",
    status: []const u8 = "error",
};

pub const Feature = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    zap: FeatureCell = .{},
    httpz: FeatureCell = .{},
    zzz: FeatureCell = .{},
    zinc: FeatureCell = .{},
    std: FeatureCell = .{},
};

pub const Category = struct {
    category: []const u8 = "",
    description: []const u8 = "",
    features: []const Feature = &.{},
};

const embedded = @embedFile("frameworks.zon");

/// Parses the embedded `frameworks.zon`. Caller owns any allocated memory.
pub fn load(allocator: std.mem.Allocator) !Frameworks {
    return std.zon.parse.fromSliceAlloc(Frameworks, allocator, embedded, null, .{ .ignore_unknown_fields = true });
}

/// Looks up the comparison cell of `feature` belonging to the framework `fw_name`.
pub fn cellFor(feature: Feature, fw_name: []const u8) FeatureCell {
    inline for (@typeInfo(Feature).@"struct".field_names) |name| {
        if (comptime !std.mem.eql(u8, name, "name") and !std.mem.eql(u8, name, "description")) {
            if (std.mem.eql(u8, name, fw_name)) return @field(feature, name);
        }
    }
    return .{};
}
