/// Shared tokenizer for word-level diff and edit_hint.
/// 
/// The tokenizer is shared so that both the diff and the edit hint agree on
/// what constitutes a "word" in code. A `[\p{L}\p{N}_]` run = 1 token,
/// whitespace run = 1 token, everything else one token per codepoint
/// (`x += 1` = 5 tokens; in code, `+=`/`=>`/`!=` are words).
const std = @import("std");

/// A token with its byte range in the original text.
pub const Token = struct {
    text: []const u8,
    start: usize,
    end: usize,
};

/// Tokenizes code text into tokens suitable for word-level diff.
/// 
/// Rules:
/// - Alphanumeric + underscore runs: one token (`foo_bar123`)
/// - Whitespace runs: one token (`  \t `)
/// - Common operators: one token (`+=`, `-=`, `*=`, `/=`, `%=`, `==`, `!=`, `<=`, `>=`, `=>`, `->`, `++`, `--`, `...`, `..`, `&&`, `||`, `<<`, `>>`, `+=`, `-=`, `*=`, `/=`, `%=`)
/// - Everything else: one token per codepoint (`+`, `-`, `*`, `/`, `%`, `<`, `>`, `=`, `!`, `&`, `|`, `^`, `~`, `.`, `,`, `;`, `:`, `(`, `)`, `[`, `]`, `{`, `}`, etc.)
pub fn tokenizeCode(arena: std.mem.Allocator, text: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const start = i;
        if (isAlphaNumOrUnderscore(c)) {
            // Alphanumeric/underscore run
            while (i < text.len and isAlphaNumOrUnderscore(text[i])) {
                i += 1;
            }
            try tokens.append(arena, .{
                .text = text[start..i],
                .start = start,
                .end = i,
            });
        } else if (std.ascii.isWhitespace(c)) {
            // Whitespace run
            while (i < text.len and std.ascii.isWhitespace(text[i])) {
                i += 1;
            }
            try tokens.append(arena, .{
                .text = text[start..i],
                .start = start,
                .end = i,
            });
        } else if (try isMultiCharOperator(text, i)) |op_len| {
            // Multi-character operator
            i += op_len;
            try tokens.append(arena, .{
                .text = text[start..i],
                .start = start,
                .end = i,
            });
        } else {
            // Single codepoint token (operator, punctuation, etc.)
            i += 1;
            try tokens.append(arena, .{
                .text = text[start..i],
                .start = start,
                .end = i,
            });
        }
    }
    return tokens.toOwnedSlice(arena);
}

fn isMultiCharOperator(text: []const u8, pos: usize) !?usize {
    if (pos + 1 >= text.len) return null;
    
    const c1 = text[pos];
    const c2 = text[pos + 1];
    
    // Three-character operators
    if (pos + 2 < text.len) {
        const c3 = text[pos + 2];
        if (c1 == '.' and c2 == '.' and c3 == '.') return 3; // ...
    }
    
    // Two-character operators
    switch (c1) {
        '+' => if (c2 == '=' or c2 == '+') return 2, // +=, ++
        '-' => if (c2 == '=' or c2 == '-' or c2 == '>') return 2, // -=, --, ->
        '*' => if (c2 == '=') return 2, // *=
        '/' => if (c2 == '=') return 2, // /=
        '%' => if (c2 == '=') return 2, // %=
        '=' => if (c2 == '=' or c2 == '>') return 2, // ==, =>
        '!' => if (c2 == '=') return 2, // !=
        '<' => if (c2 == '=' or c2 == '<') return 2, // <=, <<
        '>' => if (c2 == '=' or c2 == '>') return 2, // >=, >>
        '&' => if (c2 == '&') return 2, // &&
        '|' => if (c2 == '|') return 2, // ||
        '.' => if (c2 == '.') return 2, // ..
        else => {},
    }
    return null;
}

