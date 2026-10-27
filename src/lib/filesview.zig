//! `/files`: what the model is looking at, and what it changed.
//!
//! ## The question
//!
//! "What is the model looking at?" is the question you ask when a turn goes
//! sideways, and there was no way to answer it: the read cache knew every file
//! the model had read and NOTHING showed it. The cache's own numbers (the
//! re-reads it avoided) were in `/context` and nowhere else, and the FILES
//! were in no place at all.
//!
//! ## Two lists, and they answer different questions
//!
//! - **READ**: the files the model has read, most recent first, and whether
//!   their content is STILL in the context. A file whose content was compacted
//!   away is not in the context any more, and saying so is the difference
//!   between "the model has this" and "the model THINKS it has this" — the
//!   second one is how an agent ends up quoting a file it never saw.
//! - **CHANGED**: the files the agent wrote to, this session, in the order it
//!   did it. A question about "what did it do to my repo" is about the whole
//!   session, not about the last turn.
//!
//! ## The counters are the point
//!
//! "N re-reads avoided · M KB not re-sent" is the whole argument for the read
//! cache in one line: a cache that works and cannot be seen is a cache nobody
//! trusts enough to keep.
//!
//! ## Why it is a module of its own
//!
//! The report is a pure function of the rows and the counters, so it can be
//! tested with no TUI, no terminal and no network. The STATE it describes (the
//! read cache) lives in the `Model`, and the session's changed files live
//! here in a fixed table that the `Model` owns.

const std = @import("std");

/// The read cache's counters, as `/files` shows them.
pub const Stats = struct {
    /// Reads that were answered with "it is already in your context".
    hits: usize = 0,
    /// Reads that had to go to the disk.
    misses: usize = 0,
    /// Bytes of tool result that were NOT sent because of the cache.
    saved: usize = 0,
};

/// How many changed files are remembered.
///
/// 64 is a session's worth of edits. Past it the table stops growing and the
/// report says how many were left out: a list that stops silently is a list
/// that lies about being complete.
pub const max_changed = 64;

/// The longest path remembered.
///
/// A path longer than this is not one anybody can read on a screen, and a
/// truncated path is a lie about WHICH file it is. It is also longer than
/// every real path in the tree, so the cap never bites in practice.
pub const path_max = 256;

/// The files the agent has WRITTEN to, this session.
///
/// It is a fixed table and not a list: it lives inside the `Model`, and a list
/// on the heap would need an owner, a lock and a free for something that is a
/// handful of paths. There is no allocator and nothing to deinit.
pub const Changed = struct {
    paths: [max_changed][path_max]u8 = undefined,
    lens: [max_changed]u16 = undefined,
    len: usize = 0,
    /// Files that did not fit. The report says how many, because a list that
    /// stops silently is a list that lies about being complete.
    dropped: usize = 0,

    /// Records a file the agent wrote to.
    ///
    /// A file that is already there is NOT recorded twice: the list is of
    /// FILES, not of writes, and a file written nine times is one line.
    pub fn note(self: *Changed, path: []const u8) void {
        if (path.len == 0) return;
        for (0..self.len) |i| {
            const l = self.lens[i];
            if (l == path.len and std.mem.eql(u8, self.paths[i][0..l], path)) return;
        }
        if (path.len > path_max) {
            // A path this long is not one anybody can read, and truncating it
            // would name a file that does not exist.
            self.dropped += 1;
            return;
        }
        if (self.len >= max_changed) {
            self.dropped += 1;
            return;
        }
        @memcpy(self.paths[self.len][0..path.len], path);
        self.lens[self.len] = @intCast(path.len);
        self.len += 1;
    }

    /// The path at `i`, or "" when `i` is out of range.
    pub fn at(self: *const Changed, i: usize) []const u8 {
        if (i >= self.len) return "";
        return self.paths[i][0..self.lens[i]];
    }

    pub fn count(self: *const Changed) usize {
        return self.len;
    }

    /// Fills `out` with the paths, in order, and returns how many there were.
    ///
    /// The caller owns the array: the paths themselves are borrowed from this
    /// table, which lives in the `Model` and outlives the report.
    pub fn fill(self: *const Changed, out: [][]const u8) usize {
        const n = @min(out.len, self.len);
        for (0..n) |i| out[i] = self.at(i);
        return n;
    }

    /// Forgets everything: a new session has not changed any file yet.
    pub fn clear(self: *Changed) void {
        self.len = 0;
        self.dropped = 0;
    }
};

