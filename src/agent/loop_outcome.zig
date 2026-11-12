const tui = @import("../tui.zig");
const agent_types = @import("types.zig");
const chat = @import("../chat.zig");
const taskloop = @import("../lib/taskloop.zig");

pub const TurnOutcome = agent_types.TurnOutcome;

pub const ErrorOps = struct {
    pushStopped: *const fn (*tui.Model) void,
    reportErr: *const fn (*tui.Model, anyerror) void,
    notePoolState: *const fn (*tui.Model) void,
};

pub fn handleRunOneTurnLoopError(m: *tui.Model, err: anyerror, iterations: usize, ops: ErrorOps) TurnOutcome {
    if (err == error.Cancelled or chat.cancel_current.load(.seq_cst)) {
        chat.cancel_current.store(false, .seq_cst);
        ops.pushStopped(m);
        return .{ .iterations = iterations, .capped = false, .reason = .cancelled };
    }
    ops.reportErr(m, err);
    ops.notePoolState(m);
    return .{ .iterations = iterations, .capped = false, .reason = .done };
}

pub const FinishOps = struct {
    runCeilingSummaryTurn: *const fn (*tui.Model, []const u8, usize, *bool, *taskloop.StopReason) void,
};

pub fn finishAgentLoopOutcome(
    m: *tui.Model,
    user_text: []const u8,
    iterations: usize,
    limit: usize,
    capped: *bool,
    reason: *taskloop.StopReason,
    ops: FinishOps,
) TurnOutcome {
    if (iterations >= limit) ops.runCeilingSummaryTurn(m, user_text, iterations, capped, reason);
    return .{
        .iterations = iterations,
        .capped = capped.*,
        .reason = reason.*,
    };
}
