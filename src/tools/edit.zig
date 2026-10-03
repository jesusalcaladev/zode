const std = @import("std");
const common = @import("common.zig");

pub const max_hunks = 16;

pub const Hunk = struct {
    old: []const u8,
    new: []const u8,
    allow_multiple: bool = false,
    occurrences: usize = 0,
};

// ── edit: single hunk (compat) or multi-hunk via `edits: [...]` ─
pub fn toolEdit(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = common.getStr(obj, "path") orelse return error.MissingPath;

    // Collect hunks: `edits: [{old_string,new_string},...]` or a single pair.
    var hunks: std.ArrayList(Hunk) = .empty;
    if (obj.get("edits")) |edits_v| {
        if (edits_v != .array or edits_v.array.items.len == 0) return error.BadArgs;
        for (edits_v.array.items) |ev| {
            if (ev != .object) return error.BadArgs;
            const old_s = common.getStr(ev.object, "old_string") orelse return error.MissingOldString;
            const new_s = common.getStr(ev.object, "new_string") orelse return error.MissingNewString;
            try hunks.append(arena, .{ .old = old_s, .new = new_s });
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
        var count: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, data, pos, h.old)) |idx| {
            count += 1;
            pos = idx + h.old.len;
            if (count > 1 and !h.allow_multiple) break;
        }
        if (count == 0) {
            return std.fmt.allocPrint(arena, "error: old_string not found in {s}: \"{s}\"", .{ path, h.old[0..@min(h.old.len, 80)] });
        }
        if (count > 1 and !h.allow_multiple) {
            return std.fmt.allocPrint(arena, "error: old_string appears {d} times in {s}; be more specific or use allow_multiple", .{ count, path });
        }
        h.occurrences = count;
    }

    // Apply in order (the output of one hunk is the input of the next).
    var out: []const u8 = data;
    var total: usize = 0;
    for (hunks.items) |h| {
        out = try allocReplace(arena, out, h.old, h.new);
        total += if (h.allow_multiple) h.occurrences else 1;
    }

    var f = try dir.createFile(io, path, .{ .truncate = true });
    {
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(out);
        try w.interface.flush();
        f.close(io);
    }
    return std.fmt.allocPrint(arena, "edited {s}: {d} hunk(s), {d} replacement(s)", .{ path, hunks.items.len, total });
}

pub fn allocReplace(a: std.mem.Allocator, data: []const u8, old: []const u8, new: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, data, pos, old)) |idx| {
        try out.appendSlice(a, data[pos..idx]);
        try out.appendSlice(a, new);
        pos = idx + old.len;
    }
    try out.appendSlice(a, data[pos..]);
    return out.items;
}
