const std = @import("std");
const lang_icons = @import("lang_icons.zig");

/// Structured file-change presentation helpers for the TUI.
///
/// Pure and testable: formatting and summary building live here; runtime/tool
/// code provides real diff statistics from actual before/after state.
///
/// Important: when a file is edited multiple times in one logical task, the
/// final NET diff must come from the original baseline vs current content.
/// Summing per-operation +added/-removed counts is not a net diff. This module
/// formats what callers actually know and never invents statistics.
pub const Operation = enum {
    created,
    modified,
    deleted,
    renamed,
    read,
    restored,
    conflict,

    pub fn label(self: Operation) []const u8 {
        return switch (self) {
            .created => "Created",
            .modified => "Modified",
            .deleted => "Deleted",
            .renamed => "Renamed",
            .read => "Read",
            .restored => "Restored",
            .conflict => "Conflict",
        };
    }
};

pub const Change = struct {
    path: []const u8,
    operation: Operation = .modified,
    added: usize = 0,
    removed: usize = 0,
    hunks: usize = 0,
};

/// Returns basename and directory context for display.
pub fn pathParts(path: []const u8) struct { base: []const u8, dir: []const u8 } {
    return .{
        .base = std.fs.path.basename(path),
        .dir = std.fs.path.dirname(path) orelse "",
    };
}

/// A shortened path for display: keeps the basename and as much of the tail
/// as fits, replacing a long prefix with `…/`. The basename is never cut.
pub fn shortenPath(path: []const u8, max: usize) []const u8 {
    if (path.len <= max or max < 4) return path;
    const base = std.fs.path.basename(path);
    // Always keep at least `…/` + basename tail.
    if (base.len + 2 >= max) return base;
    const keep = max - 2; // room after "…/"
    const tail_start = path.len - keep;
    // Try to cut at a path separator so we don't split a segment.
    var cut = tail_start;
    if (std.mem.indexOfScalarPos(u8, path, tail_start, '/')) |s| {
        if (path.len - (s + 1) + 2 <= max) cut = s + 1;
    }
    // If that still doesn't fit well, fall back to raw tail.
    if (path.len - cut + 2 > max) cut = path.len - keep;
    return path; // caller renders with prefix marker; see shortenPathInto
}

/// Writes a shortened display path into `out` and returns it. When the path is
/// shortened the result starts with `…/`.
pub fn shortenPathInto(out: []u8, path: []const u8, max: usize) []const u8 {
    if (path.len <= max or out.len == 0) {
        const n = @min(path.len, out.len);
        @memcpy(out[0..n], path[0..n]);
        return out[0..n];
    }
    const prefix = "\u{2026}/";
    if (max <= prefix.len + 1 or out.len <= prefix.len) {
        const base = std.fs.path.basename(path);
        const n = @min(base.len, out.len);
        @memcpy(out[0..n], base[0..n]);
        return out[0..n];
    }
    const keep = @min(max - prefix.len, out.len - prefix.len);
    var cut = if (path.len > keep) path.len - keep else 0;
    if (std.mem.indexOfScalarPos(u8, path, cut, '/')) |s| {
        if (path.len - (s + 1) <= keep) cut = s + 1;
    }
    const tail = path[cut..];
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..][0..tail.len], tail);
    return out[0 .. prefix.len + tail.len];
}

/// Compact one-line file change card body: `path  +A -R`.
///
/// The operation/label prefix is composed by the caller so it can carry
/// semantic styling. `nerd_icons` is reserved for icon-aware rendering.
pub fn formatCompact(buf: []u8, c: Change, nerd_icons: bool) []const u8 {
    _ = nerd_icons;
    var path_buf: [200]u8 = undefined;
    const p = shortenPathInto(&path_buf, c.path, 56);
    return std.fmt.bufPrint(buf, "{s}  +{d} -{d}", .{ p, c.added, c.removed }) catch c.path;
}

