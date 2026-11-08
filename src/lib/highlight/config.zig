const std = @import("std");

const Style = @import("vaxis").Style;

// ── configuration ──────────────────────────────────────────────
pub const Cfg = struct {
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

pub fn eqAny(word: []const u8, list: []const []const u8) bool {
    for (list) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

// ── per-language tables ──────────────────────────────────────
pub const langs = struct {
    pub const zig = Cfg{
        .keywords = &.{ "const", "var", "fn", "pub", "struct", "enum", "union", "error", "test", "import", "export", "opaque", "extern", "packed", "inline", "noinline", "threadlocal", "usingnamespace", "align", "linksection", "callconv", "addrspace", "allowzero" },
        .control = &.{ "if", "else", "while", "for", "switch", "return", "try", "catch", "defer", "errdefer", "break", "continue", "unreachable", "and", "or", "orelse", "async", "await", "suspend", "resume", "asm", "volatile", "comptime", "anytype", "noreturn" },
        .builtins = &.{ "@intCast", "@intFromFloat", "@floatFromInt", "@as", "@import", "@cImport", "@memcpy", "@memset", "@abs", "@min", "@max", "@splat", "@TypeOf", "@typeInfo", "@typeName", "@field", "@intToEnum", "@enumFromInt", "@ptrCast", "@ptrFromInt", "@intFromPtr", "@alignCast", "@divTrunc", "@divFloor", "@mod", "@rem", "@sqrt", "@sin", "@cos", "@exp", "@log", "@panic", "@unreachable", "@compileError", "@setRuntimeSafety", "@call", "@src", "@embedFile" },
        .types = &.{ "u1", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f128", "bool", "void", "noreturn", "type", "anyerror", "anyopaque", "c_int", "c_uint", "c_long", "c_ulong" },
        .line_comments = &.{"//"},
        .template_literal = false,
    };
    pub const js = Cfg{
        .keywords = &.{ "const", "let", "var", "function", "class", "extends", "new", "delete", "typeof", "instanceof", "import", "export", "from", "default", "async", "yield", "this", "super", "static", "get", "set", "in", "of", "void", "with" },
        .control = &.{ "if", "else", "while", "for", "switch", "case", "return", "try", "catch", "finally", "throw", "break", "continue", "await", "do" },
        .builtins = &.{ "console", "document", "window", "Math", "JSON", "Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "BigInt", "localStorage", "fetch", "setTimeout", "setInterval", "require", "module", "process", "Buffer" },
        .types = &.{ "true", "false", "null", "undefined", "NaN", "Infinity" },
        .line_comments = &.{ "//", "#" },
        .decorators = true,
    };
    pub const ts = Cfg{
        .keywords = &.{ "const", "let", "var", "function", "class", "extends", "new", "delete", "typeof", "instanceof", "import", "export", "from", "default", "async", "yield", "this", "super", "static", "get", "set", "in", "of", "void", "interface", "type", "enum", "namespace", "declare", "abstract", "implements", "private", "protected", "public", "readonly", "keyof", "infer", "satisfies", "as" },
        .control = &.{ "if", "else", "while", "for", "switch", "case", "return", "try", "catch", "finally", "throw", "break", "continue", "await", "do" },
        .builtins = &.{ "console", "document", "window", "Math", "JSON", "Promise", "Map", "Set", "Date", "RegExp", "Error", "Symbol", "Record", "Partial", "Array", "ReadonlyArray" },
        .types = &.{ "string", "number", "boolean", "any", "unknown", "never", "void", "object", "symbol", "bigint", "true", "false", "null", "undefined" },
        .line_comments = &.{"//"},
        .decorators = true,
    };
    pub const py = Cfg{
        .keywords = &.{ "def", "class", "import", "from", "as", "with", "lambda", "global", "nonlocal", "del", "pass", "assert", "async" },
        .control = &.{ "if", "elif", "else", "while", "for", "return", "yield", "break", "continue", "raise", "try", "except", "finally", "in", "is", "not", "and", "or", "match", "case", "await" },
        .builtins = &.{ "print", "len", "range", "str", "int", "float", "list", "dict", "set", "tuple", "open", "input", "enumerate", "zip", "map", "filter", "sorted", "reversed", "sum", "min", "max", "abs", "round", "any", "all", "super", "isinstance", "getattr", "setattr", "hasattr", "type", "id", "hex", "bin", "oct", "repr", "format", "vars", "dir", "bytes", "bytearray", "frozenset", "object", "property", "staticmethod", "classmethod", "iter", "next", "divmod", "pow", "hash" },
        .types = &.{ "True", "False", "None", "self", "cls", "Exception", "ValueError", "TypeError", "KeyError", "IndexError", "RuntimeError", "OSError", "StopIteration" },
        .line_comments = &.{"#"},
        .string_prefixes = true,
    };
    pub const sh = Cfg{
        .keywords = &.{ "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "local", "export", "readonly", "declare", "typeset", "source", "alias", "unalias", "set", "shift", "trap", "eval", "exec", "builtin", "coproc" },
        .builtins = &.{ "echo", "printf", "cd", "pwd", "read", "test", "ls", "grep", "sed", "awk", "cut", "sort", "uniq", "head", "tail", "wc", "find", "xargs", "history", "jobs", "kill", "wait", "sleep", "cat", "touch", "mkdir", "rmdir", "rm", "mv", "cp", "ln", "chmod", "chown", "npm", "npx", "git", "curl", "wget", "zig", "make", "cargo", "python", "python3", "node", "docker", "kubectl", "ssh", "scp", "tar", "gzip" },
        .types = &.{ "true", "false" },
        .line_comments = &.{"#"},
        .template_literal = false,
    };
    pub const c_like = Cfg{
        .keywords = &.{ "int", "char", "void", "float", "double", "struct", "union", "enum", "typedef", "static", "const", "extern", "register", "volatile", "sizeof", "inline", "restrict", "auto", "long", "short", "signed", "unsigned", "bool", "class", "public", "private", "protected", "virtual", "override", "template", "namespace", "using", "new", "delete", "operator", "explicit", "friend", "this", "mutable", "constexpr", "noexcept", "nullptr", "throw", "try", "catch", "wchar_t", "size_t", "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t" },
        .control = &.{ "if", "else", "while", "for", "do", "switch", "case", "default", "break", "continue", "return", "goto", "ifdef", "ifndef", "include", "define", "pragma", "endif", "elif" },
        .builtins = &.{ "printf", "scanf", "malloc", "free", "memcpy", "memset", "strlen", "strcmp", "fopen", "fclose", "fprintf", "snprintf", "std", "cout", "cin", "endl", "vector", "string", "map", "set", "pair", "make_shared", "make_unique" },
        .types = &.{ "true", "false", "NULL", "nullptr" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    pub const rust = Cfg{
        .keywords = &.{ "fn", "let", "mut", "pub", "struct", "enum", "trait", "impl", "mod", "use", "crate", "self", "super", "where", "dyn", "async", "move", "ref", "union", "unsafe", "extern", "static", "const", "type" },
        .control = &.{ "if", "else", "match", "while", "loop", "for", "in", "return", "break", "continue", "yield", "await" },
        .builtins = &.{ "println!", "print!", "format!", "vec!", "panic!", "assert!", "assert_eq!", "write!", "writeln!", "todo!", "unimplemented!", "dbg!", "vec", "String", "Vec", "HashMap", "HashSet", "Option", "Result", "Box", "Rc", "Arc", "Some", "None", "Ok", "Err" },
        .types = &.{ "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "Mutex", "RwLock", "RefCell", "Cell", "Cow", "PhantomData" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    pub const go = Cfg{
        .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "fallthrough", "func", "interface", "map", "package", "range", "select", "struct", "switch", "go", "type", "var", "import" },
        .control = &.{ "if", "else", "for", "switch", "return", "goto" },
        .builtins = &.{ "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover", "print", "println", "close", "fmt", "strings", "errors", "context", "http", "json" },
        .types = &.{ "string", "bool", "byte", "rune", "error", "any", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "float32", "float64", "complex64", "complex128" },
        .line_comments = &.{"//"},
        .block_comment_start = "/*",
        .block_comment_end = "*/",
        .template_literal = false,
    };
    pub const sql = Cfg{
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
    pub const generic = Cfg{
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
pub fn cfgFor(lang: []const u8) Cfg {
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
