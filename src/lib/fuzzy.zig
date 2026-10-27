//! One fuzzy matcher for every list in zode: the palette, the modal picker and
//! `/sessions`.
//!
//! ## What "fuzzy" means here, and what it does not
//!
//! The query is a **subsequence** of the label: `cs4` reaches `claude-sonnet-4-5`.
//! Three rules keep a subsequence from matching half the catalogue, which is what a
//! filter that does not filter looks like:
//!
//! 1. **Leftmost.** The scan starts where the previous match ended, so the user gets
//!    the first place the characters appear, not a scattered later one.
//! 2. **Runs win.** A run of consecutive characters is taken whole: `bc` in `a-xbc`
//!    highlights `bc`, not `b` with a lonely `c` four columns away.
//! 3. **A window.** The matched characters have to fit in a span at most
//!    `3 * query + 8` wide. Without it `abc` is a subsequence of almost everything.
//!
//! Scoring exists for the callers that RANK (`/sessions <query>`): a prefix beats a
//! substring, a substring beats a scatter, a word boundary and a camelCase hump are
//! worth something, and a long label loses against a short one. The palette
//! deliberately does NOT sort by score: its order is the provider's (free models
//! first), and reordering a list under the cursor is worse than not reordering it.
//!
//! ## Positions are BYTE offsets
//!
//! The painter walks graphemes, so a match that lands inside a multi-byte character
//! highlights the whole character. That is the only thing that can be painted, and
//! it is also the right thing: you cannot half-highlight a glyph.

const std = @import("std");

/// How much wider than the query the matched span may be.
pub const fuzzy_window_slack: usize = 8;

/// Matches `q` as a subsequence of `label`, writing the matched BYTE offsets into
/// `buf`. Returns how many there are, or null when it does not match.
pub fn matchPositions(label: []const u8, q: []const u8, buf: []u32) ?usize {
    if (q.len == 0) return 0;
    if (q.len > buf.len) return null;
    var n: usize = 0;
    var li: usize = 0;
    var qi: usize = 0;
    while (qi < q.len) {
        var j = li;
        while (j < label.len) : (j += 1) {
            if (std.ascii.toLower(label[j]) == std.ascii.toLower(q[qi])) break;
        }
        if (j >= label.len) return null;
        // The run that starts there, taken whole.
        var run: usize = 1;
        while (qi + run < q.len and j + run < label.len and
            std.ascii.toLower(label[j + run]) == std.ascii.toLower(q[qi + run])) : (run += 1)
        {}
        for (0..run) |k| {
            buf[n] = @intCast(j + k);
            n += 1;
        }
        li = j + run;
        qi += run;
    }
    const span = buf[n - 1] - buf[0] + 1;
    if (span > q.len * 3 + fuzzy_window_slack) return null;
    return n;
}

/// The positions to HIGHLIGHT: the contiguous prefix or substring when there is one
/// (that is what the eye reads as "the match"), and the fuzzy positions otherwise.
pub fn highlightPositions(label: []const u8, q: []const u8, buf: []u32) ?usize {
    if (q.len == 0) return null;
    if (startsWithIgnoreCase(label, q)) {
        for (q, 0..) |_, i| buf[i] = @intCast(i);
        return q.len;
    }
    if (indexOfIgnoreCase(label, q)) |at| {
        for (q, 0..) |_, i| buf[i] = @intCast(at + i);
        return q.len;
    }
    return matchPositions(label, q, buf);
}

/// How good a match is. Higher is better; only the ORDER matters.
pub fn score(label: []const u8, q: []const u8, n: usize, positions: []const u32) i32 {
    if (q.len == 0) return 0;
    var s: i32 = 0;
    var last: ?usize = null;
    var run: i32 = 0;

    for (positions[0..n]) |p32| {
        const p: usize = p32;
        s += 10;
        if (last) |l| {
            if (p == l + 1) {
                run += 1;
                s += 20 * run;
            } else {
                run = 0;
                s -= @intCast(@min(p - l, 50));
            }
        }
        // Start of a word: the beginning of the label or right after a separator.
        if (p == 0 or isSeparator(label[p - 1])) s += 100;
        // A camelCase hump: "cs" reaching sonnet's S and 4 is not a hump, but
        // "claudeSonnet" has two and the humps are where humans abbreviate.
        if (p > 0 and std.ascii.isUpper(label[p]) and !std.ascii.isUpper(label[p - 1])) {
            s += 50;
        }
        last = p;
    }

    if (startsWithIgnoreCase(label, q)) {
        s += 500;
    } else if (indexOfIgnoreCase(label, q) != null) {
        s += 200;
    }
    // Shorter is better: "kimi" should beat "kimi-k2.6-thinking-preview" for the
    // same query when both match exactly at the start.
    s -= @intCast(label.len / 10);
    return s;
}

fn isSeparator(ch: u8) bool {
    return switch (ch) {
        '/', '\\', '_', '-', '.', ' ', ':', '(', ')', '[', ']', ',', '@' => true,
        else => false,
    };
}

pub const Scored = struct {
    index: usize,
    score: i32,
};

