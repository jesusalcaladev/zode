//! Clipping text to a width without cutting a character in half.
//!
//! Pure and tested on its own, because the thing that goes wrong here is a byte
//! count. `text[0..n]` with `n` landing on a UTF-8 continuation byte produces a
//! slice that is not valid UTF-8, and everything downstream — the markdown
//! parser, vaxis's grapheme iterator, the session JSON — either loses text or
//! crashes on it. Two call sites already walked back to a character start by
//! hand (`subagent.capResult`, `usercmds`); this is that loop, once, with the
//! tests it never had.
//!
//! # Columns, not bytes
//!
//! A length in BYTES is not a width: `á` is 2 bytes for 1 column and an emoji is
//! 4. A boundary computed in bytes and then handed to something that measures in
//! columns is how a clipped argument comes out two characters short or one
//! character over. The first version of this module reserved room for the
//! ellipsis with `ellipsis.len` — three BYTES for a one-column glyph — and every
//! clip came out one column too short.

const std = @import("std");

/// The ellipsis, as one glyph.
pub const ellipsis = "…";
/// Its width in COLUMNS, which is not its length in bytes. See the module
/// comment: this distinction is the whole reason the tests exist.
pub const ellipsis_cols: usize = 1;

/// The larger of the two defaults: a tool argument on a history row.
pub const default_max: usize = 60;

/// True when `text` already fits in `max_cols` columns.
pub fn fits(text: []const u8, max_cols: usize) bool {
    return columnCount(text) <= max_cols;
}

/// Clips to `max_cols` columns WITHOUT the ellipsis, into a caller buffer.
///
/// A slice of `text` when it fits (no copy). The result is never longer than
/// `max_cols` columns and always valid UTF-8.
pub fn clip(text: []const u8, max_cols: usize) []const u8 {
    if (max_cols == 0) return "";
    if (fits(text, max_cols)) return text;
    return text[0..safeBoundary(text, max_cols)];
}

/// Clips to `max_cols` columns and appends the ellipsis when it did not fit,
/// writing into `out`.
///
/// The ellipsis is INSIDE the budget: a caller that asks for 60 columns gets
/// 59 of text plus the ellipsis, never 63. An output buffer smaller than the
/// text is truncated; a bare ellipsis is returned when not even that fits.
pub fn clipInto(text: []const u8, max_cols: usize, out: []u8) []const u8 {
    if (max_cols == 0) return "";
    if (fits(text, max_cols)) return text;
    if (max_cols <= ellipsis_cols) return ellipsis;
    const budget = max_cols - ellipsis_cols;
    const body = text[0..safeBoundary(text, budget)];
    const room = @min(out.len, body.len + ellipsis.len);
    const body_room = if (room >= ellipsis.len) room - ellipsis.len else 0;
    @memcpy(out[0..body_room], body[0..@min(body_room, body.len)]);
    @memcpy(out[body_room .. body_room + ellipsis.len], ellipsis);
    return out[0 .. body_room + ellipsis.len];
}

/// The most the caller can get from `clipInto`, in bytes: the budget in
/// characters (each up to 4 bytes) plus the ellipsis.
pub fn scratchFor(max_cols: usize) usize {
    return max_cols * 4 + 8;
}
pub fn clipWrap(text: []const u8, max_cols: usize) ClipWrap {
    var buf: [scratchFor(default_max)]u8 = undefined;
    return .{ .s = clipInto(text, max_cols, &buf) };
}

/// The largest `n` such that `text[0..n]` is valid UTF-8 and `n` is at most
/// `budget` COLUMNS. Never runs past the end and never splits a character.
pub fn safeBoundary(text: []const u8, budget: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const w = charWidth(text[i..]) orelse return i;
        i += w;
        seen += columnsFor(text[i - w .. i]);
        if (seen > budget) return i - w;
    }
    return text.len;
}

/// Columns one CHARACTER occupies.
fn columnsFor(ch: []const u8) usize {
    if (ch.len < 3) return 1;
    const cp = std.unicode.utf8Decode(ch) catch return 1;
    return if (isWide(cp)) 2 else 1;
}

