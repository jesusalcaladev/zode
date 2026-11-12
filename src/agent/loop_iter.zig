const std = @import("std");
const tui = @import("../tui.zig");
const chat = @import("../chat.zig");
const taskloop = @import("../lib/taskloop.zig");
const loop_evidence = @import("loop_evidence.zig");

pub const LoopIterStart = enum { proceed, stop };

pub const Ops = struct {
    drainBackgroundTaskNotifications: *const fn (*tui.Model) void,
    pushStopped: *const fn (*tui.Model) void,
    applyLoopV2BudgetCheckpoint: *const fn (*tui.Model, usize, *?taskloop.Policy, *?loop_evidence.LoopMark, *taskloop.StopReason) bool,
    setTurnIteration: *const fn (usize) void,
};

pub fn begin(
    m: *tui.Model,
    iterations: usize,
    policy: *?taskloop.Policy,
    last_mark: *?loop_evidence.LoopMark,
    reason: *taskloop.StopReason,
    ops: Ops,
) LoopIterStart {
    ops.drainBackgroundTaskNotifications(m);
    // ESC is a STOP, not a "skip this answer".
    if (chat.cancel_current.load(.seq_cst)) {
        chat.cancel_current.store(false, .seq_cst);
        ops.pushStopped(m);
        reason.* = .cancelled;
        return .stop;
    }

    // Task-scoped budget checkpoint (ZODE_LOOP_V2 only).
    if (ops.applyLoopV2BudgetCheckpoint(m, iterations, policy, last_mark, reason)) return .stop;

    ops.setTurnIteration(iterations + 1);
    return .proceed;
}
