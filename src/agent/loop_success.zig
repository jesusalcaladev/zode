const tui = @import("../tui.zig");
const repeats_mod = @import("../lib/repeat_guard.zig");
const taskloop = @import("../lib/taskloop.zig");
const loop_guards = @import("loop_guards.zig");
const loop_end_checks = @import("loop_end_checks.zig");

pub const LoopFlowAction = loop_end_checks.LoopFlowAction;

pub const Ops = struct {
    applyExitGateCheck: *const fn (*tui.Model, *u8, u8) loop_guards.ExitGateAction,
    applyStopHookGuard: *const fn (*tui.Model) bool,
    applyRepeatGuard: *const fn (*tui.Model, *repeats_mod.Recovery) loop_guards.LoopGuardAction,
    applyNaturalTurnEndChecks: *const fn (*tui.Model, *u8, *taskloop.StopReason) LoopFlowAction,
};

pub fn handle(
    m: *tui.Model,
    again: bool,
    gate_continue_count: *u8,
    gate_continue_limit: u8,
    repeat_recovery: *repeats_mod.Recovery,
    plan_gate_asks: *u8,
    reason: *taskloop.StopReason,
    ops: Ops,
) LoopFlowAction {
    // 0. Exit gate: refuse to end on red/stale/unverified code (runs every iteration).
    switch (ops.applyExitGateCheck(m, gate_continue_count, gate_continue_limit)) {
        .proceed => {},
        .continue_loop => return .continue_loop,
        .break_loop => return .break_loop,
    }

    // Stop hook may claim the turn only after exit gate passes.
    if (ops.applyStopHookGuard(m)) return .continue_loop;

    switch (ops.applyRepeatGuard(m, repeat_recovery)) {
        .proceed => {},
        .continue_loop => return .continue_loop,
        .break_loop => return .break_loop,
    }

    if (!again) {
        switch (ops.applyNaturalTurnEndChecks(m, plan_gate_asks, reason)) {
            .proceed => {},
            .continue_loop => return .continue_loop,
            .break_loop => return .break_loop,
        }
    }

    if (again) return .continue_loop; // tool results are already in the session; ask the model again
    return .proceed; // Goal contract + natural end decides final stop/continue.
}
