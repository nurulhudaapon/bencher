//! View-model types and builders for the benchmark page.

const std = @import("std");
const Result = @import("Result.zig");
const Frameworks = @import("Frameworks.zig");

pub const Scenario = Result.Scenario;
pub const Platform = Result.Platform;
pub const Run = Result.Run;
pub const FeatureCell = Frameworks.FeatureCell;

pub const FrameworkMeta = struct {
    /// Folder / results id (e.g. `dusty-std`).
    id: []const u8,
    /// UI label (e.g. `dusty+std`).
    name: []const u8,
    version: []const u8,
    version_label: []const u8,
    language_label: []const u8,
    repo_url: []const u8,
};

pub const Framework = struct {
    name: []const u8,
    version: []const u8,
    version_label: []const u8,
    language_label: []const u8,
    repo_url: []const u8,
    rps: f64,
    rps_label: []const u8,
    height: []const u8,
    average_label: []const u8,
    fastest_label: []const u8,
    slowest_label: []const u8,
    p50_label: []const u8,
    p95_label: []const u8,
    p99_label: []const u8,
    success_label: []const u8,
};

pub const SwitchOption = struct {
    id: []const u8,
    label: []const u8,
};

pub const os_options = [_]SwitchOption{
    .{ .id = "linux", .label = "Linux" },
    .{ .id = "macos", .label = "macOS" },
    .{ .id = "windows", .label = "Windows" },
};

pub const arch_options = [_]SwitchOption{
    .{ .id = "x86_64", .label = "x86" },
    .{ .id = "aarch64", .label = "Arm" },
};

pub const FeatureRow = struct {
    name: []const u8,
    description: []const u8,
    cells: []const FeatureCell,
};

pub const Category = struct {
    name: []const u8,
    description: []const u8,
    features: []const FeatureRow,
};

/// One scenario × platform chart, with its bars already sorted and labelled.
pub const Panel = struct {
    scenario: Scenario,
    platform: Platform,
    active: bool,
    frameworks: []const Framework,
};

/// Preformatted strings for the benchmark environment tooltip.
pub const Labels = struct {
    tool: []const u8,
    mode: []const u8,
    platform: []const u8,
    threads: []const u8,
    connections: []const u8,
    duration: []const u8,
    rate: []const u8,
    runs: []const u8,
    colspan: []const u8,
};

pub fn formatCount(allocator: std.mem.Allocator, n: u64) []const u8 {
    if (n >= 1_000_000) {
        return std.fmt.allocPrint(allocator, "{d},{d:0>3},{d:0>3}", .{ n / 1_000_000, (n / 1000) % 1000, n % 1000 }) catch unreachable;
    }
    if (n >= 1000) {
        return std.fmt.allocPrint(allocator, "{d},{d:0>3}", .{ n / 1000, n % 1000 }) catch unreachable;
    }
    return std.fmt.allocPrint(allocator, "{d}", .{n}) catch unreachable;
}

fn formatRps(allocator: std.mem.Allocator, rps: f64) []const u8 {
    return formatCount(allocator, @intFromFloat(@round(rps)));
}

fn formatMs(allocator: std.mem.Allocator, seconds: f64) []const u8 {
    return std.fmt.allocPrint(allocator, "{d:.2} ms", .{seconds * 1000.0}) catch unreachable;
}

fn formatPct(allocator: std.mem.Allocator, rate: f64) []const u8 {
    return std.fmt.allocPrint(allocator, "{d:.1}%", .{rate * 100.0}) catch unreachable;
}

fn barHeight(allocator: std.mem.Allocator, rps: f64, max: f64) []const u8 {
    if (max <= 0) return "0%";
    return std.fmt.allocPrint(allocator, "{d:.2}%", .{(rps / max) * 100.0}) catch unreachable;
}

fn languageLabel(allocator: std.mem.Allocator, frameworks: []const Frameworks.Framework) []const u8 {
    for (frameworks) |fw| {
        if (std.mem.eql(u8, fw.name, "std")) {
            return std.fmt.allocPrint(allocator, "Zig {s}", .{fw.version}) catch unreachable;
        }
    }
    return "Zig 0.16.0";
}

fn versionLabel(allocator: std.mem.Allocator, version: []const u8) []const u8 {
    if (std.mem.eql(u8, version, "master")) return "master";
    return std.fmt.allocPrint(allocator, "v{s}", .{version}) catch unreachable;
}

