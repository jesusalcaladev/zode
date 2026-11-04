//! Verify that an agent in the pipeline did not delete or weaken a test that
//! existed when its stage began.
//!
//! ## Why this is a guard and not a prompt
//!
//! A model told "do not modify the tests" will occasionally do it anyway —
//! usually with the best of intentions ("the test was wrong", "simplify") and
//! occasionally by accident when it rewrites a file. A prompt is not a control,
//! so the control lives here: before a stage that writes (Implementer, Tester)
//! the harness scans every Zig file it is about to touch and records every
//! test by (file, name, body-hash). After the stage it scans again. Anything
//! missing or changed is reported by name, and the harness stops pretending
//! the work is done.
//!
//! The scope is Zig on purpose: zode is a Zig project and its tests are
//! top-level `test "..."` blocks, which this scanner understands exactly.
//! Other languages rely on the path rule (test files) enforced by the tool
//! layer, not on this file.

const std = @import("std");

pub const Entry = struct {
    /// The exact text between the quotes in `test "name" {`.
    name: []const u8,
    /// FNV-1a-64 of everything inside the block's braces, comments included.
    hash: u64,
};

pub const Report = struct {
    /// Baseline tests whose NAMES are absent in the new text.
    missing: [][]const u8,
    /// Baseline tests whose name exists but whose body differs.
    changed: [][]const u8,

    pub fn ok(self: Report) bool {
        return self.missing.len == 0 and self.changed.len == 0;
    }
};

/// Scan Zig source for `test "..."` blocks. Tests in this repo are top-level,
/// with the opening brace on the same line as the `test` keyword — anything
/// else is not a test the harness promised to protect.
pub fn scan(arena: std.mem.Allocator, text: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        if (parseTestLine(line)) |name| {
            // Search for the block's brace AFTER the name's closing quote,
            // on the same line: a `{` inside the name (or on a later line,
            // a style this scanner does not support) must not match here.
            const open_brace = blockOpenBrace(text, i, nl) orelse {
                i = @min(nl + 1, text.len);
                continue;
            };
            const close_brace = findClose(text, open_brace) orelse return error.MalformedSource;
            try entries.append(arena, .{
                .name = try arena.dupe(u8, name),
                .hash = fnv1a64(text[open_brace + 1 .. close_brace]),
            });
            i = close_brace + 1;
            continue;
        }
        i = @min(nl + 1, text.len);
    }
    return entries.toOwnedSlice(arena);
}

/// Compare a baseline scan with the current text. Both slices must come from
/// scans of the SAME file.
pub fn verify(
    arena: std.mem.Allocator,
    before: []const Entry,
    new_text: []const u8,
) !Report {
    const after = try scan(arena, new_text);
    var missing: std.ArrayList([]const u8) = .empty;
    var changed: std.ArrayList([]const u8) = .empty;
    for (before) |e| {
        const f = find(after, e.name) orelse {
            try missing.append(arena, e.name);
            continue;
        };
        if (f.hash != e.hash) try changed.append(arena, e.name);
    }
    return .{
        .missing = try missing.toOwnedSlice(arena),
        .changed = try changed.toOwnedSlice(arena),
    };
}

