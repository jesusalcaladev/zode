const std = @import("std");
const sessionindex = @import("sessionindex.zig");
const fuzzy = @import("fuzzy.zig");
const zjsonl = @import("zjsonl.zig");

pub const crop_window: usize = 1000;
pub const crop_threshold: usize = 2000;

pub const SessionHit = struct {
    entry: sessionindex.Entry,
    tier: enum { title, transcript },
    score: i32,
    snippet: []const u8 = "",
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
            if (j + 1 == needle.len) return i;
        }
    }
    return null;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (haystack[0..needle.len], needle) |h, n| {
        if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
    }
    return true;
}

pub fn sessionProse(
    allocator: std.mem.Allocator,
    io: std.Io,
    entry: sessionindex.Entry,
) ![]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, ".", .{}) catch return error.CannotOpenDir;
    defer dir.close(io);

    const data = try dir.readFileAlloc(io, entry.path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(data);

    var lines: [4096][]const u8 = undefined;
    var n_lines: usize = 0;
    var rest: []const u8 = data;
    while (rest.len > 0) {
        const nl = std.mem.indexOf(u8, rest, "\n");
        var line: []const u8 = "";
        if (nl) |i| {
            line = rest[0..i];
            rest = rest[i + 1..];
        } else {
            line = rest;
            rest = "";
        }
        if (line.len == 0) continue;
        if (zjsonl.isCompressed(line)) {
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();
            const ar = arena_state.allocator();
            const decompressed = try zjsonl.decompressInto(ar, line, 8 * 1024 * 1024);
            defer ar.free(decompressed);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, ar, decompressed, .{}) catch continue;
            if (parsed != .object) continue;
            const obj = parsed.object;
            const role = obj.get("role") orelse continue;
            if (role != .string) continue;
            if (std.mem.eql(u8, role.string, "user") or std.mem.eql(u8, role.string, "assistant")) {
                if (obj.get("content")) |c| {
                    if (c == .string and n_lines < lines.len) {
                        lines[n_lines] = try allocator.dupe(u8, c.string);
                        n_lines += 1;
                    }
                }
            }
            continue;
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{}) catch continue;
        if (parsed != .object) continue;
        const obj = parsed.object;
        const role = obj.get("role") orelse continue;
        if (role != .string) continue;
        if (std.mem.eql(u8, role.string, "user") or std.mem.eql(u8, role.string, "assistant")) {
            if (obj.get("content")) |c| {
                if (c == .string and n_lines < lines.len) {
                    lines[n_lines] = try allocator.dupe(u8, c.string);
                    n_lines += 1;
                }
            }
        }
    }

    if (n_lines == 0) return allocator.dupe(u8, "");

    var start: usize = 0;
    var end: usize = n_lines;
    if (n_lines > crop_threshold) {
        end = crop_window;
        start = n_lines - crop_window;
    }

    var total: usize = 0;
    for (lines[start..end]) |content| {
        total += content.len + 1;
    }

    const buf = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (lines[start..end]) |content| {
        @memcpy(buf[off..off + content.len], content);
        off += content.len;
        buf[off] = 0;
        off += 1;
    }

    for (lines[0..n_lines]) |content| {
        allocator.free(content);
    }

    return buf[0..off];
}

