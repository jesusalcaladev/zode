//! The repetition guard: the same tool, the same arguments, three times running.
//!
//! Not to be confused with `repeat.zig`, which provides comptime string repetition
//! for test data. This module is the runtime loop-detection guard used by the agent.
//!
//! ## Why it is separate from the limit
//!
//! A loop with a limit is stopped by the limit, which costs the whole budget first: the
//! model can burn twelve iterations re-reading the same file looking for something it
//! already has, and the user sees a normal-looking turn that ends for no stated reason.
//!
//! This catches the shape itself, and it says WHAT was repeated, so the stop is
//! informative instead of mysterious.
//!
//! ## Why a hash and not the arguments
//!
//! Comparing the bytes means owning them for the turn, and a collision here costs an
//! early stop on a turn that was going nowhere anyway — so the trade is already free.
//! `u64` FNV-1a over the tool name and the arguments. `0` is never a legal hash here
//! because `note` is only reached with a non-empty name.
//!
//! ## Why it is pure
//!
//! It was `Repeats`, a struct in a 6 000-line `agent.zig`, and its tests were the ones
//! that had to build a whole `Model` to reach it. The rule has no business knowing
//! what a `Model` is.

const std = @import("std");

pub const repeat_limit: u8 = 3;

/// Lecturas consecutivas sin una escritura nueva antes de que el harness
/// fuerce un cambio de rumbo. Detecta el bucle "read-file → read-file → read-file"
/// que nunca termina en un resumen.
pub const repeat_read_limit: u8 = 5;

/// The bounded response to a repeated tool call.
pub const Recovery = struct {
    nudged: bool = false,

    pub const Action = enum { nudge, stop };

    /// Offer one corrective prompt, then stop if the same loop returns.
    pub fn onRepeat(self: *Recovery) Action {
        if (self.nudged) return .stop;
        self.nudged = true;
        return .nudge;
    }
};

/// Whether the repetition guard is blind to this tool.
///
/// ## The criterion, and why it is not a list of conveniences
///
/// A guard on "the same call twice" can only be honest about calls that are trying to
/// DO something. These two are trying to SEE something, and neither has an argument
/// that could distinguish it from itself: the variable is time, and time is not in the
/// arguments. That is the whole test — not "is this tool important", which would let
/// every future tool argue itself an exemption.
///
/// `read` is exempt because re-reading what you just edited is correct. `bash_output`
/// because the `bash` schema instructs the model to poll with it, so a poll is the
/// harness recommending a repeat — measured stopping a real turn on the third one, with
/// a test suite still running.
pub fn isRepeatExempt(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "bash_output");
}

pub const Repeats = struct {
    last: u64 = 0,
    run: u8 = 0,
    tool: [64]u8 = undefined,
    tool_len: usize = 0,
    /// Lecturas consecutivas sin una escritura nueva (write/edit/notebook_edit).
    /// Detecta el bucle "read-file → read-file → read-file" que nunca termina.
    reads_since_write: u8 = 0,

    /// Feeds one call. Returns the tool name when this is the third identical one.
    pub fn note(self: *Repeats, name: []const u8, args_json: []const u8) ?[]const u8 {
        var h: u64 = 14695981039346656037;
        for (name) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        h ^= 0xff;
        h *%= 1099511628211;
        for (args_json) |c| {
            h ^= c;
            h *%= 1099511628211;
        }
        if (h == self.last and self.run > 0) {
            self.run += 1;
        } else {
            self.last = h;
            self.run = 1;
            self.tool_len = @min(name.len, self.tool.len);
            @memcpy(self.tool[0..self.tool_len], name[0..self.tool_len]);
        }
        if (self.run >= repeat_limit) return self.tool[0..self.tool_len];
        return null;
    }

    /// The guard as the loop applies it.
    ///
    /// The exemption lives HERE and not at the call site on purpose. It was at the call
    /// site first (`if (!std.mem.eql(u8, c.name, "read"))`), and the consequence was that
    /// the only tests for it had to be the ones that went through the whole tool
    /// executor, while `note` — the thing with the counter in it — could not be asked
    /// "what happens when you poll?" directly. A rule that lives in one place is a rule
    /// the tests can call.
    pub fn noteGuarded(self: *Repeats, name: []const u8, args_json: []const u8) ?[]const u8 {
        if (isRepeatExempt(name)) return null;
        return self.note(name, args_json);
    }

    /// Called when the model issues a `read`. Counts consecutive reads without
    /// a write in between. Returns "read" when the read limit is reached,
    /// signalling the loop to break out of a read-only spiral.
    pub fn noteRead(self: *Repeats) ?[]const u8 {
        self.reads_since_write += 1;
        if (self.reads_since_write >= repeat_read_limit) return "read";
        return null;
    }

    /// Called when the model writes or edits a file. Resets the read counter.
    pub fn noteWrite(self: *Repeats) void {
        self.reads_since_write = 0;
    }

    pub fn reset(self: *Repeats) void {
        self.* = .{};
    }
};

