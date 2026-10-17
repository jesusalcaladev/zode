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

/// One place the symbol appears, as real code.
pub const Occurrence = struct {
    path: []const u8,
    /// Byte offset into the file.
    at: usize,
    kind: symbols.Kind,
};

/// Every place the symbol appears as CODE, across a tree.
///
/// `refs` and `rename` both go through THIS, and that is the point: if the tool
/// that COUNTS and the tool that CHANGES used different scanners they would
/// disagree, and the count in the answer would be a number about something else.
/// The offsets are absolute in the file, which is what lets `rename` rewrite
/// exactly what was counted.
pub fn findOccurrences(
    arena: std.mem.Allocator,
    io: std.Io,
    subdir: []const u8,
    name: []const u8,
) ![]const Occurrence {
    var out: std.ArrayList(Occurrence) = .empty;
    // The PROJECT's files (`git ls-files`), not a tree walk with a budget: see
    // `common.gitFiles` for the measurement that made this necessary — a walk in this
    // repository spent the whole budget inside an ignored vendored copy and reported
    // "no declaration" for a symbol in `src/`.
    var files_iter = common.searchableFiles(io, arena, subdir);
    defer files_iter.deinit();

    var files: usize = 0;
    while (files_iter.next()) |path| {
        defer arena.free(path);
        if (files >= symbols.max_files) break;
        if (shouldSkip(basenameOf(path))) continue;
        const lang = symbols.Lang.fromPath(path);
        if (lang == .md) continue;

        const data = readIfSmall(io, arena, path) orelse continue;
        files += 1;
        // Cheap exit before the expensive one: `codeMask` allocates one byte per
        // byte of the file, and a `refs` over a repository touches every file in
        // it. It has to search for the raw name and not a whole word, because the
        // mask is what makes it whole-word.
        if (std.mem.indexOf(u8, data, name) == null) continue;

        const mask = symbols.codeMask(arena, data) catch continue;
        const prefixes = symbols.declarationPrefixes(lang);
        const owned = arena.dupe(u8, path) catch path;

        // Line by line, reusing the same `classify` that `refs` uses, so the two
        // tools cannot disagree about what counts as an occurrence.
        var it = std.mem.splitScalar(u8, data, '\n');
        var base: usize = 0;
        while (it.next()) |line| {
            const line_base = base;
            base += line.len + 1;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, name)) |rel| {
                from = rel + 1;
                const at = line_base + rel;
                if (!symbols.isCode(mask, at)) continue;
                if (!symbols.wholeWord(line, rel, name)) continue;
                // `classify` finds the FIRST code occurrence on the line and
                // says what it is, so two occurrences of the same name on one
                // line share its verdict. That is right for `refs` and right
                // here: they count, and `rename` does not care which was which.
                if (classify(line, name, prefixes, mask, line_base)) |kind| {
                    try out.append(arena, .{ .path = owned, .at = at, .kind = kind });
                }
            }
        }
    }
    return out.items;
}

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
    var files_iter = common.searchableFiles(io, arena, subdir);
    defer files_iter.deinit();

    var hits: std.ArrayList(symbols.Hit) = .empty;
    var total: usize = 0;
    var files: usize = 0;
    var stopped_early = false;

    while (files_iter.next()) |path| {
        defer arena.free(path);
        if (files >= symbols.max_files) {
            // Its own flag, and its own sentence: "N hits existed and M are shown" is a
            // lie when the walk is what stopped, and that is exactly the shape of
            // silence that hid this bug for a month.
            stopped_early = true;
            break;
        }
        if (shouldSkip(basenameOf(path))) continue;
        const lang = symbols.Lang.fromPath(path);
        // Markdown has no declarations; searching it only produces prose that
        // reads like a reference.
        if (lang == .md) continue;

        const data = readIfSmall(io, arena, path) orelse continue;
        files += 1;

        // Cheap exit before the expensive one. `codeMask` allocates one byte per
        // byte of the file, and a `refs` over a repository touches every file in
        // it: doing that for the 95% that do not mention the symbol is pure cost,
        // and on the test allocator it was enough to fail the suite.
        //
        // It has to be a search for the raw name, not a whole-word one: the mask
        // is what makes it whole-word, and a false positive here only means the
        // mask gets built for a file that had no symbol in it.
        if (std.mem.indexOf(u8, data, name) == null) continue;

        const prefixes = symbols.declarationPrefixes(lang);
        const owned_path = arena.dupe(u8, path) catch path;

        // The mask is the FILE's, built once, and every occurrence is checked
        // against it. Without it a name inside a string literal counted as a
        // use — measured: `refs target` on a file with "call target()" inside a
        // string answered "4 uses" where there were 2, and called one of them a
        // `[call]` because it is followed by a parenthesis.
        const mask = symbols.codeMask(arena, data) catch continue;

        var it = std.mem.splitScalar(u8, data, '\n');
        var line_no: u32 = 0;
        while (it.next()) |line| : (line_no += 1) {
            const base = @intFromPtr(line.ptr) - @intFromPtr(data.ptr);
            const kind = classify(line, name, prefixes, mask, base) orelse continue;
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
        .truncated = total > hits.items.len,
        .stopped_early = stopped_early,
    });
}

/// What this line says about the symbol: a declaration, a call, a plain use, or
/// nothing at all (null, and the line is not worth a slot).
///
/// One pass over the line, not one per kind. A line can hold the declaration AND
/// a call of the same name (`fn foo() { foo(); }` is legal in several languages),
/// and the declaration is the one that answers "where is it".
/// `base` is where this line starts inside the whole file, which is what the mask
/// is indexed by.
fn classify(
    line: []const u8,
    name: []const u8,
    prefixes: []const []const u8,
    mask: []const bool,
    base: usize,
) ?symbols.Kind {
    // A comment is not a use. `// helper is commented out here` read as a
    // reference, and the count the model asked for was wrong because of it.
    if (symbols.isCommentLine(line, prefixes)) return null;
    const def_at = symbols.findSymbol(line, name, prefixes);
    if (def_at) |at| {
        if (!symbols.isCode(mask, base + at)) return null;
        return .definition;
    }
    // Not a declaration: is it mentioned at all, as a whole word AND as code?
    const at = indexOfWord(line, name, mask, base) orelse return null;
    return if (symbols.looksLikeCall(line, at, name)) .call else .reference;
}

/// The first whole-word occurrence that is REAL CODE, or null.
///
/// Two conditions, and both are needed. `std.mem.indexOf` is not enough: `refs
/// foo` matching every `foobar` is the single failure that makes a tool like
/// this useless. Neither is the mask alone: the name can be a perfect whole word
/// inside a string literal.
fn indexOfWord(line: []const u8, word: []const u8, mask: []const bool, base: usize) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, word)) |at| {
        if (symbols.wholeWord(line, at, word) and symbols.isCode(mask, base + at)) return at;
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
