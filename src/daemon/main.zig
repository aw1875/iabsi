const std = @import("std");

const Daemon = @import("daemon.zig");
const Database = @import("db/database.zig");
const HttpClient = @import("http/client.zig");
const ApiClient = @import("http/requests.zig");
const Config = @import("utils/config.zig");
const Logger = @import("utils/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() != .ok) @panic("Failed to deinitialize allocator");

    try Logger.init(allocator, if (@import("builtin").mode == .Debug) .debug else .info);
    defer Logger.deinit(allocator);

    var config = try Config.load(allocator, "./config"); // TODO: This should be in a known path later
    defer config.deinit();

    var logger = Logger.scoped(.main);

    var database = try Database.init(allocator, config.database_path);
    defer database.deinit();

    var http_client = try HttpClient.init(allocator, .{
        .base_url = config.base_api_url,
        .timeout_ms = config.http_timeout_ms,
        .max_retries = config.max_retries,
    });
    defer http_client.deinit();

    const api_client = ApiClient.init(&http_client);

    var daemon = try Daemon.init(allocator, .{
        .api_client = &api_client,
        .config = &config,
        .database = &database,
    });
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
