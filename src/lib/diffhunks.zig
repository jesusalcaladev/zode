const std = @import("std");

/// Parse hunk metadata from unified diff text for navigation/review.
///
/// Input is the unified diff format produced by `md.unifiedDiff` / standard
/// unified diffs: `@@ -old_start,old_count +new_start,new_count @@` headers,
/// `@@ ... @@` elisions, and prefixed lines. This module is pure and testable;
/// it does not render or modify diffs.
///
/// Line indices in `Hunk` refer to 0-based indices in the `lines` slice passed
/// to `parse`, so callers can map hunks back to rendered/expanded content.
pub const Hunk = struct {
    /// Index of the `@@ -a,b +c,d @@` header line in the input.
    header_line: usize,
    /// Index of the first content line after the header (inclusive).
    content_start: usize,
    /// Index one past the last content line before next header/elision/end.
    content_end: usize,
    old_start: usize,
    old_count: usize,
    new_start: usize,
    new_count: usize,
};

pub const ParseResult = struct {
    hunks: []const Hunk,

    pub fn count(self: ParseResult) usize {
        return self.hunks.len;
    }

    pub fn at(self: ParseResult, i: usize) ?Hunk {
        if (i >= self.hunks.len) return null;
        return self.hunks[i];
    }

    pub fn next(self: ParseResult, current: ?usize) ?usize {
        if (self.hunks.len == 0) return null;
        const cur = current orelse return 0;
        if (cur + 1 < self.hunks.len) return cur + 1;
        return cur;
    }

    pub fn prev(self: ParseResult, current: ?usize) ?usize {
        if (self.hunks.len == 0) return null;
        const cur = current orelse return self.hunks.len - 1;
        if (cur > 0) return cur - 1;
        return cur;
    }
};

/// Parses hunk headers from unified diff lines.
/// `arena` owns the returned slice.
pub fn parse(arena: std.mem.Allocator, lines: []const []const u8) !ParseResult {
    var out: std.ArrayList(Hunk) = .empty;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const line = lines[i];
        if (!std.mem.startsWith(u8, line, "@@ -")) continue;
        if (parseHeader(line)) |h| {
            const content_start = i + 1;
            var content_end = content_start;
            while (content_end < lines.len) : (content_end += 1) {
                if (std.mem.startsWith(u8, lines[content_end], "@@")) break;
            }
            try out.append(arena, .{
                .header_line = i,
                .content_start = content_start,
                .content_end = content_end,
                .old_start = h.old_start,
                .old_count = h.old_count,
                .new_start = h.new_start,
                .new_count = h.new_count,
            });
        }
    }
    return .{ .hunks = try out.toOwnedSlice(arena) };
}

/// Parses a single header line: `@@ -a,b +c,d @@` or `@@ -a +c @@`-style counts.
/// Returns null for `@@ ... @@` elisions or malformed headers.
pub fn parseHeader(line: []const u8) ?Hunk {
    // Minimal tolerant parser.
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    var r = line[4..];
    const old = parseNum(r) orelse return null;
    const old_start = old.n;
    r = old.rest;
    var old_count: usize = 1;
    if (r.len > 0 and r[0] == ',') {
        const oc = parseNum(r[1..]) orelse return null;
        old_count = oc.n;
        r = oc.rest;
    }
    if (!std.mem.startsWith(u8, r, " +")) return null;
    r = r[2..];
    const new = parseNum(r) orelse return null;
    const new_start = new.n;
    r = new.rest;
    var new_count: usize = 1;
    if (r.len > 0 and r[0] == ',') {
        const nc = parseNum(r[1..]) orelse return null;
        new_count = nc.n;
    }
    return .{
        .header_line = 0,
        .content_start = 0,
        .content_end = 0,
        .old_start = old_start,
        .old_count = old_count,
        .new_start = new_start,
        .new_count = new_count,
    };
}

const Num = struct { n: usize, rest: []const u8 };

fn parseNum(s: []const u8) ?Num {
    if (s.len == 0 or s[0] < '0' or s[0] > '9') return null;
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
    }
    return .{ .n = n, .rest = s[i..] };
}

test "parseHeader: standard unified diff header" {
    const h = parseHeader("@@ -1,3 +1,4 @@").?;
    try std.testing.expectEqual(@as(usize, 1), h.old_start);
    try std.testing.expectEqual(@as(usize, 3), h.old_count);
    try std.testing.expectEqual(@as(usize, 1), h.new_start);
    try std.testing.expectEqual(@as(usize, 4), h.new_count);
}

test "parseHeader: rejects elision marker" {
    try std.testing.expect(parseHeader("@@ ... @@") == null);
}

test "parse: finds hunks and navigation indices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_][]const u8{
        "@@ -1,2 +1,3 @@",
        " ctx",
        "-old",
        "+new",
        "+add",
        "@@ ... @@",
        "@@ -20,2 +21,2 @@",
        " ctx2",
        "-a",
        "+b",
    };
    const r = try parse(arena, &lines);
    try std.testing.expectEqual(@as(usize, 2), r.count());
    const h0 = r.at(0).?;
    try std.testing.expectEqual(@as(usize, 0), h0.header_line);
    try std.testing.expectEqual(@as(usize, 1), h0.content_start);
    try std.testing.expectEqual(@as(usize, 5), h0.content_end);
    try std.testing.expectEqual(@as(usize, 20), r.at(1).?.old_start);
    try std.testing.expectEqual(@as(?usize, 0), r.next(null));
    try std.testing.expectEqual(@as(?usize, 1), r.next(0));
    try std.testing.expectEqual(@as(?usize, 1), r.next(1));
    try std.testing.expectEqual(@as(?usize, 0), r.prev(1));
}