pub fn buildFrameworkMetas(allocator: std.mem.Allocator, frameworks: []const Frameworks.Framework) []const FrameworkMeta {
    const lang = languageLabel(allocator, frameworks);
    const metas = allocator.alloc(FrameworkMeta, frameworks.len) catch unreachable;
    for (frameworks, metas) |fw, *meta| {
        const label = if (fw.label.len > 0) fw.label else fw.name;
        meta.* = .{
            .id = fw.name,
            .name = label,
            .version = fw.version,
            .version_label = versionLabel(allocator, fw.version),
            .language_label = lang,
            .repo_url = fw.repo_url,
        };
    }
    return metas;
}

fn metaFor(metas: []const FrameworkMeta, id: []const u8) FrameworkMeta {
    for (metas) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return .{
        .id = id,
        .name = id,
        .version = "0",
        .version_label = "v0",
        .language_label = if (metas.len > 0) metas[0].language_label else "Zig 0.16.0",
        .repo_url = "#",
    };
}

fn buildFrameworks(
    allocator: std.mem.Allocator,
    metas: []const FrameworkMeta,
    runs: []const Run,
    scenario_id: []const u8,
    platform_id: []const u8,
) []const Framework {
    var list: std.ArrayList(Framework) = .empty;
    var max: f64 = 0;

    for (runs) |run| {
        if (!std.mem.eql(u8, run.scenario, scenario_id)) continue;
        if (!std.mem.eql(u8, run.platform, platform_id)) continue;
        const m = metaFor(metas, run.framework);
        list.append(allocator, .{
            .name = m.name,
            .version = m.version,
            .version_label = m.version_label,
            .language_label = m.language_label,
            .repo_url = m.repo_url,
            .rps = run.rps,
            .rps_label = "",
            .height = "",
            .average_label = formatMs(allocator, run.average),
            .fastest_label = formatMs(allocator, run.fastest),
            .slowest_label = formatMs(allocator, run.slowest),
            .p50_label = formatMs(allocator, run.latency_p50),
            .p95_label = formatMs(allocator, run.latency_p95),
            .p99_label = formatMs(allocator, run.latency_p99),
            .success_label = formatPct(allocator, run.success_rate),
        }) catch unreachable;
        if (run.rps > max) max = run.rps;
    }

    const items = list.toOwnedSlice(allocator) catch unreachable;
    std.sort.pdq(Framework, items, {}, struct {
        fn lessThan(_: void, a: Framework, b: Framework) bool {
            return a.rps > b.rps;
        }
    }.lessThan);

    for (items) |*fw| {
        fw.rps_label = formatRps(allocator, fw.rps);
        fw.height = barHeight(allocator, fw.rps, max);
    }
    return items;
}

fn scenarioHasRuns(runs: []const Run, id: []const u8) bool {
    for (runs) |run| {
        if (std.mem.eql(u8, run.scenario, id)) return true;
    }
    return false;
}

fn platformHasRuns(runs: []const Run, id: []const u8) bool {
    for (runs) |run| {
        if (std.mem.eql(u8, run.platform, id)) return true;
    }
    return false;
}

pub fn buildRunnableScenarios(allocator: std.mem.Allocator, scenarios: []const Scenario, runs: []const Run) []const Scenario {
    var list: std.ArrayList(Scenario) = .empty;
    for (scenarios) |sc| {
        if (!scenarioHasRuns(runs, sc.id)) continue;
        list.append(allocator, sc) catch unreachable;
    }
    return list.toOwnedSlice(allocator) catch unreachable;
}

pub fn buildRunnablePlatforms(allocator: std.mem.Allocator, platforms: []const Platform, runs: []const Run) []const Platform {
    var list: std.ArrayList(Platform) = .empty;
    for (platforms) |pl| {
        if (!platformHasRuns(runs, pl.id)) continue;
        list.append(allocator, pl) catch unreachable;
    }
    return list.toOwnedSlice(allocator) catch unreachable;
}

pub fn buildSwitchOptions(
    allocator: std.mem.Allocator,
    catalog: []const SwitchOption,
    platforms: []const Platform,
    comptime field: []const u8,
) []const SwitchOption {
    var list: std.ArrayList(SwitchOption) = .empty;
    for (catalog) |opt| {
        for (platforms) |pl| {
            if (std.mem.eql(u8, @field(pl, field), opt.id)) {
                list.append(allocator, opt) catch unreachable;
                break;
            }
        }
    }
    return list.toOwnedSlice(allocator) catch unreachable;
}

