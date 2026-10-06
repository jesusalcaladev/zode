/// The model list, kept on disk between runs.
///
/// ## The measurement that decided the shape
///
/// 2026-10-05, `--models` against openrouter, three times each:
///
///     curl (network only):  415 / 858 / 550 ms
///     zode --models:       558 / 673 / 475 ms
///     the response:        772 839 bytes, 464 models
///
/// So the network is ~90% of it and the PARSE is the rest. The two consequences pull
/// in opposite directions and the resolution is not obvious:
///
///   - storing the RAW BODY saves nothing worth saving (~60 ms of parse) and costs a
///     re-parse on every cache read — which is the path that has to feel instant;
///   - storing the NORMALISED list makes a cache read ~5 ms, and the only risk is a
///     schema change, which the `version` field below turns into a miss.
///
/// So it stores the normalised list. That is a decision, not an accident, and the
/// version number is what makes it safe.
///
/// ## Why a cache at all when the network is the cost
///
/// Not for the 60 ms. A pty that does not answer, an SSH link, an office wifi and
/// OpenRouter having a bad minute all turn 772 KB into seconds, and a `/model` picker
/// dead for four seconds reads as a broken app. This is RESILIENCE.
///
/// ## And a cache is never the whole answer
///
/// Reading a cache written last month would be worse than useless: the user would pick
/// a model the provider has retired. So the caller READS FIRST, paints, and refreshes
/// in the background — the worker for that already existed, and all it lacked was
/// something to paint immediately.
const std = @import("std");
const models = @import("models.zig");

/// Bumped by hand when a stored field of `Model` changes meaning. A mismatch is a
/// cache MISS and not an error: the worst outcome is one slow startup after a rebuild.
///
/// An integer and not a hash of the struct, on purpose. A hash moves when a COMMENT
/// moves, and a comment does not make a cache stale.
pub const version: u32 = 1;

/// Past this age the cache is used AND refreshed anyway. The TTL decides whether the
/// refresh is URGENT, not whether the data is usable: a month-old list of model ids is
/// still a useful thing to show while the network is down.
pub const max_age_hours: u32 = 24 * 14;

pub const Entry = struct {
    fetched_at: i64 = 0,
    version: u32 = 0,
    url: []const u8 = "",
    models: []models.Model = &.{},
};

/// The file for one provider. Under `~/.config/zode` and not in the project: this is
/// machine state, like `auth.json`, and it must not end up in somebody's repository.
pub fn cachePath(env: ?*const std.process.Environ.Map, buf: []u8, provider_id: []const u8) ?[]const u8 {
    const m = env orelse return null;
    const home = m.get("HOME") orelse return null;
    if (home.len == 0) return null;
    var id_buf: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s}/.config/zode/models/{s}.json", .{
        home,
        sanitize(provider_id, &id_buf),
    }) catch null;
}

/// The provider id goes into a FILENAME, so it cannot be anything that escapes the
/// directory. Every built-in id is already `[a-z0-9-]`, and this is what keeps a user's
/// `config.json` from having to be.
fn sanitize(id: []const u8, out: []u8) []const u8 {
    const n = @min(id.len, out.len);
    for (id[0..n], 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '_';
    }
    return out[0..n];
}

