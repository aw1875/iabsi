const std = @import("std");

const Logger = @import("../utils/logging.zig");

const ConfigurableOptions = struct {
    scan_paths: [][]const u8,
    watch_paths: [][]const u8,
    excluded_paths: [][]const u8,
    excluded_files: [][]const u8,
    scan_interval_seconds: u32,
    max_retries: u32,
    max_file_size_mb: u32,
    follow_symlinks: bool,
};

const Config = @This();

base_api_url: []const u8 = if (@import("builtin").mode == .Debug) "http://localhost:3000" else "", // TODO: Set a prod url later if needed
socket_path: []const u8 = "/tmp/iabsi.sock",
database_path: []const u8 = if (@import("builtin").mode == .Debug) "./iabsid.db" else "/var/lib/iabsi/iabsid.db",
scan_paths: [][]const u8 = &.{},
watch_paths: [][]const u8 = &.{},
excluded_paths: [][]const u8 = &.{},
excluded_files: [][]const u8 = &.{},
scan_interval_seconds: u32 = 24 * 60 * 60, // 24 hours
http_timeout_ms: u32 = 30 * 1000, // 30 seconds
max_retries: u32 = 3,
chunk_size_bytes: u32 = 1024 * 1024, // 1 MB
max_file_size_mb: u32 = 100, // 100 MB
follow_symlinks: bool = false,

_allocator: std.mem.Allocator,
_needs_free: std.StringHashMap(void),

pub fn load(allocator: std.mem.Allocator, config_path: []const u8) !Config {
    const logger = Logger.scoped(.config);

    const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            logger.info("Config file not found, using defaults.", .{});

            return .{
                ._allocator = allocator,
                ._needs_free = std.StringHashMap(void).init(allocator),
            };
        },
        else => return err,
    };
    defer allocator.free(config_content);

    return try parseConfig(allocator, config_content);
}

fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
    var config = Config{
        ._allocator = allocator,
        ._needs_free = std.StringHashMap(void).init(allocator),
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or std.mem.startsWith(u8, trimmed_line, "#")) continue; // Skip empty lines and comments

        if (std.mem.indexOf(u8, trimmed_line, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed_line[0..eq_pos], " \t");
            const value = if (std.mem.indexOf(u8, trimmed_line[eq_pos + 1 ..], "#")) |comment_pos|
                std.mem.trim(u8, trimmed_line[eq_pos + 1 .. eq_pos + comment_pos], " \t") // Clean up any comments on a line if they exist
            else
                std.mem.trim(u8, trimmed_line[eq_pos + 1 ..], " \t");

            try setConfigField(&config, allocator, key, value);
        }
    }

    return config;
}

fn setConfigField(config: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const logger = Logger.scoped(.config);

    inline for (@typeInfo(ConfigurableOptions).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            try setFieldValue(config, allocator, field, value);
            return;
        }
    }

    logger.warn("Unknown configuration key: {s}", .{key});
}

fn setFieldValue(config: *Config, allocator: std.mem.Allocator, comptime field: std.builtin.Type.StructField, value: []const u8) !void {
    const logger = Logger.scoped(.config);

    const field_ptr = &@field(config, field.name);

    switch (@typeInfo(field.type)) {
        .pointer => |ptr| {
            if (ptr.child == u8) {
                field_ptr.* = try allocator.dupe(u8, value);
                try config._needs_free.put(field.name, {});
            } else if (ptr.child == []const u8) {
                var path_list = std.ArrayList([]const u8).init(allocator);
                defer path_list.deinit();

                var paths = std.mem.splitScalar(u8, value, ',');
                while (paths.next()) |path| {
                    const trimmed_path = std.mem.trim(u8, path, " \t");
                    if (trimmed_path.len == 0) continue;

                    try path_list.append(try allocator.dupe(u8, trimmed_path));
                }

                field_ptr.* = try path_list.toOwnedSlice();
                try config._needs_free.put(field.name, {});
            }
        },
        .optional => |opt| {
            if (@typeInfo(opt.child) == .Pointer) {
                field_ptr.* = if (std.mem.eql(u8, value, "")) null else try allocator.dupe(u8, value);
            }
        },
        .int => field_ptr.* = try std.fmt.parseInt(field.type, value, 10),
        else => logger.warn("Unsupported config field type for: {s}", .{field.name}),
    }
}

pub fn deinit(self: *Config) void {
    inline for (@typeInfo(ConfigurableOptions).@"struct".fields) |field| {
        const field_value = @field(self, field.name);
        if (self._needs_free.contains(field.name)) {
            switch (@typeInfo(field.type)) {
                .pointer => |ptr| {
                    if (ptr.child == u8) {
                        self._allocator.free(field_value);
                    } else if (ptr.child == []const u8) {
                        for (field_value) |str| {
                            self._allocator.free(str);
                        }

                        self._allocator.free(field_value);
                    }
                },
                .optional => |opt| {
                    if (@typeInfo(opt.child) == .Pointer and field_value != null) {
                        self._allocator.free(field_value.?);
                    }
                },
                else => {},
            }
        }
    }

    self._needs_free.deinit();
}
