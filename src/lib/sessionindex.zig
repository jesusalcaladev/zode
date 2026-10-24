//! Session metadata and the list of sessions of one project.
//!
//! There are two things a session needs to be worth listing:
//!
//!   - a NAME, because `zode-2026-10-24T18-12-03.jsonl` is not something a
//!     person recognises three days later;
//!   - an AGE it can read at a glance ("3h", "2mo"), because "which one was the
//!     one I was working on this morning" is the only question the list answers.
//!
//! Both live HERE and not in the session file itself: the `.jsonl` is
//! append-only, compressed line by line (`zjsonl`), and rewriting the head of it
//! to change a name would mean decoding and re-encoding a whole history. So the
//! name goes in a sidecar next to it, `<session>.meta.json`, written temp+rename
//! at 0600 like everything else that is not the user's project.
//!
//! ## There is no index
//!
//! A `<state>/index.json` with a per-project count and a "last session" pointer
//! is a CACHE of what the directory already says, and a cache that can disagree
//! with the truth is how a session list shows a session that no longer exists
//! (deleted, or written by another version). Listing a project means reading one
//! directory; that is a file-system operation, not a network one.

const std = @import("std");
const sessionpath = @import("sessionpath.zig");

/// The sidecar next to a session file.
pub const Meta = struct {
    /// User-given name. Empty means "never named": the UI shows the id.
    name: []const u8 = "",
    /// The model the session mostly ran on, for the list's second column.
    model: []const u8 = "",
    /// Unix seconds. 0 means "unknown, use the file's mtime".
    created_at: i64 = 0,
};

/// One session in the list.
pub const Entry = struct {
    /// Full path to the `.jsonl`. This is what a resume needs.
    path: []const u8,
    /// User-given name, or "" when it was never named.
    name: []const u8,
    model: []const u8,
    /// Unix seconds: the sidecar's `created_at`, or the file's mtime.
    created_at: i64,
};

/// `<session>.jsonl` → `<session>.meta.json`. The suffix is REPLACED, not
/// appended: `zode-1.jsonl.meta.json` would be a second extension on a file
/// whose name is already a timestamp, and every glob for `*.jsonl` would match
/// the sidecar if it ended in `.json`.
pub fn metaPath(arena: std.mem.Allocator, session_path: []const u8) ![]u8 {
    const suffix = ".jsonl";
    const base = if (std.mem.endsWith(u8, session_path, suffix))
        session_path[0 .. session_path.len - suffix.len]
    else
        session_path;
    return std.fmt.allocPrint(arena, "{s}.meta.json", .{base});
}

/// Reads the sidecar of `session_path` (the `.jsonl`, not the `.meta.json`: the
/// derivation lives in ONE place, `metaPath`). Any problem (missing file,
/// truncated JSON) is "no metadata", never an error: a session whose name
/// cannot be read still has to appear in the list, with its path and its age.
pub fn readMeta(arena: std.mem.Allocator, io: std.Io, session_path: []const u8) Meta {
    const mp = metaPath(arena, session_path) catch return .{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, mp, arena, .limited(8 * 1024)) catch return .{};
    return parseMeta(arena, data);
}

/// The pure half of `readMeta`, so the parsing has a test that does not need a
/// file system.
pub fn parseMeta(arena: std.mem.Allocator, data: []const u8) Meta {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return .{};
    if (parsed != .object) return .{};
    const o = parsed.object;
    var meta = Meta{};
    if (o.get("name")) |v| {
        if (v == .string) meta.name = v.string;
    }
    if (o.get("model")) |v| {
        if (v == .string) meta.model = v.string;
    }
    if (o.get("created_at")) |v| {
        if (v == .integer) meta.created_at = v.integer;
    }
    return meta;
}

/// Writes the sidecar for `session_path`, atomically (temp + rename, 0600), the
/// way `auth.json` is written: a half-written sidecar left by a crash would be
/// read as "no name" forever, because parsing failure is not an error.
///
/// It takes the SESSION path and derives the sidecar with `metaPath`, instead of
/// taking the sidecar path: the first version took the sidecar, and one caller
/// passing the session path renamed the metadata OVER the `.jsonl`. The test
/// caught it (the file stopped existing where the session was), and the lesson
/// is that the API should not make that mistake expressible.
pub fn writeMeta(io: std.Io, arena: std.mem.Allocator, session_path: []const u8, meta: Meta) !void {
    const path = try metaPath(arena, session_path);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    var file = std.Io.Dir.cwd().createFile(io, tmp, .{
        .truncate = true,
        .permissions = sessionpath.session_mode,
    }) catch |err| return err;
    file.setPermissions(io, sessionpath.session_mode) catch {};
    {
        var wbuf: [1024]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        writeMetaJson(&fw.interface, meta) catch |err| {
            file.close(io);
            _ = std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return err;
        };
        fw.interface.flush() catch |err| {
            file.close(io);
            _ = std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return err;
        };
    }
    file.close(io);
    try std.Io.Dir.rename(.cwd(), tmp, .cwd(), path, io);
}