pub fn buildPanels(
    allocator: std.mem.Allocator,
    metas: []const FrameworkMeta,
    runs: []const Run,
    scenarios: []const Scenario,
    platforms: []const Platform,
    active_scenario: []const u8,
    active_platform: []const u8,
) []const Panel {
    var list: std.ArrayList(Panel) = .empty;
    for (scenarios) |sc| {
        for (platforms) |pl| {
            list.append(allocator, .{
                .scenario = sc,
                .platform = pl,
                .active = std.mem.eql(u8, sc.id, active_scenario) and std.mem.eql(u8, pl.id, active_platform),
                .frameworks = buildFrameworks(allocator, metas, runs, sc.id, pl.id),
            }) catch unreachable;
        }
    }
    return list.toOwnedSlice(allocator) catch unreachable;
}

pub fn buildCategories(
    allocator: std.mem.Allocator,
    comparison_frameworks: []const Frameworks.Framework,
) []const Category {
    // Merge category/feature rows across frameworks (first-seen order + descriptions).
    var cat_order: std.ArrayList([]const u8) = .empty;
    var cat_desc: std.StringHashMapUnmanaged([]const u8) = .empty;
    var feat_order: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var feat_desc: std.StringHashMapUnmanaged([]const u8) = .empty;

    for (comparison_frameworks) |fw| {
        for (fw.comparison) |cat| {
            if (!cat_desc.contains(cat.category)) {
                cat_order.append(allocator, cat.category) catch unreachable;
                cat_desc.put(allocator, cat.category, cat.description) catch unreachable;
                feat_order.put(allocator, cat.category, .empty) catch unreachable;
            }
            const feats = feat_order.getPtr(cat.category).?;
            for (cat.features) |f| {
                const key = featureKey(allocator, cat.category, f.name);
                if (!feat_desc.contains(key)) {
                    feats.append(allocator, f.name) catch unreachable;
                    feat_desc.put(allocator, key, f.description) catch unreachable;
                }
            }
        }
    }

    const categories = allocator.alloc(Category, cat_order.items.len) catch unreachable;
    for (cat_order.items, categories) |cat_name, *category| {
        const feat_names = feat_order.get(cat_name).?.items;
        const rows = allocator.alloc(FeatureRow, feat_names.len) catch unreachable;
        for (feat_names, rows) |feat_name, *row| {
            const cells = allocator.alloc(FeatureCell, comparison_frameworks.len) catch unreachable;
            for (comparison_frameworks, cells) |fw, *cell| {
                cell.* = Frameworks.cellFor(fw, cat_name, feat_name);
            }
            const key = featureKey(allocator, cat_name, feat_name);
            row.* = .{
                .name = feat_name,
                .description = feat_desc.get(key) orelse "",
                .cells = cells,
            };
        }
        category.* = .{
            .name = cat_name,
            .description = cat_desc.get(cat_name) orelse "",
            .features = rows,
        };
    }
    return categories;
}

fn featureKey(allocator: std.mem.Allocator, category: []const u8, feature: []const u8) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ category, feature }) catch unreachable;
}

pub fn buildLabels(allocator: std.mem.Allocator, meta: Result.Meta, fw_len: usize) Labels {
    return .{
        .tool = meta.tool,
        .mode = meta.mode,
        .platform = meta.platform.label,
        .threads = std.fmt.allocPrint(allocator, "{d}", .{meta.config.threads}) catch unreachable,
        .connections = std.fmt.allocPrint(allocator, "{d}", .{meta.config.connections}) catch unreachable,
        .duration = std.fmt.allocPrint(allocator, "{d}s", .{meta.config.duration_s}) catch unreachable,
        .rate = formatCount(allocator, meta.config.rate),
        .runs = std.fmt.allocPrint(allocator, "{d}", .{meta.config.runs}) catch unreachable,
        .colspan = std.fmt.allocPrint(allocator, "{d}", .{fw_len + 1}) catch unreachable,
    };
}

pub fn osLabel(id: []const u8) []const u8 {
    for (os_options) |opt| {
        if (std.mem.eql(u8, opt.id, id)) return opt.label;
    }
    return id;
}

pub fn archLabel(id: []const u8) []const u8 {
    for (arch_options) |opt| {
        if (std.mem.eql(u8, opt.id, id)) return opt.label;
    }
    return id;
}