test "repetition recovery nudges once and then stops" {
    var recovery: Recovery = .{};
    try std.testing.expectEqual(Recovery.Action.nudge, recovery.onRepeat());
    try std.testing.expectEqual(Recovery.Action.stop, recovery.onRepeat());
}

test "repeats: noteGuarded counts identical calls, resets on different" {
    var r: Repeats = .{};
    const args = "{\"path\":\"x\"}";
    try std.testing.expect(r.noteGuarded("write", args) == null);
    try std.testing.expect(r.noteGuarded("write", args) == null);
    try std.testing.expectEqualStrings("write", r.noteGuarded("write", args).?);
    // Different args reset
    try std.testing.expect(r.noteGuarded("write", "{\"path\":\"y\"}") == null);
    try std.testing.expect(r.noteGuarded("write", "{\"path\":\"y\"}") == null);
    try std.testing.expectEqualStrings("write", r.noteGuarded("write", "{\"path\":\"y\"}").?);
}

test "repeats: reset clears state" {
    var r: Repeats = .{};
    const args = "{}";
    _ = r.noteGuarded("bash", args);
    _ = r.noteGuarded("bash", args);
    r.reset();
    try std.testing.expect(r.noteGuarded("bash", args) == null);
}

test "repeats: exemptions never trigger" {
    var r: Repeats = .{};
    for (0..5) |_| {
        try std.testing.expect(r.noteGuarded("read", "{}") == null);
        try std.testing.expect(r.noteGuarded("bash_output", "{}") == null);
    }
}

test "repeats: noteRead triggers after repeat_read_limit consecutive reads" {
    var r: Repeats = .{};
    for (0..repeat_read_limit - 1) |_| {
        try std.testing.expect(r.noteRead() == null);
    }
    try std.testing.expectEqualStrings("read", r.noteRead().?);
}

test "repeats: noteWrite resets the read counter" {
    var r: Repeats = .{};
    // Just under the limit
    for (0..repeat_read_limit - 1) |_| {
        try std.testing.expect(r.noteRead() == null);
    }
    r.noteWrite();
    // After a write, reads start from zero again
    for (0..repeat_read_limit - 1) |_| {
        try std.testing.expect(r.noteRead() == null);
    }
    try std.testing.expectEqualStrings("read", r.noteRead().?);
}

test "repeats: mixed reads and writes do not trigger early" {
    var r: Repeats = .{};
    // read, write, read, write, read - no spiral
    try std.testing.expect(r.noteRead() == null);
    r.noteWrite();
    try std.testing.expect(r.noteRead() == null);
    r.noteWrite();
    try std.testing.expect(r.noteRead() == null);
    r.noteWrite();
    try std.testing.expect(r.noteRead() == null);
}