/// The indices of `labels` that match `q`, best first.
///
/// Ties keep their ORIGINAL order: `std.mem.sort` is not stable, and a filter whose
/// equal-scoring rows swap between keystrokes is a list that moves under the cursor
/// for no reason. The sort is an insertion sort because these lists are tens of
/// rows, not thousands.
pub fn rank(
    gpa: std.mem.Allocator,
    q: []const u8,
    labels: []const []const u8,
) ![]Scored {
    var out: std.ArrayList(Scored) = .empty;
    errdefer out.deinit(gpa);

    var buf: [128]u32 = undefined;
    for (labels, 0..) |label, i| {
        const n = matchPositions(label, q, &buf) orelse continue;
        try out.append(gpa, .{ .index = i, .score = score(label, q, n, &buf) });
    }

    const items = out.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].score < key.score) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = key;
    }
    return out.toOwnedSlice(gpa);
}

pub fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn startsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(hay[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

pub fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return indexOfIgnoreCase(hay, needle) != null;
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "matchPositions: a prefix, a substring and a camelCase hump" {
    var buf: [64]u32 = undefined;

    try t.expectEqual(@as(usize, 3), matchPositions("claude-sonnet-4-5", "cla", &buf).?);
    try t.expectEqual(@as(u32, 0), buf[0]);

    const n = matchPositions("claude-sonnet-4-5", "cs4", &buf).?;
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqual(@as(u32, 0), buf[0]); // c of claude
    try t.expectEqual(@as(u32, 7), buf[1]); // s of sonnet
    try t.expectEqual(@as(u32, 14), buf[2]); // 4
}

test "matchPositions: the window rejects a scatter that is not a match" {
    var buf: [64]u32 = undefined;
    // "abc" is a subsequence of this label, far apart, and that is not a filter.
    try t.expect(matchPositions("a---------------b---------------c", "abc", &buf) == null);
    // The same three characters in a short label do match.
    try t.expect(matchPositions("a-b-c", "abc", &buf) != null);
}

test "matchPositions: case-insensitive, and the query longer than the label is null" {
    var buf: [64]u32 = undefined;
    try t.expect(matchPositions("OpenRouter", "or", &buf) != null);
    try t.expect(matchPositions("ab", "abc", &buf) == null);
    try t.expectEqual(@as(usize, 0), matchPositions("anything", "", &buf).?);
}

test "highlightPositions: a contiguous substring wins over a scattered match" {
    var buf: [64]u32 = undefined;
    // "bc" is contiguous at 3; the fuzzy scan would have taken b at 1 and c at 3
    // in a naive leftmost pass.
    const n = highlightPositions("a-xbc", "bc", &buf).?;
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(u32, 3), buf[0]);
    try t.expectEqual(@as(u32, 4), buf[1]);
}

test "score: a prefix beats a substring beats a scatter" {
    var b1: [64]u32 = undefined;
    var b2: [64]u32 = undefined;
    var b3: [64]u32 = undefined;

    const q = "son";
    const n1 = matchPositions("sonnet", q, &b1).?;
    const n2 = matchPositions("claude-sonnet", q, &b2).?;
    const n3 = matchPositions("s-o-nnet", q, &b3).?;

    const s1 = score("sonnet", q, n1, &b1);
    const s2 = score("claude-sonnet", q, n2, &b2);
    const s3 = score("s-o-nnet", q, n3, &b3);
    try t.expect(s1 > s2);
    try t.expect(s2 > s3);
}

test "score: a word boundary and a camelCase hump are worth something" {
    var ba: [64]u32 = undefined;
    var bb: [64]u32 = undefined;
    const q = "s";
    const na = matchPositions("foo/s", q, &ba).?;
    const nb = matchPositions("foos", q, &bb).?;
    try t.expect(score("foo/s", q, na, &ba) > score("foos", q, nb, &bb));

    var bc: [64]u32 = undefined;
    var bd: [64]u32 = undefined;
    const nc = matchPositions("fooBar", "b", &bc).?;
    const nd = matchPositions("foobar", "b", &bd).?;
    try t.expect(score("fooBar", "b", nc, &bc) > score("foobar", "b", nd, &bd));
}

test "rank: best first, ties keep their original order" {
    const labels = [_][]const u8{
        "zzz-sonnet", // 0: substring, long
        "sonnet-extra", // 1: prefix, long
        "sonnet", // 2: prefix, short -> should win
        "unrelated", // 3: no match
        "Sonnets", // 4: prefix, short-ish
    };
    const got = try rank(t.allocator, "sonnet", &labels);
    defer t.allocator.free(got);
    try t.expectEqual(@as(usize, 4), got.len);
    for (got) |s| try t.expect(s.index != 3);
    // "sonnet" and "Sonnets" both start with the query; the shorter one wins, and
    // the prefix rows beat the substring row.
    try t.expectEqual(@as(usize, 2), got[0].index);
    try t.expectEqual(@as(usize, 4), got[1].index);
    try t.expectEqual(@as(usize, 1), got[2].index);
    try t.expectEqual(@as(usize, 0), got[3].index);
}

test "rank: an empty query matches everything, in order" {
    const labels = [_][]const u8{ "b", "a", "c" };
    const got = try rank(t.allocator, "", &labels);
    defer t.allocator.free(got);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqual(@as(usize, 0), got[0].index);
    try t.expectEqual(@as(usize, 1), got[1].index);
    try t.expectEqual(@as(usize, 2), got[2].index);
}

test "rank: equal scores do not swap" {
    // Two identical labels score identically; the first one stays first.
    const labels = [_][]const u8{ "ab", "ab" };
    const got = try rank(t.allocator, "ab", &labels);
    defer t.allocator.free(got);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqual(@as(usize, 0), got[0].index);
    try t.expectEqual(@as(usize, 1), got[1].index);
    try t.expectEqual(got[0].score, got[1].score);
}