pub fn GET(ctx: zx.RouteContext) !void {
    const source = try Result.readResultsFile(ctx.arena, ctx.io);
    const results = try Result.parseResults(ctx.arena, source);

    const writer = if (ctx.response.writer()) |w| w else return error.WriterNotFound;
    try zx.util.zxon.serialize(results, writer, .{});
    ctx.response.setContentType(.@"application/json");
}

const Result = @import("../../Result.zig");

const zx = @import("zx");
