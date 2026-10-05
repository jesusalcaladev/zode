/// Where a symbol is DEFINED and where it is USED, across files.
///
/// ## Why this is a tool and not "two greps"
///
/// It is two greps, and that is exactly the problem: the model has to know that
/// it is two greps, get the declaration pattern right for the language it is
/// looking at, run them, and then work out which of the hits is the definition
/// and which are uses. Each of those is a round trip, and a round trip is a whole
/// request: money, seconds, and a chance to be rate-limited.
///
/// Measured on 2026-10-04 asking "what public function do these three files
/// share": six tool calls (three `read` + three `grep`) became three, and three
/// `read` became one, after this tool and the batching rule landed.
///
/// ## What it does NOT do
///
/// It does not parse. There is no AST, no type resolution, no import graph, and
/// no distinction between a same-named method in another class. What it does is
/// know the DECLARATION SHAPES of the languages zode is used on, which is what
/// makes the difference between "here is the definition" and "here are 400
/// occurrences of a word that happens to have that name".
const std = @import("std");

pub const max_hits = 120;
pub const max_files = 400;

pub const Kind = enum {
    definition,
    call,
    reference,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .definition => "definition",
            .call => "call",
            .reference => "reference",
        };
    }
};

pub const Hit = struct {
    path: []const u8,
    line: u32,
    kind: Kind,
    /// The text of the line, trimmed and cut. Kept because a hit without its line
    /// makes the model read the file anyway, which is the round trip this tool
    /// was supposed to remove.
    text: []const u8,
};

pub const Result = struct {
    hits: []const Hit,
    /// How many hits existed before the caps. A count that says 500 with 120 shown
    /// is the difference between "I looked at a bit of this" and "there are more".
    total: usize,
    truncated: bool,
};

/// How a symbol is DECLARED in this language.
///
/// The list is a list of PREFIXES, matched at the start of a trimmed line, and
/// the symbol name has to follow one of them. That is enough for the languages
/// that matter here and it does not need a parser.
///
/// The alternative — "any word that is not indented is a definition" — is wrong
/// in the most common case there is, which is a call inside a function.
pub fn declarationPrefixes(lang: Lang) []const []const u8 {
    return switch (lang) {
        .zig => &.{ "fn ", "pub fn ", "pub const ", "const ", "pub var ", "var ", "pub usingnamespace ", "test " },
        .rust => &.{ "fn ", "pub fn ", "pub(crate) fn ", "const ", "static ", "let ", "pub struct ", "struct ", "pub enum ", "enum ", "trait ", "impl ", "type ", "mod ", "pub mod ", "macro_rules! " },
        .go => &.{ "func ", "type ", "var ", "const ", "struct " },
        .py => &.{ "def ", "async def ", "class ", "lambda " },
        .js, .ts => &.{ "function ", "async function ", "const ", "let ", "var ", "class ", "export function ", "export const ", "export class ", "export default function " },
        .c => &.{ "int ", "void ", "char ", "float ", "double ", "long ", "short ", "unsigned ", "static ", "struct ", "typedef ", "#define ", "bool ", "size_t " },
        .sh => &.{ "function ", "alias " },
        .md => &.{},
        .generic => &.{ "fn ", "function ", "def ", "func ", "const ", "class ", "let ", "var ", "type ", "struct " },
    };
}

