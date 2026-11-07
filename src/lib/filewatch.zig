//! Poll of the files the session already read: what changed since.
//!
//! No OS watcher: an inotify backend would be Linux-only, would need a
//! thread, a persist layer and a debounce policy, all to detect what the
//! read cache already detects lazily. The cheap version is a poll at the
//! start of each turn over the files the model has in context (at most
//! `max_tracked`, usually tens): `stat` tells us if they moved, the content
//! hash tells us if they really changed (a `touch` moves the mtime and the
//! hash does not), and only a confirmed change invalidates cached reads and
//! sourced facts or reaches the model.
//!
//! Pure on purpose: the snapshots are values, `changed` is a comparison, no
//! I/O, no TUI, no network. The caller stats and hashes; this module decides
//! what counts as changed, so the decision is pinned by tests and the I/O
//! stays thin and boring.

const std = @import("std");

/// Ceiling on the tracked set, matching the read cache's largest ladder step
/// (512 at a 1M window). Past it the caller ignores the extras: a miss costs
/// a re-read, not a lie.
pub const max_tracked: usize = 512;
/// Ceiling on the changes reported in one poll. Past it the rest are dropped:
/// a notice that lists 300 files helps nobody.
pub const max_changed: usize = 64;
pub const path_max: usize = 512;

/// One file at one moment: what the read cache remembered, or what a fresh
/// `stat` just said. `hash == 0` means "not hashed yet" — a `stat`-only
/// snapshot, which is exactly the `cur` side of a poll.
pub const Snapshot = struct {
    path: [path_max]u8 = undefined,
    path_len: u16 = 0,
    inode: u64 = 0,
    mtime_ns: i128 = 0,
    size: u64 = 0,
    hash: u64 = 0,

    pub fn pathOf(self: *const Snapshot) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Fills the snapshot from a path and a `stat` result (the shape
    /// `readcache.check` reads: `.inode`, `.size`, `.mtime.nanoseconds`).
    pub fn ofStat(path: []const u8, st: anytype, hash: u64) Snapshot {
        var s: Snapshot = .{ .hash = hash };
        const n = @min(path.len, path_max);
        @memcpy(s.path[0..n], path[0..n]);
        s.path_len = @intCast(n);
        s.inode = @intCast(st.inode);
        s.mtime_ns = st.mtime.nanoseconds;
        s.size = st.size;
        return s;
    }
};

pub const Change = struct {
    path: [path_max]u8 = undefined,
    path_len: u16 = 0,
    old_hash: u64 = 0,
    /// 0 when the file is gone or unreadable: the old content is definitely
    /// not what is on disk any more.
    new_hash: u64 = 0,
    disappeared: bool = false,

    pub fn pathOf(self: *const Change) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Compares `prev` (what the session read) with `cur` (what `stat` says now)
/// and fills `out` with the files that MOVED: different inode (renamed over),
/// different mtime, or different size. A file only in `cur` is ignored — it
/// was never in the context, so there is nothing to invalidate. A file only
/// in `prev` is reported as disappeared.
///
/// `cur[i].hash` carries over into the change (0 until the caller hashes);
/// the caller re-hashes the candidates and discards the ones whose bytes did
/// not actually change, the same rule the read cache applies.
pub fn changed(prev: []const Snapshot, cur: []const Snapshot, out: []Change) usize {
    var n: usize = 0;
    outer: for (prev) |p| {
        var found: ?Snapshot = null;
        for (cur) |c| {
            if (std.mem.eql(u8, p.pathOf(), c.pathOf())) {
                found = c;
                break;
            }
        }
        const c = found orelse {
            if (n >= out.len) break :outer;
            const len = @min(p.pathOf().len, path_max);
            @memcpy(out[n].path[0..len], p.pathOf()[0..len]);
            out[n].path_len = @intCast(len);
            out[n].old_hash = p.hash;
            out[n].new_hash = 0;
            out[n].disappeared = true;
            n += 1;
            continue :outer;
        };
        const moved = p.inode != c.inode or p.mtime_ns != c.mtime_ns or p.size != c.size;
        if (!moved) continue;
        if (n >= out.len) break;
        const len = @min(p.pathOf().len, path_max);
        @memcpy(out[n].path[0..len], p.pathOf()[0..len]);
        out[n].path_len = @intCast(len);
        out[n].old_hash = p.hash;
        out[n].new_hash = c.hash;
        out[n].disappeared = false;
        n += 1;
    }
    return n;
}

// ── tests ─────────────────────────────────────────────────────────────

fn snap(path: []const u8, inode: u64, mtime: i128, size: u64, hash: u64) Snapshot {
    var s: Snapshot = .{ .inode = inode, .mtime_ns = mtime, .size = size, .hash = hash };
    @memcpy(s.path[0..path.len], path);
    s.path_len = @intCast(path.len);
    return s;
}

test "filewatch: unchanged set reports no change" {
    const prev = [_]Snapshot{
        snap("a.zig", 1, 100, 10, 0xaa),
        snap("b.zig", 2, 200, 20, 0xbb),
    };
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 0), changed(&prev, &prev, &out));
}

