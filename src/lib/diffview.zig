/// What a unified diff SAYS, line by line.
///
/// The diff the harness paints is a TEXT (`@@ -1,4 +1,6 @@`, `+`, `-`, ` `),
/// and everything the reader wants out of it — the line number of every row,
/// the width of the gutter, which words changed — has to be recovered from
/// that text. Recovering it once, here, is what keeps the painter from
/// guessing: a number that comes from a counter and a number that comes from
/// a second guess are not the same number.
///
/// ## The two counters
///
/// A diff has TWO line numbers per row: the line in the OLD file and the line
/// in the NEW one. A `+` row only exists in the new file, a `-` row only in
/// the old one, and a context row exists in both:
///
/// ```text
/// @@ -10,4 +12,5 @@
///  context      -> old 10, new 12
/// -removed      -> old 11
/// +added        -> new 13
/// ```
///
/// The gutter shows the NEW number for a context row (the file you are
/// looking at is the new one) and the number the row belongs to on its own
/// side: the old one for a deletion, the new one for an addition.
const std = @import("std");
const diff_tokenizer = @import("diff_tokenizer.zig");

pub const LineKind = enum {
    /// `@@ -a,b +c,d @@`
    hunk,
    /// `+ …`
    add,
    /// `- …`
    del,
    /// ` …`
    ctx,
    /// Anything else (the preview's header, the "N more lines" footer).
    other,
};

/// One row of the diff, as the painter needs it.
pub const Line = struct {
    kind: LineKind,
    /// The text of the line, without the newline.
    text: []const u8,
    /// The number the gutter shows, or null when the line has none.
    number: ?usize,
    /// Width of the gutter, in columns, for the hunk this line belongs to.
    ///
    /// It is the number of digits of the hunk's LAST line, and it is PER HUNK:
    /// a diff of a 10 000-line file has a five-digit gutter in the hunk at the
    /// end and a two-digit one in the hunk at the start, and a gutter sized for
    /// the whole file makes the first hunk a wall of spaces.
    gutter_width: usize,
    /// The changed byte ranges, in the line BODY (without the `+`/`-`).
    ranges: []const diff_tokenizer.DiffRange,
};

pub const Options = struct {
    /// Compute the word-level diff. Off for a collapsed preview: a highlight
    /// inside a quiet box is noise.
    word_diff: bool = true,
};

/// The empty range slice, shared by every line without changes.
const no_ranges: []const diff_tokenizer.DiffRange = &.{};

/// Reads a diff text and says what every row means.
pub fn analyze(arena: std.mem.Allocator, text: []const u8, opts: Options) ![]Line {
    var raw: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try raw.append(arena, l);

    const lines = try arena.alloc(Line, raw.items.len);
    var old_no: usize = 0;
    var new_no: usize = 0;

    // ── pass 1: what every row is, and its number ──
    for (raw.items, 0..) |l, i| {
        var line = Line{
            .kind = .other,
            .text = l,
            .number = null,
            .gutter_width = 0,
            .ranges = no_ranges,
        };
        if (l.len > 0) {
            switch (l[0]) {
                '@' => {
                    if (parseHunkHeader(l)) |h| {
                        line.kind = .hunk;
                        old_no = h.old_start;
                        new_no = h.new_start;
                    }
                },
                '+' => {
                    line.kind = .add;
                    line.number = new_no;
                    new_no += 1;
                },
                '-' => {
                    line.kind = .del;
                    line.number = old_no;
                    old_no += 1;
                },
                ' ' => {
                    line.kind = .ctx;
                    line.number = new_no;
                    old_no += 1;
                    new_no += 1;
                },
                else => {},
            }
        }
        lines[i] = line;
    }

    // ── pass 2: the gutter width, per hunk ──
    //
    // The width is the number of digits of the hunk's LAST line, and the hunk
    // is the run of rows between two `@@` headers. The rows before the first
    // header (the preview's own header) have no number and no gutter.
    var hunk_start: usize = 0;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        if (lines[i].kind != .hunk) continue;
        // The rows of the hunk that just ended.
        setGutterWidth(lines[hunk_start..i]);
        hunk_start = i;
    }
    setGutterWidth(lines[hunk_start..]);

    // ── pass 3: the word diff ──
    if (opts.word_diff) try pairRuns(arena, lines);

    return lines;
}

/// The width of the gutter for a run of rows: the digits of the biggest
/// number in it.
fn setGutterWidth(rows: []Line) void {
    var max_no: usize = 0;
    var any = false;
    for (rows) |r| {
        if (r.number) |n| {
            any = true;
            if (n > max_no) max_no = n;
        }
    }
    if (!any) return;
    const width = digits(max_no);
    for (rows) |*r| {
        if (r.number != null) r.gutter_width = width;
    }
}

/// Pairs a run of deletions with the run of additions that follows it.
///
/// The pairing is POSITIONAL: the first deletion with the first addition, the
/// second with the second. A run of three deletions followed by a run of five
/// additions pairs three of them and leaves two additions unpaired — and an
/// unpaired row gets NO word diff, because there is nothing on the other side
/// to compare it with.
fn pairRuns(arena: std.mem.Allocator, lines: []Line) !void {
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].kind != .del) {
            i += 1;
            continue;
        }
        // The run of deletions.
        const del_start = i;
        while (i < lines.len and lines[i].kind == .del) i += 1;
        const del_end = i;
        // The run of additions right after it (if any).
        const add_start = i;
        while (i < lines.len and lines[i].kind == .add) i += 1;
        const add_end = i;
        if (add_end == add_start) continue;

        const pairs = @min(del_end - del_start, add_end - add_start);
        var p: usize = 0;
        while (p < pairs) : (p += 1) {
            const d = &lines[del_start + p];
            const a = &lines[add_start + p];
            const old_body = bodyOf(d.text);
            const new_body = bodyOf(a.text);
            const wd = try diff_tokenizer.wordDiff(arena, old_body, new_body);
            d.ranges = wd.old;
            a.ranges = wd.new;
        }
    }
}

