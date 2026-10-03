const std = @import("std");
const common = @import("common.zig");

// ── write ────────────────────────────────────────────────────
pub fn toolWrite(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = common.getStr(obj, "path") orelse return error.MissingPath;
    const content = common.getStr(obj, "content") orelse return error.MissingContent;

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
