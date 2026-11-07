const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const styles = @import("highlight_styles.zig");
const config = @import("highlight_config.zig");
const scanner = @import("highlight_scanner.zig");
const md = @import("markdown.zig");

// ── public API ─────────────────────────────────────────────────
//
// `highlight.zig` is the entry point. The real work lives in three focused files:
//
//   - `highlight_styles.zig`   → token styles (`T`), `Kinds`, `styleFor`
//   - `highlight_config.zig`   → `Cfg`, per-language tables (`langs`), `normalizeLang`, `cfgFor`
//   - `highlight_scanner.zig`  → `State`, `StrStart`, scanner helpers, `highlightLine`, `highlightLineState`
//
// Everything below re-exports so existing callers (`markdown.zig`, `test_all.zig`,
// `test_all_tmp.zig`) keep working without changing a single import.

pub const T = styles.T;
pub const Kinds = styles.Kinds;
pub const Cfg = config.Cfg;
pub const langs = config.langs;
pub const State = struct {
    /// Inside an unclosed string.
    in_str: bool = false,
    /// Closing quote of the string in progress: `"`, `'` or `` ` ``.
    str_quote: u8 = 0,
    /// Inside an unclosed `/* … */` block comment.
    in_block: bool = false,
};
pub const StrStart = scanner.StrStart;

pub fn normalizeLang(lang: []const u8, buf: []u8) []const u8 {
    return config.normalizeLang(lang, buf);
}

pub fn cfgFor(lang: []const u8) Cfg {
    return config.cfgFor(lang);
}

pub fn styleFor(kind: Kinds) vaxis.Style {
    return styles.styleFor(kind);
}

pub fn isIdentStart(c: u8) bool {
    return scanner.isIdentStart(c);
}

pub fn isIdentChar(c: u8) bool {
    return scanner.isIdentChar(c);
}

pub fn isDigit(c: u8) bool {
    return scanner.isDigit(c);
}

pub fn lineCommentAt(line: []const u8, at: usize, prefixes: []const []const u8) ?usize {
    return scanner.lineCommentAt(line, at, prefixes);
}

pub fn stringStart(line: []const u8, at: usize, cfg: Cfg) ?scanner.StrStart {
    return scanner.stringStart(line, at, cfg);
}

pub fn findStrEnd(line: []const u8, from: usize, quote: u8) ?usize {
    return scanner.findStrEnd(line, from, quote);
}

pub fn highlightLine(
    arena: std.mem.Allocator,
    line: []const u8,
    lang: []const u8,
) ![]md.Segment {
    var st = State{};
    return highlightLineState(arena, line, lang, &st);
}

fn toMdSegs(arena: std.mem.Allocator, segs: []const scanner.Segment) ![]md.Segment {
    var out: std.ArrayList(md.Segment) = .empty;
    for (segs) |s| try out.append(arena, .{ .text = s.text, .style = s.style });
    return out.toOwnedSlice(arena);
}

