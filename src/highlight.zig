const std = @import("std");
const vaxis = @import("vaxis");
const md = @import("markdown.zig");

const Style = vaxis.Style;

// ── estilos de token (brillan en 256 y degradan bien a 16) ──
const T = struct {
    const kw = Style{ .fg = .{ .index = 5 } }; // magenta: keywords
    const kw2 = Style{ .fg = .{ .index = 5 }, .italic = true }; // control-flow
    const builtin = Style{ .fg = .{ .index = 6 } }; // cyan: builtins
    const typ = Style{ .fg = .{ .index = 4 } }; // azul: tipos
    const str = Style{ .fg = .{ .index = 2 } }; // verde: strings
    const comment = Style{ .fg = .{ .index = 8 }, .italic = true }; // gris
    const num = Style{ .fg = .{ .index = 3 } }; // amarillo
    const fn_call = Style{ .bold = true };
    const deco = Style{ .fg = .{ .index = 3 }, .italic = true }; // @decorador
    const def = Style{};
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
    /// @word se pinta como decorador (JS/TS).
    decorators: bool = false,
    /// Python/rust: prefijos r"…" b'…' f"…" pegados a strings.
    string_prefixes: bool = false,
    /// JS/TS: backtick `…` es string.
    template_literal: bool = true,
};

fn eqAny(word: []const u8, list: []const []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

// ── tablas por lenguaje ──────────────────────────────────────
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
    const generic = Cfg{
        .keywords = &.{ "if", "else", "for", "while", "return", "function", "def", "class", "import", "const", "let", "var", "fn", "struct", "enum", "pub", "use" },
        .control = &.{ "switch", "case", "try", "catch", "finally", "throw", "break", "continue", "and", "or", "not", "in", "is", "await", "yield" },
        .line_comments = &.{ "//", "#", "--" },
        .block_comment_start = "/*",
        .block_comment_end = "*/",
    };
};

fn cfgFor(lang: []const u8) Cfg {
    const l = lang;
    if (std.mem.eql(u8, l, "zig")) return langs.zig;
    if (std.mem.eql(u8, l, "js") or std.mem.eql(u8, l, "javascript")) return langs.js;
    if (std.mem.eql(u8, l, "ts") or std.mem.eql(u8, l, "typescript")) return langs.ts;
    if (std.mem.eql(u8, l, "py") or std.mem.eql(u8, l, "python")) return langs.py;
    if (std.mem.eql(u8, l, "sh") or std.mem.eql(u8, l, "bash") or std.mem.eql(u8, l, "shell") or std.mem.eql(u8, l, "zsh")) return langs.sh;
    if (std.mem.eql(u8, l, "c") or std.mem.eql(u8, l, "cpp") or std.mem.eql(u8, l, "h") or std.mem.eql(u8, l, "hpp")) return langs.c_like;
    if (std.mem.eql(u8, l, "rust") or std.mem.eql(u8, l, "rs")) return langs.rust;
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

/// Token scanner genérico de UNA línea. Soporta strings con escapes y
/// prefijos (r"…", b'…'), números (hex/bin/floats), comentarios de línea y
/// bloque, keywords/control/builtins/tipos, llamadas fn y decoradores.
/// Lenguaje desconocido → config genérica segura.
pub fn highlightLine(arena: std.mem.Allocator, line: []const u8, lang: []const u8) ![]md.Segment {
    const cfg = cfgFor(lang);

    var segs: std.ArrayList(md.Segment) = .empty;
    var i: usize = 0;
    var run_start: usize = 0; // inicio del tramo sin estilo pendiente

    const flushDef = struct {
        fn f(a: std.mem.Allocator, s: *std.ArrayList(md.Segment), from: usize, to: usize, text: []const u8) !void {
            if (to > from) try s.append(a, .{ .text = text[from..to], .style = T.def });
        }
    }.f;

    while (i < line.len) {
        // ── comentarios de línea: el resto de la línea ──
        if (lineCommentAt(line, i, cfg.line_comments)) |_| {
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..], .style = T.comment });
            return segs.toOwnedSlice(arena);
        }

        // ── apertura de comentario de bloque ──
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
            run_start = i;
            continue;
        }

        // ── números (hex/bin/floats; no dentro de identificadores) ──
        if (isDigit(line[i]) and (i == 0 or !isIdentChar(line[i - 1]))) {
            var j = i;
            while (j < line.len and (isIdentChar(line[j]) or line[j] == '.')) : (j += 1) {
                // corta el punto si no sigue un dígito (rango, llamada, fin)
                if (line[j] == '.' and (j + 1 >= line.len or !isDigit(line[j + 1]))) break;
            }
            try flushDef(arena, &segs, run_start, i, line);
            try segs.append(arena, .{ .text = line[i..j], .style = T.num });
            i = j;
            run_start = i;
            continue;
        }

        // ── @word: builtins de zig (@as) o decoradores de JS/TS ──
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

        // ── identificadores ──
        if (isIdentStart(line[i])) {
            var j = i;
            while (j < line.len and isIdentChar(line[j])) : (j += 1) {}
            // macros rust: println! / vec! (el ! va pegado)
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
                // Heurística: IdentificadorEnPascal → tipo (cubre lo no listado)
                kind = .typ;
            } else {
                // ¿llamada a función? siguiente no-espacio == '('
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

        // ── cualquier otro char: pertenece al tramo sin estilo ──
        i += 1;
    } // fin while

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

