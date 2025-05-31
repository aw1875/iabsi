const std = @import("std");

pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globMatchHelper(pattern, name, 0, 0);
}

fn globMatchHelper(pattern: []const u8, name: []const u8, px: usize, nx: usize) bool {
    if (px == pattern.len and nx == name.len) return true;
    if (px == pattern.len) return false;
    if (nx == 0 and name.len > 0 and name[0] == '.' and pattern[0] != '.') return false;

    switch (pattern[px]) {
        '?' => {
            if (nx >= name.len) return false;
            return globMatchHelper(pattern, name, px + 1, nx + 1);
        },
        '*' => {
            if (px + 1 < pattern.len and pattern[px + 1] == '*') {
                if (globMatchHelper(pattern, name, px + 2, nx)) return true;

                var i = nx;
                while (i < name.len) : (i += 1) {
                    if (globMatchHelper(pattern, name, px + 2, i + 1)) return true;
                }

                return false;
            } else {
                if (isGreedy(pattern, px)) return globMatchHelper(pattern, name, px + 1, name.len);
                if (globMatchHelper(pattern, name, px + 1, nx)) return true;

                var i = nx;
                while (i < name.len and name[i] != '/') : (i += 1) {
                    if (globMatchHelper(pattern, name, px + 1, i + 1)) return true;
                }

                return false;
            }
        },
        '\\' => {
            if (px + 1 >= pattern.len or nx >= name.len) return false;
            if (pattern[px + 1] != name[nx]) return false;
            return globMatchHelper(pattern, name, px + 2, nx + 1);
        },
        else => {
            if (nx >= name.len or pattern[px] != name[nx]) return false;
            return globMatchHelper(pattern, name, px + 1, nx + 1);
        },
    }
}

fn isGreedy(pattern: []const u8, px: usize) bool {
    if (px + 1 != pattern.len) return false; // Not at end

    var i: usize = 0;
    while (i + 1 < px) : (i += 1) {
        if (pattern[i] == '*' and pattern[i + 1] == '*') return true;
    }

    return false;
}

test "character matching" {
    try std.testing.expect(globMatch("f?le.txt", "file.txt"));
    try std.testing.expect(globMatch("f??e.txt", "file.txt"));
    try std.testing.expect(globMatch("f???.txt", "file.txt"));
    try std.testing.expect(globMatch("?.txt", "a.txt"));
    try std.testing.expect(!globMatch("?.txt", "ab.txt"));
}

test "recursive matching" {
    try std.testing.expect(globMatch("**/*.js", "/lib/utils/helper.js"));
    try std.testing.expect(globMatch("**/test/*.py", "project/test/a.py"));
    try std.testing.expect(globMatch("**", "a/b/c/d/e.txt"));
}

test "escaped characters" {
    try std.testing.expect(globMatch("file\\*.txt", "file*.txt"));
    try std.testing.expect(globMatch("file\\?.txt", "file?.txt"));
}

test "hidden files" {
    try std.testing.expect(globMatch(".*", ".gitignore"));
    try std.testing.expect(!globMatch("*", ".gitignore"));
}

test "directory specific" {
    try std.testing.expect(globMatch("docs/*.md", "docs/readme.md"));
    try std.testing.expect(!globMatch("docs/*.md", "docs/readme.txt"));
    try std.testing.expect(globMatch("docs/*", "docs/readme.md"));
    try std.testing.expect(!globMatch("docs/*", "docs/sub/readme.md"));
}

test "wildcards" {
    try std.testing.expect(globMatch("a/**", "a/b"));
    try std.testing.expect(globMatch("**", "a/b/c"));
    try std.testing.expect(globMatch("**/**", "a/b/c"));
    try std.testing.expect(globMatch("**/**/*", "a/b/c"));
    try std.testing.expect(globMatch("**/b/*", "a/b/c"));
    try std.testing.expect(globMatch("**/b/**", "a/b/c"));
    try std.testing.expect(globMatch("*/b/**", "a/b/c"));
    try std.testing.expect(globMatch("a/**", "a/b/c"));
    try std.testing.expect(globMatch("a/**/*", "a/b/c"));
    try std.testing.expect(globMatch("**", "a/b/c/d"));
    try std.testing.expect(globMatch("**/**", "a/b/c/d"));
    try std.testing.expect(globMatch("**/**/*", "a/b/c/d"));
    try std.testing.expect(globMatch("**/**/d", "a/b/c/d"));
    try std.testing.expect(globMatch("**/b/**", "a/b/c/d"));
    try std.testing.expect(globMatch("**/b/*/*", "a/b/c/d"));
    try std.testing.expect(globMatch("**/d", "a/b/c/d"));
    try std.testing.expect(globMatch("*/b/**", "a/b/c/d"));
    try std.testing.expect(globMatch("a/**", "a/b/c/d"));
    try std.testing.expect(globMatch("a/**/*", "a/b/c/d"));
    try std.testing.expect(globMatch("a/**/**/*", "a/b/c/d"));
    try std.testing.expect(globMatch("**/*.git/*", "/a/b/c/.git/d"));
    try std.testing.expect(globMatch("**/*.git/*", "/a/b/c/.git/d/e"));
    try std.testing.expect(globMatch("**/*c/*", "/a/b/c/d"));
}

test "empty strings and edge cases" {
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(globMatch("*", ""));
    try std.testing.expect(!globMatch("?", ""));
}
