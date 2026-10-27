/// The tokenizer shared by the word-level diff and `edit_hint`.
///
/// ## Why ONE tokenizer
///
/// The word diff asks "which words changed" and the edit hint asks "which line
/// did you mean". Both of them are the same question about the same code, and
/// two tokenizers are two answers: a diff that says `x += 1` changed in `+=`
/// while the hint says the line is `x += 1` (three words) is a diff and a hint
/// that disagree about what a word IS.
///
/// The rules, in one place:
///
/// - a `[\p{L}\p{N}_]` run is ONE token (`foo_bar123`)
/// - a whitespace run is ONE token (`  \t `)
/// - an operator is ONE token (`+=`, `=>`, `!=`, `->`, `...`)
/// - everything else is ONE TOKEN PER CODEPOINT (`.`, `,`, `;`, `(`, `)`)
///
/// The operator rule is the one that looks like a detail and is not: in code
/// `+=` is a WORD. A tokenizer that split it into `+` and `=` turned
/// `x += 1;` into five tokens where the punctuation carried no meaning, and
/// the first version of `edit_hint` learned that the hard way: a patch whose
/// tokens were `x += 1;` came back with NO tokens at all and every score was
/// zero.
const std = @import("std");

/// A token with its byte range in the original text.
pub const Token = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

/// Tokenizes code text into tokens suitable for word-level diff.
pub fn tokenizeCode(arena: std.mem.Allocator, text: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const start = i;
        if (isAlphaNumOrUnderscore(c)) {
            while (i < text.len and isAlphaNumOrUnderscore(text[i])) i += 1;
        } else if (std.ascii.isWhitespace(c)) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        } else if (multiCharOperator(text, i)) |op_len| {
            i += op_len;
        } else {
            i += 1;
        }
        try tokens.append(arena, .{ .text = text[start..i], .start = start, .end = i });
    }
    return tokens.toOwnedSlice(arena);
}

fn multiCharOperator(text: []const u8, pos: usize) ?usize {
    if (pos + 1 >= text.len) return null;
    const c1 = text[pos];
    const c2 = text[pos + 1];

    if (pos + 2 < text.len and c1 == '.' and c2 == '.' and text[pos + 2] == '.') return 3;

    return switch (c1) {
        '+' => if (c2 == '=' or c2 == '+') 2 else null,
        '-' => if (c2 == '=' or c2 == '-' or c2 == '>') 2 else null,
        '*' => if (c2 == '=') 2 else null,
        '/' => if (c2 == '=') 2 else null,
        '%' => if (c2 == '=') 2 else null,
        '=' => if (c2 == '=' or c2 == '>') 2 else null,
        '!' => if (c2 == '=') 2 else null,
        '<' => if (c2 == '=' or c2 == '<') 2 else null,
        '>' => if (c2 == '=' or c2 == '>') 2 else null,
        '&' => if (c2 == '&') 2 else null,
        '|' => if (c2 == '|') 2 else null,
        '.' => if (c2 == '.') 2 else null,
        else => null,
    };
}

fn isAlphaNumOrUnderscore(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

/// A matched pair: the SAME token, in both lines.
pub const Match = struct {
    old: usize,
    new: usize,
};

/// The longest common subsequence as matched pairs.
///
/// The first version returned the indices of the FIRST sequence only, and the
/// caller compared them against the indices of the SECOND one: two different
/// lists, compared element by element, which is a word diff that only looks
/// right when the two lines happen to line up.
///
/// The table is `(n+1)·(m+1)` `usize`, so a pair of very long lines is a lot
/// of memory: past `max_lcs_cells` the diff gives up and reports "everything
/// changed", which is the honest answer for a line nobody can diff.
pub const max_lcs_cells: usize = 1 << 20;

pub fn lcsMatches(arena: std.mem.Allocator, a: []const Token, b: []const Token) ![]Match {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return &.{};
    if ((n + 1) * (m + 1) > max_lcs_cells) return &.{};

    const table = try arena.alloc(usize, (n + 1) * (m + 1));
    @memset(table, 0);
    // `table[i * (m + 1) + j]` is the length of the longest common subsequence
    // of the FIRST `i` tokens of `a` and the FIRST `j` tokens of `b`, so it is
    // filled from the beginning and the walk back starts at the end.
    //
    // The first version filled it the other way round (the SUFFIX
    // convention) and walked it back as if it were the prefix one: the table
    // was the right shape and the wrong answer, and the word diff that used
    // it marked the wrong tokens.
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        var j: usize = 1;
        while (j <= m) : (j += 1) {
            table[i * (m + 1) + j] = if (std.mem.eql(u8, a[i - 1].text, b[j - 1].text))
                table[(i - 1) * (m + 1) + (j - 1)] + 1
            else
                @max(table[(i - 1) * (m + 1) + j], table[i * (m + 1) + (j - 1)]);
        }
    }

    var out: std.ArrayList(Match) = .empty;
    var x: usize = n;
    var y: usize = m;
    while (x > 0 and y > 0) {
        if (std.mem.eql(u8, a[x - 1].text, b[y - 1].text)) {
            try out.append(arena, .{ .old = x - 1, .new = y - 1 });
            x -= 1;
            y -= 1;
        } else if (table[x * (m + 1) + (y - 1)] >= table[(x - 1) * (m + 1) + y]) {
            y -= 1;
        } else {
            x -= 1;
        }
    }
    // The backtrack walks backwards; the pairs have to come out in order.
    std.mem.reverse(Match, out.items);
    return out.toOwnedSlice(arena);
}

