const std = @import("std");
const tui = @import("../tui.zig");
const agent_types = @import("types.zig");

pub const TurnOutcome = agent_types.TurnOutcome;

pub const Ops = struct {
    io: std.Io,
    appendUserLine: *const fn (*tui.Model, []const u8) void,
    resetTurnBudget: *const fn (*tui.Model) void,
    resetTurnStats: *const fn (*tui.Model, std.Io) void,
    deinitTurnStats: *const fn () void,
    runAgentLoop: *const fn (*tui.Model, []const u8) TurnOutcome,
    endTurn: *const fn (*tui.Model, usize, bool) void,
};

/// Runs the normal (non-pipeline/review) turn flow on the worker thread.
pub fn run(m: *tui.Model, user_text: []const u8, ops: Ops) void {
    ops.appendUserLine(m, user_text);
    ops.resetTurnBudget(m);

    ops.resetTurnStats(m, ops.io);
    defer ops.deinitTurnStats();
    m.implementation_nudges = 0;
    m.empty_reply_nudges = 0;

    const outcome = ops.runAgentLoop(m, user_text);
    m.streamEnd();
    ops.endTurn(m, outcome.iterations, outcome.capped);
}