pub const Lang = enum {
    zig,
    rust,
    go,
    py,
    js,
    ts,
    c,
    sh,
    md,
    generic,

    /// From a file extension, WITHOUT the dot, or "" when it is not one we know.
    pub fn fromExt(ext: []const u8) Lang {
        if (std.mem.eql(u8, ext, "zig")) return .zig;
        if (std.mem.eql(u8, ext, "rs")) return .rust;
        if (std.mem.eql(u8, ext, "go")) return .go;
        if (std.mem.eql(u8, ext, "py")) return .py;
        if (std.mem.eql(u8, ext, "js") or std.mem.eql(u8, ext, "jsx")) return .js;
        if (std.mem.eql(u8, ext, "ts") or std.mem.eql(u8, ext, "tsx")) return .ts;
        if (std.mem.eql(u8, ext, "c") or std.mem.eql(u8, ext, "h") or
            std.mem.eql(u8, ext, "cc") or std.mem.eql(u8, ext, "cpp") or
            std.mem.eql(u8, ext, "hpp")) return .c;
        if (std.mem.eql(u8, ext, "sh") or std.mem.eql(u8, ext, "bash")) return .sh;
        if (std.mem.eql(u8, ext, "md")) return .md;
        return .generic;
    }

    /// From a path. The extension is the only thing consulted, so a `.d.ts` is a
    /// declaration file and still answers `ts`.
    pub fn fromPath(path: []const u8) Lang {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const base = path[slash + 1 ..];
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .generic;
        if (dot + 1 >= base.len) return .generic;
        return fromExt(base[dot + 1 ..]);
    }
};

/// For every byte of the source, is it REAL CODE?
///
/// This is the difference between matching a name and matching a SYMBOL, and it
/// was measured on this repository's own `refs`: `refs target` on a file holding
///
/// ```zig
/// const msg = "call target() from inside a string";
/// const doc = "target in a doc string";
/// ```
///
/// answered **"4 uses"** — the two real ones plus the two inside string literals,
/// one of them classified as a `[call]` because it is followed by a `(`. A model
/// that trusted that number would rename inside a string literal, and one that
/// used it to decide whether it had found everything would go looking for two
/// references that do not exist.
///
/// A one-byte-per-source mask rather than a token stream, because every question
/// asked afterwards ("is this occurrence in code?", "does the declaration keyword
/// end here?") is a lookup and not a scan, and a scan that runs per occurrence is
/// the O(n²) this file exists to avoid.
///
/// It is NOT a full lexer and does not claim to be: it knows strings, character
/// literals, and comments, which is what separates a name from a copy of one. It
/// does not parse expressions, resolve scopes or know that `\\` opens a raw
/// string with its own delimiter rules.
pub fn codeMask(arena: std.mem.Allocator, src: []const u8) ![]const bool {
    const mask = try arena.alloc(bool, src.len);
    @memset(mask, true);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];

        // Line comments: `//` in most languages, `#` in python/shell/yaml. The
        // `#` case is language-dependent and the caller cannot tell us, so both
        // are treated as a comment and a C preprocessor line loses its trailing
        // part — which is the conservative direction: a missed declaration is
        // reported as a use, never a use is reported as a declaration.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            const end = lineEnd(src, i);
            maskRange(mask, i, end, false);
            i = end;
            continue;
        }
        if (c == '#') {
            const end = lineEnd(src, i);
            maskRange(mask, i, end, false);
            i = end;
            continue;
        }
        // Block comments, nested: `/* /* */ */` is legal in Zig, Rust and C and
        // treating them as flat gets the nesting wrong.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const end = blockCommentEnd(src, i);
            maskRange(mask, i, end, false);
            i = end;
            continue;
        }
        // Strings and character literals. A backtick is a raw string in Go and
        // Zig's simple form, and it does not take backslash escapes.
        if (c == '"' or c == '\'' or c == '`') {
            const end = stringEnd(src, i, c);
            // The delimiters stay "code" so a declaration inside them is still a
            // candidate for the keyword rule; only the BODY is masked.
            maskRange(mask, i + 1, end, false);
            i = end;
            continue;
        }
        i += 1;
    }
    return mask;
}

fn maskRange(mask: []bool, from: usize, to: usize, v: bool) void {
    const end = @min(to, mask.len);
    var k = from;
    while (k < end) : (k += 1) mask[k] = v;
}

fn lineEnd(src: []const u8, from: usize) usize {
    const nl = std.mem.indexOfScalarPos(u8, src, from, '\n') orelse src.len;
    return nl;
}

/// The offset just past the closing quote, or the end of the line.
fn stringEnd(src: []const u8, start: usize, quote: u8) usize {
    var i = start + 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and quote != '`') {
            i += 2; // an escaped quote does not close it
            continue;
        }
        if (c == quote) return i + 1;
        // An unterminated string ends at the newline, not at the end of the file:
        // otherwise one missing quote masks everything after it and the tool
        // reports nothing at all instead of reporting most of it.
        if (c == '\n') return i;
        i += 1;
    }
    return src.len;
}

