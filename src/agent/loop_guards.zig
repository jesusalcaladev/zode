const std = @import("std");
const tui = @import("app").tui;
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
        // The wire of every iteration is the session. A refusal shown only in
        // the transcript is a reason the MODEL cannot read, and the generic
        // nudge below cannot name it (saying "no passing check" when the check
        // is green and only `review` is missing is a false reason). Append the
        // exact text FIRST: `pushErrorOwned` takes ownership of the buffer.
        ops.appendHarnessPrompt(m, refusal);
        ops.pushErrorOwned(m, refusal);
        if (gate_continue_count.* >= gate_continue_limit) {
            ops.pushGateLimit(m, gate_continue_limit);
            // Breaking the loop used to end the turn with NO message to the
            // model: the user saw a TUI error line the model never received.
            var buf: [320]u8 = undefined;
            const final_note = std.mem.print(&buf, "The harness is ending this turn after {d} exit-gate refusals. The exact reason is in the message above; do not re-run the same check unchanged. Write a final summary naming precisely what is done, what is not, and what you could not verify.", .{gate_continue_limit}) catch "The harness is ending this turn after repeated exit-gate refusals. Write a final summary naming precisely what is done and what remains.";
            ops.appendHarnessPrompt(m, final_note);
            return .break_loop;
        }
        gate_continue_count.* += 1;
        ops.appendHarnessPrompt(m, "The harness will not end this turn yet: an exit gate refused it, and the exact reason is in the message above. Resolve that reason, then let the required check run again and end the turn. If you genuinely cannot, call `goal` with status blocked and what_would_unblock.");
        return .continue_loop;
    }
    return .proceed;
}

// ── tests ────────────────────────────────────────────────────────────────

const Capture = struct {
    prompts: std.ArrayList([]const u8) = .empty,
    errors: std.ArrayList([]const u8) = .empty,
    gate_limits: u8 = 0,
};
var g_capture: ?*Capture = null;
var g_gpa: std.mem.Allocator = undefined;

fn capAppend(_: *tui.Model, text: []const u8) void {
    if (g_capture) |c| c.prompts.append(g_gpa, g_gpa.dupe(u8, text) catch return) catch {};
}
fn capError(_: *tui.Model, text: []const u8) void {
    if (g_capture) |c| c.errors.append(g_gpa, g_gpa.dupe(u8, text) catch return) catch {};
}
fn capErrorOwned(_: *tui.Model, text: []const u8) void {
    if (g_capture) |c| c.errors.append(g_gpa, text) catch {};
}
fn capGateLimit(_: *tui.Model, _: u8) void {
    if (g_capture) |c| c.gate_limits += 1;
}
fn capRepeatStop(_: *tui.Model, _: []const u8) void {}

fn testOps(io: std.Io) UiOps {
    return .{
        .io = io,
        .appendHarnessPrompt = capAppend,
        .pushError = capError,
        .pushErrorOwned = capErrorOwned,
        .pushGateLimit = capGateLimit,
        .pushRepeatStop = capRepeatStop,
    };
}

test "exit gate: the exact refusal reaches the session, and a limit break is not silent" {
    // The refusal used to be `pushErrorOwned` ONLY — shown in the TUI, never
    // appended to the session, so the model got a generic (and for
    // `refused_review`, false) nudge instead of the reason it had to fix.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    g_gpa = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var m = tui.Model.init(g_gpa);
    defer m.deinit();

    // A finished, RED check over a write: `decide()` returns `.refused_failed`.
    m.auto_check.gate.writes = 1;
    m.auto_check.gate.checkable = true;
    m.auto_check.gate.verdict = .failed;
    m.auto_check.review_known = true;

    var cap = Capture{};
    g_capture = &cap;
    defer g_capture = null;
    const ops = testOps(threaded.io());

    var count: u8 = 0;
    try std.testing.expect(applyExitGateCheck(&m, &count, 3, ops) == .continue_loop);
    try std.testing.expectEqual(@as(usize, 2), cap.prompts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.prompts.items[0], "RED") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.prompts.items[1], "exact reason") != null);
    try std.testing.expectEqual(@as(usize, 1), cap.errors.items.len);
    try std.testing.expectEqual(@as(u8, 1), count);

    // At the limit the turn breaks, but the model still gets a closing message
    // instead of the last tool result followed by silence.
    count = 3;
    try std.testing.expect(applyExitGateCheck(&m, &count, 3, ops) == .break_loop);
    try std.testing.expectEqual(@as(u8, 1), cap.gate_limits);
    try std.testing.expectEqual(@as(usize, 4), cap.prompts.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.prompts.items[3], "ending this turn") != null);
}
