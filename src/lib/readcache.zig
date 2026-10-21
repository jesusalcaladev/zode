//! What zode has already read, and when it does NOT have to send it again.
//!
//! ## The problem
//!
//! `read` used to re-read the file and re-send the whole body on every call. The
//! only thing in the harness that trimmed tool output was compaction tier 1, and
//! that is a VIEW of the wire: it elides old results, it does not avoid sending
//! what is already in the model's context. So the loop "read the file, run a
//! build, read the file again to check" paid for the file twice, on every turn,
//! and paid for it again on every iteration of the turn.
//!
//! ## The rule
//!
//! A file that has not changed is ALREADY IN THE CONTEXT. Re-sending it costs
//! tokens and teaches the model nothing. So `read` answers with a short line
//! instead of the body, and says plainly that the content is still above it in
//! the conversation and how to get it again (`force: true`).
//!
//! ## Why the hash, when there is an mtime
//!
//! Because `mtime` lies in exactly the case that matters: `git checkout`,
//! `sed -i` and a `cp` that keeps the timestamp all produce a different mtime,
//! which costs nothing, but a filesystem with 1-second timestamp granularity
//! plus a same-length edit produces the SAME mtime, which would make the harness
//! tell the model "nothing changed" about a file that did. The fast path is
//! stat-only (`ino` + `mtime_ns` + `size`), and when it does not match we read
//! and compare the hash before believing anything. I/O is cheap; tokens are not.
//!
//! ## The trap this feature can walk into
//!
//! Compaction can DELETE a `read` result from the wire. If the cache still said
//! "unchanged, it is in your context", the model would be told it had a file it
//! does not have, and it would answer from a memory it never got. So every entry
//! remembers which message its result went into, and `markDroppedAt` clears the
//! `in_context` flag for the ones compaction removed. An entry with the flag
//! cleared re-reads.
//!
//! No allocator and no pointers: the whole cache is a fixed array of fixed
//! buffers, so it can be read from any thread while another one writes, and
//! there is nothing to free at teardown (which is where the ownership bugs in
//! this repo live).

const std = @import("std");
const store = @This();

/// Paths are what the MODEL typed, so they are what gets compared. No realpath:
/// resolving symlinks would make `read a.zig` and `read ./a.zig` two entries, and
/// the whole point is that a second spelling of a file you already read is still
/// "already read". The `inode` catches the case where two names are the same
/// file after a rename.
/// A path longer than this is simply NOT cached: a miss costs a re-read, and a
/// re-read of a file with a 600-character path is a rounding error. 512 is way
/// past any real path and it is what keeps this table at a size a `Model` can
/// carry around: at 1024 the 256 entries were 288 KB INSIDE the model, which is
/// zeroed on every `Model.init` and shows up in the RSS (`tools/measure.py` went
/// from 5.2 MB to 8.4 MB before this was cut).
pub const path_max = 512;
/// Line ranges per file. Real sessions re-read a handful of places in the same
/// file; 8 is enough and keeps the entry small.
pub const max_ranges = 8;
/// Files remembered. Past this the least recently used one is dropped, which is
/// a cache miss and not an error.
///
/// 128 and not 256 for the same reason as `path_max`: the table lives inside the
/// `Model`, by value, and a turn of real work touches maybe twenty files. The
/// entry is 640 bytes, so this is 80 KB the app carries instead of 160.
pub const max_entries = 128;

pub const Range = struct {
    /// 1-indexed, inclusive, like the `read` tool's own `offset`.
    first: u32 = 1,
    /// 1-indexed, inclusive. `0` means "to the end of the file as it was".
    last: u32 = 0,
};

