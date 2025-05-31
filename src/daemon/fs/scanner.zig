const std = @import("std");

const FileInfo = @import("../types.zig").FileInfo;
const Logger = @import("../utils/logging.zig");
const Exclusions = @import("../utils/exclusions.zig");
const Crypto = @import("../utils/crypto.zig");

const ScanStats = struct {
    files_scanned: u64 = 0,
    dirs_scanned: u64 = 0,
    bytes_total: u64 = 0,
    files_excluded: u64 = 0,
    dirs_excluded: u64 = 0,
    scan_duration_ms: i64 = 0,
};

const FileScanner = @This();

allocator: std.mem.Allocator,
logger: Logger.Logger,
max_file_size_mb: u64,
follow_symlinks: bool,

pub fn init(allocator: std.mem.Allocator, max_file_size_mb: u64, follow_symlinks: bool) FileScanner {
    return .{
        .allocator = allocator,
        .logger = Logger.scoped(.scanner),
        .max_file_size_mb = max_file_size_mb * 1024 * 1024, // Convert MB to bytes
        .follow_symlinks = follow_symlinks,
    };
}

pub fn scanDirectory(
    self: *FileScanner,
    dir_path: []const u8,
) !struct { files: []FileInfo, stats: ScanStats } {
    self.logger.info("Starting scan of directory: {s}", .{dir_path});

    var files = std.ArrayList(FileInfo).init(self.allocator);
    var stats = ScanStats{};

    const start_time = std.time.milliTimestamp();

    var root_dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true, .no_follow = !self.follow_symlinks });
    defer root_dir.close();

    var walker = try root_dir.walk(self.allocator);
    defer walker.deinit();

    var exclusions = Exclusions.getInstance();

    while (try walker.next()) |entry| {
        const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ dir_path, entry.path });
        defer self.allocator.free(full_path);

        if (exclusions.shouldExclude(full_path, entry.kind == .directory)) {
            self.logger.debug("Skipping excluded entry: {s} ({s})", .{ full_path, @tagName(entry.kind) });
            switch (entry.kind) {
                .directory => stats.dirs_excluded += 1,
                .file => stats.files_excluded += 1,
                else => {},
            }

            continue;
        }

        switch (entry.kind) {
            .directory => stats.dirs_scanned += 1,
            .file => {
                const stat = std.fs.cwd().statFile(full_path) catch |err| switch (err) {
                    error.AccessDenied => {
                        self.logger.warn("Access denied to file: {s}", .{full_path});
                        continue;
                    },
                    else => return err,
                };

                if (stat.size > self.max_file_size_mb) {
                    self.logger.warn("Skipping large file: {s} (~{d} MB)", .{ full_path, stat.size / (1024 * 1024) });
                    continue;
                }

                stats.files_scanned += 1;
                stats.bytes_total += stat.size;

                const owned_path = try self.allocator.dupe(u8, full_path);
                try files.append(.{
                    .path = owned_path,
                    .size = stat.size,
                    .modified = @intCast(@divFloor(stat.mtime, 1_000_000_000)),
                    .file_hash = try Crypto.hashFile(full_path),
                    .backup_status = .scanned,
                });
            },
            .sym_link => {},
            else => continue,
        }
    }

    stats.scan_duration_ms = std.time.milliTimestamp() - start_time;

    return .{
        .files = try files.toOwnedSlice(),
        .stats = stats,
    };
}
