const std = @import("std");

const globMatch = @import("glob.zig").globMatch;

const ExclusionRule = struct {
    pattern: []const u8,

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

    pub fn addExclusion(self: *ExclusionRules, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.exclusion_rules.put(owned_path, ExclusionRule{ .pattern = owned_path });
    }

    pub fn addCommonExclusions(self: *ExclusionRules) !void {
        // System directories
        try self.addExclusion("/proc/*");
        try self.addExclusion("/sys/*");
        try self.addExclusion("/dev/*");
        try self.addExclusion("/tmp/*");
        try self.addExclusion("/var/tmp/*");

        // Cache directories and their files
        try self.addExclusion("**/.cache/*");
        try self.addExclusion("**/node_modules/*");
        try self.addExclusion("**/.git/*");

        // Temporary files
        try self.addExclusion("*.tmp");
        try self.addExclusion("*.temp");
        try self.addExclusion("*~");

        // Large binary files that change frequently
        try self.addExclusion("*.log");
        try self.addExclusion("*.pid");
        try self.addExclusion("*.lock");
    }

    pub fn shouldExclude(self: *ExclusionRules, path: []const u8) bool {
        var iter = self.exclusion_rules.valueIterator();
        while (iter.next()) |rule| {
            if (rule.matches(path)) return true;
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