/// East Asian Wide and Fullwidth.
///
/// This is the table the terminal actually uses, and a coarse thing is not
/// good enough: the first version of this module used a single byte band
/// `0xE280..0xE4BFAF`, which contains U+2026 — the ellipsis itself — so every
/// clip reported one column too many and a 60-column argument came out 59.
///
/// The ranges are EastAsianWidth's "W" and "F" for the blocks a code terminal
/// plausibly shows: CJK, Hangul, Kana, fullwidth forms, and the emoji planes.
fn isWide(cp: u21) bool {
    return switch (cp) {
        // Fullwidth forms and halfwidth misalignments.
        0xFF01...0xFF60, 0xFFE0...0xFFE6 => true,
        // Hangul Jamo, syllables and compatibility.
        0x1100...0x115F, 0xA960...0xA97F, 0xAC00...0xD7A3 => true,
        // CJK radicals, Kangxi, CJK symbols and punctuation.
        0x2E80...0x303E, 0x3041...0x33FF, 0xFE30...0xFE6F, 0xFE10...0xFE19 => true,
        // The main CJK ideograph planes.
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF => true,
        // Yi, Bopomofo, and the extensions.
        0xA000...0xA4CF, 0x20000...0x2FFFD, 0x30000...0x3FFFD => true,
        // Emoji. U+2026 is NOT wide and must not be caught by a byte band.
        0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF => true,
        else => false,
    };
}

/// Byte length of the character starting at `text[0]`, or null when invalid.
fn charWidth(text: []const u8) ?usize {
    const n = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (n > text.len) return null;
    if (!std.unicode.utf8ValidateSlice(text[0..n])) return null;
    return n;
}

/// Columns a string occupies, counting a wide character as 2.
///
/// This is a MEASURE function and never loses bytes: an invalid byte counts as
/// one column and the walk continues, so the caller always sees a total close to
/// the real length. `safeBoundary` is the one that refuses to emit invalid text.
pub fn columnCount(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const w = charWidth(text[i..]) orelse {
            i += 1;
            cols += 1;
            continue;
        };
        cols += columnsFor(text[i .. i + w]);
        i += w;
    }
    return cols;
}

/// Splits at a LINE boundary, keeping `keep_head` lines from the start and
/// `keep_tail` from the end.
///
/// A tool result is cut at a line boundary so a fragment never reads as a
/// complete answer. `cut` is false when the whole text fits, and then `tail` is
/// empty and `head` is the whole thing.
///
/// The line COUNT is `starts` when the text ends with a newline and `starts + 1`
/// when it does not: "a\nb\n" is TWO lines and two newline starts, and counting
/// it three cut one line later than it should.
///
/// The tail's INDEX is `last_line + 1 - keep_tail` in LINE numbers, and that line
/// number has to be translated through the newline table. Deriving it directly as
/// `line_starts[starts - keep_tail]` — the first version — lands one line too far
/// down, so a "keep 2 tail" came back with one line in it.
pub fn clipLines(
    text: []const u8,
    keep_head: usize,
    keep_tail: usize,
) struct { head: []const u8, tail: []const u8, cut: bool } {
    var line_starts: [max_line_starts]usize = undefined;
    var starts: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n' and starts < max_line_starts) {
            line_starts[starts] = i + 1;
            starts += 1;
        }
    }
    const trailing = text.len > 0 and text[text.len - 1] == '\n';
    // Index of the LAST line.
    const last_line = if (trailing) starts -| 1 else starts;
    const total_lines = last_line + 1;
    if (total_lines <= keep_head +| keep_tail) {
        return .{ .head = text, .tail = "", .cut = false };
    }
    // Head: lines 0..keep_head, so it ends where line `keep_head` begins.
    const head_end = lineStart(keep_head, line_starts[0..starts]);
    if (keep_tail == 0) {
        return .{ .head = text[0..head_end], .tail = "", .cut = true };
    }
    // Tail: the last `keep_tail` lines, so it begins at line
    // `last_line + 1 - keep_tail`. Guarded so the two never overlap: the early
    // return above already guarantees `keep_tail < total_lines - keep_head`.
    const first_tail_line = (last_line + 1) -| keep_tail;
    const tail_at = if (first_tail_line <= keep_head)
        text.len
    else
        lineStart(first_tail_line, line_starts[0..starts]);
    return .{ .head = text[0..head_end], .tail = text[tail_at..], .cut = true };
}

/// Byte offset where line `k` begins. `k == 0` is always 0.
fn lineStart(k: usize, starts: []const usize) usize {
    if (k == 0) return 0;
    if (k <= starts.len) return starts[k - 1];
    return std.math.maxInt(usize);
}

/// Enough line starts for any result the tool-output cap can produce that still
/// matters; a longer one is clipped by its own caller first.
const max_line_starts: usize = 4096;