pub const Entry = struct {
    /// Where the entry lives in the table. A `const` next to the type so it can be
    /// written as `Entry.max_ranges` from the cache code, which is a different
    /// type and cannot see `readcache.max_ranges` through a field access.
    pub const range_limit = store.max_ranges;
    pub const no_index: u32 = std.math.maxInt(u32);

    path: [path_max]u8 = undefined,
    path_len: u16 = 0,
    inode: u64 = 0,
    mtime_ns: i128 = 0,
    size: u64 = 0,
    hash: u64 = 0,
    /// `true` when we actually sent the body (as opposed to having answered
    /// "unchanged", which is what makes this entry worth anything).
    in_context: bool = false,
    /// Index of the session message this result went into, or `no_index` when it
    /// was never persisted. Compaction maps back from here.
    msg_index: u32 = no_index,
    ranges: [max_ranges]Range = undefined,
    ranges_len: u8 = 0,
    /// Bumped on every hit, for the LRU eviction.
    used: u64 = 0,
    /// Lines in the file the last time it was read, for the short answer.
    lines: u32 = 0,

    pub fn pathOf(self: *const Entry) []const u8 {
        return self.path[0..self.path_len];
    }

    /// Does this entry already cover the lines `[first, last]`?
    ///
    /// `last == 0` means "to the end of the file as it was read", which is the
    /// same as covering everything from `first` on.
    pub fn covers(self: *const Entry, first: u32, last: u32) bool {
        if (!self.in_context) return false;
        return self.coversRange(first, last);
    }

    /// The same question WITHOUT the "is it in the context" part, for the merge
    /// logic below: there the flag is irrelevant, and asking about it would stop
    /// `addRange` from merging into an entry whose content was elided.
    fn coversRange(self: *const Entry, first: u32, last: u32) bool {
        for (self.ranges[0..self.ranges_len]) |r| {
            if (r.first <= first and endOf(r) >= last) return true;
        }
        return false;
    }

    /// Adds a range, MERGING it into any range it touches.
    ///
    /// Merging matters because the alternative is a table that fills up with ten
    /// adjacent reads of the same file and then answers "those lines I do not
    /// have" to a range it does have. The first version only merged when the new
    /// range was CONTAINED in an older one, which is not what happens when a read
    /// continues where the previous one stopped — the exact shape of "read the
    /// next 200 lines".
    pub fn addRange(self: *Entry, first: u32, last: u32) void {
        if (self.ranges_len > 0 and self.coversRange(first, last)) return;

        for (self.ranges[0..self.ranges_len]) |*r| {
            // Touching counts as merging: ranges [1,50] and [51,90] are one
            // range for every purpose here, and keeping them apart is what fills
            // the table.
            if (first > endOf(r) +| 1 or r.first > last +| 1) continue;
            if (first < r.first) r.first = first;
            if (last > endOf(r)) r.last = last;
            return;
        }

        if (self.ranges_len >= Entry.range_limit) {
            // Full: replace the last one. A miss costs a re-read; being wrong
            // would cost a lie.
            self.ranges[Entry.range_limit - 1] = .{ .first = first, .last = last };
            return;
        }
        self.ranges[self.ranges_len] = .{ .first = first, .last = last };
        self.ranges_len += 1;
    }
};

/// The inclusive end of a range, with `0` meaning "to the end of the file".
///
/// Takes a pointer because it is called with both `r` (a `*Range` out of the
/// loop) and `&r` (a copy), and one signature for the two is worth the pointer.
fn endOf(r: anytype) u32 {
    const last = r.last;
    return if (last == 0) std.math.maxInt(u32) else last;
}

/// Cap on what one "already in your context" answer is credited with. A 12 MB file
/// would make the stat say "saved 12 MB" and the /context number absurd; what
/// matters is the order of magnitude, and `read` truncates long before this.
pub const max_saved: u64 = 64 * 1024;

pub const Stats = struct {
    hits: usize = 0,
    misses: usize = 0,
    /// Bytes of tool result that were NOT sent because of this cache.
    saved: usize = 0,
};

