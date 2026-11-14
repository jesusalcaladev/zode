//! Per-project persistent memory: entries the user approved.
//!
//! Phase 11 keeps durable project knowledge in a small markdown store that is
//! **out of the prompt until consulted**. This module owns the pure parts:
//! parsing entry files, rendering them, and selecting results under an explicit
//! byte budget so oversized memories are never inlined.
//!
//! A memory is only persisted when the user approved it (the extractor proposes;
//! the store never accepts model-hallucinated durable facts silently).

const std = @import("std");
const skills = @import("../skills.zig");
const textcap = @import("../textcap.zig");

pub const max_title: usize = 120;
pub const max_body_bytes: usize = 32 * 1024;
pub const max_scan_entries: usize = 512;

pub const Entry = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    tags: []const u8 = "",
    evidence: []const u8 = "",
    body: []const u8 = "",
    /// Path the entry was loaded from, for display/precedence diagnostics.
    path: []const u8 = "",
    /// Runtime-only recall annotation (not persisted). Caller-owned.
    staleness: []const u8 = "",
};

pub const Meta = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    created_at: []const u8 = "",
    updated_at: []const u8 = "",
    tags: []const u8 = "",
    evidence: []const u8 = "",
};

/// Splits frontmatter from body using the same narrow `key: value` fence format
/// as skills/agents, then maps known memory keys.
pub fn parse(text: []const u8) Entry {
    const fm = skills.splitFrontmatter(text) orelse return .{ .body = std.mem.trim(u8, text, " \t\r\n") };
    return .{
        .id = fm.meta.name, // skills parser maps `name`; memory files may use `id` too
        .title = if (fm.meta.description.len > 0) fm.meta.description else fm.meta.name,
        .created_at = fm.meta.model, // unused slot in skills.Meta; parse directly below
        .updated_at = "",
        .tags = fm.meta.when_to_use,
        .evidence = fm.meta.allowed_tools,
        .body = std.mem.trim(u8, fm.body, " \t\r\n"),
    };
}

/// Parses memory-specific frontmatter keys directly (does not overload skills
/// semantics). Unknown keys are ignored.
pub fn parseMemory(text: []const u8) Entry {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "---")) return .{ .body = std.mem.trim(u8, text, " \t\r\n") };
    var rest = trimmed[3..];
    if (rest.len > 0 and rest[0] != '\n' and rest[0] != '\r') return .{ .body = std.mem.trim(u8, text, " \t\r\n") };
    if (std.mem.startsWith(u8, rest, "\r\n")) rest = rest[2..] else if (rest.len > 0 and rest[0] == '\n') rest = rest[1..];

    var e = Entry{};
    var i: usize = 0;
    while (i < rest.len) {
        const nl = std.mem.indexOfScalar(u8, rest[i..], '\n') orelse rest.len - i;
        const line = rest[i .. i + nl];
        i = @min(i + nl + 1, rest.len);
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, t, "---")) {
            e.body = std.mem.trim(u8, rest[i..], " \t\r\n");
            if (e.title.len == 0) e.title = e.id;
            return e;
        }
        if (t.len == 0 or t[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse continue;
        const key = std.mem.trim(u8, t[0..colon], " \t");
        var val = std.mem.trim(u8, t[colon + 1 ..], " \t");
        if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\'')))
            val = val[1 .. val.len - 1];
        if (std.mem.eql(u8, key, "id")) e.id = val else if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "name")) {
            if (e.title.len == 0 or std.mem.eql(u8, key, "title")) e.title = val;
            if (e.id.len == 0) e.id = val;
        } else if (std.mem.eql(u8, key, "created_at")) e.created_at = val else if (std.mem.eql(u8, key, "updated_at")) e.updated_at = val else if (std.mem.eql(u8, key, "tags")) e.tags = val else if (std.mem.eql(u8, key, "evidence")) e.evidence = val else if (std.mem.eql(u8, key, "paths")) e.evidence = val;
    }
    if (e.title.len == 0) e.title = e.id;
    return e;
}

/// Simple case-insensitive substring match over title/tags/body/id.
pub fn matches(e: Entry, query: []const u8) bool {
    if (query.len == 0) return true;
    return scoreMatch(e, query) > 0;
}

