const std = @import("std");
const vaxis = @import("vaxis");
const md = @import("markdown.zig");
const theme = @import("theme.zig");

const Style = vaxis.Style;

// ── token styles ───────────────────────────────────────────────
//
// They used to live here as hardcoded xterm-256 indexes and did NOT import `theme.zig`:
// the header went in the brand blue and the code block in 256, i.e. two
// different color systems on the same screen. Now they come from `theme.zig`
// in truecolor, with vaxis falling back to the closest ANSI index.
//
// What shows up the most is `def`: it was `Style{}`, that is the terminal's
// default color, which is the BRIGHTEST thing on the screen, and it covers
// ~90% of the lines of code. The whole block was the loudest point.
const T = struct {
    const kw = theme.code_kw;
    const kw2 = theme.code_kw2;
    const builtin = theme.code_builtin;
    const typ = theme.code_type;
    const str = theme.code_str;
    const comment = theme.code_comment;
    const num = theme.code_num;
    const fn_call = theme.code_fn;
    const deco = theme.code_deco;
    const def = theme.code_text;
};

const Kinds = enum { none, kw, kw2, builtin, typ, str, comment, num, fn_call, deco };

const Cfg = struct {
    keywords: []const []const u8 = &.{},
    control: []const []const u8 = &.{},
    builtins: []const []const u8 = &.{},
    types: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_comment_start: ?[]const u8 = null,
    block_comment_end: ?[]const u8 = null,
    /// @word is painted as a decorator (JS/TS).
    decorators: bool = false,
    /// Python/rust: prefixes r"…" b'…' f"…" glued to strings.
    string_prefixes: bool = false,
    /// JS/TS: a backtick `…` is a string.
    template_literal: bool = true,
};

