const std = @import("std");

const DateTime = struct {
    years: u16,
    months: u4,
    day: u5,
    hours: u5,
    minutes: u6,
    seconds: u6,

    pub fn init(timestamp: i64) DateTime {
        // Year, month, day
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const years = year_day.year;
        const months = year_day.calculateMonthDay().month.numeric();
        const day = @as(u5, year_day.calculateMonthDay().day_index + 1);

        // Hours, minutes, seconds, ms
        const day_seconds = epoch_seconds.getDaySeconds();
        const hours = day_seconds.getHoursIntoDay();
        const minutes = day_seconds.getMinutesIntoHour();
        const seconds = day_seconds.getSecondsIntoMinute();

        return DateTime{
            .years = years,
            .months = months,
            .day = day,
            .hours = hours,
            .minutes = minutes,
            .seconds = seconds,
        };
    }
};

pub const LogLevel = enum(u8) {
    debug,
    info,
    warn,
    err,

    pub fn toString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

const CoreLogger = struct {
    level: LogLevel,
    file: ?std.fs.File,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, level: LogLevel, file_path: ?[]const u8) !CoreLogger {
        const file = if (file_path) |path| blk: {
            break :blk std.fs.cwd().createFile(path, .{ .truncate = false }) catch |e| switch (e) {
                error.FileNotFound => {
                    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
                    break :blk try std.fs.cwd().createFile(path, .{ .truncate = false });
                },
                else => return e,
            };
        } else null;

        if (file) |f| try f.seekFromEnd(0);

        return CoreLogger{
            .level = level,
            .file = file,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *CoreLogger) void {
        if (self.file) |file| file.close();
    }

    pub fn log(self: *CoreLogger, level: LogLevel, scope: []const u8, comptime format: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        const dt = DateTime.init(std.time.timestamp());
        const log_line = std.fmt.allocPrint(self.allocator, "{:0>4}-{:0>2}-{:0>2}T{d:0>2}:{d:0>2}:{d:0>2} [{s}]{s}: " ++ format ++ "\n", .{
            dt.years,
            dt.months,
            dt.day,
            dt.hours,
            dt.minutes,
            dt.seconds,
            level.toString(),
            scope,
        } ++ args) catch return;
        defer self.allocator.free(log_line);

        if (self.file) |file| file.writeAll(log_line) catch {};

        const writer = if (level == .err) std.io.getStdErr().writer() else std.io.getStdOut().writer();
        writer.writeAll(log_line) catch {};
    }
};

pub const Logger = struct {
    core: *CoreLogger,
    scope: []const u8,

    pub fn debug(self: Logger, comptime format: []const u8, args: anytype) void {
        self.core.log(.debug, self.scope, format, args);
    }

    pub fn info(self: Logger, comptime format: []const u8, args: anytype) void {
        self.core.log(.info, self.scope, format, args);
    }

    pub fn warn(self: Logger, comptime format: []const u8, args: anytype) void {
        self.core.log(.warn, self.scope, format, args);
    }

    pub fn err(self: Logger, comptime format: []const u8, args: anytype) void {
        self.core.log(.err, self.scope, format, args);
    }

    pub fn errWithTrace(self: Logger, error_value: anyerror, comptime format: []const u8, args: anytype) void {
        self.err(format ++ " Error: {}", args ++ .{error_value});

        // In a debug environment, we want to dump the stack trace to help with debugging
        if (@import("builtin").mode == .Debug) std.debug.dumpCurrentStackTrace(null);
    }
};

var core_instance: ?*CoreLogger = null;
var mutex = std.Thread.Mutex{};

/// Initialize the global logger instance. This should be called once at the start of the program.
pub fn init(allocator: std.mem.Allocator, level: LogLevel, file_path: ?[]const u8) !void {
    mutex.lock();
    defer mutex.unlock();

    const core = try allocator.create(CoreLogger);
    core.* = try CoreLogger.init(allocator, level, file_path);
    core_instance = core;
}

/// Deinitialize the global logger instance. This should be called once at the end of the program.
pub fn deinit(allocator: std.mem.Allocator) void {
    mutex.lock();
    defer mutex.unlock();

    if (core_instance) |core| {
        core.deinit();
        allocator.destroy(core);
        core_instance = null;
    }
}

/// Create a scoped logger instance. This should only be called after `init()` has been called.
pub fn scoped(comptime scope: @Type(.enum_literal)) Logger {
    mutex.lock();
    defer mutex.unlock();

    if (core_instance == null) @panic("Logger not initialized. Call init() first.");

    return Logger{
        .core = core_instance.?,
        .scope = " (" ++ @tagName(scope) ++ ")",
    };
}

/// Create a global logger instance. This should only be called after `init()` has been called.
pub fn global() Logger {
    mutex.lock();
    defer mutex.unlock();

    if (core_instance == null) @panic("Logger not initialized. Call init() first.");

    return Logger{
        .core = core_instance.?,
        .scope = "",
    };
}