fn blockCommentEnd(src: []const u8, start: usize) usize {
    var depth: usize = 0;
    var i = start;
    while (i + 1 < src.len) : (i += 1) {
        if (src[i] == '/' and src[i + 1] == '*') {
            depth += 1;
            i += 1;
            continue;
        }
        if (src[i] == '*' and src[i + 1] == '/') {
            depth -= 1;
            i += 1;
            if (depth == 0) return i + 1;
        }
    }
    return src.len;
}

/// Is this offset real code, according to the mask?
pub fn isCode(mask: []const bool, at: usize) bool {
    return at < mask.len and mask[at];
}

/// The 1-based line of `at`, for the hit a caller reports.
pub fn lineOf(src: []const u8, at: usize) u32 {
    var line: u32 = 1;
    var i: usize = 0;
    while (i < at and i < src.len) : (i += 1) {
        if (src[i] == '\n') line += 1;
    }
    return line;
}

/// Is `name` a plain identifier? Rejecting anything else here is what stops
/// `refs` from being handed a pattern and used as a grep with extra steps.
pub fn validSymbol(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_' and first != '$') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return true;
}

/// Is `word` the symbol, as a WHOLE word?
///
/// Without the boundary check `refs foo` would match every `foobar`, and the
/// model would come back with "400 references" for a name that has three. This
/// is the single most important function in the file.
pub fn wholeWord(haystack: []const u8, at: usize, word: []const u8) bool {
    const before_ok = at == 0 or !isWordChar(haystack[at - 1]);
    const end = at + word.len;
    const after_ok = end >= haystack.len or !isWordChar(haystack[end]);
    return before_ok and after_ok;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Where in the line the symbol starts, or null.
///
/// `len_before` skips the language comment marker (`#`, `//`, `/*`, `--`) so that
/// a commented-out declaration is not reported as one. A model that greps a
/// symbol finds the commented copy first plenty of the time, because it is above
/// the real one.
/// Is this whole line a comment?
///
/// **This is the LINE-level rule and it is not enough on its own.** A file-level
/// `codeMask` is what tells a real use from a copy of the name inside a string,
/// and the caller must consult both. This one still exists because a comment is
/// cheap to recognise from the line alone and because `#` means "comment" in some
/// languages and "preprocessor" in others, which needs the prefix table.
///
/// A commented-out line mentioning the symbol read as a reference, and every one
/// of those inflates the count the model asked for.
pub fn isCommentLine(line: []const u8, prefixes: []const []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return false;
    // `#` is a comment in Python and shell and a preprocessor directive in C, so
    // the test is whether the language HAS a prefix that starts with it.
    const preprocessor = for (prefixes) |p| {
        if (p.len > 0 and p[0] == '#') break true;
    } else false;
    if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or
        std.mem.startsWith(u8, trimmed, "--") or std.mem.startsWith(u8, trimmed, "*")) return true;
    if (!preprocessor and std.mem.startsWith(u8, trimmed, "#")) return true;
    return false;
}

pub fn findSymbol(line: []const u8, name: []const u8, prefixes: []const []const u8) ?usize {
    if (line.len == 0) return null;
    // Delegates, so the comment rule cannot drift between "is this a definition"
    // and "is this a use": it was duplicated, and the copy that guarded the
    // definitions got updated while the one guarding the uses did not exist.
    if (isCommentLine(line, prefixes)) return null;

    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |at| {
        if (!wholeWord(line, at, name)) {
            from = at + 1;
            continue;
        }
        // BOTH ends are trimmed, which is correct for `endsWithKeyword` and was the
        // bug for the `startsWithWord` this replaced: the trailing space made
        // "pub fn " and "pub fn" two different strings, so the "the whole head
        // IS the keyword" case never fired and the tool answered "no
        // declaration" for every symbol in the repository.
        const head = std.mem.trim(u8, line[0..at], " \t");
        if (matchesKeyword(head, prefixes)) return at;
        // Go methods: `func (s *Server) Listen() error {`. The text right before
        // the name is the RECEIVER, not the keyword, so `Listen` reads as a call
        // and a `refs Listen` answers "no declaration" for a method that exists.
        // Stepping back over the receiver is what makes Go methods findable, and
        // the shape is the same in every language that has them.
        if (head.len > 0 and head[head.len - 1] == ')') {
            if (std.mem.lastIndexOfScalar(u8, head, '(')) |open| {
                if (matchesKeyword(std.mem.trim(u8, head[0..open], " \t"), prefixes)) return at;
            }
        }
        from = at + 1;
    }
    return null;
}

