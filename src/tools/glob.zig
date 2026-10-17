const std = @import("std");
const common = @import("common.zig");

// ── arguments ───────────────────────────────────────────────────────────
//
// `pattern`, `subdir`, `limit` and `sort` are parsed in ONE pure function
// because an argument that is silently ignored looks exactly like a tool that
// supports it: a `limit: 0` that quietly becomes 200, or a `sort: "fastest"`
// that is dropped, would surface as "glob did nothing useful" with no way to
// tell why. Everything outside the schema is `error.BadGlobArg`, whose message
// in `errors.zig` names the accepted values and echoes what actually arrived.

pub const default_limit = 200;
pub const min_limit = 1;
pub const max_limit = 200;

pub const Sort = enum { walk, newest, oldest, name };

pub const Args = struct {
    pattern: []const u8,
    subdir: []const u8 = ".",
    limit: usize = default_limit,
    sort: Sort = .walk,
};

pub fn parseArgs(obj: std.json.ObjectMap) !Args {
    const pattern = common.getStr(obj, "pattern") orelse return error.MissingPattern;
    if (pattern.len == 0) return error.BadGlobArg;

    var a: Args = .{ .pattern = pattern };

    if (common.getStr(obj, "subdir")) |raw| {
        const s = normalizeSubdir(raw);
        if (s.len == 0) return error.BadGlobArg;
        a.subdir = s;
    }

    if (obj.get("limit")) |v| {
        switch (v) {
            .integer => |n| {
                if (n < min_limit or n > max_limit) return error.BadGlobArg;
                a.limit = @intCast(n);
            },
            // A string "20" is rejected rather than parsed: models emit both,
            // and a lenient parser here would be a rule nobody can state in the
            // schema ("limit is an integer, or a string sometimes").
            else => return error.BadGlobArg,
        }
    }

    if (common.getStr(obj, "sort")) |s| {
        // Exactly the three values the schema's `enum` lists. `std.meta.stringToEnum`
        // would also accept `walk`, which is a state of the code and not an order
        // the model may ask for — a fourth accepted value the message does not name
        // is how a schema and its error text start disagreeing.
        a.sort = if (std.mem.eql(u8, s, "newest"))
            .newest
        else if (std.mem.eql(u8, s, "oldest"))
            .oldest
        else if (std.mem.eql(u8, s, "name"))
            .name
        else
            return error.BadGlobArg;
    }

    return a;
}

/// `"src/"`, `"./src"` and `"src"` are the same directory. Slices of the
/// argument, not copies: it lives in the arena the arguments were parsed into,
/// which outlives the call.
fn normalizeSubdir(raw: []const u8) []const u8 {
    var s = raw;
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len > 2 and s[0] == '.' and s[1] == '/') s = s[2..];
    if (std.mem.eql(u8, s, "./")) s = ".";
    return s;
}

/// The path as seen from `subdir` (`src/main.zig` -> `main.zig` when the walk
/// started at `src`). The pattern is accepted in both spellings: `src/**/*.zig`
/// from the root and `**/*.zig` under `subdir: "src"` name the same file, and
/// a tool that only takes one of them makes the model guess.
pub fn relativeTo(subdir: []const u8, path: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, ".")) return path;
    if (std.mem.startsWith(u8, path, subdir) and path.len > subdir.len and path[subdir.len] == '/')
        return path[subdir.len + 1 ..];
    return path;
}

fn globMatches(a: *const Args, path: []const u8) bool {
    if (globMatch(a.pattern, path)) return true;
    const rel = relativeTo(a.subdir, path);
    return rel.len != path.len and globMatch(a.pattern, rel);
}

// ── recursive walker skipping binary/vendored dirs ───────────

// ── glob ─────────────────────────────────────────────────────
/// One path + its mtime, the pair a `sort` orders. File scope because the
/// comparator and the walker share the type.
const Match = struct { path: []const u8, mtime: i128 = 0 };

const SortCtx = struct {
    sort: Sort,
    fn less(ctx: SortCtx, lhs: Match, rhs: Match) bool {
        return switch (ctx.sort) {
            .newest => if (lhs.mtime != rhs.mtime) lhs.mtime > rhs.mtime else std.mem.lessThan(u8, lhs.path, rhs.path),
            .oldest => if (lhs.mtime != rhs.mtime) lhs.mtime < rhs.mtime else std.mem.lessThan(u8, lhs.path, rhs.path),
            // The name is the tiebreak for the mtime orders too: two files
            // touched in the same second must not come out in walk order, which
            // is the one order that differs between machines.
            .name, .walk => std.mem.lessThan(u8, lhs.path, rhs.path),
        };
    }
};

/// mtime in nanoseconds; 0 when it cannot be read. The file was just walked,
/// so a failure is a race with a deletion — 0 puts it last for `newest`, which
/// is the safe side of "I do not know".
fn mtimeOf(io: std.Io, path: []const u8) i128 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.mtime.nanoseconds;
}