/// Writes the list. Best-effort: a cache that cannot be written is a slow `/model`, not
/// a broken app, so every failure here is swallowed.
pub fn write(
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    provider_id: []const u8,
    url: []const u8,
    list: []const models.Model,
) void {
    var path_buf: [512]u8 = undefined;
    const path = cachePath(env, &path_buf, provider_id) orelse return;
    const dir = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var dirh = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return;
    defer dirh.close(io);

    var buf: [512 * 1024]u8 = undefined;
    var f = dirh.createFile(io, std.fs.path.basename(path), .{ .truncate = true }) catch return;
    defer f.close(io);
    var fw = f.writerStreaming(io, &buf);
    const w = &fw.interface;

    // NO format string for the JSON scaffolding. Every literal brace is a placeholder to
    // a formatter and the error that comes out points at the `{d}`, never at the cause.
    // Written with `writeAll`, formatted only where there is a real number.
    w.writeAll("{\"version\":") catch return;
    w.print("{d}", .{version}) catch return;
    w.writeAll(",\"url\":") catch return;
    writeJsonString(w, url) catch return;
    w.writeAll(",\"fetched_at\":") catch return;
    w.print("{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()}) catch return;
    w.writeAll(",\"models\":[") catch return;
    for (list, 0..) |m, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"id\":") catch return;
        writeJsonString(w, m.id) catch return;
        w.writeAll(",\"ctx\":") catch return;
        w.print("{d}", .{m.context_length}) catch return;
        w.writeAll(",\"free\":") catch return;
        w.writeAll(if (m.is_free) "true" else "false") catch return;
        w.writeAll(",\"by\":") catch return;
        writeJsonString(w, m.owned_by) catch return;
        w.writeAll(",\"pp\":") catch return;
        w.print("{d}", .{m.price_prompt}) catch return;
        w.writeAll(",\"pc\":") catch return;
        w.print("{d}", .{m.price_completion}) catch return;
        w.writeAll("}") catch return;
    }
    w.writeAll("]}") catch return;
    w.flush() catch {};
}

/// Reads it. A missing file, a version mismatch, a truncated write, a provider whose
/// URL changed: all of them are a MISS and never an error, because the caller's only
/// response to a cache problem is the network, which it was going to use anyway.
pub fn read(
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    arena: std.mem.Allocator,
    provider_id: []const u8,
    url: []const u8,
) ?Entry {
    var path_buf: [512]u8 = undefined;
    const path = cachePath(env, &path_buf, provider_id) orelse return null;
    var dirh = std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{}) catch return null;
    defer dirh.close(io);
    const body = dirh.readFileAlloc(io, std.fs.path.basename(path), arena, .limited(4 * 1024 * 1024)) catch return null;

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (parsed != .object) return null;
    const o = parsed.object;

    const ver = intOf(o.get("version")) orelse return null;
    if (ver != version) return null;
    // The URL is part of the KEY, not decoration: a provider whose `models_url`
    // changed has a different catalogue, and showing the old one sends the user to
    // pick a model that is not there.
    const u = strOf(o.get("url")) orelse return null;
    if (!std.mem.eql(u8, u, url)) return null;

    var list: std.ArrayList(models.Model) = .empty;
    const arr = o.get("models") orelse return null;
    if (arr != .array) return null;
    for (arr.array.items) |e| {
        if (e != .object) continue;
        const id = strOf(e.object.get("id")) orelse continue;
        var m: models.Model = .{
            .id = id,
            .owned_by = strOf(e.object.get("by")) orelse "?",
        };
        if (intOf(e.object.get("ctx"))) |v| m.context_length = @intCast(@max(0, v));
        if (e.object.get("free")) |c| {
            if (c == .bool) m.is_free = c.bool;
        }
        m.price_prompt = floatOf(e.object.get("pp"));
        m.price_completion = floatOf(e.object.get("pc"));
        list.append(arena, m) catch continue;
    }

    return .{
        .fetched_at = intOf(o.get("fetched_at")) orelse 0,
        .version = @intCast(@max(0, ver)),
        .url = url,
        .models = list.items,
    };
}

