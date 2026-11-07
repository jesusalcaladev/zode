//! Objective facts for a long session: verified statements, not narrative.
//!
//! A narrative summary ("the user asked for X, then Y happened") is noise to a
//! coding agent. What helps is a fact that can be checked: `auth.py uses JWT`,
//! `the build failed with 2 problems`. Those go here, with their source.
//!
//! ## Rules
//!
//! Only harness- or tool-confirmed statements enter: a typecheck verdict, a
//! test result, a read that saw the content. A fact written by the model from
//! its own memory is NOT here — that is how a hallucinated fact outlives the
//! conversation that should have corrected it.
//!
//! A fact carries the content hash of the file it came from. When that file
//! changes, the fact whose source hash no longer matches dies (see
//! `invalidateSource`). A fact with NO source is a project-wide verdict (a
//! build passed/failed): any project change makes it stale, so
//! `invalidateProject` drops those. `decision` facts with a file source behave
//! like any other: they live and die with the file they describe.
//!
//! Fixed array, no allocator: the store lives in the `Model` (drawn every
//! frame, written by the worker thread) next to `Plan`, which is a value with
//! fixed buffers for the same reason. `render` allocates once per turn.

const std = @import("std");

/// Ceiling on the store. 48 facts at ~360 bytes is ~17 KB inside the `Model`,
/// which is zeroed on every `Model.init`: noticed, not a problem. Past the
/// ceiling the OLDEST fact is dropped — a miss costs a re-check, a stale fact
/// would cost a lie.
pub const max_facts: usize = 48;
pub const text_max: usize = 160;
pub const source_max: usize = 200;

pub const Kind = enum {
    fact,
    decision,
    blocker,

    pub fn tag(self: Kind) []const u8 {
        return switch (self) {
            .fact => "fact",
            .decision => "decision",
            .blocker => "blocker",
        };
    }
};

pub const Fact = struct {
    kind: Kind = .fact,
    text: [text_max]u8 = undefined,
    text_len: u16 = 0,
    source: [source_max]u8 = undefined,
    source_len: u16 = 0,
    /// Content hash (XxHash64, see `readcache.hashBytes`) of the source file
    /// at the moment the fact was confirmed. 0 when there is no source.
    source_hash: u64 = 0,

    pub fn textOf(self: *const Fact) []const u8 {
        return self.text[0..self.text_len];
    }

    pub fn sourceOf(self: *const Fact) []const u8 {
        return self.source[0..self.source_len];
    }
};

