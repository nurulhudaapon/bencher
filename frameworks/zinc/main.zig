const std = @import("std");
const shared_mod = @import("shared_mod");
const zinc = @import("zinc");

pub fn main() !void {
    var z = try zinc.init(.{
        .addr = "0.0.0.0",
        .port = shared_mod.port,
        .num_threads = shared_mod.thread_count,
        .max_conn = shared_mod.connection_count,
        .read_buffer_len = 8192,
        .header_buffer_len = 1024,
        .body_buffer_len = 4096,
        .stack_size = 1024 * 1024,
        .aio_queue_depth = shared_mod.connection_count,
    });
    defer z.deinit();

    var router = z.getRouter();
    try router.get("/", root);
    try router.get("/httpz", httpz);
    try router.get("/api/users", users);
    try router.get("/api/users/:id", user);

    std.debug.print("Started on port {d}\n", .{shared_mod.port});
    try z.run();
}

fn root(ctx: *zinc.Context) anyerror!void {
    try ctx.text(shared_mod.response.hello_world, .{});
}

fn httpz(ctx: *zinc.Context) anyerror!void {
    try ctx.text("OK", .{});
}

fn users(ctx: *zinc.Context) anyerror!void {
    try ctx.json(shared_mod.response.users, .{});
}

fn user(ctx: *zinc.Context) anyerror!void {
    const id_str = if (ctx.getParam("id")) |p| p.value else "0";
    const id = std.fmt.parseInt(u32, id_str, 10) catch 0;

    if (id == 0 or id > shared_mod.response.users.len) {
        try ctx.json(.{ .message = "Invalid ID" }, .{ .status = .bad_request });
        return;
    }

    try ctx.json(shared_mod.response.users[id - 1], .{});
}
