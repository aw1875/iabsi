const std = @import("std");

const sqlite = @import("sqlite");

const Types = @import("../types.zig");
const FileInfo = Types.FileInfo;
const Database = @import("database.zig");
const Models = @import("models.zig");
const FileBackupRow = Models.FileBackupRow;
const BackupStatus = Models.BackupStatus;

pub fn upsertFile(db: *sqlite.Db, file_info: FileInfo, scan_time: i64) !i64 {
    const query =
        \\INSERT INTO files (path, size, modified, file_hash, backup_status, last_scan_time)
        \\VALUES (?, ?, ?, ?, 'needs_backup', ?)
        \\ON CONFLICT(path) DO UPDATE SET
        \\  size = excluded.size,
        \\  modified = excluded.modified,
        \\  file_hash = excluded.file_hash,
        \\  backup_status = CASE
        \\    WHEN excluded.file_hash != files.file_hash OR files.file_hash IS NULL
        \\    THEN 'needs_backup'
        \\    ELSE files.backup_status
        \\  END,
        \\  last_scan_time = excluded.last_scan_time
    ;

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{
        .path = file_info.path,
        .size = file_info.size,
        .modified = file_info.modified,
        .file_hash = @as([]const u8, &file_info.file_hash),
        .last_scan_time = scan_time,
    });

    return db.getLastInsertRowID();
}

pub fn getFileByPath(
    db: *sqlite.Db,
    allocator: std.mem.Allocator,
    path: []const u8,
) !?FileBackupRow {
    const query = "SELECT id, path, file_hash, backup_status FROM files WHERE path = ?";

    var stmt = try db.prepare(query);
    defer stmt.deinit();

    const row = try stmt.oneAlloc(FileBackupRow, allocator, .{}, .{path});
    defer if (row) |r| allocator.free(r.path);

    if (row) |r| {
        return .{
            .id = r.id,
            .path = try allocator.dupe(u8, r.path),
            .file_hash = @as([32]u8, r.file_hash[0..32].*),
            .backup_status = r.backup_status,
        };
    }

    return null;
}

pub fn updateBackupStatus(
    db: *sqlite.Db,
    file_path: []const u8,
    status: BackupStatus,
    error_message: ?[]const u8,
) !void {
    const query = "UPDATE files SET backup_status = ?, backup_error = ?, last_backup_time = strftime('%s', 'now') WHERE path = ?";

    var stmt = try db.prepareDynamic(query);
    defer stmt.deinit();

    try stmt.exec(.{}, .{ @tagName(status), error_message, file_path });
}
