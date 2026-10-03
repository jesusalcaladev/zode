const std = @import("std");
const common = @import("common.zig");

// ── recursive walker skipping binary/vendored dirs ───────────

// ── glob ─────────────────────────────────────────────────────
pub fn toolGlob(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const pattern = common.getStr(obj, "pattern") orelse return error.MissingPattern;

    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    const max_results = 200;

    var walker = try common.walkZig(io, arena, ".");
    defer walker.deinit();

    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (count >= max_results) {
            out.appendSlice(arena, "… (more results omitted)\n") catch {};
            break;
        }
        if (globMatch(pattern, entry_path)) {
            out.print(arena, "{s}\n", .{entry_path}) catch {};
            count += 1;
        }
    }
    if (count == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{pattern});
    return out.items;
}

// ── recursive glob matcher ( *, **, ? ) ──────────────────────
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    return globHere(pattern, path);
}

pub fn globHere(p: []const u8, s: []const u8) bool {
    if (p.len == 0) return s.len == 0;

    // '**' = anything, including '/'
    if (p.len >= 2 and p[0] == '*' and p[1] == '*') {
        var rest = p[2..];
        if (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        // ** consumes 0 chars:
        if (globHere(rest, s)) return true;
        // ** consumes 1 char and keeps going:
        if (s.len > 0) return globHere(p, s[1..]);
        return false;
    }

    // '*' = anything except '/'
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globHere(p[1..], s[i..])) return true;
            if (i < s.len and s[i] == '/') return false;
        }
        return false;
    }

    // '?' = one char (not '/')
    if (p[0] == '?') {
        if (s.len == 0 or s[0] == '/') return false;
        return globHere(p[1..], s[1..]);
    }

    if (s.len == 0 or p[0] != s[0]) return false;
    return globHere(p[1..], s[1..]);
}

test "glob matcher" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(globMatch("**/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("src/*.zig", "src/main.zig"));
    try std.testing.expect(!globMatch("src/*.zig", "src/deep/x.zig"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(globMatch("**", "x/y/z"));
}
