const std = @import("std");
const common = @import("common.zig");
const output = @import("../lib/tooloutput.zig");

// ── list_files: plain directory listing (cheap) ──────────────
pub fn toolListFiles(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = common.getStr(obj, "path") orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(arena, "error opening {s}: {t}", .{ path, err });
    };
    defer dir.close(io);

    var rows_buf: [128 * 1024]u8 = undefined;
    var rows: std.Io.Writer = .fixed(&rows_buf);
    var shown: usize = 0;
    var total: usize = 0;
    const limit: usize = 500;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.name.len > 0 and e.name[0] == '.') continue; // hidden
        total += 1;
        if (shown >= limit) continue; // keep counting: a silent cut is a lie
        output.fileRow(&rows, e.kind == .directory, e.name) catch {};
        shown += 1;
    }
    var head_buf: [256]u8 = undefined;
    var head: std.Io.Writer = .fixed(&head_buf);
    if (shown == 0) {
        output.emptyDir(&head, path) catch {};
        return arena.dupe(u8, head.buffered());
    }
    output.header(&head, .files, path) catch {};
    if (total > shown) output.truncated(&head, shown, total) catch {};
    return std.mem.concat(arena, u8, &.{ head.buffered(), rows.buffered() });
}

pub fn looksLikeText(path: []const u8) bool {
    const skip_dirs = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/" };
    for (skip_dirs) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}
