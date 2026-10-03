const std = @import("std");
const common = @import("common.zig");

// ── list_files: plain directory listing (cheap) ──────────────
pub fn toolListFiles(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const path = common.getStr(obj, "path") orelse ".";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        return std.fmt.allocPrint(arena, "error opening {s}: {t}", .{ path, err });
    };
    defer dir.close(io);

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.name.len > 0 and e.name[0] == '.') continue; // hidden
        const tag: []const u8 = switch (e.kind) {
            .directory => "d",
            .file => "f",
            else => "?",
        };
        out.print(arena, "{s} {s}\n", .{ tag, e.name }) catch {};
        count += 1;
        if (count >= 500) {
            out.appendSlice(arena, "… (truncated)\n") catch {};
            break;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "(empty) {s}", .{path});
    return out.items;
}

pub fn looksLikeText(path: []const u8) bool {
    const skip_dirs = [_][]const u8{ ".zig-cache/", "zig-out/", ".git/", "node_modules/" };
    for (skip_dirs) |d| {
        if (std.mem.indexOf(u8, path, d) != null) return false;
    }
    return true;
}