fn strOf(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn intOf(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn floatOf(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// A copy of a cached list whose STRINGS the caller owns.
///
/// ## Why this function exists
///
/// `Model` is `id: []const u8, owned_by: []const u8, ...` — a struct of SLICES into
/// whatever arena built it. Copying the struct is therefore not a copy: it is a list of
/// pointers into an arena that the caller is about to destroy, and the first version of
/// the model picker did exactly that.
///
/// It is invisible in `--models`, which uses the list while the arena is still alive,
/// and it is a raw SIGSEGV (exit status 139, no panic message, empty stderr) in the TUI,
/// which keeps the copy for a frame. Measured both ways.
///
/// The rule this belongs to: **ownership has to be in the signature, not in a comment.**
/// A function returning `[]Model` out of an arena is a trapdoor, and the only thing that
/// closes it is a function whose name says what it did.
pub fn copyOut(gpa: std.mem.Allocator, src: []const models.Model) ![]models.Model {
    const out = try gpa.alloc(models.Model, src.len);
    errdefer {
        for (out[0..@min(src.len, out.len)]) |m| {
            if (m.id.len > 0) gpa.free(m.id);
            if (m.owned_by.len > 0) gpa.free(m.owned_by);
        }
        gpa.free(out);
    }
    for (src, 0..) |m, i| {
        out[i] = .{
            .id = try gpa.dupe(u8, m.id),
            .owned_by = try gpa.dupe(u8, m.owned_by),
            .context_length = m.context_length,
            .price_prompt = m.price_prompt,
            .price_completion = m.price_completion,
            .is_free = m.is_free,
        };
    }
    return out;
}

/// Frees what `copyOut` produced.
pub fn freeOut(gpa: std.mem.Allocator, list: []models.Model) void {
    for (list) |m| {
        gpa.free(m.id);
        gpa.free(m.owned_by);
    }
    gpa.free(list);
}

/// How the two lists differ, in the words the user needs: what is NEW and what is
/// GONE.
///
/// The gone list matters as much as the new one. A retired model is still in the cache,
/// and if the UI keeps offering it the user finds out by getting an error at the worst
/// possible moment. `gone` counts only the FREE ones, because a retired free model is
/// the one that was in the rotation and its absence changes what happens next.
pub const Diff = struct {
    added: usize = 0,
    removed: usize = 0,
    changed: usize = 0,
    gone: usize = 0,
};

pub fn diff(cached: []const models.Model, fresh: []const models.Model) Diff {
    var d: Diff = .{};
    for (fresh) |f| {
        const c = find(cached, f.id) orelse {
            d.added += 1;
            continue;
        };
        if (c.context_length != f.context_length) d.changed += 1;
    }
    for (cached) |c| {
        if (find(fresh, c.id) == null) {
            d.removed += 1;
            if (c.is_free) d.gone += 1;
        }
    }
    return d;
}

pub fn find(list: []const models.Model, id: []const u8) ?models.Model {
    for (list) |m| {
        if (std.mem.eql(u8, m.id, id)) return m;
    }
    return null;
}

/// One line, or EMPTY when nothing changed.
///
/// Empty is the common case and it is the load-bearing half: a line that appears on
/// every refresh trains the user to ignore it, and reordering the list under the
/// cursor is worse than not reordering at all.
/// Takes an allocator because the first version returned a slice into its OWN stack
/// buffer, and the caller then read a dead frame: the dangling-grapheme family of bug
/// this repo has paid for five times, and its own test caught it here.
pub fn describe(arena: std.mem.Allocator, d: Diff) []const u8 {
    if (d.added == 0 and d.removed == 0 and d.changed == 0) return "";
    var text = std.Io.Writer.Allocating.init(arena);
    const w = &text.writer;
    w.writeAll("models updated: ") catch return "";
    var first = true;
    if (d.added > 0) {
        w.print("{d} new", .{d.added}) catch {};
        first = false;
    }
    if (d.removed > 0) {
        w.print("{s}{d} gone", .{ if (first) "" else ", ", d.removed }) catch {};
        first = false;
    }
    if (d.changed > 0) {
        w.print("{s}{d} with a new context window", .{ if (first) "" else ", ", d.changed }) catch {};
        first = false;
    }
    return text.written();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    // An if-chain and not a switch: `\n`, `\r` and `\t` are IN `0x00...0x1f`, and a
    // switch rejects overlapping cases however they are ordered, so the range arm can
    // never coexist with the three named ones.
    for (s) |c| {
        if (c == '"') {
            try w.writeAll("\\\"");
        } else if (c == '\\') {
            try w.writeAll("\\\\");
        } else if (c == '\n') {
            try w.writeAll("\\n");
        } else if (c == '\r') {
            try w.writeAll("\\r");
        } else if (c == '\t') {
            try w.writeAll("\\t");
        } else if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('"');
}

// ── tests ───────────────────────────────────────────────────────────────────────

const std_test = std.testing;

fn envFor(home: []const u8) !std.process.Environ.Map {
    var e = std.process.Environ.Map.init(std_test.allocator);
    errdefer e.deinit();
    try e.put("HOME", home);
    return e;
}

test "a provider id can never escape the cache directory" {
    var e = try envFor("/tmp/opencode/zode-cache-home");
    defer e.deinit();
    var buf: [512]u8 = undefined;
    const p = cachePath(&e, &buf, "../../etc/passwd") orelse return error.TestUnexpectedResult;
    // It is inside `models/` and it ends in `.json`. A filename built from a provider id
    // is the one place in this file where a config value could have become a path.
    try std_test.expect(std.mem.indexOf(u8, p, "/models/") != null);
    try std_test.expect(std.mem.endsWith(u8, p, ".json"));
    try std_test.expect(std.mem.indexOf(u8, std.fs.path.basename(p), "/") == null);
}

test "the diff counts new, gone and changed — and says NOTHING when nothing changed" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cached = [_]models.Model{
        .{ .id = "a", .owned_by = "x", .context_length = 128_000 },
        .{ .id = "b", .owned_by = "x", .context_length = 8_000, .is_free = true },
    };
    const fresh = [_]models.Model{
        .{ .id = "a", .owned_by = "x", .context_length = 200_000 },
        .{ .id = "c", .owned_by = "x" },
    };

    const d = diff(&cached, &fresh);
    try std_test.expectEqual(@as(usize, 1), d.added); // c
    try std_test.expectEqual(@as(usize, 1), d.removed); // b
    try std_test.expectEqual(@as(usize, 1), d.gone); // b was free
    try std_test.expectEqual(@as(usize, 1), d.changed); // a's window moved

    const s = describe(arena, d);
    try std_test.expect(std.mem.indexOf(u8, s, "1 new") != null);
    try std_test.expect(std.mem.indexOf(u8, s, "1 gone") != null);

    // The common case says NOTHING, and that is the half that matters: a line that
    // appears on every refresh trains the user to ignore it.
    try std_test.expectEqualStrings("", describe(arena, diff(&cached, &cached)));
}

test "a round trip keeps every field the picker shows, quotes and backslashes included" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = try envFor("/tmp/opencode/zode-cache-rt");
    defer e.deinit();

    const list = [_]models.Model{
        .{ .id = "space/bunny", .owned_by = "Bunny", .context_length = 128_000, .is_free = true },
        // A quote, a backslash and a tab in one string: a hand-written JSON writer is
        // exactly where those break and exactly where nobody tests.
        .{
            .id = "weird/\\\"quoted\\\"",
            .owned_by = "a \"name\" with \\ and \ttab",
            .context_length = 8_000,
            .price_prompt = 0.00000015,
        },
    };
    write(std_test.io, &e, "probe", "https://example.com/v1/models", &list);

    var buf: [512]u8 = undefined;
    const path = cachePath(&e, &buf, "probe").?;
    defer std.Io.Dir.cwd().deleteFile(std_test.io, path) catch {};

    const back = read(std_test.io, &e, arena, "probe", "https://example.com/v1/models") orelse return error.TestUnexpectedResult;
    try std_test.expectEqual(@as(usize, 2), back.models.len);
    try std_test.expectEqualStrings("space/bunny", back.models[0].id);
    try std_test.expectEqualStrings("Bunny", back.models[0].owned_by);
    try std_test.expectEqual(@as(u32, 128_000), back.models[0].context_length);
    try std_test.expect(back.models[0].is_free);
    try std_test.expectEqualStrings("weird/\\\"quoted\\\"", back.models[1].id);
    try std_test.expectEqualStrings("a \"name\" with \\ and \ttab", back.models[1].owned_by);
    // A price that is a float and not a string, because OpenRouter sends "0.00000015"
    // as a STRING and the whole point of `jsonNumber` in models.zig is that it never
    // returns NaN. A cache that stored it as a string would put that back.
    try std_test.expectApproxEqAbs(@as(f64, 0.00000015), back.models[1].price_prompt, 1e-12);
    try std_test.expect(back.fetched_at > 0);
}

test "a cache for a DIFFERENT url is a miss, not a wrong list" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = try envFor("/tmp/opencode/zode-cache-url");
    defer e.deinit();

    const list = [_]models.Model{.{ .id = "a", .owned_by = "x" }};
    write(std_test.io, &e, "probe2", "https://old.example.com/v1/models", &list);
    var buf: [512]u8 = undefined;
    const path = cachePath(&e, &buf, "probe2").?;
    defer std.Io.Dir.cwd().deleteFile(std_test.io, path) catch {};

    // Same provider, new URL: a different catalogue. Showing the old one sends the
    // user to pick a model that is not there.
    try std_test.expect(read(std_test.io, &e, arena, "probe2", "https://new.example.com/v1/models") == null);
    try std_test.expect(read(std_test.io, &e, arena, "probe2", "https://old.example.com/v1/models") != null);
}

test "a corrupt cache file is a miss and not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std_test.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = try envFor("/tmp/opencode/zode-cache-bad");
    // the arena IS used, by read()
    defer e.deinit();

    var buf: [512]u8 = undefined;
    const path = cachePath(&e, &buf, "bad").?;
    std.Io.Dir.cwd().createDirPath(std_test.io, "/tmp/opencode/zode-cache-bad/.config/zode/models") catch {};
    try std.Io.Dir.cwd().writeFile(std_test.io, .{ .sub_path = path, .data = "{\"version\":1,\"models\":[{half" });
    defer std.Io.Dir.cwd().deleteFile(std_test.io, path) catch {};

    // A power cut during the write is the realistic way to get here, and the answer has
    // to be "no cache", never a panic in the middle of opening `/model`.
    try std_test.expect(read(std_test.io, &e, arena, "bad", "https://x/v1/models") == null);
}