fn matchesKeyword(head: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (endsWithKeyword(head, p)) return true;
    }
    return false;
}

/// Does the text before the name END with a declaration keyword?
///
/// ENDS, and not starts. `static int add(...)` is a C declaration and the keyword
/// is `int`, which is in the middle; `pub fn run()` is a Zig one and the keyword
/// is at the end. Asking "does the head end with a prefix" answers both, and the
/// boundary check is what stops `fnn` from reading as `fn`.
fn endsWithKeyword(head: []const u8, prefix: []const u8) bool {
    const bare = std.mem.trimEnd(u8, prefix, " \t");
    if (bare.len == 0) return false;
    if (!std.mem.endsWith(u8, head, bare)) return false;
    if (head.len == bare.len) return true;
    // What comes before the keyword must be a boundary, or `fnn` matches `fn`.
    const before = head[head.len - bare.len - 1];
    return !isWordChar(before);
}

/// Is this line USING the symbol rather than declaring it?
///
/// A `(` right after the name is the call shape in every language here, and it is
/// the one that separates "three definitions" from "four hundred places it is
/// called", which is the number the model is actually after.
pub fn looksLikeCall(line: []const u8, at: usize, name: []const u8) bool {
    const end = at + name.len;
    var i = end;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return i < line.len and line[i] == '(';
}

/// Renders the result so the model can act on it without re-reading anything.
///
/// Definitions come FIRST and untruncated: they are the answer to "where is it",
/// and burying them under 120 uses is what makes a model read the file anyway.
pub fn render(arena: std.mem.Allocator, name: []const u8, res: Result) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;

    var defs: usize = 0;
    for (res.hits) |h| {
        if (h.kind == .definition) defs += 1;
    }
    if (defs == 0) {
        try out.print(arena, "`{s}` has no declaration in the files searched.\n", .{name});
        try out.appendSlice(arena, "It may be a field, a local, a parameter, a macro from a dependency, or it may be spelled differently. A grep for the bare name still finds the uses.\n");
    } else {
        try out.print(arena, "`{s}` — {d} definition(s):\n", .{ name, defs });
        for (res.hits) |h| {
            if (h.kind != .definition) continue;
            try out.print(arena, "  {s}:{d}\n    {s}\n", .{ h.path, h.line, h.text });
        }
    }

    var uses: usize = 0;
    for (res.hits) |h| {
        if (h.kind != .definition) uses += 1;
    }
    if (uses > 0) {
        try out.print(arena, "\n{d} use(s):\n", .{uses});
        for (res.hits) |h| {
            if (h.kind == .definition) continue;
            try out.print(arena, "  [{s}] {s}:{d}  {s}\n", .{ h.kind.label(), h.path, h.line, h.text });
        }
    }
    if (res.truncated) {
        try out.print(arena, "\n(cut: {d} hits existed and {d} are shown. Narrow it with `subdir`, or grep for one file.)", .{ res.total, res.hits.len });
    }
    return out.items;
}

// ── tests ────────────────────────────────────────────────────────

