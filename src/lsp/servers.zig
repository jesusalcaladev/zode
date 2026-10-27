//! Which language server answers for which file.
//!
//! This is a TABLE, not a discovery mechanism: the command that gets spawned is
//! fixed here and is never chosen by the model. That is the property that lets
//! `lsp` run without a permission dialog — unlike `bash`, there is no argument a
//! model can put in it.
//!
//! It is pure so the extension matching (including the `.ZIG` that a
//! case-insensitive filesystem can hand you, and the `.h` that both clangd and a
//! project's own config may claim) can be tested without spawning anything.

const std = @import("std");

pub const Server = struct {
    /// Also the identity of a running instance: two extensions that name the
    /// same server share one process.
    name: []const u8,
    /// What goes in `textDocument/didOpen` (`zig`, `typescriptreact`, ...).
    language_id: []const u8,
    /// argv. `argv[0]` is looked up in `PATH`; an absolute path works too.
    command: []const []const u8,
    extensions: []const []const u8,
};

/// The servers zode knows how to start, and nothing else. A language server is
/// not started until a file of one of these extensions is actually queried, so
/// an absent binary costs nothing until it is needed (and then the error names
/// the binary to install).
pub const defaults = [_]Server{
    .{ .name = "zls", .language_id = "zig", .command = &.{"zls"}, .extensions = &.{ ".zig", ".zon" } },
    .{ .name = "typescript-language-server", .language_id = "typescript", .command = &.{ "typescript-language-server", "--stdio" }, .extensions = &.{ ".ts", ".mts", ".cts" } },
    .{ .name = "typescript-language-server", .language_id = "typescriptreact", .command = &.{ "typescript-language-server", "--stdio" }, .extensions = &.{".tsx"} },
    .{ .name = "typescript-language-server", .language_id = "javascript", .command = &.{ "typescript-language-server", "--stdio" }, .extensions = &.{ ".js", ".mjs", ".cjs" } },
    .{ .name = "typescript-language-server", .language_id = "javascriptreact", .command = &.{ "typescript-language-server", "--stdio" }, .extensions = &.{".jsx"} },
    .{ .name = "pyright", .language_id = "python", .command = &.{ "pyright-langserver", "--stdio" }, .extensions = &.{ ".py", ".pyi" } },
    .{ .name = "rust-analyzer", .language_id = "rust", .command = &.{"rust-analyzer"}, .extensions = &.{".rs"} },
    .{ .name = "gopls", .language_id = "go", .command = &.{"gopls"}, .extensions = &.{".go"} },
    .{ .name = "clangd", .language_id = "c", .command = &.{"clangd"}, .extensions = &.{ ".c", ".h" } },
    .{ .name = "clangd", .language_id = "cpp", .command = &.{"clangd"}, .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx" } },
    .{ .name = "lua-language-server", .language_id = "lua", .command = &.{"lua-language-server"}, .extensions = &.{".lua"} },
    .{ .name = "bash-language-server", .language_id = "shellscript", .command = &.{ "bash-language-server", "start" }, .extensions = &.{ ".sh", ".bash", ".zsh" } },
    .{ .name = "solargraph", .language_id = "ruby", .command = &.{ "solargraph", "stdio" }, .extensions = &.{".rb"} },
    .{ .name = "jdtls", .language_id = "java", .command = &.{"jdtls"}, .extensions = &.{".java"} },
    .{ .name = "vscode-json-language-server", .language_id = "json", .command = &.{ "vscode-json-language-server", "--stdio" }, .extensions = &.{ ".json", ".jsonc" } },
};

/// The dot-extension of a path, lowercased into `buf` (which must hold at least
/// the longest extension). Returns null when there is no dot in the basename.
pub fn extension(path: []const u8, buf: []u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot..];
    if (ext.len > buf.len) return null;
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..ext.len];
}

/// The server for `path`, `extra` first (a user config can add a language zode
/// does not ship, or override one by naming the same extension).
pub fn find(extra: []const Server, path: []const u8) ?Server {
    var buf: [32]u8 = undefined;
    const ext = extension(path, &buf) orelse return null;
    for (extra) |s| {
        for (s.extensions) |e| {
            if (std.ascii.eqlIgnoreCase(e, ext)) return s;
        }
    }
    for (defaults) |s| {
        for (s.extensions) |e| {
            if (std.ascii.eqlIgnoreCase(e, ext)) return s;
        }
    }
    return null;
}

/// Does any known server claim this path? Used to answer "no server for `.txt`"
/// before doing any work.
pub fn supported(extra: []const Server, path: []const u8) bool {
    return find(extra, path) != null;
}

/// The list of extensions we can serve, for the tool's error message ("install
/// one of these"), built once into `arena`.
pub fn knownExtensions(arena: std.mem.Allocator, extra: []const Server) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    // `extra` then `defaults`, deduplicated, so the message is short.
    for ([_][]const Server{ extra, &defaults }) |list| {
        for (list) |s| {
            for (s.extensions) |e| {
                var dup = false;
                for (seen.items) |x| {
                    if (std.ascii.eqlIgnoreCase(x, e)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                try seen.append(arena, e);
                if (out.items.len > 0) try out.append(arena, ' ');
                try out.appendSlice(arena, e);
            }
        }
    }
    return out.items;
}

test "extension is lowercased and taken from the basename" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(".zig", extension("src/foo.zig", &buf).?);
    try std.testing.expectEqualStrings(".zig", extension("SRC/Foo.ZIG", &buf).?);
    // A dot in a directory name is not an extension.
    try std.testing.expectEqualStrings(".ts", extension("a.b/foo.ts", &buf).?);
    try std.testing.expect(extension("Makefile", &buf) == null);
}

test "find: zig maps to zls, tsx to the react language id" {
    try std.testing.expectEqualStrings("zls", find(&.{}, "src/main.zig").?.name);
    try std.testing.expectEqualStrings("zls", find(&.{}, "build.zig.zon").?.name);
    try std.testing.expectEqualStrings("typescriptreact", find(&.{}, "a.tsx").?.language_id);
    try std.testing.expectEqualStrings("typescript", find(&.{}, "a.ts").?.language_id);
    // Same server, one process: the language id is per document, not per client.
    try std.testing.expectEqualStrings(find(&.{}, "a.ts").?.name, find(&.{}, "a.tsx").?.name);
    try std.testing.expect(find(&.{}, "notes.txt") == null);
}

test "find: a user server wins over the built-in for the same extension" {
    const mine = Server{
        .name = "my-zig-lsp",
        .language_id = "zig",
        .command = &.{"my-lsp"},
        .extensions = &.{".zig"},
    };
    try std.testing.expectEqualStrings("my-zig-lsp", find(&.{mine}, "a.zig").?.name);
    // And an unknown extension can be added.
    const txt = Server{
        .name = "txtlsp",
        .language_id = "text",
        .command = &.{"txtlsp"},
        .extensions = &.{".txt"},
    };
    try std.testing.expectEqualStrings("txtlsp", find(&.{txt}, "a.txt").?.name);
}
