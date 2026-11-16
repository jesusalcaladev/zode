//! Three-way finding counts (Phase 32.1): the protocol a `verify`-role report
//! carries from the finder to the reader.
//!
//! WHY A PROTOCOL AND NOT A PROMPT: this file defines the DATA — `found`,
//! `verified`, `refuted` — and how it is rendered. It does not tell any model
//! what to look for; that checklist is ours, in `review.zig`. Porting the
//! protocol without importing a server-side finder prompt is the whole point.
//!
//! Pure on purpose: formatting and the "no data is not zero" rule are testable
//! without the TUI, without the network and without a subagent run.

const std = @import("std");

pub const Finding = enum { found, verified, refuted };

pub const Counts = struct {
    found: usize = 0,
    verified: usize = 0,
    refuted: usize = 0,

    /// Every report starts here: NO DATA. "setting up" must never read as
    /// "0 findings" — that is `proofWord(.nothing) -> "not checked"` applied
    /// to a progress pill.
    pub fn hasData(self: Counts) bool {
        return self.found > 0 or self.verified > 0 or self.refuted > 0;
    }

    pub fn note(self: *Counts, f: Finding) void {
        switch (f) {
            .found => self.found += 1,
            .verified => self.verified += 1,
            .refuted => self.refuted += 1,
        }
    }

    /// Word labels, never ✓/✗: provenance icons tell the reader where a
    /// verdict came from and silently lose that information when pasted.
    pub fn format(self: Counts, gpa: std.mem.Allocator) ![]const u8 {
        if (!self.hasData()) return gpa.dupe(u8, "setting up");
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.print(gpa, "{d} found · {d} verified", .{ self.found, self.verified });
        // Hide the refuted count at zero: a stable "0 refuted" prefix teaches
        // the eye to ignore the line. Show it only when it carries information.
        if (self.refuted > 0) try out.print(gpa, " · {d} refuted", .{self.refuted});
        return out.toOwnedSlice(gpa);
    }
};

/// Parses the report lines emitted by the verify role ("found:", "verified:",
/// "refuted:") into counts. Line-oriented and case-sensitive on the prefix so
/// a quoted "found:" in prose does not inflate the count — only a line that
/// STARTS with the marker counts.
pub fn parseReport(text: []const u8) Counts {
    var c = Counts{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t-*");
        if (std.mem.startsWith(u8, line, "found:")) c.found += 1 else if (std.mem.startsWith(u8, line, "verified:")) c.verified += 1 else if (std.mem.startsWith(u8, line, "refuted:")) c.refuted += 1;
    }
    return c;
}

pub const Phase = enum {
    setting_up,
    finding,
    verifying,
    deduping,
    ready,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .setting_up => "setting up",
            .finding => "finding",
            .verifying => "verifying",
            .deduping => "deduping",
            .ready => "ultrareview ready",
        };
    }
};

/// The +1 animation counter, mirroring the `tps_win_ns` rolling-window pattern:
/// a value that climbs by one per tick toward a target, never jumping, so the
/// reader sees the count move. Pure — the TUI owns the clock.
pub const Counter = struct {
    target: usize = 0,
    shown: usize = 0,

    pub fn setTarget(self: *Counter, n: usize) void {
        if (n > self.target) self.target = n;
    }

    pub fn tick(self: *Counter) bool {
        if (self.shown >= self.target) return false;
        self.shown += 1;
        return true;
    }

    pub fn done(self: *const Counter) bool {
        return self.shown >= self.target;
    }
};

test "verifycounts: no data reads as setting up, not zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Counts{};
    try std.testing.expect(!c.hasData());
    const s = try c.format(a);
    try std.testing.expectEqualStrings("setting up", s);
}

test "verifycounts: refuted hidden at zero, shown when positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Counts{ .found = 12, .verified = 5 };
    const s = try c.format(a);
    try std.testing.expectEqualStrings("12 found · 5 verified", s);
    const c2 = Counts{ .found = 12, .verified = 5, .refuted = 2 };
    const s2 = try c2.format(a);
    try std.testing.expectEqualStrings("12 found · 5 verified · 2 refuted", s2);
}

test "verifycounts: word labels only, no provenance icons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_of_each = Counts{ .found = 1, .verified = 1, .refuted = 1 };
    const s = try one_of_each.format(a);
    try std.testing.expect(std.mem.indexOf(u8, s, "✓") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "✗") == null);
    for ([_]Phase{ .setting_up, .finding, .verifying, .deduping, .ready }) |p| {
        try std.testing.expect(p.label().len > 0);
        try std.testing.expect(std.mem.indexOf(u8, p.label(), "✓") == null);
    }
}

test "verifycounts: counter animates +1 toward the target" {
    var c = Counter{};
    c.setTarget(3);
    try std.testing.expect(!c.done());
    try std.testing.expect(c.tick());
    try std.testing.expectEqual(@as(usize, 1), c.shown);
    _ = c.tick();
    _ = c.tick();
    try std.testing.expect(c.done());
    try std.testing.expect(!c.tick());
}

test "verifycounts: parseReport counts only marker lines" {
    const r =
        \\found: a risky branch
        \\verified: it fails with a 500
        \\refuted: the other candidate held up
        \\This prose mentions found: but is not a finding.
        \\  verified: an indented one
    ;
    const c = parseReport(r);
    try std.testing.expectEqual(@as(usize, 1), c.found);
    try std.testing.expectEqual(@as(usize, 2), c.verified);
    try std.testing.expectEqual(@as(usize, 1), c.refuted);
}