/// The report, built line by line.
///
/// The header is composed LAST and put in FRONT: the counts are only known
/// once every file has been added, and a header that says "0 files" above a
/// list of three is a header that lies.
pub const Report = struct {
    gpa: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    reads: usize = 0,
    changes: usize = 0,
    /// A `bash` command that was NOT read-only ran in this session.
    ///
    /// A command is a STRING, not a list of files, so the files it changed are
    /// not knowable from the call. The report says so instead of implying that
    /// the list is complete: a list that is silently incomplete is worse than
    /// no list.
    bash_may_write: bool = false,

    pub fn init(gpa: std.mem.Allocator) Report {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Report) void {
        self.body.deinit(self.gpa);
    }

    /// A section title ("changed").
    pub fn addSection(self: *Report, title: []const u8) !void {
        if (self.body.items.len > 0) try self.body.append(self.gpa, '\n');
        try self.body.appendSlice(self.gpa, title);
    }

    /// One file the model has read.
    ///
    /// `in_context` is the fact that matters: it says whether the model can
    /// still see the content, which is a different question from whether the
    /// file was read.
    pub fn addRead(self: *Report, path: []const u8, lines: u32, in_context: bool) !void {
        if (self.body.items.len > 0) try self.body.append(self.gpa, '\n');
        try self.body.print(self.gpa, "  {s: <30} {d: >7} lines  \u{b7} {s}", .{
            path,
            lines,
            if (in_context) "in context" else "not in context",
        });
        self.reads += 1;
    }

    /// One file the agent wrote to.
    pub fn addChanged(self: *Report, path: []const u8) !void {
        if (self.body.items.len > 0) try self.body.append(self.gpa, '\n');
        try self.body.print(self.gpa, "  {s}", .{path});
        self.changes += 1;
    }

    /// A note that does not belong to a section (the dropped files).
    pub fn addNote(self: *Report, text: []const u8) !void {
        if (self.body.items.len > 0) try self.body.append(self.gpa, '\n');
        try self.body.appendSlice(self.gpa, text);
    }

    /// The whole report, as one string. The caller owns it.
    ///
    /// `dropped` is how many changed files did not fit in the table: it is said
    /// out loud, because a list that stops silently reads as "that is all of
    /// them".
    pub fn finish(self: *Report, stats: Stats, dropped: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);

        if (self.reads == 0 and self.changes == 0 and !self.bash_may_write) {
            try out.appendSlice(self.gpa, "files \u{b7} nothing read or written yet this session");
            return out.toOwnedSlice(self.gpa);
        }

        try out.print(self.gpa, "files \u{b7} {d} read \u{b7} {d} changed this session", .{
            self.reads,
            self.changes,
        });
        if (self.body.items.len > 0) {
            try out.append(self.gpa, '\n');
            try out.appendSlice(self.gpa, self.body.items);
        }
        if (dropped > 0) {
            try out.print(self.gpa, "\n  \u{b7} {d} more file(s) not listed (the list holds {d})", .{
                dropped,
                max_changed,
            });
        }
        if (self.bash_may_write) {
            try out.print(self.gpa, "\n  \u{b7} a `bash` command may have changed files that are not in this list", .{});
        }
        if (stats.hits > 0 or stats.saved > 0) {
            try out.print(self.gpa, "\nread cache \u{b7} {d} re-read{s} avoided \u{b7} ~{d} KB not re-sent", .{
                stats.hits,
                if (stats.hits == 1) "" else "s",
                stats.saved / 1024,
            });
        }
        return out.toOwnedSlice(self.gpa);
    }
};

// ── tests ─────────────────────────────────────────────────────

const testing = std.testing;

test "the empty report says so, and does not show an empty section" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    const text = try r.finish(.{}, 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "nothing read or written") != null);
    try testing.expect(std.mem.indexOf(u8, text, "read cache") == null);
}

test "the header counts the files, and the rows say whether they are in the context" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    try r.addRead("src/tui.zig", 3420, true);
    try r.addRead("build.zig", 88, false);
    const text = try r.finish(.{ .hits = 2, .misses = 1, .saved = 49 * 1024 }, 0);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "2 read") != null);
    try testing.expect(std.mem.indexOf(u8, text, "src/tui.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "in context") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not in context") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2 re-reads avoided") != null);
    try testing.expect(std.mem.indexOf(u8, text, "~49 KB not re-sent") != null);
}

test "the changed files are their own section" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    try r.addSection("changed");
    try r.addChanged("src/agent.zig");
    try r.addChanged("src/commands.zig");
    const text = try r.finish(.{}, 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "2 changed") != null);
    try testing.expect(std.mem.indexOf(u8, text, "changed\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "src/agent.zig") != null);
}

test "the files that did not fit are said out loud" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    try r.addSection("changed");
    try r.addChanged("a.zig");
    const text = try r.finish(.{}, 3);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "3 more file(s) not listed") != null);
}

test "a bash that may have written says so, instead of implying a complete list" {
    var r = Report.init(testing.allocator);
    defer r.deinit();
    r.bash_may_write = true;
    const text = try r.finish(.{}, 0);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not in this list") != null);
    // And it is NOT the "nothing happened" line: a bash that may have written
    // is not "nothing written".
    try testing.expect(std.mem.indexOf(u8, text, "nothing read or written") == null);
}

test "Changed: the same file twice is one line" {
    var c = Changed{};
    c.note("src/tui.zig");
    c.note("src/agent.zig");
    c.note("src/tui.zig");
    try testing.expectEqual(@as(usize, 2), c.count());
    try testing.expectEqualStrings("src/tui.zig", c.at(0));
    try testing.expectEqualStrings("src/agent.zig", c.at(1));
    try testing.expectEqualStrings("", c.at(2));
}

test "Changed: the table stops at the cap and says how many were left out" {
    var c = Changed{};
    var i: usize = 0;
    while (i < max_changed + 5) : (i += 1) {
        var buf: [16]u8 = undefined;
        c.note(try std.fmt.bufPrint(&buf, "f{d}.zig", .{i}));
    }
    try testing.expectEqual(@as(usize, max_changed), c.count());
    try testing.expectEqual(@as(usize, 5), c.dropped);
}

test "Changed: a path that does not fit is dropped, not truncated" {
    var c = Changed{};
    var buf: [path_max + 10]u8 = undefined;
    const long = try std.fmt.bufPrint(&buf, "{s}", .{"x" ** (path_max + 5)});
    c.note(long);
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expectEqual(@as(usize, 1), c.dropped);
}

test "Changed: clear forgets everything, and a new session starts empty" {
    var c = Changed{};
    c.note("a.zig");
    c.clear();
    try testing.expectEqual(@as(usize, 0), c.count());
    try testing.expectEqual(@as(usize, 0), c.dropped);
}

