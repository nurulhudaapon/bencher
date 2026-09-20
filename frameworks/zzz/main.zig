const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

const zzz = @import("zzz");
const http = zzz.HTTP;
const shared_mod = @import("shared_mod");

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = shared_mod.port;

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .{ .multi = shared_mod.thread_count },
        .pooling = .static,
        .size_tasks_initial = shared_mod.worker_count,
    });
    defer t.deinit();

    var router: Router = try .init(init.gpa, &.{
        Route.init("/httpz").get({}, httpz).layer(),
        Route.init("/api/users").get({}, users).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    var socket: Socket = try .init(init.io, .{
        .tcp = .{ .host = host, .port = port },
    });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = shared_mod.connection_count,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}

fn httpz(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .body = "OK",
    });
}

fn users(ctx: *const Context, _: void) !Respond {
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, shared_mod.response.users, .{});
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.JSON,
        .body = body,
    });
}
