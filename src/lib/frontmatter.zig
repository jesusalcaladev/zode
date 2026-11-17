//! The shared frontmatter SCANNER (Phase 42.3).
//!
//! Skills, output styles and agent definitions each carried the same ~28-line
//! fence/comment/quote scanner; only the set of recognized keys differed. This
//! module owns the scanning. A caller keeps its own key switch and its own Meta
//! type, so adding a key to one feature cannot silently affect another.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const Iterator = struct {
    rest: []const u8,
    /// Set when the closing `---` fence was consumed. An unclosed header must
    /// be refused, not silently treated as an empty one.
    closed: bool = false,

    /// Returns the next `key: value` pair, or null at the closing fence / EOF.
    pub fn next(self: *Iterator) ?Pair {
        while (self.rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const line = self.rest[0..nl];
            // CLAMPED: when the closing `---` is the last line and the file has
            // no trailing newline, `nl` is 0 and `i + nl + 1` walks past the end.
            self.rest = self.rest[@min(nl + 1, self.rest.len)..];
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.eql(u8, t, "---")) {
                self.closed = true;
                return null;
            }
            if (t.len == 0 or t[0] == '#') continue;
            const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
            const key = std.mem.trim(u8, t[0..colon], " \t");
            var val = std.mem.trim(u8, t[colon + 1 ..], " \t");
            if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\'')))
            {
                val = val[1 .. val.len - 1];
            }
            return .{ .key = key, .value = val };
        }
        return null;
    }
};

/// Split a `---`-fenced header from the body. Returns null when there is no
/// fence at the start of a line. The body is trimmed; headers are returned
/// through the iterator, not as a map, so each caller dispatches its own keys.
pub fn split(text: []const u8) ?struct { body: []const u8, closed: bool, iterator: Iterator } {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return null;
    const after = trimmed[3..];
    if (after.len > 0 and after[0] != '\n' and after[0] != '\r') return null;
    var rest = after;
    if (std.mem.startsWith(u8, rest, "\r\n")) {
        rest = rest[2..];
    } else if (rest.len > 0 and rest[0] == '\n') {
        rest = rest[1..];
    }
    // The body begins AFTER the closing fence. Peek ahead to find it.
    var scan = Iterator{ .rest = rest };
    while (scan.next()) |_| {}
    return .{ .body = std.mem.trimStart(u8, scan.rest, " \t\r\n"), .closed = scan.closed, .iterator = .{ .rest = rest, .closed = scan.closed } };
}

test "frontmatter: pairs, quotes, comments and a fence without trailing newline" {
    const text =
        \\---
        \\# a comment
        \\name: "demo"
        \\description: 'a value: with a colon'
        \\---
        \\body text
    ;
    const s = split(text).?;
    var it = s.iterator;
    const a = it.next().?;
    try std.testing.expectEqualStrings("name", a.key);
    try std.testing.expectEqualStrings("demo", a.value);
    const b = it.next().?;
    try std.testing.expectEqualStrings("description", b.key);
    try std.testing.expectEqualStrings("a value: with a colon", b.value);
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqualStrings("body text", s.body);

    const no_newline = "---\nname: x\n---";
    try std.testing.expectEqualStrings("", split(no_newline).?.body);
    try std.testing.expect(split("no fence") == null);
}
