const std = @import("std");
const tui = @import("../tui.zig");
const goal_mod = @import("../lib/goal.zig");
const repeats_mod = @import("../lib/repeat_guard.zig");

pub const LoopGuardAction = enum { proceed, continue_loop, break_loop };
pub const ExitGateAction = enum { proceed, continue_loop, break_loop };

pub const UiOps = struct {
    io: std.Io,
    appendHarnessPrompt: *const fn (*tui.Model, []const u8) void,
    pushError: *const fn (*tui.Model, []const u8) void,
    pushErrorOwned: *const fn (*tui.Model, []u8) void,
    pushGateLimit: *const fn (*tui.Model, u8) void,
    pushRepeatStop: *const fn (*tui.Model, []const u8) void,
};

/// Stop hook guard: may claim the turn only after exit gate passes.
pub fn applyStopHookGuard(m: *tui.Model, ops: UiOps) bool {
    if (m.auto_check.stopHookCheck("turn_end", m.allocator)) |refusal| {
        ops.pushError(m, refusal);
        ops.appendHarnessPrompt(m, "The harness will not end this turn yet: a stop hook is in force. Resolve it and end the turn, or remove the hook.");
        return true; // continue loop
    }
    return false;
}

/// Repeated tool-call guard.
pub fn applyRepeatGuard(m: *tui.Model, repeat_recovery: *repeats_mod.Recovery, ops: UiOps) LoopGuardAction {
    if (m.loop_repeated) |which| {
        m.loop_repeated = null;
        // A read spiral is not "the same call with unchanged arguments": it is
        // one file read again and again. Telling the model the arguments are
        // unchanged would be false, and a false reason is a reason it cannot
        // act on.
        const same_file = std.mem.eql(u8, which, "read");
        switch (repeat_recovery.onRepeat()) {
            .nudge => {
                m.repeats.reset();
                if (same_file) {
                    ops.appendHarnessPrompt(m, "The harness detected the same file being read over and over without a change in between. Its content is already above you; do not read it again unchanged. Use what you have, or read a different file.");
                } else {
                    ops.appendHarnessPrompt(m, "The harness detected the same tool call repeated with unchanged arguments. Do not call it again unchanged. Inspect the prior result and choose a materially different next step; if the operation is genuinely necessary, explain why before trying it once with a deliberate change.");
                }
                return .continue_loop;
            },
            .stop => {
                if (same_file) {
                    ops.appendHarnessPrompt(m, "The harness stopped this turn because the same file was read again after you were asked to change approach. Summarize what you learned and what remains.");
                } else {
                    ops.appendHarnessPrompt(m, "The harness stopped this turn because the same tool call repeated with unchanged arguments after you were asked to change approach. Summarize what you learned and what remains.");
                }
                ops.pushRepeatStop(m, which);
                return .break_loop;
            },
        }
    }
    return .proceed;
}

/// Exit gate: refuse to end on red/stale/unverified code.
pub fn applyExitGateCheck(
    m: *tui.Model,
    gate_continue_count: *u8,
    gate_continue_limit: u8,
    ops: UiOps,
) ExitGateAction {
    if (m.goal.status == goal_mod.Status.blocked) return .proceed;
    if (m.auto_check.exitGate(&m.bg, m.allocator, ops.io)) |refusal| {
        // A `met` that the code contradicts goes back to open.
        if (m.goal.status == goal_mod.Status.met) m.goal.status = goal_mod.Status.none;
        ops.pushErrorOwned(m, refusal);
        if (gate_continue_count.* >= gate_continue_limit) {
            ops.pushGateLimit(m, gate_continue_limit);
            return .break_loop;
        }
        gate_continue_count.* += 1;
        ops.appendHarnessPrompt(m, "The harness will not end this turn yet: the code you wrote does not have a passing check behind it. Read the problems above, fix them, and let the check run again. If you genuinely cannot, call `goal` with status blocked and what_would_unblock.");
        return .continue_loop;
    }
    return .proceed;
}
