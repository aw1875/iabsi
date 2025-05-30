const std = @import("std");

const Config = @import("utils/config.zig");
const Database = @import("db/database.zig");
const Logger = @import("utils/logging.zig");

pub const DaemonArgs = struct {
    config: *Config,
    database: *Database,
};

const Daemon = @This();

allocator: std.mem.Allocator,
config: *Config,
database: *Database,
logger: Logger.Logger,
pool: *std.Thread.Pool,
should_exit: bool = false,

pub fn init(allocator: std.mem.Allocator, args: DaemonArgs) !Daemon {
    var pool = try allocator.create(std.Thread.Pool);
    try pool.init(.{ .allocator = allocator });

    return Daemon{
        .allocator = allocator,
        .config = args.config,
        .database = args.database,
        .logger = Logger.scoped(.daemon),
        .pool = pool,
    };
}

pub fn deinit(self: *Daemon) void {
    self.pool.deinit();
    self.allocator.destroy(self.pool);
}

pub fn run(self: *Daemon) !void {
    while (!self.should_exit) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

pub fn shutdown(self: *Daemon) void {
    self.logger.info("Shutting down iabsid...", .{});
    self.should_exit = true;
}