/// Relevance score for recall ranking. Higher is more relevant.
pub fn scoreMatch(e: Entry, query: []const u8) usize {
    if (query.len == 0) return 1;
    var score: usize = 0;
    if (containsIgnoreCase(e.id, query)) score += 8;
    if (containsIgnoreCase(e.title, query)) score += 6;
    if (containsIgnoreCase(e.tags, query)) score += 4;
    if (containsIgnoreCase(e.evidence, query)) score += 3;
    if (containsIgnoreCase(e.body, query)) score += 2;
    // Prefer entries with evidence/timestamps over bare notes on ties.
    if (e.evidence.len > 0) score += 1;
    if (e.updated_at.len > 0 or e.created_at.len > 0) score += 1;
    return score;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub const ConsultResult = struct {
    text: []u8,
    included: usize,
    omitted: usize,
};

/// Renders matching entries into an owned buffer, never exceeding `budget_bytes`.
/// Entries that do not fit are omitted entirely (never partially inlined in a way
/// that hides truncation) and counted in `omitted`. Matches are ranked by
/// relevance when a query is provided.
pub fn consult(gpa: std.mem.Allocator, entries: []const Entry, query: []const u8, budget_bytes: usize) !ConsultResult {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var included: usize = 0;
    var omitted: usize = 0;

    try out.appendSlice(gpa, "[Project memory]\n");
    if (query.len > 0) {
        try out.appendSlice(gpa, "query: ");
        try out.appendSlice(gpa, query);
        try out.appendSlice(gpa, "\n");
    }

    // Select and rank matches (relevance recall).
    var matched: std.ArrayListUnmanaged(Entry) = .empty;
    defer matched.deinit(gpa);
    for (entries) |e| {
        if (!matches(e, query)) continue;
        try matched.append(gpa, e);
    }
    if (query.len > 0 and matched.items.len > 1) {
        const Ctx = struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                // `query` is captured via threadlocal-ish not possible; compare by precomputed
                // stable fields only is insufficient. Use a second pass via sort with cached scores
                // by embedding score in a wrapper? keep simple: compare id/title/body presence not enough.
                // Fallback: compare by (has title/tag/body richness, id) — actual query scoring done below.
                const aa = if (a.id.len > 0) a.id else a.title;
                const bb = if (b.id.len > 0) b.id else b.title;
                return std.mem.lessThan(u8, aa, bb);
            }
        };
        _ = Ctx;
    }
    // Rank by score desc for query recall (stable by original id/title on ties).
    if (query.len > 0 and matched.items.len > 1) {
        // Insertion sort is fine for small bounded memory lists.
        var i: usize = 1;
        while (i < matched.items.len) : (i += 1) {
            const x = matched.items[i];
            const sx = scoreMatch(x, query);
            var j: usize = i;
            while (j > 0) : (j -= 1) {
                const y = matched.items[j - 1];
                const sy = scoreMatch(y, query);
                const better = sx > sy or (sx == sy and std.mem.lessThan(u8,
                    if (x.id.len > 0) x.id else x.title,
                    if (y.id.len > 0) y.id else y.title));
                if (!better) break;
                matched.items[j] = y;
            }
            matched.items[j] = x;
        }
    }

    for (matched.items) |e| {
        var item: std.ArrayListUnmanaged(u8) = .empty;
        defer item.deinit(gpa);
        try item.appendSlice(gpa, "\n---\n");
        try item.appendSlice(gpa, "id: ");
        try item.appendSlice(gpa, if (e.id.len > 0) e.id else "(unknown)");
        try item.appendSlice(gpa, "\n");
        if (e.title.len > 0) {
            try item.appendSlice(gpa, "title: ");
            try item.appendSlice(gpa, e.title);
            try item.appendSlice(gpa, "\n");
        }
        if (e.tags.len > 0) {
            try item.appendSlice(gpa, "tags: ");
            try item.appendSlice(gpa, e.tags);
            try item.appendSlice(gpa, "\n");
        }
        if (e.updated_at.len > 0) {
            try item.appendSlice(gpa, "updated_at: ");
            try item.appendSlice(gpa, e.updated_at);
            try item.appendSlice(gpa, "\n");
        } else if (e.created_at.len > 0) {
            try item.appendSlice(gpa, "created_at: ");
            try item.appendSlice(gpa, e.created_at);
            try item.appendSlice(gpa, "\n");
        }
        if (e.evidence.len > 0) {
            try item.appendSlice(gpa, "evidence: ");
            try item.appendSlice(gpa, e.evidence);
            try item.appendSlice(gpa, "\n");
        }
        if (e.staleness.len > 0) {
            try item.appendSlice(gpa, "staleness: ");
            try item.appendSlice(gpa, e.staleness);
            try item.appendSlice(gpa, "\n");
        }
        try item.appendSlice(gpa, "\n");
        const body = if (e.body.len > max_body_bytes) e.body[0..max_body_bytes] else e.body;
        try item.appendSlice(gpa, body);
        if (e.body.len > max_body_bytes) try item.appendSlice(gpa, "\n(truncated)");
        try item.appendSlice(gpa, "\n");

        if (out.items.len + item.items.len > budget_bytes) {
            omitted += 1;
            continue;
        }
        try out.appendSlice(gpa, item.items);
        included += 1;
    }

    if (included == 0 and omitted == 0) {
        try out.appendSlice(gpa, "\n(no matching memories)\n");
    } else if (omitted > 0) {
        var note_buf: [96]u8 = undefined;
        const note = std.fmt.bufPrint(&note_buf, "\n({d} matching memories omitted: outside consultation budget)\n", .{omitted}) catch "";
        if (out.items.len + note.len <= budget_bytes) try out.appendSlice(gpa, note);
    }
    return .{ .text = try out.toOwnedSlice(gpa), .included = included, .omitted = omitted };
}

