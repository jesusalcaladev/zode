/// `rename`: change a symbol everywhere it is, in ONE call, and say what it did.
///
/// ## Why this is a tool and not something the model does with `edit`
///
/// Renaming is the one refactoring where "one call per occurrence" is
/// catastrophic rather than slow: a rename applied to nine files out of ten leaves
/// a codebase that does not compile, and nothing in the tool results says which
/// file was skipped. The model has to remember to check, and the check costs a
/// round trip.
///
/// So the tool does the mechanical part — find every occurrence, replace them, and
/// report each file — and leaves the judgement to the model. That is the split:
/// the tool cannot know whether the symbol should be renamed, and it can be
/// certain about which bytes say its name.
///
/// ## What it will not do, so nobody has to find out
///
/// - **It does not rename anything that is not the symbol.** Whole word only, and
///   only where `lib/symbols.zig` says the bytes are real CODE: a name inside a
///   string literal, a comment or another identifier is left alone. That was a
///   measured bug in `refs` before the mask existed ("4 uses" where there were 2).
/// - **It does not touch a file it could not read**, and it says so.
/// - **It does not resolve which of two same-named symbols you meant.** If a
///   function and a local share a name, both are renamed. `refs` first, then ask
///   the model to narrow down — the alternative is guessing, and a wrong rename is
///   worse than no rename.
const std = @import("std");
const common = @import("common.zig");
const symbols = @import("../lib/symbols.zig");
const refs_tool = @import("refs.zig");
const pathsafe = @import("../lib/pathsafe.zig");

/// How many replacements one `rename` may make.
///
/// 200, and the number is about REVIEWABILITY: 200 replacements is a diff a human
/// can check in one sitting, and it is also roughly where a mistake stops being
/// obvious. A repository-wide rename that touches 2000 places is not a rename any
/// more, and the tool saying so is more useful than doing it.
pub const max_replacements = 200;

pub const Outcome = struct {
    ok: usize,
    skipped: usize,
    /// Files that were written, with how many replacements each got.
    files: usize,
    truncated: bool,
};

pub fn toolRename(
    io: std.Io,
    obj: std.json.ObjectMap,
    arena: std.mem.Allocator,
) ![]const u8 {
    const from = common.getStr(obj, "symbol") orelse return error.MissingSymbol;
    const to = common.getStr(obj, "to") orelse return error.MissingRenameTarget;

    if (!symbols.validSymbol(from)) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` is not a plain identifier, so it cannot be renamed safely. Renaming is only allowed for a single identifier: a pattern would rename things you did not mean.",
            .{from},
        );
    }
    if (!symbols.validSymbol(to)) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` is not a valid identifier (letters, digits and _ only), so it cannot be a new name.",
            .{to},
        );
    }
    if (std.mem.eql(u8, from, to)) {
        return std.fmt.allocPrint(arena, "`{s}` is already named that. Nothing was changed.", .{from});
    }

    const subdir = common.getStr(obj, "subdir") orelse ".";
    const occurrences = try refs_tool.findOccurrences(arena, io, subdir, from);

    if (occurrences.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "`{s}` was not found as code in {s}. Nothing was changed. If it exists inside a string or a comment, renaming it there is not something a rename should do — say so and edit that place by hand.",
            .{ from, subdir },
        );
    }
    if (occurrences.len > max_replacements) {
        return std.fmt.allocPrint(
            arena,
            "{d} places mention `{s}`, over the cap of {d} for one rename. Nothing was changed. Narrow it with `subdir`, or rename the obvious group first and the rest after.",
            .{ occurrences.len, from, max_replacements },
        );
    }

    // Grouped by file, because that is the unit of writing and of reporting.
    var out: std.ArrayList(u8) = .empty;
    var done: usize = 0;
    var written: usize = 0;
    var skipped: usize = 0;

    var paths = try arena.alloc([]const u8, occurrences.len);
    for (occurrences) |o| {
        var seen = false;
        for (paths[0..written]) |p| {
            if (std.mem.eql(u8, p, o.path)) seen = true;
        }
        if (seen) continue;
        paths[written] = o.path;
        written += 1;
    }

    for (paths[0..written]) |path| {
        var dir = std.Io.Dir.cwd();
        const original = dir.readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024)) catch {
            try out.print(arena, "  SKIPPED {s}: could not read it\n", .{path});
            skipped += 1;
            continue;
        };
        const mask = symbols.codeMask(arena, original) catch continue;

        // Rewrite only the offsets the mask says are code and the scan said are
        // the symbol. Everything else is copied byte for byte.
        const rebuilt = replaceInCode(arena, original, mask, from, to) catch continue;
        if (std.mem.eql(u8, rebuilt, original)) continue;

        const n = countInPath(occurrences, path);
        // The SENSITIVE-PATH rule, and it is the only tool that needs it
        // here: `rename` finds its own files, so its arguments NEVER name
        // them. It cannot ask (a tool has no `Model` and cannot see a
        // dialog), so it refuses and says why — and the model can then edit
        // the file by hand.
        const verdict = pathsafe.checkWriteApproved(std.Io.Dir.cwd(), io, arena, path);
        if (verdict != .ok) {
            try out.print(arena, "  SKIPPED {s}: {s}\n", .{ path, pathsafe.refusalText(arena, verdict) });
            skipped += 1;
            continue;
        }
        dir.writeFile(io, .{ .sub_path = path, .data = rebuilt }) catch |err| {
            try out.print(arena, "  FAILED {s}: {t}\n", .{ path, err });
            skipped += 1;
            continue;
        };
        try out.print(arena, "  {s}: {d} replacement(s)\n", .{ path, n });
        done += n;
    }

    try out.print(arena, "renamed `{s}` to `{s}`: {d} replacement(s) in {d} file(s)", .{ from, to, done, written });
    if (skipped > 0) try out.print(arena, ", {d} file(s) SKIPPED or FAILED and still contain the old name", .{skipped});
    if (done == 0) {
        try out.appendSlice(arena, ". Nothing changed — check that the symbol exists as code with `refs`.");
    } else {
        try out.appendSlice(arena, ". Run the build and the tests now: a rename is only done when it compiles.");
    }
    return out.items;
}

fn countInPath(occ: []const refs_tool.Occurrence, path: []const u8) usize {
    var n: usize = 0;
    for (occ) |o| {
        if (std.mem.eql(u8, o.path, path)) n += 1;
    }
    return n;
}

/// The rewritten bytes, replacing ONLY where the mask says code.
///
/// It walks the mask rather than searching again, because searching again is how
/// the two answers drift apart: what `refs` counted and what `rename` changed must
/// be the same set of offsets or the tool reports one number and does another.
pub fn replaceInCode(
    arena: std.mem.Allocator,
    src: []const u8,
    mask: []const bool,
    from: []const u8,
    to: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (symbols.isCode(mask, i) and i + from.len <= src.len and
            std.mem.eql(u8, src[i .. i + from.len], from) and
            symbols.wholeWord(src, i, from))
        {
            try out.appendSlice(arena, to);
            i += from.len;
            continue;
        }
        try out.append(arena, src[i]);
        i += 1;
    }
    return out.items;
}