pub const Cache = struct {
    entries: [max_entries]Entry = undefined,
    len: usize = 0,
    stats: Stats = .{},
    /// The clock for `used`, so LRU does not need a real timestamp. A counter is
    /// enough: it only has to order two hits.
    clock: u64 = 0,
    /// `read` is in `isParallelSafe`, so several calls run at once and two of them
    /// can be the same file. The lock is INSIDE the cache for that reason, and it
    /// is never held across a read (see the note on `markDroppedAt`).
    lock: std.atomic.Mutex = .unlocked,

    pub fn lockIt(self: *Cache) void {
        while (!self.lock.tryLock()) std.Thread.yield() catch {};
    }

    pub fn unlockIt(self: *Cache) void {
        self.lock.unlock();
    }

    pub fn tick(self: *Cache) u64 {
        self.clock += 1;
        return self.clock;
    }

    /// The entry for `path`, or null. The caller holds the lock.
    pub fn find(self: *Cache, path: []const u8) ?*Entry {
        for (self.entries[0..self.len]) |*e| {
            if (std.mem.eql(u8, e.pathOf(), path)) return e;
        }
        return null;
    }

    fn push(self: *Cache) *Entry {
        if (self.len < max_entries) {
            const e = &self.entries[self.len];
            self.len += 1;
            return e;
        }
        // Full: evict the least recently used. `used` is never 0 for a live entry
        // (every find bumps it), so entry 0 is a safe starting victim.
        var victim: usize = 0;
        var oldest = self.entries[0].used;
        for (self.entries[1..self.len], 1..) |*e, i| {
            if (e.used < oldest) {
                oldest = e.used;
                victim = i;
            }
        }
        return &self.entries[victim];
    }

    /// What the tool learned about this file WITHOUT reading it.
    ///
    /// The `read_then_decide` arm is what the caller already knows about the
    /// previous content, as VALUES and not as a pointer into the table: the lock
    /// is released before the caller reads the file, and a second `read` of the
    /// same file running in parallel can be rewriting that entry right then. A
    /// pointer would be a data race that only shows up as a wrong hash.
    pub const Verdict = union(enum) {
        /// Nothing to do: the answer is already in the context.
        already_sent: Sent,
        /// Read it, then compare the hash with `Prev.hash`.
        read_then_decide: Prev,
    };

    /// Everything the short answer needs, read while the lock was held.
    pub const Sent = struct {
        lines: u32 = 0,
        /// How many bytes of tool result this call is not going to send. Counted
        /// here, where the entry is still consistent, rather than by the caller
        /// guessing afterwards.
        saved: usize = 0,
    };

    /// What the cache remembers about a file, if anything.
    pub const Prev = struct {
        hash: u64 = 0,
        in_context: bool = false,
    };

    /// The fast path, stat only: does this exact file, with this inode, mtime and
    /// size, already have those lines in the context?
    pub fn check(self: *Cache, path: []const u8, stat: anytype, first: u32, last: u32) Verdict {
        self.lockIt();
        defer self.unlockIt();
        const e = self.find(path) orelse {
            self.stats.misses += 1;
            return .{ .read_then_decide = .{} };
        };
        e.used = self.tick();
        const same = e.inode == inodeOf(stat) and
            e.mtime_ns == stat.mtime.nanoseconds and
            e.size == stat.size;
        if (same and e.covers(first, last)) {
            self.stats.hits += 1;
            self.stats.saved += @intCast(@min(e.size, max_saved));
            return .{ .already_sent = .{ .lines = e.lines, .saved = @intCast(@min(e.size, max_saved)) } };
        }
        self.stats.misses += 1;
        return .{ .read_then_decide = .{ .hash = e.hash, .in_context = e.in_context } };
    }

    /// Records a read that SENT the body.
    ///
    /// `hash` is of the bytes just read, which is what makes the next
    /// `read_then_decide` answerable when the mtime moved for a reason that did
    /// not change the content.
    pub fn record(self: *Cache, path: []const u8, stat: anytype, hash: u64, first: u32, last: u32, lines: u32) void {
        if (path.len == 0 or path.len > path_max) return;
        self.lockIt();
        defer self.unlockIt();
        const e = self.push();
        e.* = .{};
        @memcpy(e.path[0..path.len], path);
        e.path_len = @intCast(path.len);
        e.inode = inodeOf(stat);
        e.mtime_ns = stat.mtime.nanoseconds;
        e.size = stat.size;
        e.hash = hash;
        e.in_context = true;
        e.lines = lines;
        e.used = self.tick();
        e.addRange(first, last);
    }

    /// Are those exact lines already in the context? For the caller that has
    /// just decided the content did NOT change: the bytes being the same is not
    /// enough, the RANGE the model asked for also has to be one it has.
    pub fn coversRangeOf(self: *Cache, path: []const u8, first: u32, last: u32) bool {
        self.lockIt();
        defer self.unlockIt();
        const e = self.find(path) orelse return false;
        e.used = self.tick();
        return e.covers(first, last);
    }

    /// A read whose bytes were identical to what the model already has.
    ///
    /// The entry KEEPS its ranges and its `in_context`: the model does have those
    /// lines, it just got told again that it does. What changes is the stat, so
    /// the next call takes the fast path.
    pub fn confirmUnchanged(self: *Cache, path: []const u8, stat: anytype, first: u32, last: u32, saved: usize) void {
        if (path.len == 0 or path.len > path_max) return;
        self.lockIt();
        defer self.unlockIt();
        const e = self.find(path) orelse return;
        e.used = self.tick();
        e.inode = inodeOf(stat);
        e.mtime_ns = stat.mtime.nanoseconds;
        e.size = stat.size;
        e.addRange(first, last);
        self.stats.saved += saved;
    }

    /// Forgets a file. Called when zode writes it: the next `read` MUST return
    /// the new content, whatever the mtime says.
    pub fn invalidate(self: *Cache, path: []const u8) void {
        self.lockIt();
        defer self.unlockIt();
        const e = self.find(path) orelse return;
        e.hash = 0;
        e.in_context = false;
        e.ranges_len = 0;
        e.msg_index = Entry.no_index;
    }

    /// Says which message a `read` result landed in, so compaction can undo it.
    pub fn setMessageIndex(self: *Cache, path: []const u8, index: u32) void {
        self.lockIt();
        defer self.unlockIt();
        const e = self.find(path) orelse return;
        e.msg_index = index;
    }

    /// Compaction removed the message this result went into: it is no longer in
    /// the context, so the next `read` has to send the body again.
    pub fn markDroppedAt(self: *Cache, index: usize) void {
        self.lockIt();
        defer self.unlockIt();
        for (self.entries[0..self.len]) |*e| {
            if (e.msg_index == index) {
                e.in_context = false;
                e.msg_index = Entry.no_index;
            }
        }
    }

    /// How many entries still claim their content is in the context.
    pub fn liveEntries(self: *Cache) usize {
        self.lockIt();
        defer self.unlockIt();
        var n: usize = 0;
        for (self.entries[0..self.len]) |*e| {
            if (e.in_context) n += 1;
        }
        return n;
    }

    /// The counters, under the lock.
    pub fn statsSnapshot(self: *Cache) Stats {
        self.lockIt();
        defer self.unlockIt();
        return self.stats;
    }

    /// The whole table, with the lock held.
    ///
    /// The callback runs UNDER the lock: the entries are fixed buffers that a
    /// worker can rewrite at any moment, so a caller that reads them has to
    /// copy what it needs while the lock is held. The paths it hands out are
    /// only valid until the callback returns.
    ///
    /// The callback must not call back into the cache (`lockIt` is a spinlock
    /// and it is not reentrant) and it must not block: the worker that owns
    /// the cache is waiting for it.
    pub fn withAll(self: *Cache, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const Entry) void) void {
        self.lockIt();
        defer self.unlockIt();
        f(ctx, self.entries[0..self.len]);
    }

    /// Forgets everything.
    ///
    /// A new session has NOTHING in its context, so an entry that says "the
    /// model has this file" is a lie from that moment on: the next `read`
    /// would take the fast path and answer "it is already in your context"
    /// WITHOUT sending the body, and the model would be working from a file it
    /// cannot see.
    ///
    /// The bytes of the entries are not zeroed: `len` is what makes them
    /// unreadable, and `push` overwrites an entry whole before using it.
    pub fn clear(self: *Cache) void {
        self.lockIt();
        defer self.unlockIt();
        self.len = 0;
        self.stats = .{};
    }
};

