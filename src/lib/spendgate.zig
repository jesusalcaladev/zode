//! Gate before you spend (Phase 32.3): four CHEAP local checks with
//! user-facing messages, run before anything expensive (a container, an
//! advisor LLM call, a large diff) starts.
//!
//! Fail-OPEN bias: an unreadable counter/utilization is `{ kind: .proceed }`.
//! An unreadable counter must not become a wall — the gate informs, and the
//! spend is the failure you can justify. This is deliberately LOUD about what
//! it could not read, never silent about a wall it invented.

const std = @import("std");

pub const Kind = enum { proceed, stop };

pub const Verdict = struct {
    kind: Kind = .proceed,
    /// User-facing messages, one per check that had something to say.
    notes: []const []const u8 = &.{},
};

/// The four checks, in order. All take plain data — no IO here, so it is
/// testable without a filesystem. The caller does the git/file reads and
/// hands the results in.
pub const Inputs = struct {
    /// Whether a merge-base with the main branch exists.
    has_merge_base: bool = true,
    /// Whether the diff against that base is non-empty.
    has_changes: bool = true,
    /// Number of files in the repository (only huge repos matter).
    repo_files: usize = 0,
    /// Whether a quota/utilization counter could be READ. Unreadable does NOT
    /// block — that is the fail-open bias.
    quota_readable: bool = true,
    /// Quota utilization fraction (0..1), only used when readable.
    quota_used: f64 = 0,
};

pub const repo_large_files: usize = 50_000;
pub const quota_high: f64 = 0.95;

pub fn decide(gpa: std.mem.Allocator, in: Inputs) !Verdict {
    var notes: std.ArrayList([]const u8) = .empty;
    errdefer notes.deinit(gpa);

    if (!in.has_merge_base) {
        try notes.append(gpa, "no merge-base with main: skipping the expensive check — compare against the branch you forked from");
        return .{ .kind = .stop, .notes = try notes.toOwnedSlice(gpa) };
    }
    if (!in.has_changes) {
        // "bail early on empty diffs instead of launching a container that
        // will just echo 'no changes'".
        try notes.append(gpa, "empty diff against main: nothing to verify — no container, no advisor call");
        return .{ .kind = .stop, .notes = try notes.toOwnedSlice(gpa) };
    }
    if (in.repo_files > repo_large_files) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa,
            "repository has {d} files (over the {d} threshold): the cheap check is skipped, spend with care",
            .{ in.repo_files, repo_large_files },
        ));
    }
    // Fail-OPEN: unreadable quota is a note and a proceed, never a wall.
    if (!in.quota_readable) {
        try notes.append(gpa, "quota/utilization could not be read: proceeding (an unreadable counter is not a wall)");
    } else if (in.quota_used >= quota_high) {
        try notes.append(gpa, try std.fmt.allocPrint(gpa,
            "quota {d:.0}% used: expensive work may be gated — proceed only if it is needed",
            .{in.quota_used * 100.0},
        ));
    }
    return .{ .kind = .proceed, .notes = try notes.toOwnedSlice(gpa) };
}

test "spendgate: empty diff stops before any expensive work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try decide(a, .{ .has_changes = false });
    try std.testing.expectEqual(Kind.stop, v.kind);
    try std.testing.expect(std.mem.indexOf(u8, v.notes[0], "empty diff") != null);
}

test "spendgate: no merge-base stops with a named reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try decide(arena.allocator(), .{ .has_merge_base = false });
    try std.testing.expectEqual(Kind.stop, v.kind);
    try std.testing.expect(std.mem.indexOf(u8, v.notes[0], "merge-base") != null);
}

test "spendgate: unreadable quota is fail-open, not a wall" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try decide(arena.allocator(), .{ .quota_readable = false });
    try std.testing.expectEqual(Kind.proceed, v.kind);
    var said = false;
    for (v.notes) |n| {
        if (std.mem.indexOf(u8, n, "not a wall") != null) said = true;
    }
    try std.testing.expect(said);
}

test "spendgate: a healthy diff with readable quota proceeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try decide(arena.allocator(), .{});
    try std.testing.expectEqual(Kind.proceed, v.kind);
    try std.testing.expectEqual(@as(usize, 0), v.notes.len);
}