fn find(entries: []const Entry, name: []const u8) ?Entry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// `test "name"` on a line, with any indent. "testimony of" does not match:
/// the word after `test` has to be a quoted string.
fn parseTestLine(line: []const u8) ?[]const u8 {
    var s = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, s, "test")) return null;
    s = s["test".len..];
    if (s.len == 0 or (s[0] != ' ' and s[0] != '\t')) return null;
    s = std.mem.trimStart(u8, s, " \t");
    if (s.len < 2 or s[0] != '"') return null;
    const rest = s[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

/// The opening brace of a `test "name" {` block, on the same line, with the
/// name's escapes honoured. Returns null when there is no brace on the line
/// (an unsupported style, which is skipped, not a crash).
fn blockOpenBrace(text: []const u8, line_start: usize, nl: usize) ?usize {
    var j = line_start;
    // Skip to the opening quote of the name.
    while (j < nl and text[j] != '"') : (j += 1) {}
    if (j >= nl) return null;
    j += 1;
    // The name, with escapes honoured.
    while (j < nl) : (j += 1) {
        const c = text[j];
        if (c == '\\') {
            j += 1;
            continue;
        }
        if (c == '"') break;
    }
    if (j >= nl) return null;
    j += 1;
    // The brace, still on the same line. A comment before it ends the
    // supported shape.
    while (j < nl) : (j += 1) {
        const c = text[j];
        if (c == '/' and j + 1 < nl and text[j + 1] == '/') return null;
        if (c == '{') return j;
    }
    return null;
}

/// The closing brace matching the one at `from`, with Zig's lexical rules for
/// strings, char literals, line comments, nesting block comments and
/// multiline string literals (`\\foo`) applied so braces inside any of them
/// do not affect the depth.
fn findClose(text: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    var i = from + 1;
    var at_line_start = true;
    while (i < text.len) : (i += 1) {
        const c = text[i];

        if (at_line_start) {
            at_line_start = false;
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t')) : (j += 1) {}
            if (j + 1 < text.len and text[j] == '\\' and text[j + 1] == '\\') {
                // Multiline string literal: skip to the end of the line but
                // keep `at_line_start` for its newline.
                i = j;
                while (i < text.len and text[i] != '\n') : (i += 1) {}
                if (i >= text.len) return null;
                at_line_start = true;
                // Outer `i += 1` moves past the newline, and `at_line_start`
                // is already set for the next line.
                continue;
            }
        }

        switch (c) {
            '\n' => {
                at_line_start = true;
                continue;
            },
            '"' => {
                i = skipDobleQuote(text, i) orelse return null;
                continue;
            },
            '\'' => {
                i = skipSingleQuote(text, i) orelse return null;
                continue;
            },
            '/' => {
                if (i + 1 < text.len and text[i + 1] == '/') {
                    // Land ON the newline; the outer `i += 1` moves past it,
                    // so mark the next line start here.
                    i = skipToNewline(text, i);
                    at_line_start = true;
                    continue;
                }
                if (i + 1 < text.len and text[i + 1] == '*') {
                    i = skipBlockComment(text, i) orelse return null;
                    continue;
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn skipDobleQuote(text: []const u8, from: usize) ?usize {
    var i = from + 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '"') return i;
        if (c == '\n') return null; // unterminated string
    }
    return null;
}

fn skipSingleQuote(text: []const u8, from: usize) ?usize {
    var i = from + 1;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\'') return i;
        if (c == '\n') return null;
    }
    return null;
}

fn skipToNewline(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') return i;
    }
    return text.len;
}

fn skipBlockComment(text: []const u8, from: usize) ?usize {
    var depth: usize = 1;
    var i = from + 2;
    while (i < text.len) {
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            depth += 1;
            i += 2;
            continue;
        }
        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '/') {
            depth -= 1;
            // Return the index of the '/' in the closer; the outer loop's
            // `i += 1` lands past the comment.
            if (depth == 0) return i + 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    return null;
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |b| {
        hash ^= b;
        hash *%= 1099511628211;
    }
    return hash;
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "scan: finds top-level tests and hashes their bodies" {
    const src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\fn helper() void {}
        \\
        \\test "beta" {
        \\    try std.testing.expectEqualStrings("a{b}", "a{b}");
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const entries = try scan(arena_state.allocator(), src);
    try t.expectEqual(@as(usize, 2), entries.len);
    try t.expectEqualStrings("alpha", entries[0].name);
    try t.expectEqualStrings("beta", entries[1].name);
}

test "scan: braces in strings, comments and multiline strings do not unbalance" {
    const src =
        \\test "strings" {
        \\    const s = "not { a brace";
        \\    // a brace in a comment: {
        \\    /* block with { brace } and /* nested */ comment */
        \\    const raw =
        \\        \\\\also { not } balanced
        \\        \\\\end
        \\    ;
        \\    try std.testing.expect(s.len > 0);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const entries = try scan(arena_state.allocator(), src);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expectEqualStrings("strings", entries[0].name);
}

test "verify: ok when nothing changed" {
    const src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const before = try scan(a, src);
    const report = try verify(a, before, src);
    try t.expect(report.ok());
    try t.expectEqual(@as(usize, 0), report.missing.len);
    try t.expectEqual(@as(usize, 0), report.changed.len);
}

test "verify: a changed body is reported by name" {
    const before_src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
    ;
    const after_src =
        \\test "alpha" {
        \\    try std.testing.expect(false);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const before = try scan(a, before_src);
    const report = try verify(a, before, after_src);
    try t.expect(!report.ok());
    try t.expectEqual(@as(usize, 1), report.changed.len);
    try t.expectEqualStrings("alpha", report.changed[0]);
}

test "verify: a deleted test is reported by name" {
    const before_src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test "beta" {
        \\    try std.testing.expect(true);
        \\}
    ;
    const after_src =
        \\test "beta" {
        \\    try std.testing.expect(true);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const before = try scan(a, before_src);
    const report = try verify(a, before, after_src);
    try t.expect(!report.ok());
    try t.expectEqual(@as(usize, 1), report.missing.len);
    try t.expectEqualStrings("alpha", report.missing[0]);
}

test "verify: added tests are fine" {
    const before_src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
    ;
    const after_src =
        \\test "alpha" {
        \\    try std.testing.expect(true);
        \\}
        \\
        \\test "new one" {
        \\    try std.testing.expect(false == false);
        \\}
    ;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const before = try scan(a, before_src);
    const report = try verify(a, before, after_src);
    try t.expect(report.ok());
}

test "parseTestLine: testimony does not open a test" {
    try t.expect(parseTestLine("testimony \"not a test\" {") == null);
    try t.expect(parseTestLine("test \"real\" {") != null);
    try t.expect(parseTestLine("    test \"indented\" {") != null);
    try t.expect(parseTestLine("testx \"no\" {") == null);
}