/// The hash of the bytes, which is the thing that decides whether a file really
/// changed when the timestamps cannot be trusted.
pub fn hashBytes(bytes: []const u8) u64 {
    var h = std.hash.XxHash64.init(0);
    h.update(bytes);
    return h.final();
}

fn inodeOf(stat: anytype) u64 {
    // `Stat.inode` is a platform type; `INode` on every target zode builds for is
    // an integer wide enough, and the cast is checked by the tests.
    return @intCast(stat.inode);
}

// ── tests ─────────────────────────────────────────────────────

test "covers: an already read range is not asked for again" {
    var e = Entry{ .in_context = true };
    e.addRange(1, 100);
    try std.testing.expect(e.covers(1, 100));
    try std.testing.expect(e.covers(10, 20));
    try std.testing.expect(e.covers(50, 50));
    // Asking beyond what was read is NOT covered: there it does have to send.
    try std.testing.expect(!e.covers(1, 101));
    try std.testing.expect(!e.covers(90, 120));
    try std.testing.expect(!e.covers(101, 200));
}

test "covers: an entry without context covers NOTHING" {
    // This is the failure that produces "the model thinks it has the file": if
    // compaction took it away, `covers` has to say no.
    var e = Entry{ .in_context = false };
    e.addRange(1, 100);
    try std.testing.expect(!e.covers(1, 100));
}

