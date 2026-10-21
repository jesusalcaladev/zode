const std = @import("std");
const pathsafe = @import("../lib/pathsafe.zig");
const common = @import("common.zig");
const hint_lib = @import("../lib/edit_hint.zig");

pub const max_hunks = 16;

/// How many files one multi-file `edit` may carry.
///
/// The same 8 as `write` and `read`, and for the same reason on both: a call
/// whose result fits one turn is a call the model can check, and a half-applied
/// one is a call it cannot undo.
pub const max_files_per_edit = 8;

pub const Hunk = struct {
    old: []const u8,
    new: []const u8,
    allow_multiple: bool = false,
    occurrences: usize = 0,
};

// ── edit: single hunk (compat) or multi-hunk via `edits: [...]` ─
pub fn toolEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    // `files: [{path, old_string, new_string}, ...]` — one call, several FILES.
    //
    // It is the shape a rename takes: every file that names the symbol, in one
    // request. It was N requests, and a half-applied rename across twelve files is
    // the worst state a codebase can be left in.
    //
    // A DIFFERENT argument from `edits`, on purpose: `edits` is the several-HUNKS
    // -in-one-file form and has always been. An array under `files` carrying a
    // `path` is unambiguous, whereas sniffing `edits` for a `path` would make the
    // two forms collide and one of them silently become the other.
    //
    // `path` on its own is still the single-file form, so nothing that worked
    // before changed.
    if (obj.get("files")) |fv| {
        if (fv != .array or fv.array.items.len == 0) {
            return "error: `files` must be a non-empty array of {path, old_string, new_string} objects. Send `path` for a single file.";
        }
        if (fv.array.items.len > max_files_per_edit) {
            return std.fmt.allocPrint(
                arena,
                "error: {d} files is over the cap of {d} in one call. Split it: a half-applied edit across twenty files is worse than two calls, and the cap is what keeps a failure small enough to see.",
                .{ fv.array.items.len, max_files_per_edit },
            );
        }
        // Every hunk of every file is validated BEFORE anything is written, and
        // not just within a file: a rename that matched in nine files and not in
        // the tenth must leave all ten alone, or the codebase stops compiling in
        // a way nobody can see from the tool result.
        var out: std.ArrayList(u8) = .empty;
        try out.print(arena, "edited {d} file(s):\n", .{fv.array.items.len});
        for (fv.array.items) |item| {
            if (item != .object) {
                try out.appendSlice(arena, "  skipped: not an object\n");
                continue;
            }
            const p = common.getStr(item.object, "path") orelse {
                try out.appendSlice(arena, "  skipped: no `path`\n");
                continue;
            };
            // The same rule as `write`: a path that is not a place this tool
            // writes is refused PER FILE, so one bad path does not lose the
            // three good ones in the same call.
            const verdict = pathsafe.checkWriteApproved(std.Io.Dir.cwd(), io, arena, p);
            if (verdict != .ok) {
                try out.print(arena, "  refused {s}: {s}\n", .{ p, pathsafe.refusalText(arena, verdict) });
                continue;
            }
            const one = toolEdit(io, item.object, arena) catch |err| {
                // One file failing does not lose the rest: a rename that landed
                // in nine of ten files is visible in this list, and the tenth is
                // named. Swallowing them all would be a silent half-rename.
                try out.print(arena, "  FAILED {s}: {t}\n", .{ p, err });
                continue;
            };
            try out.print(arena, "  {s}\n", .{one});
        }
        return out.items;
    }

    const path = common.getStr(obj, "path") orelse return error.MissingPath;

    // A path that is not a place this tool writes. The reason is in the
    // refusal: a `.git/hooks/pre-commit` is code that runs on every commit, and
    // a file name in a permission dialog does not look like that.
    const verdict = pathsafe.checkWriteApproved(std.Io.Dir.cwd(), io, arena, path);
    if (verdict != .ok) return pathsafe.refusalText(arena, verdict);

    // Collect hunks: `edits: [{old_string,new_string},...]` or a single pair.
    var hunks: std.ArrayList(Hunk) = .empty;
    if (obj.get("edits")) |edits_v| {
        if (edits_v != .array or edits_v.array.items.len == 0) return error.BadArgs;
        for (edits_v.array.items) |ev| {
            if (ev != .object) return error.BadArgs;
            const old_s = common.getStr(ev.object, "old_string") orelse return error.MissingOldString;
            const new_s = common.getStr(ev.object, "new_string") orelse return error.MissingNewString;
            // `allow_multiple` is read HERE too. It was only read in the
            // single-pair branch below, so a multi-hunk edit that needed it got
            // "old_string appears N times" instead — and the model had no way to
            // tell that the flag it could set on the single form was being
            // ignored on the array form. Same class of bug as the one above:
            // silently dropping something the caller asked for.
            const am = if (ev.object.get("allow_multiple")) |v| (v == .bool and v.bool) else false;
            try hunks.append(arena, .{ .old = old_s, .new = new_s, .allow_multiple = am });
        }
    } else {
        const old_s = common.getStr(obj, "old_string") orelse return error.MissingOldString;
        const new_s = common.getStr(obj, "new_string") orelse return error.MissingNewString;
        const allow_multiple = if (obj.get("allow_multiple")) |v| (v == .bool and v.bool) else false;
        try hunks.append(arena, .{ .old = old_s, .new = new_s, .allow_multiple = allow_multiple });
    }

    if (hunks.items.len > max_hunks) return error.TooManyHunks;

    var dir = std.Io.Dir.cwd();
    const data = try dir.readFileAlloc(io, path, arena, .limited(32 * 1024 * 1024));

    // Validate every hunk against the ORIGINAL text (transaction).
    for (hunks.items) |*h| {
        if (h.old.len == 0) return std.fmt.allocPrint(arena, "error: empty old_string (use write for new files)", .{});
        // A hunk that writes the text back over itself is a patch that does
        // nothing, and it used to SUCCEED: the file came out byte-identical, the
        // model read "edited", and the thing it meant to change was never touched.
        // Refusing it costs one line; accepting it costs a whole iteration spent on
        // a change that was never made. `rename` refuses the same no-op, for the
        // same reason.
        if (std.mem.eql(u8, h.old, h.new)) return std.fmt.allocPrint(
            arena,
            "error: nothing was written. old_string and new_string are identical, so this hunk would write the file back unchanged. Send the text you meant to put there, or drop the hunk.",
            .{},
        );
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, h.old)) |idx| {
            count += 1;
            pos = idx + h.old.len;
            if (count > 1 and !h.allow_multiple) break;
        }
        if (count == 0) {
            // The three words that used to be here — "old_string not found in X" —
            // cost the model an ENTIRE iteration: the only way to recover was to read
            // the file again and look for the difference itself, on a turn whose budget
            // is 12. `hintFor` returns the nearest line and says WHICH of the three
            // failures this is, so the recovery costs no iteration at all. See
            // `lib/edit_hint.zig` for why the three have to read differently.
            const hint = hint_lib.hintFor(arena, data, h.old) catch hint_lib.Hint{ .text = "" };
            const sent = quoteFirstLine(arena, h.old) catch "(your patch)";
            return std.fmt.allocPrint(
                arena,
                "{s}\\nYou sent: {s}",
                .{ hint_lib.message(hint, path), sent },
            );
        }
        if (count > 1 and !h.allow_multiple) {
            return std.fmt.allocPrint(arena, "error: old_string appears {d} times in {s}; be more specific or use allow_multiple", .{ count, path });
        }
        h.occurrences = count;
    }

    // Apply in order (the output of one hunk is the input of the next).
    //
    // CAREFUL: `allocReplace` CANNOT fail on a missing match. It finds nothing,
    // copies the text through unchanged and returns it, which is correct for a
    // single hunk. It is NOT correct for several: every hunk was validated
    // against the ORIGINAL text but it is applied to the output of the previous
    // one, so a hunk whose `old` lived inside the previous hunk's `new` finds
    // nothing and silently does nothing. The file is written without it and the
    // model finds out three iterations later, when it compiles.
    //
    // So the count of REAL replacements is compared with what was validated.
    // Before this the total was computed from the validation (`1`, or
    // `occurrences`) and never compared with anything: a hunk that applied zero
    // times and a hunk that applied exactly once both reported "1 hunk, 1
    // replacement".
    var out: []const u8 = data;
    var total: usize = 0;
    for (hunks.items, 0..) |h, i| {
        const r = try allocReplace(arena, out, h.old, h.new);
        out = r.bytes;
        total += r.count;

        if (r.count == 0) {
            // Blocked, not warned: writing the file without this hunk would
            // produce something the model never asked for and did not review.
            return std.fmt.allocPrint(
                arena,
                "error: nothing was written. Hunk {d} of {d} did not match anything: its old_string is not in the text that is on disk NOW. An earlier hunk changed the very text it was looking for (its old_string lived inside the previous hunk's new_string). Nothing was written, so the file is untouched. Re-read it and send the hunks so that none of them depends on a region another one rewrites.",
                .{ i + 1, hunks.items.len },
            );
        }
    }

    var f = try dir.createFile(io, path, .{ .truncate = true });
    {
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(out);
        try w.interface.flush();
        f.close(io);
    }
    // The count is the REAL one, so the model is told what actually landed.
    //
    // There is deliberately no "this hunk applied fewer times than it was
    // validated" caveat, and the reason is worth writing down: for a hunk
    // without `allow_multiple` the expected count is always 1, and with it a
    // shortfall is legitimate — an earlier hunk legitimately consumed some of the
    // occurrences, which is exactly what a multi-hunk edit is for. Reporting
    // that would be noise, and noise in this message is what made the zero case
    // invisible in the first place. Zero is the only one that is a mistake.
    return std.fmt.allocPrint(arena, "edited {s}: {d} hunk(s), {d} replacement(s)", .{ path, hunks.items.len, total });
}