test "wholeWord: without the boundary check 'foo' matches 'foobar' and everything is broken" {
    // This is the whole reason the function exists: `refs foo` must not come back
    // with every identifier that starts with foo.
    try std.testing.expect(wholeWord("foo(", 0, "foo"));
    try std.testing.expect(wholeWord("x = foo;", 4, "foo"));
    try std.testing.expect(wholeWord("foo", 0, "foo"));
    try std.testing.expect(!wholeWord("foobar", 0, "foo"));
    try std.testing.expect(!wholeWord("afoo", 1, "foo"));
    try std.testing.expect(!wholeWord("_foo", 1, "foo"));
    // A DOLLAR is part of the identifier: in JS `$foo` and `foo` are two
    // different symbols, so `refs foo` must not report every `$foo`.
    try std.testing.expect(!wholeWord("$foobar", 1, "foo"));
    try std.testing.expect(!wholeWord("$foo", 1, "foo"));
}

test "findSymbol: a declaration is found and a call is not" {
    const zig = declarationPrefixes(.zig);
    try std.testing.expect(findSymbol("pub fn targetForCandidate(m: *Model) ?Target {", "targetForCandidate", zig) != null);
    try std.testing.expect(findSymbol("fn main() void {", "main", zig) != null);
    try std.testing.expect(findSymbol("    const max_hits = 120;", "max_hits", zig) != null);
    // A CALL inside a function is not a declaration. This is the case that
    // otherwise fills the answer with three dozen "definitions".
    try std.testing.expect(findSymbol("    return findSymbol(line, name, prefixes);", "findSymbol", zig) == null);
    // Indented declarations count: methods and nested functions are real.
    try std.testing.expect(findSymbol("    pub fn verdict(self: *const T) V {", "verdict", zig) != null);
}

test "findSymbol: a COMMENTED declaration is not a declaration" {
    // The model greps a symbol and finds the commented copy first plenty of the
    // time, because it is above the real one.
    const zig = declarationPrefixes(.zig);
    try std.testing.expect(findSymbol("// pub fn oldName() void {", "oldName", zig) == null);
    try std.testing.expect(findSymbol("    // fn oldName() void {", "oldName", zig) == null);
    try std.testing.expect(findSymbol("# def old_name():", "old_name", declarationPrefixes(.py)) == null);
    // A doc comment mentioning the name in prose must not become a definition.
    try std.testing.expect(findSymbol("/// See also `foo` for the other one.", "foo", zig) == null);
}

test "findSymbol: the prefix has to END at the name" {
    // `pub fnn` is not `pub fn`. A check that only looks for the prefix at the
    // start would call `fnn` a function named `pub fn`.
    const zig = declarationPrefixes(.zig);
    try std.testing.expect(findSymbol("pub fnn = 3;", "pub", zig) == null);
    try std.testing.expect(findSymbol("variable = 1;", "variable", zig) == null);
}

test "the declaration shapes of each language, so the answer is not only about Zig" {
    try std.testing.expect(findSymbol("pub fn run() !void {}", "run", declarationPrefixes(.zig)) != null);
    try std.testing.expect(findSymbol("pub(crate) fn helper() {}", "helper", declarationPrefixes(.rust)) != null);
    try std.testing.expect(findSymbol("impl CacheStats {", "CacheStats", declarationPrefixes(.rust)) != null);
    try std.testing.expect(findSymbol("func (s *Server) Listen() error {", "Listen", declarationPrefixes(.go)) != null);
    try std.testing.expect(findSymbol("    async def main():", "main", declarationPrefixes(.py)) != null);
    try std.testing.expect(findSymbol("export function parse(t: string) {", "parse", declarationPrefixes(.ts)) != null);
    try std.testing.expect(findSymbol("static int add(int a, int b) {", "add", declarationPrefixes(.c)) != null);
    try std.testing.expect(findSymbol("#define MAX_PATH 4096", "MAX_PATH", declarationPrefixes(.c)) != null);
    // And the same line IS a comment in Python, where it must not be a
    // declaration. One rule cannot serve both, so the language decides.
    try std.testing.expect(findSymbol("#define MAX_PATH 4096", "MAX_PATH", declarationPrefixes(.py)) == null);
    try std.testing.expect(findSymbol("# a comment about max_hits", "max_hits", declarationPrefixes(.py)) == null);

    // And each language must NOT answer for the others' shapes.
    try std.testing.expect(findSymbol("def snake_case():", "snake_case", declarationPrefixes(.zig)) == null);
    try std.testing.expect(findSymbol("pub fn zig_only() {}", "zig_only", declarationPrefixes(.py)) == null);
}