/// Renders a new memory file (frontmatter + body). Caller frees.
pub fn renderEntry(gpa: std.mem.Allocator, id: []const u8, title: []const u8, tags: []const u8, evidence: []const u8, body: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "---\n");
    try out.appendSlice(gpa, "id: ");
    try out.appendSlice(gpa, id);
    try out.appendSlice(gpa, "\n");
    try out.appendSlice(gpa, "title: \"");
    for (title) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r') try out.append(gpa, ' ') else try out.append(gpa, c);
    }
    try out.appendSlice(gpa, "\"\n");
    if (tags.len > 0) {
        try out.appendSlice(gpa, "tags: \"");
        try out.appendSlice(gpa, tags);
        try out.appendSlice(gpa, "\"\n");
    }
    if (evidence.len > 0) {
        try out.appendSlice(gpa, "evidence: \"");
        for (evidence) |c| {
            if (c == '"' or c == '\\' or c == '\n' or c == '\r') try out.append(gpa, ' ') else try out.append(gpa, c);
        }
        try out.appendSlice(gpa, "\"\n");
    }
    try out.appendSlice(gpa, "---\n\n");
    try out.appendSlice(gpa, std.mem.trim(u8, body, " \t\r\n"));
    try out.appendSlice(gpa, "\n");
    return out.toOwnedSlice(gpa);
}

fn renderListLine(e: Entry, out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator) !void {
    try out.appendSlice(gpa, "- ");
    try out.appendSlice(gpa, if (e.id.len > 0) e.id else "?");
    try out.appendSlice(gpa, ": ");
    const title = if (e.title.len > 0) e.title else "(untitled)";
    const cap = @min(title.len, max_title);
    try out.appendSlice(gpa, title[0..cap]);
    if (e.tags.len > 0) {
        try out.appendSlice(gpa, " [");
        try out.appendSlice(gpa, e.tags);
        try out.appendSlice(gpa, "]");
    }
    if (e.staleness.len > 0) {
        try out.appendSlice(gpa, " {stale: ");
        try out.appendSlice(gpa, e.staleness);
        try out.appendSlice(gpa, "}");
    }
    try out.appendSlice(gpa, "\n");
}

pub fn renderList(gpa: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "[Project memory entries]\n");
    if (entries.len == 0) {
        try out.appendSlice(gpa, "(no memories)\n");
        return out.toOwnedSlice(gpa);
    }
    for (entries) |e| try renderListLine(e, &out, gpa);
    return out.toOwnedSlice(gpa);
}

/// Best-effort staleness note for recall: flags missing evidence paths.
/// Evidence may be comma/space/newline-separated; tokens that look like file
/// paths are checked relative to cwd and repo root. Returns empty when nothing
/// looks stale, else an owned note.
pub fn stalenessNote(gpa: std.mem.Allocator, io: std.Io, cwd: []const u8, repo_root: ?[]const u8, e: Entry) []const u8 {
    if (e.evidence.len == 0) {
        if (e.updated_at.len == 0 and e.created_at.len == 0) return gpa.dupe(u8, "no evidence or timestamp") catch "";
        return "";
    }
    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, e.evidence, ", \t\r\n");
    var n_missing: usize = 0;
    var n_checked: usize = 0;
    while (it.next()) |tok_raw| {
        const tok = std.mem.trim(u8, tok_raw, "\"'`()[]");
        if (tok.len == 0) continue;
        // Heuristic: path-like tokens only (avoid flagging plain text evidence).
        const looks_path = std.mem.indexOfScalar(u8, tok, '/') != null or std.mem.indexOfScalar(u8, tok, '.') != null;
        if (!looks_path) continue;
        n_checked += 1;
        if (pathExists(io, cwd, repo_root, tok)) continue;
        n_missing += 1;
        if (missing.items.len == 0) missing.appendSlice(gpa, "missing evidence: ") catch {} else missing.appendSlice(gpa, ", ") catch {};
        const cap = @min(tok.len, 80);
        missing.appendSlice(gpa, tok[0..cap]) catch {};
    }
    if (n_checked == 0) {
        // Evidence text but no path-like tokens; can't verify, not a staleness error.
        if (e.updated_at.len == 0 and e.created_at.len == 0) return gpa.dupe(u8, "evidence not path-verifiable") catch "";
        return "";
    }
    if (n_missing == 0) return "";
    if (missing.items.len == 0) return gpa.dupe(u8, "evidence paths missing") catch "";
    return missing.toOwnedSlice(gpa) catch "";
}

