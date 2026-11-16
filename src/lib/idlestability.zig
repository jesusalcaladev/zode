//! Stable-idle detection (Phase 32.4): one rule for anything that finishes in
//! the background. A single idle observation means NOTHING between tool turns;
//! and a completion tag can split across pipe flushes. So BOTH are required:
//!
//!   STABLE_IDLE_POLLS = 5 consecutive idle polls with no log growth
//!   AND an explicit completion tag.
//!
//! Pure on purpose: the counter is testable without a process, a pipe or a
//! clock. The caller feeds it what it observed.

const std = @import("std");

pub const STABLE_IDLE_POLLS: usize = 5;

pub const Tracker = struct {
    idle_polls: usize = 0,
    last_log_bytes: usize = 0,
    /// Set once the explicit completion tag has been SEEN in full. A tag that
    /// splits across flushes is not complete, so callers accumulate it before
    /// calling `noteTag`.
    tagged: bool = false,

    /// One poll. Growth resets the idle streak; no growth extends it.
    pub fn poll(self: *Tracker, log_bytes: usize) void {
        if (log_bytes > self.last_log_bytes) {
            self.last_log_bytes = log_bytes;
            self.idle_polls = 0;
        } else {
            if (self.idle_polls < STABLE_IDLE_POLLS) self.idle_polls += 1;
        }
    }

    pub fn noteTag(self: *Tracker) void {
        self.tagged = true;
    }

    /// Complete only when BOTH conditions hold. Never one alone.
    pub fn complete(self: *const Tracker) bool {
        return self.tagged and self.idle_polls >= STABLE_IDLE_POLLS;
    }
};

/// Accumulates bytes across polls until the completion tag appears whole —
/// a tag split across pipe flushes must still be recognised.
pub const TagScanner = struct {
    tail: [64]u8 = undefined,
    tail_len: usize = 0,

    pub fn feed(self: *TagScanner, chunk: []const u8, tag: []const u8) bool {
        if (tag.len == 0 or tag.len > self.tail.len) return false;
        var combined: [128]u8 = undefined;
        const take = @min(self.tail_len, combined.len);
        @memcpy(combined[0..take], self.tail[0..take]);
        const room = combined.len - take;
        const add = @min(chunk.len, room);
        @memcpy(combined[take .. take + add], chunk[0..add]);
        const total = take + add;
        if (std.mem.indexOf(u8, combined[0..total], tag) != null) return true;
        // Keep only the last `tag.len - 1` bytes so a split across the boundary
        // is joined on the next feed.
        const keep = @min(tag.len - 1, total);
        @memcpy(self.tail[0..keep], combined[total - keep .. total]);
        self.tail_len = keep;
        return false;
    }
};

test "idlestability: one idle poll is not enough" {
    var t = Tracker{};
    t.poll(10); // establish the baseline byte count (growth, not idle)
    for (0..STABLE_IDLE_POLLS - 1) |_| t.poll(10);
    t.noteTag();
    try std.testing.expect(!t.complete());
    t.poll(10);
    try std.testing.expect(t.complete());
}

test "idlestability: tag alone is not enough" {
    var t = Tracker{};
    for (0..STABLE_IDLE_POLLS + 2) |_| t.poll(10);
    try std.testing.expect(!t.complete()); // no tag
}

test "idlestability: log growth resets the idle streak" {
    var t = Tracker{};
    for (0..4) |_| t.poll(10);
    t.poll(20); // growth
    try std.testing.expectEqual(@as(usize, 0), t.idle_polls);
    for (0..STABLE_IDLE_POLLS) |_| t.poll(20);
    t.noteTag();
    try std.testing.expect(t.complete());
}

test "idlestability: a tag split across flushes is still found" {
    var s = TagScanner{};
    try std.testing.expect(!s.feed("log line ... __ZODE_DO", "__ZODE_DONE__"));
    try std.testing.expect(s.feed("NE__ trailing", "__ZODE_DONE__"));
}

test "idlestability: STABLE_IDLE_POLLS is five" {
    try std.testing.expectEqual(@as(usize, 5), STABLE_IDLE_POLLS);
}