/// Tier 1: title substring match. Instant — no disk I/O beyond what's already
/// loaded.
pub fn searchTitle(
    gpa: std.mem.Allocator,
    entries: []const sessionindex.Entry,
    query: []const u8,
) ![]SessionHit {
    if (query.len == 0) return error.EmptyQuery;

    var out: std.ArrayList(SessionHit) = .empty;
    errdefer out.deinit(gpa);

    for (entries) |e| {
        const session_id = std.fs.path.basename(e.path);
        const title = e.title(session_id);
        if (containsIgnoreCase(title, query) == null) continue;

        var score: i32 = 1000;
        if (startsWithIgnoreCase(title, query)) score += 500;
        score -= @intCast(title.len / 10);

        try out.append(gpa, .{
            .entry = e,
            .tier = .title,
            .score = score,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Tier 2: transcript fuzzy match. Reads each session's transcript (cropped at
/// both ends), extracts prose, and fuzzy-matches the query against it.
/// Returns hits with a bounded snippet around the match.
pub fn searchTranscript(
    gpa: std.mem.Allocator,
    io: std.Io,
    entries: []const sessionindex.Entry,
    query: []const u8,
) ![]SessionHit {
    if (query.len == 0) return error.EmptyQuery;

    var out: std.ArrayList(SessionHit) = .empty;
    errdefer out.deinit(gpa);

    var buf: [128]u32 = undefined;
    for (entries) |e| {
        const prose = sessionProse(gpa, io, e) catch continue;
        if (prose.len == 0) continue;

        const n = fuzzy.matchPositions(prose, query, &buf) orelse {
            gpa.free(prose);
            continue;
        };

        const first = buf[0];
        const last = buf[n - 1];
        const half: usize = 80;
        var s_start: usize = 0;
        var s_end: usize = prose.len;
        if (first > half) s_start = first - half;
        if (last + half < prose.len) s_end = last + half + 1;

        const snippet_slice = prose[s_start..s_end];
        const snippet = try gpa.dupe(u8, snippet_slice);
        gpa.free(prose);

        var score: i32 = 500;
        if (startsWithIgnoreCase(prose, query)) score += 300;

        try out.append(gpa, .{
            .entry = e,
            .tier = .transcript,
            .score = score,
            .snippet = snippet,
        });
    }

    return out.toOwnedSlice(gpa);
}

/// Rank hits: `|Δt| > 60s → recency wins; within a minute → relevance tiebreak`.
pub fn rankHits(
    gpa: std.mem.Allocator,
    hits: []SessionHit,
) ![]SessionHit {
    var sorted: std.ArrayList(SessionHit) = .empty;
    errdefer sorted.deinit(gpa);

    for (hits) |h| {
        try sorted.append(gpa, h);
    }

    const items = sorted.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0) {
            const a = items[j - 1];
            const b = key;
            const dt = if (a.entry.created_at >= b.entry.created_at)
                a.entry.created_at - b.entry.created_at
            else
                b.entry.created_at - a.entry.created_at;
            const recency_wins = dt > 60;
            const swap = if (recency_wins) a.entry.created_at < b.entry.created_at else a.score < b.score;
            if (!swap) break;
            items[j] = a;
            j -= 1;
        }
        items[j] = key;
    }

    return sorted.toOwnedSlice(gpa);
}

/// Combined three-tier search. Tier 1 (title) is always run; tier 2
/// (transcript) supplements. Results are merged and ranked.
pub fn searchSessions(
    gpa: std.mem.Allocator,
    io: std.Io,
    entries: []const sessionindex.Entry,
    query: []const u8,
) ![]SessionHit {
    if (query.len == 0) return error.EmptyQuery;

    var hits: std.ArrayList(SessionHit) = .empty;
    errdefer hits.deinit(gpa);

    const title_hits = try searchTitle(gpa, entries, query);
    defer gpa.free(title_hits);
    for (title_hits) |h| { try hits.append(gpa, h); }

    const transcript_hits = try searchTranscript(gpa, io, entries, query);
    defer gpa.free(transcript_hits);
    for (transcript_hits) |h| { try hits.append(gpa, h); }

    return rankHits(gpa, hits.items);
}

// ── tests ───────────────────────────────────────────────────────────────────

const t = std.testing;

test "sessionProse: extracts user + assistant content only" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "sess_prose_test.jsonl",
        .data = "{\"role\":\"system\",\"content\":\"system instruction\"}\n"
            ++ "{\"role\":\"user\",\"content\":\"hello world\"}\n"
            ++ "{\"role\":\"tool\",\"content\":\"tool result noise\"}\n"
            ++ "{\"role\":\"assistant\",\"content\":\"hi there\"}\n",
    });

    const entry = sessionindex.Entry{
        .path = "sess_prose_test.jsonl",
        .name = "",
        .model = "",
        .custom_title = "",
        .ai_title = "",
        .created_at = 0,
    };
    const prose = try sessionProse(a, io, entry);
    defer a.free(prose);

    try std.testing.expect(std.mem.indexOf(u8, prose, "hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, prose, "hi there") != null);
    try std.testing.expect(std.mem.indexOf(u8, prose, "system instruction") == null);
    try std.testing.expect(std.mem.indexOf(u8, prose, "tool result noise") == null);
}

test "searchTitle: substring match on title" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const entries = try a.alloc(sessionindex.Entry, 3);
    defer a.free(entries);
    entries[0] = .{ .path = "a.jsonl", .name = "", .model = "", .custom_title = "fix the parser", .ai_title = "", .created_at = 100 };
    entries[1] = .{ .path = "b.jsonl", .name = "", .model = "", .custom_title = "", .ai_title = "parser fix", .created_at = 200 };
    entries[2] = .{ .path = "c.jsonl", .name = "", .model = "", .custom_title = "", .ai_title = "", .created_at = 300 };

    const hits = try searchTitle(a, entries, "parser");
    defer a.free(hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(std.mem.eql(u8, hits[0].entry.path, "a.jsonl") or std.mem.eql(u8, hits[0].entry.path, "b.jsonl"));
    try std.testing.expect(std.mem.eql(u8, hits[1].entry.path, "a.jsonl") or std.mem.eql(u8, hits[1].entry.path, "b.jsonl"));
}

test "rankHits: recency wins beyond 60s, relevance tiebreak within" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const now: i64 = 1_000_000;
    var hits = try a.alloc(SessionHit, 3);
    defer a.free(hits);
    hits[0] = .{ .entry = .{ .path = "a.jsonl", .name = "", .model = "", .custom_title = "", .ai_title = "", .created_at = now + 120 }, .tier = .title, .score = 10 };
    hits[1] = .{ .entry = .{ .path = "b.jsonl", .name = "", .model = "", .custom_title = "", .ai_title = "", .created_at = now + 30 }, .tier = .title, .score = 900 };
    hits[2] = .{ .entry = .{ .path = "c.jsonl", .name = "", .model = "", .custom_title = "", .ai_title = "", .created_at = now - 5000 }, .tier = .title, .score = 1000 };

    const ranked = try rankHits(a, hits);
    defer a.free(ranked);
    try std.testing.expectEqual(@as(usize, 3), ranked.len);
    try std.testing.expectEqual(ranked[0].entry.created_at, now + 120);
    try std.testing.expect(ranked[1].entry.created_at == now + 30);
}

test "searchSessions: combines title and transcript tiers" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const io = std.testing.io;
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "sess_combined_test.jsonl",
        .data = "{\"role\":\"user\",\"content\":\"distributed systems design\"}\n"
            ++ "{\"role\":\"assistant\",\"content\":\"here is the design\"}\n",
    });

    var entries = try a.alloc(sessionindex.Entry, 2);
    defer a.free(entries);
    entries[0] = .{ .path = "sess_combined_test.jsonl", .name = "", .model = "", .custom_title = "Design session", .ai_title = "", .created_at = 100 };
    entries[1] = .{ .path = "other.jsonl", .name = "", .model = "", .custom_title = "Unrelated", .ai_title = "", .created_at = 200 };

    const hits = try searchSessions(a, io, entries, "design");
    defer a.free(hits);
    try std.testing.expect(hits.len >= 1);
    var found = false;
    for (hits) |h| {
        if (std.mem.eql(u8, h.entry.path, "sess_combined_test.jsonl")) found = true;
    }
    try std.testing.expect(found);
}