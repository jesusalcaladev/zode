const std = @import("std");
const common = @import("common.zig");
const pathsafe = @import("../lib/pathsafe.zig");

/// How many files one `write {files:[...]}` call may carry.
///
/// 8, same as `read`'s `paths` and for the same reason on both sides: what goes
/// in one call has to be small enough that a failure halfway through is visible
/// and re-runnable, and small enough that the result fits a turn.
pub const max_files_per_call = 8;

/// Whether this tool may write to `path`, and the sentence when it may not.
///
/// The check is here, in the tool that writes, and not in the permission
/// dialog: the dialog asks "may I write X?" and the user says yes to a file
/// name they did not read. A `.git/hooks/pre-commit` passes that, because the
/// name looks like a path and not like code that runs on every commit.
///
/// The refusal NAMES what writing there would do, and it names the way out
/// (`bash`, which goes through the permission dialog with the user's eyes on
/// it). A refusal without a way forward is a wall, and a model answers a wall
/// by trying the next tool until one of them works.
pub fn writeAllowed(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const v = pathsafe.checkWrite(path);
    return switch (v) {
        .ok => null,
        else => pathsafe.refusalText(arena, v),
    };
}

// ── write ────────────────────────────────────────────────────
pub fn toolWrite(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    // `files: [{path, content}, ...]` FIRST, because it changes the shape of the
    // answer: one call with N files is ONE round trip instead of N.
    //
    // Renaming a type or a constant means touching every file that names it, and
    // that is the single most common multi-file edit there is. It was N round
    // trips, and on a free tier every one of those is also a chance of a 429 plus
    // three backoff waits.
    if (obj.get("files")) |fv| {
        if (fv != .array or fv.array.items.len == 0) {
            return "error: `files` must be a non-empty array of {path, content} objects. Send `path`/`content` for a single file.";
        }
        if (fv.array.items.len > max_files_per_call) {
            return std.fmt.allocPrint(
                arena,
                "error: {d} files is over the cap of {d} in one call. Split it: the cap exists so that a failure halfway through is a small one you can see, not a whole rename half applied.",
                .{ fv.array.items.len, max_files_per_call },
            );
        }
        var out: std.ArrayList(u8) = .empty;
        out.print(arena, "wrote {d} file(s):\n", .{fv.array.items.len}) catch {};
        for (fv.array.items) |item| {
            if (item != .object) {
                out.appendSlice(arena, "  skipped: not an object\n") catch {};
                continue;
            }
            const p = common.getStr(item.object, "path") orelse {
                out.appendSlice(arena, "  skipped: no `path`\n") catch {};
                continue;
            };
            const c = common.getStr(item.object, "content") orelse {
                out.print(arena, "  skipped {s}: no `content`\n", .{p}) catch {};
                continue;
            };
            // The refusal is PER FILE: a batch of four files where one of them
            // is a git hook writes the other three and says why it did not
            // write the fourth. Refusing the whole call would make one bad path
            // lose the three good ones.
            if (writeAllowed(arena, p)) |why| {
                out.print(arena, "  refused {s}: {s}\n", .{ p, why }) catch {};
                continue;
            }
            var d = std.Io.Dir.cwd();
            d.writeFile(io, .{ .sub_path = p, .data = c }) catch |err| {
                // One failure does not lose the others: four files and one error
                // is a fixable answer, four failures is a broken tool.
                out.print(arena, "  FAILED {s}: {t}\n", .{ p, err }) catch {};
                continue;
            };
            out.print(arena, "  {s} ({d} bytes, {d} lines)\n", .{ p, c.len, lineCount(c) }) catch {};
        }
        return out.items;
    }

    const path = common.getStr(obj, "path") orelse return error.MissingPath;
    const content = common.getStr(obj, "content") orelse return error.MissingContent;

    if (writeAllowed(arena, path)) |why| return why;

    var dir = std.Io.Dir.cwd();
    dir.writeFile(io, .{
        .sub_path = path,
        .data = content,
    }) catch |err| {
        return std.fmt.allocPrint(arena, "error writing {s}: {t}", .{ path, err });
    };
    // The result is NOT just "wrote X (N bytes)": it carries a PREVIEW of what
    // was written. A tool result that says only "ok" makes you open the file to
    // find out whether the model wrote what you asked for, and in an agent loop
    // that check is exactly the step you skip.
    //
    // The preview is part of the tool result (what the MODEL sees to decide
    // whether it worked), not a UI decoration, so it survives to the session
    // file and to `/resume`. It is capped so a 400-line file does not turn into
    // 400 lines of tool result (which would then be elided by the compaction
    // tier and cost a whole extra request).
    var out: std.ArrayList(u8) = .empty;
    // A file ending in `\n` has N lines, not N+1: counting the newline as a
    // separator would report one more line than there is (and the "N more
    // lines" below would be off by one too). Same rule as `splitLines`.
    const total = lineCount(content);
    out.appendSlice(arena, try std.fmt.allocPrint(
        arena,
        "wrote {s} ({d} bytes, {d} lines)",
        .{ path, content.len, total },
    )) catch return std.fmt.allocPrint(arena, "wrote {s}", .{path});

    const max_preview = 12;
    out.appendSlice(arena, "\n--- preview ---") catch return out.items;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var shown: usize = 0;
    while (lines.next()) |l| {
        if (shown >= max_preview) break;
        out.append(arena, '\n') catch return out.items;
        out.appendSlice(arena, l) catch return out.items;
        shown += 1;
    }
    if (total > shown) {
        out.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "\n\u{2026} {d} more lines",
            .{total - shown},
        )) catch {};
    }
    return out.items;
}

/// Lines in `text`, ignoring the final newline: "a\nb\n" is 2 lines, not 3.
///
/// `std.mem.splitScalar` would report the empty string after the last `\n` as a
/// line, and every count derived from it (the header, the "N more lines") would
/// be one too high.
pub fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    const n = std.mem.count(u8, text, "\n");
    return if (std.mem.endsWith(u8, text, "\n")) n else n + 1;
}
