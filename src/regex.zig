const std = @import("std");

/// Mini backtracking regex engine. Supports what an LLM uses when searching
/// code: literals, `.`, `^`, `$`, classes `[a-z_]` `[^...]`, escapes
/// `\w \d \s \.`, etc., quantifiers `* + ?`, and top-level alternation `a|b`.
/// No groups with quantifiers (rare in code searches).
pub const Regex = struct {
    pattern: []const u8,

    pub fn compile(pattern: []const u8) Regex {
        return .{ .pattern = pattern };
    }

    /// Does it match at any position of `text`?
    pub fn matches(self: *const Regex, text: []const u8) bool {
        // Top-level alternation: try each branch.
        var it = BranchIter{ .p = self.pattern };
        while (it.next()) |branch| {
            if (matchBranch(branch, text)) return true;
        }
        return false;
    }

    /// Returns the end of the match that starts at `start` (for future use).
    fn matchBranch(branch: []const u8, text: []const u8) bool {
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (matchSeq(branch, 0, text, start) != null) return true;
        }
        return false;
    }
};

const BranchIter = struct {
    p: []const u8,
    i: usize = 0,
    depth: usize = 0,

    fn next(self: *BranchIter) ?[]const u8 {
        if (self.i > self.p.len) return null;
        const start = self.i;
        while (self.i < self.p.len) {
            const c = self.p[self.i];
            if (c == '[') self.depth += 1;
            if (c == ']' and self.depth > 0) self.depth -= 1;
            if (c == '\\' and self.i + 1 < self.p.len) {
                self.i += 2;
                continue;
            }
            if (c == '|' and self.depth == 0) {
                const branch = self.p[start..self.i];
                self.i += 1;
                return branch;
            }
            self.i += 1;
        }
        if (start > self.p.len) return null;
        const branch = self.p[start..self.i];
        self.i += 1; // mark the end for the next call
        return branch;
    }
};

/// Matches the sequence `p[from..]` against `text[from_text..]`.
/// Returns the end position of the match or null.
fn matchSeq(p: []const u8, from: usize, text: []const u8, from_text: usize) ?usize {
    var ti = from_text;
    var pi = from;

    // ^ anchor
    if (pi < p.len and p[pi] == '^') {
        if (ti != 0) return null;
        pi += 1;
    }
    // trailing $
    if (pi < p.len and p[pi] == '$' and pi + 1 == p.len) {
        return if (ti == text.len) ti else null;
    }

    while (pi < p.len) {
        const c = p[pi];
        if (c == '$' and pi + 1 == p.len) {
            return if (ti == text.len) ti else null;
        }

        // How wide is the atom and its quantifier?
        const atom = Atom.parse(p, pi) orelse return null;
        pi = atom.end;
        var quant = Quant.one;
        var next_pi = pi;
        if (pi < p.len) {
            if (p[pi] == '*') {
                quant = .star;
                next_pi = pi + 1;
            } else if (p[pi] == '+') {
                quant = .plus;
                next_pi = pi + 1;
            } else if (p[pi] == '?') {
                quant = .opt;
                next_pi = pi + 1;
            }
        }

        switch (quant) {
            .one => {
                if (ti >= text.len) return null;
                if (!atom.match(text[ti])) return null;
                ti += 1;
            },
            .opt => {
                if (ti < text.len and atom.match(text[ti])) {
                    // try with and without
                    if (matchSeq(p, next_pi, text, ti + 1) != null) return ti + 1;
                }
                pi = next_pi;
            },
            .star, .plus => {
                // Consume greedily as much as possible
                var count: usize = 0;
                var end = ti;
                while (end < text.len and atom.match(text[end])) : (end += 1) count += 1;
                if (quant == .plus and count == 0) return null;
                // Backtrack: try the maximum count downwards
                var take = count;
                while (true) {
                    if (matchSeq(p, next_pi, text, ti + take) != null) return ti + take;
                    if (take == 0) return null;
                    take -= 1;
                }
            },
        }
        pi = next_pi;
    }
    return ti;
}

const Quant = enum { one, star, plus, opt };

