const std = @import("std");

const sqlite = @import("sqlite");

const DateTime = @import("types.zig").DateTime;
const Database = @import("db/database.zig");
const Queries = @import("db/queries.zig");
const FileScanner = @import("fs/scanner.zig");
const ApiClient = @import("http/requests.zig");
const Types = @import("types.zig");
const FileInfo = Types.FileInfo;
const Config = @import("utils/config.zig");
const FileChunker = @import("fs/chunker.zig");
const Logger = @import("utils/logging.zig");

const BackupJobPriority = enum {
    low,
    normal,
    high,
};

const BackupJob = struct {
    file_info: FileInfo,
    retry_count: u32 = 0,
    priority: BackupJobPriority,
};

const BackupStats = struct {
    files_queued: u64 = 0,
    files_completed: u64 = 0,
    files_failed: u64 = 0,
    bytes_uploaded: u64 = 0,
    chunks_uploaded: u64 = 0,
    chunks_deduplicated: u64 = 0,
};

pub const DaemonArgs = struct {
    api_client: *const ApiClient,
    config: *Config,
    database: *Database,
};

const Daemon = @This();

allocator: std.mem.Allocator,
api_client: *const ApiClient,
config: *Config,
database: *sqlite.Db,
file_scanner: FileScanner,
logger: Logger.Logger,
pool: *std.Thread.Pool,
should_exit: bool = false,

backup_queue: std.ArrayList(BackupJob),
backup_mutex: std.Thread.Mutex = .{},
backup_condition: std.Thread.Condition = .{},
backup_stats: BackupStats = .{},

pub fn init(allocator: std.mem.Allocator, args: DaemonArgs) !Daemon {
    var pool = try allocator.create(std.Thread.Pool);
    try pool.init(.{ .allocator = allocator });

    return .{
        .allocator = allocator,
        .api_client = args.api_client,
        .config = args.config,
        .database = args.database.getDb(),
        .file_scanner = FileScanner.init(allocator, args.config.max_file_size_mb, args.config.follow_symlinks),
        .logger = Logger.scoped(.daemon),
        .pool = pool,
        .backup_queue = std.ArrayList(BackupJob).init(allocator),
    };
}

pub fn deinit(self: *Daemon) void {
    self.pool.deinit();
    self.allocator.destroy(self.pool);

    self.backup_mutex.lock();
    defer self.backup_mutex.unlock();

    for (self.backup_queue.items) |job| {
        self.allocator.free(job.file_info.path);
    }
    self.backup_queue.deinit();
}