fn eqAny(word: []const u8, list: []const []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

// ── per-language tables ──────────────────────────────────────
const langs = struct {
    const zig = Cfg{
        .keywords = &.{ "const", "var", "fn", "pub", "struct", "enum", "union", "error", "test", "import", "export", "opaque", "extern", "packed", "inline", "noinline", "threadlocal", "usingnamespace", "align", "linksection", "callconv", "addrspace", "allowzero" },
        .control = &.{ "if", "else", "while", "for", "switch", "return", "try", "catch", "defer", "errdefer", "break", "continue", "unreachable", "and", "or", "orelse", "async", "await", "suspend", "resume", "asm", "volatile", "comptime", "anytype", "noreturn" },
        .builtins = &.{ "@intCast", "@intFromFloat", "@floatFromInt", "@as", "@import", "@cImport", "@memcpy", "@memset", "@abs", "@min", "@max", "@splat", "@TypeOf", "@typeInfo", "@typeName", "@field", "@intToEnum", "@enumFromInt", "@ptrCast", "@ptrFromInt", "@intFromPtr", "@alignCast", "@divTrunc", "@divFloor", "@mod", "@rem", "@sqrt", "@sin", "@cos", "@exp", "@log", "@panic", "@unreachable", "@compileError", "@setRuntimeSafety", "@call", "@src", "@embedFile" },
        .types = &.{ "u1", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f128", "bool", "void", "noreturn", "type", "anyerror", "anyopaque", "c_int", "c_uint", "c_long", "c_ulong" },
        .line_comments = &.{"//"},
        .template_literal = false,
    };
    const js = Cfg{
        .keywords = &.{ "const", "let", "var", "function", "class", "extends", "new", "delete", "typeof", "instanceof", "import", "export", "from", "default", "async", "yield", "this", "super", "static", "get", "set", "in", "of", "void", "with" },
        .control = &.{ "if", "else", "while", "for", "switch", "case", "return", "try", "catch", "finally", "throw", "break", "continue", "await", "do" },
        .builtins = &.{ "console", "document", "window", "Math", "JSON", "Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "BigInt", "localStorage", "fetch", "setTimeout", "setInterval", "require", "module", "process", "Buffer" },
        .types = &.{ "true", "false", "null", "undefined", "NaN", "Infinity" },
        .line_comments = &.{ "//", "#" },
        .decorators = true,
    };
    const ts = Cfg{
        .keywords = &.{ "const", "let", "var", "function", "class", "extends", "new", "delete", "typeof", "instanceof", "import", "export", "from", "default", "async", "yield", "this", "super", "static", "get", "set", "in", "of", "void", "interface", "type", "enum", "namespace", "declare", "abstract", "implements", "private", "protected", "public", "readonly", "keyof", "infer", "satisfies", "as" },
        .control = &.{ "if", "else", "while", "for", "switch", "case", "return", "try", "catch", "finally", "throw", "break", "continue", "await", "do" },
        .builtins = &.{ "console", "document", "window", "Math", "JSON", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "Record", "Partial", "Array", "ReadonlyArray" },
        .types = &.{ "string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol", "bigint", "true", "false", "null", "undefined" },
        .line_comments = &.{"//"},
        .decorators = true,
    };
    const py = Cfg{
        .keywords = &.{ "def", "class", "import", "from", "as", "with", "lambda", "global", "nonlocal", "del", "pass", "assert", "async" },
        .control = &.{ "if", "elif", "else", "while", "for", "return", "yield", "break", "continue", "raise", "try", "except", "finally", "in", "is", "not", "and", "or", "match", "case", "await" },
        .builtins = &.{ "print", "len", "range", "str", "int", "float", "list", "dict", "set", "tuple", "open", "input", "enumerate", "zip", "map", "filter", "sorted", "reversed", "sum", "min", "max", "abs", "round", "any", "all", "super", "isinstance", "getattr", "setattr", "hasattr", "type", "id", "hex", "bin", "oct", "repr", "format", "vars", "dir", "bytes", "bytearray", "frozenset", "object", "property", "staticmethod", "classmethod", "iter", "next", "divmod", "pow", "hash" },
        .types = &.{ "True", "False", "None", "self", "cls", "Exception", "ValueError", "TypeError", "KeyError", "IndexError", "RuntimeError", "OSError", "StopIteration" },
        .line_comments = &.{"#"},
        .string_prefixes = true,
    };
    const sh = Cfg{
        .keywords = &.{ "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "local", "export", "readonly", "declare", "typeset", "source", "alias", "unalias", "set", "shift", "trap", "eval", "exec", "builtin", "coproc" },
        .builtins = &.{ "echo", "printf", "cd", "pwd", "read", "test", "ls", "grep", "sed", "awk", "cut", "sort", "uniq", "head", "tail", "wc", "find", "xargs", "history", "jobs", "kill", "wait", "sleep", "cat", "touch", "mkdir", "rmdir", "rm", "mv", "cp", "ln", "chmod", "chown", "npm", "npx", "git", "curl", "wget", "zig", "make", "cargo", "python", "python3", "node", "docker", "kubectl", "ssh", "scp", "tar", "gzip" },
        .types = &.{ "true", "false" },
        .line_comments = &.{"#"},
        .template_literal = false,
    };
    const c_like = Cfg{
        .keywords = &.{ "int", "char", "void", "float", "double", "struct", "union", "enum", "typedef", "static", "const", "extern", "register", "volatile", "sizeof", "inline", "restrict", "auto", "long", "short", "signed", "unsigned", "bool", "class", "public", "private", "protected", "virtual", "override", "template", "namespace", "using", "new", "delete", "operator", "explicit", "friend", "this", "mutable", "constexpr", "noexcept", "nullptr", "throw", "try", "catch", "wchar_t", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t" },
        .control = &.{ "if", "else", "while", "for", "do", "switch", "case", "default", "break", "continue", "return", "goto", "ifdef", "ifndef", "include", "define", "pragma", "endif", "elif" },
        .builtins = &.{ "printf", "scanf", "malloc", "free", "memcpy", "memset", "strlen", "strcmp", "fopen", "fclose", "fprintf", "snprintf", "std", "cout", "cin", "endl", "vector", "string", "map", "set", "pair", "make_shared", "make_unique" },
        .types = &.{ "true", "false", "NULL", "nullptr" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    const rust = Cfg{
        .keywords = &.{ "fn", "let", "mut", "pub", "struct", "enum", "trait", "impl", "mod", "use", "crate", "self", "super", "where", "dyn", "async", "move", "ref", "union", "unsafe", "extern", "static", "const", "type" },
        .control = &.{ "if", "else", "match", "while", "loop", "for", "in", "return", "break", "continue", "yield", "await" },
        .builtins = &.{ "println!", "print!", "format!", "vec!", "panic!", "assert!", "assert_eq!", "write!", "writeln!", "todo!", "unimplemented!", "dbg!", "vec", "String", "Vec", "HashMap", "HashSet", "Option", "Result", "Box", "Rc", "Arc", "Some", "None", "Ok", "Err" },
        .types = &.{ "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "Mutex", "RwLock", "RefCell", "Cell", "Cow", "PhantomData" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    const go = Cfg{
        .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "fallthrough", "func", "interface", "map", "package", "range", "select", "struct", "switch", "go", "type", "var", "import" },
        .control = &.{ "if", "else", "for", "switch", "return", "goto" },
        .builtins = &.{ "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover", "print", "println", "close", "fmt", "strings", "errors", "context", "http", "json" },
        .types = &.{ "string", "bool", "byte", "rune", "error", "any", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "float32", "float64", "complex64", "complex128" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    const sql = Cfg{
        .keywords = &.{ "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "VIEW", "TRUNCATE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT", "NULL", "DEFAULT", "PRIMARY", "UNIQUE", "FOREIGN", "REFERENCES", "DISTINCT", "COUNT", "SUM", "AVG", "MIN", "MAX" },
        .control = &.{ "CASE", "WHEN", "THEN", "ELSE", "END", "UNION", "EXCEPT", "INTERSECT", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "IN", "IS" },
        .types = &.{ "INTEGER", "TEXT", "BLOB", "REAL", "NUMERIC", "BOOLEAN", "TIMESTAMP", "DATE", "JSON", "JSONB", "UUID", "SERIAL", "BIGSERIAL", "VARCHAR", "CHAR", "DECIMAL", "FLOAT", "DOUBLE" },
        .line_comments = &.{ "--", "#" },
        .template_literal = false,
    };
    // Fallback for any untagged fence, or a rare one (`json`, `tsx`,
    // `diff`, `text`).
    //
    // `builtins` and `types` were EMPTY, and that is not just about missing
    // colors: the PascalCase→type heuristic in `highlightLine` is guarded by
    // `cfg.types.len > 0`, so with the fallback half the code of
    // a `json` or a `tsx` came out plain. With these two tables it does not.
    const generic = Cfg{
        .keywords = &.{ "if", "else", "for", "while", "return", "function", "def", "class", "import", "const", "let", "var", "fn", "struct", "enum", "pub", "use", "module", "interface", "type", "extends", "implements", "package", "func", "val", "mut", "static", "final", "public", "private", "protected", "virtual", "override", "async", "defp", "end", "nil", "true", "false", "null", "None", "True", "False" },
        .control = &.{ "switch", "case", "try", "catch", "finally", "throw", "break", "continue", "and", "or", "not", "in", "is", "await", "yield", "elif", "elseif", "unless", "match", "select", "defer", "goto", "do", "then", "fi", "done", "unless" },
        .builtins = &.{ "print", "println", "printf", "console", "require", "import", "export", "document", "window", "fetch", "len", "range", "open", "str", "int", "float", "list", "dict", "set", "map", "Array", "Object", "String", "Number", "Boolean", "Promise", "Math", "JSON", "Date", "Error" },
        .types = &.{ "string", "number", "boolean", "object", "array", "symbol", "bigint", "undefined", "any", "unknown", "never", "byte", "short", "long", "float", "double", "char", "int32", "int64", "uint32", "uint64", "String", "Number", "Boolean", "Array", "Object", "Promise", "Error" },
        .line_comments = &.{ "//", "#", "--" },
        .block_comment_start = "/*",
        .block_comment_end = "*/",
    };
};

/// Normalizes a fence tag and returns the result in `buf`.
///
/// Returning a `[]const u8` pointing at a stack temporary was a bug: the slice got
/// used after the function had returned. That is why the caller passes the buffer
/// and the config (which only points at static literals) is resolved
/// inside `cfgFor`.
///
/// The fence tag comes from the MODEL, so it comes from whatever it knows about the
/// language: ```JSON, ```Json, ``` tsx, ``` c++, ``` objective-c. Without
/// normalizing, all of that fell into `generic` and came out plain.
pub fn normalizeLang(lang: []const u8, buf: []u8) []const u8 {
    const l = std.mem.trim(u8, lang, " \t\r\n");
    if (l.len == 0) return "";
    const n = @min(l.len, buf.len);
    for (l[0..n], 0..) |c, i| {
        buf[i] = std.ascii.toLower(c);
    }
    const low = buf[0..n];
    const table = .{
        .{ "javascript", "js" },     .{ "typescript", "ts" },
        .{ "tsx", "ts" },            .{ "jsx", "js" },
        .{ "python", "py" },         .{ "shell", "sh" },
        .{ "bash", "sh" },           .{ "zsh", "sh" },
        .{ "console", "sh" },        .{ "golang", "go" },
        .{ "rs", "rust" },           .{ "c++", "cpp" },
        .{ "cxx", "cpp" },           .{ "h", "c" },
        .{ "objective-c", "c" },     .{ "objc", "c" },
        .{ "csharp", "c" },          .{ "cs", "c" },
        .{ "haskell", "generic" },   .{ "elixir", "generic" },
        .{ "ruby", "generic" },      .{ "rb", "generic" },
        .{ "lua", "generic" },       .{ "toml", "generic" },
        .{ "yaml", "generic" },      .{ "yml", "generic" },
        .{ "html", "generic" },      .{ "xml", "generic" },
        .{ "css", "generic" },       .{ "scss", "generic" },
        .{ "markdown", "generic" },  .{ "md", "generic" },
        .{ "text", "generic" },      .{ "plain", "generic" },
        .{ "plaintext", "generic" }, .{ "txt", "generic" },
        .{ "diff", "generic" },      .{ "patch", "generic" },
        .{ "json", "generic" },      .{ "jsonc", "generic" },
    };
    inline for (table) |pair| {
        if (std.mem.eql(u8, low, pair[0])) return pair[1];
    }
    return low;
}

/// Language config, with the tag ALREADY normalized.
///
/// The normalization happens HERE and not before: `normalizeLang` writes into a stack
/// buffer, so the slice is only valid while this function runs. And
/// `Cfg` only holds pointers to static literals, so returning a
/// `Cfg` is safe.
fn cfgFor(lang: []const u8) Cfg {
    var lbuf: [32]u8 = undefined;
    const l = normalizeLang(lang, &lbuf);
    if (std.mem.eql(u8, l, "zig")) return langs.zig;
    if (std.mem.eql(u8, l, "js")) return langs.js;
    if (std.mem.eql(u8, l, "ts")) return langs.ts;
    if (std.mem.eql(u8, l, "py")) return langs.py;
    if (std.mem.eql(u8, l, "sh")) return langs.sh;
    if (std.mem.eql(u8, l, "c") or std.mem.eql(u8, l, "cpp")) return langs.c_like;
    if (std.mem.eql(u8, l, "rust")) return langs.rust;
    if (std.mem.eql(u8, l, "go")) return langs.go;
    if (std.mem.eql(u8, l, "sql")) return langs.sql;
    return langs.generic;
}

fn styleFor(kind: Kinds) Style {
    return switch (kind) {
        .none => T.def,
        .kw => T.kw,
        .kw2 => T.kw2,
        .builtin => T.builtin,
        .typ => T.typ,
        .str => T.str,
        .comment => T.comment,
        .num => T.num,
        .fn_call => T.fn_call,
        .deco => T.deco,
    };
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Scanner state BETWEEN lines.
///
/// Without this, a trailing `\\` in Zig or an unclosed quote made the
/// next line get painted ENTIRELY green: the scanner had no way of knowing it
/// was still inside a string. It is the classic bug of
/// line-by-line highlighters, and it shows badly in an `edit` of
/// a file with multiline strings.
pub const State = struct {
    /// Inside an unclosed string.
    in_str: bool = false,
    /// Closing quote of the string in progress: `"`, `'` or `` ` ``.
    str_quote: u8 = 0,
    /// Inside an unclosed `/* … */` block comment.
    in_block: bool = false,
};

/// Generic token scanner for ONE line. Supports strings with escapes and
/// prefixes (r"…", b'…'), numbers (hex/bin/floats), line and block comments,
/// keywords/control/builtins/types, fn calls and decorators.
/// Unknown language → safe generic config.
///
/// `state` is carried between lines of the SAME block so multiline strings and
/// block comments get painted right (see `State`). Callers that go line by line
/// with no state (the diff) pass a fresh one per line.
pub fn highlightLine(arena: std.mem.Allocator, line: []const u8, lang: []const u8) ![]md.Segment {
    var st = State{};
    return highlightLineState(arena, line, lang, &st);
}

/// Like `highlightLine` but with state carried between lines.
pub fn highlightLineState(
    arena: std.mem.Allocator,
    line: []const u8,
    lang: []const u8,
    state: *State,
) ![]md.Segment {
    const cfg = cfgFor(lang);

    var segs: std.ArrayList(md.Segment) = .empty;
    var i: usize = 0;
    var run_start: usize = 0; // start of the pending unstyled run

    // If we came from inside a string or a block comment, EVERYTHING left in the
    // line is that color (up to where it closes, if it does).
    const resume_str = state.in_str;
    const resume_block = state.in_block;
    if (resume_block) {
        const close = cfg.block_comment_end orelse "*/";
        if (std.mem.indexOf(u8, line, close)) |end| {
            try segs.append(arena, .{ .text = line[0 .. end + close.len], .style = T.comment });
            run_start = end + close.len;
            i = end + close.len;
            state.in_block = false;
        } else {
            try segs.append(arena, .{ .text = line, .style = T.comment });
            return segs.toOwnedSlice(arena);
        }
    }
    if (resume_str) {
        const q = state.str_quote;
        const end = findStrEnd(line, 0, q);
        if (end) |e| {
            try segs.append(arena, .{ .text = line[0..e], .style = T.str });
            run_start = e;
            i = e;
            state.in_str = false;
        } else {
            try segs.append(arena, .{ .text = line, .style = T.str });
            return segs.toOwnedSlice(arena);
        }
    }

    const flushDef = struct {
        fn f(a: std.mem.Allocator, s: *std.ArrayList(md.Segment), from: usize, to: usize, text: []const u8) !void {
            if (to > from) try s.append(a, .{ .text = text[from..to], .style = T.def });
        }
    }.f;

    while (i < line.len) {
        // ── line comments: the rest of the line ──
        if (lineCommentAt(line, i, cfg.line_comments)) |_| {
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..], .style = T.comment });
            return segs.toOwnedSlice(arena);
        }

        // ── opening of a block comment ──
        if (cfg.block_comment_start) |bs| {
            if (std.mem.startsWith(u8, line[i..], bs)) {
                const close = cfg.block_comment_end orelse "*/";
                try flushDef(arena, &segs, run_start, i, line);
                if (std.mem.indexOfPos(u8, line, i + bs.len, close)) |end| {
                    try segs.append(arena, .{ .text = line[i .. end + close.len], .style = T.comment });
                    i = end + close.len;
                } else {
                    try segs.append(arena, .{ .text = line[i..], .style = T.comment });
                    i = line.len;
                    state.in_block = true; // continues on the next line
                }
                run_start = i;
                continue;
            }
        }

        // ── strings ──
        if (stringStart(line, i, cfg)) |sres| {
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..sres.end], .style = T.str });
            i = sres.end;
            // String unclosed in this line: the rest of the line and the
            // next one are string. Without this, an unclosed quote painted the
            // rest of the file green.
            if (sres.open) {
                state.in_str = true;
                state.str_quote = sres.quote;
                return segs.toOwnedSlice(arena);
            }
            run_start = i;
            continue;
        }

        // ── numbers (hex/bin/floats; not inside identifiers) ──
        if (isDigit(line[i]) and (i == 0 or !isIdentChar(line[i - 1]))) {
            var j = i;
            while (j < line.len and (isIdentChar(line[j]) or line[j] == '.')) : (j += 1) {
                // cut the dot if no digit follows (range, call, end)
                if (line[j] == '.' and (j + 1 >= line.len or !isDigit(line[j + 1]))) break;
            }
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..j], .style = T.num });
            i = j;
            run_start = i;
            continue;
        }

        // ── @word: zig builtins (@as) or JS/TS decorators ──
        if (line[i] == '@' and i + 1 < line.len and isIdentStart(line[i + 1])) {
            var j = i + 1;
            while (j < line.len and isIdentChar(line[j])) : (j += 1) {}
            const word = line[i..j];
            var kind: Kinds = .none;
            if (eqAny(word, cfg.builtins)) {
                kind = .builtin;
            } else if (cfg.decorators) {
                kind = .deco;
            }
            if (kind != .none) {
                try flushDef(arena, &segs, run_start, i, line);
                try segs.append(arena, .{ .text = word, .style = styleFor(kind) });
                run_start = j;
            }
            i = j;
            continue;
        }

        // ── identifiers ──
        if (isIdentStart(line[i])) {
            var j = i;
            while (j < line.len and isIdentChar(line[j])) : (j += 1) {}
            // rust macros: println! / vec! (the ! is glued to it)
            if (j < line.len and line[j] == '!' and eqAny(line[i .. j + 1], cfg.builtins)) j += 1;
            const word = line[i..j];

            var kind: Kinds = .none;
            if (eqAny(word, cfg.control)) {
                kind = .kw2;
            } else if (eqAny(word, cfg.keywords)) {
                kind = .kw;
            } else if (eqAny(word, cfg.builtins)) {
                kind = .builtin;
            } else if (eqAny(word, cfg.types)) {
                kind = .typ;
            } else if (cfg.types.len > 0 and word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
                // Heuristic: PascalCase identifier → type (covers what is not listed)
                kind = .typ;
            } else {
                // Function call? next non-space == '('
                var k = j;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) k += 1;
                if (k < line.len and line[k] == '(') kind = .fn_call;
            }

            if (kind != .none) {
                try flushDef(arena, &segs, run_start, i, line);
                try segs.append(arena, .{ .text = word, .style = styleFor(kind) });
                run_start = j;
            }
            i = j;
            continue;
        }

        // ── any other char: it belongs to the unstyled run ──
        i += 1;
    } // end while

    try flushDef(arena, &segs, run_start, line.len, line);
    if (segs.items.len == 0) {
        try segs.append(arena, .{ .text = line, .style = T.def });
    }
    return segs.toOwnedSlice(arena);
}

fn lineCommentAt(line: []const u8, at: usize, prefixes: []const []const u8) ?usize {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, line[at..], p)) return p.len;
    }
    return null;
}

