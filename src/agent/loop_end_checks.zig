const std = @import("std");
const tui = @import("../tui.zig");
const goal_mod = @import("../lib/goal.zig");
const taskloop = @import("../lib/taskloop.zig");
const loop_evidence = @import("loop_evidence.zig");

pub const LoopFlowAction = enum { proceed, continue_loop, break_loop };

pub const Ops = struct {
    appendHarnessPrompt: *const fn (*tui.Model, []const u8) void,
    pushError: *const fn (*tui.Model, []const u8) void,
    pushErrorOwned: *const fn (*tui.Model, []u8) void,
    pushGoalMetOpenSteps: *const fn (*tui.Model, usize, usize, usize) void,
    currentPermModeIsReadOnly: *const fn () bool,
    planApprovalNudge: *const fn (*tui.Model) ?[]u8,
    loopV2: *const fn () bool,
    loopEvidence: *const fn (*const tui.Model) taskloop.Evidence,
    loopMark: *const fn (*const tui.Model) loop_evidence.LoopMark,
    progressText: *const fn (taskloop.Evidence) []const u8,
};

pub fn applyGoalContractAndEnd(
    m: *tui.Model,
    reason: *taskloop.StopReason,
    tools_run: usize,
    ops: Ops,
) LoopFlowAction {
    // Goal `met` contradicting open plan steps: refuse once and continue.
    if (!goal_mod.verdictIsFinal(m.goal, m.plan.openCount()) and
        m.goal.status == goal_mod.Status.met and
        m.goal.checkpoints == 0)
    {
        var g = m.goal;
        g.checkpoints += 1;
        m.goal = g;
        m.goal.status = goal_mod.Status.none;
        ops.pushGoalMetOpenSteps(m, m.plan.openCount(), m.plan.doneCount(), m.plan.items.len);
        ops.appendHarnessPrompt(m, "The harness will not accept `met` yet: your plan still has open steps. Finish them, tick them with `todo`, and call `goal` again — or, if they genuinely cannot be finished here, call `goal` with status blocked and what_would_unblock.");
        return .continue_loop;
    }

    // Non-credible `blocked` (no real attempt/evidence): refuse once and continue.
    if (!goal_mod.verdictCredible(&m.goal, tools_run)) {
        m.goal.blocked_refusals += 1;
        m.goal.status = goal_mod.Status.none;
        const why = goal_mod.blockedRetryText(m.allocator) catch return .break_loop;
        ops.pushErrorOwned(m, why);
        ops.appendHarnessPrompt(m, goal_mod.blockedRetryPrompt());
        return .continue_loop;
    }

    if (m.goal.status != goal_mod.Status.none) {
        reason.* = .done;
        return .break_loop;
    }

    return .break_loop; // natural end
}

pub fn applyNaturalTurnEndChecks(
    m: *tui.Model,
    plan_gate_asks: *u8,
    reason: *taskloop.StopReason,
    ops: Ops,
) LoopFlowAction {
    // Plan approval gate: in read-only/plan mode, do not end with unanswered plan.
    if (ops.currentPermModeIsReadOnly()) {
        if (m.plan_write_blocked_this_turn and !m.plan_touched_this_turn and m.plan_missing_nudges_this_turn < 2) {
            m.plan_missing_nudges_this_turn += 1;
            ops.appendHarnessPrompt(m, "Plan mode blocked a write because no implementation plan has been recorded yet. Use `todo` to show a complete, concrete plan: include objective (what success looks like), approach (how/files/strategy), guardrails (what must not break and how to verify), and concrete steps with how/verify notes. Then end your turn so the user can approve or revise it. Do not retry the blocked write.");
            return .continue_loop;
        }
        if (m.plan_write_blocked_this_turn and !m.plan_touched_this_turn) {
            ops.pushError(m, "plan mode is still active: no implementation plan was recorded, so no approval was requested and no write was allowed");
            return .break_loop;
        }
        if (m.plan_touched_this_turn and !m.plan.isEmpty() and plan_gate_asks.* < 2) {
            plan_gate_asks.* += 1;
            if (ops.planApprovalNudge(m)) |nudge| {
                ops.appendHarnessPrompt(m, nudge);
                m.allocator.free(nudge);
                return .continue_loop;
            }
        }
    }

    // LoopV2 completion contract before natural end.
    if (ops.loopV2()) {
        const evidence = ops.loopEvidence(m);
        if (taskloop.endReason(evidence)) |why| {
            reason.* = why;
            return .break_loop;
        }
        if (m.plan_touched_this_turn and m.plan.openCount() > 0 and plan_gate_asks.* < 2) {
            plan_gate_asks.* += 1;
            ops.appendHarnessPrompt(m, "Your plan still has open steps. Continue the task and close them, or call `goal` with status blocked and what_would_unblock if they cannot be finished here.");
            return .continue_loop;
        }
        if (m.goal.isOpen() and m.goal.checkpoints < 2) {
            m.goal.checkpoints += 1;
            ops.appendHarnessPrompt(m, "The goal is still open. Keep going until it is met, or call `goal` with status blocked and what_would_unblock.");
            return .continue_loop;
        }
        reason.* = .stalled;
        return .break_loop;
    }
    return .break_loop;
}


/// Task-scoped budget checkpoint (LoopV2). Returns true if loop should stop.
pub fn applyLoopV2BudgetCheckpoint(
    m: *tui.Model,
    iterations: usize,
    policy: *?taskloop.Policy,
    last_mark: *?loop_evidence.LoopMark,
    reason: *taskloop.StopReason,
    ops: Ops,
) bool {
    if (!(ops.loopV2() and iterations > 0)) return false;
    const mark = ops.loopMark(m);
    const changed = !std.meta.eql(mark, last_mark.* orelse mark);
    if (policy.*) |*p| {
        p.note(iterations, changed);
        last_mark.* = mark;
        switch (p.decide(iterations)) {
            .work => {},
            .checkpoint => {
                const prompt = std.fmt.allocPrint(
                    m.allocator,
                    "Checkpoint: {d} iterations used, {d} left before the next one. {s}. Keep going and finish what is open; do not restart work that is already done. If it genuinely cannot be finished here, call `goal` with status blocked and what_would_unblock.\n",
                    .{ iterations, p.budget.soft - iterations, ops.progressText(ops.loopEvidence(m)) },
                ) catch null;
                if (prompt) |text| {
                    ops.appendHarnessPrompt(m, text);
                    m.allocator.free(text);
                }
            },
            .stop => |why| {
                reason.* = why;
                return true;
            },
        }
    }
    return reason.* != .done;
}
