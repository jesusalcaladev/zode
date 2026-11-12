const std = @import("std");
const tui = @import("../tui.zig");
const chat = @import("../chat.zig");
const taskloop = @import("../lib/taskloop.zig");
const repeats_mod = @import("../lib/repeat_guard.zig");
const agent_types = @import("types.zig");
const loop_evidence = @import("loop_evidence.zig");
const loop_iter = @import("loop_iter.zig");
const loop_success = @import("loop_success.zig");

pub const TurnOutcome = agent_types.TurnOutcome;

pub const State = struct {
    iterations: usize = 0,
    limit: usize,
    repeat_recovery: repeats_mod.Recovery = .{},
    plan_gate_asks: u8 = 0,
    capped: bool = false,
    gate_continue_count: u8 = 0,
    gate_continue_limit: u8 = 3,
    policy: ?taskloop.Policy = null,
    last_mark: ?loop_evidence.LoopMark = null,
    reason: taskloop.StopReason = .done,
};

pub const InitOps = struct {
    fireUserPromptSubmitHooks: *const fn (*tui.Model, []const u8) void,
    resetInheritedGoalState: *const fn (*tui.Model) void,
    statusIterationLimit: *const fn (*const tui.Model) usize,
    loopV2: *const fn () bool,
    loopBudget: *const fn (*const tui.Model) taskloop.Budget,
    loopMark: *const fn (*const tui.Model) loop_evidence.LoopMark,
    drainBackgroundTaskNotifications: *const fn (*tui.Model) void,
};

pub fn init(m: *tui.Model, user_text: []const u8, ops: InitOps) State {
    ops.fireUserPromptSubmitHooks(m, user_text);
    // Clear inherited goal state so queued turns don't inherit previous objective.
    ops.resetInheritedGoalState(m);

    var st = State{ .limit = ops.statusIterationLimit(m) };
    m.repeats.reset();

    // A NEW turn starts un-cancelled: ESC belongs to the turn it interrupted.
    chat.cancel_current.store(false, .seq_cst);
    // Defensive: a previous path must never leave the schema/tool gate stuck.
    m.deny_all_tools = false;

    if (ops.loopV2()) {
        st.policy = taskloop.Policy{ .budget = ops.loopBudget(m) };
        st.last_mark = ops.loopMark(m);
    }
    ops.drainBackgroundTaskNotifications(m);
    return st;
}

pub const RunOps = struct {
    init: InitOps,
    beginLoopIteration: *const fn (*tui.Model, usize, *?taskloop.Policy, *?loop_evidence.LoopMark, *taskloop.StopReason) loop_iter.LoopIterStart,
    runOneTurn: *const fn (*tui.Model, []const u8, usize) anyerror!bool,
    handleRunOneTurnLoopError: *const fn (*tui.Model, anyerror, usize) TurnOutcome,
    handleLoopTurnSuccess: *const fn (*tui.Model, bool, *u8, u8, *repeats_mod.Recovery, *u8, *taskloop.StopReason) loop_success.LoopFlowAction,
    applyGoalContractAndEnd: *const fn (*tui.Model, *taskloop.StopReason) loop_success.LoopFlowAction,
    finishAgentLoopOutcome: *const fn (*tui.Model, []const u8, usize, usize, *bool, *taskloop.StopReason) TurnOutcome,
};

pub fn run(m: *tui.Model, user_text: []const u8, ops: RunOps) TurnOutcome {
    var st = init(m, user_text, ops.init);

    while (st.iterations < st.limit) : (st.iterations += 1) {
        if (ops.beginLoopIteration(m, st.iterations, &st.policy, &st.last_mark, &st.reason) == .stop) break;
        const again = ops.runOneTurn(m, user_text, st.iterations) catch |err| {
            return ops.handleRunOneTurnLoopError(m, err, st.iterations);
        };
        switch (ops.handleLoopTurnSuccess(
            m,
            again,
            &st.gate_continue_count,
            st.gate_continue_limit,
            &st.repeat_recovery,
            &st.plan_gate_asks,
            &st.reason,
        )) {
            .continue_loop => continue,
            .break_loop => break,
            .proceed => {
                switch (ops.applyGoalContractAndEnd(m, &st.reason)) {
                    .proceed => {},
                    .continue_loop => continue,
                    .break_loop => break,
                }
            },
        }
    }

    return ops.finishAgentLoopOutcome(m, user_text, st.iterations, st.limit, &st.capped, &st.reason);
}
