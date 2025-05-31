const std = @import("std");

const globMatch = @import("glob.zig").globMatch;

const ExclusionType = enum {
    file,
    dir,
};

const ExclusionRule = struct {
    pattern: []const u8,
    type: ExclusionType,

    pub fn matches(self: *const ExclusionRule, path: []const u8) bool {
        return globMatch(self.pattern, path);
    }
};

pub const ExclusionRules = struct {
    allocator: std.mem.Allocator,
    exclusion_rules: std.StringHashMap(ExclusionRule),

    pub fn init(allocator: std.mem.Allocator) ExclusionRules {
        return ExclusionRules{
            .allocator = allocator,
            .exclusion_rules = std.StringHashMap(ExclusionRule).init(allocator),
        };
    }

    pub fn deinit(self: *ExclusionRules) void {
        var iter = self.exclusion_rules.iterator();
        while (iter.next()) |rule| {
            self.allocator.free(rule.key_ptr.*);
        }

        self.exclusion_rules.deinit();
    }

    pub fn excludeFile(self: *ExclusionRules, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.exclusion_rules.put(owned_path, ExclusionRule{ .pattern = owned_path, .type = .file });
    }

    pub fn excludeDir(self: *ExclusionRules, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.exclusion_rules.put(owned_path, ExclusionRule{ .pattern = owned_path, .type = .dir });
    }

    pub fn addCommonExclusions(self: *ExclusionRules) !void {
        // System directories
        try self.excludeDir("/proc*");
        try self.excludeDir("/sys*");
        try self.excludeDir("/dev*");
        try self.excludeDir("/tmp*");
        try self.excludeDir("/var/tmp*");

        // Cache directories and their files
        try self.excludeDir("*.cache*");
        try self.excludeDir("*node_modules*");
        try self.excludeDir("*.git*");

        // Temporary files
        try self.excludeFile("*.tmp");
        try self.excludeFile("*.temp");
        try self.excludeFile("*~");

        // Large binary files that change frequently
        try self.excludeFile("*.log");
        try self.excludeFile("*.pid");
        try self.excludeFile("*.lock");
    }

    pub fn shouldExclude(self: *ExclusionRules, path: []const u8, is_dir: bool) bool {
        var iter = self.exclusion_rules.valueIterator();
        while (iter.next()) |rule| {
            const type_match = switch (rule.type) {
                .dir => is_dir,
                .file => !is_dir,
            };

            if (type_match and rule.matches(path)) return true;
        }

        return false;
    }
};

var instance: ?*ExclusionRules = null;
var mutex = std.Thread.Mutex{};

/// Initializes the singleton instance of ExclusionRules. This should only be called once at the start of the program.
pub fn init(allocator: std.mem.Allocator) !void {
    mutex.lock();
    defer mutex.unlock();

    const inst = try allocator.create(ExclusionRules);
    inst.* = ExclusionRules.init(allocator);
    instance = inst;
}

/// Deinitializes the singleton instance of ExclusionRules. This should only be called once at the end of the program.
pub fn deinit(allocator: std.mem.Allocator) void {
    mutex.lock();
    defer mutex.unlock();

    if (instance) |i| {
        i.deinit();
        allocator.destroy(i);
        instance = null;
    }
}

/// Retrieves the singleton instance of ExclusionRules. This should be called after `init()` has been called.
pub fn getInstance() *ExclusionRules {
    mutex.lock();
    defer mutex.unlock();

    if (instance == null) @panic("ExclusionRules instance not initialized. Call init() first.");

    return instance.?;
}
