const Response = struct {
    const User = struct {
        id: u32,
        name: []const u8,
    };

    hello_world: []const u8,
    users: []const User,
};

pub const response: Response = @import("asset/response.zon");

/// Fixed listen port for every framework container (Docker healthcheck + loadgen).
pub const port = 8081;
pub const thread_count = 2;
pub const worker_count = 4;
pub const connection_count = 4096;