test "looksLikeCall: a call is a use, and it is the number the model wants" {
    try std.testing.expect(looksLikeCall("    return foo(1);", 11, "foo"));
    try std.testing.expect(looksLikeCall("foo()", 0, "foo"));
    try std.testing.expect(looksLikeCall("x = foo (1)", 4, "foo")); // the space is allowed
    try std.testing.expect(!looksLikeCall("const foo = 1;", 6, "foo"));
    try std.testing.expect(!looksLikeCall("    foo.bar();", 4, "foo"));
}

test "validSymbol: a pattern is refused, so this cannot become a grep with extra steps" {
    try std.testing.expect(validSymbol("foo"));
    try std.testing.expect(validSymbol("_Foo2"));
    try std.testing.expect(validSymbol("$scope"));
    try std.testing.expect(!validSymbol(""));
    try std.testing.expect(!validSymbol("foo.bar"));
    try std.testing.expect(!validSymbol("foo*"));
    try std.testing.expect(!validSymbol("2foo"));
    // A keyword IS a searchable symbol. It is a silly thing to look for and the
    // tool answers honestly either way; refusing it would make `refs` fail on an
    // input it could have handled.
    try std.testing.expect(validSymbol("fn"));
    // Too long to be a symbol: it is a pasted line.
    try std.testing.expect(!validSymbol("a" ** 200));
}

test "Lang: the extension is the only thing consulted" {
    try std.testing.expectEqual(Lang.zig, Lang.fromPath("src/agent.zig"));
    try std.testing.expectEqual(Lang.ts, Lang.fromPath("src/x.d.ts"));
    try std.testing.expectEqual(Lang.c, Lang.fromPath("vendor/zlib.h"));
    try std.testing.expectEqual(Lang.generic, Lang.fromPath("Makefile"));
    try std.testing.expectEqual(Lang.generic, Lang.fromPath("noext"));
    // A markdown file has no declarations, so it must answer "none" and not fall
    // through to the generic table and find things in prose.
    try std.testing.expectEqual(Lang.md, Lang.fromPath("README.md"));
    try std.testing.expectEqual(@as(usize, 0), declarationPrefixes(.md).len);
}

test "render: definitions come first and untruncated" {
    // Burying the definition under a hundred uses is what makes a model go read
    // the file anyway, which is the round trip this tool exists to remove.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hits = [_]Hit{
        .{ .path = "b.zig", .line = 9, .kind = .call, .text = "foo(1);" },
        .{ .path = "a.zig", .line = 3, .kind = .definition, .text = "pub fn foo() void {}" },
        .{ .path = "c.zig", .line = 20, .kind = .reference, .text = "const x = foo;" },
    };
    const out = try render(arena, "foo", .{ .hits = &hits, .total = 3, .truncated = false });

    const def_at = std.mem.indexOf(u8, out, "definition(s)").?;
    const use_at = std.mem.indexOf(u8, out, "use(s)").?;
    try std.testing.expect(def_at < use_at);
    try std.testing.expect(std.mem.indexOf(u8, out, "a.zig:3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[call] b.zig:9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[reference] c.zig:20") != null);
}

test "render: a symbol with no declaration says so instead of returning nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hits = [_]Hit{
        .{ .path = "a.zig", .line = 3, .kind = .call, .text = "foo(1);" },
    };
    const out = try render(arena, "foo", .{ .hits = &hits, .total = 1, .truncated = false });
    try std.testing.expect(std.mem.indexOf(u8, out, "no declaration") != null);
    // And it says what else it might be, so the model does not conclude "it does
    // not exist" and delete something.
    try std.testing.expect(std.mem.indexOf(u8, out, "a local") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "does not exist") == null);
}