pub fn highlightLineState(
    arena: std.mem.Allocator,
    line: []const u8,
    lang: []const u8,
    state: *State,
) ![]md.Segment {
    const cfg = config.cfgFor(lang);

    var segs: std.ArrayList(scanner.Segment) = .empty;
    var i: usize = 0;
    var run_start: usize = 0;

    const resume_str = state.in_str;
    const resume_block = state.in_block;
    if (resume_block) {
        const close = cfg.block_comment_end orelse "*/";
        if (std.mem.indexOf(u8, line, close)) |end| {
            try segs.append(arena, .{ .text = line[0 .. end + close.len], .style = styles.T.comment });
            run_start = end + close.len;
            i = end + close.len;
            state.in_block = false;
        } else {
            try segs.append(arena, .{ .text = line, .style = styles.T.comment });
            return toMdSegs(arena, try segs.toOwnedSlice(arena));
        }
    }
    if (resume_str) {
        const q = state.str_quote;
        const end = scanner.findStrEnd(line, 0, q);
        if (end) |e| {
            try segs.append(arena, .{ .text = line[0..e], .style = styles.T.str });
            run_start = e;
            i = e;
            state.in_str = false;
        } else {
            try segs.append(arena, .{ .text = line, .style = styles.T.str });
            return toMdSegs(arena, try segs.toOwnedSlice(arena));
        }
    }

    const flushDef = struct {
        fn f(a: std.mem.Allocator, s: *std.ArrayList(scanner.Segment), from: usize, to: usize, text: []const u8) !void {
            if (to > from) try s.append(a, .{ .text = text[from..to], .style = styles.T.def });
        }
    }.f;

    while (i < line.len) {
        // ── line comments: the rest of the line ──
        if (scanner.lineCommentAt(line, i, cfg.line_comments)) |_| {
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..], .style = styles.T.comment });
            return toMdSegs(arena, try segs.toOwnedSlice(arena));
        }

        // ── opening of a block comment ──
        if (cfg.block_comment_start) |bs| {
            if (std.mem.startsWith(u8, line[i..], bs)) {
                const close = cfg.block_comment_end orelse "*/";
                try flushDef(arena, &segs, run_start, i, line);
                if (std.mem.indexOfPos(u8, line, i + bs.len, close)) |end| {
                    try segs.append(arena, .{ .text = line[i .. end + close.len], .style = styles.T.comment });
                    i = end + close.len;
                } else {
                    try segs.append(arena, .{ .text = line[i..], .style = styles.T.comment });
                    i = line.len;
                    state.in_block = true;
                }
                run_start = i;
                continue;
            }
        }

        // ── string start ──
        if (scanner.stringStart(line, i, cfg)) |sres| {
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..sres.end], .style = styles.T.str });
            i = sres.end;
            if (sres.open) {
                state.in_str = true;
                state.str_quote = sres.quote;
                return toMdSegs(arena, try segs.toOwnedSlice(arena));
            }
            run_start = i;
            continue;
        }
        // ── numbers ──
        if (scanner.isDigit(line[i]) and (i == 0 or !scanner.isIdentChar(line[i - 1]))) {
            var j = i;
            while (j < line.len and (scanner.isIdentChar(line[j]) or line[j] == '.')) : (j += 1) {
                if (line[j] == '.' and (j + 1 >= line.len or !scanner.isDigit(line[j + 1]))) break;
            }
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..j], .style = styles.T.num });
            i = j;
            run_start = i;
            continue;
        }
        // ── @word ──
        if (line[i] == '@' and i + 1 < line.len and scanner.isIdentStart(line[i + 1])) {
            var j = i + 1;
            while (j < line.len and scanner.isIdentChar(line[j])) : (j += 1) {}
            const word = line[i..j];
            var kind: styles.Kinds = .none;
            if (config.eqAny(word, cfg.builtins)) { kind = .builtin; }
            else if (cfg.decorators) { kind = .deco; }
            if (kind != .none) {
                try flushDef(arena, &segs, run_start, i, line);
                try segs.append(arena, .{ .text = word, .style = styles.styleFor(kind) });
                run_start = j;
            }
            i = j;
            continue;
        }
        // ── identifiers ──
        if (scanner.isIdentStart(line[i])) {
            var j = i;
            while (j < line.len and scanner.isIdentChar(line[j])) : (j += 1) {}
            if (j < line.len and line[j] == '!' and config.eqAny(line[i .. j + 1], cfg.builtins)) j += 1;
            const word = line[i..j];
            var kind: styles.Kinds = .none;
            if (config.eqAny(word, cfg.control)) { kind = .kw2; }
            else if (config.eqAny(word, cfg.keywords)) { kind = .kw; }
            else if (config.eqAny(word, cfg.builtins)) { kind = .builtin; }
            else if (config.eqAny(word, cfg.types)) { kind = .typ; }
            else if (cfg.types.len > 0 and word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') { kind = .typ; }
            else {
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
                if (k < line.len and line[k] == '(') kind = .fn_call;
            }
            if (kind != .none) {
                try flushDef(arena, &segs, run_start, i, line);
                try segs.append(arena, .{ .text = word, .style = styles.styleFor(kind) });
                run_start = j;
            }
            i = j;
            continue;
        }
        i += 1;
    }

    try flushDef(arena, &segs, run_start, line.len, line);
    if (segs.items.len == 0) {
        try segs.append(arena, .{ .text = line, .style = styles.T.def });
    }

    return toMdSegs(arena, try segs.toOwnedSlice(arena));
}

pub const Style = vaxis.Style;

// ── tests ────────────────────────────────────────────────────

fn findSeg(segs: []const md.Segment, needle: []const u8) ?md.Segment {
    for (segs) |s| {
        if (std.mem.eql(u8, s.text, needle)) return s;
    }
    return null;
}

fn joinedText(arena: std.mem.Allocator, segs: []const md.Segment) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segs) |s| try out.appendSlice(arena, s.text);
    return out.items;
}

