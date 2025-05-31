const std = @import("std");

const ShortHash = @import("../utils/crypto.zig").ShortHash;

pub const ChunkResult = struct {
    hash: [8]u8,
    data: []u8,
    size: usize,
};

pub const GearChunker = struct {
    allocator: std.mem.Allocator,
    gear: [256]u32,
    min_chunk_size: usize,
    max_chunk_size: usize,
    mask: u32,
    work_buffer: []u8,

    pub fn init(allocator: std.mem.Allocator) !GearChunker {
        var prng = std.Random.DefaultPrng.init(42816);
        var gear_table: [256]u32 = undefined;

        for (0..256) |i| {
            gear_table[i] = prng.random().int(u32);
        }

        return .{
            .allocator = allocator,
            .gear = gear_table,
            .mask = (1 << 13) - 1,
            .min_chunk_size = 1024 * 1024,
            .max_chunk_size = 8 * 1024 * 1024,
            .work_buffer = try allocator.alloc(u8, 8 * 1024 * 1024),
        };
    }

    pub fn deinit(self: *GearChunker) void {
        self.allocator.free(self.work_buffer);
    }

    pub fn chunkFile(self: *GearChunker, file_path: []const u8) ![]ChunkResult {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var br = std.io.bufferedReader(file.reader());
        const reader = br.reader();

        var chunks = std.ArrayList(ChunkResult).init(self.allocator);

        while (true) {
            if (try self.findNextChunk(reader)) |chunk| try chunks.append(chunk) else break;
        }

        return chunks.toOwnedSlice();
    }

    fn findNextChunk(self: *GearChunker, reader: anytype) !?ChunkResult {
        var rolling_hash: u32 = 0;
        var buffer_pos: usize = 0;

        var read_buffer: [256 * 1024]u8 = undefined;
        outer: while (buffer_pos < self.max_chunk_size) {
            const bytes_read = try reader.read(&read_buffer);
            if (bytes_read == 0) break;

            for (read_buffer[0..bytes_read]) |byte| {
                if (buffer_pos >= self.max_chunk_size) break :outer;

                self.work_buffer[buffer_pos] = byte;
                buffer_pos += 1;

                rolling_hash = ((rolling_hash << 1) +% self.gear[byte]);

                if (buffer_pos >= self.min_chunk_size) {
                    if ((rolling_hash & self.mask) == 0) break :outer;
                }
            }
        }

        if (buffer_pos == 0) return null;

        const chunk_data = try self.allocator.dupe(u8, self.work_buffer[0..buffer_pos]);

        var hash: ShortHash = undefined;
        std.mem.writeInt(u64, &hash, std.hash.XxHash64.hash(0, chunk_data), .little);

        return .{
            .hash = hash,
            .data = chunk_data,
            .size = buffer_pos,
        };
    }
};

pub fn chunkFile(allocator: std.mem.Allocator, file_path: []const u8) ![]ChunkResult {
    var chunker = try GearChunker.init(allocator);
    defer chunker.deinit();

    return try chunker.chunkFile(file_path);
}