pub const Store = struct {
    items: [max_facts]Fact = undefined,
    len: usize = 0,

    pub fn init() Store {
        return .{};
    }

    pub fn isEmpty(self: *const Store) bool {
        return self.len == 0;
    }

    pub fn clear(self: *Store) void {
        self.len = 0;
    }

    pub fn countKind(self: *const Store, kind: Kind) usize {
        var n: usize = 0;
        for (self.items[0..self.len]) |f| {
            if (f.kind == kind) n += 1;
        }
        return n;
    }

    /// Adds a fact. Returns true when the store changed.
    ///
    /// Text is sanitized to one line (rendering is one fact per line, and a
    /// newline in the middle would be a second line that looks like another
    /// fact) and truncated at `text_max` — a truncated fact is still true,
    /// it is just shorter. An empty text is refused: there is no fact to keep.
    pub fn add(self: *Store, kind: Kind, text: []const u8, source: []const u8, source_hash: u64) bool {
        var tbuf: [text_max]u8 = undefined;
        const t = sanitizeInto(&tbuf, text);
        if (t.len == 0) return false;
        const s = std.mem.trim(u8, source, " \t");
        // Exact duplicate: the second copy is tokens for nothing.
        for (self.items[0..self.len]) |f| {
            if (f.kind == kind and std.mem.eql(u8, f.textOf(), t) and std.mem.eql(u8, f.sourceOf(), s)) {
                return false;
            }
        }
        // Full: evict the oldest (index 0), so the newest evidence wins.
        if (self.len == max_facts) {
            std.mem.copyForwards(Fact, self.items[0 .. self.len - 1], self.items[1..self.len]);
            self.len -= 1;
        }
        var f: Fact = .{ .kind = kind, .source_hash = if (s.len == 0) 0 else source_hash };
        @memcpy(f.text[0..t.len], t);
        f.text_len = @intCast(t.len);
        const sl = @min(s.len, source_max);
        @memcpy(f.source[0..sl], s[0..sl]);
        f.source_len = @intCast(sl);
        self.items[self.len] = f;
        self.len += 1;
        return true;
    }

    /// Drops the facts whose source is `path` and whose remembered hash is
    /// NOT `new_hash` — the file changed under them. `new_hash == 0` means
    /// "the file is gone or unreadable": every fact sourced from it dies.
    /// Returns how many were removed.
    pub fn invalidateSource(self: *Store, path: []const u8, new_hash: u64) usize {
        // The stored source is truncated at `source_max`, so the caller's
        // path is too: comparing a 2048-byte path against a 200-byte stored
        // one would never match, and the stale fact would survive the very
        // change it must die from.
        const key = path[0..@min(path.len, source_max)];
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.len) {
            const f = self.items[i];
            if (std.mem.eql(u8, f.sourceOf(), key) and (new_hash == 0 or f.source_hash != new_hash)) {
                self.removeAt(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    /// Drops the project-wide verdicts (no source): a build pass/fail is a
    /// statement about the code BEFORE the change, and believing it after one
    /// is how a green answers for code it never saw. File-sourced facts are
    /// untouched — they have their own invalidation by hash.
    /// Returns how many were removed.
    pub fn invalidateProject(self: *Store) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.len) {
            if (self.items[i].source_len == 0) {
                self.removeAt(i);
                removed += 1;
            } else {
                i += 1;
            }
        }
        return removed;
    }

    fn removeAt(self: *Store, i: usize) void {
        // Shift down. The store is tiny; the loop is cheaper than the comment.
        var j = i;
        while (j + 1 < self.len) : (j += 1) {
            self.items[j] = self.items[j + 1];
        }
        self.len -= 1;
    }

    /// The block that goes on the wire, or null when there is nothing to say
    /// (an empty `[Facts]` message would be tokens for nothing, every turn).
    ///
    /// Order is insertion order (chronological): stable while nothing changes,
    /// which keeps the prompt-cache breakpoint intact until a fact actually
    /// changes. The caller appends this as a `user` message AFTER the cached
    /// prefix, the same trick as `[Plan]`.
    pub fn render(self: *const Store, arena: std.mem.Allocator) ?[]const u8 {
        if (self.len == 0) return null;
        var text = std.Io.Writer.Allocating.init(arena);
        const w = &text.writer;
        w.print("[Facts] Verified statements for this session, confirmed by the harness or a tool. They override your memory of older turns. A fact whose source file changed was dropped; re-read a source only if you need the current content.", .{}) catch return null;
        for (self.items[0..self.len]) |f| {
            if (f.source_len > 0) {
                if (f.source_hash != 0) {
                    w.print("\n- {s} ({s}@{x:0>8}): {s}", .{ f.kind.tag(), f.sourceOf(), f.source_hash, f.textOf() }) catch return null;
                } else {
                    w.print("\n- {s} ({s}): {s}", .{ f.kind.tag(), f.sourceOf(), f.textOf() }) catch return null;
                }
            } else {
                w.print("\n- {s}: {s}", .{ f.kind.tag(), f.textOf() }) catch return null;
            }
        }
        // Owned, exact length: the caller may free it with the allocator it
        // passed (a `written()` slice shares the writer's capacity and
        // freeing it checks the length — the safe allocator aborts).
        return text.toOwnedSlice() catch null;
    }
};

/// One line, trimmed, cut at the buffer size. Newlines/tabs inside become
/// spaces, so a multi-line verdict (a build note) still renders as ONE fact.
/// The result lives in `buf`: the caller owns the lifetime — returning a
/// slice of a local would dangle (found by the dedupe test, which read
/// garbage on the second `add`).
fn sanitizeInto(buf: *[text_max]u8, text: []const u8) []const u8 {
    const max: usize = text_max;
    var n: usize = 0;
    for (text) |c| {
        if (n >= max) break;
        buf[n] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
        n += 1;
    }
    // Collapse the double spaces that a removed newline leaves behind.
    var out: usize = 0;
    var prev_space = false;
    for (buf[0..n]) |c| {
        if (c == ' ') {
            if (prev_space) continue;
            prev_space = true;
        } else {
            prev_space = false;
        }
        // Compact in place: `out` never passes the read index.
        buf[out] = c;
        out += 1;
    }
    return std.mem.trim(u8, buf[0..out], " ");
}

// ── tests ─────────────────────────────────────────────────────────────

test "facts: empty store renders nothing" {
    var s: Store = .init();
    try std.testing.expect(s.isEmpty());
    try std.testing.expect(s.render(std.testing.allocator) == null);
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "facts: add and dedupe" {
    var s: Store = .init();
    try std.testing.expect(s.add(.fact, "auth.py uses JWT", "auth.py", 0x1234));
    try std.testing.expect(!s.add(.fact, "auth.py uses JWT", "auth.py", 0x1234));
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqual(@as(usize, 1), s.countKind(.fact));
    // Same text, different kind: a different fact.
    try std.testing.expect(s.add(.decision, "auth.py uses JWT", "auth.py", 0x1234));
    try std.testing.expectEqual(@as(usize, 2), s.len);
    // Empty text is refused.
    try std.testing.expect(!s.add(.fact, "   ", "x", 0));
    try std.testing.expect(!s.add(.fact, "", "x", 0));
    try std.testing.expectEqual(@as(usize, 2), s.len);
}

test "facts: multiline text becomes one line" {
    var s: Store = .init();
    try std.testing.expect(s.add(.blocker, "build failed\nsrc/x.zig:3: error: oops", "", 0));
    try std.testing.expectEqualStrings("build failed src/x.zig:3: error: oops", s.items[0].textOf());
    const out = s.render(std.testing.allocator) orelse return error.NoRender;
    defer std.testing.allocator.free(out);
    // One fact = one line starting with "- ".
    const lines = std.mem.count(u8, out, "\n- ");
    try std.testing.expectEqual(@as(usize, 1), lines);
}

test "facts: render names kind, text and source with hash" {
    var s: Store = .init();
    _ = s.add(.fact, "uses JWT", "auth.py", 0xabcdef);
    _ = s.add(.blocker, "build fails", "", 0);
    const out = s.render(std.testing.allocator) orelse return error.NoRender;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[Facts]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- fact (auth.py@00abcdef): uses JWT") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "- blocker: build fails") != null);
}

test "facts: invalidateSource keeps a matching hash, drops a stale one" {
    var s: Store = .init();
    _ = s.add(.fact, "old", "a.zig", 0x1111);
    _ = s.add(.fact, "same", "a.zig", 0x2222);
    _ = s.add(.fact, "other file", "b.zig", 0x1111);
    try std.testing.expectEqual(@as(usize, 1), s.invalidateSource("a.zig", 0x2222));
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("same", s.items[0].textOf());
    // File gone (hash 0): everything sourced from it dies.
    try std.testing.expectEqual(@as(usize, 1), s.invalidateSource("a.zig", 0));
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("other file", s.items[0].textOf());
    // Unknown path removes nothing.
    try std.testing.expectEqual(@as(usize, 0), s.invalidateSource("zzz.zig", 0));
}

test "facts: a path longer than source_max still matches its stored prefix" {
    // The store truncates the source; the poller passes the read cache's
    // full path. If the comparison did not truncate, the fact would outlive
    // the file change it must die from.
    var buf: [source_max + 50]u8 = undefined;
    @memset(buf[0..], 'a');
    const path = buf[0..];
    var s: Store = .init();
    _ = s.add(.fact, "old", path, 0x1111);
    try std.testing.expectEqual(@as(usize, 1), s.invalidateSource(path, 0x2222));
    try std.testing.expect(s.isEmpty());
}

test "facts: invalidateProject drops only sourceless verdicts" {
    var s: Store = .init();
    _ = s.add(.blocker, "build fails", "", 0);
    _ = s.add(.fact, "project check passed", "", 0);
    _ = s.add(.decision, "keep the API", "api.zig", 0x99);
    try std.testing.expectEqual(@as(usize, 2), s.invalidateProject());
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqualStrings("keep the API", s.items[0].textOf());
}

test "facts: store stays capped, oldest evicted first" {
    var s: Store = .init();
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < max_facts + 10) : (i += 1) {
        const t = std.fmt.bufPrint(&buf, "fact {d}", .{i}) catch continue;
        try std.testing.expect(s.add(.fact, t, "f.zig", 0));
    }
    try std.testing.expectEqual(max_facts, s.len);
    // The first 10 are gone; "fact 10" is the oldest survivor.
    try std.testing.expectEqualStrings("fact 10", s.items[0].textOf());
}

test "facts: clear empties the store" {
    var s: Store = .init();
    _ = s.add(.fact, "x", "", 0);
    s.clear();
    try std.testing.expect(s.isEmpty());
    try std.testing.expect(s.render(std.testing.allocator) == null);
}

test "facts: the store stays small enough to live inside the Model" {
    // It is carried BY VALUE in `tui.Model` (drawn every frame, written by
    // the worker), like `Plan`. 48 facts of fixed buffers is the ceiling this
    // guards: growing the entry or the count past it is a startup-RSS
    // regression that no other test would notice.
    try std.testing.expect(@sizeOf(Store) <= 24 * 1024);
}
