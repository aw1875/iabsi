const std = @import("std");

const Logger = @import("../utils/logging.zig");
const HttpClient = @import("client.zig");

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