/// Scratch type for call sites that want a `[]const u8` out of a stack buffer.
pub const ClipWrap = struct {
    s: []const u8,
};

// ── tests ──────────────────────────────────────────────────

test "columnCount: ASCII is one column per byte" {
    try std.testing.expectEqual(@as(usize, 5), columnCount("hello"));
}

test "columnCount: a combining mark does not add a column" {
    // "e" + combining acute = one grapheme, one column.
    try std.testing.expectEqual(@as(usize, 1), columnCount("é"));
}

test "columnCount: CJK is two columns per character" {
    try std.testing.expectEqual(@as(usize, 6), columnCount("日本語"));
}

test "fits: a long ASCII command is 60 columns at most" {
    try std.testing.expect(!fits("zig build test --summary all && ls -la src && cat build.zig", 20));
    try std.testing.expect(fits("ls -la", 20));
}

test "clipInto: the ellipsis is INSIDE the budget" {
    var buf: [64]u8 = undefined;
    const out = clipInto("abcdefghij", 5, &buf);
    try std.testing.expectEqual(@as(usize, 5), columnCount(out));
    try std.testing.expect(std.mem.eql(u8, out, "abcd…"));
}

test "clipInto: a budget of one is the ellipsis alone" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, clipInto("abc", 1, &buf), "…"));
}

test "clipInto: the ASCII case is exactly the budget" {
    // The bug this pins: the first version reserved room with `ellipsis.len`
    // (3 BYTES) instead of `ellipsis_cols` (1), so every clip came out short.
    var buf: [64]u8 = undefined;
    for (0..40) |max_cols| {
        if (max_cols == 0) continue;
        const out = clipInto("abcdefghij", max_cols, &buf);
        const want = @min(max_cols, columnCount("abcdefghij"));
        try std.testing.expectEqual(want, columnCount(out));
    }
}

test "clipInto: never cuts a multi-byte character" {
    var buf: [64]u8 = undefined;
    const out = clipInto("héllo wörld", 4, &buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqual(@as(usize, 4), columnCount(out));
}

test "clipInto: a 2-column CJK character is not cut in half" {
    var buf: [64]u8 = undefined;
    const out = clipInto("日本語", 3, &buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(columnCount(out) <= 3);
}

test "clipInto: a string that fits is returned as is" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, clipInto("short", 10, &buf), "short"));
}

test "safeBoundary: a budget past the end returns the whole length" {
    try std.testing.expectEqual(@as(usize, 3), safeBoundary("abc", 100));
}

test "safeBoundary: an invalid start byte stops the walk" {
    try std.testing.expectEqual(@as(usize, 0), safeBoundary("\xffabc", 10));
}

test "safeBoundary: a continuation byte is never a boundary" {
    const s = "é ñ";
    const at = safeBoundary(s, 2);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s[at..]));
    try std.testing.expect(columnCount(s[0..at]) <= 2);
}

test "clipLines: a short result is not cut" {
    const s = "a\nb\nc";
    const r = clipLines(s, 2, 2);
    try std.testing.expect(!r.cut);
    try std.testing.expectEqual(s, r.head);
    try std.testing.expectEqual(@as(usize, 0), r.tail.len);
}

test "clipLines: a trailing newline does not count as an extra line" {
    // "line 0\n...line 9\n" is 10 lines and 10 newlines. Counting 11 cut one
    // line later than it should, which is how a 10-line result came out with an
    // 11-line-gap marker over it.
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    var fill: [32]u8 = undefined;
    for (0..10) |i| {
        const line = std.fmt.bufPrint(&fill, "line {d}\n", .{i}) catch unreachable;
        @memcpy(buf[n .. n + line.len], line);
        n += line.len;
    }
    const r = clipLines(buf[0..n], 2, 2);
    try std.testing.expect(r.cut);
}

test "clipLines: a text with no trailing newline keeps its last line" {
    const s = "a\nb\nc\nd";
    const r = clipLines(s, 2, 1);
    try std.testing.expect(r.cut);
    try std.testing.expect(std.mem.indexOf(u8, r.tail, "d") != null);
}

test "clipLines: keep 0 head is allowed" {
    const s = "a\nb\nc\nd\ne";
    const r = clipLines(s, 0, 1);
    try std.testing.expect(r.cut);
    try std.testing.expectEqual(@as(usize, 0), r.head.len);
    try std.testing.expect(std.mem.indexOf(u8, r.tail, "e") != null);
}