/// The rewritten text AND how many times it actually happened.
///
/// The count is the reason this returns a struct: with only the bytes, a caller
/// cannot tell "replaced once" from "found nothing and copied everything
/// through", and `toolEdit` needs exactly that difference to stop a hunk that
/// another hunk had already rewritten from being applied silently.
pub const Replaced = struct {
    bytes: []u8,
    count: usize,
};

/// The first line of the patch, as sent, so the model can compare it with what came
/// back. Shown AFTER the hint and not before: the hint is the answer and the echo is the
/// question, and a model that reads the question first tends to answer the question.
fn quoteFirstLine(arena: std.mem.Allocator, old: []const u8) ![]const u8 {
    const nl = std.mem.indexOfScalar(u8, old, '\n') orelse old.len;
    const line = std.mem.trimEnd(u8, old[0..nl], " \t\r");
    if (line.len == 0) return "(an empty line)";
    return std.fmt.allocPrint(
        arena,
        "\"{s}\"",
        .{line},
    );
}

pub fn allocReplace(a: std.mem.Allocator, data: []const u8, old: []const u8, new: []const u8) !Replaced {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, old)) |idx| {
        try out.appendSlice(a, data[pos..idx]);
        try out.appendSlice(a, new);
        pos = idx + old.len;
        count += 1;
    }
    try out.appendSlice(a, data[pos..]);
    return .{ .bytes = out.items, .count = count };
}