const Atom = struct {
    end: usize, // index in the pattern after the atom
    kind: Kind,

    const Kind = union(enum) {
        literal: u8,
        any, // .
        class: struct { negated: bool, chars: []const u8 },
        escape: u8, // w d s W D S, or an escaped literal
    };

    fn parse(p: []const u8, at: usize) ?Atom {
        const c = p[at];
        switch (c) {
            '.' => return .{ .end = at + 1, .kind = .any },
            '\\' => {
                if (at + 1 >= p.len) return null;
                return .{ .end = at + 2, .kind = .{ .escape = p[at + 1] } };
            },
            '[' => {
                var j = at + 1;
                var negated = false;
                if (j < p.len and p[j] == '^') {
                    negated = true;
                    j += 1;
                }
                const chars_start = j;
                // a leading ']' is a literal
                if (j < p.len and p[j] == ']') j += 1;
                while (j < p.len and p[j] != ']') : (j += 1) {
                    if (p[j] == '\\' and j + 1 < p.len) j += 1;
                }
                if (j >= p.len) return null; // unterminated class
                return .{ .end = j + 1, .kind = .{ .class = .{ .negated = negated, .chars = p[chars_start..j] } } };
            },
            else => return .{ .end = at + 1, .kind = .{ .literal = c } },
        }
    }

    fn match(self: Atom, c: u8) bool {
        switch (self.kind) {
            .literal => |l| return l == c,
            .any => return c != '\n',
            .class => |cl| {
                const in = classMatch(cl.chars, c);
                return if (cl.negated) !in else in;
            },
            .escape => |e| return switch (e) {
                'w' => isWord(c),
                'W' => !isWord(c),
                'd' => c >= '0' and c <= '9',
                'D' => !(c >= '0' and c <= '9'),
                's' => c == ' ' or c == '\t' or c == '\n' or c == '\r',
                'S' => !(c == ' ' or c == '\t' or c == '\n' or c == '\r'),
                'n' => c == '\n',
                't' => c == '\t',
                else => e == c,
            },
        }
    }

    fn isWord(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    fn classMatch(chars: []const u8, c: u8) bool {
        var i: usize = 0;
        while (i < chars.len) : (i += 1) {
            // ranges a-z
            if (i + 2 < chars.len and chars[i + 1] == '-' and chars[i + 2] != ']') {
                if (c >= chars[i] and c <= chars[i + 2]) return true;
                i += 2;
                continue;
            }
            // escapes \w \d \s inside a class
            if (chars[i] == '\\' and i + 1 < chars.len) {
                const e = chars[i + 1];
                const in = switch (e) {
                    'w' => isWord(c),
                    'd' => c >= '0' and c <= '9',
                    's' => c == ' ' or c == '\t',
                    else => e == c,
                };
                if (in) return true;
                i += 1;
                continue;
            }
            if (chars[i] == c) return true;
        }
        return false;
    }
};

// ── tests ────────────────────────────────────────────────────
test "literales y anclas" {
    const re = Regex.compile("fn main");
    try std.testing.expect(re.matches("const x = 1; fn main() {}"));
    try std.testing.expect(re.matches("fn mainn")); // substring: unanchored does match
    const anchored = Regex.compile("^fn ");
    try std.testing.expect(anchored.matches("fn a() {}"));
    try std.testing.expect(!anchored.matches("x fn a() {}"));
    const end = Regex.compile("\\);$");
    try std.testing.expect(end.matches("foo());"));
    try std.testing.expect(!end.matches("foo()); x"));
}

test "clases y cuantificadores" {
    try std.testing.expect(Regex.compile("[a-z]+_id").matches("const user_id = 1;"));
    try std.testing.expect(!Regex.compile("[0-9]+x").matches("abc"));
    try std.testing.expect(Regex.compile("\\d").matches("abc123"));
    try std.testing.expect(!Regex.compile("\\d").matches("abc"));
    try std.testing.expect(Regex.compile("a.c").matches("abc"));
    try std.testing.expect(Regex.compile("a\\.c").matches("a.c"));
    try std.testing.expect(!Regex.compile("a\\.c").matches("abc"));
    try std.testing.expect(Regex.compile("colou?r").matches("color"));
    try std.testing.expect(Regex.compile("colou?r").matches("colour"));
}

test "alternación" {
    try std.testing.expect(Regex.compile("foo|bar").matches("xbarz"));
    try std.testing.expect(Regex.compile("foo|bar").matches("xfooz"));
    try std.testing.expect(!Regex.compile("foo|bar").matches("xbaz"));
}
