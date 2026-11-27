//! 1-based line ranges shared by the file editor, the prompt mentions and the
//! UI. Keeping the normalization in one pure module means the number the user
//! selects on screen is the same number the model sees in the prompt.

const std = @import("std");

pub const Range = struct {
    first: usize,
    last: usize,

    pub fn count(self: Range) usize {
        if (self.last < self.first) return 0;
        return self.last - self.first + 1;
    }

    pub fn contains(self: Range, line: usize) bool {
        return line >= self.first and line <= self.last;
    }
};

/// What a user typed in the go-to-line field: `40` or `40-120`.
pub const Spec = union(enum) {
    line: usize,
    range: Range,

    pub fn asRange(self: Spec) Range {
        return switch (self) {
            .line => |n| .{ .first = n, .last = n },
            .range => |r| r,
        };
    }
};

pub fn parse(text: []const u8) ?Spec {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return null;
    const dash = std.mem.indexOfScalar(u8, s, '-') orelse {
        const n = std.fmt.parseInt(usize, s, 10) catch return null;
        if (n == 0) return null;
        return .{ .line = n };
    };
    if (std.mem.indexOfScalarPos(u8, s, dash + 1, '-') != null) return null;
    const a = std.fmt.parseInt(usize, s[0..dash], 10) catch return null;
    const b = std.fmt.parseInt(usize, s[dash + 1 ..], 10) catch return null;
    if (a == 0 or b == 0) return null;
    return .{ .range = .{ .first = a, .last = b } };
}

/// Clamp to the real file and order the endpoints. Returns null when nothing
/// of the requested range exists (empty file, range past EOF).
pub fn normalize(first: usize, last: usize, line_count: usize) ?Range {
    if (line_count == 0) return null;
    var a = @min(first, last);
    var b = @max(first, last);
    a = @max(a, 1);
    b = @min(b, line_count);
    if (a > b) return null;
    return .{ .first = a, .last = b };
}

/// A trailing newline terminates the last line; it does not start an empty
/// one. An empty buffer still has one (empty) line, as in every editor.
pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 1;
    var n: usize = 1;
    for (text) |c| if (c == '\n') {
        n += 1;
    };
    if (text[text.len - 1] == '\n') n -= 1;
    return @max(n, 1);
}

pub fn lineAt(text: []const u8, line: usize) []const u8 {
    if (line == 0) return "";
    var it = std.mem.splitScalar(u8, text, '\n');
    var i: usize = 1;
    while (it.next()) |part| : (i += 1) {
        if (i == line) return std.mem.trimEnd(u8, part, "\r");
    }
    return "";
}

/// `path:40` or `path:40-120`, into a caller-owned buffer.
pub fn format(buf: []u8, path: []const u8, r: Range) ![]const u8 {
    if (r.first == r.last) return std.fmt.bufPrint(buf, "{s}:{d}", .{ path, r.first });
    return std.fmt.bufPrint(buf, "{s}:{d}-{d}", .{ path, r.first, r.last });
}

test "parse: a line and a range" {
    try std.testing.expectEqual(@as(usize, 40), (parse("40").?).line);
    const r = parse(" 40-120 ").?.range;
    try std.testing.expectEqual(@as(usize, 40), r.first);
    try std.testing.expectEqual(@as(usize, 120), r.last);
}

test "parse: rejects junk, zero and multi-dash input" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("abc") == null);
    try std.testing.expect(parse("0") == null);
    try std.testing.expect(parse("40-") == null);
    try std.testing.expect(parse("-40") == null);
    try std.testing.expect(parse("1-2-3") == null);
}

test "normalize: orders, clamps and refuses an empty result" {
    const r = normalize(120, 40, 100).?;
    try std.testing.expectEqual(@as(usize, 40), r.first);
    try std.testing.expectEqual(@as(usize, 100), r.last);
    try std.testing.expectEqual(@as(usize, 61), r.count());
    try std.testing.expect(normalize(500, 600, 100) == null);
    try std.testing.expect(normalize(1, 1, 0) == null);
}

test "lineCount and lineAt: a trailing newline is not a new line" {
    const text = "one\ntwo\nthree\n";
    try std.testing.expectEqual(@as(usize, 3), lineCount(text));
    try std.testing.expectEqualStrings("one", lineAt(text, 1));
    try std.testing.expectEqualStrings("three", lineAt(text, 3));
    try std.testing.expectEqualStrings("", lineAt(text, 4));
    try std.testing.expectEqual(@as(usize, 1), lineCount(""));
}

test "format: one line and a range" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("src/a.zig:40", try format(&buf, "src/a.zig", .{ .first = 40, .last = 40 }));
    try std.testing.expectEqualStrings("src/a.zig:40-120", try format(&buf, "src/a.zig", .{ .first = 40, .last = 120 }));
}