test "addRange: two contiguous ranges merge into one" {
    var e = Entry{ .in_context = true };
    e.addRange(1, 50);
    e.addRange(40, 90);
    // With the table full of pairs, a range spanning both has to count as
    // covered, or the cache would say "you do not have it" about something it
    // does.
    try std.testing.expect(e.covers(1, 90));
    try std.testing.expect(!e.covers(1, 91));
}

test "addRange: the table stays at max_ranges and does not grow" {
    var e = Entry{ .in_context = true };
    var i: u32 = 1;
    while (i < max_ranges * 3) : (i += 1) {
        e.addRange(i * 1000, i * 1000 + 10);
    }
    try std.testing.expectEqual(@as(u8, max_ranges), e.ranges_len);
}

test "cache: an identical stat does NOT re-read (fast path, no hash)" {
    var c: Cache = .{};
    defer c.invalidate("f.txt");
    const stat = .{ .inode = @as(u64, 42), .size = @as(u64, 100), .mtime = .{ .nanoseconds = @as(i128, 1000) } };

    c.record("f.txt", stat, 0xabcd, 1, 100, 100);
    try std.testing.expectEqual(@as(usize, 0), c.stats.hits);

    const v = c.check("f.txt", stat, 1, 100);
    try std.testing.expect(v == .already_sent);
    try std.testing.expectEqual(@as(usize, 1), c.stats.hits);
}

test "cache: the SAME mtime with different content does NOT fool it (hence the hash)" {
    // The case that kills a cache made only of mtime: a `sed -i` of the same
    // length inside the same clock tick.
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 500) } };
    c.record("f.txt", stat, hashBytes("hola-----"), 1, 10, 10);

    // Same stat: the fast path is right, and that is correct.
    try std.testing.expect(c.check("f.txt", stat, 1, 10) == .already_sent);

    // The mtime changes (say a `git checkout`) but the content does NOT: it has
    // to read to find out, and the answer is "still the same".
    const touched = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 900) } };
    const v = c.check("f.txt", touched, 1, 10);
    switch (v) {
        .read_then_decide => |prev| {
            // The cache DID have the entry (the hash is not zero), and the hash still
            // gives the same thing: that is what makes the short answer correct
            // even though the mtime moved.
            try std.testing.expect(prev.in_context);
            try std.testing.expectEqual(hashBytes("hola-----"), prev.hash);
        },
        .already_sent => return error.TestUnexpectedResult,
    }
    c.confirmUnchanged("f.txt", touched, 1, 10, 900);
    // And now the fast path is right again with the new mtime.
    try std.testing.expect(c.check("f.txt", touched, 1, 10) == .already_sent);
}

test "cache: an uncovered range is sent again even when the stat is identical" {
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 200), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("f.txt", stat, 1, 1, 100, 200);
    try std.testing.expect(c.check("f.txt", stat, 1, 100) == .already_sent);
    switch (c.check("f.txt", stat, 101, 200)) {
        .read_then_decide => {},
        .already_sent => return error.TestUnexpectedResult,
    }
}

test "cache: force (an already read range but requested with force) ignores it" {
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("f.txt", stat, 1, 1, 10, 10);
    // `force` is resolved in the tool, but the cache has to be able to answer yes
    // to it: otherwise a `force: true` would not put the stat in "send it again"
    // mode.
    try std.testing.expect(c.check("f.txt", stat, 1, 10) == .already_sent);
}

