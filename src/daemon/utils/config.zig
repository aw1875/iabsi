const std = @import("std");
const log = std.log.scoped(.config);

const Config = @This();

socket_path: []const u8 = "/tmp/iabsi.sock",
database_path: []const u8 = if (@import("builtin").mode == .Debug) "./iabsid.db" else "/var/lib/iabsi/iabsid.db",
log_file: []const u8 = if (@import("builtin").mode == .Debug) "./iabsid.log" else "/var/log/iabsi.log",
scan_paths: [][]const u8 = &.{},
watch_paths: [][]const u8 = &.{},
scan_interval_seconds: u32 = 24 * 60 * 60, // 24 hours
http_timeout_ms: u32 = 30 * 1000, // 30 seconds
max_retries: u32 = 3,
chunk_size_bytes: u32 = 1024 * 1024, // 1 MB
max_file_size_mb: u32 = 100, // 100 MB

allocator: std.mem.Allocator,
_needs_free: std.StringHashMap(void),

pub fn load(allocator: std.mem.Allocator, config_path: []const u8) !Config {
    const config_content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("Config file not found, using defaults.", .{});
            return Config{
                .allocator = allocator,
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
        .allocator = allocator,
        ._needs_free = std.StringHashMap(void).init(allocator),
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0 or std.mem.startsWith(u8, trimmed_line, "#")) continue; // Skip empty lines and comments

        if (std.mem.indexOf(u8, trimmed_line, "=")) |eq_pos| {
            const key = std.mem.trim(u8, trimmed_line[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed_line[eq_pos + 1 ..], " \t");

            try setConfigField(&config, allocator, key, value);
        }
    }

    return config;
}

fn setConfigField(config: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "allocator") or
            std.mem.eql(u8, field.name, "database_path") or
            std.mem.eql(u8, field.name, "_needs_free")) continue; // We can ignore these fields

        if (std.mem.eql(u8, field.name, key)) {
            try setFieldValue(config, allocator, field, value);
            return;
        }
    }

    log.warn("Unknown configuration key: {s}", .{key});
}

fn setFieldValue(config: *Config, allocator: std.mem.Allocator, comptime field: std.builtin.Type.StructField, value: []const u8) !void {
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
        else => log.warn("Unsupported config field type for: {s}", .{field.name}),
    }
}

pub fn deinit(self: *Config) void {
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "allocator") or
            std.mem.eql(u8, field.name, "database_path") or
            std.mem.eql(u8, field.name, "_needs_free")) continue; // We know we don't need to free these

        const field_value = @field(self, field.name);
        if (self._needs_free.contains(field.name)) {
            switch (@typeInfo(field.type)) {
                .pointer => |ptr| {
                    if (ptr.child == u8) {
                        self.allocator.free(field_value);
                    } else if (ptr.child == []const u8) {
                        for (field_value) |str| {
                            self.allocator.free(str);
                        }

                        self.allocator.free(field_value);
                    }
                },
                .optional => |opt| {
                    if (@typeInfo(opt.child) == .Pointer and field_value != null) {
                        self.allocator.free(field_value.?);
                    }
                },
                else => {},
            }
        }
    }

    self._needs_free.deinit();
}