const StrStart = struct { end: usize };

/// Devuelve el índice final (exclusivo) del string que EMPIEZA en `at`,
/// o null si ahí no empieza un string.
fn stringStart(line: []const u8, at: usize, cfg: Cfg) ?StrStart {
    if (line[at] != '"' and line[at] != '\'' and line[at] != '`') return null;
    if (line[at] == '`' and !cfg.template_literal) return null;
    // prefijos r"…" b'…' f"…": solo si el char anterior es parte de un
    // identificador corto tipo prefijo (python/rust); en la práctica basta
    // con aceptarlo si el char anterior no es otro delimitador.
    if (cfg.string_prefixes and at > 0 and isIdentChar(line[at - 1])) {
        // podría ser el fin de un identificador común ("foo"x no es válido),
        // pero aceptar el string evita falsos negativos con r"/b'/f".
        return scanString(line, at);
    }
    if (at > 0 and isIdentChar(line[at - 1]) and !cfg.string_prefixes) {
        // ej: 12"abc" o foo"bar": no tratamos como string (JS lo permite;
        // falso negativo aceptable para mantener simple el scanner).
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
    // string sin cierre en la línea: pintar hasta el final
    return .{ .end = line.len };
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

    // El texto concatenado debe ser IDÉNTICO a la línea (no se pierde nada).
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));

    const kw = findSeg(segs, "const").?;
    try std.testing.expectEqual(@as(u8, 5), kw.style.fg.index); // magenta
    const num = findSeg(segs, "42").?;
    try std.testing.expectEqual(@as(u8, 3), num.style.fg.index); // amarillo
    var found_comment = false;
    for (segs) |s| {
        if (std.mem.startsWith(u8, s.text, "// fin")) found_comment = true;
    }
    try std.testing.expect(found_comment);
    const b = findSeg(segs, "@as").?;
    try std.testing.expectEqual(@as(u8, 6), b.style.fg.index); // cyan builtin
}

test "python: def kw, print builtin, self tipo, # comentario" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "def foo(self): print('hi')  # nota";
    const segs = try highlightLine(arena, line, "py");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    try std.testing.expectEqual(@as(u8, 5), findSeg(segs, "def").?.style.fg.index);
    try std.testing.expectEqual(@as(u8, 6), findSeg(segs, "print").?.style.fg.index);
    try std.testing.expectEqual(@as(u8, 4), findSeg(segs, "self").?.style.fg.index);
}

test "shell: builtin cyan y comentario #" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = "grep foo file.txt # buscar";
    const segs = try highlightLine(arena, line, "sh");
    try std.testing.expectEqualStrings(line, try joinedText(arena, segs));
    try std.testing.expectEqual(@as(u8, 6), findSeg(segs, "grep").?.style.fg.index);
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
