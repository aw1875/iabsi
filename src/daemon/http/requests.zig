const std = @import("std");

const ChunkResult = @import("../fs/chunker.zig").ChunkResult;
const Types = @import("../types.zig");
const FileInfo = Types.FileInfo;
const Logger = @import("../utils/logging.zig");
const HttpClient = @import("client.zig");

const FileChunk = struct {
    hash: []const u8,
    order: u32,
    offset: u64,

    pub fn init(allocator: std.mem.Allocator, chunk: ChunkResult, index: usize) !FileChunk {
        return .{
            .hash = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&chunk.hash)}),
            .order = @intCast(index),
            .offset = @intCast(chunk.size * index),
        };
    }
};

const FileMetadataBody = struct {
    client_id: []const u8,
    original_path: []const u8,
    size: u64,
    modified_time: i64,
    file_hash: []const u8,
    chunks: []FileChunk,

    pub fn init(allocator: std.mem.Allocator, client_id: []const u8, file_info: FileInfo, chunks: []FileChunk) !FileMetadataBody {
        return .{
            .client_id = client_id,
            .original_path = file_info.path,
            .size = file_info.size,
            .modified_time = file_info.modified,
            .file_hash = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&file_info.file_hash)}),
            .chunks = chunks,
        };
    }
};

const ApiClient = @This();

http_client: *HttpClient,

pub fn init(http_client: *HttpClient) ApiClient {
    return .{ .http_client = http_client };
}

pub fn uploadChunk(self: *const ApiClient, chunk_hash: [8]u8, chunk_data: []const u8) !bool {
    const path = try std.fmt.allocPrint(self.http_client.allocator, "/chunks/{s}", .{std.fmt.fmtSliceHexLower(&chunk_hash)});
    defer self.http_client.allocator.free(path);

    return try self.http_client.post(void, []const u8, path, chunk_data, .{ .content_type = .{ .override = "application/octet-stream" } });
}

pub fn chunkExists(self: *const ApiClient, chunk_hash: [8]u8) !bool {
    const path = try std.fmt.allocPrint(self.http_client.allocator, "/chunks/{s}", .{std.fmt.fmtSliceHexLower(&chunk_hash)});
    defer self.http_client.allocator.free(path);

    return try self.http_client.head(path, null);
}

pub fn uploadFile(self: *const ApiClient, client_id: []const u8, file_info: FileInfo, chunks: []const ChunkResult) !bool {
    var json_chunks = std.ArrayList(FileChunk).init(self.http_client.allocator);
    defer {
        for (json_chunks.items) |*chunk| self.http_client.allocator.free(chunk.hash);
        json_chunks.deinit();
    }

    for (chunks, 0..) |chunk, i| {
        try json_chunks.append(try FileChunk.init(self.http_client.allocator, chunk, i));
    }

    const metadata = try FileMetadataBody.init(self.http_client.allocator, client_id, file_info, json_chunks.items);
    defer self.http_client.allocator.free(metadata.file_hash);

    const response = try self.http_client.post(struct { file_id: i64 }, FileMetadataBody, "/files", metadata, .{ .content_type = .{ .override = "application/json" } });
    return if (response) |r| r.json().file_id != 0 else false;
}
