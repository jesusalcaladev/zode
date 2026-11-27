//! Copied-text cleanup for the TUI selection.
//!
//! The painted screen is a grid, so a naive copy picks up trailing padding on
//! every line, CRLF from remote sessions and blank rows that were only there
//! to separate paragraphs. None of that is what the reader meant to copy.
//! The cleanup is deliberately conservative: it never joins lines and never
//! changes a non-whitespace byte.

const std = @import("std");

pub const max_bytes: usize = 1024 * 1024;

/// Normalizes line endings, trims trailing horizontal whitespace on each line,
/// and drops leading/trailing blank lines. Returns an owned buffer; input is
/// never modified. Oversized input is truncated at a line boundary and the
/// caller is told via `truncated`.
pub fn clean(gpa: std.mem.Allocator, text: []const u8) !Result {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len and out.items.len < max_bytes) {
        const end = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        var line = text[i..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = std.mem.trimEnd(u8, line, " \t");
        // Skip leading blank lines.
        if (out.items.len == 0 and line.len == 0) {
            i = @min(end + 1, text.len);
            continue;
        }
        if (out.items.len + line.len + 1 > max_bytes) break;
        try out.appendSlice(gpa, line);
        if (end < text.len) try out.append(gpa, '\n');
        i = @min(end + 1, text.len);
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
        _ = out.pop();
    }
    return .{ .text = try out.toOwnedSlice(gpa), .truncated = i < text.len };
}

pub const Result = struct {
    text: []u8,
    truncated: bool,
};

test "cliptext: normalize CRLF, trim padding and drop outer blank lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try clean(a, "\r\n  first  \r\nsecond\t\r\n\r\n");
    // Leading indentation is data: it is NOT trimmed.
    try std.testing.expectEqualStrings("  first\nsecond", r.text);
    try std.testing.expect(!r.truncated);
}

test "cliptext: internal blank lines are kept, no byte is rewritten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try clean(a, "a\n\n  b  \n");
    try std.testing.expectEqualStrings("a\n\n  b", r.text);
}

test "cliptext: an oversized selection is cut at a line boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two lines, the first just under the cap: the second must not be copied.
    const first = try a.alloc(u8, max_bytes - 4);
    @memset(first, 'x');
    const text = try std.mem.concat(a, u8, &.{ first, "\nsecond" });
    const r = try clean(a, text);
    try std.testing.expect(r.truncated);
    try std.testing.expect(r.text.len <= max_bytes);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "second") == null);
}
