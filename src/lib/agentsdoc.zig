//! Instruction-file loading with `@import` expansion.
//!
//! zode already injects a project's instruction file (`AGENTS.md` /
//! `CLAUDE.md`) into the system prompt. This module adds the part that makes a
//! large instruction file maintainable: an `@import` directive that pulls in
//! another file, resolved relative to the file that contains the directive.
//!
//! The expansion is deliberately narrow and deterministic:
//! - A line whose trimmed content starts with `@import ` is a directive.
//! - The path is the rest of the line, optionally wrapped in double quotes.
//! - Paths resolve relative to the importing file's directory.
//! - Cycles and excessive depth are refused with a visible marker, not a crash.
//! - A missing import becomes a visible marker, not a silent drop: a partial
//!   instruction file that still loads is better than one that disappears.
//!
//! Pure in its decisions, testable with temp-root fixtures (all I/O goes through
//! the `io` and path arguments the caller provides).

const std = @import("std");

pub const max_depth: usize = 8;
pub const max_file_bytes: usize = 1024 * 1024;
pub const max_expanded_bytes: usize = 1024 * 1024;

/// Expands `@import` directives in `text`. `file_dir` is the directory of the
/// file `text` came from (absolute or cwd-relative), used to resolve imports.
/// `visited` tracks normalized absolute paths already being expanded to detect
/// cycles. Returns owned bytes; the caller frees with `gpa`.
pub fn expand(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_dir: []const u8,
    text: []const u8,
    depth: usize,
    visited: *std.ArrayListUnmanaged([]const u8),
) anyerror![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    if (depth > max_depth) {
        try out.appendSlice(gpa, "<!-- zode: @import depth limit reached -->\n");
        try out.appendSlice(gpa, text);
        return out.toOwnedSlice(gpa);
    }

    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw_line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        // Preserve CRLF input lines as LF in output (normalize); keep the line
        // content without a trailing \r.
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (parseImport(line)) |import_path| {
            try expandOne(gpa, io, file_dir, import_path, depth, visited, &out);
            // The import replaces the directive line entirely.
        } else {
            try out.appendSlice(gpa, line);
        }
        if (out.items.len > max_expanded_bytes) {
            out.shrinkRetainingCapacity(max_expanded_bytes);
            try out.appendSlice(gpa, "\n<!-- zode: instruction file truncated after @import expansion -->\n");
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn expandOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    file_dir: []const u8,
    import_path: []const u8,
    depth: usize,
    visited: *std.ArrayListUnmanaged([]const u8),
    out: *std.ArrayListUnmanaged(u8),
) anyerror!void {
    if (import_path.len == 0) {
        try out.appendSlice(gpa, "<!-- zode: @import missing path -->");
        return;
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined = joinPath(&path_buf, file_dir, import_path) orelse {
        try appendMarker(out, gpa, "invalid", import_path);
        return;
    };
    var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const norm = normalizePath(&norm_buf, joined) orelse {
        try appendMarker(out, gpa, "invalid", import_path);
        return;
    };

    for (visited.items) |v| {
        if (std.mem.eql(u8, v, norm)) {
            try appendMarker(out, gpa, "cycle", import_path);
            return;
        }
    }

    const data = std.Io.Dir.cwd().readFileAlloc(io, norm, gpa, .limited(max_file_bytes)) catch {
        try appendMarker(out, gpa, "missing", import_path);
        return;
    };
    defer gpa.free(data);

    const norm_owned = try gpa.dupe(u8, norm);
    try visited.append(gpa, norm_owned);
    defer {
        _ = visited.pop();
        gpa.free(norm_owned);
    }

    var child_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const child_dir = dirOf(norm, &child_dir_buf) orelse file_dir;
    const expanded = try expand(gpa, io, child_dir, data, depth + 1, visited);
    defer gpa.free(expanded);
    try out.appendSlice(gpa, expanded);
}

fn appendMarker(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, kind: []const u8, path: []const u8) !void {
    try out.appendSlice(gpa, "<!-- zode: @import ");
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, ": ");
    // Keep markers single-line and safe for embedding.
    for (path) |c| {
        if (c == '\n' or c == '\r' or c == '-' and false) break;
        try out.append(gpa, if (c == '<' or c == '>' or c == '\n' or c == '\r') '_' else c);
    }
    try out.appendSlice(gpa, " -->");
}

/// Parses an `@import` directive from a single line. Returns the path, or null.
pub fn parseImport(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, "@import")) return null;
    const rest0 = t["@import".len..];
    if (rest0.len == 0) return "";
    if (rest0[0] != ' ' and rest0[0] != '\t') return null;
    const rest = std.mem.trim(u8, rest0, " \t");
    if (rest.len == 0) return "";
    if (rest[0] == '"') {
        if (rest.len < 2) return "";
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return rest[1..];
        return rest[1..end];
    }
    // Unquoted: take until whitespace/comment-ish end of token.
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ' and rest[end] != '\t') : (end += 1) {}
    return rest[0..end];
}

