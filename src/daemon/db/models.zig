const std = @import("std");

pub const BackupStatus = enum {
    scanned,
    not_backed_up,
    needs_backup,
    backing_up,
    backed_up,
    backup_error,

    pub const BaseType = []const u8;
    pub const default = BackupStatus.not_backed_up;

    pub fn fromSql(value: []const u8) BackupStatus {
        return std.meta.stringToEnum(BackupStatus, value) orelse .not_backed_up;
    }

    pub fn toSql(self: BackupStatus) []const u8 {
        return @tagName(self);
    }
};

pub const FileBackupRow = struct {
    id: i64,
    path: []const u8,
    file_hash: [32]u8,
    backup_status: BackupStatus,
};