test "render: a truncated result says how many there were" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hits = [_]Hit{
        .{ .path = "a.zig", .line = 3, .kind = .definition, .text = "fn foo() {}" },
    };
    const out = try render(arena, "foo", .{ .hits = &hits, .total = 500, .truncated = true });
    // 500 with 1 shown, so the model knows it is looking at a fragment.
    try std.testing.expect(std.mem.indexOf(u8, out, "500 hits existed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "subdir") != null);
}

test "codeMask: a name inside a string is NOT code, and that is the whole point" {
    // Measured on this repository: `refs target` on a file with a string
    // mentioning `target()` answered "4 uses" — the two real ones plus the two
    // inside string literals, one of them classified as a CALL because it is
    // followed by a `(`. A model that trusted the count would rename inside a
    // string.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src =
        \\pub fn target() void {}
        \\const msg = "call target() from inside a string";
        \\const c = 'x';
        \\fn caller() void { target(); }
    ;
    const mask = try codeMask(a, src);

    const at_msg = std.mem.indexOf(u8, src, "\"call target").?;
    const at_inner = std.mem.indexOfPos(u8, src, at_msg, "target()").?;
    try std.testing.expect(!isCode(mask, at_inner));

    // And the real ones are still code.
    try std.testing.expect(isCode(mask, std.mem.indexOf(u8, src, "pub fn target").?));
    const at_call = std.mem.lastIndexOf(u8, src, "target").?;
    try std.testing.expect(isCode(mask, at_call));
}

test "codeMask: comments, and nested block comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src =
        \\fn real() void {}
        \\// target in a line comment
        \\/* target in a block comment */
        \\/* outer /* target in the nested part */ still outer */
        \\fn after() void {}
    ;
    const mask = try codeMask(a, src);
    try std.testing.expect(isCode(mask, std.mem.indexOf(u8, src, "real").?));
    try std.testing.expect(isCode(mask, std.mem.indexOf(u8, src, "after").?));

    // Every `target` in a comment is masked, INCLUDING the nested one: treating
    // block comments as flat gets the nesting wrong and leaves the tail live.
    var from: usize = 0;
    var masked: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, "target")) |at| {
        if (!isCode(mask, at)) masked += 1;
        from = at + 1;
    }
    // Three: the line comment, the block comment, and the one inside the NESTED
    // comment. Treating block comments as flat ends the outer at the inner's `*/`
    // and leaves the rest of the line live, which is the bug this asserts.
    try std.testing.expectEqual(@as(usize, 3), masked);
}

test "codeMask: an escaped quote does not end the string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `he said "hi"` inside the literal: closing there would unmask everything
    // after it and report a declaration that is not there.
    const src = "const s = \"he said \\\"hi\\\" and then target\";\nconst y = target;\n";
    const mask = try codeMask(a, src);
    const inner = std.mem.indexOf(u8, src, "target").?;
    try std.testing.expect(!isCode(mask, inner));
    const real = std.mem.lastIndexOf(u8, src, "target").?;
    try std.testing.expect(isCode(mask, real));
}

test "codeMask: an unterminated string ends at the newline, not at the end of the file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // One missing quote. Masking to the end of the file would report nothing at
    // all; masking to the newline reports most of it, which is the useful
    // direction to be wrong in.
    const src = "const s = \"oops\nfn target() void {}\nconst x = target;\n";
    const mask = try codeMask(a, src);
    try std.testing.expect(isCode(mask, std.mem.indexOf(u8, src, "fn target").?));
    try std.testing.expect(isCode(mask, std.mem.lastIndexOf(u8, src, "target").?));
}

test "codeMask: the delimiters themselves stay code, so a declaration inside is still found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const src = "const s = \"hello\";\n";
    const mask = try codeMask(a, src);
    try std.testing.expect(isCode(mask, 0)); // the opening quote
    try std.testing.expect(!isCode(mask, std.mem.indexOf(u8, src, "hello").?));
    try std.testing.expect(isCode(mask, std.mem.indexOf(u8, src, ";").?));
}

test "lineOf: the 1-based line a hit reports" {
    const src = "a\nbb\nccc\n";
    try std.testing.expectEqual(@as(u32, 1), lineOf(src, 0));
    try std.testing.expectEqual(@as(u32, 2), lineOf(src, 2));
    try std.testing.expectEqual(@as(u32, 3), lineOf(src, 5));
    try std.testing.expectEqual(@as(u32, 4), lineOf(src, src.len));
}