test "filewatch: mtime moved means changed" {
    const prev = [_]Snapshot{snap("a.zig", 1, 100, 10, 0xaa)};
    const cur = [_]Snapshot{snap("a.zig", 1, 200, 10, 0)};
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 1), changed(&prev, &cur, &out));
    try std.testing.expectEqualStrings("a.zig", out[0].pathOf());
    try std.testing.expectEqual(@as(u64, 0xaa), out[0].old_hash);
    try std.testing.expect(!out[0].disappeared);
}

test "filewatch: renamed over (new inode) means changed even if mtime matches" {
    const prev = [_]Snapshot{snap("a.zig", 1, 100, 10, 0xaa)};
    const cur = [_]Snapshot{snap("a.zig", 7, 100, 10, 0)};
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 1), changed(&prev, &cur, &out));
    // Same length, same mtime: a size-only cache would call it unchanged.
    const same = [_]Snapshot{snap("a.zig", 1, 100, 11, 0)};
    try std.testing.expectEqual(@as(usize, 1), changed(&prev, &same, &out));
}

test "filewatch: disappeared file is reported with hash 0" {
    const prev = [_]Snapshot{snap("gone.zig", 1, 100, 10, 0xaa)};
    const empty = [_]Snapshot{};
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 1), changed(&prev, &empty, &out));
    try std.testing.expect(out[0].disappeared);
    try std.testing.expectEqual(@as(u64, 0), out[0].new_hash);
}

test "filewatch: a file only in cur is ignored (never in context)" {
    const empty = [_]Snapshot{};
    const cur = [_]Snapshot{snap("new.zig", 3, 300, 30, 0)};
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 0), changed(&empty, &cur, &out));
}

test "filewatch: order does not matter, paths match by string" {
    const prev = [_]Snapshot{
        snap("a.zig", 1, 100, 10, 0xaa),
        snap("b.zig", 2, 200, 20, 0xbb),
    };
    const cur = [_]Snapshot{
        snap("b.zig", 2, 200, 20, 0),
        snap("a.zig", 1, 100, 10, 0),
    };
    var out: [max_changed]Change = undefined;
    try std.testing.expectEqual(@as(usize, 0), changed(&prev, &cur, &out));
}

test "filewatch: changes beyond the output cap are truncated, not a crash" {
    var prev: [80]Snapshot = undefined;
    var cur: [80]Snapshot = undefined;
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        const p = std.fmt.bufPrint(&buf, "f{d}.zig", .{i}) catch continue;
        prev[i] = snap(p, 1, 100, 10, 0xaa);
        cur[i] = snap(p, 1, 200, 10, 0);
    }
    var out: [8]Change = undefined;
    try std.testing.expectEqual(@as(usize, 8), changed(&prev, &cur, &out));
}

test "ofStat: reads the stat fields the read cache reads" {
    const st = .{ .inode = @as(u64, 42), .size = @as(u64, 123), .mtime = .{ .nanoseconds = @as(i128, 777) } };
    const s = Snapshot.ofStat("x.zig", st, 0x1);
    try std.testing.expectEqualStrings("x.zig", s.pathOf());
    try std.testing.expectEqual(@as(u64, 42), s.inode);
    try std.testing.expectEqual(@as(i128, 777), s.mtime_ns);
    try std.testing.expectEqual(@as(u64, 123), s.size);
    try std.testing.expectEqual(@as(u64, 0x1), s.hash);
}