/// A byte range in a line that changed.
pub const DiffRange = struct {
    start: usize,
    end: usize,
};

/// The changed ranges on BOTH sides of a pair of lines.
///
/// `old` are byte ranges in the OLD line and `new` are byte ranges in the NEW
/// one. Both sides are needed: a diff that highlights what was ADDED and not
/// what was REMOVED is a diff that shows half of every change.
pub const WordDiff = struct {
    old: []const DiffRange,
    new: []const DiffRange,
};

/// Above this fraction of changed tokens the word ranges are DISCARDED.
///
/// A rewrite is not information, it is confetti: when 60% of the tokens
/// changed, marking the 60% tells the reader nothing they could not see from
/// the line colours. The same call as `edit_hint`'s 0.50 Jaccard, for the same
/// reason.
pub const change_threshold: f64 = 0.40;

/// The word-level diff of a pair of lines.
///
/// `old_line` and `new_line` are the BODIES (without the diff's `+`/`-`
/// prefix). Returns empty ranges on both sides when the change is too big to
/// be worth pointing at, and when the two lines have nothing in common.
pub fn wordDiff(arena: std.mem.Allocator, old_line: []const u8, new_line: []const u8) !WordDiff {
    const old_tokens = try tokenizeCode(arena, old_line);
    const new_tokens = try tokenizeCode(arena, new_line);
    if (old_tokens.len == 0 or new_tokens.len == 0) return .{ .old = &.{}, .new = &.{} };

    const matches = try lcsMatches(arena, old_tokens, new_tokens);

    // How much of the NEW line is new. The new side is the one that decides
    // whether the change is a rewrite: a line that grew is measured on what
    // it grew into.
    const changed = new_tokens.len - matches.len;
    const ratio = @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(new_tokens.len));
    if (ratio > change_threshold) return .{ .old = &.{}, .new = &.{} };

    const old_same = try arena.alloc(bool, old_tokens.len);
    @memset(old_same, false);
    const new_same = try arena.alloc(bool, new_tokens.len);
    @memset(new_same, false);
    for (matches) |m| {
        // The matched tokens are the ones that did NOT change.
        old_same[m.old] = true;
        new_same[m.new] = true;
    }

    return .{
        .old = try rangesOf(arena, old_tokens, old_same),
        .new = try rangesOf(arena, new_tokens, new_same),
    };
}

/// The byte ranges of the tokens that are NOT in the common subsequence,
/// merged into runs.
fn rangesOf(arena: std.mem.Allocator, tokens: []const Token, same: []const bool) ![]DiffRange {
    var out: std.ArrayList(DiffRange) = .empty;
    var i: usize = 0;
    while (i < tokens.len) {
        if (same[i]) {
            i += 1;
            continue;
        }
        const start = tokens[i].start;
        var end = tokens[i].end;
        i += 1;
        // A run of changed tokens is ONE range: the highlight covers the
        // spaces between them too, which is what makes it read as a region
        // and not as a pile of loose words.
        while (i < tokens.len and !same[i]) : (i += 1) end = tokens[i - 1].end;
        try out.append(arena, .{ .start = start, .end = end });
    }
    return out.toOwnedSlice(arena);
}

/// The Jaccard similarity of two texts over the shared tokens.
///
/// `edit_hint` uses it to decide whether a line is "close enough" to be worth
/// showing. It is here, and not there, because the tokens are here: two
/// tokenizers are two answers to "what is a word in code", and a hint that
/// says a line is `x += 1` (three words) while the diff says the `+=` is what
/// changed is a hint and a diff that do not agree.
pub fn jaccard(a: []const u8, b: []const u8) f64 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    return jaccardIn(arena_state.allocator(), a, b);
}