fn writeMetaJson(w: *std.Io.Writer, meta: Meta) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, meta.name);
    try w.writeAll(",\"model\":");
    try writeJsonString(w, meta.model);
    try w.print(",\"created_at\":{d}}}\n", .{meta.created_at});
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const esc: ?[]const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => null,
        };
        const e = esc orelse continue;
        if (i > start) try w.writeAll(s[start..i]);
        try w.writeAll(e);
        start = i + 1;
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeAll("\"");
}

/// Every session in `dir_path`, NEWEST FIRST.
///
/// One directory read and one sidecar read per session: the list is opened by a
/// keystroke, so it cannot walk the project or parse a history. A missing
/// directory is an empty list — a project that never saved a session has no
/// sessions, which is not an error to show.
pub fn scan(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) []Entry {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);

    var list: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) continue;
        if (!sessionpath.isSessionFile(e.name)) continue;

        const path = std.fs.path.join(arena, &.{ dir_path, e.name }) catch continue;
        const mtime = blk: {
            const st = dir.statFile(io, e.name, .{}) catch break :blk @as(i64, 0);
            break :blk st.mtime.toSeconds();
        };

        var name: []const u8 = "";
        var model: []const u8 = "";
        var created: i64 = 0;
        const meta = readMeta(arena, io, path);
        // Only take what is non-empty: `parseMeta` allocates in the same arena,
        // so the slices stay valid for as long as the list does.
        if (meta.name.len > 0) name = meta.name;
        if (meta.model.len > 0) model = meta.model;
        if (meta.created_at > 0) created = meta.created_at;
        if (created == 0) created = mtime;

        list.append(arena, .{
            .path = path,
            .name = name,
            .model = model,
            .created_at = created,
        }) catch continue;
    }

    std.mem.sort(Entry, list.items, {}, newerFirst);
    return list.items;
}

fn newerFirst(_: void, a: Entry, b: Entry) bool {
    if (a.created_at != b.created_at) return a.created_at > b.created_at;
    // Same second (two sessions created by a script): the path decides, so the
    // order is stable between two openings of the list instead of whatever the
    // directory happened to return.
    return std.mem.lessThan(u8, a.path, b.path);
}

/// How long ago, in the shortest unit that is still true: `now`, `42s`, `12m`,
/// `3h`, `2d`, `3w`, `4mo`, `2y`.
///
/// `mo` and not `m` for months: with `m` already meaning minutes, `3m` and `3m`
/// are two different ages that read the same.
pub fn ageLabel(now: i64, then: i64, buf: []u8) []const u8 {
    const d = now - then;
    if (d <= 1) return std.fmt.bufPrint(buf, "now", .{}) catch "now";
    const s: u64 = @intCast(d);
    const pair: struct { n: u64, unit: []const u8 } = if (s < 60)
        .{ .n = s, .unit = "s" }
    else if (s < 3600)
        .{ .n = s / 60, .unit = "m" }
    else if (s < 86_400)
        .{ .n = s / 3600, .unit = "h" }
    else if (s < 7 * 86_400)
        .{ .n = s / 86_400, .unit = "d" }
    else if (s < 30 * 86_400)
        .{ .n = s / (7 * 86_400), .unit = "w" }
    else if (s < 365 * 86_400)
        .{ .n = s / (30 * 86_400), .unit = "mo" }
    else
        .{ .n = s / (365 * 86_400), .unit = "y" };
    return std.fmt.bufPrint(buf, "{d}{s}", .{ pair.n, pair.unit }) catch "?";
}

// ── tests ─────────────────────────────────────────────────────

const t = std.testing;

test "metaPath: replaces .jsonl, does not append" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try t.expectEqualStrings(
        "/state/sessions/abc/zode-1.meta.json",
        try metaPath(a, "/state/sessions/abc/zode-1.jsonl"),
    );
    // A path without the suffix gets it too, instead of losing characters.
    try t.expectEqualStrings("/tmp/zode-1.meta.json", try metaPath(a, "/tmp/zode-1"));
}

