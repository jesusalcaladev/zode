/// `refs`: where a symbol is defined and where it is used.
///
/// The classification is `lib/symbols.zig`, which is pure and tested on its own.
/// This file is the part that has to know about directories and files.
const std = @import("std");
const common = @import("common.zig");
const symbols = @import("../lib/symbols.zig");

/// Directories that never hold a symbol anybody is looking for, and walking them
/// is pure cost. It is a NAME list and not an extension list, because a generated
/// file can have any extension and a `.min.js` is still a `.js`.
const skip_names = [_][]const u8{
    ".git",
    "zig-out",
    ".zig-cache",
    "zig-pkg",
    "node_modules",
    "vendor",
    "target",
    ".venv",
    "__pycache__",
    "dist",
    "build",
};

fn shouldSkip(name: []const u8) bool {
    for (skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Cap on the text kept from a line. A hit whose line is 4 KB of generated code
/// is a hit the model cannot read, and it still costs one of the 120 slots.
const line_clip = 160;

/// Files bigger than this are not read. A 4 MB generated file does not hold more
/// relevant declarations than a 40 KB one, and reading it costs a trip through
/// the page cache on every single `refs`.
const max_file_bytes = 512 * 1024;

pub fn toolRefs(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const name = common.getStr(obj, "symbol") orelse return error.MissingSymbol;

    // A pattern here would turn this into a grep with extra steps, and the model
    // would reach for it instead of `grep` for the things `grep` is better at.
    if (!symbols.validSymbol(name)) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` is not a plain identifier, so it cannot be a symbol. `refs` finds a definition and its uses; for a pattern or a piece of text use `grep`, which is what it is for.",
            .{name},
        );
    }

    const subdir = common.getStr(obj, "subdir") orelse ".";
    var walker = try common.walkAll(io, arena, subdir);
    defer walker.deinit();

    var hits: std.ArrayList(symbols.Hit) = .empty;
    var total: usize = 0;
    var files: usize = 0;
    var truncated = false;

    while (walker.next()) |path| {
        defer arena.free(path);
        if (files >= symbols.max_files) {
            truncated = true;
            break;
        }
        if (shouldSkip(basenameOf(path))) continue;
        const lang = symbols.Lang.fromPath(path);
        // Markdown has no declarations; searching it only produces prose that
        // reads like a reference.
        if (lang == .md) continue;

        const data = readIfSmall(io, arena, path) orelse continue;
        files += 1;
        const prefixes = symbols.declarationPrefixes(lang);
        const owned_path = arena.dupe(u8, path) catch path;

        var it = std.mem.splitScalar(u8, data, '\n');
        var line_no: u32 = 0;
        while (it.next()) |line| : (line_no += 1) {
            const kind = classify(line, name, prefixes) orelse continue;
            total += 1;
            if (hits.items.len >= symbols.max_hits) continue;
            hits.append(arena, .{
                .path = owned_path,
                .line = line_no + 1,
                .kind = kind,
                .text = clipLine(arena, line),
            }) catch continue;
        }
    }

    return symbols.render(arena, name, .{
        .hits = hits.items,
        .total = total,
        // Both counts matter and they are different: the walk gave up early, or
        // the hits did not fit. Either way the model is looking at a fragment and
        // has to be told so.
        .truncated = truncated or total > hits.items.len,
    });
}

/// What this line says about the symbol: a declaration, a call, a plain use, or
/// nothing at all (null, and the line is not worth a slot).
///
/// One pass over the line, not one per kind. A line can hold the declaration AND
/// a call of the same name (`fn foo() { foo(); }` is legal in several languages),
/// and the declaration is the one that answers "where is it".
fn classify(line: []const u8, name: []const u8, prefixes: []const []const u8) ?symbols.Kind {
    // A comment is not a use. `// helper is commented out here` read as a
    // reference, and the count the model asked for was wrong because of it.
    if (symbols.isCommentLine(line, prefixes)) return null;
    const def_at = symbols.findSymbol(line, name, prefixes);
    if (def_at) |at| {
        _ = at;
        return .definition;
    }
    // Not a declaration: is it mentioned at all, as a whole word?
    const at = indexOfWord(line, name) orelse return null;
    return if (symbols.looksLikeCall(line, at, name)) .call else .reference;
}

/// The first whole-word occurrence, or null.
///
/// `std.mem.indexOf` is NOT enough: `refs foo` matching every `foobar` is the
/// single failure that makes a tool like this useless.
fn indexOfWord(line: []const u8, word: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, word)) |at| {
        if (symbols.wholeWord(line, at, word)) return at;
        from = at + 1;
    }
    return null;
}

fn basenameOf(p: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse 0;
    return p[slash + 1 ..];
}

fn readIfSmall(io: std.Io, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.cwd();
    const st = dir.statFile(io, path, .{}) catch return null;
    if (st.size > max_file_bytes) return null;
    return dir.readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch null;
}

fn clipLine(arena: std.mem.Allocator, line: []const u8) []const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len <= line_clip) return t;
    return std.fmt.allocPrint(arena, "{s}...", .{t[0..line_clip]}) catch t;
}
