const std = @import("std");

fn HttpResponse(comptime T: type) type {
    return union(enum) {
        _json: std.json.Parsed(T),
        _string: []const u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                ._json => |*j| j.deinit(),
                ._string => |s| allocator.free(s),
            }
        }

        pub fn json(self: *const @This()) T {
            return switch (self.*) {
                ._json => |j| j.value,
                ._string => @panic("Cannot access string value from JSON response"),
            };
        }

        pub fn string(self: *const @This()) []const u8 {
            return switch (self.*) {
                ._json => @panic("Cannot access JSON value from string response"),
                ._string => |s| s,
            };
        }
    };
}

const HttpClientArgs = struct {
    base_url: []const u8,
    timeout_ms: u32,
};

const HttpClient = @This();

allocator: std.mem.Allocator,
base_url: []const u8,
timeout_ms: u32,
_client: std.http.Client,

pub fn init(allocator: std.mem.Allocator, args: HttpClientArgs) !HttpClient {
    return .{
        .allocator = allocator,
        .base_url = try allocator.dupe(u8, args.base_url),
        .timeout_ms = args.timeout_ms,
        ._client = std.http.Client{ .allocator = allocator },
    };
}

pub fn deinit(self: *HttpClient) void {
    self.allocator.free(self.base_url);
    self._client.deinit();
}

pub fn get(self: *HttpClient, comptime R: type, path: []const u8, headers: ?std.http.Client.Request.Headers) !?HttpResponse(R) {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.GET, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    if (headers) |h| req.headers = h;

    try req.send();
    try req.finish();
    try req.wait();

    if (req.response.status != .ok) return null;

    return try self.deserialize(R, try req.reader().readAllAlloc(self.allocator, 1024 * 1024));
}

pub fn head(self: *HttpClient, path: []const u8, headers: ?std.http.Client.Request.Headers) !bool {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.HEAD, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    if (headers) |h| req.headers = h;

    try req.send();
    try req.finish();
    try req.wait();

    return req.response.status == .ok;
}

pub fn post(self: *HttpClient, comptime R: type, comptime B: type, path: []const u8, body: B, headers: ?std.http.Client.Request.Headers) !if (R == void) bool else ?HttpResponse(R) {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.POST, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    const body_data = switch (@typeInfo(B)) {
        .pointer => body,
        .@"struct" => try std.json.stringifyAlloc(self.allocator, body, .{}),
        else => @compileError("Unsupported body type for POST request"),
    };
    defer if (@typeInfo(B) == .@"struct") self.allocator.free(body_data);

    if (headers) |h| req.headers = h;
    req.transfer_encoding = .{ .content_length = body_data.len };

    try req.send();
    try req.writeAll(body_data);
    try req.finish();
    try req.wait();

    return switch (R) {
        void => req.response.status == .ok or
            req.response.status == .created or
            req.response.status == .no_content,
        else => if (req.response.status != .ok and req.response.status != .created and req.response.status != .no_content)
            null
        else
            try self.deserialize(R, try req.reader().readAllAlloc(self.allocator, 1024 * 1024)),
    };
}

// NOTE: May not need this method, but put it in for now in case we do
pub fn put(self: *HttpClient, comptime R: type, comptime B: type, path: []const u8, body: B, headers: ?std.http.Client.Request.Headers) !if (R == void) bool else ?HttpResponse(R) {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.PUT, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    const json_body = try std.json.stringifyAlloc(self.allocator, body, .{});
    defer self.allocator.free(json_body);

    if (headers) |h| req.headers = h;
    req.transfer_encoding = .{ .content_length = json_body.len };

    try req.send();
    try req.writeAll(json_body);
    try req.finish();
    try req.wait();

    return switch (R) {
        void => req.response.status == .ok or
            req.response.status == .created or
            req.response.status == .no_content,
        else => if (req.response.status != .ok and req.response.status != .created and req.response.status != .no_content)
            null
        else
            try self.deserialize(R, try req.reader().readAllAlloc(self.allocator, 1024 * 1024)),
    };
}

// NOTE: May not need this method, but put it in for now in case we do
pub fn delete(self: *HttpClient, path: []const u8, headers: ?std.http.Client.Request.Headers) !bool {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.DELETE, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    if (headers) |h| req.headers = h;

    try req.send();
    try req.finish();
    try req.wait();

    return req.response.status == .ok or req.response.status == .no_content;
}

// NOTE: May not need this method, but put it in for now in case we do
pub fn patch(self: *HttpClient, comptime R: type, comptime B: type, path: []const u8, body: B, headers: ?std.http.Client.Request.Headers) !if (R == void) bool else ?HttpResponse(R) {
    const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
    defer self.allocator.free(url);

    var server_header_buffer: [2048]u8 = undefined;
    var req = try self._client.open(.PATCH, try std.Uri.parse(url), .{ .server_header_buffer = &server_header_buffer });
    defer req.deinit();

    const json_body = try std.json.stringifyAlloc(self.allocator, body, .{});
    defer self.allocator.free(json_body);

    if (headers) |h| req.headers = h;
    req.transfer_encoding = .{ .content_length = json_body.len };

    try req.send();
    try req.writeAll(json_body);
    try req.finish();
    try req.wait();

    return switch (R) {
        void => req.response.status == .ok or
            req.response.status == .created or
            req.response.status == .no_content,
        else => if (req.response.status != .ok and req.response.status != .created and req.response.status != .no_content)
            null
        else
            try self.deserialize(R, try req.reader().readAllAlloc(self.allocator, 1024 * 1024)),
    };
}

fn deserialize(self: *HttpClient, comptime T: type, body: []const u8) !HttpResponse(T) {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return HttpResponse(T){ ._string = body };
            } else {
                defer self.allocator.free(body);

                const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{ .allocate = .alloc_always });
                return HttpResponse(T){ ._json = parsed };
            }
        },
        .@"struct" => {
            defer self.allocator.free(body);

            const parsed = try std.json.parseFromSlice(T, self.allocator, body, .{ .allocate = .alloc_always });
            return HttpResponse(T){ ._json = parsed };
        },
        else => @compileError("Unsupported type for deserialization: " ++ @typeName(T)),
    };
}