fn pathExists(io: std.Io, cwd: []const u8, repo_root: ?[]const u8, path: []const u8) bool {
    if (path.len == 0) return false;
    // Absolute-ish or repo-relative: try as-is from cwd, then from repo root.
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
    if (f) |*ff| { ff.close(io); return true; }
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch null;
    if (d) |*dd| { dd.close(io); return true; }
    if (cwd.len > 0 and path[0] != '/') {
        var b1: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fmt.bufPrint(&b1, "{s}/{s}", .{ cwd, path })) |p| {
            f = std.Io.Dir.cwd().openFile(io, p, .{}) catch null;
            if (f) |*ff| { ff.close(io); return true; }
            d = std.Io.Dir.cwd().openDir(io, p, .{}) catch null;
            if (d) |*dd| { dd.close(io); return true; }
        } else |_| {}
    }
    if (repo_root) |root| {
        if (root.len > 0 and path[0] != '/') {
            var b2: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrint(&b2, "{s}/{s}", .{ root, path })) |p| {
                f = std.Io.Dir.cwd().openFile(io, p, .{}) catch null;
                if (f) |*ff| { ff.close(io); return true; }
                d = std.Io.Dir.cwd().openDir(io, p, .{}) catch null;
                if (d) |*dd| { dd.close(io); return true; }
            } else |_| {}
        }
    }
    return false;
}

test "parseMemory: reads frontmatter and body" {
    const text =
        \\---
        \\id: auth-flow
        \\title: "Auth flow uses bearer tokens"
        \\tags: auth, api
        \\evidence: src/lib/providers.zig
        \\---
        \\
        \\The provider key is sent as a bearer token.
    ;
    const e = parseMemory(text);
    try std.testing.expectEqualStrings("auth-flow", e.id);
    try std.testing.expectEqualStrings("Auth flow uses bearer tokens", e.title);
    try std.testing.expectEqualStrings("auth, api", e.tags);
    try std.testing.expect(std.mem.indexOf(u8, e.body, "bearer token") != null);
}

test "consult: a memory outside the budget is not inlined" {
    var big_buf: [400]u8 = undefined;
    @memset(&big_buf, 'B');
    var items = [_]Entry{
        .{ .id = "small", .title = "small", .body = "ok" },
        .{ .id = "big", .title = "big", .body = "" },
    };
    items[1].body = &big_buf;

    const r = try consult(std.testing.allocator, &items, "", 120);
    defer std.testing.allocator.free(r.text);
    try std.testing.expect(r.included >= 1);
    try std.testing.expect(r.omitted >= 1);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "id: small") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "id: big") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "omitted") != null);
}

test "consult: query filters entries" {
    const entries = [_]Entry{
        .{ .id = "a", .title = "Auth tokens", .body = "bearer" },
        .{ .id = "b", .title = "UI layout", .body = "footer" },
    };
    const r = try consult(std.testing.allocator, &entries, "auth", 4096);
    defer std.testing.allocator.free(r.text);
    try std.testing.expectEqual(@as(usize, 1), r.included);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "id: a") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "id: b") == null);
}

test "renderEntry: round-trips through parseMemory" {
    const text = try renderEntry(std.testing.allocator, "m1", "My memory", "tag1", "file.zig", "body line");
    defer std.testing.allocator.free(text);
    const e = parseMemory(text);
    try std.testing.expectEqualStrings("m1", e.id);
    try std.testing.expectEqualStrings("My memory", e.title);
    try std.testing.expect(std.mem.indexOf(u8, e.body, "body line") != null);
}