/// Computes the Longest Common Subsequence (LCS) between two token sequences.
/// Returns the LCS as a list of indices into the first sequence.
pub fn lcsTokens(a: []const Token, b: []const Token) ![]usize {
    const n = a.len;
    const m = b.len;
    if (n == 0 or m == 0) return &.{};
    
    // DP table for LCS lengths
    var dp = try std.heap.page_allocator.alloc(usize, (n + 1) * (m + 1));
    defer std.heap.page_allocator.free(dp);
    @memset(dp, 0);
    
    // Fill DP table
    var i: usize = 1;
    while (i <= n) {
        var j: usize = 1;
        while (j <= m) {
            const idx = i * (m + 1) + j;
            if (std.mem.eql(u8, a[i - 1].text, b[j - 1].text)) {
                dp[idx] = dp[(i - 1) * (m + 1) + (j - 1)] + 1;
            } else {
                dp[idx] = @max(dp[(i - 1) * (m + 1) + j], dp[i * (m + 1) + (j - 1)]);
            }
            j += 1;
        }
        i += 1;
    }
    
    // Backtrack to find LCS indices in a
    var lcs_indices: std.ArrayList(usize) = .empty;
    i = n;
    var j = m;
    while (i > 0 and j > 0) {
        if (std.mem.eql(u8, a[i - 1].text, b[j - 1].text)) {
            try lcs_indices.append(std.heap.page_allocator, i - 1);
            i -= 1;
            j -= 1;
        } else if (dp[(i - 1) * (m + 1) + j] >= dp[i * (m + 1) + (j - 1)]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }
    
    // Reverse to get forward order
    var result = try std.heap.page_allocator.alloc(usize, lcs_indices.items.len);
    for (lcs_indices.items, 0..) |idx, rev_i| {
        result[lcs_indices.items.len - 1 - rev_i] = idx;
    }
    
    lcs_indices.deinit(std.heap.page_allocator);
    return result;
}

/// A byte range in the new line that changed.
pub const DiffRange = struct {
    start: usize,
    end: usize,
};

/// Computes word-level diff ranges for a pair of lines.
/// 
/// Given the old line (with `-` prefix) and new line (with `+` prefix),
/// returns the byte ranges in the new line that changed.
/// 
/// Pure insertions/deletions (unpaired lines) get NO word diff.
/// Above CHANGE_THRESHOLD (40%), discard word ranges and return flat color.
pub fn wordDiffRanges(
    arena: std.mem.Allocator,
    old_line: []const u8,
    new_line: []const u8,
) ![]DiffRange {
    const old_tokens = try tokenizeCode(std.heap.page_allocator, old_line);
    defer std.heap.page_allocator.free(old_tokens);
    const new_tokens = try tokenizeCode(std.heap.page_allocator, new_line);
    defer std.heap.page_allocator.free(new_tokens);
    
    const lcs = try lcsTokens(old_tokens, new_tokens);
    defer std.heap.page_allocator.free(lcs);
    
    // If more than 40% changed, discard word diff
    const total_new = new_tokens.len;
    const common = lcs.len;
    if (total_new > 0) {
        const change_ratio = 1.0 - (@as(f64, @floatFromInt(common)) / @as(f64, @floatFromInt(total_new)));
        if (change_ratio > 0.40) {
            return &.{};
        }
    }
    
    // Build ranges from LCS - tokens NOT in LCS are changed
    var ranges: std.ArrayList(DiffRange) = .empty;
    var last_end: usize = 0;
    var lcs_idx: usize = 0;
    
    var ti: usize = 0;
    while (ti < new_tokens.len) {
        if (lcs_idx < lcs.len and lcs[lcs_idx] == ti) {
            // This token is in LCS (unchanged)
            if (ti > last_end) {
                // There was a gap - changed region
                try ranges.append(arena, .{
                    .start = new_tokens[last_end].start,
                    .end = new_tokens[ti].start,
                });
            }
            last_end = ti + 1;
            lcs_idx += 1;
        }
        ti += 1;
    }
    
    // Check for trailing changed region
    if (last_end < new_tokens.len) {
        try ranges.append(arena, .{
            .start = new_tokens[last_end].start,
            .end = new_tokens[new_tokens.len - 1].end,
        });
    }
    
    return ranges.toOwnedSlice(arena);
}

fn isAlphaNumOrUnderscore(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

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

test "lcsTokens: common tokens" {
    const a = try tokenizeCode(std.heap.page_allocator, "x = 1");
    defer std.heap.page_allocator.free(a);
    const b = try tokenizeCode(std.heap.page_allocator, "x = 2");
    defer std.heap.page_allocator.free(b);
    
    const lcs = try lcsTokens(a, b);
    defer std.heap.page_allocator.free(lcs);
    
    // "x", " ", "=", " " should match (4 tokens), only "1" vs "2" differs
    try std.testing.expectEqual(@as(usize, 4), lcs.len);
}

test "wordDiffRanges: simple change" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    
    const ranges = try wordDiffRanges(arena, "x = 1", "x = 2");
    // Only "1" -> "2" should be marked as changed
    try std.testing.expectEqual(@as(usize, 1), ranges.len);
}

test "wordDiffRanges: above threshold returns empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    
    // Completely different lines - should exceed 40% threshold
    const ranges = try wordDiffRanges(arena, "hello world", "goodbye universe");
    try std.testing.expectEqual(@as(usize, 0), ranges.len);
}