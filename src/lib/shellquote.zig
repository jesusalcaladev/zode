const std = @import("std");

/// Wraps `path` in single quotes for safe shell use, escaping embedded single quotes.
pub fn single(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    out.append(gpa, '\'') catch return null;
    for (path) |c| {
        if (c == '\'') out.appendSlice(gpa, "'\\''") catch return null else out.append(gpa, c) catch return null;
    }
    out.append(gpa, '\'') catch return null;
    return out.toOwnedSlice(gpa) catch null;
}

test "shellquote: single quotes escape embedded quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("'plain'", single(a, "plain").?);
    try std.testing.expectEqualStrings("'it'\\''s'", single(a, "it's").?);
    try std.testing.expectEqualStrings("''", single(a, "").?);
}
