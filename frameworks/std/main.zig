const std = @import("std");
const shared_mod = @import("shared_mod");
const net = std.Io.net;
const http = std.http;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const address = try net.IpAddress.parse("0.0.0.0", shared_mod.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Started on port {d} ({d} threads)\n", .{ shared_mod.port, shared_mod.thread_count });

    // Fixed worker set (same limit as httpz/zap/zzz via shared_mod.thread_count).
    // Each worker accepts then handles one connection at a time.
    var workers: [shared_mod.thread_count - 1]std.Thread = undefined;
    for (&workers) |*t| {
        t.* = try std.Thread.spawn(.{}, acceptLoop, .{ io, &server });
    }
    acceptLoop(io, &server);
    for (workers) |t| t.join();
}

fn acceptLoop(io: std.Io, server: *net.Server) void {
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        handleConnection(io, stream);
    }
}

fn handleConnection(io: std.Io, stream: net.Stream) void {
    defer {
        var copy = stream;
        copy.close(io);
    }

    var recv_buffer: [4000]u8 = undefined;
    var send_buffer: [4000]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    while (true) {
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => {
                std.debug.print("Error receiving request: {}\n", .{err});
                return;
            },
        };

        const target = req.head.target;
        const path = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;

        if (std.mem.eql(u8, path, "/api/users")) {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            std.json.Stringify.value(shared_mod.response.users, .{}, &w) catch {
                std.debug.print("Error encoding JSON\n", .{});
                return;
            };
            req.respond(w.buffered(), .{
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            }) catch |err| {
                std.debug.print("Error responding: {}\n", .{err});
                return;
            };
        } else {
            req.respond("OK", .{}) catch |err| {
                std.debug.print("Error responding: {}\n", .{err});
                return;
            };
        }

        if (!req.head.keep_alive) break;
    }
}
