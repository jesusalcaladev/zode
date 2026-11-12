const std = @import("std");
const taskloop = @import("../lib/taskloop.zig");
const exitgate = @import("../lib/exitgate.zig");
const plan_mod = @import("../lib/plan.zig");
const goal_mod = @import("../lib/goal.zig");

/// Fingerprint of what changed since the last mark: files written, plan steps
/// closed, verified writes. Reading files is work but is NOT progress that earns
/// more budget.
pub const LoopMark = struct {
    files: usize,
    plan_done: u8,
    verified_writes: u32,
};

/// Headless equivalent: builds a LoopMark from the gate's counters.
pub fn loopMarkFromGate(writes: usize, plan_done: u8, verified_writes: u32) LoopMark {
    return .{
        .files = writes,
        .plan_done = plan_done,
        .verified_writes = verified_writes,
    };
}

/// Build a LoopMark from observed counters (model/turn state).
pub fn loopMarkFrom(files: usize, plan_done: u8, verified_writes: u32) LoopMark {
    return loopMarkFromGate(files, plan_done, verified_writes);
}

/// Map an exit gate + plan into a taskloop.Evidence, for the headless runner
/// which has no `*tui.Model`.
pub fn loopEvidenceFromGate(
    gate: exitgate.Gate,
    plan: plan_mod.Plan,
) taskloop.Evidence {
    const check_green = gate.verdict == .passed and gate.unverified() == 0;
    return .{
        .files_written = gate.writes,
        .check_green = check_green,
        .check_red = gate.verdict == .failed,
        .checkable = gate.checkable,
        .plan_open = plan.openCount(),
        .plan_done = plan.doneCount(),
        .tools_run = 0,
        .verdict = .none,
        .blocked_credible = false,
    };
}

pub const LoopEvidenceInput = struct {
    gate: exitgate.Gate,
    plan: plan_mod.Plan,
    goal_status: goal_mod.Status,
    files_written: usize,
    tools_run: usize,
};

pub fn loopEvidenceFrom(input: LoopEvidenceInput) taskloop.Evidence {
    const check_green = input.gate.verdict == .passed and input.gate.unverified() == 0;
    return .{
        .files_written = input.files_written,
        .check_green = check_green,
        .check_red = input.gate.verdict == .failed,
        .checkable = input.gate.checkable,
        .plan_open = input.plan.openCount(),
        .plan_done = input.plan.doneCount(),
        .tools_run = input.tools_run,
        .verdict = switch (input.goal_status) {
            .none => .none,
            .met => .met,
            .blocked => .blocked,
        },
        .blocked_credible = true,
    };
}

/// A one-line description of why the turn cannot end yet, for the checkpoint
/// prompt. English only.
pub fn progressText(e: taskloop.Evidence) []const u8 {
    if (e.check_red) return "the last check is RED";
    if (e.files_written > 0 and e.checkable and !e.check_green)
        return "the files you wrote have no green check behind them";
    if (e.plan_open > 0) return "the plan still has open steps";
    if (e.verdict == .none and e.tools_run > 0)
        return "the turn has not reached a verdict";
    return "no change was recorded in the last iteration";
}
