//! Periodic ticks while a turn is parked (Phase 19). Pure on purpose: the
//! decision "should a check-in fire now?" depends only on booleans and a
//! counter — no Model, no clock, no TUI. The harness owns the clock and the
//! delivery (via the session's `appendHarnessPrompt` door).
//!
//! WHY OFF BY DEFAULT: an unasked check-in in the middle of a turn is noise.
//! A session flag turns it on; and a tick is NEVER emitted while a tool is
//! running or a request is streaming — "parked" means waiting, not working.

const std = @import("std");

pub const default_interval_ms: u64 = 30_000;

pub const State = struct {
    enabled: bool = false,
    /// Last tick, in epoch ms. 0 = never.
    last_ms: u64 = 0,
    interval_ms: u64 = default_interval_ms,

    /// Should a tick fire now? `tool_running` and `busy` are the harness's
    /// predicates (Model.tool_run / isBusy). A tick is suppressed while EITHER
    /// is true — that is the "tick is suppressed while a tool is running" rule.
    pub fn due(self: *const State, now_ms: u64, tool_running: bool, busy: bool) bool {
        if (!self.enabled) return false;
        if (tool_running or busy) return false;
        if (self.last_ms == 0) return true;
        return now_ms >= self.last_ms + self.interval_ms;
    }

    pub fn mark(self: *State, now_ms: u64) void {
        self.last_ms = now_ms;
    }

    pub fn reset(self: *State) void {
        self.last_ms = 0;
    }
};

pub const checkin_text = "Anything useful to do while you wait? If not, say so and stop.";

test "tick: off by default, on after enable" {
    var s = State{};
    try std.testing.expect(!s.due(1000, false, false));
    s.enabled = true;
    try std.testing.expect(s.due(1000, false, false));
}

test "tick: suppressed while a tool is running or the turn is busy" {
    var s = State{ .enabled = true };
    try std.testing.expect(!s.due(1000, true, false));
    try std.testing.expect(!s.due(1000, false, true));
    try std.testing.expect(s.due(1000, false, false));
}

test "tick: respects the interval between check-ins" {
    var s = State{ .enabled = true, .interval_ms = 1000 };
    try std.testing.expect(s.due(1000, false, false));
    s.mark(1000);
    try std.testing.expect(!s.due(1500, false, false));
    try std.testing.expect(s.due(2000, false, false));
    s.reset();
    try std.testing.expect(s.due(2000, false, false));
}