/// The Jaccard similarity of two texts, with the tokens allocated in `arena`.
///
/// The caller owns the arena, and it can be reset between two texts: a file
/// with ten thousand lines is ten thousand pairs of token lists, and keeping
/// them all is a memory leak with a very long fuse.
pub fn jaccardIn(arena: std.mem.Allocator, a: []const u8, b: []const u8) f64 {
    const at = tokenizeCode(arena, a) catch return 0;
    const bt = tokenizeCode(arena, b) catch return 0;
    if (at.len == 0 or bt.len == 0) return 0;

    var inter: usize = 0;
    for (at) |t| {
        for (bt) |u| {
            if (std.mem.eql(u8, t.text, u.text)) {
                inter += 1;
                break;
            }
        }
    }
    const total = at.len + bt.len - inter;
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(total));
}

// ── tests ───────────────────────────────────────────────────────────────────────

test "tokenizeCode: x += 1 is 5 tokens" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenizeCode(arena, "x += 1");
    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualStrings("x", tokens[0].text);
    try std.testing.expectEqualStrings(" ", tokens[1].text);
    try std.testing.expectEqualStrings("+=", tokens[2].text);
    try std.testing.expectEqualStrings(" ", tokens[3].text);
    try std.testing.expectEqualStrings("1", tokens[4].text);
}

test "tokenizeCode: foo_bar is 1 token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenizeCode(arena, "foo_bar");
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("foo_bar", tokens[0].text);
}

test "tokenizeCode: whitespace is 1 token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenizeCode(arena, "  \t ");
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("  \t ", tokens[0].text);
}

test "tokenizeCode: an operator is a word and the punctuation is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = try tokenizeCode(arena, "a => b;");
    try std.testing.expectEqualStrings("=>", tokens[2].text);
    try std.testing.expectEqualStrings("b", tokens[4].text);
    try std.testing.expectEqualStrings(";", tokens[5].text);
}

test "lcsMatches: the pairs are in order and point at BOTH sides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try tokenizeCode(arena, "x = 1");
    const b = try tokenizeCode(arena, "x = 2");

    const matches = try lcsMatches(arena, a, b);
    // "x", " ", "=", " " are common; only "1" vs "2" differs.
    try std.testing.expectEqual(@as(usize, 4), matches.len);
    for (matches, 0..) |m, i| {
        try std.testing.expectEqualStrings(a[i].text, b[m.new].text);
        try std.testing.expectEqual(m.old, i);
    }
}

test "wordDiff: only the changed token is marked, on BOTH sides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try wordDiff(arena, "x = 1", "x = 2");
    try std.testing.expectEqual(@as(usize, 1), d.new.len);
    try std.testing.expectEqual(@as(usize, 1), d.old.len);
    // "x = " is 4 bytes, so the changed token starts at 4.
    try std.testing.expectEqual(@as(usize, 4), d.new[0].start);
    try std.testing.expectEqual(@as(usize, 5), d.new[0].end);
    try std.testing.expectEqual(@as(usize, 4), d.old[0].start);
}

test "wordDiff: a line 50% changed gets no ranges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const d = try wordDiff(arena, "hello world", "goodbye universe");
    try std.testing.expectEqual(@as(usize, 0), d.new.len);
    try std.testing.expectEqual(@as(usize, 0), d.old.len);
}

test "wordDiff: a line 10% changed does get ranges (the threshold is not vacuous)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 10 tokens, one of them different: 10% changed.
    const d = try wordDiff(arena, "a b c d e f g h i j", "a b c d e f g h i k");
    try std.testing.expectEqual(@as(usize, 1), d.new.len);
    try std.testing.expectEqual(@as(usize, 1), d.old.len);
    try std.testing.expectEqualStrings("k", "a b c d e f g h i k"[d.new[0].start..d.new[0].end]);
}

test "wordDiff: the ranges are byte ranges INTO the line, not token indices" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old_line = "const x = 1;";
    const new_line = "const x = 42;";
    const d = try wordDiff(arena, old_line, new_line);
    try std.testing.expectEqual(@as(usize, 1), d.new.len);
    try std.testing.expectEqualStrings("42", new_line[d.new[0].start..d.new[0].end]);
    try std.testing.expectEqualStrings("1", old_line[d.old[0].start..d.old[0].end]);
}