/// The body of a diff row: everything after the `+`/`-`/space marker.
fn bodyOf(line: []const u8) []const u8 {
    if (line.len == 0) return line;
    return line[1..];
}

/// The number of decimal digits of `n` (at least 1).
pub fn digits(n: usize) usize {
    if (n == 0) return 1;
    var v = n;
    var d: usize = 1;
    while (v >= 10) : (v /= 10) d += 1;
    return d;
}

const HunkHeader = struct {
    old_start: usize,
    new_start: usize,
};

/// Parses `@@ -a,b +c,d @@`.
///
/// A header that does not parse is not a header: the row is then an "other"
/// row, and the counters keep going. A diff with a broken header still gets
/// its word diffs; it just does not get a gutter.
fn parseHunkHeader(line: []const u8) ?HunkHeader {
    if (!std.mem.startsWith(u8, line, "@@ -")) return null;
    var i: usize = "@@ -".len;
    const old_start = readNumber(line, &i) orelse return null;
    if (i < line.len and line[i] == ',') {
        i += 1;
        _ = readNumber(line, &i) orelse return null;
    }
    if (i + 1 >= line.len or line[i] != ' ' or line[i + 1] != '+') return null;
    i += 2;
    const new_start = readNumber(line, &i) orelse return null;
    return .{ .old_start = old_start, .new_start = new_start };
}

/// The number at `i`, and where it ended.
///
/// The digits are read by hand because `parseUnsigned` wants the WHOLE string
/// to be a number, and the header is `@@ -10,4 +12,5 @@`: there is a comma
/// and a space and a second number after the first one.
fn readNumber(line: []const u8, i: *usize) ?usize {
    const start = i.*;
    while (i.* < line.len and std.ascii.isDigit(line[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseUnsigned(usize, line[start..i.*], 10) catch null;
}

// ── tests ───────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the numbers come from the two counters, not from the row's position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -10,4 +12,5 @@
        \\ context
        \\-removed
        \\+added
        \\ context
    ;
    const lines = try analyze(arena, diff, .{});
    try testing.expectEqual(LineKind.hunk, lines[0].kind);
    try testing.expectEqual(@as(?usize, 12), lines[1].number); // context: the NEW number
    try testing.expectEqual(@as(?usize, 11), lines[2].number); // deletion: the OLD number
    try testing.expectEqual(@as(?usize, 13), lines[3].number); // addition: the NEW number
    try testing.expectEqual(@as(?usize, 14), lines[4].number);
}

test "the gutter is as wide as the hunk's last line, and per hunk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,3 +1,3 @@
        \\ one
        \\@@ -98,2 +98,2 @@
        \\ ninety
        \\ ninety
    ;
    const lines = try analyze(arena, diff, .{});
    // The first hunk's biggest number is 3: one column.
    try testing.expectEqual(@as(usize, 1), lines[1].gutter_width);
    // The second hunk's biggest is 99: two columns.
    try testing.expectEqual(@as(usize, 2), lines[3].gutter_width);
    try testing.expectEqual(@as(usize, 2), lines[4].gutter_width);
}

test "a run of three deletions and five additions pairs three of them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,8 +1,8 @@
        \\-x = 1
        \\-y = 2
        \\-z = 3
        \\+x = 9
        \\+y = 8
        \\+z = 7
        \\+extra one
        \\+extra two
    ;
    const lines = try analyze(arena, diff, .{});
    // The three pairs have word diffs; the two extra additions do not.
    try testing.expect(lines[1].ranges.len > 0);
    try testing.expect(lines[2].ranges.len > 0);
    try testing.expect(lines[3].ranges.len > 0);
    try testing.expect(lines[4].ranges.len > 0);
    try testing.expect(lines[5].ranges.len > 0);
    try testing.expect(lines[6].ranges.len > 0);
    try testing.expectEqual(@as(usize, 0), lines[7].ranges.len);
    try testing.expectEqual(@as(usize, 0), lines[8].ranges.len);
}

test "a pure insertion is unpaired and gets no word diff" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,3 @@
        \\ keep
        \\+brand new line
        \\ keep
    ;
    const lines = try analyze(arena, diff, .{});
    try testing.expectEqual(@as(usize, 0), lines[2].ranges.len);
}

test "the word diff can be turned off (a collapsed preview)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ -1,2 +1,2 @@
        \\-const x = 1;
        \\+const x = 42;
    ;
    const on = try analyze(arena, diff, .{ .word_diff = true });
    try testing.expect(on[2].ranges.len > 0);
    const off = try analyze(arena, diff, .{ .word_diff = false });
    try testing.expectEqual(@as(usize, 0), off[2].ranges.len);
}

test "a row that is not part of the diff has no number and no gutter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff = "diff preview · +3 −1\n@@ -1,2 +1,2 @@\n-a\n+b\n";
    const lines = try analyze(arena, diff, .{});
    try testing.expectEqual(LineKind.other, lines[0].kind);
    try testing.expectEqual(@as(?usize, null), lines[0].number);
    try testing.expectEqual(@as(usize, 0), lines[0].gutter_width);
    try testing.expectEqual(@as(usize, 1), lines[2].gutter_width);
}

test "a broken header does not stop the diff: the rows keep their word diffs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const diff =
        \\@@ nonsense @@
        \\-const x = 1;
        \\+const x = 42;
    ;
    const lines = try analyze(arena, diff, .{});
    try testing.expectEqual(LineKind.other, lines[0].kind);
    try testing.expect(lines[2].ranges.len > 0);
}
