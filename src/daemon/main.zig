const std = @import("std");

const Daemon = @import("daemon.zig");
const Database = @import("db/database.zig");
const HttpClient = @import("http/client.zig");
const ApiClient = @import("http/requests.zig");
const Config = @import("utils/config.zig");
const Exclusions = @import("utils/exclusions.zig");
const Logger = @import("utils/logging.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() != .ok) @panic("Failed to deinitialize allocator");

    // Initialize logger
    try Logger.init(allocator, if (@import("builtin").mode == .Debug) .debug else .info);
    defer Logger.deinit(allocator);

    // Load configuration
    var config = try Config.load(allocator, "./config"); // TODO: This should be in a known path later
    defer config.deinit();

    // Setup Database
    var database = try Database.init(allocator, config.database_path);
    defer database.deinit();

    // Setup HTTP client and API wrapper
    var http_client = try HttpClient.init(allocator, .{ .base_url = config.base_api_url, .timeout_ms = config.http_timeout_ms });
    defer http_client.deinit();
    const api_client = ApiClient.init(&http_client);

    // Setup exclusions
    try Exclusions.init(allocator);
    defer Exclusions.deinit(allocator);
    var exclusions = Exclusions.getInstance();

    // Add exclusions
    try exclusions.addCommonExclusions(); // TODO: Make this configurable
    for (config.excluded_paths) |path| try exclusions.addExclusion(path);
    for (config.excluded_files) |file| try exclusions.addExclusion(file);

    // Setup daemon
    var daemon = try Daemon.init(allocator, .{
        .api_client = &api_client,
        .config = &config,
        .database = &database,
    });
    defer daemon.deinit();

    setupSignalHandlers(&daemon);

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