pub fn run(self: *Daemon) !void {
    self.logger.info("Starting iabsid", .{});
    const scan_thread = try std.Thread.spawn(.{}, scannerLoop, .{self});
    defer scan_thread.join();

    var backup_threads: [8]std.Thread = undefined; // TODO: Number of threads should be configurable?
    for (&backup_threads) |*thread| thread.* = try std.Thread.spawn(.{}, backupWorkerLoop, .{self});
    defer for (backup_threads) |thread| thread.join();

    const stats_thread = try std.Thread.spawn(.{}, statsReporterLoop, .{self});
    defer stats_thread.join();

    while (!self.should_exit) {
        // TODO: Handle IPC events from client process
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

pub fn shutdown(self: *Daemon) void {
    self.logger.info("Shutting down iabsid", .{});
    self.should_exit = true;

    self.backup_condition.broadcast();
}

fn sleepTilNextScan(self: *Daemon) void {
    const hours_to_sleep = self.config.scan_interval_seconds / 3600;
    const remaining_seconds: u64 = self.config.scan_interval_seconds % 3600;

    for (0..hours_to_sleep) |_| {
        if (self.should_exit) break;
        std.Thread.sleep(std.time.ns_per_hour);
    }

    if (!self.should_exit and remaining_seconds > 0) {
        std.Thread.sleep(remaining_seconds * std.time.ns_per_s);
    }
}

fn scannerLoop(self: *Daemon) void {
    while (!self.should_exit) {
        var wg = std.Thread.WaitGroup{};
        wg.startMany(self.config.scan_paths.len);

        for (self.config.scan_paths) |path| {
            self.pool.spawn(scanWorker, .{ self, path, &wg }) catch |err| {
                self.logger.err("Failed to spawn scan worker for {s}: {}", .{ path, err });
                wg.finish();
                continue;
            };
        }

        const next_scan_dt = DateTime.init(std.time.timestamp() + self.config.scan_interval_seconds);
        const next_scan_time = std.fmt.allocPrint(self.allocator, "{:0>4}-{:0>2}-{:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            next_scan_dt.years,
            next_scan_dt.months,
            next_scan_dt.day,
            next_scan_dt.hours,
            next_scan_dt.minutes,
            next_scan_dt.seconds,
        }) catch |err| {
            self.logger.err("Failed to format next scan time: {}", .{err});
            return;
        };
        defer self.allocator.free(next_scan_time);

        self.pool.waitAndWork(&wg);
        self.logger.info("Scan completed for all paths. Next scan scheduled at {s}", .{next_scan_time});
        self.sleepTilNextScan();
    }
}

fn scanWorker(
    self: *Daemon,
    path: []const u8,
    wg: *std.Thread.WaitGroup,
) void {
    defer wg.finish();

    const results = self.file_scanner.scanDirectory(path) catch |err| {
        self.logger.err("Failed to scan directory {s}: {}", .{ path, err });
        return;
    };
    defer {
        for (results.files) |file| {
            self.allocator.free(file.path);
        }

        self.allocator.free(results.files);
    }

    for (results.files) |file| {
        _ = Queries.upsertFile(self.database, file, std.time.milliTimestamp()) catch |err| {
            self.logger.err("Failed to upsert file {s}: {}", .{ file.path, err });
            continue;
        };

        if (self.needsBackup(file)) {
            self.queueFileForBackup(file, .normal) catch |err| {
                self.logger.err("Failed to queue file for backup {s}: {}", .{ file.path, err });
            };
        }
    }
}

fn needsBackup(self: *Daemon, file: FileInfo) bool {
    const result = Queries.getFileByPath(self.database, self.allocator, file.path) catch return true;
    defer if (result) |r| self.allocator.free(r.path);

    if (result == null) return true;
    return !std.mem.eql(u8, &result.?.file_hash, &file.file_hash) or
        result.?.backup_status == .needs_backup or
        result.?.backup_status == .not_backed_up or
        result.?.backup_status == .backup_error;
}

fn queueFileForBackup(self: *Daemon, file_info: FileInfo, priority: BackupJobPriority) !void {
    self.backup_mutex.lock();
    defer self.backup_mutex.unlock();

    try self.backup_queue.append(BackupJob{
        .file_info = .{
            .path = try self.allocator.dupe(u8, file_info.path),
            .size = file_info.size,
            .modified = file_info.modified,
            .file_hash = file_info.file_hash,
        },
        .priority = priority,
    });

    self.backup_stats.files_queued += 1;
    self.backup_condition.signal();
}

fn backupWorkerLoop(self: *Daemon) void {
    while (!self.should_exit) {
        const job = self.getNextBackupJob() orelse {
            self.backup_mutex.lock();
            defer self.backup_mutex.unlock();

            if (self.should_exit) break;
            self.backup_condition.wait(&self.backup_mutex);
            continue;
        };

        self.processBackupJob(job);
    }
}

fn getNextBackupJob(self: *Daemon) ?BackupJob {
    self.backup_mutex.lock();
    defer self.backup_mutex.unlock();

    if (self.backup_queue.items.len == 0) return null;
    return self.backup_queue.orderedRemove(0);
}

fn processBackupJob(self: *Daemon, job: BackupJob) void {
    defer self.allocator.free(job.file_info.path);

    self.logger.debug("Processing backup for: {s}", .{job.file_info.path});

    self.backupFile(job.file_info) catch |err| {
        self.logger.err("Backup failed for {s}: {}", .{ job.file_info.path, err });

        self.backup_mutex.lock();
        self.backup_stats.files_failed += 1;
        self.backup_mutex.unlock();

        if (job.retry_count < self.config.max_retries) {
            var retry_job = job;
            retry_job.retry_count += 1;
            retry_job.file_info.path = self.allocator.dupe(u8, job.file_info.path) catch return;

            std.Thread.sleep(std.time.ns_per_s * (@as(u64, 1) << @intCast(retry_job.retry_count))); // Handle exponential backoff

            self.backup_mutex.lock();
            defer self.backup_mutex.unlock();

            self.backup_queue.append(retry_job) catch return;
            self.backup_condition.signal();
        }

        _ = Queries.updateBackupStatus(self.database, job.file_info.path, .backup_error, "Backup failed") catch |backup_err| {
            self.logger.err("Failed to update backup status for {s}: {}", .{ job.file_info.path, backup_err });
        };
        return;
    };

    self.backup_mutex.lock();
    self.backup_stats.files_completed += 1;
    self.backup_mutex.unlock();

    _ = Queries.updateBackupStatus(self.database, job.file_info.path, .backed_up, null) catch |err| {
        self.logger.err("Failed to update backup time for {s}: {}", .{ job.file_info.path, err });
    };
}

fn backupFile(self: *Daemon, file_info: FileInfo) !void {
    const chunks = try FileChunker.chunkFile(self.allocator, file_info.path);
    defer self.allocator.free(chunks);

    var chunks_uploaded: u64 = 0;
    var chunks_deduplicated: u64 = 0;
    var bytes_uploaded: u64 = 0;

    for (chunks) |chunk| {
        const chunk_exists = self.api_client.chunkExists(chunk.hash) catch false;
        if (chunk_exists) {
            self.logger.debug("Chunk {s} already exists, skipping upload", .{std.fmt.fmtSliceHexLower(&chunk.hash)});
            chunks_deduplicated += 1;
            continue;
        }

        const chunk_uploaded = try self.api_client.uploadChunk(chunk.hash, chunk.data);
        if (chunk_uploaded) {
            chunks_uploaded += 1;
            bytes_uploaded += chunk.size;
        } else {
            return error.ChunkUploadFailed;
        }
    }

    const file_uploaded = try self.api_client.uploadFile("my_client", file_info, chunks); // TODO: Replace "my_client" with actual client identifier
    if (!file_uploaded) return error.FileUploadFailed;

    self.backup_mutex.lock();
    defer self.backup_mutex.unlock();

    self.backup_stats.chunks_uploaded += chunks_uploaded;
    self.backup_stats.chunks_deduplicated += chunks_deduplicated;
    self.backup_stats.bytes_uploaded += bytes_uploaded;

    self.logger.debug("Backed up {s}: {} chunks uploaded, {} deduplicated, {} bytes", .{ file_info.path, chunks_uploaded, chunks_deduplicated, bytes_uploaded });
}

// NOTE: Will probably remove this in the future, but for now it's useful for debugging
fn statsReporterLoop(self: *Daemon) void {
    while (!self.should_exit) {
        std.Thread.sleep(30 * std.time.ns_per_s);

        if (self.should_exit) break;

        self.backup_mutex.lock();
        const stats = self.backup_stats;
        const queue_length = self.backup_queue.items.len;
        self.backup_mutex.unlock();

        if (stats.files_queued > 0 or queue_length > 0) {
            self.logger.info("Backup stats: {} queued, {} completed, {} failed, {} in queue", .{ stats.files_queued, stats.files_completed, stats.files_failed, queue_length });

            if (stats.chunks_uploaded > 0) {
                const mb_uploaded = stats.bytes_uploaded / (1024 * 1024);
                self.logger.info("Upload stats: {} chunks uploaded, {} deduplicated, {} MB transferred", .{ stats.chunks_uploaded, stats.chunks_deduplicated, mb_uploaded });
            }
        }
    }
}
