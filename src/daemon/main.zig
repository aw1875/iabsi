const std = @import("std");

const Config = @import("utils/config.zig");
const Daemon = @import("daemon.zig");
const Database = @import("db/database.zig");
const Logger = @import("utils/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() != .ok) @panic("Failed to deinitialize allocator");

    var config = try Config.load(allocator, "./config"); // TODO: This should be in a known path later
    defer config.deinit();

    try Logger.init(allocator, if (@import("builtin").mode == .Debug) .debug else .info, config.log_file);
    defer Logger.deinit(allocator);

    var logger = Logger.scoped(.main);

    var database = try Database.init(allocator, config.database_path);
    defer database.deinit();

    var daemon = try Daemon.init(allocator, .{ .config = &config, .database = &database });
    defer daemon.deinit();

    setupSignalHandlers(&daemon);

    logger.info("Starting iabsid", .{});

    try daemon.run();
}

fn setupSignalHandlers(daemon: *Daemon) void {
    global_daemon = daemon;

    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = sigintCallback },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = sigintCallback },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
}

var global_daemon: ?*Daemon = null;
fn sigintCallback(_: c_int) callconv(.C) void {
    if (global_daemon) |d| d.shutdown();
    std.posix.exit(130);
}