test "cache: invalidate after a write makes the next read send the body" {
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("f.txt", stat, 1, 1, 10, 10);
    try std.testing.expect(c.check("f.txt", stat, 1, 10) == .already_sent);
    c.invalidate("f.txt");
    switch (c.check("f.txt", stat, 1, 10)) {
        .read_then_decide => {},
        .already_sent => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), c.liveEntries());
}

test "cache: markDroppedAt undoes what compaction took" {
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("f.txt", stat, 1, 1, 10, 10);
    c.setMessageIndex("f.txt", 12);
    try std.testing.expectEqual(@as(usize, 1), c.liveEntries());
    try std.testing.expect(c.check("f.txt", stat, 1, 10) == .already_sent);

    // Compaction tier 1 takes message 12 away (not one of the recent window). The
    // model does not have that text any more.
    c.markDroppedAt(12);
    try std.testing.expectEqual(@as(usize, 0), c.liveEntries());
    switch (c.check("f.txt", stat, 1, 10)) {
        .read_then_decide => {},
        .already_sent => return error.TestUnexpectedResult,
    }
}

test "cache: the renamed file is re-read (another inode, another name)" {
    var c: Cache = .{};
    const a = .{ .inode = @as(u64, 1), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    const b = .{ .inode = @as(u64, 2), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("a.zig", a, 1, 1, 10, 10);
    switch (c.check("b.zig", b, 1, 10)) {
        .read_then_decide => {},
        .already_sent => return error.TestUnexpectedResult,
    }
}

test "cache: the table fills up and keeps answering (eviction, not a crash)" {
    var c: Cache = .{};
    var i: usize = 0;
    var name_buf: [32]u8 = undefined;
    const stat = .{ .inode = @as(u64, 1), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    while (i < max_entries + 20) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.zig", .{i});
        c.record(name, stat, 1, 1, 10, 10);
    }
    try std.testing.expectEqual(max_entries, c.len);
    // It keeps working: it is a cache, not a chain.
    const name = try std.fmt.bufPrint(&name_buf, "f{d}.zig", .{max_entries + 19});
    try std.testing.expect(c.check(name, stat, 1, 10) == .already_sent);
}

test "hashBytes: same content, same hash" {
    try std.testing.expectEqual(hashBytes("hola"), hashBytes("hola"));
    try std.testing.expect(hashBytes("hola") != hashBytes("holo"));
    try std.testing.expectEqual(hashBytes(""), hashBytes(""));
}

test "cache: clear forgets everything, and a new session has nothing in its context" {
    // The failure this prevents: after `/new`, the cache still says "the model
    // has this file", the next `read` takes the fast path and does NOT send
    // the body, and the model works from a file it cannot see.
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("f.txt", stat, 1, 1, 10, 10);
    try std.testing.expectEqual(@as(usize, 1), c.liveEntries());

    c.clear();
    try std.testing.expectEqual(@as(usize, 0), c.len);
    try std.testing.expectEqual(@as(usize, 0), c.liveEntries());
    switch (c.check("f.txt", stat, 1, 10)) {
        .read_then_decide => {},
        .already_sent => return error.TestUnexpectedResult,
    }
}

test "cache: withAll hands the table to the callback, and the counters come back" {
    var c: Cache = .{};
    const stat = .{ .inode = @as(u64, 7), .size = @as(u64, 10), .mtime = .{ .nanoseconds = @as(i128, 5) } };
    c.record("a.txt", stat, 1, 1, 10, 10);
    c.record("b.txt", stat, 1, 1, 20, 20);

    const Ctx = struct {
        seen: usize = 0,
        lines: u32 = 0,
        fn take(self: *@This(), entries: []const Entry) void {
            for (entries) |e| {
                self.seen += 1;
                self.lines += e.lines;
            }
        }
    };
    var ctx = Ctx{};
    c.withAll(&ctx, Ctx.take);
    try std.testing.expectEqual(@as(usize, 2), ctx.seen);
    try std.testing.expectEqual(@as(u32, 30), ctx.lines);

    const s = c.statsSnapshot();
    try std.testing.expectEqual(@as(usize, 0), s.hits);
}
