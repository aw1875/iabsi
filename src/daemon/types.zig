const std = @import("std");

const BackupStatus = @import("db/models.zig").BackupStatus;

pub const DateTime = struct {
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

pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    modified: i64,
    file_hash: [32]u8,
    chunk_hashes: ?[][8]u8 = null,
    backup_status: BackupStatus = .scanned,

    pub fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};