const StrStart = struct { end: usize, open: bool = false, quote: u8 = '"' };

/// Returns the end index (exclusive) of the string that STARTS at `at`,
/// or null if no string starts there.
fn stringStart(line: []const u8, at: usize, cfg: Cfg) ?StrStart {
    if (line[at] != '"' and line[at] != '\'' and line[at] != '`') return null;
    if (line[at] == '`' and !cfg.template_literal) return null;
    // prefixes r"…" b'…' f"…": only if the previous char is part of a
    // short identifier-like prefix (python/rust); in practice it is enough
    // to accept it if the previous char is not another delimiter.
    if (cfg.string_prefixes and at > 0 and isIdentChar(line[at - 1])) {
        // could be the end of a regular identifier ("foo"x is not valid),
        // but accepting the string avoids false negatives with r"/b'/f".
        return scanString(line, at);
    }
    if (at > 0 and isIdentChar(line[at - 1]) and !cfg.string_prefixes) {
        // e.g.: 12"abc" or foo"bar": not treated as a string (JS allows it;
        // an acceptable false negative to keep the scanner simple).
        return null;
    }
    return scanString(line, at);
}

fn scanString(line: []const u8, open: usize) ?StrStart {
    const quote = line[open];
    var j = open + 1;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 1;
            continue;
        }
        if (line[j] == quote) return .{ .end = j + 1 };
    }
    // String not closed in the line: it is painted to the end AND remembered
    // (`open = true`) so the next line keeps being string.
    return .{ .end = line.len, .open = true, .quote = quote };
}