test "copyOut survives the arena it came from, which a plain struct copy does not" {
    // The exact shape that segfaulted: a list read out of an arena, the arena dropped,
    // and the copy used afterwards.
    var inner = std.heap.ArenaAllocator.init(std_test.allocator);
    {
        var astate = std.heap.ArenaAllocator.init(std_test.allocator);
        const arena = astate.allocator();
        var e = try envFor("/tmp/opencode/zode-cache-deep");
        defer e.deinit();

        const list = [_]models.Model{
            .{ .id = "alpha/model", .owned_by = "Alpha", .context_length = 128_000, .is_free = true },
        };
        write(std_test.io, &e, "deep", "https://example.com/v1/models", &list);

        const back = read(std_test.io, &e, arena, "deep", "https://example.com/v1/models") orelse return error.TestUnexpectedResult;
        const copied = try copyOut(std_test.allocator, back.models);
        defer freeOut(std_test.allocator, copied);

        // Destroy the arena the slices pointed into. Deliberately, and with no `defer`:
        // having both is a double free and a segfault in the arena's own free list.
        astate.deinit();

        // Reading the copy NOW is the assertion. With `gpa.dupe(Model, ...)` the struct
        // is copied and the pointers are not, and this line reads freed memory.
        try std_test.expectEqualStrings("alpha/model", copied[0].id);
        try std_test.expectEqualStrings("Alpha", copied[0].owned_by);
        try std_test.expectEqual(@as(u32, 128_000), copied[0].context_length);
        try std_test.expect(copied[0].is_free);
    }
    inner.deinit();
}
