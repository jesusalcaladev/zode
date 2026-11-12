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

/// Compact one-line file change card text.
///
/// Format (text fallback): `name  +A -R  ·  dir`
/// The leading marker/icon/label is left to the renderer so it can apply
/// theme roles and semantic file labels consistently.
pub fn formatCompact(buf: []u8, c: Change, nerd_icons: bool) []const u8 {
    _ = nerd_icons; // label/icon rendering is handled by the caller/renderer
    const parts = pathParts(c.path);
    if (parts.dir.len == 0 or std.mem.eql(u8, parts.dir, ".")) {
        return std.fmt.bufPrint(buf, "{s}  +{d} -{d}", .{ parts.base, c.added, c.removed }) catch parts.base;
    }
    return std.fmt.bufPrint(buf, "{s}  +{d} -{d}  ·  {s}", .{
        parts.base,
        c.added,
        c.removed,
        parts.dir,
    }) catch parts.base;
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
    try std.testing.expectEqualStrings("session.ts  +24 -8  ·  src/auth", line);
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