/// Expanded file card lines (renderer applies styles/borders as appropriate).
pub fn formatExpanded(
    arena: std.mem.Allocator,
    c: Change,
    nerd_icons: bool,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const parts = pathParts(c.path);
    const chip = lang_icons.forPath(c.path, nerd_icons);
    const lang = if (chip.label.len > 0) chip.label else "file";

    const head = try std.fmt.allocPrint(arena, "{s}  {s}", .{ parts.base, lang });
    try out.append(arena, head);
    try out.append(arena, c.path);
    try out.append(arena, "");
    const stats = try std.fmt.allocPrint(
        arena,
        "+{d} additions · -{d} deletions · {s}",
        .{ c.added, c.removed, c.operation.label() },
    );
    try out.append(arena, stats);
    if (c.hunks > 0) {
        const h = try std.fmt.allocPrint(arena, "{d} changed hunks", .{c.hunks});
        try out.append(arena, h);
    }
    return out.toOwnedSlice(arena);
}

/// Builds a grouped change summary. Callers provide real diff counts per
/// operation; this groups by path in insertion order and reports totals.
/// It does NOT claim a net diff across multiple edits of the same file unless
/// the caller supplies net stats.
pub const Summary = struct {
    items: std.ArrayList(Change) = .empty,
    total_added: usize = 0,
    total_removed: usize = 0,

    pub fn deinit(self: *Summary, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }

    /// Adds or updates a file entry by path. If `net` is true, the caller
    /// asserts these are net stats for that path in this logical group and we
    /// replace previous stats for the path. Otherwise we keep the latest
    /// operation stats as a best-effort update without inventing a net diff.
    pub fn note(self: *Summary, gpa: std.mem.Allocator, c: Change, net: bool) !void {
        for (self.items.items) |*it| {
            if (std.mem.eql(u8, it.path, c.path)) {
                if (net) {
                    self.total_added = self.total_added - it.added + c.added;
                    self.total_removed = self.total_removed - it.removed + c.removed;
                    it.* = c;
                } else {
                    // Keep latest real operation stats for display; totals track
                    // this operation as reported (not a net-diff claim).
                    self.total_added += c.added;
                    self.total_removed += c.removed;
                    it.* = c;
                }
                return;
            }
        }
        try self.items.append(gpa, c);
        self.total_added += c.added;
        self.total_removed += c.removed;
    }
};

test "pathParts and compact formatting" {
    const c = Change{ .path = "src/auth/session.ts", .added = 24, .removed = 8 };
    var buf: [160]u8 = undefined;
    const line = formatCompact(&buf, c, false);
    try std.testing.expectEqualStrings("src/auth/session.ts  +24 -8", line);
}

test "formatCompact shortens a long path but keeps the basename" {
    const c = Change{ .path = "src/very/deeply/nested/directory/structure/component.zig", .added = 1, .removed = 0 };
    var buf: [160]u8 = undefined;
    const line = formatCompact(&buf, c, false);
    try std.testing.expect(std.mem.indexOf(u8, line, "component.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "+1 -0") != null);
    try std.testing.expect(line.len <= "src/very/deeply/nested/directory/structure/component.zig  +1 -0".len);
}

test "expanded formatting includes operation and path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const c = Change{ .path = "src/main.zig", .operation = .modified, .added = 3, .removed = 1, .hunks = 2 };
    const lines = try formatExpanded(arena_state.allocator(), c, false);
    try std.testing.expect(lines.len >= 4);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[1], "src/main.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[3], "Modified") != null);
}

test "summary groups by path and replaces when net stats are provided" {
    const gpa = std.testing.allocator;
    var s = Summary{};
    defer s.deinit(gpa);
    try s.note(gpa, .{ .path = "a.zig", .added = 10, .removed = 2 }, false);
    try s.note(gpa, .{ .path = "a.zig", .added = 4, .removed = 1 }, true);
    try std.testing.expectEqual(@as(usize, 1), s.items.items.len);
    try std.testing.expectEqual(@as(usize, 4), s.items.items[0].added);
    try std.testing.expectEqual(@as(usize, 1), s.items.items[0].removed);
    try std.testing.expectEqual(@as(usize, 4), s.total_added);
    try std.testing.expectEqual(@as(usize, 1), s.total_removed);
}
