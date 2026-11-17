//! Case-insensitive ASCII search — ONE implementation for the six copies that
//! had grown across the tree (Phase 42.4). Pure, no allocator, no Unicode
//! folding: the callers search tool names, paths and model ids, all ASCII.

const std = @import("std");

/// First index of `needle` in `hay`, ignoring ASCII case, or null.
/// An empty needle matches at index 0 (the usual string-search convention).
pub fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return indexOf(haystack, needle) != null;
}

test "textcase: case-insensitive search and the empty needle" {
    try std.testing.expectEqual(@as(usize, 0), indexOf("ZODE_FOO_KEY=x", "zode").?);
    try std.testing.expect(contains("Review Checklist", "review"));
    try std.testing.expect(!contains("Review Checklist", "zig"));
    try std.testing.expect(contains("anything", ""));
    try std.testing.expect(indexOf("ab", "abcd") == null);
}
