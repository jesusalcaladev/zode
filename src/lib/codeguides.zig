//! Pure helpers for the two code-fence affordances: matching brackets share a
//! colour by nesting depth, and indentation gets a subtle vertical guide.
//! No IO, no terminal, no allocation — the painter only reads these values.

const std = @import("std");

/// Byte is one of the three bracket pairs.
pub fn isBracket(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

pub fn isOpen(c: u8) bool {
    return c == '(' or c == '[' or c == '{';
}

pub fn isClose(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

/// Number of unmatched OPEN brackets before `off`. Quoted strings (including
/// escaped quotes) are skipped: a `(` inside `"text("` is not a nesting level.
pub fn bracketDepthAt(text: []const u8, off: usize) usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    const end = @min(off, text.len);
    var i: usize = 0;
    while (i < end) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\' and i + 1 < end) {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            quote = c;
            continue;
        }
        if (isOpen(c)) {
            depth += 1;
        } else if (isClose(c) and depth > 0) {
            depth -= 1;
        }
    }
    return depth;
}

/// Pair level for a bracket byte: closing brackets belong to the level of the
/// opening bracket they match, so `(` and `)` at the same nesting level get the
/// same colour.
pub fn bracketLevelAt(text: []const u8, off: usize) usize {
    if (off >= text.len) return 0;
    const before = bracketDepthAt(text, off);
    return if (isClose(text[off]) and before > 0) before - 1 else before;
}

test "brackets: pairs share a level and nesting increments it" {
    const text = "f(a[0]) { g(b) }";
    const positions = [_]struct { off: usize, level: usize }{
        .{ .off = 1, .level = 0 },  // (
        .{ .off = 3, .level = 1 },  // [
        .{ .off = 5, .level = 1 },  // ]
        .{ .off = 6, .level = 0 },  // )
        .{ .off = 8, .level = 0 },  // {
        .{ .off = 11, .level = 1 }, // (
        .{ .off = 13, .level = 1 }, // )
        .{ .off = 15, .level = 0 }, // }
    };
    for (positions) |p| try std.testing.expectEqual(p.level, bracketLevelAt(text, p.off));
}

test "brackets inside strings do not change the nesting level" {
    const text = "x = \"(\" + f(1)";
    try std.testing.expectEqual(@as(usize, 0), bracketLevelAt(text, 11));
    try std.testing.expectEqual(@as(usize, 0), bracketLevelAt(text, 13));
}
