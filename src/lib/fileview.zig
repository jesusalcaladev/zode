//! Pure geometry and change-marking for the in-TUI file viewer/editor.
//!
//! The TUI owns the keys and the painting; this module owns the answers that
//! must be the same in both: which line an offset is on, what a selection
//! means, which lines differ from the baseline, and what window to show.
//! Keeping it pure makes the review workflow testable without a terminal.

const std = @import("std");
const filerange = @import("filerange.zig");

pub const Mark = enum { same, changed };

pub const Changes = struct {
    /// One entry per line of the CURRENT text.
    marks: []Mark,
    /// Lines that existed in the baseline but have no counterpart any more.
    removed: usize = 0,
    /// Number of current lines marked `changed`.
    added: usize = 0,

    pub fn deinit(self: *Changes, alloc: std.mem.Allocator) void {
        alloc.free(self.marks);
    }
};

pub fn lineStart(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and text[i - 1] != '\n') i -= 1;
    return i;
}

pub fn lineEnd(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i < text.len and text[i] != '\n') i += 1;
    return i;
}

/// 1-based line number of an offset, clamped to the buffer.
pub fn lineOfOffset(text: []const u8, offset: usize) usize {
    const at = @min(offset, text.len);
    var n: usize = 1;
    for (text[0..at]) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

/// Byte offset where a 1-based line starts.
pub fn offsetOfLine(text: []const u8, line: usize) usize {
    if (line <= 1) return 0;
    var n: usize = 1;
    var i: usize = 0;
    while (i < text.len and n < line) : (i += 1) {
        if (text[i] == '\n') n += 1;
    }
    return i;
}

/// Selection between two offsets, always ordered and always 1-based.
pub fn rangeForOffsets(text: []const u8, a: usize, b: usize) filerange.Range {
    const x = lineOfOffset(text, @min(a, b));
    const y = lineOfOffset(text, @max(a, b));
    return .{ .first = x, .last = y };
}

/// Move a line inside the real document, for go-to-line and arrow keys.
pub fn clampLine(text: []const u8, line: usize) usize {
    return @max(1, @min(line, filerange.lineCount(text)));
}

/// Window of lines to paint, keeping the cursor around the middle once the
/// document is taller than the pane. Never returns an empty window.
pub fn windowFor(text: []const u8, cursor_line: usize, rows: usize) filerange.Range {
    const total = filerange.lineCount(text);
    const h = @max(rows, 1);
    if (total <= h) return .{ .first = 1, .last = total };
    const half = h / 2;
    var first: usize = if (cursor_line > half) cursor_line - half else 1;
    first = @min(first, total - h + 1);
    return .{ .first = first, .last = first + h - 1 };
}

fn linesOf(alloc: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (it.peek() == null and raw.len == 0 and text.len > 0 and text[text.len - 1] == '\n') break;
        try list.append(alloc, std.mem.trimEnd(u8, raw, "\r"));
    }
    return list.toOwnedSlice(alloc);
}

/// Marks current lines against the baseline.
///
/// Common prefix and suffix are exact and cheap. For the middle, a line whose
/// exact bytes are no longer present is marked changed. This never claims a
/// pairing it did not prove (no invented hunk numbers): it answers the one
/// question the editor needs — "did this line come from the file I opened?".
pub fn docChanges(alloc: std.mem.Allocator, before: []const u8, after: []const u8) !Changes {
    const old_lines = try linesOf(alloc, before);
    defer alloc.free(old_lines);
    const new_lines = try linesOf(alloc, after);
    defer alloc.free(new_lines);

    var prefix: usize = 0;
    while (prefix < old_lines.len and prefix < new_lines.len and
        std.mem.eql(u8, old_lines[prefix], new_lines[prefix])) : (prefix += 1) {}

    var suffix: usize = 0;
    while (suffix < old_lines.len - prefix and suffix < new_lines.len - prefix and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - suffix], new_lines[new_lines.len - 1 - suffix])) : (suffix += 1) {}

    const marks = try alloc.alloc(Mark, new_lines.len);
    for (marks) |*m| m.* = .same;
    var added: usize = 0;
    for (prefix..new_lines.len - suffix) |i| {
        var found = false;
        for (prefix..old_lines.len - suffix) |j| {
            if (std.mem.eql(u8, old_lines[j], new_lines[i])) {
                found = true;
                break;
            }
        }
        if (!found) {
            marks[i] = .changed;
            added += 1;
        }
    }
    return .{ .marks = marks, .removed = (old_lines.len - prefix - suffix), .added = added };
}

test "offset/line geometry round-trips" {
    const text = "one\nsecond\nthird";
    try std.testing.expectEqual(@as(usize, 2), lineOfOffset(text, 5));
    try std.testing.expectEqual(@as(usize, 4), offsetOfLine(text, 2));
    try std.testing.expectEqualStrings("second", text[lineStart(text, 5)..lineEnd(text, 5)]);
    try std.testing.expectEqual(@as(usize, 11), lineStart(text, text.len));
    try std.testing.expectEqual(@as(usize, 3), clampLine(text, 99));
    try std.testing.expectEqual(@as(usize, 1), clampLine(text, 0));
}

test "rangeForOffsets orders a backwards selection" {
    const text = "one\ntwo\nthree\nfour";
    const r = rangeForOffsets(text, 14, 1);
    try std.testing.expectEqual(@as(usize, 1), r.first);
    try std.testing.expectEqual(@as(usize, 4), r.last);
}

test "windowFor keeps the cursor visible and stops at EOF" {
    const text = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10";
    const w = windowFor(text, 6, 4);
    try std.testing.expectEqual(@as(usize, 4), w.first);
    try std.testing.expectEqual(@as(usize, 7), w.last);
    const tail = windowFor(text, 10, 4);
    try std.testing.expectEqual(@as(usize, 7), tail.first);
    try std.testing.expectEqual(@as(usize, 10), tail.last);
    const small = windowFor("a\nb", 2, 8);
    try std.testing.expectEqual(@as(usize, 1), small.first);
    try std.testing.expectEqual(@as(usize, 2), small.last);
}

test "docChanges: an append marks only the new line" {
    var c = try docChanges(std.testing.allocator, "a\nb\n", "a\nb\nc\n");
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), c.marks.len);
    try std.testing.expectEqual(Mark.same, c.marks[0]);
    try std.testing.expectEqual(Mark.same, c.marks[1]);
    try std.testing.expectEqual(Mark.changed, c.marks[2]);
    try std.testing.expectEqual(@as(usize, 1), c.added);
    try std.testing.expectEqual(@as(usize, 0), c.removed);
}

test "docChanges: an edit in the middle does not repaint the untouched edges" {
    var c = try docChanges(std.testing.allocator, "a\nb\nc\nd\n", "a\nB\nc\nd\n");
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(Mark.same, c.marks[0]);
    try std.testing.expectEqual(Mark.changed, c.marks[1]);
    try std.testing.expectEqual(Mark.same, c.marks[2]);
    try std.testing.expectEqual(Mark.same, c.marks[3]);
    try std.testing.expectEqual(@as(usize, 1), c.removed);
}

test "docChanges: identical documents have no marks" {
    var c = try docChanges(std.testing.allocator, "a\nb", "a\nb");
    defer c.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), c.added);
    try std.testing.expectEqual(@as(usize, 0), c.removed);
}
