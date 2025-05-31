const std = @import("std");

// Might not be perfect, but passes many common basic cases. See https://research.swtch.com/glob
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var px: usize = 0;
    var nx: usize = 0;
    var next_px: usize = 0;
    var next_nx: usize = 0;

    while (px < pattern.len or nx < name.len) {
        if (px < pattern.len) {
            switch (pattern[px]) {
                '?' => {
                    if (nx < name.len) {
                        px += 1;
                        nx += 1;
                        continue;
                    }
                },
                '*' => {
                    next_px = px;
                    next_nx = nx + 1;
                    px += 1;
                    continue;
                },
                else => {
                    if (nx < name.len and pattern[px] == name[nx]) {
                        px += 1;
                        nx += 1;
                        continue;
                    }
                },
            }
        }

        if (next_nx != 0 and next_nx <= name.len) {
            px = next_px;
            nx = next_nx;
            continue;
        }

        return false;
    }

    return true;
}

test "glob match test cases" {
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(globMatch("?", "a"));
    try std.testing.expect(!globMatch("?", ""));
    try std.testing.expect(!globMatch("?", "ab"));
    try std.testing.expect(globMatch("abc", "abc"));
    try std.testing.expect(!globMatch("abc", "abcd"));
    try std.testing.expect(!globMatch("abc", "ab"));
    try std.testing.expect(globMatch("a*c", "abc"));
    try std.testing.expect(globMatch("a*c", "abbc"));
    try std.testing.expect(globMatch("a*c", "ac"));
    try std.testing.expect(!globMatch("a*c", "ab"));
    try std.testing.expect(globMatch("a*bc*de", "axyzbcqqqde"));
    try std.testing.expect(globMatch("file?.txt", "file1.txt"));
    try std.testing.expect(!globMatch("file?.txt", "file12.txt"));
    try std.testing.expect(globMatch("*.txt", "file.txt"));
    try std.testing.expect(!globMatch("*.txt", "file.csv"));
    try std.testing.expect(globMatch("test.*", "test.zig"));
    try std.testing.expect(!globMatch("test.*", "test"));
    try std.testing.expect(globMatch("*bar", "foobar"));
    try std.testing.expect(globMatch("*bar", "bar"));
    try std.testing.expect(!globMatch("*bar", "fooba"));
    try std.testing.expect(globMatch("file*", "file"));
    try std.testing.expect(globMatch("file*", "file123"));
    try std.testing.expect(!globMatch("file?", "file"));
    try std.testing.expect(globMatch("file?", "file1"));
    try std.testing.expect(globMatch("*a*b*c*", "aaabbbccc"));
    try std.testing.expect(globMatch("*a*b*c*", "acbac"));
    try std.testing.expect(globMatch("*a*b*c*", "abcabc"));
    try std.testing.expect(!globMatch("*a*b*c*", "acb"));
    try std.testing.expect(globMatch("*?*?*", "ab"));
    try std.testing.expect(!globMatch("*?*?*", "a"));

    // Edge cases
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(!globMatch("", "abc"));
    try std.testing.expect(globMatch("***", "abc"));
    try std.testing.expect(globMatch("?*?", "ab"));
    try std.testing.expect(!globMatch("?*?", "a"));
}