/// End index (exclusive) of the string that is still OPEN since `from`, or null
/// if it does not close in this line. `quote` is the delimiter.
fn findStrEnd(line: []const u8, from: usize, quote: u8) ?usize {
    var j = from;
    while (j < line.len) : (j += 1) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 1;
            continue;
        }
        if (line[j] == quote) return j + 1;
    }
    return null;
}

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

test "zig: keyword, número, comentario, builtin y texto íntegro" {
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

test "python: def kw, print builtin, self tipo, # comentario" {
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

test "shell: builtin cyan y comentario #" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "grep foo file.txt # buscar";
    const segs = try highlightLine(arena, line, "sh");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    try std.testing.expectEqual(theme.code_builtin, findSeg(segs, "grep").?.style);
}

test "lang desconocida: fallback seguro sin crash y texto íntegro" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "weird || syntax @x \"str\"";
    const segs = try highlightLine(arena, line, "langinventada");
    try std.testing.expect(segs.len >= 1);
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
}

test "string con escape y sin cierre no crashea" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "const s = \"a\\\"b";
    const segs = try highlightLine(arena, line, "zig");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
}

test "comentario de bloque C en una línea" {
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

test "línea vacía y solo espacios" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e = try highlightLine(arena, "", "zig");
    try std.testing.expectEqual(@as(usize, 1), e.len);
    const w = try highlightLine(arena, "   ", "zig");
    try std.testing.expectEqualStrings("   ", try joinedText(arena, w));
}

test "un string multilínea no pinta de verde el resto del bloque" {
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

test "un comentario de bloque multilínea tampoco se propaga mal" {
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

test "el estado se reinicia entre fences distintos" {
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