pub fn toolGlob(io: std.Io, obj: std.json.ObjectMap, arena: std.mem.Allocator) ![]const u8 {
    const a = try parseArgs(obj);
    var matches: std.ArrayList(Match) = .empty;

    var walker = try common.walkZig(io, arena, a.subdir);
    defer walker.deinit();

    const need_mtime = a.sort == .newest or a.sort == .oldest;
    while (walker.next()) |entry_path| {
        defer arena.free(entry_path);
        if (!globMatches(&a, entry_path)) continue;
        const copy = try arena.dupe(u8, entry_path);
        try matches.append(arena, .{ .path = copy, .mtime = if (need_mtime) mtimeOf(io, copy) else 0 });
        // Walk order may stop at limit + 1: the extra one IS the proof that
        // something was left out. A sort has to see every match, because "the
        // 20 newest" is a statement about all of them and the first 20 in
        // directory order are not that.
        if (a.sort == .walk and matches.items.len > a.limit) break;
    }

    if (a.sort != .walk) std.mem.sort(Match, matches.items, SortCtx{ .sort = a.sort }, SortCtx.less);
    const truncated = matches.items.len > a.limit;
    const items = matches.items[0..@min(matches.items.len, a.limit)];

    if (items.len == 0) return std.fmt.allocPrint(arena, "no matches: {s}", .{a.pattern});
    var out: std.ArrayList(u8) = .empty;
    for (items) |m| out.print(arena, "{s}\n", .{m.path}) catch {};
    // Only when a match really was dropped: the old check ran on the next
    // WALKER entry, so a tree with more files than matches claimed truncation
    // even when every match had been printed.
    if (truncated) out.appendSlice(arena, "… (more results omitted)\n") catch {};
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

// ── argument parsing: the pure half of the subdir/limit/sort upgrade ────

fn parseJson(a: std.mem.Allocator, json: []const u8) !Args {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    return parseArgs(v.object);
}

test "glob args: defaults are the whole project and the 200-result cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(arena_state.allocator(), "{\"pattern\":\"**/*.zig\"}");
    try std.testing.expectEqualStrings(".", a.subdir);
    try std.testing.expectEqual(@as(usize, default_limit), a.limit);
    try std.testing.expectEqual(Sort.walk, a.sort);
}

test "glob args: subdir, limit and sort are read, and ./src/ is src" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = try parseJson(
        arena_state.allocator(),
        "{\"pattern\":\"*.zig\",\"subdir\":\"./src/\",\"limit\":20,\"sort\":\"newest\"}",
    );
    try std.testing.expectEqualStrings("src", a.subdir);
    try std.testing.expectEqual(@as(usize, 20), a.limit);
    try std.testing.expectEqual(Sort.newest, a.sort);
}

test "glob args: a value outside the schema is an error, never a silent default" {
    // The whole point of parseArgs: an ignored `limit: 0` (or a `sort` nobody
    // accepts) looks exactly like a tool that supports the argument and did
    // nothing with it. Each case must be refused with what IS accepted.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bad = [_][]const u8{
        "{\"pattern\":\"*.zig\",\"limit\":0}",
        "{\"pattern\":\"*.zig\",\"limit\":201}",
        "{\"pattern\":\"*.zig\",\"limit\":\"20\"}",
        "{\"pattern\":\"*.zig\",\"sort\":\"fastest\"}",
        "{\"pattern\":\"*.zig\",\"sort\":\"walk\"}",
        "{\"pattern\":\"*.zig\",\"subdir\":\"\"}",
        "{\"pattern\":\"\"}",
    };
    for (bad) |j| try std.testing.expectError(error.BadGlobArg, parseJson(a, j));
    try std.testing.expectError(error.MissingPattern, parseJson(a, "{}"));
}

test "glob: the pattern matches from the project root or from subdir" {
    try std.testing.expectEqualStrings("main.zig", relativeTo("src", "src/main.zig"));
    try std.testing.expectEqualStrings("src/main.zig", relativeTo(".", "src/main.zig"));

    var a: Args = .{ .pattern = "src/*.zig", .subdir = "." };
    try std.testing.expect(globMatches(&a, "src/main.zig"));
    a = .{ .pattern = "**/*.zig", .subdir = "src" };
    try std.testing.expect(globMatches(&a, "src/main.zig"));
    a = .{ .pattern = "main.zig", .subdir = "src" };
    try std.testing.expect(globMatches(&a, "src/main.zig"));
    a = .{ .pattern = "other/*", .subdir = "src" };
    try std.testing.expect(!globMatches(&a, "src/main.zig"));
}

test "glob: sort orders by mtime, with the name as the tiebreak" {
    var items = [_]Match{
        .{ .path = "a", .mtime = 100 },
        .{ .path = "b", .mtime = 300 },
        .{ .path = "c", .mtime = 200 },
        .{ .path = "d", .mtime = 300 },
    };

    std.mem.sort(Match, &items, SortCtx{ .sort = .newest }, SortCtx.less);
    // b and d share an mtime; the NAME decides, never the walk order.
    try std.testing.expectEqualStrings("b", items[0].path);
    try std.testing.expectEqualStrings("d", items[1].path);
    try std.testing.expectEqualStrings("c", items[2].path);
    try std.testing.expectEqualStrings("a", items[3].path);

    std.mem.sort(Match, &items, SortCtx{ .sort = .oldest }, SortCtx.less);
    try std.testing.expectEqualStrings("a", items[0].path);
    try std.testing.expectEqualStrings("c", items[1].path);
    try std.testing.expectEqualStrings("b", items[2].path);
    try std.testing.expectEqualStrings("d", items[3].path);

    std.mem.sort(Match, &items, SortCtx{ .sort = .name }, SortCtx.less);
    try std.testing.expectEqualStrings("a", items[0].path);
    try std.testing.expectEqualStrings("b", items[1].path);
    try std.testing.expectEqualStrings("c", items[2].path);
    try std.testing.expectEqualStrings("d", items[3].path);
}