test "parseMeta: the three fields, and garbage is 'no metadata'" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const m = parseMeta(a, "{\"name\":\"fix the parser\",\"model\":\"glm-5.3\",\"created_at\":1761234567}");
    try t.expectEqualStrings("fix the parser", m.name);
    try t.expectEqualStrings("glm-5.3", m.model);
    try t.expectEqual(1761234567, m.created_at);

    // A name with an escaped quote survives the round trip of the writer below.
    const empty = parseMeta(a, "not json at all");
    try t.expectEqualStrings("", empty.name);
    try t.expectEqual(@as(i64, 0), empty.created_at);
}

test "writeMetaJson escapes what JSON cannot carry bare" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeMetaJson(&w, .{ .name = "a\"b\\c", .model = "m", .created_at = 5 });
    const out = w.buffered();

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const back = parseMeta(arena_state.allocator(), out);
    try t.expectEqualStrings("a\"b\\c", back.name);
    try t.expectEqual(@as(i64, 5), back.created_at);
}

test "ageLabel: the shortest unit that is still true" {
    var buf: [16]u8 = undefined;
    const cases = [_]struct { d: i64, want: []const u8 }{
        .{ .d = 0, .want = "now" },
        .{ .d = 1, .want = "now" },
        .{ .d = 2, .want = "2s" },
        .{ .d = 59, .want = "59s" },
        .{ .d = 60, .want = "1m" },
        .{ .d = 3599, .want = "59m" },
        .{ .d = 3600, .want = "1h" },
        .{ .d = 86_399, .want = "23h" },
        .{ .d = 86_400, .want = "1d" },
        .{ .d = 6 * 86_400, .want = "6d" },
        .{ .d = 7 * 86_400, .want = "1w" },
        .{ .d = 29 * 86_400, .want = "4w" },
        .{ .d = 30 * 86_400, .want = "1mo" },
        .{ .d = 364 * 86_400, .want = "12mo" },
        .{ .d = 365 * 86_400, .want = "1y" },
        // A clock that went backwards (NTP, or a session file copied with a
        // future mtime) is "now", not "-3h".
        .{ .d = -100, .want = "now" },
    };
    for (cases) |c| {
        try t.expectEqualStrings(c.want, ageLabel(100_000, 100_000 - c.d, &buf));
    }
}

test "writeMeta and readMeta roundtrip through a real file" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const root = try std.fmt.allocPrint(a, ".zode-meta-rt-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const session = try std.fs.path.join(a, &.{ root, "zode-1.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = session, .data = "{}\n" });

    try writeMeta(io, a, session, .{ .name = "named", .model = "glm-5.3", .created_at = 42 });
    // The sidecar exists where `metaPath` says, and the SESSION file is
    // untouched (that was a real bug: the meta renamed over the session).
    const still = try std.Io.Dir.cwd().readFileAlloc(io, session, a, .limited(64));
    try t.expectEqualStrings("{}\n", still);
    const back = readMeta(a, io, session);
    try t.expectEqualStrings("named", back.name);
    try t.expectEqualStrings("glm-5.3", back.model);
    try t.expectEqual(@as(i64, 42), back.created_at);
}

test "scan: newest first, sidecars and non-session files ignored" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;

    const root = try std.fmt.allocPrint(a, ".zode-sessionindex-{d}", .{t.random_seed});
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    // Three sessions: one named, one only with a sidecar date, one not a
    // session file at all (a sidecar must not show up as a session).
    const old = try std.fs.path.join(a, &.{ root, "zode-old.jsonl" });
    const new = try std.fs.path.join(a, &.{ root, "zode-new.jsonl" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = old, .data = "{}\n" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = new, .data = "{}\n" });
    try writeMeta(io, a, old, .{ .name = "the old one", .model = "glm-5.3", .created_at = 1_000 });
    try writeMeta(io, a, new, .{ .name = "", .model = "", .created_at = 2_000 });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ root, "notes.txt" }), .data = "x" });

    const list = scan(a, io, root);
    try t.expectEqual(@as(usize, 2), list.len);
    // Newest first, even though "old" sorts first alphabetically.
    try t.expect(std.mem.endsWith(u8, list[0].path, "zode-new.jsonl"));
    try t.expectEqualStrings("the old one", list[1].name);
    try t.expectEqualStrings("glm-5.3", list[1].model);
    try t.expectEqual(@as(i64, 1_000), list[1].created_at);

    // A directory that does not exist is an empty list, not an error.
    try t.expectEqual(@as(usize, 0), scan(a, io, try std.fmt.allocPrint(a, "{s}/nope", .{root})).len);
}