/// Reads `{dir}/{name}` and expands its imports. Returns owned bytes or null
/// when the file cannot be read (missing/too big/unreadable).
pub fn readExpandedAt(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8) ?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch return null;
    defer gpa.free(data);

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_dir = dirOf(path, &dir_buf) orelse dir;
    var visited: std.ArrayListUnmanaged([]const u8) = .empty;
    defer visited.deinit(gpa);
    return expand(gpa, io, file_dir, data, 0, &visited) catch return null;
}

fn dirOf(path: []const u8, buf: []u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (slash == 0) return "/";
    if (slash >= buf.len) return null;
    @memcpy(buf[0..slash], path[0..slash]);
    return buf[0..slash];
}

fn joinPath(buf: []u8, base: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0) return null;
    if (rel[0] == '/') {
        if (rel.len > buf.len) return null;
        @memcpy(buf[0..rel.len], rel);
        return buf[0..rel.len];
    }
    const need = base.len + 1 + rel.len;
    if (need > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 .. need], rel);
    return buf[0..need];
}

/// Lexical path normalization (resolves `.` and `..` segments). Absolute paths
/// stay absolute; relative paths stay relative. Does not touch the filesystem.
fn normalizePath(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const abs = path[0] == '/';
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    defer parts.deinit(std.heap.page_allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!abs) {
                parts.append(std.heap.page_allocator, seg) catch return null;
            }
            continue;
        }
        parts.append(std.heap.page_allocator, seg) catch return null;
    }

    var w: std.Io.Writer = .fixed(buf);
    if (abs) w.writeByte('/') catch return null;
    for (parts.items, 0..) |p, i| {
        if (i > 0) w.writeByte('/') catch return null;
        w.writeAll(p) catch return null;
    }
    const out = w.buffered();
    if (out.len == 0) return if (abs) "/" else ".";
    return out;
}

// ── tests ─────────────────────────────────────────────────────

const testing = std.testing;

test "parseImport: quoted and unquoted forms" {
    try testing.expectEqualStrings("a/b.md", parseImport("@import \"a/b.md\"").?);
    try testing.expectEqualStrings("a/b.md", parseImport("  @import a/b.md").?);
    try testing.expectEqualStrings("shared/rules.md", parseImport("@import\t\"shared/rules.md\"").?);
    try testing.expect(parseImport("not an import") == null);
    try testing.expect(parseImport("@imported") == null);
    try testing.expectEqualStrings("", parseImport("@import").?);
}

test "expand: resolves imports relative to the importing file with temp-root fixture" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "proj/sub");
    try tmp.dir.createDirPath(testing.io, "proj/shared");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/shared/rules.md", .data = "RULE-LINE\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "proj/sub/AGENTS.md", .data = "before\n@import \"../shared/rules.md\"\nafter\n" });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];

    const got = readExpandedAt(testing.allocator, testing.io, blk: {
        var p: [std.fs.max_path_bytes]u8 = undefined;
        break :blk try std.fmt.bufPrint(&p, "{s}/proj/sub", .{root});
    }, "AGENTS.md") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "before") != null);
    try testing.expect(std.mem.indexOf(u8, got, "RULE-LINE") != null);
    try testing.expect(std.mem.indexOf(u8, got, "after") != null);
    try testing.expect(std.mem.indexOf(u8, got, "@import") == null);
}

test "expand: missing import becomes a visible marker and does not fail the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "p");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "p/AGENTS.md", .data = "head\n@import \"nope.md\"\ntail\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&p, "{s}/p", .{root});
    const got = readExpandedAt(testing.allocator, testing.io, dir, "AGENTS.md") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "head") != null);
    try testing.expect(std.mem.indexOf(u8, got, "tail") != null);
    try testing.expect(std.mem.indexOf(u8, got, "@import missing") != null);
}

test "expand: cycle detection stops infinite recursion" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "c");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c/a.md", .data = "A\n@import \"b.md\"\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c/b.md", .data = "B\n@import \"a.md\"\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var p: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&p, "{s}/c", .{root});
    const got = readExpandedAt(testing.allocator, testing.io, dir, "a.md") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "A") != null);
    try testing.expect(std.mem.indexOf(u8, got, "B") != null);
    try testing.expect(std.mem.indexOf(u8, got, "@import cycle") != null);
}

test "normalizePath: resolves dot segments lexically" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/a/c", normalizePath(&buf, "/a/b/../c").?);
    try testing.expectEqualStrings("/a/b", normalizePath(&buf, "/a/./b").?);
    try testing.expectEqualStrings("a/c", normalizePath(&buf, "a/b/../c").?);
}