test "zig: keyword, number, comment, builtin and the text intact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "const n = @as(u8, 42); // fin";
    const segs = try highlightLine(arena, line, "zig");

    // The concatenated text must be IDENTICAL to the line (nothing is lost).
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));

    const kw = findSeg(segs, "const").?;
    try std.testing.expectEqual(theme.code_kw, kw.style);
    const num = findSeg(segs, "42").?;
    try std.testing.expectEqual(theme.code_num, num.style);
    var found_comment = false;
    for (segs) |s| {
        if (std.mem.startsWith(u8, s.text, "// fin")) found_comment = true;
    }
    try std.testing.expect(found_comment);
    const b = findSeg(segs, "@as").?;
    try std.testing.expectEqual(theme.code_builtin, b.style);
}

test "python: def kw, print builtin, self type, # comment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "def foo(self): print('hi')  # nota";
    const segs = try highlightLine(arena, line, "py");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    try std.testing.expectEqual(theme.code_kw, findSeg(segs, "def").?.style);
    try std.testing.expectEqual(theme.code_builtin, findSeg(segs, "print").?.style);
    try std.testing.expectEqual(theme.code_type, findSeg(segs, "self").?.style);
}

test "shell: cyan builtin and # comment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "grep foo file.txt # buscar";
    const segs = try highlightLine(arena, line, "sh");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    try std.testing.expectEqual(theme.code_builtin, findSeg(segs, "grep").?.style);
}

test "unknown lang: safe fallback without a crash and the text intact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "weird || syntax @x \"str\"";
    const segs = try highlightLine(arena, line, "langinventada");
    try std.testing.expect(segs.len >= 1);
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
}

test "a string with an escape and no closing does not crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "const s = \"a\\\"b";
    const segs = try highlightLine(arena, line, "zig");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
}

test "a C block comment on one line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "int x = 1; /* bloque */ y = 2;";
    const segs = try highlightLine(arena, line, "c");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    var found = false;
    for (segs) |s| {
        if (std.mem.eql(u8, s.text, "/* bloque */")) found = true;
    }
    try std.testing.expect(found);
}

test "an empty line and spaces only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e = try highlightLine(arena, "", "zig");
    try std.testing.expectEqual(@as(usize, 1), e.len);
    const w = try highlightLine(arena, "   ", "zig");
    try std.testing.expectEqualStrings("   ", try joinedText(arena, w));
}

test "a multiline string does not paint the rest of the block green" {
    // 4.8 of the ROADMAP. The scanner went line by line with no state, so a `\`
    // in Zig or an unclosed quote made the next line come out
    // ENTIRELY green (and sometimes the rest of the file).
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var st = State{};
    // Line 1: opens a multiline string and does NOT close it. The real case is a
    // trailing `\\` in Zig (line continuation) or an unbalanced quote
    // in a long file.
    const l1 = try highlightLineState(arena, "const s = \"hola", "zig", &st);
    try std.testing.expect(st.in_str);
    try std.testing.expectEqualStrings("const s = \"hola", try joinedText(arena, l1));

    // Line 2: still inside the string until it closes.
    const l2 = try highlightLineState(arena, "  mundo\";", "zig", &st);
    try std.testing.expect(!st.in_str); // the " here closed it
    try std.testing.expectEqualStrings("  mundo\";", try joinedText(arena, l2));

    // Line 3: it is normal code again (the string closed in line 2).
    const l3 = try highlightLineState(arena, "const n = 1;", "zig", &st);
    try std.testing.expectEqualStrings("const n = 1;", try joinedText(arena, l3));
    if (findSeg(l3, "const")) |kw| try std.testing.expectEqual(T.kw, kw.style);
}

test "a multiline block comment does not leak either" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var st = State{};
    const l1 = try highlightLineState(arena, "/* abre", "c", &st);
    try std.testing.expect(st.in_block);
    for (l1) |s| try std.testing.expectEqual(T.comment, s.style);

    const l2 = try highlightLineState(arena, "sigue comentario", "c", &st);
    for (l2) |s| try std.testing.expectEqual(T.comment, s.style);
    try std.testing.expect(st.in_block);

    const l3 = try highlightLineState(arena, "*/ const n = 1;", "c", &st);
    try std.testing.expect(!st.in_block);
    try std.testing.expectEqualStrings("*/ const n = 1;", try joinedText(arena, l3));
}

test "the state resets between different fences" {
    // If a block ends with an open string, the NEXT fence must not
    // stay green by dragging the state along.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var st = State{};
    _ = try highlightLineState(arena, "const s = \"", "zig", &st);
    try std.testing.expect(st.in_str);
    st = .{}; // new fence
    const l = try highlightLineState(arena, "const n = 1;", "zig", &st);
    // None of this line is string: `const` is a keyword and the rest is text.
    try std.testing.expect(findSeg(l, "const") != null);
    if (findSeg(l, "const")) |kw| try std.testing.expectEqual(T.kw, kw.style);
}
