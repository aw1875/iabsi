const std = @import("std");
const sqlite = @import("sqlite");

const tables = @embedFile("sql/tables.sql");
const indexes = @embedFile("sql/indexes.sql");
const triggers = @embedFile("sql/triggers.sql");

const BackupDatabase = @This();

db: sqlite.Db,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !BackupDatabase {
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = db_path_z },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });

    // Initialize the database
    try db.exec(tables, .{}, .{});
    try db.exec(indexes, .{}, .{});
    try db.exec(triggers, .{}, .{});

    return .{
        .db = db,
        .allocator = allocator,
    };
}

pub fn deinit(self: *BackupDatabase) void {
    self.db.deinit();
}
