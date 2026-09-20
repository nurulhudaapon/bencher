const std = @import("std");
const shared_mod = @import("shared_mod");
const zap = @import("zap");

var routes: std.StringHashMap(zap.HttpRequestFn) = undefined;

pub fn main() !void {
    try setupRoutes(std.heap.page_allocator);

    var listener = zap.HttpListener.init(.{
        .port = shared_mod.port,
        .on_request = dispatchRequest,
        .log = false,
    });
    try listener.listen();

    std.debug.print("Started on port {d}\n", .{shared_mod.port});

    zap.start(.{
        .threads = shared_mod.thread_count,
        .workers = shared_mod.worker_count,
    });
}

fn root(req: zap.Request) !void {
    req.setStatus(.ok);
    try req.sendBody(shared_mod.response.hello_world);
}

fn httpz(req: zap.Request) !void {
    req.setStatus(.ok);
    try req.sendBody("OK");
}

fn users(req: zap.Request) !void {
    req.setStatus(.ok);
    var buf: [256]u8 = undefined;
    try req.sendJson(try zap.util.stringifyBuf(&buf, shared_mod.response.users, .{}));
}

fn user(req: zap.Request) !void {
    // TODO: get id from request
    const id = std.fmt.parseInt(u32, "1", 10) catch 0;

    var buf: [256]u8 = undefined;

    if (id == 0 or id > shared_mod.response.users.len) {
        req.setStatus(.bad_request);
        try req.sendJson(try zap.util.stringifyBuf(&buf, .{ .message = "Invalid ID" }, .{}));
        return;
    }

    req.setStatus(.ok);

    try req.sendJson(try zap.util.stringifyBuf(&buf, shared_mod.response.users[id - 1], .{}));
}

fn notfound(req: zap.Request) !void {
    req.setStatus(.not_found);
    try req.sendBody("Not Found");
}

// Route dispatcher
fn dispatchRequest(r: zap.Request) !void {
    const path = r.path orelse {
        try notfound(r);
        return;
    };

    // Handle static routes
    if (routes.get(path)) |handler| {
        try handler(r);
        return;
    }

    // Default: not found
    try notfound(r);
}

fn setupRoutes(allocator: std.mem.Allocator) !void {
    routes = std.StringHashMap(zap.HttpRequestFn).init(allocator);
    try routes.put("/", root);
    try routes.put("/httpz", httpz);
    try routes.put("/api/users", users);
    try routes.put("/api/users/:id", user);
}
